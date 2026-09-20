# frozen_string_literal: true

module ReactorSim
  # One advance of one operation, start to finish. Separate from `Operation` because the ORDER
  # of these phases is the most load-bearing and least obvious thing in the engine.
  #
  # Every phase reads the frozen previous tick and returns new state. Nothing here mutates the
  # operation — `Operation#step!` installs the result — which is what keeps a half-finished tick
  # from ever being observable.
  #
  #   0 ACTUATE   levers travel toward their targets; all actuation entropy is drawn here
  #   1 READ      freeze tick N-1 and build the context every node will see
  #   2 PLAN      every node declares intent, independently, against N-1
  #   3 SETTLE    one pure function over every claim — mass, heat and momentum alike
  #   4 TRANSFER  a advection  b conduction  c ambient  d drivetrain  e torque
  #   5 REACT     phase change and chemistry, local to each node
  #   6 STRESS    durability, overload, failure events
  #     a endanger — what a failure does to the people near it
  #     b tire     — what the work does to the people doing it
  #   7 OBSERVE   instruments sample and their filters advance
  #
  # Phase 4's internal order matters: mass moves before heat so a parcel's energy travels with
  # it, and torque is transmitted after node effects so a prime mover has computed the torque
  # before it is charged for it.
  class Tick
    # Bounds a hazard scaled by a runaway figure. Four times the reference is already far past
    # `Injury::MORTAL_BITE`, so this bounds a bug without bounding the design. See `#hazard_scale`.
    HAZARD_SCALE = (0.0..4.0)

    # Everything a node is allowed to see. Note the absence of a clock: `dt` is simulated
    # seconds, handed in, never measured.
    #
    # `nodes` and `states` are the PREVIOUS tick's, frozen. Reading another node's last-known
    # condition cannot break order-independence, because tick N-1 is settled and identical for
    # everyone. It is not a licence to reach anywhere: structural relationships are declared
    # (`drives:`, `exhausts_to:`, a link), so what depends on what stays visible.
    Context = Struct.new(:controls, :dt, :tick, :content, :nodes, :states,
                         keyword_init: true) do
      def node_omega(id) = ask(id, :omega)

      # What a shaft has stored, which is what decides whether it can force a stalling machine
      # through. A locked cylinder is not destroyed by *speed* — it is destroyed by a driveline
      # with enough energy to drive the piston into an incompressible charge instead of stopping
      # against it. See `Cylinder#overload?`.
      def node_kinetic_joules(id) = ask(id, :kinetic_joules)

      def node_pressure(id) = ask(id, :pressure_pa, content)

      def node_temperature(id) = ask(id, :temperature_k, content)

      def node_state(id) = states[id]

      # Any other derived quantity, for a node that has **declared** what it is watching.
      # `ReliefValve#senses` is the case this exists for: a safety device does not always
      # protect against the plain vessel pressure — a cylinder is destroyed by the pressure at
      # top dead centre, which no node's `pressure_pa` reports. The declaration is what keeps
      # this from being a licence to reach anywhere.
      def node_reading(id, quantity) = ask(id, quantity, content)

      private

      # nil when the node does not exist or cannot answer, so a caller can fall back without
      # having to know the graph. Every one of these reads the PREVIOUS tick.
      def ask(id, quantity, *extra)
        node = nodes[id]
        return nil unless node.respond_to?(quantity)

        node.public_send(quantity, states.fetch(id), *extra)
      end
    end

    attr_reader :state, :nodes, :links, :paths, :thermal_links, :drive_links, :control_points,
                :diagnostics, :minions, :content, :rngs

    def initialize(operation, state)
      @state = state
      @nodes = operation.nodes
      @links = operation.links
      @paths = operation.paths
      @thermal_links = operation.thermal_links
      @drive_links = operation.drive_links
      @control_points = operation.control_points
      @diagnostics = operation.diagnostics
      @minions = operation.minions
      @content = operation.content
      @rngs = operation.rngs
    end

    # Returns the next state. The operation installs it; nothing is mutated here.
    def call(tick:, dt:)
      controls = actuate(dt)                                    # phase 0
      read = state.fetch(:nodes)                                # phase 1
      ctx = Context.new(controls: control_values(controls), dt:, tick:, content: content,
                        nodes: nodes, states: read)

      intents = nodes.to_h { |id, node| [ id, node.plan(read.fetch(id), ctx) ] }  # phase 2

      settlement = Arbiter.settle(                              # phase 3
        nodes: nodes, states: read, paths: paths, thermal_links: thermal_links,
        drive_links: drive_links, intents:, content: content, dt:, ctx: ctx
      )

      next_nodes, delivered = advect(read, settlement.flows)      # phase 4a
      next_nodes = conduct(next_nodes, settlement.heat)          # phase 4b
      next_nodes, ledger = shed_to_ambient(next_nodes, settlement.ambient)         # phase 4c
      next_nodes, ledger = drive(next_nodes, read, settlement.drive, ledger, ctx)  # phase 4d
      next_nodes, events = apply_nodes(next_nodes, settlement.flows, delivered, ctx)
      next_nodes = transmit_torque(next_nodes, ctx)              # phase 4e
      next_nodes = react(next_nodes, ctx)                        # phase 5
      ledger = record_injections(ledger, next_nodes)
      next_nodes, ledger, wear_events = stress(next_nodes, ledger, ctx)  # phase 6
      next_minions, hurt_events = endanger(wear_events, ctx)     # phase 6b
      next_minions, spent_events = tire(next_minions, controls, ctx)     # phase 6c
      next_diagnostics = observe(next_nodes, ctx)                # phase 7

      # Phase 8. Note that this hash IS the next state — a key not named here is silently
      # dropped, so anything added to state must also be added here even when no phase
      # touches it.
      { nodes: next_nodes.freeze,
        controls: controls.freeze,
        diagnostics: next_diagnostics.freeze,
        minions: next_minions.freeze,
        ledger: ledger.freeze,
        events: (events + wear_events + hurt_events + spent_events).freeze }.freeze
    end

    private

    def actuate(dt)
      state.fetch(:controls).to_h do |id, cp_state|
        [ id, control_points.fetch(id)
                .actuate(cp_state, dt: dt, rate_multiplier: crew_multiplier(id)).freeze ]
      end
    end

    # Who is stood at this lever, and how fast they can work it.
    #
    # Read from STATE rather than configuration, because a station is assignable: a minion who
    # has been moved is at the post their state names, not the one they were built with.
    def crew_multiplier(control_point_id)
      minion_id = station_index[control_point_id]
      # TODO: expedient — an unmanned lever moves at full rate. It should almost certainly not
      # move at all, but every steam engine lever is frictionless today and discards this
      # multiplier entirely, so making it 0.0 now would be an untested change to a value
      # nothing reads. A proper implementation decides what an unattended control does, which
      # is a game-design question rather than a mechanical one.
      return 1.0 unless minion_id

      minions.fetch(minion_id)
             .rate_multiplier(state.fetch(:minions).fetch(minion_id), content)
    end

    # TODO: expedient — last writer wins if two minions share a station. A proper
    # implementation either refuses the assignment or sums their effort; both need a rule for
    # what a crowd at one lever means, which nothing yet depends on.
    def station_index
      @station_index ||= state.fetch(:minions).each_with_object({}) { |(id, minion_state), acc|
        station = minion_state[:station]
        acc[station] = id if station
      }.freeze
    end

    # What a node actually reads off a lever. For a **valve** that is its position: a regulator
    # goes where you put it. For an **effort** station it is the position scaled by what the
    # person standing there can manage, because stoking is not a setting — it is somebody
    # shovelling, and the lever is their instruction to do it as hard as they can.
    #
    # **Nobody posted means nothing gets done.** An unmanned shovel moves no coal.
    def control_values(controls)
      controls.to_h do |id, s|
        control = control_points.fetch(id)
        [ id, control.effort? ? worked(control, s) : control.value(s) ]
      end.freeze
    end

    # Read from the PREVIOUS tick's minion state, so who is standing where cannot depend on
    # phase order. A minion carried out has `station: nil` and therefore mans nothing.
    def worked(control, control_state)
      minion_id = station_index[control.id]
      return 0.0 if minion_id.nil?

      minion = minions[minion_id] or return 0.0
      control.value(control_state) *
        minion.capability(state.fetch(:minions).fetch(minion_id),
                          effort: control.effort, aided_by: control.aided_by)
    end

    # Phase 4a. Granted parcels move, carrying their energy with them. Ungranted mass stays
    # where it was — that is back-pressure, and why nothing is ever silently destroyed.
    #
    # Material crosses a whole PATH in one tick: out of one holder, through however many
    # conduits, into the next. A conduit stops nothing but it does touch what passes, so the
    # stream is walked through each wall in turn.
    #
    # Returns `[next_states, delivered]`, where `delivered` is what actually ARRIVED at each
    # inlet, after the walls took their share. **That is not what the source dispatched**: the
    # stream gives up energy to every conduit it crosses, so reporting dispatched parcels as
    # received credits the sink with energy still in the pipe.
    def advect(read, flows)
      removals  = Hash.new { |h, k| h[k] = [] }
      additions = Hash.new { |h, k| h[k] = [] }
      delivered = Hash.new { |h, k| h[k] = Hash.new { |i, j| i[j] = [] } }
      walls = {}
      # **What each conduit actually passed this tick, by mass AND by volume.** A conduit is
      # resolved *through*, so it is never a flow's endpoint and its `Grant` is empty — it has
      # no other way to learn its own throughput. A driven fitting needs it: hydraulic power is
      # `ΔP × Q` with Q volumetric, and a pump against a shut valve has to cost its shaft
      # nothing.
      #
      # Volume as well as mass because both are wanted and neither can be recovered from the
      # other here: `carry_through` drops `:parcels` from the wall state, so a conduit cannot
      # look up what it was carrying after the fact.
      #
      # Summed across flows, because several paths may cross one wall in a tick, and written to
      # **every** conduit below including the untouched ones — a stale figure from last tick
      # would keep charging a shaft for a flow that has stopped.
      carried_kg = Hash.new(0.0)
      carried_m3 = Hash.new(0.0)

      flows.each do |flow|
        next if flow.parcels.empty?

        removals[flow.source_node].concat(flow.parcels)

        carried = flow.parcels
        # `flow.conduits`, not `path.conduits` — a reversed flow crosses the same walls in the
        # opposite order, and on a multi-conduit line that decides which wall sees the stream
        # while it is still hot.
        flow.conduits.each do |conduit_id|
          carried_kg[conduit_id] += Parcel.total_kg(carried)
          carried_m3[conduit_id] += Parcel.total_volume(carried, content)
          carried, walls[conduit_id] =
            carry_through(nodes.fetch(conduit_id), walls[conduit_id] || read.fetch(conduit_id), carried)
        end

        additions[flow.sink_node].concat(carried)
        delivered[flow.sink_node][flow.sink_port].concat(carried)
      end

      next_states = read.to_h do |id, state|
        state = walls.fetch(id, state)
        node = nodes.fetch(id)
        if node.transport?
          state = state.merge(carried_kg: carried_kg[id], carried_m3: carried_m3[id])
        end
        next [ id, state ] unless state.key?(:parcels)

        held = Parcel.subtract(state.fetch(:parcels), removals[id])
        held = Parcel.normalise(held + additions[id])
        [ id, node.rebalance(state.merge(parcels: held), content) ]
      end

      [ next_states, delivered ]
    end

    # A conduit holds nothing, but it is still metal the stream is in contact with. Mixing the
    # two to one temperature is the same lumped-body rule every other node obeys — a conduit has
    # no *residence*, but it does have thermal contact. Without this a chimney would not cool its
    # flue gas and a conduit could never rupture from over-temperature.
    #
    # `rebalance` only redistributes, so energy is conserved exactly. The `:parcels` key is
    # dropped again, so nothing is ever left behind in a conduit.
    def carry_through(conduit, wall_state, parcels)
      mixed = conduit.rebalance(wall_state.merge(parcels: parcels), content)
      [ mixed.fetch(:parcels), mixed.reject { |key, _| key == :parcels }.freeze ]
    end

    # Phase 4b. Granted heat is deposited. Accumulated per node first so a node touched by
    # several links rebalances once rather than once per link.
    def conduct(states, heat)
      return states if heat.empty?

      net = Hash.new(0.0)
      thermal_links.each do |link|
        q = heat.fetch(link.id, 0.0)
        net[link.a] -= q
        net[link.b] += q
      end

      deposit(states, net)
    end

    # Phase 4c. Waste heat leaves for the environment and is written to the ledger. This is
    # what stops a long chain being a perfect heat accumulator.
    def shed_to_ambient(states, ambient)
      return [ states, state.fetch(:ledger) ] if ambient.empty?

      shed = ambient.values.sum
      [ deposit(states, ambient.transform_values(&:-@)),
        Ledger.add(state.fetch(:ledger), joules_to_ambient: shed) ]
    end

    # Phase 4d. Angular momentum crosses the drivetrain, then bearing drag takes its cut.
    #
    # Momentum is conserved to the bit; kinetic energy deliberately is not. A slipping belt
    # loses energy and that loss is real — so the difference is measured before and after
    # and written to the ledger as friction heat rather than being allowed to evaporate.
    # Without that, "energy conserved" would quietly stop being a checkable statement the
    # moment anything started spinning.
    def drive(states, read, transfers, ledger, ctx)
      return [ states, ledger ] if drive_links.empty? && rotating_ids.empty?

      before = rotating_kinetic_joules(read)

      net = Hash.new(0.0)
      drive_links.each do |link|
        delta = transfers.fetch(link.id, 0.0)
        net[link.a] -= delta
        net[link.b] += delta
      end
      rotating_ids.each { |id| net[id] -= transfers.fetch(:"#{id}=ground", 0.0) }

      spun = states.to_h do |id, state|
        next [ id, state ] if net[id].zero?

        [ id, nodes.fetch(id).add_angular_momentum(state, net[id]) ]
      end

      book_drive(spun, before - rotating_kinetic_joules(spun), transfers, ledger, ctx)
    end

    # What the drivetrain lost, split between work taken out and heat.
    #
    # **The total is measured and the split is estimated, never the other way round.** Kinetic
    # energy is quadratic, so no intermediate state between two settled ticks means anything:
    # applying the couplings first and measuring, then the drags, charges each for a state the
    # machine was never in — it inflated a mill's output past its own engine's and drove
    # `joules_to_friction` negative.
    #
    # So each term is estimated at the speed the network **settled** to, which is what backward
    # Euler says the step was taken at: a drag did `momentum × ω`, a coupling dissipated
    # `transferred × Δω`. Those are proportions; the measured total is then divided by them, so
    # the books close exactly whatever the estimates are worth.
    def book_drive(states, lost, transfers, ledger, ctx)
      estimates = drag_estimates(states, transfers, ctx)
      total = estimates.values.sum + slip_estimate(states, transfers)
      scale = total.positive? ? lost / total : 0.0

      # Work leaves through `joules_extracted`, which `record_injections` already sums — a load
      # reports its own extraction exactly as an injector reports its own.
      booked = states.to_h do |id, state|
        next [ id, state ] unless rotating_ids.include?(id)

        [ id, state.merge(joules_extracted: estimates.fetch([ id, :work ], 0.0) * scale) ]
      end

      # **A drag that names a node heats that node**, so its energy never leaves the system and
      # never reaches the ledger. That is what makes a bearing able to run hot.
      kept = 0.0
      estimates.each do |(_, into), estimate|
        next if %i[work friction].include?(into)

        joules = estimate * scale
        kept += joules
        booked[into] = nodes.fetch(into).add_joules(booked.fetch(into), joules, ctx.content)
      end

      taken = booked.sum { |id, s| rotating_ids.include?(id) ? s.fetch(:joules_extracted, 0.0) : 0.0 }
      friction = lost - taken - kept
      return [ booked, ledger ] if friction.abs <= Parcel::EPSILON

      [ booked, Ledger.add(ledger, joules_to_friction: friction) ]
    end

    # `momentum × ω` per `[shaft, destination]`. Every drag on one shaft shares its settled
    # speed, so the momentum each removed is exactly proportional to its conductance — and the
    # destination is whatever declared it: `:work` out of the machine, `:friction` off the
    # books, a node id into that node's metal.
    def drag_estimates(states, transfers, ctx)
      drag_shares(states, ctx).each_with_object(Hash.new(0.0)) do |(shaft, shares), acc|
        removed = transfers.fetch(:"#{shaft}=ground", 0.0)
        total = shares.values.sum
        next if removed.zero? || !total.positive?

        carried = removed * nodes.fetch(shaft).omega(states.fetch(shaft))
        shares.each { |into, conductance| acc[[ shaft, into ]] += carried * (conductance / total) }
      end
    end

    # Everything dragging on each shaft, gathered from whoever declared it. A shaft's own windage
    # and the bearings carrying it all land on the same row.
    def drag_shares(states, ctx)
      nodes.each_with_object({}) do |(id, node), acc|
        next unless node.respond_to?(:drag_conductances)

        declared = node.drag_conductances(states.fetch(id), ctx)
        next if declared.empty?

        into = acc[node.drag_shaft] ||= Hash.new(0.0)
        declared.each { |destination, conductance| into[destination] += conductance }
      end
    end

    # `transferred × Δω` across every coupling — the classic slip loss, and never negative.
    def slip_estimate(states, transfers)
      drive_links.sum do |link|
        delta = transfers.fetch(link.id, 0.0)
        next 0.0 if delta.zero?

        gap = nodes.fetch(link.a).omega(states.fetch(link.a)) -
              nodes.fetch(link.b).omega(states.fetch(link.b))
        (delta * gap).abs
      end
    end

    # Phase 4e. A prime mover — a cylinder, a turbine — declares the torque it is exerting
    # on the shaft it drives. Here that impulse is applied and PAID FOR, exactly.
    #
    # The shaft's kinetic energy gain from an impulse is `ω·ΔL + ΔL²/2I`; billing the driver
    # the first-order `torque × ω × dt` alone would quietly manufacture the second term.
    # Invisible at small timesteps and very visible at `time_scale` 100 — so the gain is
    # measured rather than predicted, and the driver's charge loses precisely that.
    #
    # **Applied after the drivetrain settles rather than inside it**, which is an operator split
    # and leaves a residue: the shaft sheds 11% of its speed in 4d and regains it here, every
    # tick, and `indicated_power_w` therefore reads `ΔL²/2I` — about 5% — high. It is benign
    # because a prime mover is a near-constant *source* where a brake is stiff feedback, and
    # splitting a source is first order with a small constant. **The lever, if it ever matters,
    # is written up in `docs/design_sketches/bearings.md` §6.4**: `Relaxation.settle` already
    # takes current sources on its right-hand side, so the impulse could be solved with the
    # network and this method reduced to its billing.
    def transmit_torque(states, ctx)
      drivers = nodes.select { |_, n| n.respond_to?(:drives) && n.respond_to?(:extractable_joules) }
      return states if drivers.empty?

      drivers.reduce(states) do |acc, (id, driver)|
        torque = acc.fetch(id).fetch(:torque, 0.0)
        next acc if torque.abs <= Parcel::EPSILON

        shaft = nodes[driver.drives]
        next acc unless shaft.respond_to?(:omega)
        # Nothing drives a wheel that has come apart. The driver keeps its computed torque —
        # a cylinder still has pressure across its piston — but there is no longer anything
        # on the other end of the crank for it to do work on.
        next acc if acc.fetch(driver.drives)[:failure]

        before = shaft.kinetic_joules(acc.fetch(driver.drives))
        spun = shaft.apply_torque(acc.fetch(driver.drives), torque, ctx.dt)
        work = shaft.kinetic_joules(spun) - before

        # A cylinder cannot deliver more than its charge holds. If it is starved, scale the
        # impulse back rather than letting the shaft accelerate on borrowed energy.
        budget = driver.extractable_joules(acc.fetch(id))
        if work > budget
          scale = budget / work
          spun = shaft.apply_torque(acc.fetch(driver.drives), torque * scale, ctx.dt)
          work = shaft.kinetic_joules(spun) - before
        end

        # `work_joules` is what the shaft actually gained; `shaft_power_w` is the same figure as
        # a rate, so an instrument need not know the timestep.
        #
        # **This is not the driver's `indicated_power_w`, and an instrument must not use that
        # one.** A prime mover computes torque from a cycle that knows only pressures; the budget
        # above is what its charge could actually pay for. The two are anti-correlated where they
        # disagree — 566 kW at 167 rpm against 479 kW at 187 rpm — so the diagram reading falls
        # as the engine speeds up. This figure is the honest one.
        # **A prime mover may carry its own rotor**, and then `id == driver.drives` — a donkey
        # engine is one lump of machinery, not an engine belted to a separate flywheel. Merging
        # two entries under one key would silently drop the spin, so the charge is folded into
        # the spun state instead of written beside it.
        charged = driver.add_joules(id == driver.drives ? spun : acc.fetch(id), -work,
                                    ctx.content)
                        .merge(work_joules: work, shaft_power_w: work / ctx.dt).freeze
        next acc.merge(id => charged) if id == driver.drives

        acc.merge(driver.drives => spun.freeze, id => charged)
      end
    end

    def rotating_ids
      @rotating_ids ||= nodes.select { |_, n| n.respond_to?(:omega) }.keys.freeze
    end

    def rotating_kinetic_joules(states)
      rotating_ids.sum { |id| nodes.fetch(id).kinetic_joules(states.fetch(id)) }
    end

    def deposit(states, net)
      states.to_h do |id, state|
        q = net[id] || 0.0
        next [ id, state ] if q.abs <= Parcel::EPSILON

        [ id, nodes.fetch(id).add_joules(state, q, content) ]
      end
    end

    # Node-specific effects, given what settlement actually granted. The parcel bookkeeping
    # is already done, so a node only implements what makes it that node.
    def apply_nodes(states, flows, delivered, ctx)
      grants = grants_from(flows, delivered)
      events = []

      next_states = states.to_h do |id, state|
        result = nodes.fetch(id).apply(state, ctx, grants.fetch(id, Grant.none))
        next_state, node_events = result.is_a?(Array) ? result : [ result, [] ]
        events.concat(node_events)
        [ id, next_state.freeze ]
      end

      [ next_states, events ]
    end

    # Anything a node injected this tick — a burner, a heater, fission — goes on the books
    # as an input. Nodes report it in their own state rather than reaching for the ledger,
    # so `apply` stays a pure state transform.
    def record_injections(ledger, states)
      joules = states.values.sum { |s| s.fetch(:joules_injected, 0.0) }
      mass   = states.values.sum { |s| s.fetch(:mass_injected, 0.0) }
      work   = states.values.sum { |s| s.fetch(:joules_extracted, 0.0) }
      burnt  = states.values.sum { |s| s.fetch(:joules_from_reactions, 0.0) }
      vented = states.values.sum { |s| s.fetch(:mass_vented, 0.0) }
      spilled = states.values.sum { |s| s.fetch(:mass_spilled, 0.0) }
      consumed = states.values.sum { |s| s.fetch(:mass_consumed, 0.0) }
      delivered = states.values.sum { |s| s.fetch(:mass_delivered, 0.0) }
      dumped = states.values.sum { |s| s.fetch(:joules_discarded, 0.0) }
      totals = [ joules, mass, work, vented, spilled, consumed, delivered, dumped, burnt ]
      return ledger if totals.all?(&:zero?)

      Ledger.add(ledger, joules_added: joules, mass_added: mass, joules_to_work: work,
                         mass_vented: vented, mass_spilled: spilled, mass_consumed: consumed,
                         mass_delivered: delivered,
                         joules_advected_out: dumped, joules_from_reactions: burnt)
    end

    # `delivered` comes from advection because only advection knows what survived the walls;
    # `sent` and `rejected` come from the flows, because those are what left and what could
    # not. Taking both from the flows credited a sink with energy still sitting in the pipe.
    def grants_from(flows, delivered)
      sent     = Hash.new { |h, k| h[k] = Hash.new { |i, j| i[j] = [] } }
      rejected = Hash.new { |h, k| h[k] = Hash.new(0.0) }

      flows.each do |flow|
        # The parcels themselves, not just their mass: a node that ships material also ships
        # its enthalpy, and the boundary nodes have to declare both.
        sent[flow.source_node][flow.source_port].concat(flow.parcels)
        rejected[flow.source_node][flow.source_port] += flow.rejected_kg
      end

      nodes.keys.to_h do |id|
        [ id, Grant.new(received: delivered[id].transform_values { |ps| Parcel.normalise(ps) },
                        sent: sent[id].transform_values { |ps| Parcel.normalise(ps) },
                        rejected: rejected[id]) ]
      end
    end

    # Phase 5. Local to each node — no cross-node effects, so order cannot matter.
    # Chemistry advances at a rate; phase change snaps to equilibrium.
    def react(states, ctx)
      states.to_h do |id, state|
        node = nodes.fetch(id)
        next [ id, state ] unless state.key?(:parcels) && !state.fetch(:parcels).empty?

        state = run_reactions(node, state, ctx)
        state = run_phase_change(node, state, ctx)
        [ id, node.rebalance(state, content).freeze ]
      end
    end

    def run_reactions(node, state, ctx)
      state = state.merge(joules_from_reactions: 0.0)

      node.reactions.reduce(state) do |acc, reaction_id|
        spec = content.reaction(reaction_id)
        acc = advance_ignition(spec, reaction_id, node, acc, ctx)

        # A bed choked with its own ash reacts more slowly, because the air can no longer reach
        # what is left to burn. Applied to `dt` so the closed form stays a closed form and
        # stays exact — a reaction that gets a shorter effective second is the same reaction.
        parcels, released = Resources::Reaction.advance(
          spec, acc.fetch(:parcels),
          temperature_k: node.temperature_k(acc, content),
          dt: ctx.dt * node.reaction_throttle(acc, content), content: content,
          ignited_fuel_kg: ignited_fuel_kg(spec, reaction_id, acc)
        )
        next acc if released.zero? && parcels.equal?(acc.fetch(:parcels))

        acc = burn_down_ignition(spec, reaction_id, acc, parcels)

        # Recorded as well as applied. Combustion is the largest single energy input in the
        # game and it must not arrive silently.
        node.rebalance(acc.merge(parcels: parcels,
                                 joules: acc.fetch(:joules) + released,
                                 joules_from_reactions: acc.fetch(:joules_from_reactions, 0.0) + released),
                       content)
      end
    end

    # How much of this reaction's fuel is alight, after spread, quenching and whatever the
    # igniter managed to seed this tick.
    #
    # Runs BEFORE the reaction, so the heat released this tick reflects the fire as it is now
    # rather than as it was a tick ago. Reactions that do not model ignition are left alone —
    # their state key stays at zero and Reaction.advance keeps its own temperature gate.
    def advance_ignition(spec, reaction_id, node, state, ctx)
      return state unless Resources::Ignition.modelled?(spec)

      advanced = Resources::Ignition.advance(
        spec, ignition_for(state, reaction_id), state.fetch(:parcels),
        temperature_k: node.temperature_k(state, content), dt: ctx.dt, content: content,
        # Set by the node in phase 4 — a pilot light, an arc, a match. Consumed here rather
        # than added by the node itself, for the same reason `joules_injected` is: a node
        # records what it did and the tick decides what that means.
        seed_kg: state.fetch(:ignition_seed_kg, 0.0)
      )

      with_ignition(state, reaction_id, advanced)
    end

    # Kilograms of fuel alight, or nil for a reaction that does not model ignition — which is
    # what tells Reaction.advance to keep its own bulk-temperature gate.
    def ignited_fuel_kg(spec, reaction_id, state)
      return nil unless Resources::Ignition.modelled?(spec)

      ignition_for(state, reaction_id).fetch(:kg, 0.0)
    end

    def ignition_for(state, reaction_id)
      state.fetch(:ignition, {}).fetch(reaction_id, nil) || Resources::Ignition.initial_state
    end

    # Fuel that burned away shrinks the fire in PROPORTION, not one kilogram for one.
    #
    # Subtracting the burnt mass outright says that burning unlights the rest of the fire,
    # which is backwards — a flame front consuming a lump moves on to the next one. It also
    # made ignition impossible: at `rate_per_s: 6.0` a small ember is fuel-limited and burns
    # away inside a tick, so every seed the igniter laid was eaten before it could spread, and
    # the fire could never establish however long the match was held to it.
    #
    # Scaling by what remains keeps the lit FRACTION across a burn, and still takes the fire to
    # zero as the last of the fuel goes.
    def burn_down_ignition(spec, reaction_id, state, next_parcels)
      return state unless Resources::Ignition.modelled?(spec)

      before = Resources::Ignition.fuel_mass(spec, state.fetch(:parcels), content)
      after = Resources::Ignition.fuel_mass(spec, next_parcels, content)
      return state unless before.positive? && after < before

      ignition = ignition_for(state, reaction_id)
      with_ignition(state, reaction_id,
                    ignition.merge(kg: ignition.fetch(:kg, 0.0) * (after / before)))
    end

    def with_ignition(state, reaction_id, ignition)
      state.merge(
        ignition: state.fetch(:ignition, {}).merge(reaction_id => ignition.freeze).freeze
      )
    end

    # Phase change is solved against the volume it actually happens in, so pressure and the
    # liquid/vapour split come out self-consistent. Solving them in sequence oscillates —
    # see the note on Saturation.solve.
    #
    # A node with no volume (nothing that Holds) cannot boil, which is correct: there is
    # nowhere for the vapour to be.
    def run_phase_change(node, state, ctx)
      return state unless node.respond_to?(:volume_m3)

      pairs = state.fetch(:parcels).filter_map { |p| content.phase_pair(p.fetch(:resource)) }.uniq

      pairs.reduce(state) do |acc, (liquid, vapour)|
        parcels, _pressure = Resources::Saturation.solve(
          liquid, vapour, acc.fetch(:parcels),
          volume_m3: node.volume_m3, content: ctx.content
        )
        acc.merge(parcels: parcels)
      end
    end

    # Phase 6. Durability depletes from operating conditions; a node fails when it hits
    # zero. Never a per-tick dice roll — the player must be able to learn "I ran it too hot
    # for too long" rather than being told the dice disliked them.
    def stress(states, ledger, ctx)
      events = []
      before = rotating_kinetic_joules(states)

      next_states = states.to_h do |id, state|
        node = nodes.fetch(id)
        next [ id, state ] unless node.respond_to?(:apply_wear)

        worn, node_events = node.apply_wear(state, ctx)
        events.concat(node_events)
        # **A part that has let go stops being a machine.** A burst flywheel is not a
        # flywheel spinning with a failure recorded against it — it is scrap, and it does not
        # keep turning. `Wearing` set the flag and nothing anywhere acted on it, so a wheel
        # that burst at 400.8 rpm against a 321.6 limit was doing **2364.7 rpm and 3.97 MW**
        # six hundred ticks later.
        worn = worn.merge(angular_momentum: 0.0) if worn[:failure] && worn.key?(:angular_momentum)
        [ id, worn.freeze ]
      end

      next_states = spread_damage(next_states, events)

      # The energy that wheel was carrying went into wrecking the shop. Ledgered rather than
      # dropped, for the same reason belt slip is: an explicit line nobody can miss beats a
      # silent hole, and this one is large — a flywheel at its burst speed holds megajoules.
      wrecked = before - rotating_kinetic_joules(next_states)
      ledger = Ledger.add(ledger, joules_to_friction: wrecked) if wrecked.abs > Parcel::EPSILON

      [ next_states, ledger, events ]
    end

    # What a part breaking does to the parts around it.
    #
    # **Structural energy is fiat, deliberately.** Modelling the release properly would be a
    # whole physics for one narrative beat, and would need a notion of *place* before it could
    # name a neighbour. So a mode names what it damages and by how much, and this spends that as
    # durability. Nothing is created, so conservation holds by construction rather than by a
    # clamp: damage is a durability write, never a joule.
    #
    # Applied after every node's wear is settled, never inside the map, so two parts failing on
    # one tick and damaging each other give the same answer whatever order they are visited in.
    # See `docs/design_sketches/failure_model.md` §6.
    def spread_damage(states, events)
      harm = Hash.new(0.0)
      events.each do |event|
        node = nodes[event[:node]]
        next unless node.respond_to?(:failure_damages)

        (node.failure_damages[event[:mode]] || {}).each { |id, share| harm[id] += share }
      end
      return states if harm.empty?

      states.merge(harm.filter_map { |id, share| damaged(states, id, share) }.to_h)
    end

    # Phase 6b. What a failure does to the people near it — the other half of `spread_damage`.
    #
    # **No entropy here.** A minion's `resilience` was rolled at `initial_state`, so the Danger
    # Check is a deterministic comparison and injuries replay exactly. See `Injury`.
    #
    # Runs after all wear is settled, never inside it, so two parts failing on one tick hurt the
    # same people whatever order they were visited in.
    def endanger(wear_events, ctx)
      minions_state = state.fetch(:minions)
      exposure = hazards_from(wear_events)
      return [ minions_state, [] ] if exposure.empty?

      events = []
      next_states = minions_state.to_h do |id, minion_state|
        minion = minions[id]
        # A station is where somebody IS, so it comes from state rather than config — a minion
        # who has been reassigned is standing somewhere else, and one already carried out is
        # standing nowhere and cannot be hurt again by the same blast.
        hazard = exposure[minion_state[:station]]
        next [ id, minion_state ] if minion.nil? || hazard.nil?

        hurt, mode = Injury.check(minion, minion_state, hazard)
        events << hurt_event(minion, hurt, mode, hazard, ctx) if mode
        [ id, hurt.freeze ]
      end

      [ next_states, events ]
    end

    # Phase 6c. What the work does to the people doing it.
    #
    # **Runs after `endanger`, not at phase 0.** Three reasons, and the third is the one that
    # bites: the effort actually demanded this tick is settled at phase 1, so accruing at phase 0
    # charges people for last tick's levers; `endanger` already writes `minions`, and a second
    # writer would need a merge rule between them; and a minion carried out in 6b has
    # `station: nil` on this tick and must stop working on this tick, not the next one.
    #
    # Reads the post-injury state deliberately — a hurt fireman is a worse fireman, so the same
    # lever costs them more from the moment they are hurt.
    #
    # **No entropy**, exactly as the Danger Check draws none, so a tired minion replays exactly.
    def tire(minions_state, controls, ctx)
      events = []

      next_states = minions_state.to_h do |id, minion_state|
        minion = minions[id]
        next [ id, minion_state ] if minion.nil?

        control = control_points[minion_state[:station]]
        demand = control ? control.demand(controls.fetch(control.id)) : 0.0

        tired = Fatigue.advance(minion, minion_state, control: control, demand: demand, dt: ctx.dt)
        tired, spent = Fatigue.check_spent(tired)
        events << spent_event(minion, control, ctx) if spent
        [ id, tired.freeze ]
      end

      [ next_states, events ]
    end

    # The person and the post, the same split `hurt_event` makes: the post outlives whoever was
    # standing at it, and a consumer given only the job could not say who needs a rest.
    def spent_event(minion, control, ctx)
      Event.build(type: :minion_spent, node: minion.id, label: minion.name,
                  severity: :warning, tick: ctx.tick,
                  detail: { minion: minion.minion, station: control&.id })
    end

    # Severity ADDS where two failures endanger one station on the same tick, because two things
    # letting go beside somebody is worse than either. Tags union, so gear that resists one of
    # them still helps.
    def hazards_from(wear_events)
      wear_events.each_with_object({}) do |event, acc|
        node = nodes[event[:node]]
        next unless node.respond_to?(:failure_hazards)

        declared = node.failure_hazards[event[:mode]] or next
        scale = hazard_scale(declared, event)

        (declared[:stations] || {}).each do |station, weight|
          at = acc[station] ||= { station: station, severity: 0.0, tags: [], sources: [] }
          at[:severity] += weight.to_f * scale
          at[:tags] |= Array(declared[:tags])
          at[:sources] |= [ event[:node] ]
        end
      end
    end

    # **How bad it was, not merely that it happened.** A station's figure is a WEIGHT — how
    # exposed that post is — and the magnitude comes from the part, read off the failure event's
    # own `detail:`.
    #
    # Reading the event rather than the node buys three things: the figure is what the part
    # reported at the instant it failed rather than whatever its state has become since; it needs
    # no cross-node read, so phase 6b stays order-independent by construction; and the magnitude
    # lands on the durable record, so a consumer can see why an injury was as bad as it was.
    #
    # `scales_with:` names a key in that detail and `reference:` is the value at which a
    # station's weight means its face value. A declaration with neither is flat, which is right
    # for most hazards — a linkage snapping is a linkage snapping.
    def hazard_scale(declared, event)
      key = declared[:scales_with] or return 1.0

      reference = declared[:reference].to_f
      return 1.0 unless reference.positive?

      magnitude = event.dig(:detail, key)
      # A part that declared a scale and then reported nothing is a wiring mistake, but it must
      # not silently make the hazard harmless — fall back to the flat figure and let the spec
      # that walks every machine be the thing that catches it.
      return 1.0 if magnitude.nil?

      (magnitude.to_f / reference).clamp(HAZARD_SCALE.begin, HAZARD_SCALE.end)
    end

    # `node:` is the JOB and `minion:` is the person, and both have to be on the record.
    #
    # The job is what a panel labels — "the fireman has been carried out" — and it is the id
    # everything inside the operation is keyed by. But the **injury list belongs to a person**:
    # Jim is out for two matches, and the fireman's job is still there for somebody else to
    # stand in. A consumer given only the role could not write that down.
    def hurt_event(minion, hurt, mode, hazard, ctx)
      Event.build(type: :minion_hurt, node: minion.id, label: minion.name,
                  severity: mode == :minor ? :warning : :critical,
                  tick: ctx.tick, mode: mode,
                  detail: { minion: minion.minion,
                            lasting: Injury.lasting?(mode),
                            station: hazard[:station],
                            by: hazard[:sources],
                            tags: hazard[:tags],
                            resilience_left: hurt.fetch(:resilience).round(3) })
    end

    # A share of what the part started with rather than a flat figure, so the same table entry
    # means the same thing to a light fitting and a heavy one.
    def damaged(states, id, share)
      state = states[id]
      return nil if state.nil? || !state.key?(:durability)

      spent = state.fetch(:initial_durability, 0.0) * share
      [ id, state.merge(durability: [ state.fetch(:durability) - spent, 0.0 ].max).freeze ]
    end

    # Phase 7. Each instrument samples its source and advances its filter chain. The only
    # place diagnostic entropy is drawn — reading is a pure lookup afterwards, so a tick
    # can be projected any number of times without changing the match.
    def observe(node_states, ctx)
      current = state.fetch(:diagnostics)

      diagnostics.to_h do |id, diagnostic|
        [ id, diagnostic.record(current.fetch(id), nodes, node_states, ctx,
                                rngs.fetch(id)).freeze ]
      end
    end
  end
end
