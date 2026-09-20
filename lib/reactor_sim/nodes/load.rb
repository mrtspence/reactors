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
    # ## What it absorbs depends on how fast it is going
    #
    # A load has a **torque curve**, and it is what gives the machine an operating point at
    # all. A constant-torque brake has no stable intersection with a prime mover's torque
    # curve: the engine either overcomes it and accelerates without limit, or it does not and
    # stalls. That is what this was, and it is why the engine sat on a knife edge — throttle 80
    # settled at 452 rpm and throttle 100 ran away to 1211 rpm, with all the speed stability in
    # the machine coming from the cylinder's own breathing rather than from what it was driving.
    #
    #     :fan        τ ∝ ω²    pumps, fans, blowers, paddle agitators
    #     :viscous    τ ∝ ω     line shafting, churns, anything dragging through fluid
    #     :constant   τ         hoists, presses, a screw jack — the honest exception
    #
    # `max_torque` is what the load absorbs at `rated_omega`, so the two together name a duty
    # point rather than a ceiling.
    class Load < Node
      include Concerns::Rotating

      CURVES = %i[fan viscous constant].freeze

      attr_reader :moment_of_inertia, :radius_m, :friction, :control_id, :max_torque,
                  :rated_omega, :curve

      def initialize(id:, label: nil, moment_of_inertia: 50.0, max_torque:,
                     rated_omega: 10.0, curve: :fan,
                     control_id: nil, friction: 0.0, radius_m: 1.0)
        super(id: id, label: label)
        @moment_of_inertia = moment_of_inertia.to_f
        @radius_m = radius_m.to_f
        @friction = friction.to_f
        @control_id = control_id&.to_sym
        @max_torque = max_torque.to_f
        @rated_omega = rated_omega.to_f
        @curve = curve.to_sym
        raise Error, "unknown load curve #{@curve.inspect}" unless CURVES.include?(@curve)

        freeze
      end

      # Torque absorbed at a given speed, before the operator's demand is applied.
      def torque_at(omega)
        return @max_torque if @curve == :constant || @rated_omega <= 0.0

        ratio = omega.abs / @rated_omega
        @max_torque * (@curve == :fan ? ratio * ratio : ratio)
      end

      # The brake, as a conductance toward rest, linearised at this tick's speed: `τ(ω)/ω`.
      #
      # **Solved with the drivetrain, not after it.** `L -= τ(ω)·dt` is explicit Euler and is
      # stable only while `dt < 2I/(dτ/dω)`, which a fan-law mill crosses at ordinary working
      # speed — 0.156 s against a 250 ms tick. The load was spun up by its coupling and slammed
      # to a standstill every tick, with the old `max(…, 0.0)` clamp hiding the divergence well
      # enough to read as a steady state, and the coupling slipping 65% against it.
      #
      # Integrating each side exactly and composing them is no fix: that is still splitting, and
      # it left the mill at 8.5 rad/s against a true equilibrium of 19.6. The linearisation here
      # is a far smaller error than the split it replaces.
      def drag_conductances(state, ctx)
        w = omega(state)
        demand = @control_id ? (ctx.controls.fetch(@control_id, 0.0) / 100.0).clamp(0.0, 1.0) : 1.0
        return super if broken?(state) || w <= 0.0 || demand <= 0.0

        brake = [ torque_at(w) * demand / w, max_drag_conductance(ctx.dt) ].min
        brake.positive? ? super.merge(work: brake) : super
      end
    end
  end
end
