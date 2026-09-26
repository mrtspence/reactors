# frozen_string_literal: true

module ReactorSim
  module Operations
    module Mine
      # The panel. What the overseer can see of a hole in the ground, and how badly.
      #
      # **Almost nothing about a mine is visible from the surface**, which is the whole character
      # of this operation against the steam engine's. An engine is in front of you; a district is
      # half a kilometre away in the dark and everything you know about it arrives late, through
      # somebody, or not at all.
      #
      # The instruments here are correspondingly poor: the sump is a float on a chain, the air is
      # a reading taken at one measuring station, and how much coal is left in the seam is a
      # surveyor's estimate that quantises hard. The shaft speed is the one honest gauge, because
      # it is at bank where you can see it.
      module_function

      PANEL_ORDER = %i[
        flame_cap lamp_flame canary
        shaft_speed shaft_supply
        air_quantity district_air
        sump_level
        coal_raised seam_remaining
      ].freeze

      def catalogue
        {
          # **The flame cap, and it is the whole thesis of this game in one instrument.**
          #
          # Nobody measures firedamp. A deputy lowers the wick in a safety lamp until the flame
          # is almost out, holds it up into the roof cavity where the gas collects, and reads the
          # height of the pale blue cone above it — by eye, in the dark, at one point in a
          # district, some minutes ago. That reading is the only thing standing between a shift
          # and an explosion, and it is a person's estimate.
          #
          # So: banded into what a cap actually looks like, prose rather than a number, lagged
          # because he has to walk back and tell you, and **stuck** because a lamp that has been
          # knocked goes on showing the last thing it showed. The bands are the real ones —
          # a cap appears around 2%, is unmistakable by 3%, and the mixture fires at 5%.
          #
          # The upgrade path is the historical one: a better lamp reduces the `Stick`, a
          # methanometer eventually removes the `Noise`. **Neither may ever remove the `Bands`**
          # — a number here would be a different game.
          flame_cap: Diagnostic.new(
            id: :flame_cap, label: "Flame Cap",
            source: Sources::Fraction.new(:district, :firedamp),
            filters: [ Filters::Lag.new(6), Filters::Noise.new(0.35, deadband: 0.5),
                       Filters::Stick.new(chance: 0.02, release_chance: 0.25),
                       Filters::Bands.new([ 0.8, 2.0, 3.0, 5.0 ]) ],
            display: Displays::Prose.new([ "no cap on the lamp", "a trace of gas",
                                           "a cap, plainly", "a tall cap — clear the district",
                                           "the lamp is firing" ])
          ),

          # **The same lamp, read the other way, and the only gauge in the mine that trips
          # before the danger does.**
          #
          # Firedamp is read off what the flame *gains* — a pale cap above it. Blackdamp is read
          # off what the flame *loses*: it dulls, shrinks, and will not stay lit. That is not a
          # convenience, it is why a flame lamp was still worth carrying after electric light
          # existed, and it is the one warning in this operation that arrives with time to act
          # on it. **A lamp goes out at around the point a man starts to suffer; it is well out
          # before one collapses**, so the bands are set to put "will not stay lit" at
          # `Breath::SAFE` and the dull flame comfortably ahead of it.
          #
          # At the pit bottom rather than the face, because blackdamp is heavier than air and
          # lies in the dips — see `Mine.goaf_seep`.
          lamp_flame: Diagnostic.new(
            id: :lamp_flame, label: "Pit Bottom Lamp",
            source: Sources::Fraction.new(:pit_bottom, :blackdamp),
            # Measured, not derived: a well-ventilated pit bottom settles at about 2.2% and
            # `Breath::SAFE` falls at about 6.4%, so a clear flame has to reach past the first
            # and a dull one has to arrive before the second. `Sources::Fraction` reports mass
            # and `Breath` works in volume, which is the other reason these are measured.
            filters: [ Filters::Lag.new(5), Filters::Noise.new(0.3, deadband: 0.4),
                       Filters::Bands.new([ 3.0, 5.0, 8.0, 14.0 ]) ],
            display: Displays::Prose.new([ "burning clear", "the flame is dull",
                                           "the flame is low — bad air below",
                                           "the lamp will not stay lit",
                                           "the lamp is out" ])
          ),

          # **The bird, and it is an instrument in the most literal sense in the game.**
          #
          # Whitedamp is odourless, colourless, and kills at a concentration that displaces
          # nothing — there is no flame trick for it, because a lamp burns perfectly well in
          # air that is killing you. So the only warning anybody had was an animal with a
          # faster metabolism going over first, and a rescue party's whole margin was the gap
          # between the bird and the man.
          #
          # That gap is what the bands encode: the bird is distressed well under
          # `toxic_fraction`, and on its back at about it. **Three states and no number**, and
          # it must never become a number — a canary that reported parts per million would be
          # a different game, and nobody carried a meter.
          canary: Diagnostic.new(
            id: :canary, label: "Canary",
            source: Sources::Fraction.new(:district, :whitedamp),
            # No `Stick`: the bird is not an instrument that can be knocked out of true, and
            # no `Noise` either — it is a plain, honest reading of a thing too small to
            # misjudge by eye. The lag is the walk back with the cage.
            filters: [ Filters::Lag.new(4), Filters::Bands.new([ 0.05, 0.25 ]) ],
            display: Displays::Prose.new([ "singing", "the bird is distressed",
                                           "the bird is down — get them out" ])
          ),

          # At bank, on the shaft itself. The one thing you can actually watch, and the first
          # sign that the engine house has stopped paying attention to you.
          shaft_speed: Diagnostic.new(
            id: :shaft_speed, label: "Line Shaft",
            source: Sources::Derived.new(:line_shaft, :rpm),
            filters: [ Filters::Lag.new(1), Filters::Noise.new(1.2, deadband: 4.0) ],
            display: Displays::Needle.new(unit: "rpm", precision: 0, min: 0.0, max: 320.0)
          ),

          # How much bought power is in hand. Banded rather than numeric: an overseer knows
          # whether the supply is holding up, not how many joules are in the shaft.
          shaft_supply: Diagnostic.new(
            id: :shaft_supply, label: "Supply",
            source: Sources::Field.new(:line_shaft, :supply_joules),
            filters: [ Filters::Lag.new(2), Filters::Bands.new([ 1.0e3, 2.5e5, 1.5e6 ]) ],
            display: Displays::Prose.new([ "nothing coming through", "running down",
                                           "holding", "plenty in hand" ])
          ),

          # Air quantity at the measuring station, which is a vane anemometer somebody holds up
          # in the return. Lagged and coarse, because that is what taking a reading is.
          air_quantity: Diagnostic.new(
            id: :air_quantity, label: "Air Quantity",
            source: Sources::Field.new(:upcast, :carried_kg),
            filters: [ Filters::Average.new(8), Filters::Lag.new(4),
                       Filters::Noise.new(0.4, deadband: 1.0) ],
            display: Displays::Needle.new(unit: "kg/s", precision: 1, min: 0.0, max: 14.0)
          ),

          # What the district actually holds. **Deliberately the worst gauge on the panel** —
          # quantised hard and four ticks behind, because nobody is standing there with a
          # manometer. It is the instrument firedamp will eventually be read against.
          district_air: Diagnostic.new(
            id: :district_air, label: "District Air",
            source: Sources::Derived.new(:district, :contents_kg),
            filters: [ Filters::Lag.new(4), Filters::Quantize.new(50.0) ],
            display: Displays::Digital.new(unit: "kg", precision: 0)
          ),

          # A float on a chain in the sump. Coarse, slow, and the only warning that the pump is
          # not keeping pace with the make of water.
          sump_level: Diagnostic.new(
            id: :sump_level, label: "Sump",
            source: Sources::Contents.new(:pit_bottom, :water),
            filters: [ Filters::Lag.new(3), Filters::Quantize.new(25.0) ],
            display: Displays::Needle.new(unit: "kg", precision: 0, min: 0.0, max: 2_000.0)
          ),

          # What has gone up the shaft this tick, averaged — a winder's output is a cycle rather
          # than a flow, so the instantaneous figure is not a reading anybody could use.
          coal_raised: Diagnostic.new(
            id: :coal_raised, label: "Coal Raised",
            source: Sources::Field.new(:winder, :carried_kg),
            filters: [ Filters::Average.new(12), Filters::Lag.new(2) ],
            display: Displays::Needle.new(unit: "kg/s", precision: 2, min: 0.0, max: 8.0)
          ),

          # A surveyor's estimate of what is left in the district, and it is a guess.
          seam_remaining: Diagnostic.new(
            id: :seam_remaining, label: "Seam",
            source: Sources::Contents.new(:seam, :coal),
            filters: [ Filters::Lag.new(6), Filters::Quantize.new(5_000.0) ],
            display: Displays::Digital.new(unit: "t", precision: 0, convert: :kilo)
          )
        }
      end
    end

    # At `Operations` level rather than inside `Mine`, because `register` is a method on this
    # module and a nested module does not inherit it.
    register(Mine::TYPE,
             chassis: Mine::CHASSIS.keys,
             assembler: lambda { |chassis, loadout|
               Mine.assembly_for(chassis || :two_shaft, loadout || {})
             }) do |id:, seed:, time_scale: Mine::DEFAULT_TIME_SCALE, state: nil,
                                                 rngs: nil, content: nil,
                                                 chassis: :two_shaft, loadout: {},
                                                 crew: {}|
      Mine.build(id: id, seed: seed, chassis: chassis, loadout: loadout, crew: crew,
                 time_scale: time_scale, state: state, rngs: rngs, content: content)
    end
  end
end
