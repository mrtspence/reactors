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

      # **Where every gauge sits on the panel, whichever way it arrives.**
      #
      # A player learns a panel by where things are, so this order is the one thing neither the
      # slot list nor a fitted instrument may disturb: fitting a better pressure gauge must not
      # move the water glass. `Assembly` sorts by this and refuses a gauge it does not name, so
      # the list cannot drift by omission.
      PANEL_ORDER = %i[
        boiler_pressure boiler_water safety_valve valve_setting_pa
        crown_sheet plug_blown
        firebox_temp fire_state
        engine_speed flywheel_stress flywheel_condition
        engine_power cylinder_pressure cylinder_water cylinder_relief_valve
        bearing_temp bearing_condition
        coal_remaining water_remaining oil_remaining air_supply
        condenser_vacuum
      ].freeze

      # **Every gauge this engine knows how to show, indexed by id — not the ones it is showing.**
      # Parts name the instruments that arrive with them and `Assembly` selects from this hash, so
      # an unfitted part takes its gauge with it and a part naming a gauge that does not exist
      # fails at build.
      #
      # **`boiler_pressure` is deliberately absent**: it is a separate instrument screwed to the
      # boiler rather than a property of it, so it arrives with a `:boiler_gauge` part instead.
      #
      # Building a gauge costs nothing — a `Diagnostic` is frozen configuration — so the catalogue
      # holds `condenser_vacuum` on both chassis even though only one can fit a condenser.
      # Filtering happens at selection, where it can be checked.
      def catalogue
        [
          safety_valve, valve_setting,
          crown_sheet, plug_blown,
          firebox_temp, fire_state,
          flywheel_speed, flywheel_stress, flywheel_condition,
          engine_power, cylinder_pressure, cylinder_water, cylinder_relief_valve,
          bearing_temp, bearing_condition,
          coal_remaining, water_remaining, oil_remaining, air_supply,
          condenser_vacuum
        ].to_h { |d| [ d.id, d ] }.freeze
      end

      # **The gauge that matters most, and a fitting in its own right.** The definition stays here
      # with the rest of the panel's reasoning; the *figures* come from whichever gauge is fitted,
      # exactly as a boiler's shell thickness comes from whichever boiler is. `full_scale_pa` is a
      # property of the instrument — a 0–14 atm dial and a 0–4 atm dial are different objects,
      # chosen to suit the drum.
      #
      # Stock is two ticks late and ±8 kPa, enough to make the last stretch before the relief
      # valve a genuine judgement call.
      #
      # > **An instrument upgrade may reduce a filter. It may never remove a class of one.** Less
      # > lag, less noise, a finer band — never zero lag, and never a number where the design
      # > chose prose. The instruments are not an obstacle between the player and the game, they
      # > *are* the game, and a panel that can be bought into telling the truth has sold the only
      # > thing it was protecting. `safety_valve`, `crown_sheet` and `flywheel_condition` are
      # > exempt outright: the first is true by design because nobody is reading a dial, and the
      # > other two are vague *because that is the hazard*.
      def boiler_pressure(full_scale_pa:, lag: 2, noise_pa: 8_000.0)
        Diagnostic.new(
          id: :boiler_pressure, label: "Boiler Pressure",
          source: Sources::Derived.new(:boiler, :pressure_pa),
          filters: [ Filters::Lag.new(lag), Filters::Noise.new(noise_pa),
                     Filters::Range.new(0.0, full_scale_pa) ],
          display: Displays::Needle.new(unit: "kPa", convert: :kpa, precision: 0,
                                        min: 0.0, max: full_scale_pa)
        )
      end

      # **The water glass**, without which the priming mechanic is unreadable. It reads a sight
      # glass rather than kilograms because that is the quantity the hazard turns on: carryover
      # depends on where the water stands relative to the steam offtake.
      #
      # Points at `effective_fill`, so it shows the water **with its bubbles in it** — the real
      # instrument's defining flaw, and the mechanic: work the engine hard and the level reads
      # high, shut off and it drops away. Showing the true liquid level would quietly remove the
      # trap that makes swell interesting. Scaled past 100%, because a glass that cannot show an
      # overfull boiler cannot warn anyone about one.
      #
      # **A fitting, like the pressure gauge, and for a sharper reason:** this is the reading the
      # crown-sheet hazard turns on, so how well you can see the water is the most consequential
      # thing a player can buy. A boiler with no way to read its level is legal here, and
      # frightening.
      #
      # `step:` is the try-cocks tier — taps at fixed heights telling you which side of each the
      # water is, and nothing between. A **fourth filter on top of the other three**, which is
      # what makes it a downgrade rather than a different flavour. `label:` is the part's, because
      # try-cocks are not a glass; the **id** stays `:boiler_water` whatever is fitted, because
      # that is the role and `PANEL_ORDER` keys on it.
      def boiler_water(label: "Water Glass", lag: 1, noise: 0.012, step: nil, max: 1.25)
        filters = [ Filters::Lag.new(lag), Filters::Noise.new(noise),
                    Filters::Range.new(0.0, max) ]
        filters << Filters::Quantize.new(step) if step

        Diagnostic.new(
          id: :boiler_water, label: label, observer: :fireman,
          source: Sources::Derived.new(:boiler, :effective_fill),
          filters: filters,
          display: Displays::Needle.new(unit: "%", convert: :percent, precision: 0,
                                        min: 0.0, max: max)
        )
      end

      # **The one instrument that needs no instrument.** A safety valve lifting is the loudest
      # thing in the building — you hear it in the next field, and a driver knows the difference
      # between a valve simmering on its seat and one blowing full lift. So this gets no lag and
      # no noise, which makes it the only gauge on the panel that is simply *true*, and it is
      # true because the player is not reading a dial at all.
      #
      # It matters that this exists rather than being inferable from the pressure gauge: that
      # gauge is two ticks late and ±8 kPa, so the moment the boiler starts wasting steam is
      # precisely the moment its needle is least trustworthy. Blowing off is also a *cost* —
      # water and heat going over the roof — and a cost a player cannot see is a cost they
      # cannot manage.
      #
      # Reads the valve's own recorded opening, so it reports the easing lever too: pull the
      # handle and this says so, which is what makes the lever's expense visible.
      def safety_valve
        Diagnostic.new(
          id: :safety_valve, label: "Safety Valve",
          source: Sources::Field.new(:relief, :lift),
          filters: [ Filters::Bands.new([ 0.01, 0.25, 0.75 ]) ],
          display: Displays::Prose.new([
            "seated", "simmering", "blowing off", "full lift"
          ])
        )
      end

      # The cylinder's own relief valve, and a lamp rather than prose because there is nothing
      # progressive about it. It sits shut through every normal revolution — it is set above the
      # highest compression the engine reaches in ordinary work — so any light at all means the
      # charge is reaching a pressure at top dead centre that the engine was not built for.
      #
      # **This is the warning that arrives before `cylinder_water` does.** That gauge is somebody
      # listening to the engine, four ticks stale and banded; this is a spring lifting, and it
      # lifts on `compression_pressure_pa`, which is the quantity that actually destroys the
      # cylinder. A driver who sees this and does not open the cocks has been told.
      def cylinder_relief_valve
        Diagnostic.new(
          id: :cylinder_relief_valve, label: "Cylinder Relief",
          source: Sources::Field.new(:cylinder_relief, :lift),
          filters: [ Filters::Bands.new([ 0.01 ]) ],
          # No `label:` on the lamp — `Diagnostic#chrome` merges its own `label` last, so a
          # display's label is always discarded. `loop_rig` passes one and it has never shown.
          display: Displays::Lamp.new(colour: :red)
        )
      end

      # What the adjusting screw has actually been wound to, in the same units as the pressure
      # gauge beside it. The lever reads as *margin*, which is the right way to make the decision
      # but the wrong way to judge how close the needle is — so this closes that gap, and the two
      # are meant to be read together.
      #
      # No lag and no noise: it is a screw with a scale on it, not a measurement.
      def valve_setting
        Diagnostic.new(
          id: :valve_setting_pa, label: "Valve Set To",
          source: Sources::Field.new(:relief, :setting_pa),
          filters: [],
          display: Displays::Digital.new(unit: "kPa", convert: :kpa, precision: 0)
        )
      end

      # **Nobody can see a crown sheet**, and that is the entire difficulty of the hazard it
      # names. It is inside the firebox, under water when all is well, and the only instrument a
      # real footplate has for it is the water glass — which, at exactly the wrong moment, lies.
      #
      # So this is not a thermometer. It is the smell and sound of a boiler being mistreated:
      # the fire roaring differently, the plate ticking, steam where steam should not be. Banded
      # well below the 750 K the plate lets go at, and lagged, because the whole point is that the
      # warning is late, vague, and easy to talk yourself out of.
      #
      # It is deliberately **not** given to the fireman as an `observer:`. Their attention is on
      # the glass and the fire, and a crown sheet coming uncovered is precisely the thing a busy
      # crew misses.
      def crown_sheet
        Diagnostic.new(
          id: :crown_sheet, label: "Firebox Crown",
          source: Sources::Field.new(:boiler, :crown_temperature_k),
          filters: [ Filters::Lag.new(4),
                     Filters::Bands.new([ 480.0, 580.0, 660.0 ]) ],
          display: Displays::Prose.new([
            "quiet", "ticking", "smells hot", "glowing"
          ])
        )
      end

      # The plug, and this one is a lamp because it is the least ambiguous event on the engine.
      # When it goes, it goes: the fire is out, the shed is full of steam, and the only question
      # left is how long the repair takes. No lag and no noise — you do not *miss* a fusible plug.
      # NOTE the id. `:fusible_plug` is the **node**, and ids are one flat namespace across nodes,
      # levers, gauges and crew because they key one RNG table — `validate_graph!` refuses the
      # collision outright. Same trap the stoker/`:stoker` pair fell into.
      def plug_blown
        Diagnostic.new(
          id: :plug_blown, label: "Fusible Plug",
          source: Sources::Flag.new(:fusible_plug, :melted),
          filters: [],
          display: Displays::Lamp.new(colour: :red)
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
          # **The shaft figure, not the diagram's.** `indicated_power_w` is what the indicator
          # diagram claims from its two pressures; `shaft_power_w` is what the crank was
          # measurably given, after `Tick#transmit_torque` has held the cylinder to what its
          # charge could pay for. The two diverge whenever the regulator is the restriction —
          # and they diverge the wrong way, so the diagram gauge read 566 kW at 167 rpm and
          # 479 kW at 187 rpm. An instrument may be late, noisy or misread; it may not be
          # anti-correlated with the thing it names.
          source: Sources::Field.new(:cylinder, :shaft_power_w),
          # **The eight-tick average that used to lead this chain is gone.** It was there
          # because the cylinder alternated between two power figures on successive ticks — a
          # period-2 limit cycle against a supply read one tick behind — and lagging or
          # quantising an oscillation only gives you a lagged oscillation.
          #
          # That oscillation was a symptom of an unstable mass solver, not of the cylinder.
          # With transport settled implicitly the raw signal has a coefficient of variation of
          # 0.006 and **no sign reversals at all** over 120 ticks, so there is nothing left to
          # average and the gauge is that much more responsive for losing it. Removing this was
          # the acceptance test the transport design set for itself.
          filters: [ Filters::Quantize.new(500.0) ],
          display: Displays::Digital.new(unit: "kW", convert: :kilo, precision: 1)
        )
      end

      # **Steam chest, not cylinder, and that is the instrument a driver actually has.**
      #
      # A gauge on the cylinder reads a lumped charge that has already expanded and is halfway
      # out of the exhaust — near the release condition, and the least useful of the five
      # pressures inside one revolution. The chest is where admission pressure lives, and the
      # gap between this needle and the boiler gauge **is** the wire-drawing: open the regulator
      # and the two converge, close it and they part. That difference is now the thing worth
      # reading on the whole panel, because it is what sets the power.
      def cylinder_pressure
        Diagnostic.new(
          id: :cylinder_pressure, label: "Steam Chest Pressure",
          source: Sources::Derived.new(:steam_chest, :pressure_pa),
          # Same oscillation, and the same average has come off for the same reason — the
          # cylinder no longer alternates, so the noise now lands on a genuinely settled
          # reading rather than being averaged out of a swing several times its size.
          filters: [ Filters::Noise.new(5_000.0) ],
          display: Displays::Digital.new(unit: "kPa", convert: :kpa, precision: 0)
        )
      end

      # **Nobody can see into a cylinder**, so this is the sound of it: a wet one knocks, and a
      # driver who knows the sound opens the cocks before it does any harm.
      #
      # Prose and never a number, for the same reason `flywheel_condition` is — the warning a
      # real engine gives is qualitative, and giving more than the machine gives would take the
      # judgement out of it. Lagged four ticks because it is somebody listening, and banded well
      # below the failure point so there is room to act: hydraulic lock arrives at a liquid
      # fraction of 1.0 and this is calling it "wet" at 0.5.
      def cylinder_water
        Diagnostic.new(
          id: :cylinder_water, label: "Cylinder", observer: :yardhand,
          source: Sources::Derived.new(:cylinder, :occupancy),
          filters: [ Filters::Lag.new(4), Filters::Bands.new([ 0.15, 0.5, 0.85 ]) ],
          display: Displays::Prose.new([ "dry", "damp", "wet", "knocking badly" ])
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

      # **Quantised coarsely on purpose.** Nobody dips an oil drum to the kilogram — you look in
      # and judge it, and the number a driver acts on is "getting low" rather than 43.
      def oil_remaining
        Diagnostic.new(
          id: :oil_remaining, label: "Oil in Store",
          source: Sources::Contents.new(:oil_store, :bearing_oil),
          filters: [ Filters::Quantize.new(5.0) ],
          display: Displays::Digital.new(unit: "kg", precision: 0)
        )
      end

      # **The slow one, and the only warning a hot box gives.** A bearing that is going to wipe
      # spends minutes climbing before it does, so this is the instrument that makes the runaway
      # survivable — lagged and noisy enough that the exact figure is never the point, precise
      # enough that a rising trend is unmistakable.
      #
      # Scaled to the babbitt rather than to the machine: 520 K is where it melts, so a dial that
      # ends there puts the danger at the top of the sweep where a driver reads it by needle
      # position rather than by arithmetic.
      def bearing_temp
        Diagnostic.new(
          id: :bearing_temp, label: "Main Bearing Temperature", observer: :yardhand,
          source: Sources::Derived.new(:main_bearings, :temperature_k),
          filters: [ Filters::Lag.new(6), Filters::Noise.new(4.0),
                     Filters::Range.new(273.15, 573.15) ],
          display: Displays::Needle.new(unit: "°C", convert: :k_to_c, precision: 0,
                                        min: 273.15, max: 573.15)
        )
      end

      # **Never a number, for the same reason the flywheel has none.** A bearing was judged by
      # hand and nose — crews felt the boxes and smelled them — so this is what somebody reports
      # walking the length of the engine, not a reading.
      #
      # Exempt from the upgrade rule along with `flywheel_condition`: it is vague *because that
      # is the hazard*, and an instrument that made it precise would sell the only thing it
      # protects.
      def bearing_condition
        Diagnostic.new(
          id: :bearing_condition, label: "Bearing Condition", observer: :yardhand,
          source: Sources::Derived.new(:main_bearings, :integrity),
          filters: [ Filters::Lag.new(10), Filters::Misread.new(chance: 0.14, magnitude: 0.25),
                     Filters::Bands.new([ 0.2, 0.5, 0.8, 0.97 ]) ],
          display: Displays::Prose.new([
            "smells hot, knocking badly", "running warm and noisy", "warm to the hand",
            "cool enough", "cold and quiet"
          ])
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

      # Air reaching the fire. Starve it and the fire dies with no other warning — the firebox
      # quietly stops making heat.
      #
      # **The bands have to sit inside what the firebox can physically hold.** A 6 m³ box
      # entirely full of pure air at 900 K holds 2.35 kg, so a band above that is one the gauge is
      # structurally incapable of reading. Measured across the damper: 0.0083 / 0.0269 / 0.0477 /
      # 0.1744 / 0.3669 kg at 20 / 40 / 60 / 80 / 100, against a fire of 333 / 375 / 409 / 562 /
      # 715 K — **44× and monotone**.
      #
      # A *proxy*: draught is a flow and this is an inventory, and a hotter fire holds less air
      # mass at the same draught. The damper's effect dominates that, but the honest quantity is
      # the pressure difference driving the air in.
      def air_supply
        Diagnostic.new(
          id: :air_supply, label: "Draught",
          source: Sources::Contents.new(:firebox, :air),
          filters: [ Filters::Lag.new(1), Filters::Bands.new([ 0.05, 0.15, 0.30 ]) ],
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

    # **The keyword list here is a whitelist, and that is load-bearing on restore.** An option
    # the builder does not name is an `ArgumentError` rather than a silent default — loud,
    # which is right, but it means `options:` and this signature have to move together. A
    # `loadout:` that failed to arrive would rebuild the stock engine from a snapshot of a
    # stripped one, silently and completely.
    # `chassis:` here is the *enumeration* — derived from `CHASSIS` so it cannot drift from the
    # frames that actually exist — and is unrelated to the `chassis:` keyword the block takes,
    # which is one chosen frame. See `Operations.register`.
    register(SteamEngine::TYPE,
             chassis: SteamEngine::CHASSIS.keys,
             assembler: lambda { |chassis, loadout|
               SteamEngine.assembly_for(chassis || :high_pressure, loadout || {})
             }) do |id:, seed:, time_scale: 1.0, state: nil,
                                                     rngs: nil, content: nil,
                                                     chassis: :high_pressure, loadout: {},
                                                     crew: {}|
      SteamEngine.build(id: id, seed: seed, chassis: chassis, loadout: loadout, crew: crew,
                        time_scale: time_scale, state: state, rngs: rngs, content: content)
    end
  end
end
