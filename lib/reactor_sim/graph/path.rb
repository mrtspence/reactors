# frozen_string_literal: true

module ReactorSim
  # A resolved route for material: one terminal node's outlet to another terminal node's
  # inlet, through zero or more **transport** nodes.
  #
  # This exists because a conduit that holds material cannot deliver a steady flow. Its
  # intake has to be decided from tick N−1, before it can know what it will discharge this
  # tick, and the only inventory rule that stays bounded — `draws = throughput − held` —
  # produces the map `h ↦ T − h`: an involution with eigenvalue exactly −1, so it oscillates
  # forever and cannot damp. Removing the `− held` term gives steady flow and an unbounded
  # duct instead (measured: 1.2 kg climbing to 7.0 kg in a 1 m³ damper).
  #
  # Steady inventory and steady throughput are therefore mutually exclusive for a
  # separately-stateful intermediate node. The fix is to stop it being one: a conduit
  # contributes its rate limit, its lever and its wall to a path, and the path moves material
  # from one real holder to another in a single settlement.
  #
  # See docs/design_sketches/flow_through_issue_draft.md for the measurements and
  # docs/design_sketches/transport_model.md for where this is going.
  class Path
    attr_reader :links, :conduits, :from_node, :from_port, :to_node, :to_port

    def initialize(links:, conduits:)
      @links = links.freeze
      # Transport node ids, in the order material crosses them.
      @conduits = conduits.freeze
      @from_node = links.first.from_node
      @from_port = links.first.from_port
      @to_node = links.last.to_node
      @to_port = links.last.to_port
      freeze
    end

    def id = :"#{@from_node}.#{@from_port}=>#{@to_node}.#{@to_port}"

    def direct? = @conduits.empty?

    class << self
      # Every path in the graph, in declaration order.
      #
      # Derived once at construction and never recomputed: the graph is configuration, not
      # state, so this costs nothing per tick. Order follows the operation's own link list
      # rather than any hash, which is what keeps it order-independent — `graph_spec`
      # shuffles the node and link lists and compares digests.
      def resolve(nodes:, links:)
        transport = nodes.each_with_object({}) { |(id, node), acc| acc[id] = true if node.transport? }

        outgoing = Hash.new { |h, k| h[k] = [] }
        links.each { |link| outgoing[link.from_node] << link }

        links.reject { |link| transport.key?(link.from_node) }
             .map { |link| walk(link, transport, outgoing) }
             .freeze
      end

      private

      # Follow a link forward until it lands on something that actually holds material.
      def walk(first, transport, outgoing)
        chain = [ first ]
        conduits = []
        current = first

        while transport.key?(current.to_node)
          conduits << current.to_node
          # A ring of transport nodes has no holder to settle against, so it would loop here
          # forever. Cheaper to say so than to hang.
          if conduits.length > transport.size
            raise Error, "transport nodes form a cycle with no holder: #{conduits.uniq.join(' -> ')}"
          end

          onward = outgoing[current.to_node]
          # A conduit holds nothing, so one whose outlet goes nowhere is not a stub — it is a
          # line that silently swallows everything put into it.
          raise Error, "#{current.to_node} has no outlet link; a conduit cannot be a dead end" if onward.empty?
          if onward.length > 1
            raise Error, "#{current.to_node} has #{onward.length} outlet links; a conduit carries one path"
          end

          current = onward.first
          chain << current
        end

        new(links: chain, conduits: conduits)
      end
    end
  end
end
