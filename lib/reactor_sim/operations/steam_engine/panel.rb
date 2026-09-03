# frozen_string_literal: true

module ReactorSim
  module Operations
    module SteamEngine
      # The panel. What the overseer can actually see, and how badly.
      #
      # Deliberately imperfect. Boiler pressure lags and jitters, because a Bourdon gauge
      # does; the fire is judged by eye through a door; the flywheel's condition is somebody
      # squinting at it and guessing. The two things that will kill you — pressure and
      # speed — get the best instruments, and even those are late.
      module_function

      def diagnostics(spec)
        base = [
          boiler_pressure(spec), boiler_water, firebox_temp, fire_state,
          flywheel_speed, flywheel_stress, flywheel_condition,
          engine_power, cylinder_pressure, coal_remaining, water_remaining, air_supply
        ]
        spec.fetch(:condenser) ? base + [ condenser_vacuum ] : base
      end

      # The gauge that matters most, so it is the one most worth upgrading. Two ticks late
      # and ±8 kPa, which is enough to make the last stretch before the relief valve a
      # genuine judgement call.
      def boiler_pressure(spec)
        Diagnostic.new(
          id: :boiler_pressure, label: "Boiler Pressure",
          source: Sources::Derived.new(:boiler, :pressure_pa),
          filters: [ Filters::Lag.new(2), Filters::Noise.new(8_000.0),
                     Filters::Range.new(0.0, spec.fetch(:burst_pa)) ],
          display: Displays::Needle.new(unit: "kPa", convert: :kpa, precision: 0,
                                        min: 0.0, max: spec.fetch(:burst_pa))
        )
      end

      # Run the boiler dry and it will fail long before the gauge looks alarming, which is
      # exactly why this reads in a sight glass and not in kilograms.
      def boiler_water
        Diagnostic.new(
          id: :boiler_water, label: "Water Level",
          source: Sources::Contents.new(:boiler, :water),
          filters: [ Filters::Lag.new(1), Filters::Noise.new(30.0), Filters::Quantize.new(50.0) ],
          display: Displays::Needle.new(unit: "kg", precision: 0, min: 0.0, max: 3_500.0)
        )
      end

      def firebox_temp
        Diagnostic.new(
          id: :firebox_temp, label: "Firebox Temperature",
          source: Sources::Derived.new(:firebox, :temperature_k),
          filters: [ Filters::Lag.new(3), Filters::Noise.new(25.0),
                     Filters::Range.new(273.15, 1_673.15) ],
          display: Displays::Needle.new(unit: "°C", convert: :k_to_c, precision: 0,
                                        min: 273.15, max: 1_673.15)
        )
      end

      # Judged through the fire door: is it lit, and is it roaring or sulking?
      def fire_state
        Diagnostic.new(
          id: :fire_state, label: "The Fire",
          source: Sources::Derived.new(:firebox, :temperature_k),
          filters: [ Filters::Lag.new(2),
                     Filters::Bands.new([ 400.0, 700.0, 1_000.0, 1_300.0 ]) ],
          display: Displays::Prose.new([
            "cold", "smouldering", "caught", "burning well", "roaring"
          ])
        )
      end

      def flywheel_speed
        Diagnostic.new(
          id: :engine_speed, label: "Engine Speed",
          source: Sources::Derived.new(:flywheel, :rpm),
          filters: [ Filters::Lag.new(1), Filters::Noise.new(4.0), Filters::Range.new(0.0, 400.0) ],
          display: Displays::Needle.new(unit: "rpm", precision: 0, min: 0.0, max: 400.0)
        )
      end

      # How close the wheel is to coming apart, as a fraction of what it can stand. Above
      # 1.0 it lets go — but the needle lags, so a runaway can pass the redline before the
      # dial admits it.
      def flywheel_stress
        Diagnostic.new(
          id: :flywheel_stress, label: "Wheel Stress",
          source: Sources::Derived.new(:flywheel, :stress_fraction),
          filters: [ Filters::Lag.new(2), Filters::Noise.new(0.03), Filters::Range.new(0.0, 1.5) ],
          display: Displays::Needle.new(unit: "×", precision: 2, min: 0.0, max: 1.5)
        )
      end

      # Somebody's opinion of the flywheel, twelve ticks stale and sometimes wrong. Never a
      # number — a cast-iron wheel gives very little warning, and the game should not give
      # more than the wheel does.
      def flywheel_condition
        Diagnostic.new(
          id: :flywheel_condition, label: "Flywheel Condition", observer: :yardhand,
          source: Sources::Derived.new(:flywheel, :integrity),
          filters: [ Filters::Lag.new(12), Filters::Misread.new(chance: 0.12, magnitude: 0.25),
                     Filters::Bands.new([ 0.15, 0.45, 0.75, 0.95 ]) ],
          display: Displays::Prose.new([
            "hairline cracks showing", "worn and rumbling", "seen better days",
            "running true", "as new"
          ])
        )
      end

      def engine_power
        Diagnostic.new(
          id: :engine_power, label: "Indicated Power",
          source: Sources::Field.new(:cylinder, :indicated_power_w),
          # Averaged BEFORE anything else. The cylinder alternates between two power figures on
          # successive ticks (a period-2 limit cycle against a supply read one tick behind),
          # and lagging or quantising an oscillation just gives you a lagged oscillation.
          # Eight ticks is two seconds — long enough to settle the swing, short enough that
          # opening the throttle still reads as immediate.
          filters: [ Filters::Average.new(8), Filters::Quantize.new(500.0) ],
          display: Displays::Digital.new(unit: "kW", convert: :kilo, precision: 1)
        )
      end

      def cylinder_pressure
        Diagnostic.new(
          id: :cylinder_pressure, label: "Cylinder Pressure",
          source: Sources::Derived.new(:cylinder, :pressure_pa),
          # Same oscillation, same treatment. The average comes first so the noise lands on a
          # settled reading rather than being lost inside a swing several times its size.
          filters: [ Filters::Average.new(8), Filters::Noise.new(5_000.0) ],
          display: Displays::Digital.new(unit: "kPa", convert: :kpa, precision: 0)
        )
      end

      def coal_remaining
        Diagnostic.new(
          id: :coal_remaining, label: "Coal in Bunker",
          source: Sources::Contents.new(:bunker, :coal),
          filters: [ Filters::Quantize.new(100.0) ],
          display: Displays::Digital.new(unit: "kg", precision: 0)
        )
      end

      def water_remaining
        Diagnostic.new(
          id: :water_remaining, label: "Water in Supply",
          source: Sources::Contents.new(:supply, :water),
          filters: [ Filters::Quantize.new(100.0) ],
          display: Displays::Digital.new(unit: "kg", precision: 0)
        )
      end

      # Air reaching the fire. Starve it and the fire dies with no other warning — the
      # firebox just quietly stops making heat.
      def air_supply
        Diagnostic.new(
          id: :air_supply, label: "Draught",
          source: Sources::Contents.new(:firebox, :air),
          filters: [ Filters::Lag.new(1), Filters::Bands.new([ 0.5, 3.0, 10.0 ]) ],
          display: Displays::Prose.new([ "choked", "thin", "adequate", "strong" ])
        )
      end

      # Atmospheric engines only. The vacuum IS the engine; lose it and the piston stops
      # being pushed by anything.
      def condenser_vacuum
        Diagnostic.new(
          id: :condenser_vacuum, label: "Condenser Vacuum",
          source: Sources::Derived.new(:condenser, :pressure_pa),
          filters: [ Filters::Lag.new(1), Filters::Noise.new(2_000.0),
                     Filters::Range.new(0.0, Units::STANDARD_PRESSURE_PA) ],
          display: Displays::Needle.new(unit: "kPa", convert: :kpa, precision: 0,
                                        min: 0.0, max: Units::STANDARD_PRESSURE_PA)
        )
      end
    end

    register(SteamEngine::TYPE) do |id:, seed:, time_scale: 1.0, state: nil, rngs: nil, variant: :high_pressure|
      SteamEngine.build(id: id, seed: seed, variant: variant, time_scale: time_scale,
                        state: state, rngs: rngs)
    end
  end
end
