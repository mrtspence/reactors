# frozen_string_literal: true

module ReactorSim
  module Nodes
    # **The winding rope**, hung from a hoist's drum over a sheave. It holds nothing and turns with
    # nothing; it wears, and one day it parts.
    #
    # What wears it, every second, from conditions rather than dice:
    #
    #   bending     every metre it runs over the sheave, harder the more it is carrying
    #   corrosion   all the time, faster in a wet shaft — `wet_by:` names a node with a `ground`
    #   heat        a sheave running hot drags the rope over itself; past `HOT_SHEAVE_K` it scores
    #   kinks       a snatch, per metre of slack the cage fell
    #
    # It parts on **overload**: the tension — the cage, its load and its acceleration, or the
    # snatch when a hung cage falls its slack — past what is left of its breaking strain. A worn
    # rope parts under a load a new one would have carried.
    #
    # ## What the shaft can do about it
    #
    # **Recapping** (`recap_control:`) cuts off the worn end and makes it good again, while the cage
    # is stopped at bank; the rope is shorter every time, and with `spare_m` gone it does nothing.
    # **Re-roping** (`renew_control:`) puts a new rope on from the spare (`spare:`), once enough work
    # has gone into it — a fresh rope at full length, even in place of one that has parted.
    #
    # **What it is made of is its own config** — `breaking_kn`, `kg_per_m`, `stiffness_n_per_m` and
    # its wear rates — so a hemp rope and a steel one are the same node. **What hangs on it is the
    # drum's**: the cage's mass and whether the cage carries safety catches, read off `hoist:`.
    # Parted, it fails `parted` with the cage falling, or `parted_held` where the catches grip the
    # guides; hazards and wreckage per mode are the machine's to declare.
    #
    # **Its own weight is load.** The rope hanging below the sheave pulls on it as the cage does,
    # so a heavy rope in a deep shaft strains itself with the cage empty, and what the sheave
    # carries is both sides of the drum (`bearing_load_n`).
    #
    #   config: hoist, breaking_kn, kg_per_m, sheave, wet_by, recap_control, renew_control, spare,
    #           bend_per_m, corrode_per_s, stiffness_n_per_m, endangers, damages
    #   state:  durability, failure, spare_m, renewing_s, renewed
    class Rope < Node
      include Concerns::Wearing

      # Durability per metre run over the sheave at the tension `breaking_kn` is rated against
      # carrying a working load — about four hundred full winds of this shaft.
      BEND_PER_M = 0.025

      # Durability per second in an ordinary shaft. A wet one is worse by its `ground`.
      CORRODE_PER_S = 0.02

      # Past this the sheave is scoring the rope, per kelvin per second.
      HOT_SHEAVE_K = 380.0
      SCORED_PER_K_S = 0.05

      # What a working load is, as a share of the breaking strain: the rope's bending wear is rated
      # against it.
      WORKING_SHARE = 0.15

      # Recapping: durability restored, and rope spent, per second of somebody fully at it.
      RECAP_PER_S = 1.5
      RECAP_SPENT_M_PER_S = 0.05
      SPARE_M = 20.0

      # Seconds of somebody fully at it to put a new rope on.
      RENEW_S = 240.0

      # Durability a snatch takes, per metre of slack the cage fell.
      KINK_PER_M = 30.0

      # N/m: steel winding rope, ninety metres of it.
      STIFFNESS_N_PER_M = 8.0e5

      attr_reader :hoist, :breaking_kn, :kg_per_m, :sheave, :wet_by, :recap_control, :renew_control,
                  :spare, :stiffness_n_per_m

      def initialize(id:, hoist:, breaking_kn:, kg_per_m: 0.0, label: nil, sheave: nil, wet_by: nil,
                     recap_control: nil, renew_control: nil, spare: nil,
                     bend_per_m: BEND_PER_M, corrode_per_s: CORRODE_PER_S,
                     stiffness_n_per_m: STIFFNESS_N_PER_M, endangers: {}, damages: {})
        super(id: id, label: label)
        @stiffness_n_per_m = stiffness_n_per_m.to_f
        @hoist = hoist.to_sym
        @breaking_kn = breaking_kn.to_f
        @kg_per_m = kg_per_m.to_f
        @bend_per_m = bend_per_m.to_f
        @corrode_per_s = corrode_per_s.to_f
        @sheave = sheave&.to_sym
        @wet_by = wet_by&.to_sym
        @recap_control = recap_control&.to_sym
        @renew_control = renew_control&.to_sym
        @spare = spare&.to_sym
        @failure_hazards = endangers.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
        @failure_damages = damages.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
        freeze
      end

      attr_reader :failure_hazards, :failure_damages

      def base_initial_state(rng, content)
        super.merge(spare_m: SPARE_M, renewing_s: 0.0, renewed: 0)
      end

      # --- what it is carrying ---------------------------------------------------------------

      # Newtons in the rope at the cage, read off the drum as of last tick: nothing while the cage
      # hangs; its weight, what is in it and the rope below the sheave, plus what it takes to
      # accelerate them, while it rides; and the snatch on the tick it falls its slack.
      def tension_n(ctx)
        drum = ctx.nodes.fetch(@hoist)
        drum_state = ctx.states.fetch(@hoist)
        return 0.0 if drum.hung?(drum_state)

        mass = drum.cage_kg + drum.cargo_kg(ctx) + hanging_kg(drum.cage_m(drum_state))
        fallen = drum.snatch_m(drum_state)
        return Rope.snatch_n(mass, fallen, @stiffness_n_per_m) if fallen.positive?

        mass * (Units::GRAVITY_M_PER_S2 + drum.acceleration_m_s2(drum_state).abs)
      end

      # The rope below the sheave on a side that reaches `depth_m` down the shaft.
      def hanging_kg(depth_m) = @kg_per_m * [ depth_m, 0.0 ].max

      # **What the sheave carries**: both sides of the drum — cage A on this rope, the empty cage B
      # and its rope on the other — each pressing the journal with √2 of its pull over a quarter
      # turn of wrap. Read by a `Bearing` that names this rope as `loaded_by:`.
      def bearing_load_n(ctx)
        drum = ctx.nodes.fetch(@hoist)
        drum_state = ctx.states.fetch(@hoist)
        other = (drum.cage_kg + hanging_kg(drum.depth_m - drum.cage_m(drum_state))) *
                Units::GRAVITY_M_PER_S2

        Math.sqrt(2.0) * (tension_n(ctx) + other)
      end

      # **A mass falling `h` onto a rope of stiffness `s`**: `T = mg + √((mg)² + 2·s·mg·h)`, which
      # is exactly twice the static load at no slack at all and climbs with the root of the slack.
      def self.snatch_n(mass_kg, fallen_m, stiffness_n_per_m)
        weight = mass_kg * Units::GRAVITY_M_PER_S2
        weight + Math.sqrt((weight**2) + (2.0 * stiffness_n_per_m * weight * fallen_m))
      end

      def breaking_n = @breaking_kn * 1_000.0

      def overload?(_state, ctx, integrity) = tension_n(ctx) > breaking_n * integrity

      # --- what wears it --------------------------------------------------------------------

      def stress_per_second(_state, ctx)
        drum = ctx.nodes.fetch(@hoist)
        running = drum.speed_m_s(ctx.states.fetch(@hoist)).abs
        loaded = tension_n(ctx) / (breaking_n * WORKING_SHARE)

        (@bend_per_m * running * loaded) + (@corrode_per_s * wetness(ctx)) + scoring(ctx) + kinking(ctx)
      end

      # A snatch kinks the rope where it took it, per metre of slack fallen, once.
      def kinking(ctx)
        drum = ctx.nodes.fetch(@hoist)
        KINK_PER_M * drum.snatch_m(ctx.states.fetch(@hoist)) / ctx.dt
      end

      def wetness(ctx)
        return 1.0 unless @wet_by

        node = ctx.nodes.fetch(@wet_by)
        node.respond_to?(:ground) ? node.ground(ctx.states.fetch(@wet_by)) : 1.0
      end

      def scoring(ctx)
        return 0.0 unless @sheave

        over = ctx.node_temperature(@sheave).to_f - HOT_SHEAVE_K
        over.positive? ? over * SCORED_PER_K_S : 0.0
      end

      # Ascending severity: caught in the guides is the lesser of the two.
      def failure_modes = { parted_held: {}, parted: {} }

      def failure_mode(_state, ctx, _cause) = ctx.nodes.fetch(@hoist).catches? ? :parted_held : :parted

      def failure_detail(_state, ctx)
        drum = ctx.nodes.fetch(@hoist)
        { tension_kn: (tension_n(ctx) / 1_000.0).round(1),
          depth_m: drum.cage_m(ctx.states.fetch(@hoist)).round(1) }
      end

      # --- recapping and re-roping ----------------------------------------------------------

      def apply(state, ctx, _grant)
        state = recap(state, ctx)
        renew(state, ctx)
      end

      # Only with the cage stopped at the top landing: you cannot cut a rope that is carrying it.
      def at_bank?(ctx) = ctx.nodes.fetch(@hoist).cage_stopped_at?(ctx.states.fetch(@hoist), 0.0)

      def worked(ctx, control) = control ? (ctx.controls.fetch(control, 0.0) / 100.0).clamp(0.0, 1.0) : 0.0

      def recap(state, ctx)
        effort = worked(ctx, @recap_control)
        return state unless effort.positive? && !broken?(state) && at_bank?(ctx)
        return state unless state.fetch(:spare_m).positive?

        restored = [ state.fetch(:durability) + (RECAP_PER_S * effort * ctx.dt),
                     state.fetch(:initial_durability) ].min
        state.merge(durability: restored,
                    spare_m: [ state.fetch(:spare_m) - (RECAP_SPENT_M_PER_S * effort * ctx.dt), 0.0 ].max)
      end

      # A spare is in store while the spare's own state says so, as of last tick.
      def spare_in_store?(ctx) = @spare && ctx.node_state(@spare)&.fetch(:in_store, false)

      def renew(state, ctx)
        effort = worked(ctx, @renew_control)
        return state.merge(renewing_s: 0.0) unless effort.positive? && spare_in_store?(ctx)

        progress = state.fetch(:renewing_s) + (effort * ctx.dt)
        return state.merge(renewing_s: progress) if progress < RENEW_S

        state.merge(durability: state.fetch(:initial_durability), failure: nil, spare_m: SPARE_M,
                    renewing_s: 0.0, renewed: state.fetch(:renewed) + 1)
      end
    end

    # **A coil of new rope in the store**, there to be wound on. It knows it has been used when the
    # rope it is for says it has been renewed, as of last tick — so neither writes the other.
    class SpareRope < Node
      attr_reader :rope

      def initialize(id:, rope:, label: nil)
        super(id: id, label: label)
        @rope = rope.to_sym
        freeze
      end

      def base_initial_state(rng, content) = super.merge(in_store: true)

      def apply(state, ctx, _grant)
        renewed = ctx.node_state(@rope)&.fetch(:renewed, 0).to_i
        renewed.positive? ? state.merge(in_store: false) : state
      end
    end
  end
end
