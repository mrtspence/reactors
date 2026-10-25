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
  #   6 STRESS    a durability, overload, failure events
  #              b endanger — what a failure does to the people near it
  #              c tire     — what the work does to the people doing it
  #              d travel   — where the people have got to
  #   7 OBSERVE   instruments sample and their filters advance
  #
  # Phase 4's internal order matters: mass moves before heat so a parcel's energy travels with
  # it, and torque is transmitted after node effects so a prime mover has computed the torque
  # before it is charged for it.
  class Tick
    # Bounds a hazard scaled by a runaway figure. Four times the reference of anything meant to kill
    # is already far past `Injury::MORTAL_BITE`, so this bounds a bug without bounding the design.
    # See `#hazard_scale`.
    HAZARD_SCALE = (0.0..4.0)

    # Everything a node is allowed to see. Note the absence of a clock: `dt` is simulated
    # seconds, handed in, never measured.
    #
    # `nodes` and `states` are the PREVIOUS tick's, frozen. Reading another node's last-known
    # condition cannot break order-independence, because tick N-1 is settled and identical for
    # everyone. It is not a licence to reach anywhere: structural relationships are declared
    # (`drives:`, `exhausts_to:`, a link), so what depends on what stays visible.
    NO_SLIP = { slip: nil, slip_at: nil, slip_for: nil }.freeze

    # **A slip lasts seconds, not a tick.** At a quarter-second tick a single reversed step is
    # a rounding error nobody could see; held for a few seconds the lever visibly walks the
    # wrong way and the player swears and re-commands, which is the whole mechanic.
    SLIP_TICKS = 12

    # Freeze, reverse, or grab the wrong lever entirely. The first two are legible in `actual`
    # diverging from `target`, which the panel already draws; the third is the funniest and
    # only became possible with the spatial model, because "which other lever could they have
    # grabbed" is a question about where they are standing.
    SLIPS = %i[freeze reverse wrong_lever].freeze

    # Below this share of its rated speed, whatever drives a ridden way is not driving it.
    DRIVEN_IN_SERVICE = 0.1

    Context = Struct.new(:controls, :dt, :tick, :content, :nodes, :states, :ignition, :cargo,
                         :outdoors, :exposure, keyword_init: true) do
      def node_omega(id) = ask(id, :omega)

      # **The sky, as of last tick** — every channel in `Conditions::STANDARD` plus the ground's.
      # The standard sky where an operation has no outdoors node.
      def sky = outdoors || Conditions::STANDARD

      # How far the outdoor temperature is from the standard day a node's ambient was declared
      # against, K.
      def outdoor_shift_k = sky.fetch(:outdoor_k) - Conditions::STANDARD_K

      # **A node's ambient now**: its declared figure, shifted by the weather as far as its place
      # is exposed. Exact under the standard sky, which is what leaves every machine a spec
      # measures where it was.
      def ambient_k_of(node)
        share = exposure&.fetch(node.id, nil) or return node.ambient_k

        node.ambient_k + (share * outdoor_shift_k)
      end

      # The weight of everybody committed to riding this hoist, as of last tick.
      def cargo_kg(id) = cargo&.fetch(id, 0.0) || 0.0

      # What is alight in the room this node is the air of, as `{ kg_per_s:, watts:, cause: }`,
      # or nil. Keyed by the air node rather than the place, because the air is what catches.
      def room_ignition(id) = ignition&.[](id)

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

    # What is dangerous this tick, by the two things that can make it so: the post somebody is
    # standing at, and the room they are standing in. Resolved together per minion, because a
    # hewer whose roof comes in while his district is full of afterdamp is in both.
    # And the third: the hoist somebody is riding, because a cage hitting the headframe hurts the
    # men in it and not the men standing at the landing it passed.
    # `alongs` are hazards that run down a passage (`along:`), whose weight depends on where on it
    # somebody is — resolved per person in `endanger`, not indexed.
    Exposure = Struct.new(:stations, :places, :riders, :alongs, keyword_init: true) do
      def empty? = stations.empty? && places.empty? && riders.empty? && alongs.empty?

      # Each kind's severity ADDS and causes union, the same rule two failures at one post already
      # follow.
      def at(station, place, via = nil)
        found = [ stations[station], places[place], riders[via] ].compact
        return nil if found.empty?
        return found.first if found.one?

        found.reduce { |a, b| Tick.combined(a, b) }
      end
    end

    # **Every wound a harm left, for the record** — nobody's broken leg goes unmentioned because
    # they were also badly burned. Carries what the delivery tier keeps between matches: the kind,
    # the depth and the variant, and **which wound it is** — its place among theirs this match
    # (`slot`), or the delivery tier's own name for one carried in (`ref`) — so a wound that
    # deepens is the same wound.
    def self.reported(wounds, state)
      held = state.fetch(:wounds, [])
      wounds.map do |wound|
        { kind: wound.fetch(:kind), tier: wound.fetch(:tier), id: wound.fetch(:id),
          label: wound.fetch(:label), depth: wound.fetch(:depth).round(3),
          variant: wound.fetch(:variant), cause: wound[:cause], ref: wound[:ref],
          slot: held.index { |w| w.equal?(wound) } }.compact
      end
    end

    # Two hazards reaching one person at once, as one.
    def self.combined(first, second)
      first.merge(second) do |key, x, y|
        case key
        when :wounds then x.merge(y) { |_, a, b| a + b }
        when :causes, :sources then x | y
        else x
        end
      end
    end

    attr_reader :state, :nodes, :links, :paths, :thermal_links, :drive_links, :control_points,
                :diagnostics, :minions, :content, :rngs, :layout, :routing

    def initialize(operation, state)
      @state = state
      @grudges = operation.grudges
      @nodes = operation.nodes
      @links = operation.links
      @paths = operation.paths
      @gas_neighbours = operation.gas_neighbours
      @thermal_links = operation.thermal_links
      @drive_links = operation.drive_links
      @control_points = operation.control_points
      @diagnostics = operation.diagnostics
      @minions = operation.minions
      @content = operation.content
      @rngs = operation.rngs
      @layout = operation.layout
      @routing = operation.routing
    end

    # Returns the next state. The operation installs it; nothing is mutated here.
    def call(tick:, dt:)
      fates = @fates = draw_fates                               # phase 0
      @tempers = draw_tempers                                   # phase 0
      @wound_dice = draw_wounds                                 # phase 0
      controls = actuate(dt, fates)                             # phase 0
      read = state.fetch(:nodes)                                # phase 1
      # `control_values` builds `@ignition` from the same lever positions, so it comes first.
      ctx = Context.new(controls: control_values(controls), ignition: @ignition, cargo: cargo,
                        dt:, tick:, content: content, nodes: nodes, states: read,
                        outdoors: sky_before, exposure: layout.node_exposure)

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
      next_nodes, prompt_events = react(next_nodes, ctx)        # phase 5
      ledger = record_injections(ledger, next_nodes)
      next_nodes, ledger, wear_events = stress(next_nodes, ledger, ctx, prompt_events)  # phase 6
      next_minions, hurt_events = endanger(wear_events + prompt_events, ctx)  # phase 6b
      next_minions, burn_events = scorch(next_minions, next_nodes, ctx)  # phase 6b′
      felt = place_felt(next_nodes)
      next_minions, cold_events = chill(next_minions, felt, ctx)         # phase 6b″
      next_minions, spent_events = tire(next_minions, next_nodes, controls, ctx, felt)  # phase 6c
      next_minions, blunder_events = blunder(next_minions, next_nodes, fates, ctx) # phase 6d
      tempers = provoke(next_minions, next_nodes, ctx)           # phase 6d′
      next_minions = tempers.minions
      next_minions, carry_events = travel(next_minions, ctx)     # phase 6e
      next_nodes = signal_winding(next_nodes, next_minions, controls)
      next_diagnostics = observe(next_nodes, ctx)                # phase 7

      # Phase 8. Note that this hash IS the next state — a key not named here is silently
      # dropped, so anything added to state must also be added here even when no phase
      # touches it.
      { nodes: next_nodes.freeze,
        controls: controls.freeze,
        diagnostics: next_diagnostics.freeze,
        minions: next_minions.freeze,
        ledger: ledger.freeze,
        mishaps: (pending_mishaps(blunder_events) + tempers.mishaps).freeze,
        spite: tempers.spite,
        events: (events + prompt_events + wear_events + hurt_events + burn_events + cold_events +
                 spent_events + blunder_events + tempers.events + carry_events).freeze }.freeze
    end

    # **What somebody did to a part this tick, for the next tick's `stress` to apply.** Its own
    # state key because events are output and are not snapshotted.
    def pending_mishaps(blunder_events)
      blunder_events.filter_map do |event|
        next unless event[:type] == :minion_mishap

        event.fetch(:detail).slice(:node, :kind, :share).freeze
      end.freeze
    end

    private

    # Phase 0. **Where the levers actually get to, which is not always where they were sent.**
    #
    # Travel and application are separated so a mistake can send one lever's movement to a
    # different lever. A slip changes `actual` and never `target`: the command log still
    # carries absolute destinations, still replays identically and still needs no dedup table.
    # **The mistake is in the execution, not in the instruction**, which is both the honest
    # model of a real mistake and the only version that leaves invariant 4 intact.
    def actuate(dt, fates)
      states = state.fetch(:controls)
      steps = states.to_h do |id, cp_state|
        [ id, control_points.fetch(id)
                .travel(cp_state, dt: dt, rate_multiplier: crew_multiplier(id)) ]
      end

      slips = slips_for(states, fates, dt)
      moved = misapplied(steps, slips)

      levers = states.to_h do |id, cp_state|
        [ id, control_points.fetch(id).nudge(cp_state, moved.fetch(id, 0.0))
                            .merge(slips.fetch(id, NO_SLIP)).compact.freeze ]
      end
      governed(levers, dt)
    end

    # **A post whose occupant drives other levers** — the engineman working the clutches and brake
    # to send the cage where the player named, a mobile engine's driver working its throttle and
    # feed. From the machine's frozen last-tick state, so it cannot depend on phase order. With
    # nobody posted nothing runs, and the levers it drives hold where they were left: their target is
    # written with their actual, so they have nowhere to travel to.
    def governed(levers, dt)
      control_points.each_value.select(&:governor).reduce(levers) do |acc, post|
        minion_id = occupant(post.id) or next acc
        minion = minions[minion_id] or next acc

        governor = post.governor
        held = governor.levers.to_h { |id| [ id, control_points.fetch(id).value(acc.fetch(id)) ] }
        frozen = acc.fetch(post.id)[:slip] == :freeze
        outputs =
          if governor.respond_to?(:hoist)
            winding(governor, post, minion, acc, held, frozen)
          else
            governor.govern(commanded: post.value(acc.fetch(post.id)), nodes: nodes, states: state.fetch(:nodes),
                            content: content, dt: dt, frozen: frozen, held: held, lateness: lateness(post, minion))
          end
        acc.merge(outputs.to_h { |id, value| [ id, acc.fetch(id).merge(target: value, actual: value).freeze ] })
      end
    end

    # The winding engineman: where the cage is to go, then the clutches and brake to take it there.
    def winding(governor, post, minion, acc, held, frozen)
      drum = nodes.fetch(governor.hoist)
      drum_state = state.fetch(:nodes).fetch(governor.hoist)
      destination = governor.dispatch(
        commanded: post.value(acc.fetch(post.id)), shuttling: shuttling?(governor, acc),
        drum: drum, drum_state: drum_state, states: state.fetch(:nodes),
        calls: calls_for(governor.hoist)
      )
      governor.govern(
        destination: destination, drum: drum, drum_state: drum_state,
        lateness: lateness(post, minion), frozen: frozen, held: held,
        ready: signalled?(governor.hoist, acc)
      )
    end

    # **The signal board**: what each winder's cage is doing and waiting on, written onto its drum
    # as `signal:` for the panel (`Winding#signal`). After the walk, over the tick that has just
    # settled — the boarders, the marshals at their posts, the decks being worked — because no node
    # can see the people, the same reason `advect` hands a conduit its `carried_kg`.
    def signal_winding(states, minions_state, levers)
      control_points.each_value.select { |post| post.governor.respond_to?(:hoist) }.reduce(states) do |acc, post|
        governor = post.governor
        passage = layout.passages.find { |p| p.hoist == governor.hoist } or next acc
        drum = nodes.fetch(governor.hoist)
        drum_state = acc.fetch(governor.hoist)
        posted = minions_state.values.filter_map { |s| s[:station] }
        landing = passage.ends.find { |place| drum.cage_stopped_at?(drum_state, passage.landing_m(place)) }
        marshals = passage.marshals.select { |_, post_id| posted.include?(post_id) }.keys

        signal = governor.signal(
          drum: drum, drum_state: drum_state, states: acc, landing: landing,
          staffed: posted.include?(post.id), fumbling: !levers.fetch(post.id)[:slip].nil?,
          running: winding_shaft_running?(passage, acc), shuttling: shuttling?(governor, levers),
          marshals: marshals, slipping: marshals.select { |place| levers.fetch(passage.marshals.fetch(place))[:slip] },
          boarding: minions_state.values.filter_map { |s| s[:place] if s[:via] == governor.hoist && s.fetch(:boarding_s, 0.0).positive? },
          waiting: minions_state.filter_map { |id, s| s[:place] if minions.key?(id) && waiting_to_cross?(id, s, passage) }
        )
        acc.merge(governor.hoist => drum_state.merge(signal: governor.signal_index(signal)).freeze)
      end
    end

    # Whether what drives a ridden way is turning, the test `in_service?` makes, on settled state.
    def winding_shaft_running?(passage, states)
      return true unless passage.driven_by && passage.rated_omega&.positive?

      shaft = nodes.fetch(passage.driven_by)
      shaft.omega(states.fetch(passage.driven_by)).abs >= passage.rated_omega * DRIVEN_IN_SERVICE
    end

    def shuttling?(governor, levers)
      return false unless governor.shuttle && levers.key?(governor.shuttle)

      control_points.fetch(governor.shuttle).value(levers.fetch(governor.shuttle)) >= 50.0
    end

    # **Where the men on a hoist want it**, as percent of the shaft from bank: the far landing of
    # anybody aboard first, then the landing of anybody waiting there to cross, by id. From the
    # frozen previous tick, like everything else the engineman reads.
    def calls_for(hoist)
      passage = layout.passages.find { |p| p.hoist == hoist } or return []
      riders = state.fetch(:minions).select { |id, _| minions.key?(id) }.sort_by(&:first)

      aboard = riders.filter_map { |_, s| passage.other(s[:place]) if s[:via] == hoist }
      waiting = riders.filter_map { |id, s| s[:place] if waiting_to_cross?(id, s, passage) }
      (aboard + waiting).uniq.map { |landing| passage.landing_m(landing) / passage.metres * 100.0 }
    end

    def waiting_to_cross?(id, minion_state, passage)
      here = minion_state[:place]
      return false unless minion_state[:via].nil? && passage.touches?(here)

      going = posted_place(minions.fetch(id), minion_state)
      return false if going.nil? || going == here

      layout.next_hop(here, going, routing.fetch(id, []), closed_ways) == passage.other(here)
    end

    # **The marshal's bell**: whether the cage may be wound away from the landing it stands at. With
    # no marshal posted there is no bell, and the engineman winds on the order alone. A posted
    # marshal rings once nobody is still getting in — or, slipping, rings anyway: a false ready.
    def signalled?(hoist, levers)
      passage = layout.passages.find { |p| p.hoist == hoist } or return true
      drum = nodes.fetch(hoist)
      drum_state = state.fetch(:nodes).fetch(hoist)
      landing = passage.ends.find { |place| drum.cage_stopped_at?(drum_state, passage.landing_m(place)) }
      marshal = landing && passage.marshals[landing]
      return true if marshal.nil? || crews[marshal].nil?
      return true if levers.fetch(marshal)[:slip]

      state.fetch(:minions).none? do |_, s|
        s[:via] == hoist && s[:place] == landing && s.fetch(:boarding_s, 0.0).positive?
      end
    end

    # How far out of their depth somebody is at a post, as a factor on how late they act: 1.0 for
    # a hand who knows the job. The same `difficulty − wits` that decides how often they slip.
    def lateness(post, minion)
      minion_state = state.fetch(:minions).fetch(minion.id)
      wits = minion.wits(minion_state, ambient: ambient_for(minion, minion_state))

      1.0 + [ post.difficulty(minion) - wits, 0.0 ].max
    end

    # **A slip somebody meant** (`state[:spite]`, left by phase 6d′) begins in place of the dice.
    def slips_for(states, fates, dt)
      meant = state.fetch(:spite, []).to_h { |deed| [ deed.fetch(:control), deed.fetch(:slip) ] }

      states.to_h do |id, cp_state|
        next [ id, { slip: meant.fetch(id), slip_at: nil, slip_for: SLIP_TICKS } ] if meant.key?(id)

        left = cp_state[:slip_for].to_i
        next [ id, cp_state.slice(:slip, :slip_at).merge(slip_for: left - 1) ] if left.positive?

        [ id, begin_slip(control_points.fetch(id), fates, dt) ]
      end
    end

    # **Everybody at the post can get it wrong, each on their own die**, so a crew slips more often
    # than one of its members. The first of them by id who did picks the kind and the victim.
    def begin_slip(control, fates, dt)
      crew = crews[control.id] or return NO_SLIP
      fate = crew.lazy.filter_map { |id| slipped(control, id, fates, dt) }.first or return NO_SLIP

      kind = SLIPS[(fate.fetch(:kind) * SLIPS.length).floor.clamp(0, SLIPS.length - 1)]
      victim = kind == :wrong_lever ? within_reach(control, fate.fetch(:victim)) : nil
      return NO_SLIP if kind == :wrong_lever && victim.nil?

      { slip: kind, slip_at: victim, slip_for: SLIP_TICKS }
    end

    # This minion's fate if it says they slipped at this lever, or nil.
    def slipped(control, minion_id, fates, dt)
      fate = fates[minion_id] or return nil
      minion_state = state.fetch(:minions).fetch(minion_id)
      minion = minions.fetch(minion_id)
      wits = minion.wits(minion_state, ambient: ambient_for(minion, minion_state))

      fate.fetch(:slip) < control.slip_chance(minion, wits, dt) ? fate : nil
    end

    # **Which other lever they could have grabbed instead** — the ones in the same room, which
    # is why this waited for geometry. You cannot pull something in another building by
    # mistake.
    def within_reach(control, pick)
      # Empty for a lever standing on its own, and for one placed nowhere at all — in an
      # operation with no geometry there is no such thing as the lever next to this one.
      near = reachable.fetch(control.id, [])
      return nil if near.empty?

      near[(pick * near.length).floor.clamp(0, near.length - 1)]
    end

    def reachable
      @reachable ||= control_points.each_value.group_by(&:place).transform_values { |group|
        group.select(&:lever?).map(&:id)
      }.each_with_object({}) { |(place, ids), acc|
        next if place.nil?

        ids.each { |id| acc[id] = (ids - [ id ]).freeze }
      }
    end

    # Reads the PREVIOUS tick's lever positions, because phase 0 runs before phase 1 settles
    # this tick's — and because a gate asking whether somebody can see should not depend on a
    # light they are about to switch on.
    def ambient_before
      @ambient_before ||=
        ambient_tags(state.fetch(:controls).to_h { |id, s| [ id, control_points.fetch(id).value(s) ] })
    end

    # Order-independent on purpose: every redirection reads the frozen `steps`, never the
    # running total, so two minions slipping onto each other's levers cannot depend on which
    # was visited first.
    def misapplied(steps, slips)
      moved = steps.to_h do |id, step|
        [ id, case slips.dig(id, :slip)
              when nil then step
              when :reverse then -step
              else 0.0
              end ]
      end

      slips.each do |id, slip|
        next unless slip[:slip] == :wrong_lever && slip[:slip_at]

        moved[slip[:slip_at]] = moved.fetch(slip[:slip_at], 0.0) + steps.fetch(id, 0.0)
      end

      moved
    end

    # Who is stood at this lever, and how fast they can work it: **the hands on it, summed**, as
    # two people on a stiff valve wheel turn it faster than one.
    #
    # Read from STATE rather than configuration, because a station is assignable: a minion who
    # has been moved is at the post their state names, not the one they were built with.
    def crew_multiplier(control_point_id)
      crew = crews[control_point_id]
      # **An unattended lever travels at its rated speed, because the overseer is working it.**
      # Surface plant is the player's own: a colliery's fan, pump and winder are at bank where
      # no minion is normally posted, so a lever that froze without a body would mean a pit
      # whose fan could never be started. Posting somebody makes it *faster or slower* than
      # rated rather than making it possible at all.
      return 1.0 unless crew

      crew.sum { |id| minions.fetch(id).rate_multiplier(state.fetch(:minions).fetch(id), content) }
    end

    # **Everybody actually working each post**, by sorted id — `station`, not `posting`, because
    # somebody still walking there is not working yet. Sorted, so every sum over a crew and every
    # "first of them" is independent of the order the roster was declared in. A post nobody is at
    # has no entry. `Operation#room_at?` keeps a crew within the post's `capacity`.
    def crews
      @crews ||= state.fetch(:minions).keys.sort.each_with_object({}) { |id, acc|
        next unless minions.key?(id)

        minion_state = state.fetch(:minions).fetch(id)
        # Somebody in a fight is at their post and working nothing.
        next if Animosity.fighting?(minion_state)

        station = minion_state[:station] or next
        (acc[station] ||= []) << id
      }.transform_values(&:freeze).freeze
    end

    # The one person at a post that holds one — a governor, which `ControlPoint` refuses to give
    # room for more.
    def occupant(post_id) = crews[post_id]&.first

    # What a node actually reads off a lever. For a **valve** that is its position: a regulator
    # goes where you put it. For an **effort** station it is the position scaled by what the
    # person standing there can manage, because stoking is not a setting — it is somebody
    # shovelling, and the lever is their instruction to do it as hard as they can.
    #
    # **Nobody posted means nothing gets done.** An unmanned shovel moves no coal.
    def control_values(controls)
      levers = controls.to_h { |id, s| [ id, control_points.fetch(id).value(s) ] }
      # Kept, because phase 7 asks the same question of an observer that phase 0 asks of a
      # worker: whether the room lets them see what they are doing.
      ambient = @ambient = ambient_tags(levers)
      @ignition = ignition_sources(levers)

      controls.to_h do |id, s|
        control = control_points.fetch(id)
        [ id, control.effort? ? worked(control, s, ambient) : levers.fetch(id) ]
      end.freeze
    end

    # **What the ROOM contributes to a job, as opposed to what the person brought to it.**
    #
    # A lamp on the wall and a lamp on your belt are the same fact to a gate: `gated_by:
    # darkvision` asks whether somebody can see, not whose light it is. So a node that lights a
    # place offers its tag to everybody standing in it, and `Minion#gate` takes the better of
    # the two — the better, never the sum, because two lamps do not let you see twice.
    #
    # Read from N−1 node state and this tick's lever positions, exactly as `worked` reads N−1
    # minions, so nothing here can depend on phase order. An operation with no places — the
    # steam engine — skips it entirely and every gate stays what the minion carries.
    def ambient_tags(levers)
      return {} if layout.places.empty?

      lit = nodes.each_with_object({}) do |(id, node), acc|
        next unless node.respond_to?(:ambient_tags)

        place = layout.place_of_node(id) or next
        offered = node.ambient_tags(state.fetch(:nodes).fetch(id), levers)
        acc[place] = (acc[place] || {}).merge(offered) { |_, a, b| [ a, b ].max }
      end
      under_the_sky(lit)
    end

    # **What the sky offers a place open to it**, as far as it is open: its light, and whether the
    # ground underfoot is wet or icy. Merged by the same better-of rule as a lamp, so daylight at
    # bank and a lamp at bank do not add up to more than either.
    def under_the_sky(lit)
      sky = sky_before
      layout.exposed_places.each_with_object(lit) do |place, acc|
        share = layout.exposure(place)
        offered = { darkvision: sky.fetch(:daylight) * share,
                    wet: sky.fetch(:wet, 0) * share, icy: sky.fetch(:icy, 0) * share }.reject { |_, v| v.zero? }
        acc[place] = (acc[place] || {}).merge(offered) { |_, a, b| [ a, b ].max }
      end
    end

    # The sky as it was at the end of last tick, which is what everything this tick reads.
    def sky_before
      @sky_before ||= state.dig(:nodes, Nodes::Outdoors::ID)&.slice(*Nodes::Outdoors::SKY) ||
                      Conditions::STANDARD
    end

    # **An ignition source belongs to the room it is in**, and offers itself to the air of that
    # room. A candle, a sparking bell and a hot bearing are all this, which is why no vessel
    # names its igniters: the sources are whatever stands in its place.
    #
    # Built as `ambient_tags` is, from N−1 node state and this tick's levers. **Walked by sorted
    # id**, because sources in one room are summed and the sum must not depend on the order an
    # operation declared its nodes in.
    #
    # **People are in the room too**: anybody carrying a naked light (`open_flame`) offers it to the
    # air where they stand, as of last tick — the commonest igniter of all. Walked after the nodes,
    # by sorted id, for the same reason.
    #
    # TODO: callers still to come, each untested until it lands — hot bearings and a burning
    # headgear (unit 3b); a blown-out shot (unit 4).
    def ignition_sources(levers)
      return {} if layout.places.empty?

      lit = nodes.keys.sort.each_with_object({}) do |id, acc|
        node = nodes.fetch(id)
        next unless node.respond_to?(:ignition)

        air = layout.breathes(layout.place_of_node(id)) or next
        offered = node.ignition(state.fetch(:nodes).fetch(id), levers) or next
        next unless offered.fetch(:kg_per_s, 0.0).positive? || offered.fetch(:watts, 0.0).positive?

        acc[air] = alight_together(acc[air], offered)
      end
      hand_flames(lit).freeze
    end

    def hand_flames(lit)
      minions.keys.sort.each_with_object(lit) do |id, acc|
        minion = minions.fetch(id)
        next unless minion.open_flame?

        air = layout.breathes(state.dig(:minions, id, :place)) or next
        acc[air] = alight_together(acc[air], Minion::HAND_FLAME)
      end
    end

    # **What each hoist or man engine is carrying**: everybody on it, by their body, their kit and
    # anybody they are carrying. From the frozen previous tick, so it cannot depend on phase order.
    def cargo
      carried = being_carried(state.fetch(:minions))

      state.fetch(:minions).each_with_object(Hash.new(0.0)) do |(id, minion_state), acc|
        hoist = carried_by(minion_state) or next
        minion = minions[id] or next
        next if carried.key?(id)

        acc[hoist] += minion.mass_kg + Burden.load_kg(minion, minion_state, minions)
      end.freeze
    end

    # Two sources in one room burn together; the room was lit by whichever offered more.
    def alight_together(was, offered)
      return offered.freeze if was.nil?

      { kg_per_s: was.fetch(:kg_per_s, 0.0) + offered.fetch(:kg_per_s, 0.0),
        watts: was.fetch(:watts, 0.0) + offered.fetch(:watts, 0.0),
        cause: offered.fetch(:kg_per_s, 0.0) > was.fetch(:kg_per_s, 0.0) ? offered[:cause] : was[:cause] }.freeze
    end

    # **In worker-equivalents**: the lever times the crew's capabilities, summed. 100 is one
    # competent, unaided human flat out and five of them read 500, so a node multiplies a
    # per-worker rate by this and caps nothing — the crew is the ceiling.
    #
    # Read from the PREVIOUS tick's minion state, so who is standing where cannot depend on
    # phase order. A minion carried out has `station: nil` and therefore mans nothing.
    def worked(control, control_state, ambient)
      crew = crews[control.id] or return 0.0

      control.value(control_state) * crew.sum do |id|
        minion_state = state.fetch(:minions).fetch(id)
        minions.fetch(id).capability(minion_state,
                                     effort: control.effort, aided_by: control.aided_by,
                                     gated_by: control.gated_by,
                                     ambient: ambient[minion_state[:place]])
      end
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

      # A geared link takes `ratio` times what it delivers off its driving end.
      net = Hash.new(0.0)
      drive_links.each do |link|
        delta = transfers.fetch(link.id, 0.0)
        net[link.a] -= link.ratio * delta
        net[link.b] += delta
      end
      rotating_ids.each do |id|
        net[id] -= transfers.fetch(:"#{id}=ground", 0.0)
        net[id] += transfers.fetch(:"#{id}=source", 0.0)
      end

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
    #
    # **A source is the one term that can put energy in.** Gravity on a falling load adds to the
    # drivetrain and gravity on a rising one takes from it, so its work is estimated the same way,
    # booked on the node that declared it — `joules_injected` in, `joules_extracted` out — and
    # added back before the drags and slip divide what is left.
    def book_drive(states, lost, transfers, ledger, ctx)
      estimates = drag_estimates(states, transfers, ctx)
      sourced = source_estimates(states, transfers)
      total = estimates.values.sum + slip_estimate(states, transfers)
      scale = total.positive? ? (lost + sourced.values.sum) / total : 0.0
      gained = sourced.values.sum { |joules| [ joules, 0.0 ].max }

      # Work leaves through `joules_extracted`, which `record_injections` already sums — a load
      # reports its own extraction exactly as an injector reports its own. **What a rope end
      # brakes off is `joules_roped`**, kept apart because only it crosses to the far end: every
      # other `:work` drag on that shaft — the fan's, the pump's — is this operation's own.
      booked = states.to_h do |id, state|
        next [ id, state ] unless rotating_ids.include?(id)

        roped = nodes.fetch(id).respond_to?(:hear) ? { joules_roped: estimates.fetch([ id, :rope ], 0.0) * scale } : {}
        raised = [ -sourced.fetch(id, 0.0), 0.0 ].max
        fallen = nodes.fetch(id).respond_to?(:drive_torque) ? { joules_injected: [ sourced.fetch(id, 0.0), 0.0 ].max } : {}
        [ id, state.merge(joules_extracted: (estimates.fetch([ id, :work ], 0.0) * scale) + raised,
                          **roped, **fallen) ]
      end

      # **A drag that names a node heats that node**, so its energy never leaves the system and
      # never reaches the ledger. That is what makes a bearing able to run hot.
      kept = 0.0
      estimates.each do |(_, into), estimate|
        next if %i[work friction rope].include?(into)

        joules = estimate * scale
        kept += joules
        booked[into] = nodes.fetch(into).add_joules(booked.fetch(into), joules, ctx.content)
      end

      taken = booked.sum do |id, s|
        rotating_ids.include?(id) ? s.fetch(:joules_extracted, 0.0) + s.fetch(:joules_roped, 0.0) : 0.0
      end
      friction = lost - taken - kept + gained
      return [ booked, ledger ] if friction.abs <= Parcel::EPSILON

      [ booked, Ledger.add(ledger, joules_to_friction: friction) ]
    end

    # `momentum × ω` per source, signed: positive is energy into the drivetrain.
    def source_estimates(states, transfers)
      rotating_ids.each_with_object({}) do |id, acc|
        momentum = transfers.fetch(:"#{id}=source", 0.0)
        next if momentum.zero?

        acc[id] = momentum * nodes.fetch(id).omega(states.fetch(id))
      end
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

        gap = (link.ratio * nodes.fetch(link.a).omega(states.fetch(link.a))) -
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
      work   = states.values.sum { |s| s.fetch(:joules_extracted, 0.0) + s.fetch(:joules_roped, 0.0) }
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
    # Chemistry advances at a rate; phase change snaps to equilibrium. **So does anything faster
    # than a tick**: a node hosting a prompt reaction resolves it first (`Concerns::PromptReaction`),
    # and what it resolved does not then run again at its rate.
    #
    # **A front travels a room a tick**: one that resolved in a neighbour last tick (`front:` in
    # its N−1 state) arrives here this tick, through any path that carries gas.
    def react(states, ctx)
      events = []
      reacted = states.to_h do |id, state|
        node = nodes.fetch(id)
        # A front lasts the tick it resolved in, so one left over from an emptied room is spent.
        next [ id, state[:front] ? state.merge(front: false) : state ] unless state.key?(:parcels) &&
                                                                              !state.fetch(:parcels).empty?

        state = state.merge(joules_from_reactions: 0.0)
        resolved = []
        if node.respond_to?(:resolve_prompt)
          state, resolved, prompted = node.resolve_prompt(state, ctx, arriving: front_from(id, ctx))
          events.concat(prompted)
        end
        state = run_reactions(node, state, ctx, skip: resolved)
        state = run_phase_change(node, state, ctx)
        [ id, node.rebalance(state, content).freeze ]
      end

      [ reacted, events ]
    end

    # The first neighbour, by sorted id, whose front resolved last tick; nil if none did.
    def front_from(id, ctx)
      @gas_neighbours.fetch(id, []).find { |neighbour| ctx.node_state(neighbour)&.fetch(:front, false) }
    end

    def run_reactions(node, state, ctx, skip: [])
      (node.reactions - skip).reduce(state) do |acc, reaction_id|
        spec = content.reaction(reaction_id)
        acc = advance_ignition(spec, reaction_id, node, acc, ctx)

        # A bed choked with its own ash reacts more slowly, because the air can no longer reach
        # what is left to burn. Applied to `dt` so the closed form stays a closed form and
        # stays exact — a reaction that gets a shorter effective second is the same reaction.
        parcels, released = Resources::Reaction.advance(
          spec, acc.fetch(:parcels),
          temperature_k: node.temperature_k(acc, content),
          dt: ctx.dt * node.reaction_throttle(acc, content, reaction_id), content: content,
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
        seed_kg: state.fetch(:ignition_seed_kg, 0.0),
        hottest_k: hot_spot_k(node, ctx)
      )

      with_ignition(state, reaction_id, advanced)
    end

    # The hottest of the nodes a vessel's fuel touches, as of last tick; nil if it names none.
    def hot_spot_k(node, ctx)
      spots = node.respond_to?(:hot_spot) ? Array(node.hot_spot) : []
      spots.filter_map { |spot| ctx.node_temperature(spot) }.max
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
    #
    # **A mixture outside its flammable range has no front to move on**, so there what burns comes
    # off the lit mass one for one: a naked light in lean gas burns what it lit and no more. In
    # proportion, the lit mass would outlive every tick's burn and a lean district would burn many
    # times what its lights set alight.
    def burn_down_ignition(spec, reaction_id, state, next_parcels)
      return state unless Resources::Ignition.modelled?(spec)

      before = Resources::Ignition.fuel_mass(spec, state.fetch(:parcels), content)
      after = Resources::Ignition.fuel_mass(spec, next_parcels, content)
      return state unless before.positive? && after < before

      ignition = ignition_for(state, reaction_id)
      lit = ignition.fetch(:kg, 0.0)
      left = if Resources::Ignition.carries_flame?(spec, state.fetch(:parcels), content)
        lit * (after / before)
      else
        [ lit - (before - after), 0.0 ].max
      end
      with_ignition(state, reaction_id, ignition.merge(kg: left))
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
    # `prompt_events` are phase 5's — an explosion takes its `damages:` with it the way a failure does.
    def stress(states, ledger, ctx, prompt_events = [])
      states, events = suffer_mishaps(states, ctx)
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

      next_states = spread_damage(next_states, events + prompt_events)

      # The energy that wheel was carrying went into wrecking the shop. Ledgered rather than
      # dropped, for the same reason belt slip is: an explicit line nobody can miss beats a
      # silent hole, and this one is large — a flywheel at its burst speed holds megajoules.
      wrecked = before - rotating_kinetic_joules(next_states)
      ledger = Ledger.add(ledger, joules_to_friction: wrecked) if wrecked.abs > Parcel::EPSILON

      [ next_states, ledger, events ]
    end

    # Phase 6, first: **what somebody did to a part last tick** (`state[:mishaps]`). Before wear,
    # so a part a mishap breaks is then treated exactly as any other broken part this tick — its
    # momentum taken, its `failure_damages` spread.
    def suffer_mishaps(states, ctx)
      events = []
      suffered = state.fetch(:mishaps, []).reduce(states) do |acc, mishap|
        target = mishap.fetch(:node)
        after, emitted = nodes.fetch(target).suffer(acc.fetch(target), mishap, ctx)
        events.concat(emitted)
        acc.merge(target => after.freeze)
      end

      [ suffered, events ]
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
        # Both come from state rather than config — a minion who has been reassigned is standing
        # somewhere else, and one already carried out has no station and cannot be hurt again by
        # the same blast. **A place outlives a station**: being stood down clears the post but
        # not the room, so somebody carried out of a district full of afterdamp is still in it.
        hazard = exposure.at(minion_state[:station], minion_state[:place], carried_by(minion_state))
        next [ id, minion_state ] if minion.nil?

        hazard = along(exposure.alongs, minion, minion_state, hazard, events, ctx)
        next [ id, minion_state ] if hazard.nil?

        hurt, mode, wounds = injure(minion, minion_state, hazard)
        events << hurt_event(minion, hurt, mode, wounds, hazard, ctx) if mode
        [ id, hurt.freeze ]
      end

      [ next_states, events ]
    end

    # **A hazard that runs down a passage** — a runaway set on an incline — and reaches each person
    # by where on it they are: `share` of the way from the top, the harm growing with it as the
    # energy does. At the foot it is everybody; at the top, little. Stations may be placed on the
    # way (`positions:`), and those who work the road itself (`roaming:`) are somewhere on it by
    # their `road:` die. **Anybody on the road** may reach the refuge the place has fitted, by its
    # effectiveness and their wits — a near miss — or, worse, be **crushed** by a fast set, a
    # chance that rises as the square of the share.
    def along(alongs, minion, minion_state, hazard, events, ctx)
      alongs.reduce(hazard) do |acc, (declared, scale, source)|
        run = declared.fetch(:along)
        placed = run_share(run, minion, minion_state) or next acc
        share, on_road = placed
        share = past_the_catch(run, share)
        next acc unless share.positive?

        if on_road && (guard = refuge_reached(minion, minion_state))
          events << near_miss_event(minion, minion_state, source, guard, ctx)
          next acc
        end

        hit = run_hit(run, declared, scale * share, on_road && caught?(run, minion, minion_state, share), source)
        acc ? Tick.combined(acc, hit) : hit
      end
    end

    # **A run with a `catch:` stops most of what passes it**: further down than `at`, what is left
    # of the share is `1 − holds` of it. Above the catch, unchanged.
    def past_the_catch(run, share)
      stop = run[:catch] or return share
      share > stop.fetch(:at) ? share * (1.0 - stop.fetch(:holds)) : share
    end

    # `[share, on_road]`, or nil for somebody nowhere on the run.
    def run_share(run, minion, minion_state)
      station = minion_state[:station]
      place = minion_state[:place]
      return [ run.fetch(:positions).fetch(station), false ] if run.fetch(:positions, {}).key?(station)
      return [ fate_of(minion, :road), true ] if Array(run[:roaming]).include?(station)

      walking = walking_share(run, minion, minion_state)
      return [ walking, true ] if walking
      return [ 1.0, false ] if place == run.fetch(:to)
      return [ run.fetch(:top_share, 0.0), false ] if place == run.fetch(:from)

      nil
    end

    # How far down the run somebody walking it has got, or nil if they are not on it.
    def walking_share(run, minion, minion_state)
      return nil unless minion_state.fetch(:progress, 0.0).positive?

      here = minion_state[:place]
      ends = [ run.fetch(:from), run.fetch(:to) ]
      return nil unless ends.include?(here)

      going = posted_place(minion, minion_state) or return nil
      hop = layout.next_hop(here, going, routing.fetch(minion.id, []), closed_ways)
      return nil unless ends.include?(hop) && hop != here

      metres = layout.passages_between(here, hop).first&.metres or return nil
      gone = (minion_state.fetch(:progress) / metres).clamp(0.0, 1.0)
      here == run.fetch(:from) ? gone : 1.0 - gone
    end

    # The refuge somebody on the road reached, or nil.
    def refuge_reached(minion, minion_state)
      fitted = safety_equipment[minion_state[:place]] or return nil
      effectiveness, source = fitted
      Blunder.accident_avoided?(effectiveness, avoid_for(minion, minion_state), fate_of(minion, :dodge)) ? source : nil
    end

    # Somebody quick and watchful is caught less often; nobody is ever safe from it.
    def caught?(run, minion, minion_state, share)
      crushed = run[:crushed] or return false
      clear = [ avoid_for(minion, minion_state), Blunder::MIN_AVOID ].max
      fate_of(minion, :caught) < crushed.fetch(:chance) * (share**2) / clear
    end

    # **Getting out of the way, where they stand**: their wits in the room's light and its
    # distractions, and their agility under what they carry.
    def avoid_for(minion, minion_state)
      minion.avoid(minion_state, ambient: ambient_for(minion, minion_state),
                                 burden: Burden.ratio(minion, minion_state, minions))
    end

    # **What the room offers this person**: its own tags, with the allure of everybody else
    # standing in it added to whatever `distracting` the room offers. From last tick's places, so
    # it cannot depend on visit order; nobody is distracted by themselves. An operation with no
    # geometry is one room.
    def ambient_for(minion, minion_state, rooms = ambient_before)
      place = minion_state[:place]
      room = rooms[place]
      others = allure_before.fetch(place, []).sum { |id, allure| id == minion.id ? 0.0 : allure }
      return room unless others.positive?

      (room || {}).merge(distracting: Injury.numeric(room&.fetch(:distracting, nil)) + others)
    end

    # `{ place => [[id, allure]] }` of everybody with any, by sorted id.
    def allure_before
      @allure_before ||= minions.keys.sort.each_with_object({}) { |id, acc|
        minion_state = state.fetch(:minions).fetch(id)
        allure = minions.fetch(id).allure(minion_state)
        (acc[minion_state[:place]] ||= []) << [ id, allure ] if allure.positive?
      }.freeze
    end

    # A set that catches somebody does `factor` times the harm, and of the kinds `crushed:` says.
    def run_hit(run, declared, weight, crushed, source)
      severity = run.fetch(:weight) * weight
      shares = declared.fetch(:wounds)
      cause = nil
      if crushed
        severity *= run.dig(:crushed, :factor)
        shares = run.dig(:crushed, :wounds)
        cause = run.dig(:crushed, :cause)
      end
      { wounds: Wounds.dealt(shares, severity), causes: Array(declared[:causes]), sources: [ source ],
        cause: cause }.compact
    end

    # This tick's die for somebody, thrown in phase 0 (`draw_fates`).
    def fate_of(minion, key) = (@fates || {}).dig(minion.id, key) || 1.0

    # Phase 6c. What the work does to the people doing it — and what the air does to them,
    # which is the same pool and deliberately so. Bad air derates capability on the way down, so
    # somebody works worse before they drop; it recovers when they reach clean air; and
    # `endurance` is already its divisor, which is the right stat for how long a person lasts.
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
    #
    # **A hot place makes the same work cost more** (`Chill.strain`), from the air as it is felt.
    def tire(minions_state, states, controls, ctx, felt = {})
      events = []
      air = breathable_air(states)

      next_states = minions_state.to_h do |id, minion_state|
        minion = minions[id]
        next [ id, minion_state ] if minion.nil?

        fighting = Animosity.exertion(minion, minion_state)
        control = Animosity.fighting?(minion_state) ? nil : control_points[minion_state[:station]]
        demand = control ? control.demand(controls.fetch(control.id)) : 0.0
        here = air.fetch(minion_state[:place], 1.0)
        choking = Breath.rate(here, minion, minion_state)

        tired = Fatigue.advance(minion, Breath.draw(minion_state, here, minion),
                                control: control, demand: demand, dt: ctx.dt,
                                suffocation: choking,
                                burden: Burden.ratio(minion, minion_state, minions),
                                strain: Chill.strain(felt[minion_state[:place]]), fighting: fighting)
        tired, spent = Fatigue.check_spent(tired)
        events << spent_event(minion, control, ctx) if spent

        tired, mode, wounds = choke(id, tired, choking, ctx.dt)
        events << suffocated_event(minion, tired, mode, wounds, ctx) if mode
        [ id, tired.freeze ]
      end

      [ next_states, events ]
    end

    # Phase 0. **Every die this tick throws for a person, in one place, drawn unconditionally.**
    #
    # Six per minion whether any of them is used or not. A conditional draw makes the RNG
    # stream depend on the condition, and the divergence that causes does not show up here —
    # it shows up days later, on a restore, as a replay that quietly differs. Keeping the
    # count fixed and in one method is what makes that checkable: if this returns six values,
    # it drew six.
    #
    # **No two outcomes share a draw**, so they stay uncorrelated: `peril` picks which accident it
    # was and `dodge` whether the safety equipment caught it.
    #
    # Each minion draws from their own stream, so no two can race and the order they are
    # visited in cannot matter.
    def draw_fates
      minions.keys.to_h do |id|
        rng = rngs.fetch(id)
        [ id, { margin: Blunder.roll(rng), slip: rng.float,
                kind: rng.float, victim: rng.float, dodge: rng.float, peril: rng.float,
                road: rng.float, caught: rng.float } ]
      end
    end

    # Phase 0, and the same rule: **every die a temper throws, unconditionally**, from each
    # person's own temper stream, so none of the draws above moves.
    def draw_tempers
      minions.keys.to_h { |id| [ id, Animosity.draw(rngs.fetch(Animosity.stream(id))) ] }
    end

    # Phase 0 again: **the die that picks which of a tier's wounds somebody takes**, one a person a
    # tick from their own wound stream, whether or not anything hurts them.
    def draw_wounds
      minions.keys.to_h { |id| [ id, rngs.fetch(Injury.stream(id)).float ] }
    end

    # **The Danger Check, with what it needs from the tick**: the catalogue and this person's die.
    def injure(minion, minion_state, hazard)
      Injury.check(minion, minion_state, hazard, catalogue: content.wounds, die: wound_die(minion.id))
    end

    def wound_die(id) = (@wound_dice || {}).fetch(id, 0.0)

    # Phase 6d′. **What people do to each other** — after their own blunders, before anybody
    # walks, so a brawler is held where the fight is. See `Animosity::Provoke`.
    def provoke(minions_state, states, ctx)
      Animosity::Provoke.new(
        minions: minions, table: @grudges, control_points: control_points,
        opportunities: opportunities(states, ctx.dt), dice: @tempers, carried: being_carried(minions_state),
        ctx: ctx, wounds: content.wounds, wound_dice: @wound_dice,
        defence: ->(minion, s) { minion.defend(s, ambient: ambient_for(minion, s), burden: Burden.ratio(minion, s, minions)) },
        ambient: ->(minion, s) { ambient_for(minion, s) }
      ).call(minions_state)
    end

    # **Every peril somebody could be pushed into right now**, by id — in front of a tub only
    # while tubs are running.
    def opportunities(states, dt)
      perils_in_reach(states, dt).filter_map { |peril, activity| peril if peril.opportunity && activity.positive? }
                                 .sort_by(&:id)
    end

    # Phase 6d. **What the people do to themselves**, which is the route into harm that needs
    # nothing to break first.
    #
    # After `tire`, so it reads this tick's fatigue rather than last tick's. The usual argument
    # that everything must read the frozen N−1 does not apply: that rule constrains what
    # *nodes* may see of each other, and a minion's fatigue and their margin are one object
    # being advanced twice in a fixed order. After `endanger` too, so somebody already carried
    # out by an explosion this tick has no station before their own margin is weighed.
    def blunder(minions_state, states, fates, ctx)
      reaching = perils_in_reach(states, ctx.dt)
      return [ minions_state, [] ] if reaching.empty?

      events = []
      next_states = minions_state.to_h do |id, minion_state|
        minion = minions[id]
        next [ id, minion_state ] if minion.nil?

        [ id, weigh(minion, minion_state, reaching, fates, events, ctx).freeze ]
      end

      [ next_states, events ]
    end

    def weigh(minion, minion_state, reaching, fates, events, ctx)
      mine = reaching.select do |peril, _|
        peril.reaches?(minion_state[:station], minion_state[:place], carried_by(minion_state))
      end
      after, peril = Blunder.advance(mine, minion, minion_state, ctx.dt,
                                     fates.dig(minion.id, :margin) || 1.0,
                                     fates.dig(minion.id, :peril) || 0.0,
                                     ambient: ambient_for(minion, minion_state),
                                     avoid: avoid_for(minion, minion_state))
      return after if peril.nil?

      guarded = guarding(minion, minion_state, fates)
      if guarded
        events << near_miss_event(minion, minion_state, peril.id, guarded, ctx)
        return after
      end

      events << mishap_event(minion, minion_state, peril, ctx) if peril.mishap?
      return after unless peril.hurts?

      hurt, mode, wounds = injure(minion, after, peril.hazard)
      events << blundered_event(minion, hurt, mode, wounds, peril, ctx) if mode
      hurt
    end

    # **What somebody did to the machine.** Nobody is hurt and nothing has necessarily failed,
    # so neither `minion_hurt` nor `part_failed` is the transition. The part named in `detail:`
    # suffers it on the next tick's `stress`, through `state[:mishaps]` — the same one-hop delay as
    # everything else, and no second writer to node state after wear.
    def mishap_event(minion, state, peril, ctx)
      Event.build(type: :minion_mishap, node: minion.id, label: minion.name,
                  severity: :warning, tick: ctx.tick, cause: peril.id,
                  detail: { minion: minion.minion, place: state[:place], **peril.mishap })
    end

    # **What kept them out of it, or nil.** Safety equipment only helps somebody with the
    # attention to spare for it, which `Minion#wits` carries along with being able to see what
    # is coming at all.
    def guarding(minion, minion_state, fates)
      fitted = safety_equipment[minion_state[:place]] or return nil
      effectiveness, source = fitted

      return nil unless Blunder.accident_avoided?(
        effectiveness, avoid_for(minion, minion_state), fates.dig(minion.id, :dodge) || 1.0
      )

      source
    end

    # What is fitted where, as `{ place => [effectiveness, node] }`, best guard winning.
    # Configuration rather than state, so it is worked out once for the whole tick.
    def safety_equipment
      @safety_equipment ||= nodes.each_with_object({}) do |(id, node), acc|
        node.safety_equipment.each do |place, effectiveness|
          best = acc[place]
          acc[place] = [ effectiveness.to_f, id ] if best.nil? || effectiveness.to_f > best.first
        end
      end
    end

    # **The player has to be told their safety equipment worked**, or the money they spent on
    # it is indistinguishable from money they wasted. A fitting whose entire value is the
    # accidents that did *not* happen is invisible by construction unless the engine says so.
    #
    # A `warning`, so it reaches the incident feed rather than only the durable log: a near
    # miss is the operation telling the player exactly where its next casualty comes from.
    # `cause` is the peril's id, or the part whose failure it was.
    def near_miss_event(minion, state, cause, source, ctx)
      Event.build(type: :minion_near_miss, node: minion.id, label: minion.name,
                  severity: :warning, tick: ctx.tick, cause: cause,
                  detail: { minion: minion.minion, place: state[:place], saved_by: source })
    end

    # **What every place is doing to the people in it, worked out once rather than once per
    # person.** Activity rather than time: the danger of a haulage road is not being on it, it
    # is the tub going past — so running the mine harder runs it more dangerously, and
    # production and safety become the same dial. That is the central tension of the whole
    # operation and it is historically exact.
    def perils_in_reach(states, dt)
      nodes.each_with_object({}) do |(id, node), acc|
        node.perils.each do |peril|
          acc[peril] = if peril.scales_with
            node.activity(states.fetch(id), peril.scales_with, dt).to_f
          else
            1.0
          end
        end
      end
    end

    # **Reuses `minion_hurt` rather than growing a second type.** The transition is identical —
    # a Danger Check, a tier, a station possibly cleared — and the engine's job is to report
    # transitions while the delivery tier composes meaning. `cause:` carries which peril, so
    # "hurt by machinery" and "hurt by their own bad luck" are still different sentences.
    def blundered_event(minion, state, mode, wounds, peril, ctx)
      Event.build(type: :minion_hurt, node: minion.id, label: minion.name,
                  severity: :critical, tick: ctx.tick, mode: mode, cause: peril.id,
                  detail: { minion: minion.minion, lasting: Injury.lasting?(mode),
                            place: state[:place], wounds: Tick.reported(wounds, state) })
    end

    # Phase 6b′. **What the heat where somebody is standing does to them.**
    #
    # Beside `endanger` rather than inside it, because the two are different shapes: a hazard
    # is a blow delivered by a part that failed, and heat is a condition of the room that
    # grinds away for as long as somebody is in it. It grinds `resilience` directly — heat is
    # not tiredness and does not recover by standing somewhere cooler for a minute.
    #
    # **No entropy**, exactly as the Danger Check draws none.
    def scorch(minions_state, states, ctx)
      events = []
      heat = place_gas(states)
      return [ minions_state, events ] if heat.empty?

      next_states = minions_state.to_h do |id, minion_state|
        minion = minions[id]
        next [ id, minion_state ] if minion.nil?

        burned, mode, wounds = Scorch.advance(minion, minion_state, heat[minion_state[:place]], ctx.dt,
                                              catalogue: content.wounds, die: wound_die(id))
        events << burned_event(minion, burned, mode, wounds, ctx) if mode
        [ id, burned.freeze ]
      end

      [ next_states, events ]
    end

    # The gas filling each room, once per tick rather than once per person. The same node
    # `breathable_air` reads, because what you are standing in is what you are breathing.
    def place_gas(states)
      return {} if layout.places.empty?

      layout.places.each_with_object({}) do |place, acc|
        parcels = states.dig(layout.breathes(place), :parcels) or next
        gas = Scorch.gas(parcels, content) or next
        acc[place] = gas
      end
    end

    # Phase 6b″. **What the cold does to the people in it**, from the air of their place as it
    # feels — the wind on it as far as the place is open to the sky. After `scorch`, reading the
    # same rooms, so a minion is never both scorched and chilled by one tick's arithmetic in an
    # order that matters: no room is both past 318 K and below 265.
    def chill(minions_state, felt, ctx)
      events = []
      return [ minions_state, events ] if felt.empty?

      next_states = minions_state.to_h do |id, minion_state|
        minion = minions[id]
        next [ id, minion_state ] if minion.nil?

        cold, mode, wounds = Chill.advance(minion, minion_state, felt[minion_state[:place]], ctx.dt,
                                           catalogue: content.wounds, die: wound_die(id))
        events << chilled_event(minion, cold, mode, wounds, ctx) if mode
        [ id, cold.freeze ]
      end

      [ next_states, events ]
    end

    # The air of each room as a person would feel it, once per tick.
    def place_felt(states)
      return {} if layout.places.empty?

      wind = sky_before.fetch(:wind_m_s)
      place_gas(states).to_h do |place, (temperature_k, _rho_c)|
        [ place, Chill.felt_k(temperature_k, layout.exposure(place), wind) ]
      end
    end

    def chilled_event(minion, state, mode, wounds, ctx)
      Event.build(type: :minion_hurt, node: minion.id, label: minion.name,
                  severity: :critical, tick: ctx.tick, mode: mode, cause: :cold,
                  detail: { minion: minion.minion, lasting: Injury.lasting?(mode),
                            place: state[:place], chilled: state.fetch(:chilled, 0.0).round(3),
                            wounds: Tick.reported(wounds, state) })
    end

    def burned_event(minion, state, mode, wounds, ctx)
      Event.build(type: :minion_hurt, node: minion.id, label: minion.name,
                  severity: :critical, tick: ctx.tick, mode: mode, cause: :burns,
                  detail: { minion: minion.minion, lasting: Injury.lasting?(mode),
                            place: state[:place],
                            burns: state.fetch(:burns, 0.0).round(3), wounds: Tick.reported(wounds, state) })
    end

    # **The air in each room, once per tick rather than once per person.** Read off the state
    # phase 5 just produced, so a district that exploded this tick is unbreathable this tick
    # rather than next. A place is never missing an air node — `Layout` refuses to build one
    # that has none — so a fraction here is always a real reading.
    def breathable_air(states)
      # Gated on PLACES, never on passages: a room needs no way out of it to have air in it, and
      # `spatial?` answers a different question. An operation that declares no places — the steam
      # engine — gets an empty map and every lookup falls back to clean.
      return {} if layout.places.empty?

      layout.places.to_h do |place|
        air = layout.breathes(place)
        [ place, states[air] ? breathability(nodes[air], states.fetch(air)) : 1.0 ]
      end
    end

    # **Poisoned air reads as no air at all**, which is the whole difference between whitedamp
    # and every other damp: carbon monoxide does not have to displace anything, so a lungful
    # that is still almost entirely air kills just the same. Collapsing it to zero here rather
    # than in `Breath.rate` keeps the rate a function of one number and puts both ways of
    # ruining a volume of air in the same place.
    #
    # **What you breathe is the gas.** Water standing on the floor and coal in the tubs take up
    # none of a lungful; a room drowned to its roof has none left at all.
    def breathability(node, state)
      return 0.0 if node.respond_to?(:submerged?) && node.submerged?(state, content)

      gas = Parcel.matching(state.fetch(:parcels, []), [ :gas ], content)
      return 0.0 if Breath.poisoned?(gas, content)

      Breath.breathable_fraction(gas, content)
    end

    # Collapse, and then the clock. **Pinned at the fatigue ceiling is not enough on its own** —
    # a stoker flat out reaches it too and is merely spent. Pinned there *in bad air* is a
    # different thing, and the dwell from there to a mortal injury is what makes going back for
    # somebody worth doing: fix the ventilation and the clock runs backwards.
    def choke(id, state, rate, dt)
      state = Breath.advance(state, rate, dt)
      return [ state, nil, [] ] unless rate.positive? && state.fetch(:fatigue) >= Fatigue::RANGE.end

      Injury.succumb(state, Breath.suffocated?(state) ? :mortal : :severe, kind: :breath,
                                                                            catalogue: content.wounds, die: wound_die(id))
    end

    # **`cause:` is a top-level field, the same one `break_part` sets**, because the feed reads
    # it there. Inside `detail:` it is invisible to every consumer and the line reads "unknown".
    def suffocated_event(minion, state, mode, wounds, ctx)
      Event.build(type: :minion_hurt, node: minion.id, label: minion.name,
                  severity: :critical, tick: ctx.tick, mode: mode, cause: :asphyxia,
                  detail: { minion: minion.minion, lasting: Injury.lasting?(mode),
                            place: state[:place],
                            asphyxia: state.fetch(:asphyxia, 0.0).round(3), wounds: Tick.reported(wounds, state) })
    end

    # Phase 6e. Where everybody has got to.
    #
    # **Runs after `tire`, and reads no controls**, so who is standing where still comes from the
    # previous tick everywhere it matters — `crews` and `control_values` are built in
    # phase 0 from N−1, so a minion who arrives here takes up their post on the NEXT tick. That is
    # the same one-hop delay every other thing in the engine has, and it is what keeps arrival
    # from depending on phase order.
    #
    # An operation with no passages has no geometry and this is a no-op, which is what leaves the
    # steam engine bit-identical.
    # **Two passes, and the split is what keeps the phase order-independent.** A carried minion's
    # place is written by whoever is holding them, and a cross-minion write inside one `to_h` would
    # be overwritten by the carried minion's own iteration — so which won would depend on hash
    # order. Pass one walks everybody who can walk; pass two is a pure function of its output.
    #
    # Correct only because **a carried minion may not carry**: the graph is exactly one deep, so
    # stowing is a lookup rather than a traversal. `Operation#assign_minion` enforces that.
    def travel(minions_state, ctx)
      return [ minions_state, [] ] unless layout.spatial?

      carried = being_carried(minions_state)
      events = []
      walked = minions_state.to_h do |id, minion_state|
        minion = minions[id]
        # **A brawler's orders wait for the fight to end**, or a quick hand on the crew screen
        # would part every fight before its first blow.
        next [ id, minion_state ] if minion.nil? || carried.key?(id) || Animosity.fighting?(minion_state)

        after = walk(minion, minion_state, ctx, events)
        lifted(minion_state, after).each { |got| events << carried_event(minion, got, ctx) }
        [ id, after.freeze ]
      end

      [ stow(marshal(walked, minions_state), carried), events ]
    end

    # **Who a marshal lets on.** Everybody who boarded a cage this tick at a landing whose marshal is
    # posted is let on in id order while what is already aboard, as of last tick, leaves room under
    # the cage's rating; the first who does not fit and everybody after them wait. With nobody at the
    # landing, nobody is stopped. A pass of its own, after the walk, so who boarded first cannot
    # depend on the order the walk visited them in.
    def marshal(walked, before)
      boarded = walked.select { |id, s| s[:via] && before.dig(id, :via).nil? }
      return walked if boarded.empty?

      aboard = cargo
      refused = boarded.group_by { |_, s| [ s[:via], s[:place] ] }.flat_map do |(hoist, landing), group|
        passage = layout.passages.find { |p| p.hoist == hoist && p.touches?(landing) }
        room = room_aboard(passage, landing, aboard) or next []

        group.sort_by(&:first).filter_map do |id, s|
          room -= minions.fetch(id).mass_kg + Burden.load_kg(minions.fetch(id), s, minions)
          id if room.negative?
        end
      end

      walked.merge(refused.to_h { |id| [ id, walked.fetch(id).merge(via: nil, boarding_s: 0.0).freeze ] })
    end

    # Kilograms a marshalled landing will still let on, or nil where nobody is marshalling it.
    def room_aboard(passage, landing, aboard)
      station = passage&.marshals&.fetch(landing, nil)
      return nil if station.nil? || passage.rated_kg.nil? || crews[station].nil?

      passage.rated_kg - aboard.fetch(passage.hoist, 0.0)
    end

    # Who this minion picked up this tick. A set difference rather than a flag, so it cannot
    # disagree with the state it describes.
    def lifted(before, after) = Burden.carried(after) - Burden.carried(before)

    # Who is in somebody's arms, as `{ carried id => carrier id }`. Built from the frozen state at
    # the top of the phase, so it cannot see pass one's writes.
    def being_carried(minions_state)
      minions_state.each_with_object({}) do |(carrier, state), acc|
        Burden.carried(state).each { |id| acc[id] = carrier }
      end
    end

    # Cargo goes where its carrier got to, and **stops working on the way**: somebody in another
    # person's arms is not at a lever, so `station` and `posting` are cleared here. Without that a
    # casualty keeps hewing all the way to the pit bank, and would walk back to the face the moment
    # they were set down.
    #
    # Cleared every tick rather than once at pickup, because this is the single writer of a carried
    # minion's state and a lone write at pickup would be undone by their own `assign`.
    #
    # **Their `progress` and `journey` are left alone**: they are not walking, and clearing them
    # would throw away a half-finished walk that is still theirs once they are set down.
    def stow(walked, carried)
      return walked if carried.empty?

      walked.merge(carried.to_h { |id, carrier|
        here = walked.dig(carrier, :place) || walked.dig(id, :place)
        [ id, walked.fetch(id).merge(place: here, station: nil, posting: nil).freeze ]
      })
    end

    # **A posting may name a person as well as a station**, which is the whole of the fetch order:
    # `assign_minion(:crew_2, :crew_1)` sends somebody to wherever `crew_1` is, and the id spaces
    # cannot collide because every id in an operation is one flat namespace.
    def walk(minion, state, ctx, events)
      return ride(minion, state, ctx, events) if state[:via]

      destination = posted_place(minion, state)
      here = minion.place(state)
      # A posting with no place, or none at all, is worked from wherever they are standing.
      return reached(minion, state) if destination.nil? || destination == here

      step(minion, embark(minion, state, here, destination), here, destination, ctx)
    end

    # Where a posting resolves to: a lever's room, or whichever room the person named is in now.
    # Reading the casualty's **frozen** place is what lets a rescuer re-route for free when their
    # casualty is moved by somebody else.
    def posted_place(minion, state)
      posting = minion.posting(state)
      return layout.place_of(posting) unless minions.key?(posting)

      state_of(posting)&.fetch(:place, nil)
    end

    def state_of(id) = state.fetch(:minions)[id]

    # **`journey` is the high-water mark of how far there was left to go, measured BEFORE this
    # tick's walking** — taken after it, the first tick's strides are missing from the total and
    # everybody arrives short of the far end of their own bar.
    #
    # A high-water mark rather than a remembered starting point is what lets somebody re-ordered
    # to a farther face have their bar start again instead of reading past full, without the
    # walk having to know it was re-ordered.
    def embark(minion, state, here, destination)
      setting_out = left(minion, state, here, destination, state.fetch(:progress, 0.0))

      state.merge(journey: [ state.fetch(:journey, 0.0), setting_out ].max)
    end

    # **Arriving at a person is a pickup; arriving at a lever is taking up a post.** The two are
    # different enough to be worth the branch: a fetch order is *consumed* on arrival, because
    # holding somebody is not a job and leaving a minion id in `station` would read as "working
    # Jim" to the panel and as off-post to `tire`.
    def reached(minion, state)
      posting = minion.posting(state)
      return pick_up(minion, state, posting) if minions.key?(posting)

      state.merge(station: posting, progress: 0.0, remaining: 0.0, journey: 0.0)
    end

    # Silent on failure, and deliberately. Somebody else having got there first, or a load that
    # will not fit after all, is a rescuer standing in a district with empty hands — which the
    # crew screen already shows. An event for it would be a type nothing reads.
    def pick_up(minion, minion_state, casualty)
      stood_down = minion_state.merge(posting: nil, station: nil, progress: 0.0,
                                      remaining: 0.0, journey: 0.0)
      return stood_down unless liftable?(minion, minion_state, casualty)

      stood_down.merge(carrying: (Burden.carried(minion_state) + [ casualty ]).freeze)
    end

    # Reads the FROZEN roster for who is already carried, so two rescuers sent to one casualty
    # cannot both succeed depending on which was visited first. `minion_state` is this carrier's
    # own hash and `state` is the whole previous tick — naming them apart matters here, because
    # one of them has a `:minions` key and the other does not.
    def liftable?(minion, minion_state, casualty)
      return false if being_carried(state.fetch(:minions)).key?(casualty)
      return false if Burden.carrying?(state_of(casualty) || {})

      Burden.liftable?(minion, minion_state, minions, minions[casualty])
    end

    # One tick's walking, which may cross more than one passage if the stretches are short or the
    # clock is fast. **Distance carries over between them** rather than being discarded at each
    # place, or a mine run at a high `time_scale` would advance one passage per tick however long
    # the tick was.
    def step(minion, state, here, destination, ctx)
      remaining = minion.pace(state, burden: Burden.ratio(minion, state, minions)) * ctx.dt
      progress = state.fetch(:progress, 0.0)

      while remaining.positive? && here != destination
        hop = layout.next_hop(here, destination, routing.fetch(minion.id, []), closed_ways)
        passage = hop && quickest(here, hop, ctx)
        # No way on, or the only ways on are powered and stopped. They wait where they are,
        # which is what being stranded underground looks like.
        break if passage.nil?
        # A cage is boarded, not walked: they wait at the landing until it is here.
        return board(minion, state, passage, here, progress) if passage.ridden?

        speed = passage.speed_in(ctx)
        break unless speed.positive?

        travelled = remaining * speed
        if progress + travelled < passage.metres
          progress += travelled
          break
        end

        remaining -= (passage.metres - progress) / speed
        here = hop
        progress = 0.0
      end

      at_post = here == destination
      on = passage&.driven_by if !at_post && progress.positive? && passage&.powered?
      minion.advance_to(state, place: here, progress: at_post ? 0.0 : progress,
                               remaining: at_post ? 0.0 : left(minion, state, here, destination, progress),
                               station: at_post ? minion.posting(state) : nil)
            .merge(riding: on)
    end

    # What is carrying somebody through the shaft — a cage they are in, or the rods they are
    # stepping on — which is how a `riders:` hazard or peril finds them.
    def carried_by(minion_state) = minion_state[:via] || minion_state[:riding]

    # How much walking is left, for the panel rather than for the walking. `assign_minion`
    # refuses a posting there is no way to, so a missing route means the ways out have changed
    # under somebody already walking — they hold where they are, and so does their progress.
    def left(minion, state, here, destination, progress)
      route = layout.route_metres(here, destination, routing.fetch(minion.id, []), closed_ways)
      return state.fetch(:remaining, 0.0) if route.nil?

      [ route - progress, 0.0 ].max
    end

    # Somebody takes the quickest way that is actually running. With the cage stopped that is
    # the ladderway; with it going it is the cage. **Ties break on declaration order**, so a
    # layout stays deterministic when two ways are equally good. A cage nobody is winding is not
    # running at all.
    def quickest(here, hop, ctx)
      layout.passages_between(here, hop)
            .select { |p| !p.closed_by?(closed_ways) && in_service?(p, ctx) }
            .max_by { |p| p.speed_in(ctx) }
    end

    # **What is in the way**: every node some passage runs through that is blocking it, as of
    # last tick. A choked shaft closes the ladders and the cage in it alike, a flooded pit bottom
    # every way that runs through it, and routing finds another way out if the pit has one.
    def closed_ways
      @closed_ways ||= layout.through_nodes.select { |id|
        nodes.fetch(id).blocks_passage?(state.dig(:nodes, id), content)
      }.freeze
    end

    # A ridden way is running while somebody is winding it, the drum is sound, and whatever drives
    # it is turning — a cage with no power behind it is not a way down at all.
    def in_service?(passage, ctx)
      return true unless passage.ridden?
      return false if crews[passage.staffed_by].nil?
      return false if wrecked?(passage)
      return true unless passage.driven_by && passage.rated_omega&.positive?

      ctx.node_omega(passage.driven_by).to_f >= passage.rated_omega * DRIVEN_IN_SERVICE
    end

    # **Waiting at a landing, and stepping in when the cage is there and stopped.** From the
    # drum's frozen last-tick state. Once aboard, `via` names the drum and the rider is wherever
    # the cage is until it stops at a landing on their way.
    def board(minion, state, passage, here, progress)
      unless cage_at?(passage, here)
        return minion.advance_to(state, place: here, progress: progress,
                                        remaining: state.fetch(:remaining, 0.0))
      end

      minion.advance_to(state, place: here, progress: 0.0, remaining: passage.metres)
            .merge(via: passage.hoist, boarding_s: Nodes::Hoist::BOARDING_S)
    end

    # Aboard: where the cage is, until it stops at the far landing — or back at the one they got on
    # at, if that is where they are going now or if the cage has stopped running there.
    def ride(minion, state, ctx, events)
      here = minion.place(state)
      passage = layout.passages.find { |p| p.hoist == state[:via] && p.touches?(here) }
      return state.merge(via: nil, boarding_s: 0.0) if passage.nil?
      return alight(minion, state, nearest_landing(passage)) if wrecked?(passage)
      return boarding(minion, state, passage, here, ctx, events) if state.fetch(:boarding_s, 0.0).positive?

      far = passage.other(here)
      return alight(minion, state, far) if cage_at?(passage, far)
      if cage_at?(passage, here) && (posted_place(minion, state) == here || !in_service?(passage, ctx))
        return alight(minion, state, here)
      end

      travelled = (cage_position(passage) - passage.landing_m(here)).abs
      minion.advance_to(state, place: here, progress: travelled,
                               remaining: [ passage.metres - travelled, 0.0 ].max)
    end

    # **Still getting in.** With the cage stopped at the landing it is a few seconds; wound away
    # meanwhile, they are caught between the cage and the shaft side and left at the landing hurt.
    def boarding(minion, state, passage, here, ctx, events)
      if cage_at?(passage, here)
        return state.merge(boarding_s: [ state.fetch(:boarding_s) - ctx.dt, 0.0 ].max)
      end

      hazard = nodes.fetch(passage.hoist).boarding_hazard
      return alight(minion, state.merge(boarding_s: 0.0), here) if hazard.nil?

      dealt = { wounds: Wounds.dealt(hazard.fetch(:wounds), hazard.fetch(:severity)), causes: Array(hazard[:causes]) }
      hurt, mode, wounds = injure(minion, state, dealt)
      events << caught_boarding_event(minion, hurt, mode, wounds, ctx) if mode
      alight(minion, hurt.merge(boarding_s: 0.0), here)
    end

    def caught_boarding_event(minion, state, mode, wounds, ctx)
      Event.build(type: :minion_hurt, node: minion.id, label: minion.name,
                  severity: :critical, tick: ctx.tick, mode: mode, cause: :caught_boarding,
                  detail: { minion: minion.minion, lasting: Injury.lasting?(mode), wounds: Tick.reported(wounds, state),
                            place: state[:place] })
    end

    def alight(minion, state, place)
      arrived = minion.advance_to(state.merge(via: nil), place: place, progress: 0.0, remaining: 0.0)
      posted_place(minion, arrived) == place ? reached(minion, arrived) : arrived
    end

    # A cage that has hit the end of its shaft, or whose rope has parted, is not going anywhere:
    # whoever is in it gets out where it ended, and the failure's own hazards have already found
    # them. A rope that parts with nothing to grip the guides drops the cage to the bottom.
    def wrecked?(passage)
      drum = nodes.fetch(passage.hoist)
      drum.broken?(state.dig(:nodes, passage.hoist)) || rope_parted?(drum)
    end

    def rope_parted?(drum) = !drum.rope.nil? && nodes.fetch(drum.rope).broken?(state.dig(:nodes, drum.rope))

    def nearest_landing(passage)
      drum = nodes.fetch(passage.hoist)
      return passage.b if rope_parted?(drum) && !drum.catches?

      cage_position(passage) < passage.metres / 2.0 ? passage.a : passage.b
    end

    def cage_position(passage)
      drum = nodes.fetch(passage.hoist)
      drum.cage_m(state.fetch(:nodes).fetch(passage.hoist))
    end

    def cage_at?(passage, place)
      nodes.fetch(passage.hoist).cage_stopped_at?(state.fetch(:nodes).fetch(passage.hoist),
                                                   passage.landing_m(place))
    end

    # **A rescue reaching its casualty, which the engine did on its own.** The order was given
    # minutes earlier and somewhere else, so the moment it is fulfilled is a transition worth the
    # durable record — `:info`, because the crew screen is already showing who is holding whom and
    # the incident feed is for what has gone wrong.
    #
    # Setting somebody down gets no event: the player pressed the button and knows where they were
    # standing when they did.
    def carried_event(minion, casualty, ctx)
      Event.build(type: :minion_carried, node: minion.id, label: minion.name,
                  severity: :info, tick: ctx.tick, cause: :rescue,
                  detail: { minion: minion.minion, casualty: casualty,
                            place: state_of(casualty)&.fetch(:place, nil) })
    end

    # The person and the post, the same split `hurt_event` makes: the post outlives whoever was
    # standing at it, and a consumer given only the job could not say who needs a rest.
    def spent_event(minion, control, ctx)
      Event.build(type: :minion_spent, node: minion.id, label: minion.name,
                  severity: :warning, tick: ctx.tick, cause: :exhaustion,
                  detail: { minion: minion.minion, station: control&.id })
    end

    # Severity ADDS where two failures endanger one station on the same tick, because two things
    # letting go beside somebody is worse than either. Tags union, so gear that resists one of
    # them still helps.
    #
    # **Two keys, and `places:` is the one that says the true thing.** A hazard keyed by station
    # says somebody was hurt because of the job they were doing; a boiler letting go hurts
    # whoever is in the engine room, and misses the fireman who left two minutes ago. Both are
    # legal — an operation with no geometry has only stations to name — and a minion is looked up
    # in each, which is what lets a machine be moved onto places without moving all of them at
    # once. See `docs/design_sketches/breathable-air.md` §5.
    def hazards_from(wear_events)
      exposure = Exposure.new(stations: {}, places: {}, riders: {}, alongs: [])

      wear_events.each do |event|
        node = nodes[event[:node]]
        next unless node.respond_to?(:failure_hazards)

        declared = node.failure_hazards[event[:mode]] or next
        scale = hazard_scale(declared, event)

        exposure.alongs << [ declared, scale, event[:node] ] if declared[:along]
        accrue(exposure.stations, :station, declared[:stations], declared, scale, event[:node])
        accrue(exposure.places, :place, declared[:places], declared, scale, event[:node])
        accrue(exposure.riders, :via, declared[:riders], declared, scale, event[:node])
      end

      exposure.places.replace(carried(exposure.places)) unless exposure.places.empty?
      exposure
    end

    # **A carried place shares hazards with the place it stands in**, by its `shares:`, both ways —
    # a boiler bursting on a footplate reaches the bench it stands beside, and a boom coming down
    # on the bench reaches the train under it. Where it stands is its carrier's last tick, and each
    # share is taken from the hazards before any sharing, so nothing is counted twice and the order
    # places are walked in cannot matter.
    def carried(places)
      shared = places.dup
      layout.carried_places.each do |place|
        share = place.shares.to_f
        next unless share.positive?

        host = nodes.fetch(place.carried_by).place_at(state.fetch(:nodes).fetch(place.carried_by)) or next
        [ [ place.id, host ], [ host, place.id ] ].each do |from, to|
          at = places[from] or next
          passed = at.merge(place: to, wounds: at.fetch(:wounds).transform_values { |severity| severity * share })
          shared[to] = shared[to] ? Tick.combined(shared[to], passed) : passed
        end
      end
      shared
    end

    def accrue(index, key_name, weights, declared, scale, source)
      (weights || {}).each do |key, weight|
        at = index[key] ||= { key_name => key, wounds: {}, causes: [], sources: [] }
        at[:wounds] = at[:wounds].merge(Wounds.dealt(declared.fetch(:wounds), weight.to_f * scale)) { |_, a, b| a + b }
        at[:causes] |= Array(declared[:causes])
        at[:sources] |= [ source ]
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
    # everything inside the operation is keyed by. But **wounds belong to a person**: Jim is out
    # healing for two matches, and the fireman's job is still there for somebody else to stand
    # in. A consumer given only the role could not write that down.
    # **`cause:` is the KIND of harm, not the part.** "Rockfall" is what a player needs to read
    # off the feed; which node's failure delivered it is already on the record as `by:`. With no
    # cause it is the first kind of wound, and the part only as a last resort, because "unknown"
    # next to a dead minion is the one thing the line must never say.
    def hurt_event(minion, hurt, mode, wounds, hazard, ctx)
      Event.build(type: :minion_hurt, node: minion.id, label: minion.name,
                  severity: Injury::MODES.dig(mode, :stood_down) ? :critical : :warning,
                  tick: ctx.tick, mode: mode,
                  cause: hazard[:cause] || hazard.fetch(:causes, []).first || hazard.fetch(:wounds).keys.min ||
                         hazard[:sources].first,
                  detail: { minion: minion.minion,
                            lasting: Injury.lasting?(mode),
                            station: hazard[:station],
                            place: hazard[:place],
                            by: hazard[:sources],
                            wounds: Tick.reported(wounds, hurt),
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
        [ id, diagnostic.record(current.fetch(id), nodes, node_states, ctx, rngs.fetch(id),
                                competence: reading_competence(diagnostic)).freeze ]
      end
    end

    # **How well whoever is watching this instrument can read it**, or nil when nobody is.
    #
    # `observer:` names a **station**, never a minion, the same rule `endangers:` follows and
    # for the same reason: a station is fixed by the machine and a roster is the player's. An
    # instrument that names none is a dial on a wall and reads 1.0 — which is every gauge in
    # the game but the few where the reading is somebody's word. **A crew reads a dial as well as
    # its sharpest member.**
    def reading_competence(diagnostic)
      station = diagnostic.observer or return 1.0
      crew = crews[station] or return nil

      crew.map { |id|
        minion_state = state.fetch(:minions).fetch(id)
        minion = minions.fetch(id)
        minion.wits(minion_state, ambient: ambient_for(minion, minion_state, @ambient || {}))
      }.max
    end
  end
end
