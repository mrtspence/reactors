# frozen_string_literal: true

module ReactorSim
  # What sits between the truth and the player.
  #
  # This is where the game's central tension lives: the simulation underneath is far more
  # detailed than what anyone can see, and the gap between the two is the design lever. A
  # gauge lags, jitters, quantises, pegs, sticks, or is read out by someone who cannot
  # really tell — and every one of those is an upgrade slot.
  #
  # Filters compose rather than inherit. The v0 base class carried lag, noise, clamping and
  # pegging for every instrument including ones that were a single lamp; a subclass tree
  # would have needed `NoisyLaggedStickyGauge` and 2^n siblings. A chain of small
  # transforms gets the same expressiveness, and **"upgrade your instrument" becomes
  # literally "remove a filter from the list"**.
  #
  # Every filter is a pure function of (state, value) except for the entropy it draws, and
  # all of that is drawn ONCE PER TICK during recording — never at read time. A tick may be
  # projected any number of times (a player view, a spectator view, a resync of either),
  # and drawing at read time would make the RNG stream depend on how many people happened
  # to be watching.
  module Filters
    # Filters return this so a display can say more than just the number — that a needle is
    # pegged, that a reading is stale, that the instrument is plainly broken.
    Result = Struct.new(:state, :value, :flags, keyword_init: true) do
      def initialize(state:, value:, flags: [])
        super
      end
    end

    class Base
      def initial_state(_rng) = {}

      # Advance one tick. May draw entropy; runs exactly once per tick.
      def apply(_state, _value, _rng, _ctx) = raise NotImplementedError

      # Does this filter make the reading WORSE, or does it change what the reading MEANS?
      #
      # The distinction decides what a spectator sees. A god-view should skip lag, noise
      # and clamping — but not a Rate or a Bands, because those are not distortions, they
      # are the quantity itself. Skipping them showed a temperature of 300 K in a box
      # labelled "K/s", which is how this got noticed.
      #
      # Only distorting filters draw entropy, which is also why the undistorted pass costs
      # nothing and cannot perturb the RNG stream.
      def distortion? = true
    end

    # Reports what was true `ticks` ago. Stacks on top of the delay already inherent in the
    # graph, so a gauge two hops downstream with a lag of 2 is four ticks behind the lever.
    class Lag < Base
      def initialize(ticks)
        super()
        @ticks = Integer(ticks)
        raise Error, "lag must be >= 0" if @ticks.negative?

        freeze
      end

      def initial_state(_rng) = { history: Array.new(@ticks + 1, nil) }

      def apply(state, value, _rng, _ctx)
        history = ([ value ] + state.fetch(:history))[0, @ticks + 1]
        delayed = history.fetch(@ticks)

        # Nothing has been observed for long enough yet — report the current value rather
        # than a fabricated zero. The v0 engine seeded history with 0.0 and opened every
        # match showing a reactor at 0 K.
        Result.new(state: { history: history }, value: delayed.nil? ? value : delayed,
                   flags: delayed.nil? ? [ :warming_up ] : [])
      end
    end

    # An imprecise instrument.
    #
    # The offset is only redrawn once the underlying value has moved further than
    # `deadband`. That is both more honest — a miscalibrated gauge reads consistently
    # wrong, it does not reroll its error every quarter second — and it fixes a real
    # protocol problem: with a fresh draw every tick, essentially every noisy gauge
    # reported a change every tick forever, and "send only what changed" compressed
    # nothing at all.
    class Noise < Base
      def initialize(magnitude, deadband: nil)
        super()
        @magnitude = magnitude.to_f
        @deadband = (deadband || magnitude).to_f
        freeze
      end

      def initial_state(rng) = { offset: rng.noise(@magnitude), anchor: nil }

      def apply(state, value, rng, _ctx)
        anchor = state.fetch(:anchor)
        moved = anchor.nil? || (value - anchor).abs > @deadband
        offset = moved ? rng.noise(@magnitude) : state.fetch(:offset)

        Result.new(state: { offset: offset, anchor: moved ? value : anchor },
                   value: value + offset)
      end
    end

    # An instrument with a scale, which therefore has ends it can be pinned against.
    #
    # The flag is the point. "600 °C" and "at least 600 °C" are very different things to
    # know, and v0 shipped only the clamped number — so a pegged gauge lied by omission
    # with nothing to signal it. Widening the scale is an upgrade.
    class Range < Base
      def initialize(min, max)
        super()
        @min = min.to_f
        @max = max.to_f
        freeze
      end

      def apply(state, value, _rng, _ctx)
        flags = []
        flags << :pegged_low if value <= @min
        flags << :pegged_high if value >= @max

        Result.new(state: state, value: value.clamp(@min, @max), flags: flags)
      end
    end

    # A dial that only reads in increments. Cheap instruments have coarse steps, and a
    # coarse step also stops a twitchy signal reporting a change every tick.
    class Quantize < Base
      def initialize(step)
        super()
        @step = step.to_f
        raise Error, "quantize step must be positive" unless @step.positive?

        freeze
      end

      def apply(state, value, _rng, _ctx)
        Result.new(state: state, value: (value / @step).round * @step)
      end
    end

    # Collapses a continuous value into one of N bands.
    #
    # This is what makes durability readable without ever being a number: bands plus prose
    # give "the fitting is showing some cracks" instead of "integrity 63%".
    class Bands < Base
      # Not a distortion: banding is how the quantity is expressed at all. A spectator
      # still needs "sound" rather than a raw durability figure.
      def distortion? = false

      def initialize(thresholds)
        super()
        @thresholds = thresholds.map(&:to_f).sort.freeze
        freeze
      end

      def apply(state, value, _rng, _ctx)
        Result.new(state: state, value: @thresholds.count { |t| value >= t }.to_f)
      end
    end

    # A needle that catches and holds its last reading for a while. Deeply annoying, and
    # exactly the sort of thing a player should want to spend money replacing.
    class Stick < Base
      def initialize(chance:, release_chance: 0.3)
        super()
        @chance = chance.to_f
        @release_chance = release_chance.to_f
        freeze
      end

      def initial_state(_rng) = { stuck_at: nil }

      def apply(state, value, rng, _ctx)
        stuck_at = state.fetch(:stuck_at)

        if stuck_at
          return Result.new(state: state, value: stuck_at, flags: [ :stuck ]) if
            rng.float > @release_chance

          return Result.new(state: { stuck_at: nil }, value: value)
        end

        return Result.new(state: { stuck_at: value }, value: value, flags: [ :stuck ]) if
          rng.float < @chance

        Result.new(state: state, value: value)
      end
    end

    # Someone who cannot really tell, reporting anyway.
    #
    # Not an instrument fault — an observer fault. An untrained underling eyeballing a
    # fitting is occasionally and confidently wrong, which is a different and funnier
    # failure than a gauge being noisy. Intended to be driven by whoever is on that
    # station once minions land.
    class Misread < Base
      def initialize(chance:, magnitude:)
        super()
        @chance = chance.to_f
        @magnitude = magnitude.to_f
        freeze
      end

      def initial_state(_rng) = { wrong_by: 0.0 }

      def apply(_state, value, rng, _ctx)
        return Result.new(state: { wrong_by: 0.0 }, value: value) if rng.float >= @chance

        wrong_by = rng.noise(@magnitude)
        Result.new(state: { wrong_by: wrong_by }, value: value + wrong_by,
                   flags: [ :misread ])
      end
    end

    # Rate of change per simulated second. A source cannot do this because it needs memory
    # of the previous tick — which is exactly why rates live here and not there.
    class Rate < Base
      # Not a distortion: the rate IS the quantity. Skip it and a god-view reports the
      # underlying value in the rate's units, which is nonsense.
      def distortion? = false

      def initial_state(_rng) = { previous: nil }

      def apply(state, value, _rng, ctx)
        previous = state.fetch(:previous)
        rate = previous.nil? || ctx.dt.zero? ? 0.0 : (value - previous) / ctx.dt

        Result.new(state: { previous: value }, value: rate,
                   flags: previous.nil? ? [ :warming_up ] : [])
      end
    end
  end
end
