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

      # Bearing drag and windage, relaxing toward rest. Closed form for the same reason
      # everything else is: `time_scale` is a dial, so nothing may depend on dt being small.
      # A spinning wheel must coast to a stop, never through it into running backwards.
      def friction_loss(state, dt)
        return 0.0 if friction <= 0.0

        Relaxation.to_reservoir(moment_of_inertia, omega(state), 0.0, friction, dt)
      end

      def initial_omega = 0.0
      def friction = 0.0
      def radius_m = 1.0
    end
  end
end
