# frozen_string_literal: true

module ReactorSim
  module Operations
    module MobileEngine
      # **A steam shovel's dipper**: a bucket on a hoisting chain at the end of a boom, going round
      # dig, swing, dump, swing back. A holder of its own — a dipperful at a time — driven by its
      # engine's shaft and filled as hard as the craneman sets the cut. See
      # `docs/design_sketches/steam-shovel.md` §14.
      #
      # **The engine pays for the cut, the lift and the swing** as drags on its shaft, so hard
      # ground slows the engine and the shovel digs slower as well as dearer — nothing else decides
      # that. The swings are time at the shaft's speed, so a struggling engine is a slow shovel all
      # round. A full car holds it at dumping, an empty reach at digging.
      #
      # It also writes **the shovel's board** (`signal`), from the engine's last tick and its own:
      # what the crew would shout, for a prose display.
      class Dipper < Node
        include Concerns::Thermal
        include Concerns::Holds
        include EngineBoard

        PHASES = %i[digging swinging dumping returning].freeze

        # A bucket's own iron, which the chain lifts with the load.
        DIPPER_KG = 1_200.0
        # How fast the chain draws the dipper up through the cut at the shaft's rated speed.
        HOIST_M_PER_S = 1.0
        # Filled this close to its capacity, it swings.
        FULL_SHARE = 0.98

        # The first that holds, in order.
        SIGNALS = {
          boom_down: "boom down",
          chain_parted: "chain parted",
          splicing: "splicing the chain",
          standing: "standing — fire out",
          out_of_water: "out of water",
          short_of_water: "short of water",
          short_of_steam: "short of steam",
          blowing_off: "blowing off",
          chain_worn: "chain worn",
          moving_up: "moving up",
          waiting_on_cars: "waiting on cars",
          standing_by: "standing by",
          digging: "digging"
        }.freeze

        attr_reader :heat_capacity, :ambient_conductance, :initial_temperature_k, :ambient_k, :volume_m3,
                    :capacity_kg, :fill_kg_per_s, :swing_s, :lift_m, :work_j_per_kg, :swing_w, :driven_by,
                    :rated_omega, :crane_control, :demand_control, :chain, :boom, :engine, :perils

        # `engine:` is the names of the pieces the board reads — `{ boiler:, supply:, firebox:, relief: }`
        # — with the boiler's `working_pa:`; `reach:` the holder it digs from.
        def initialize(id:, capacity_kg:, fill_kg_per_s:, swing_s:, lift_m:, work_j_per_kg:, swing_w:, driven_by:,
                       rated_omega:, crane_control:, demand_control:, chain:, boom:, engine:, reach:,
                       perils: [], label: "Dipper", heat_capacity: 6.0e5, ambient_conductance: 20.0)
          super(id: id, label: label, ports: [
            Port.new(id: :in, direction: :inlet, accepts: [ :solid ], max_kg_per_s: fill_kg_per_s * 2.0),
            Port.new(id: :out, direction: :outlet, accepts: [ :solid ], max_kg_per_s: capacity_kg)
          ])
          @capacity_kg = capacity_kg.to_f
          @fill_kg_per_s = fill_kg_per_s.to_f
          @swing_s = swing_s.to_f
          @lift_m = lift_m.to_f
          @work_j_per_kg = work_j_per_kg.to_f
          @swing_w = swing_w.to_f
          @driven_by = driven_by.to_sym
          @rated_omega = rated_omega.to_f
          @crane_control = crane_control.to_sym
          @demand_control = demand_control.to_sym
          @chain = chain.to_sym
          @boom = boom.to_sym
          @engine = engine.freeze
          @reach = reach.to_sym
          @perils = perils.freeze
          @heat_capacity = heat_capacity.to_f
          @ambient_conductance = ambient_conductance.to_f
          @initial_temperature_k = Units::STANDARD_TEMPERATURE_K
          @ambient_k = Units::STANDARD_TEMPERATURE_K
          # Roomy enough for a heaped dipperful of the lightest ground it digs.
          @volume_m3 = capacity_kg / 1_200.0
          freeze
        end

        def base_initial_state(rng, content)
          super.merge(phase: 0, phase_s: 0.0, dug_kg: 0.0, tension_n: 0.0, signal: 0)
        end

        def phase(state) = PHASES.fetch(state.fetch(:phase))
        def swinging?(state) = %i[swinging returning].include?(phase(state))

        # **Whether it can work at all**: chain whole, boom up.
        def working?(ctx)
          (ctx.node_state(@chain) || {})[:failure].nil? && (ctx.node_state(@boom) || {})[:failure].nil?
        end

        def speed(ctx) = (ctx.node_omega(@driven_by).to_f / @rated_omega).clamp(0.0, 1.0)

        # **Both ports, always**: a holder that declared nothing would let the path drive the flow,
        # and the bench would pour through the dipper into the car. A zero is a shut door.
        def plan(state, ctx)
          working = working?(ctx)
          digging = working && phase(state) == :digging
          dumping = working && phase(state) == :dumping
          crane = (ctx.controls.fetch(@crane_control, 0.0) / 100.0).clamp(0.0, 1.0)
          want = [ @fill_kg_per_s * speed(ctx) * crane * ctx.dt, @capacity_kg - contents_kg(state) ].min
          Intent.new(draws: { in: digging ? [ want, 0.0 ].max : 0.0 }, pushes: { out: dumping ? contents_kg(state) : 0.0 })
        end

        def apply(state, ctx, grant)
          dug = grant.received_kg(:in)
          held = contents_kg(state)
          state = state.merge(dug_kg: dug, tension_n: tension_n(held, dug, ctx))
          state = advance(state, held, ctx) if working?(ctx)
          state.merge(signal: SIGNALS.keys.index(signal(state, ctx)))
        end

        # **What the engine pays**, from last tick: the lift leaves as work, the cut and the swing as
        # loss. As conductances on the shaft, like any driven fitting, so the solve stays stable.
        def drag_shaft = @driven_by

        def drag_conductances(state, ctx)
          omega = ctx.node_omega(@driven_by).to_f
          return {} unless omega.positive? && ctx.dt.positive?

          rate = state.fetch(:dug_kg) / ctx.dt
          lift_w = rate * Units::GRAVITY_M_PER_S2 * @lift_m
          loss_w = (rate * @work_j_per_kg) + (swinging?(state) ? @swing_w * speed(ctx) : 0.0)
          { work: lift_w / (omega**2), friction: loss_w / (omega**2) }.select { |_, c| c.positive? }
        end

        # How busy it is, for a peril spent by its swing.
        def activity(state, quantity, _dt) = quantity == :swinging && swinging?(state) ? 1.0 : nil

        private

        def advance(state, held, ctx)
          case phase(state)
          when :digging then held >= @capacity_kg * FULL_SHARE ? begin_phase(state, :swinging) : state
          when :swinging then timed(state, ctx, :dumping)
          when :dumping then held <= Parcel::EPSILON ? begin_phase(state, :returning) : state
          else timed(state, ctx, :digging)
          end
        end

        def timed(state, ctx, onward)
          spent = state.fetch(:phase_s) + (ctx.dt * speed(ctx))
          spent >= @swing_s ? begin_phase(state, onward) : state.merge(phase_s: spent)
        end

        def begin_phase(state, phase) = state.merge(phase: PHASES.index(phase), phase_s: 0.0)

        # **What the chain carries**: the dipper and its load, and the cut it is drawn through —
        # the cut's power over the hoisting speed, so a slowing engine in hard ground pulls hardest.
        def tension_n(held, dug, ctx)
          hoist = HOIST_M_PER_S * [ speed(ctx), 0.1 ].max
          cut_n = ctx.dt.positive? ? (dug / ctx.dt) * @work_j_per_kg / hoist : 0.0
          ((DIPPER_KG + held) * Units::GRAVITY_M_PER_S2) + cut_n
        end

        def signal(state, ctx)
          boom = ctx.node_state(@boom) || {}
          chain = ctx.node_state(@chain) || {}
          return :boom_down if boom[:failure]
          return (chain.fetch(:splicing, 0.0).positive? ? :splicing : :chain_parted) if chain[:failure]

          engine_signal(ctx) || work_signal(state, ctx, chain)
        end

        def work_signal(state, ctx, chain)
          return :chain_worn if chain[:worn]
          return :standing_by unless ctx.controls.fetch(@demand_control, 0.0).positive?
          return :moving_up if phase(state) == :digging && Parcel.total_kg((ctx.node_state(@reach) || {}).fetch(:parcels, [])) <= Parcel::EPSILON
          return :waiting_on_cars if phase(state) == :dumping && contents_kg(state).positive?

          :digging
        end
      end

      # **The hoisting chain**, worn by the dipper's digging and parted by a snatch past what is left
      # of it — the cut's pull when the ground is harder than she was digging. Parted, the dipper
      # comes down on whoever is under it, and the pitmen splice it.
      #
      # **An iron chain shows its wear and a steel one does not** (`shows_wear:`): iron was the
      # period's choice because it gave warning, steel "suffered rapid wear and frequent breakages"
      # (Hermann).
      class Chain < Node
        include Concerns::Wearing

        # A snatch: what a hard bite pulls the chain to, against the steady draw.
        SNATCH = 2.0
        # Integrity under which a chain that shows its wear is seen to be worn.
        WORN = 0.6
        # Seconds of a pitman's work to splice a parted chain.
        SPLICE_S = 480.0

        attr_reader :dipper, :breaking_kn, :wear_per_s, :shows_wear, :splice_control, :failure_hazards,
                    :failure_damages

        def initialize(id:, dipper:, breaking_kn:, wear_per_s:, shows_wear:, splice_control:, endangers: {},
                       label: "Hoisting Chain")
          super(id: id, label: label)
          @dipper = dipper.to_sym
          @breaking_kn = breaking_kn.to_f
          @wear_per_s = wear_per_s.to_f
          @shows_wear = shows_wear
          @splice_control = splice_control.to_sym
          @failure_hazards = endangers.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          @failure_damages = {}.freeze
          freeze
        end

        def base_initial_state(rng, content) = super.merge(splicing: 0.0, worn: false)

        def failure_modes = { parted: {} }

        def failure_detail(_state, ctx) = { tension_n: dipper_state(ctx).fetch(:tension_n, 0.0).round }

        # Wear by digging, scaled by how hard the chain is drawn against what it was made for.
        def stress_per_second(_state, ctx)
          dug = dipper_state(ctx).fetch(:dug_kg, 0.0)
          return 0.0 unless dug.positive?

          @wear_per_s * (dipper_state(ctx).fetch(:tension_n) / (@breaking_kn * 1_000.0))
        end

        def overload?(_state, ctx, integrity)
          dipper_state(ctx).fetch(:dug_kg, 0.0).positive? &&
            SNATCH * dipper_state(ctx).fetch(:tension_n) > @breaking_kn * 1_000.0 * integrity
        end

        def apply(state, ctx, _grant)
          state = state.merge(worn: @shows_wear && integrity(state) < WORN)
          broken?(state) ? splice(state, ctx) : state
        end

        private

        def dipper_state(ctx) = ctx.node_state(@dipper) || {}

        def splice(state, ctx)
          work = [ ctx.controls.fetch(@splice_control, 0.0) / 100.0, 0.0 ].max
          progress = state.fetch(:splicing) + (work * ctx.dt / SPLICE_S)
          return state.merge(splicing: progress) if progress < 1.0

          state.merge(failure: nil, durability: state.fetch(:initial_durability), splicing: 0.0)
        end
      end

      # **The boom**, which takes the crowd and the cut. It fatigues when the dipper is forced through
      # ground past what it was built for, and comes down when it is spent: a wreck, and the shovel
      # out for the match. Anything else that fails may damage it (`damages:` — a slide, unit 5).
      class Boom < Node
        include Concerns::Wearing

        attr_reader :dipper, :rated_n, :fatigue_per_s, :failure_hazards, :failure_damages

        def initialize(id:, dipper:, rated_n:, fatigue_per_s:, endangers: {}, label: "Boom")
          super(id: id, label: label)
          @dipper = dipper.to_sym
          @rated_n = rated_n.to_f
          @fatigue_per_s = fatigue_per_s.to_f
          @failure_hazards = endangers.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          @failure_damages = {}.freeze
          freeze
        end

        def failure_modes = { down: {} }

        def failure_detail(_state, ctx) = { tension_n: (ctx.node_state(@dipper) || {}).fetch(:tension_n, 0.0).round }

        # Nothing within its rating; past it, by how far.
        def stress_per_second(_state, ctx)
          over = ((ctx.node_state(@dipper) || {}).fetch(:tension_n, 0.0) / @rated_n) - 1.0
          over.positive? ? @fatigue_per_s * over : 0.0
        end
      end
    end
  end
end
