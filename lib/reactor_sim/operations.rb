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

    class << self
      def register(type, &builder)
        @builders[type.to_sym] = builder
      end

      def fetch(type)
        @builders.fetch(type.to_sym) do
          raise Error, "unknown operation type: #{type.inspect} (known: #{known.join(', ')})"
        end
      end

      def known = @builders.keys
    end
  end
end
