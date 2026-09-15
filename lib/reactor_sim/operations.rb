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
    @harnesses = Set.new

    class << self
      # `chassis:` is the list of frames this type can be built on, and it exists so the
      # registry can be *asked* rather than reached into. The delivery tier needs to enumerate
      # them — every chassis is separately unlockable — and the alternative was a hand-written
      # map from operation type to `SomeOperation::CHASSIS`, which is an inventory list that
      # drifts the first time somebody adds a frame. Pass the keys, never a literal list.
      #
      # It is introspection, not configuration: nothing in a tick reads this, and a builder
      # still takes `chassis:` as an ordinary option and still raises on one it does not know.
      # `harness: true` marks a registration that exists only to exercise the engine — a spec rig,
      # not a machine anyone plays. It still builds and runs exactly like any other operation;
      # what it does not do is appear anywhere enumerating *machines*.
      #
      # This exists because `spec/support/loop_rig.rb` registers globally, as it must for
      # `Match.create` to find it, and the delivery tier's blueprint catalogue is **derived** from
      # this registry. The rig therefore became an unlockable operation that had to be priced, and
      # the whole catalogue refused to build — but only in a full-suite run, because nothing loads
      # the rig otherwise. Derivation is still right; it just has to derive from the correct set.
      #
      # The default is `false` on purpose: forgetting to mark a real machine does nothing, and
      # forgetting to mark a rig fails loudly and points straight at it.
      def register(type, chassis: [], harness: false, &builder)
        @builders[type.to_sym] = builder
        @chassis[type.to_sym] = Array(chassis).map(&:to_sym).freeze
        @harnesses << type.to_sym if harness
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

      # Everything registered, rigs included — what `Match.create` resolves against.
      def known = @builders.keys

      # The machines. Anything enumerating operations for a *player* wants this rather than
      # `known`: a spec rig is not a machine, and a catalogue built from `known` picks one up the
      # moment a full-suite run loads it.
      def catalogued = @builders.keys - @harnesses.to_a

      def harness?(type) = @harnesses.include?(type.to_sym)
    end
  end
end
