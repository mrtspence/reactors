# frozen_string_literal: true

module ReactorSim
  module Nodes
    # **A spring-applied brake on a shaft**, held off by its lever: what the lever does not hold off,
    # the spring applies. A sibling of `Bearing` — a friction interface on a shaft it does not turn
    # with, whose drag heats itself — without the oil, because a brake must run dry.
    #
    # **It sticks, then slips.** A constant-torque brake linearised as `τ/ω` has no torque at rest
    # and could never hold a load. So while the shaft is all but stopped and the brake can take the
    # torque it is holding against — read from the shaft through `supports:`, as of last tick — it
    # is **locked**; past that it slips at its capacity.
    #
    # **An overwind trip** (`trip:`, `[top_m, bottom_m]`) throws the brake on in full, whatever the
    # lever says, once the shaft's `position_m` is past either mark, and cuts the drive to it — a
    # drive link naming it in `cut_by:` drops out (`cuts_drive?`). It is then only as good as the
    # brake behind it.
    #
    # ## How it fails
    #
    # **The rod is always in tension while the spring is applied**, so it fatigues with every second
    # the brake is on, and when it parts the brake has no force behind it at all — whatever the lever
    # says, and whoever is or is not standing there. **The lining fades as it heats**: past
    # `FADE_FROM_K` its grip falls away, and run past `GLAZE_K` it glazes and is weaker for good.
    #
    #   glazed       the lining has glazed: it grips at `GLAZED_GRIP` of what it did
    #   rod_parted   nothing behind it
    #
    #   config: supports, capacity_nm, control_id, heat_capacity, trip
    #   state:  joules, durability, failure
    class Brake < Node
      include Concerns::Thermal
      include Concerns::Wearing

      # What "locked" costs, as a multiple of the shaft's own `I/dt`. A held cage creeps at the
      # load torque divided by this, so it is large: half a millimetre an hour under a laden deck.
      LOCK_MULTIPLE = 1.0e6

      # Below this the shaft counts as stopped, and the brake may grip rather than slide.
      STICK_OMEGA = 0.05

      # Where the lining starts to lose its grip, where it has lost most of it, and how much it
      # keeps there. A hot brake on a long descent is a weaker brake.
      FADE_FROM_K = 450.0
      FADE_TO_K = 650.0
      FADED_GRIP = 0.35

      # Past this the lining glazes and does not come back.
      GLAZE_K = 700.0
      GLAZED_GRIP = 0.6

      # Durability per second with the spring fully applied: the rod in tension. Against
      # `Wearing::DEFAULT_DURABILITY_RANGE`, so a rod lasts something over two hours of being on.
      ROD_RATE = 0.12

      attr_reader :supports, :capacity_nm, :control_id, :heat_capacity, :ambient_conductance,
                  :ambient_k, :initial_temperature_k, :trip

      def initialize(id:, supports:, capacity_nm:, heat_capacity:, label: nil, control_id: nil,
                     ambient_conductance: 40.0, ambient_k: Units::STANDARD_TEMPERATURE_K, trip: nil)
        super(id: id, label: label)
        @supports = supports.to_sym
        @capacity_nm = capacity_nm.to_f
        @control_id = control_id&.to_sym
        @trip = trip&.map(&:to_f)&.freeze
        @heat_capacity = heat_capacity.to_f
        @ambient_conductance = ambient_conductance.to_f
        @ambient_k = ambient_k.to_f
        @initial_temperature_k = @ambient_k
        freeze
      end

      def drag_shaft = @supports

      # How much of the spring is on the lever's account: all of it with the lever down, or tripped.
      def applied_fraction(ctx)
        return 1.0 if tripped?(ctx)
        return 1.0 unless @control_id

        1.0 - (ctx.controls.fetch(@control_id, 0.0) / 100.0).clamp(0.0, 1.0)
      end

      def tripped?(ctx)
        return false unless @trip

        position = ctx.node_reading(@supports, :position_m) or return false
        position < @trip.first || position > @trip.last
      end

      def cuts_drive?(ctx) = tripped?(ctx)

      # How well the lining grips at its temperature, 1.0 cold.
      def fade(temperature_k)
        return 1.0 if temperature_k <= FADE_FROM_K
        return FADED_GRIP if temperature_k >= FADE_TO_K

        1.0 - ((1.0 - FADED_GRIP) * (temperature_k - FADE_FROM_K) / (FADE_TO_K - FADE_FROM_K))
      end

      # What it can actually hold now: the spring as applied, the lining as hot as it is, and
      # whatever its failure has left of it.
      def holding_nm(state, ctx)
        @capacity_nm * applied_fraction(ctx) * fade(temperature_k(state, ctx.content)) *
          derating(state, :grip)
      end

      def drag_conductances(state, ctx)
        applied = holding_nm(state, ctx)
        return {} unless applied.positive?

        shaft = ctx.nodes.fetch(@supports)
        speed = shaft.omega(ctx.states.fetch(@supports)).abs
        limit = shaft.moment_of_inertia / ctx.dt
        holding = ctx.node_reading(@supports, :load_torque).to_f.abs

        return { id => limit * LOCK_MULTIPLE } if speed < STICK_OMEGA && applied >= holding

        # **Sliding, it is only capped where it cannot hold the load.** At `I/dt` a brake against
        # a steady load settles at `load ÷ (I/dt)`, which past ~800 N·m on a drum is above the stick
        # speed — so a brake holding nine times a cage's weight let it creep for ever. The implicit
        # solve cannot reverse the shaft, so uncapped it simply brings it under the stick speed.
        cap = applied >= holding ? limit * LOCK_MULTIPLE : limit
        { id => [ applied / [ speed, STICK_OMEGA ].max, cap ].min }
      end

      # --- wear ---------------------------------------------------------------------

      def stress_per_second(_state, ctx) = ROD_RATE * applied_fraction(ctx)

      def overload?(state, ctx, _integrity) = temperature_k(state, ctx.content) > GLAZE_K

      def failure_modes = { glazed: { derates: { grip: GLAZED_GRIP } }, rod_parted: { derates: { grip: 0.0 } } }

      def failure_mode(_state, _ctx, cause) = cause == :overload ? :glazed : :rod_parted

      def failure_detail(state, ctx) = { temperature_k: temperature_k(state, ctx.content).round(1) }
    end
  end
end
