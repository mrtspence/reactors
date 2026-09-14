# frozen_string_literal: true

module ReactorSim
  # How a reading is presented. The last step before a number leaves the simulation.
  #
  # Displays are pure formatting and hold no state. They are also the ONLY place a unit
  # conversion may happen — everything inside the sim is SI, and Kelvin becomes °C here or
  # not at all (docs/simulation_architecture.md §2).
  module Displays
    class Base
      def render(_value, _flags) = raise NotImplementedError

      # What the client needs in order to draw the instrument's chrome once. Values stream;
      # this does not.
      def chrome = { kind: kind }

      def kind = self.class.name.split("::").last.downcase.to_sym
    end

    # A number on a scale. The workhorse.
    class Needle < Base
      def initialize(unit: "", precision: 1, min: nil, max: nil, convert: nil)
        super()
        @unit = unit
        @precision = precision
        @min = min
        @max = max
        @convert = convert
        freeze
      end

      def render(value, _flags) = converted(value).round(@precision)

      def chrome = { kind: :needle, unit: @unit, min: converted(@min), max: converted(@max) }

      private

      # `convert` exists so a gauge can read in °C while the sim thinks in Kelvin. It is a
      # symbol rather than a proc so the whole diagnostic stays trivially serialisable.
      def converted(value)
        return nil if value.nil?
        return value.to_f if @convert.nil?

        Units.public_send(@convert, value.to_f)
      end
    end

    # Same number, no scale. Cheaper to draw, and a digital readout with no range gives no
    # sense of "how bad is that", which is itself a design choice.
    class Digital < Base
      def initialize(unit: "", precision: 0, convert: nil)
        super()
        @unit = unit
        @precision = precision
        @convert = convert
        freeze
      end

      def render(value, _flags)
        value = @convert ? Units.public_send(@convert, value.to_f) : value.to_f
        @precision.zero? ? value.round : value.round(@precision)
      end

      def chrome = { kind: :digital, unit: @unit }
    end

    # On or off. The simplest possible instrument, and the reason the base class had to
    # stop carrying lag and noise machinery — a warning lamp should not pay for either.
    class Lamp < Base
      def initialize(on_above: 0.5, colour: :amber, label: nil)
        super()
        @on_above = on_above.to_f
        @colour = colour.to_sym
        @label = label
        freeze
      end

      def render(value, _flags) = value.to_f > @on_above

      def chrome = { kind: :lamp, colour: @colour, label: @label }
    end

    # Words instead of numbers.
    #
    # Fed by a Bands filter, this is how durability becomes readable without ever becoming
    # a health bar: "the fitting is showing some cracks". Pair it with Lag and Misread and
    # the report is not just vague but occasionally wrong, which is the intended texture.
    class Prose < Base
      def initialize(phrases)
        super()
        @phrases = phrases.map(&:to_s).freeze
        raise Error, "prose display needs at least one phrase" if @phrases.empty?

        freeze
      end

      def render(value, _flags)
        @phrases.fetch(value.to_i.clamp(0, @phrases.size - 1))
      end

      def chrome = { kind: :prose }
    end
  end
end
