# frozen_string_literal: true

module ReactorSim
  # A window into the machinery — and a deliberately imperfect one.
  #
  # Diagnostics are where the game's central tension lives: the simulation underneath
  # is far more detailed than what the player can see, and the gap between the two is
  # the design lever. A gauge can lag, jitter, and peg at the end of its scale, and
  # every one of those is an upgrade slot.
  #
  # Crucially the distortion happens HERE, inside the sim, not in the view layer.
  # Ground truth never leaves the engine (docs/architecture.md §4).
  #
  # Note that noise is drawn ONCE PER TICK in #record and stored, rather than being
  # drawn when the gauge is read. That keeps #reading a pure function of state, which
  # matters more than it looks: a tick may be projected any number of times (a player
  # view, a spectator view, a resync of either), and drawing noise at read time would
  # make the RNG stream depend on how many people happened to be watching.
  class Diagnostic
    attr_reader :id, :label, :mechanism, :field, :unit, :min, :max, :noise, :delay, :precision

    def initialize(id:, label:, mechanism:, field:, unit: "", min: 0.0, max: 100.0,
                   noise: 0.0, delay: 0, precision: 1)
      @id = id
      @label = label
      @mechanism = mechanism
      @field = field
      @unit = unit
      @min = min.to_f
      @max = max.to_f
      @noise = noise.to_f
      @delay = delay
      @precision = precision
    end

    # History is newest-first and exactly long enough to serve the configured delay.
    def initial_state(_rng) = { history: Array.new(@delay + 1, 0.0), noise_offset: 0.0 }

    def record(state, true_value, rng)
      {
        history: ([ true_value ] + state.fetch(:history))[0, @delay + 1],
        noise_offset: @noise.zero? ? 0.0 : rng.noise(@noise)
      }
    end

    # What the player sees: delayed, noisy, clamped to the instrument's scale.
    def reading(state)
      value = state.fetch(:history).fetch(@delay) + state.fetch(:noise_offset)
      value.clamp(@min, @max).round(@precision)
    end

    # What a spectator sees: the truth, undelayed and unfiltered.
    def truth(state) = state.fetch(:history).first.round(@precision)

    # True when the instrument is pinned at either end of its scale and is therefore
    # lying by omission. Worth surfacing — "your gauge is maxed out" is information.
    def pegged?(state)
      value = state.fetch(:history).fetch(@delay)
      value <= @min || value >= @max
    end
  end
end
