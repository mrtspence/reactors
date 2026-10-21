# frozen_string_literal: true

module ReactorSim
  # **What the world outside is doing**: the weather and the light, and later whatever else a
  # match is played under.
  #
  # A kind of condition draws what it needs once, from the outdoors node's stream at
  # `initial_state`, and answers its readings at any moment as a pure function of what it drew
  # and the clock — so no die is thrown after the start, and a snapshot taken mid-storm replays
  # the rest of it exactly. Kinds are read in registration order, each seeing what the earlier
  # ones answered: the weather needs the hour the daylight read.
  #
  # **Everything a kind says goes out through a fixed set of channels** (`STANDARD`'s keys), so a
  # later kind reuses consumers that already exist. All readings are numbers, which keeps the
  # schedule and the readings JSON-safe in a snapshot.
  #
  # See `docs/design_sketches/conditions.md`.
  module Conditions
    STANDARD_K = Units::STANDARD_TEMPERATURE_K
    STANDARD_PA = Units::STANDARD_PRESSURE_PA

    # What falls, as a number in the readings.
    FORMS = %i[none rain sleet snow].freeze

    # **The sky a spec measures a machine under**, and what an operation built without
    # `conditions:` gets: a mild, still, dry day at noon. Every node's ambient is exactly what it
    # was declared as under it, because exposure shifts an ambient by the sky's departure from this.
    STANDARD = { outdoor_k: STANDARD_K, pressure_pa: STANDARD_PA, pressure_trend: 0.0,
                 precipitation: 0.0, form: 0, wind_m_s: 0.0, daylight: 1.0, hour: 12.0,
                 spell: 0 }.freeze

    # How long a schedule is drawn for, seconds: comfortably past the longest match.
    HORIZON_S = 3.0 * 3600.0

    @kinds = {}

    class << self
      attr_reader :kinds

      def register(id, kind) = @kinds[id.to_sym] = kind

      # A setup as it arrived in `options:`, keys and the season and climate as symbols; nil for
      # no conditions at all, which is the standard sky.
      def setup(raw)
        return nil if raw.nil?

        given = raw.to_h { |k, v| [ k.to_sym, v ] }
        { climate: (given[:climate] || :northern_coalfield).to_sym, season: given.fetch(:season).to_sym,
          start_hour: given[:start_hour]&.to_f, severity: given[:severity]&.to_f }.freeze
      end

      # Each kind's draw, keyed by kind, all from the one stream in registration order.
      def draw(rng, setup, content)
        season = content.season(setup.fetch(:climate), setup.fetch(:season))
        @kinds.to_h { |id, kind| [ id, kind.draw(rng, setup, season) ] }
      end

      # The readings at `clock_s` seconds into the match.
      def read(setup, drawn, clock_s, content)
        return STANDARD if setup.nil?

        climate = content.climate(setup.fetch(:climate))
        season = climate.fetch(:seasons).fetch(setup.fetch(:season))
        @kinds.reduce(STANDARD) do |readings, (id, kind)|
          readings.merge(kind.read(drawn.fetch(id), clock_s, season, climate, readings))
        end
      end
    end

    # **The sun.** A match is an hour of a real day, starting at a drawn hour: most are day shifts,
    # some cross dusk or dawn, and a few are night shifts dark at bank throughout.
    module Daylight
      module_function

      # When shifts start, as weights over hours of the day.
      STARTS = [ [ 0.65, 6.0..14.0 ], [ 0.25, 14.0..19.0 ], [ 0.10, 19.0..29.0 ] ].freeze

      # Civil twilight: full dark six degrees below the horizon, full light six above.
      TWILIGHT_DEG = 6.0

      # Two draws whether or not the hour was given, so a set start hour does not shift every draw
      # after it.
      def draw(rng, setup, _season)
        roll = rng.float
        span = rng.float
        return { start_hour: setup.fetch(:start_hour) } if setup[:start_hour]

        hours = (STARTS.find { |weight, _| (roll -= weight).negative? } || STARTS.last).last
        { start_hour: (hours.begin + (span * (hours.end - hours.begin))) % 24.0 }
      end

      def read(drawn, clock_s, season, climate, _readings)
        hour = (drawn.fetch(:start_hour) + (clock_s / 3600.0)) % 24.0
        { hour: hour, daylight: light(elevation_deg(hour, season.fetch(:day_of_year), climate.fetch(:latitude_deg))) }
      end

      def elevation_deg(hour, day_of_year, latitude_deg)
        rad = Math::PI / 180.0
        declination = 23.44 * Math.sin(2.0 * Math::PI * (284.0 + day_of_year) / 365.0)
        hour_angle = 15.0 * (hour - 12.0)
        sine = (Math.sin(latitude_deg * rad) * Math.sin(declination * rad)) +
               (Math.cos(latitude_deg * rad) * Math.cos(declination * rad) * Math.cos(hour_angle * rad))
        Math.asin(sine.clamp(-1.0, 1.0)) / rad
      end

      def light(elevation)
        x = ((elevation + TWILIGHT_DEG) / (2.0 * TWILIGHT_DEG)).clamp(0.0, 1.0)
        x * x * (3.0 - (2.0 * x))
      end
    end

    # **The weather**: a season's mean and its day, with a run of spells drawn on top. A spell
    # eases into the next across `EASE_S`, so a storm arrives over minutes rather than on a tick.
    module Weather
      module_function

      EASE_S = 600.0

      # The hour of the day's high; the low is twelve hours off it, near dawn.
      WARMEST_HOUR = 15.0

      # Where the glass starts against the season's mean, Pa either way.
      PRESSURE_SPREAD_PA = 1_500.0

      # Snow below the first, sleet up to the second, rain above.
      SNOW_BELOW_K = 274.15
      SLEET_BELOW_K = 275.65

      def draw(rng, setup, season)
        span = season.fetch(:severity)
        severity = rng.between(span.first.to_f, span.last.to_f)
        start_pa = rng.between(-PRESSURE_SPREAD_PA, PRESSURE_SPREAD_PA)
        names = spell_names(season)
        weights = names.map { |name| season.fetch(:spells).fetch(name).fetch(:weight).to_f }

        spells = []
        at = 0.0
        while at < HORIZON_S
          pick = rng.float * weights.sum
          index = weights.index { |w| (pick -= w).negative? } || (weights.size - 1)
          minutes = season.fetch(:spells).fetch(names.fetch(index)).fetch(:minutes)
          length = rng.between(minutes.first.to_f, minutes.last.to_f) * 60.0
          spells << { spell: index, from_s: at, to_s: at + length }
          at += length
        end

        { severity: setup[:severity] || severity, start_pa: start_pa, spells: spells }
      end

      # Sorted, so a spell's index means the same thing in every snapshot of every match.
      def spell_names(season) = season.fetch(:spells).keys.sort

      def read(drawn, clock_s, season, _climate, readings)
        names = spell_names(season)
        figures = ->(index) { season.fetch(:spells).fetch(names.fetch(index)) }
        now, blend, after = spell_at(drawn.fetch(:spells), clock_s)
        mix = ->(key) { ((1.0 - blend) * figures.(now).fetch(key).to_f) + (blend * figures.(after).fetch(key).to_f) }

        severity = drawn.fetch(:severity)
        day = 0.5 * season.fetch(:daily_range_k).to_f *
              Math.cos(2.0 * Math::PI * (readings.fetch(:hour) - WARMEST_HOUR) / 24.0)
        outdoor = season.fetch(:mean_k).to_f + day + (severity * mix.(:offset_k))
        falling = severity * mix.(:precipitation)

        { outdoor_k: outdoor, wind_m_s: severity * mix.(:wind_m_s),
          precipitation: falling, form: form(falling, outdoor),
          pressure_pa: season.fetch(:pressure_pa).to_f + drawn.fetch(:start_pa) +
                       pressure_moved(drawn.fetch(:spells), clock_s, figures, severity),
          pressure_trend: severity * mix.(:pressure_trend),
          spell: blend < 0.5 ? now : after }
      end

      def form(falling, outdoor_k)
        return FORMS.index(:none) unless falling.positive?
        return FORMS.index(:snow) if outdoor_k < SNOW_BELOW_K
        return FORMS.index(:sleet) if outdoor_k < SLEET_BELOW_K

        FORMS.index(:rain)
      end

      # The spell now, how far into the ease toward the next it is, and the next. Past the drawn
      # horizon the last spell simply holds.
      def spell_at(spells, clock_s)
        current = spells.index { |s| clock_s < s.fetch(:to_s) } || (spells.size - 1)
        spell = spells.fetch(current)
        following = spells.fetch([ current + 1, spells.size - 1 ].min)
        easing = ((clock_s - (spell.fetch(:to_s) - EASE_S)) / EASE_S).clamp(0.0, 1.0)
        easing = 0.0 if following.equal?(spell)

        [ spell.fetch(:spell), easing, following.fetch(:spell) ]
      end

      # How far the glass has moved since the start, the trend of each spell over its time so far.
      def pressure_moved(spells, clock_s, figures, severity)
        spells.sum do |s|
          held_s = [ [ clock_s, s.fetch(:to_s) ].min - s.fetch(:from_s), 0.0 ].max
          severity * figures.(s.fetch(:spell)).fetch(:pressure_trend).to_f * held_s / 3600.0
        end
      end
    end

    register(:daylight, Daylight)
    register(:weather, Weather)
  end
end
