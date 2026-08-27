# frozen_string_literal: true

module ReactorSim
  module Nodes
    # Whatever a machine is actually driving — a mill, a pump, a line shaft, a generator.
    #
    # This is where useful work leaves the operation, and where a good deal of the danger
    # comes from. A prime mover held at speed by a heavy load is stable; take the load away
    # and everything going in becomes acceleration instead, with nothing but the driven
    # mass's own strength in the way. Shedding a load suddenly is a classic way for
    # machinery to destroy itself, and it needs no special case: drop the demand and the
    # physics does the rest.
    #
    # A separate node rather than a property of the rotating mass, so the coupling between
    # them is a DriveLink that can slip, be disengaged, or later snap.
    class Load < Node
      include Concerns::Rotating

      attr_reader :moment_of_inertia, :radius_m, :friction, :control_id, :max_torque

      def initialize(id:, label: nil, moment_of_inertia: 50.0, max_torque:,
                     control_id: nil, friction: 0.0, radius_m: 1.0)
        super(id: id, label: label)
        @moment_of_inertia = moment_of_inertia.to_f
        @radius_m = radius_m.to_f
        @friction = friction.to_f
        @control_id = control_id&.to_sym
        @max_torque = max_torque.to_f
        freeze
      end

      # Work is measured as the kinetic energy actually removed, not as `torque × ω × dt`.
      # The two agree only in the limit of small steps, and `time_scale` means steps are not
      # small — taking the difference keeps the books exact at any dt.
      def apply(state, ctx, _grant)
        demand = @control_id ? (ctx.controls.fetch(@control_id, 0.0) / 100.0).clamp(0.0, 1.0) : 1.0
        torque = @max_torque * demand
        return state.merge(joules_extracted: 0.0) if torque <= 0.0

        before = kinetic_joules(state)
        # A brake cannot drive the shaft backwards, however hard it is applied.
        slowed = state.merge(
          angular_momentum: [ state.fetch(:angular_momentum) - (torque * ctx.dt), 0.0 ].max
        )

        slowed.merge(joules_extracted: before - kinetic_joules(slowed))
      end
    end
  end
end
