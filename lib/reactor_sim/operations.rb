# frozen_string_literal: true

module ReactorSim
  # Registry of operation types.
  #
  # An operation's *configuration* — which mechanisms exist, how they are wired, what
  # the gauges show — is code, rebuilt identically every time. Only its *state* is
  # serialised. That is what lets a snapshot be a small bag of floats rather than an
  # object graph, and what lets a restored match be wired up by type name.
  module Operations
    @builders = {}
    @chassis = {}

    class << self
      # `chassis:` is the list of frames this type can be built on, and it exists so the
      # registry can be *asked* rather than reached into. The delivery tier needs to enumerate
      # them — every chassis is separately unlockable — and the alternative was a hand-written
      # map from operation type to `SomeOperation::CHASSIS`, which is an inventory list that
      # drifts the first time somebody adds a frame. Pass the keys, never a literal list.
      #
      # It is introspection, not configuration: nothing in a tick reads this, and a builder
      # still takes `chassis:` as an ordinary option and still raises on one it does not know.
      def register(type, chassis: [], &builder)
        @builders[type.to_sym] = builder
        @chassis[type.to_sym] = Array(chassis).map(&:to_sym).freeze
      end

      def fetch(type)
        @builders.fetch(type.to_sym) do
          raise Error, "unknown operation type: #{type.inspect} (known: #{known.join(', ')})"
        end
      end

      # Empty for a type that has only one frame and does not name it. That is a real answer —
      # "this machine has no chassis to choose" — and not a missing one, so it does not raise.
      def chassis_for(type)
        @chassis.fetch(type.to_sym) do
          raise Error, "unknown operation type: #{type.inspect} (known: #{known.join(', ')})"
        end
      end

      def known = @builders.keys
    end
  end
end
