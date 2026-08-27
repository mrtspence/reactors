# frozen_string_literal: true

module ReactorSim
  # Where a gauge gets its number.
  #
  # The v0 engine hard-wired every diagnostic to `mechanisms[id][field]`, so a gauge could
  # only ever read one scalar off one mechanism. Nothing could show a tank level, a flow
  # rate, or anything derived — which is how a player ended up with no instrument for the
  # steam line that was about to kill them.
  #
  # Sources are stateless and pure. Anything that needs memory (lag, rates, sticking) is a
  # Filter, so that all diagnostic state lives in one place and snapshots as one thing.
  module Sources
    Reading = Struct.new(:value, :available, keyword_init: true) do
      def self.missing = new(value: 0.0, available: false)
      def self.of(value) = new(value: value.to_f, available: true)
    end

    class Base
      def sample(_nodes, _states, _content) = raise NotImplementedError

      # Sources are configuration; two with the same settings are interchangeable.
      def label = self.class.name.split("::").last.downcase
    end

    # A raw field out of a node's state hash.
    class Field < Base
      def initialize(node, key)
        super()
        @node = node.to_sym
        @key = key.to_sym
        freeze
      end

      def sample(_nodes, states, _content)
        state = states[@node] or return Reading.missing
        value = state[@key]
        value.nil? ? Reading.missing : Reading.of(value)
      end
    end

    # Something a node computes rather than stores — temperature and pressure are both
    # derived, never held, so this is the only way to gauge them.
    class Derived < Base
      SIGNATURES = {
        temperature_k: :with_content,
        pressure_pa: :with_content,
        contents_volume: :with_content,
        room_m3: :with_content,
        contents_kg: :state_only,
        # Rotation and wear. All state-only, because none of them need to know what the
        # node is holding — a flywheel's speed does not depend on the weather.
        omega: :state_only,
        rpm: :state_only,
        rim_speed: :state_only,
        kinetic_joules: :state_only,
        stress_fraction: :with_content,
        integrity: :state_only
      }.freeze

      def initialize(node, quantity)
        super()
        @node = node.to_sym
        @quantity = quantity.to_sym
        raise Error, "cannot derive #{quantity.inspect}" unless SIGNATURES.key?(@quantity)

        freeze
      end

      def sample(nodes, states, content)
        node = nodes[@node] or return Reading.missing
        state = states[@node] or return Reading.missing
        return Reading.missing unless node.respond_to?(@quantity)

        value = SIGNATURES.fetch(@quantity) == :with_content ? node.public_send(@quantity, state, content)
                                                             : node.public_send(@quantity, state)
        Reading.of(value)
      end
    end

    # How full something is, 0..100. The instrument the old engine structurally could not
    # provide, and the one a backing-up line most needs.
    class Level < Base
      def initialize(node)
        super()
        @node = node.to_sym
        freeze
      end

      def sample(nodes, states, content)
        node = nodes[@node] or return Reading.missing
        state = states[@node] or return Reading.missing
        return Reading.missing unless node.respond_to?(:contents_volume) && node.respond_to?(:volume_m3)
        return Reading.of(0.0) if node.volume_m3 <= 0.0

        Reading.of(node.contents_volume(state, content) / node.volume_m3 * 100.0)
      end
    end

    # How much of one substance a node holds. Reads through the parcel list, so it works
    # for a mixture — "how much water is in the drum" while it also holds steam.
    class Contents < Base
      def initialize(node, resource)
        super()
        @node = node.to_sym
        @resource = resource.to_sym
        freeze
      end

      def sample(_nodes, states, _content)
        state = states[@node] or return Reading.missing
        parcel = state.fetch(:parcels, []).find { |p| p.fetch(:resource) == @resource }
        Reading.of(parcel ? parcel.fetch(:kg) : 0.0)
      end
    end

    # Remaining integrity, as an absolute quantity. Never shown as a number — it is banded
    # and put into prose by the filter chain, so the player gets "showing some cracks"
    # rather than a health bar (docs/simulation_architecture.md §7).
    class Durability < Base
      def initialize(node)
        super()
        @node = node.to_sym
        freeze
      end

      def sample(_nodes, states, _content)
        state = states[@node] or return Reading.missing
        value = state[:durability]
        value.nil? ? Reading.missing : Reading.of(value)
      end
    end

    # Whether something has failed. Feeds a lamp.
    class Broken < Base
      def initialize(node)
        super()
        @node = node.to_sym
        freeze
      end

      def sample(_nodes, states, _content)
        state = states[@node] or return Reading.missing
        Reading.of(state[:broken] ? 1.0 : 0.0)
      end
    end

    # One number across many nodes — total output, hottest cluster, lowest reservoir.
    # A panel-level instrument rather than a per-part one.
    class Aggregate < Base
      OPERATIONS = { sum: :sum, max: :max, min: :min }.freeze

      def initialize(sources, operation: :sum)
        super()
        @sources = sources.freeze
        @operation = operation.to_sym
        raise Error, "unknown aggregate #{operation.inspect}" unless OPERATIONS.key?(@operation)

        freeze
      end

      def sample(nodes, states, content)
        values = @sources.map { |s| s.sample(nodes, states, content) }
                         .select(&:available).map(&:value)
        return Reading.missing if values.empty?

        Reading.of(values.public_send(OPERATIONS.fetch(@operation)))
      end
    end
  end
end
