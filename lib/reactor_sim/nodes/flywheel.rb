# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A heavy spinning mass: flywheel, turbine rotor, water wheel, windmill, line shaft.
    #
    # Two jobs. It smooths an uneven torque into steady rotation, and it stores enough
    # energy to be genuinely dangerous — which is the more interesting one.
    #
    # ## Why it comes apart
    #
    # A spinning disc is trying to tear itself open. Hoop stress goes as ρv², where v is the
    # rim speed, so stress climbs with the SQUARE of speed: twice the RPM is four times the
    # stress. Whether it survives depends on the ratio of the material's tensile strength to
    # its density, and both of those live in content rather than here — swapping the
    # material is a data change (see `content/resources/materials.yml`).
    #
    # This is an OVERLOAD failure, not a fatigue one: it happens on the tick the limit is
    # passed, not after a slow decline. Accumulated wear still counts, though — `integrity`
    # scales the burst speed down, so a mass that has been abused lets go earlier than a
    # fresh one. Both models, each where it belongs.
    class Flywheel < Node
      include Concerns::Rotating
      include Concerns::Wearing

      # Real parts fail well below the ideal figure, because of casting flaws, stress
      # concentrations and geometry. That is a property of the PART, not of the metal, so it
      # is configured here rather than alongside the material's strength.
      DEFAULT_SAFETY_FACTOR = 0.35

      attr_reader :moment_of_inertia, :radius_m, :friction, :material, :fatigue_rate,
                  :safety_factor, :mass_kg

      def initialize(id:, label: nil, mass_kg:, radius_m:, material: :cast_iron,
                     safety_factor: DEFAULT_SAFETY_FACTOR, friction: 0.0,
                     initial_omega: 0.0, fatigue_rate: 0.0)
        super(id: id, label: label)
        @mass_kg = mass_kg.to_f
        @radius_m = radius_m.to_f
        # Solid disc about its centre.
        @moment_of_inertia = 0.5 * @mass_kg * (@radius_m**2)
        @material = material.to_sym
        @safety_factor = safety_factor.to_f
        @friction = friction.to_f
        @initial_omega = initial_omega.to_f
        @fatigue_rate = fatigue_rate.to_f
        freeze
      end

      def initial_omega = @initial_omega

      # Rim speed at which a pristine example of this material comes apart.
      def burst_speed_m_s(content)
        Math.sqrt(content.tensile_strength_pa(@material) / content.density(@material)) *
          @safety_factor
      end

      def burst_omega(content, integrity = 1.0)
        burst_speed_m_s(content) * integrity / @radius_m
      end

      # Current hoop stress as a fraction of what this part can take. Above 1.0 it lets go.
      # Worth putting on a gauge — a redline is something an operator can actually steer by.
      def stress_fraction(state, content)
        limit = burst_omega(content, integrity(state))
        return 0.0 if limit <= 0.0

        (omega(state) / limit)**2
      end

      def overload?(state, ctx, integrity)
        omega(state).abs > burst_omega(ctx.content, integrity)
      end

      # Running near the limit uses a part up even when it survives, so repeated
      # over-speeding lowers the speed at which it eventually fails.
      def stress_per_second(state, ctx)
        return 0.0 if @fatigue_rate.zero?

        over = stress_fraction(state, ctx.content) - 0.5
        over.positive? ? over * @fatigue_rate : 0.0
      end

      def failure_type = :flywheel_burst

      def failure_detail(state, _ctx)
        { rpm: rpm(state).round(1),
          rim_speed_m_s: rim_speed(state).round(1),
          kinetic_joules: kinetic_joules(state).round(0) }
      end
    end
  end
end
