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
        sump_level water_make
        district_light district_fire
        roof_timber putting
        cage_speed winding_gear
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
          # **And it is somebody's word, so it is the one instrument that names an observer.**
          # `:timbering` because that post is in the district and produces nothing: the hands
          # at the face are cutting, and the man setting props is the one with time to hold a
          # lamp up into the roof. It also gives the only station in the mine that wins no coal
          # a second reason to be manned — pull the timberman and you lose the gas reading
          # entirely, which is a decision rather than a tax.
          flame_cap: Diagnostic.new(
            id: :flame_cap, label: "Flame Cap", observer: :timbering,
            source: Sources::Fraction.new(:district, :firedamp),
            filters: [ Filters::Lag.new(6), Filters::Noise.new(0.35, deadband: 0.5),
                       Filters::Stick.new(chance: 0.02, release_chance: 0.25),
                       # A band and a bit, so being wrong means reading the wrong *phrase* —
                       # the only thing a player ever sees of this gauge.
                       Filters::Misread.new(chance: 0.02, magnitude: 1.2, deadband: 1.2),
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
          #
          # **A level, not a weight.** Nobody at a pit bottom knows or cares how many kilograms
          # are standing in the sump; what they know is how far up the chain the float is and
          # how much is left before it is over the rails and backing up the road. 100% is
          # `Sump::FLOOD_KG` — the point where the workings start to go — so the needle reads
          # as distance from disaster rather than as an amount of water.
          sump_level: Diagnostic.new(
            id: :sump_level, label: "Sump",
            source: Sources::Derived.new(:pit_bottom, :flooding),
            filters: [ Filters::Lag.new(3), Filters::Quantize.new(0.02) ],
            display: Displays::Needle.new(unit: "%", precision: 0, min: 0.0, max: 100.0,
                                          convert: :percent)
          ),

          # **How hard it is coming in**, which is a different question from how much has
          # arrived — and the one that tells a player what kind of ground they have been given.
          # The make of water varies per match, so this is how a pit introduces itself.
          #
          # Prose, because a deputy reports what the fissure is doing rather than a rate: there
          # is no instrument on a wet roadway, only somebody who has walked it.
          water_make: Diagnostic.new(
            id: :water_make, label: "The Make",
            source: Sources::Field.new(:seepage, :carried_kg),
            filters: [ Filters::Average.new(10), Filters::Lag.new(5),
                       Filters::Bands.new([ 0.04, 0.18, 0.5, 2.0 ]) ],
            display: Displays::Prose.new([ "barely damp", "weeping steadily",
                                           "running in", "a strong feeder",
                                           "pouring in — she will not hold it" ])
          ),

          # **Nobody could mistake an ignition, so the panel must not be quieter than the
          # place.** An event is a transition and a player who looked away for ten seconds
          # while the roadway caught would have nothing else to tell them.
          #
          # Read off the **heat** rather than off what is alight, because a firedamp flash is
          # over in about five ticks — it burns the mixture back down through its own lean
          # limit and goes out — while what it leaves behind is a roadway at two thousand
          # kelvin that nobody can go into for minutes. The heat is both the thing you would
          # notice and the thing that is still true when you look up.
          district_fire: Diagnostic.new(
            id: :district_fire, label: "Fire",
            source: Sources::Derived.new(:district, :temperature_k),
            filters: [ Filters::Lag.new(2), Filters::Bands.new([ 320.0, 400.0, 700.0, 1_200.0 ]) ],
            display: Displays::Prose.new([ "no smell of burning", "warm, and smoke in the return",
                                           "hot — something has gone up", "the workings are alight",
                                           "an inferno; nobody is going down there" ])
          ),

          # **What the district is lit by, and therefore whether anybody can work in it.**
          # Hewing is gated on `darkvision`: unlit, a shift at the face wins exactly nothing,
          # and nothing else on the panel would have said why.
          district_light: Diagnostic.new(
            id: :district_light, label: "District Light",
            source: Sources::Field.new(:sconces, :lit),
            filters: [ Filters::Lag.new(2), Filters::Bands.new([ 0.05, 0.3, 0.6, 0.9 ]) ],
            display: Displays::Prose.new([ "dark — nobody can work", "barely enough to see by",
                                           "working light", "well lit", "bright as a street" ])
          ),

          # **What the putter is actually shifting**, which is the one job on this panel whose
          # output you could otherwise only infer from the coal arriving at bank minutes later.
          # Face to pit bottom, averaged for the same reason the winder's is: a man pushing tubs
          # is a sequence of trips, not a flow.
          #
          # A road that has come in still passes a little — `roof_fall` derates throughput to
          # 0.12 rather than sealing it — so a needle sitting near zero while somebody is posted
          # and the lever is open is what a fall looks like from bank.
          putting: Diagnostic.new(
            id: :putting, label: "Tubs", source: Sources::Field.new(:tub_road, :carried_kg),
            filters: [ Filters::Average.new(10), Filters::Lag.new(3),
                       Filters::Noise.new(0.3, deadband: 0.8) ],
            display: Displays::Needle.new(unit: "kg/s", precision: 2, min: 0.0, max: 7.0)
          ),

          # **How much ground is standing on its own**, read off what the roadway has left.
          #
          # There is no stock of timber to count — timbering is a lever, not a store — so what a
          # deputy reports is the state of the ground: whether the bars are taking weight and
          # whether the road is working. `Roadway` wears on `hewing − timbering`, so this falls
          # only while a face is being cut faster than it is being supported, which is exactly
          # the decision the gauge exists to inform.
          #
          # Prose and heavily lagged, because it is a walk and a judgement, not a measurement.
          roof_timber: Diagnostic.new(
            id: :roof_timber, label: "Roof", source: Sources::Derived.new(:tub_road, :integrity),
            filters: [ Filters::Lag.new(6), Filters::Noise.new(0.04, deadband: 0.05),
                       Filters::Bands.new([ 0.3, 0.55, 0.8 ]) ],
            display: Displays::Prose.new([ "the road is working — get timber in",
                                           "bars taking weight", "standing well", "newly set" ])
          ),

          # What has gone up the shaft this tick, averaged — a winder's output is a cycle rather
          # than a flow, so the instantaneous figure is not a reading anybody could use.
          coal_raised: Diagnostic.new(
            id: :coal_raised, label: "Coal Raised",
            source: Sources::Field.new(:winder, :carried_kg),
            filters: [ Filters::Average.new(12), Filters::Lag.new(2) ],
            display: Displays::Needle.new(unit: "kg/s", precision: 2, min: 0.0, max: 8.0)
          ),

          # **Is the man-riding gear actually turning**, which nothing on the panel said.
          #
          # A cage is a passage rather than a node, so calling it and having it *move* are two
          # different facts: the lever is set at bank, the speed comes off the line shaft, and a
          # shift told to ride a cage that is not turning simply takes the ladders instead and
          # nobody at bank can tell. This is the gauge that closes that gap — at bank, on the
          # gear itself, which is why it is an honest needle rather than a report.
          #
          # Ships with the man-riding fitting, because with nothing fitted there is no gear to
          # watch and the ladders need no instrument.
          cage_speed: Diagnostic.new(
            id: :cage_speed, label: "Man Winding",
            source: Sources::Derived.new(:cage_drive, :rpm),
            filters: [ Filters::Lag.new(1), Filters::Noise.new(1.0, deadband: 3.0) ],
            display: Displays::Needle.new(unit: "rpm", precision: 0, min: 0.0, max: 320.0)
          ),

          # **What the winding gear has left in it**, and the reason it is on the panel now is
          # the reason it will matter later: rope goes before anything else in a headframe, and
          # it goes from wear rather than from an event.
          #
          # TODO: first caller of a *rope-specific* failure is the hot-rope mode — a rope that
          # has been run hard fails differently from gear that has simply worn out, and wants
          # its own `failure_modes` entry on the winder plus a duty term in `stress_per_second`.
          # Today this reads the winder's ordinary durability, which is honest but blunt: it
          # falls with use and says nothing about *why*.
          winding_gear: Diagnostic.new(
            id: :winding_gear, label: "Winding Gear",
            source: Sources::Derived.new(:winder, :integrity),
            filters: [ Filters::Lag.new(4), Filters::Noise.new(0.03, deadband: 0.04),
                       Filters::Bands.new([ 0.2, 0.5, 0.8 ]) ],
            display: Displays::Prose.new([ "the rope is going — stop winding",
                                           "worn, and showing it", "serviceable", "sound" ])
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
                                                 crew: {}, ground: nil|
      Mine.build(id: id, seed: seed, chassis: chassis, loadout: loadout, crew: crew,
                 ground: ground,
                 time_scale: time_scale, state: state, rngs: rngs, content: content)
    end
  end
end
