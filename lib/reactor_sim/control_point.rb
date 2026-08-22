# frozen_string_literal: true

module ReactorSim
  # A lever the player can actually pull.
  #
  # Control points hold an absolute value, never a delta. Commands set that value
  # outright, which is what makes at-least-once delivery from the command log
  # harmless: replaying "set to 42" twice is indistinguishable from once.
  # See docs/architecture.md §6.
  class ControlPoint
    attr_reader :id, :label, :mechanism, :min, :max, :default, :unit

    def initialize(id:, label:, mechanism:, min: 0.0, max: 100.0, default: 0.0, unit: "%")
      @id = id
      @label = label
      @mechanism = mechanism
      @min = min.to_f
      @max = max.to_f
      @default = default.to_f
      @unit = unit
    end

    def initial_state(_rng) = { value: @default }

    # Out-of-range values are clamped rather than rejected. A command that arrives
    # late or from a stale client should still land somewhere sane.
    def set(state, value)
      state.merge(value: value.to_f.clamp(@min, @max))
    end

    def value(state) = state.fetch(:value)
  end
end
