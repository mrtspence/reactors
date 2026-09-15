# frozen_string_literal: true

module ReactorSim
  # One advance of one operation, start to finish.
  #
  # Extracted from Operation because the ORDER of these phases is the most load-bearing and
  # least obvious thing in the engine, and it deserves to be readable in one sitting rather
  # than buried under an object's public API. Operation owns configuration, commands,
  # projection and serialisation; this owns the tick and nothing else.
  #
  # Every phase reads the frozen previous tick and returns new state. Nothing here mutates
  # the operation — `Operation#step!` takes the result and installs it — which is what keeps
  # a half-finished tick from ever being observable.
  #
  #   0 ACTUATE   levers travel toward their targets; all actuation entropy is drawn here
  #   1 READ      freeze tick N-1 and build the context every node will see
  #   2 PLAN      every node declares intent, independently, against N-1
  #   3 SETTLE    one pure function over every claim — mass, heat and momentum alike
  #   4 TRANSFER  a advection  b conduction  c ambient  d drivetrain  e torque
  #   5 REACT     phase change and chemistry, local to each node
  #   6 STRESS    durability, overload, failure events
  #   7 OBSERVE   instruments sample and their filters advance
  #
  # Phase 4's internal order matters: mass moves before heat so a parcel's energy travels
  # with it, and torque is transmitted after node effects so a prime mover has computed the
  # torque before it is charged for it.
  class Tick
    # Everything a node is allowed to see. Note the absence of a clock: `dt` is simulated
    # seconds, handed in, never measured.
    #
    # `nodes` and `states` are the PREVIOUS tick's, frozen. A node may read another node's
    # last-known condition — a cylinder needs its shaft's speed and the pressure it exhausts
    # against — and doing so cannot break order-independence, because tick N-1 is settled
    # and identical for everyone. It is the same rule the whole engine already runs on.
    #
    # This is deliberately not a licence for nodes to reach anywhere. Structural
    # relationships are declared (`drives:`, `exhausts_to:`, a link, a thermal link), so
    # what depends on what stays visible in the operation definition.
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
      next_diagnostics = observe(next_nodes, ctx)                # phase 7

      # Phase 8. Note that this hash IS the next state — a key not named here is silently
      # dropped, so anything added to state must also be added here even when no phase
      # touches it.
      { nodes: next_nodes.freeze,
        controls: controls.freeze,
        diagnostics: next_diagnostics.freeze,
        # Carried through untouched. Nothing advances fatigue or health yet, so there is no
        # minion phase — but leaving this line out would delete the crew on tick 1 and raise
        # on tick 2.
        # TODO: fatigue accrual belongs in phase 0, alongside the actuation entropy it would
        # feed. Deferred because the rate at which a minion tires is a balance decision.
        minions: state.fetch(:minions),
        ledger: ledger.freeze,
        events: (events + wear_events).freeze }.freeze
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

    def control_values(controls)
      controls.to_h { |id, s| [ id, control_points.fetch(id).value(s) ] }.freeze
    end

    # Phase 4a. Granted parcels move, carrying their energy with them. Ungranted mass
    # simply stays where it was — that is back-pressure, and it is why nothing is ever
    # silently destroyed.
    #
    # Material crosses a whole PATH in one tick: out of one holder, through however many
    # conduits, into the next holder. A conduit stops nothing (see `Nodes::Conduit` for what
    # holding it cost us) but it does touch what passes, so the stream is walked through each
    # wall in turn.
    # Returns [next_states, delivered], where `delivered` is `{node => {port => parcels}}` —
    # what actually ARRIVED at each inlet, after the walls have had their share.
    #
    # That distinction is not pedantry. What a sink receives is not what the source dispatched:
    # the stream gives up energy to every conduit it crosses, so flue gas that left the firebox
    # at 700 K reaches the sky cooler, with the difference sitting in the chimney's wall.
    # Reporting the dispatched parcels as "received" quietly credits the sink with energy that
    # is still in the pipe — invisible until `Atmosphere` began ledgering the enthalpy it was
    # handed, at which point the energy books drifted by about 4 kJ a tick.
    def advect(read, flows)
      removals  = Hash.new { |h, k| h[k] = [] }
      additions = Hash.new { |h, k| h[k] = [] }
      delivered = Hash.new { |h, k| h[k] = Hash.new { |i, j| i[j] = [] } }
      walls = {}

      flows.each do |flow|
        next if flow.parcels.empty?

        removals[flow.source_node].concat(flow.parcels)

        carried = flow.parcels
        # `flow.conduits`, not `path.conduits` — a reversed flow crosses the same walls in the
        # opposite order, and on a multi-conduit line that decides which wall sees the stream
        # while it is still hot.
        flow.conduits.each do |conduit_id|
          carried, walls[conduit_id] =
            carry_through(nodes.fetch(conduit_id), walls[conduit_id] || read.fetch(conduit_id), carried)
        end

        additions[flow.sink_node].concat(carried)
        delivered[flow.sink_node][flow.sink_port].concat(carried)
      end

      next_states = read.to_h do |id, state|
        state = walls.fetch(id, state)
        next [ id, state ] unless state.key?(:parcels)

        held = Parcel.subtract(state.fetch(:parcels), removals[id])
        held = Parcel.normalise(held + additions[id])
        [ id, nodes.fetch(id).rebalance(state.merge(parcels: held), content) ]
      end

      [ next_states, delivered ]
    end

    # A conduit holds nothing, but it is still metal that the stream is in contact with.
    # Mixing the two to a single temperature is the same lumped-body rule every other node
    # obeys — we removed the *residence*, not the thermal contact.
    #
    # This is not decoration. Without it a chimney would stop cooling its flue gas, the
    # hotwell would stop cooling condensate, and a conduit could never rupture from
    # over-temperature because its wall would never see anything hot.
    #
    # `rebalance` only redistributes, so energy is conserved exactly. The parcels come back
    # out at the mixed temperature and the wall keeps the rest; the `:parcels` key is dropped
    # again so nothing is ever left behind in a conduit.
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

      spun = states.to_h do |id, state|
        node = nodes.fetch(id)
        next [ id, state ] unless node.respond_to?(:omega)

        state = node.add_angular_momentum(state, net[id]) unless net[id].zero?
        loss = node.friction_loss(state, ctx.dt)
        [ id, loss.zero? ? state : node.add_angular_momentum(state, -loss) ]
      end

      dissipated = before - rotating_kinetic_joules(spun)
      return [ spun, ledger ] if dissipated.abs <= Parcel::EPSILON

      [ spun, Ledger.add(ledger, joules_to_friction: dissipated) ]
    end

    # Phase 4e. A prime mover — a cylinder, a turbine — declares the torque it is exerting
    # on the shaft it drives. Here that impulse is applied and PAID FOR, exactly.
    #
    # The shaft's kinetic energy gain from an impulse is `ω·ΔL + ΔL²/2I`; billing the driver
    # the first-order `torque × ω × dt` alone would quietly manufacture the second term.
    # Invisible at small timesteps and very visible at `time_scale` 100 — so the gain is
    # measured rather than predicted, and the driver's charge loses precisely that.
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
        # a rate, because that is what an instrument wants and dividing by `dt` outside the
        # simulation would need the observer to know the timestep.
        #
        # **This is not the same number as the driver's own `indicated_power_w`, and an
        # instrument must not use that one.** A prime mover computes its torque from a cycle
        # that knows only pressures; the budget above is what its charge could actually pay for.
        # While the two disagree the gauge reading the diagram is not merely optimistic, it is
        # anti-correlated — measured at 566 kW and 167 rpm against 479 kW and 187 rpm, so it
        # fell as the engine sped up. Indicated power is a real and different quantity from
        # shaft power in a real engine; here the gap is a modelling artifact and it is this
        # figure that is honest.
        acc.merge(
          driver.drives => spun.freeze,
          id => driver.add_joules(acc.fetch(id), -work, ctx.content)
                      .merge(work_joules: work, shaft_power_w: work / ctx.dt).freeze
        )
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
      dumped = states.values.sum { |s| s.fetch(:joules_discarded, 0.0) }
      return ledger if [ joules, mass, work, vented, spilled, dumped, burnt ].all?(&:zero?)

      Ledger.add(ledger, joules_added: joules, mass_added: mass, joules_to_work: work,
                         mass_vented: vented, mass_spilled: spilled,
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
    # **Structural energy is fiat here, deliberately.** A bursting drum throws its shell at the
    # shop, and that matters in exactly two places — it breaks adjacent machinery and it injures
    # nearby crew. Modelling the release properly would be a whole physics for one narrative
    # beat, and it would need a notion of *place* before it could even name a neighbour. So a
    # mode names what it damages and by how much, and this spends that as durability.
    #
    # **Nothing is created, so conservation is untouched by construction** rather than by a
    # clamp: damage is a durability write, never a joule. See
    # docs/design_sketches/failure_model.md §6.
    #
    # Applied after every node's wear is settled, never inside the map, so two parts failing on
    # the same tick and damaging each other give the same answer whatever order they are
    # visited in. Phase 6 has to obey order-independence like everything else.
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
