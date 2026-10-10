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
    #   config: supports, capacity_nm, control_id (how far it is held off), heat_capacity
    #   state:  joules
    class Brake < Node
      include Concerns::Thermal

      # What "locked" costs, as a multiple of the shaft's own `I/dt`. A held cage creeps at the
      # load torque divided by this, so it is large: half a millimetre an hour under a laden deck.
      LOCK_MULTIPLE = 1.0e6

      # Below this the shaft counts as stopped, and the brake may grip rather than slide.
      STICK_OMEGA = 0.05

      attr_reader :supports, :capacity_nm, :control_id, :heat_capacity, :ambient_conductance,
                  :ambient_k, :initial_temperature_k

      def initialize(id:, supports:, capacity_nm:, heat_capacity:, label: nil, control_id: nil,
                     ambient_conductance: 40.0, ambient_k: Units::STANDARD_TEMPERATURE_K)
        super(id: id, label: label)
        @supports = supports.to_sym
        @capacity_nm = capacity_nm.to_f
        @control_id = control_id&.to_sym
        @heat_capacity = heat_capacity.to_f
        @ambient_conductance = ambient_conductance.to_f
        @ambient_k = ambient_k.to_f
        @initial_temperature_k = @ambient_k
        freeze
      end

      def drag_shaft = @supports

      # How much of the spring reaches the shaft: all of it with the lever down.
      def applied_nm(ctx)
        held_off = @control_id ? (ctx.controls.fetch(@control_id, 0.0) / 100.0).clamp(0.0, 1.0) : 0.0

        @capacity_nm * (1.0 - held_off)
      end

      def drag_conductances(_state, ctx)
        applied = applied_nm(ctx)
        return {} unless applied.positive?

        shaft = ctx.nodes.fetch(@supports)
        speed = shaft.omega(ctx.states.fetch(@supports)).abs
        limit = shaft.moment_of_inertia / ctx.dt
        holding = ctx.node_reading(@supports, :load_torque).to_f.abs

        return { id => limit * LOCK_MULTIPLE } if speed < STICK_OMEGA && applied >= holding

        { id => [ applied / [ speed, STICK_OMEGA ].max, limit ].min }
      end
    end
  end
end
