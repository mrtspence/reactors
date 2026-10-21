# frozen_string_literal: true

module ReactorSim
  module Operations
    # **What anybody can say about the weather, and what an instrument can.** Shared by every
    # operation with an `Outdoors` node, because the sky is the same whatever is under it.
    #
    # The starting readings are **a person's guesses** — "feels cold", "my knee aches", "getting
    # dark" — so they are observer gauges: nobody at the post, nobody saying; somebody daft or in
    # the dark, often wrong. The numbers take an instrument, bought: a thermometer, and a barometer
    # whose glass shows which way it is going, which is what a pit top read it for.
    module WeatherGauges
      module_function

      # The first five are somebody's word and go on every panel; the last three are fitted.
      ORDER = %i[how_it_feels the_light the_weather the_wind the_knee thermometer barometer the_glass].freeze

      # What falls, as `Outdoors` sums it up for a man looking at it.
      FALLING = [ "dry", "spitting", "raining", "pouring", "sleet", "snowing", "a blizzard" ].freeze

      def guesses(observer:)
        {
          how_it_feels: guess(:how_it_feels, "How It Feels", observer, :feels_k,
                              [ 258.0, 268.0, 276.0, 284.0, 292.0, 298.0, 304.0 ],
                              [ "bitter — can't feel my hands", "freezing", "feels cold", "fresh", "mild",
                                "warm", "a bit hot", "sweltering" ], magnitude: 4.0),
          the_light: guess(:the_light, "The Light", observer, :daylight, [ 0.05, 0.4, 0.8 ],
                           [ "pitch black", "getting dark", "grey", "broad daylight" ], magnitude: 0.1),
          the_weather: Diagnostic.new(
            id: :the_weather, label: "The Weather", observer: observer,
            source: Sources::Field.new(Nodes::Outdoors::ID, :falling),
            filters: [ Filters::Lag.new(4) ],
            display: Displays::Prose.new(FALLING)
          ),
          the_wind: guess(:the_wind, "The Wind", observer, :wind_m_s, [ 2.0, 6.0, 11.0, 17.0 ],
                          [ "still", "a breeze", "blowing", "blowing hard", "wind's howling" ], magnitude: 2.0),
          # Falling glass, aching knee: the oldest barometer there is, and about as reliable.
          the_knee: guess(:the_knee, "His Knee", observer, :pressure_trend, [ -250.0, -60.0, 60.0 ],
                          [ "my knee's killing me", "my knee aches", "nothing in the knee", "knee feels grand" ],
                          magnitude: 120.0)
        }
      end

      def instruments
        {
          thermometer: Diagnostic.new(
            id: :thermometer, label: "Thermometer", source: Sources::Field.new(Nodes::Outdoors::ID, :outdoor_k),
            filters: [ Filters::Lag.new(8) ],
            display: Displays::Digital.new(unit: "°C", precision: 0, convert: :k_to_c)
          ),
          barometer: Diagnostic.new(
            id: :barometer, label: "Barometer", source: Sources::Field.new(Nodes::Outdoors::ID, :pressure_pa),
            filters: [ Filters::Lag.new(4) ],
            display: Displays::Needle.new(unit: "kPa", precision: 1, min: 96_000.0, max: 106_000.0, convert: :kpa)
          ),
          # Which way the glass is going, Pa/s: falling fast is a storm, or gas off the goaf.
          the_glass: Diagnostic.new(
            id: :the_glass, label: "The Glass", source: Sources::Field.new(Nodes::Outdoors::ID, :pressure_pa),
            filters: [ Filters::Average.new(240), Filters::Rate.new,
                       Filters::Bands.new([ -250.0 / 3600.0, -60.0 / 3600.0, 60.0 / 3600.0 ]) ],
            display: Displays::Prose.new([ "falling fast", "falling", "steady", "rising" ])
          )
        }
      end

      def guess(id, label, observer, key, thresholds, phrases, magnitude:)
        Diagnostic.new(
          id: id, label: label, observer: observer,
          source: Sources::Field.new(Nodes::Outdoors::ID, key),
          filters: [ Filters::Lag.new(4), Filters::Misread.new(chance: 0.04, magnitude: magnitude, deadband: magnitude),
                     Filters::Bands.new(thresholds) ],
          display: Displays::Prose.new(phrases)
        )
      end

      # **The instruments a pit top or an engine house buys.** One slot, two tiers, shared by every
      # operation that fits `:weather_instruments`.
      Parts.register(:thermometer, kind: :weather_instruments, label: "Thermometer",
                                   description: "A mercury glass on the wall outside. Degrees, not opinions.",
                                   instruments: %i[thermometer]) { |_spec| Fragment.empty }
      Parts.register(:barometer, kind: :weather_instruments, label: "Barometer and Thermometer",
                                 description: "The pair the Act asks for at the pit top. Watch the glass.",
                                 instruments: %i[thermometer barometer the_glass]) { |_spec| Fragment.empty }

      # The slot both operations fit them in. Empty to start: the weather is a guess until a player
      # pays for better.
      def slot
        Slot.new(id: :weather_instruments, accepts: :weather_instruments, label: "Weather Instruments",
                 group: :weather, required: false, default: nil, when_empty: :omit)
      end
    end
  end
end
