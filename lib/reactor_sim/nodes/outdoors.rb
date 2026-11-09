# frozen_string_literal: true

module ReactorSim
  module Nodes
    # **The sky over an operation, and the ground under it.** Holds the conditions a match is
    # played under — what `Conditions` drew for it at the start and what they read now — so the
    # weather snapshots, restores and replays like everything else, and instruments read it
    # through ordinary sources.
    #
    # Every operation in a match draws from the same seed and this node's own id, so **two of
    # them read the same sky**, as if on one site, with nothing passing between them.
    #
    # It also keeps what the weather leaves on the ground, because that is history rather than a
    # reading: snow lying and melting, and how long since the ground was last wet.
    #
    #   state: clock_s, drawn, dry_s, dark, and every key in `SKY`
    #
    # `SKY` is every channel in `Conditions::STANDARD` plus the ground's: `runoff` (kg/m²/s of rain
    # and melt reaching the drains), `snow_kg_m2`, `wet` and `icy` (0 or 1), and `feels_k`, the
    # air with the wind on it — what a man standing in it would call the temperature.
    #
    # Built without a setup it reads the standard sky for ever, which is what a spec measuring a
    # machine wants.
    class Outdoors < Node
      ID = :outdoors

      SKY = (Conditions::STANDARD.keys + %i[runoff snow_kg_m2 wet icy feels_k falling]).freeze

      # What falls, as somebody looking at it would sum it up — an index into
      # `Operations::WeatherGauges::FALLING`: dry, spitting, raining, pouring, sleet, snowing, a
      # blizzard.
      SPITTING_BELOW = 2.0e-4
      POURING_FROM = 1.0e-3
      BLIZZARD_WIND_M_S = 12.0

      # Wet underfoot for this long after it stops raining, s.
      DRIES_S = 1_800.0

      # Snow melts at about 3 mm of water a day per kelvin above freezing — the degree-day rule —
      # which is this in kg/m²/s per K.
      MELT_PER_K = 3.5e-5

      # Lying snow worth calling lying, kg/m²: a few millimetres of water's worth.
      LIES_KG_M2 = 2.0

      FREEZING_K = 273.15

      # Daylight, with hysteresis: dark below the first, light again above the second.
      DUSK = 0.4
      DAWN = 0.6

      attr_reader :setup

      def initialize(setup: nil, label: "Outdoors")
        super(id: ID, label: label, ports: [])
        @setup = Conditions.setup(setup)
        freeze
      end

      def base_initial_state(rng, content)
        drawn = @setup ? Conditions.draw(rng, @setup, content) : {}
        sky = Conditions.read(@setup, drawn, 0.0, content)
        { clock_s: 0.0, drawn: drawn, dry_s: DRIES_S, dark: sky.fetch(:daylight) < DUSK }
          .merge(ground(sky, 0.0, DRIES_S, 0.0))
      end

      def plan(_state, _ctx) = Intent.none

      # Drawn from the match's seed under one name, not the operation's, so every operation in a
      # match gets the same sky (`Operation#build_rngs`).
      def shared_stream = "sky"

      # Every channel, as of this state.
      def sky(state) = state.slice(*SKY)

      def apply(state, ctx, _grant)
        clock = state.fetch(:clock_s) + ctx.dt
        sky = Conditions.read(@setup, state.fetch(:drawn), clock, ctx.content)
        snow, melt = lie(state.fetch(:snow_kg_m2), sky, ctx.dt)
        dry = raining?(sky) ? 0.0 : state.fetch(:dry_s) + ctx.dt
        runoff = (raining?(sky) ? sky.fetch(:precipitation) : 0.0) + melt

        next_state = state.merge(clock_s: clock, dry_s: dry, dark: dark_now?(state.fetch(:dark), sky.fetch(:daylight)))
                          .merge(ground(sky, snow, dry, runoff))
        [ next_state, events(state, next_state, ctx) ]
      end

      # The wind on the air, for a person: the Canadian wind-chill index, which only means anything
      # below about 10 °C and above a walking breeze, and is the air itself otherwise.
      def self.feels_k(air_k, wind_m_s)
        celsius = air_k - FREEZING_K
        kmh = wind_m_s * 3.6
        return air_k if celsius > 10.0 || kmh < 4.8

        felt = 13.12 + (0.6215 * celsius) - (11.37 * (kmh**0.16)) + (0.3965 * celsius * (kmh**0.16))
        felt + FREEZING_K
      end

      private

      def raining?(sky) = [ Conditions::FORMS.index(:rain), Conditions::FORMS.index(:sleet) ].include?(sky.fetch(:form))

      # What lies, and what melted off it this tick as kg/m²/s.
      def lie(snow, sky, dt)
        snow += sky.fetch(:precipitation) * dt if sky.fetch(:form) == Conditions::FORMS.index(:snow)
        melted = [ MELT_PER_K * [ sky.fetch(:outdoor_k) - FREEZING_K, 0.0 ].max * dt, snow ].min
        [ snow - melted, dt.positive? ? melted / dt : 0.0 ]
      end

      def ground(sky, snow, dry_s, runoff)
        wet = dry_s < DRIES_S || (snow.positive? && sky.fetch(:outdoor_k) > FREEZING_K)
        icy = sky.fetch(:outdoor_k) < FREEZING_K && (wet || snow >= LIES_KG_M2)
        sky.merge(runoff: runoff, snow_kg_m2: snow, wet: wet ? 1 : 0, icy: icy ? 1 : 0,
                  feels_k: self.class.feels_k(sky.fetch(:outdoor_k), sky.fetch(:wind_m_s)),
                  falling: falling(sky))
      end

      def falling(sky)
        rate = sky.fetch(:precipitation)
        case Conditions::FORMS.fetch(sky.fetch(:form))
        when :none then 0
        when :rain
          if rate < SPITTING_BELOW then 1
          elsif rate < POURING_FROM then 2
          else 3
          end
        when :sleet then 4
        else rate >= POURING_FROM || sky.fetch(:wind_m_s) >= BLIZZARD_WIND_M_S ? 6 : 5
        end
      end

      def dark_now?(dark, daylight)
        return daylight < DAWN if dark

        daylight < DUSK
      end

      # A change of spell, nightfall and daybreak: the transitions, never the readings.
      def events(before, after, ctx)
        out = []
        if before.fetch(:spell) != after.fetch(:spell)
          out << Event.build(type: :weather_turned, node: id, label: label, severity: :info, tick: ctx.tick,
                             detail: { from: before.fetch(:spell), to: after.fetch(:spell) })
        end
        if after.fetch(:dark) && !before.fetch(:dark)
          out << Event.build(type: :nightfall, node: id, label: label, severity: :info, tick: ctx.tick)
        elsif before.fetch(:dark) && !after.fetch(:dark)
          out << Event.build(type: :daybreak, node: id, label: label, severity: :info, tick: ctx.tick)
        end
        out
      end
    end
  end
end
