# frozen_string_literal: true

module ReactorSim
  # A tagged opening on a node.
  #
  # Tags are what make parts swappable: compatibility is a data question ("does this pipe
  # accept gas?") rather than a code question. A separator declares a gas outlet and a
  # liquid outlet and the routing falls out — which is all a drum separator actually is
  # (docs/simulation_architecture.md §3).
  #
  # `max_kg_per_s` is throughput, never storage. A port restricts flow; a node holds
  # material. Conflating those two was the original sin of the old `Buffer`.
  class Port
    DIRECTIONS = %i[inlet outlet].freeze

    attr_reader :id, :direction, :accepts, :max_kg_per_s

    def initialize(id:, direction:, accepts: [], max_kg_per_s: Float::INFINITY)
      raise Error, "bad port direction: #{direction.inspect}" unless DIRECTIONS.include?(direction)

      @id = id.to_sym
      @direction = direction
      @accepts = Array(accepts).map(&:to_sym).freeze
      @max_kg_per_s = max_kg_per_s.to_f
      freeze
    end

    def inlet?  = @direction == :inlet
    def outlet? = @direction == :outlet

    # An empty tag list accepts anything. Ports are permissive by default so that simple
    # operations need not declare a taxonomy they do not have.
    def accepts?(resource, content)
      return true if @accepts.empty?

      (content.tags(resource) & @accepts).any?
    end

    def capacity_kg(dt) = @max_kg_per_s * dt
  end
end
