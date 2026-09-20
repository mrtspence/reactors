# frozen_string_literal: true

module ReactorSim
  module Concerns
    # A node that spins.
    #
    # Every kinetic part in the game is this one concern — flywheels, turbines, water
    # wheels, windmills, drive shafts. Worth getting right once rather than per machine.
    #
    # **Angular momentum is stored; everything else is derived.** That is the same rule that
    # made Thermal work, and for the same reason: momentum is what a coupling actually
    # conserves. Store angular velocity instead and two joined shafts have no conserved
    # quantity between them, so every join becomes a hand-tuned fudge — which is precisely
    # the trap the old `Buffer` fell into.
    #
    # Storing kinetic energy would be the other tempting choice. It plugs into the existing
    # energy ledger, but a slipping belt does not conserve energy, so the coupling rule
    # would have to be invented rather than derived. Momentum is the honest quantity, and
    # the energy a slipping coupling loses is real friction heat that belongs on the ledger.
    #
    #   config: moment_of_inertia (kg·m²), friction (N·m·s/rad), radius_m
    #   state:  angular_momentum (kg·m²/s)
    module Rotating
      def rotating_initial_state(_rng, _content)
        { angular_momentum: moment_of_inertia * initial_omega }
      end

      def omega(state) = state.fetch(:angular_momentum) / moment_of_inertia

      def rpm(state) = omega(state) * 60.0 / (2.0 * Math::PI)

      def kinetic_joules(state)
        (state.fetch(:angular_momentum)**2) / (2.0 * moment_of_inertia)
      end

      # Rim speed. What actually tears a spinning mass apart is how fast its edge travels,
      # not how fast it is turning.
      def rim_speed(state) = omega(state) * radius_m

      def apply_torque(state, newton_metres, dt)
        state.merge(angular_momentum: state.fetch(:angular_momentum) + (newton_metres * dt))
      end

      def add_angular_momentum(state, delta)
        state.merge(angular_momentum: state.fetch(:angular_momentum) + delta)
      end

      # What drags this body toward rest, in N·m·s/rad, grouped by where the energy it removes
      # belongs on the ledger. Bearing drag and windage are `:friction`; a load's brake is
      # `:work`, because that one is the point of the machine.
      #
      # **Declared rather than applied**, so `Arbiter.settle_drive` solves it inside the
      # drivetrain network instead of after it. Applied afterwards it is operator splitting, and
      # a stiff drag makes that error dominate everything else — see `Relaxation.settle`.
      #
      # A body that has let go declares nothing: it is off the drivetrain and `Tick#stress` has
      # already taken its momentum. **That decision belongs here rather than in the arbiter**,
      # because it is not universal — a seized bearing drags harder after it fails, which is what
      # makes a seizure stop the shaft at all.
      def drag_conductances(state, _ctx)
        return {} if broken?(state)

        friction.positive? ? { friction: friction } : {}
      end

      # Which shaft a declared drag acts on. Itself, for a body dragging against the air — but a
      # bearing is not the thing that turns, so it names the shaft it carries instead.
      def drag_shaft = id

      # **A bound on the linearisation, not a stop.** At `c = I/dt` the backward-Euler step leaves
      # exactly half the speed — `(I/dt + c)·ω′ = (I/dt)·ω` — so this halves a body per tick at
      # most. Backward Euler is stable at any conductance and cannot reverse a shaft, so nothing
      # needs this for stability; what it bounds is how far a nonlinear drag may be trusted when
      # it has been linearised as `τ(ω)/ω`, which diverges as a constant-torque brake slows.
      #
      # A drag that genuinely means "this has stopped turning" declares a large multiple of it
      # instead — see `Nodes::Bearing` on seizure.
      def max_drag_conductance(dt) = moment_of_inertia / dt

      def initial_omega = 0.0
      def friction = 0.0
      def radius_m = 1.0
    end
  end
end
