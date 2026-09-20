# frozen_string_literal: true

module ReactorSim
  # Anything in an operation's graph. Mechanisms and conduits are both nodes.
  #
  # A node is **configuration and behaviour only** — it holds no mutable state. All state lives
  # in the Operation's frozen hash and is passed in, so a node physically cannot write to the
  # tick it is reading from. That is what makes order-independence enforceable rather than merely
  # intended.
  #
  # The authoring surface is two methods:
  #
  #   plan(state, ctx)         -> Intent   what I want to draw and push
  #   apply(state, ctx, grant) -> state    what I actually got, and what it does to me
  #
  # Heat transfer, phase change, reactions, wear, failure and observation are driven by the
  # concerns a node includes and by engine machinery. A new mechanism is a little config and
  # those two methods, never a re-implementation of physics.
  class Node
    class << self
      # Concerns register themselves on include so `initial_state` can gather their state
      # fragments without anyone maintaining a list by hand.
      def concerns
        @concerns ||= superclass.respond_to?(:concerns) ? superclass.concerns.dup : []
      end

      def include(*mods)
        mods.each { |m| concerns << m if m.name&.start_with?("ReactorSim::Concerns::") }
        super
      end
    end

    attr_reader :id, :label, :ports

    def initialize(id:, label: nil, ports: [])
      @id = id.to_sym
      @label = label || @id.to_s.tr("_", " ").capitalize
      @ports = ports.to_h { |p| [ p.id, p ] }.freeze
    end

    # --- graph ---------------------------------------------------------------

    def port(port_id)
      @ports.fetch(port_id.to_sym) { raise Error, "#{@id} has no port #{port_id.inspect}" }
    end

    def inlets  = @ports.values.select(&:inlet?)
    def outlets = @ports.values.select(&:outlet?)

    # Does material pass THROUGH this node rather than stopping in it?
    #
    # A transport node is never an endpoint for a flow: `Path` resolves straight past it to
    # the holders on either side, and it contributes only a rate limit, a lever and a wall.
    # Almost nothing should say yes — see `Nodes::Conduit` for why holding material in an
    # intermediate node cannot produce a steady flow.
    def transport? = false

    # What this part does to the **composition** of a stream crossing one of its ports.
    #
    # `{}` means no opinion, which is almost every node. Otherwise a hash of tag (or exact
    # resource) to a multiplier: below 1.0 holds a substance back, above 1.0 carries more of it
    # than its share. `Arbiter` multiplies these along every port on a path.
    #
    # **This changes the mix and never the total.** Throughput belongs to rates and conductances;
    # two numbers describing one restriction is always a mistake. See
    # `docs/reference/settlement.md`.
    #
    # Per PORT, not per node, because a part's outlets have to be able to disagree — that is
    # what makes a sorter expressible at all.
    def transport_affinity(_port_id, _state, _ctx) = {}

    # How fast reactions hosted here may run, as a multiple. 1.0 unless a node has a reason to
    # say otherwise — a bed choked with its own ash is the one that does. A multiplier on `dt`
    # rather than a cap on the extent, because choking slows a reaction down; it does not put a
    # ceiling on it. (Scaling the extent would charge a fire for its draught twice, which is the
    # mistake `Resources::Ignition` records having made with the lit-mass term.)
    def reaction_throttle(_state, _content) = 1.0

    # --- lifecycle -----------------------------------------------------------

    # Merges every included concern's fragment over the node's own base state, so a node
    # that includes Thermal and Holds automatically has `joules` and `parcels`.
    def initial_state(rng, content)
      self.class.concerns.reduce(base_initial_state(rng, content)) do |acc, mod|
        fragment = :"#{concern_key(mod)}_initial_state"
        respond_to?(fragment, true) ? acc.merge(send(fragment, rng, content)) : acc
      end.freeze
    end

    # A node that hosts reactions carries how much of each one's fuel is alight, in kg.
    # Everything starts cold: a fire has to be lit, and nothing in the graph starts burning
    # just because it happens to contain something flammable.
    def base_initial_state(_rng, _content)
      return {} if reactions.empty?

      { ignition: reactions.to_h { |id| [ id, Resources::Ignition.initial_state.freeze ] }.freeze }
    end

    # --- tick ----------------------------------------------------------------

    # Declare intent against the PREVIOUS tick's state. Must be pure and must not assume
    # anything it asks for will be granted.
    def plan(_state, _ctx) = Intent.none

    # Compute the next state given what settlement actually granted. Returns either a
    # state hash or [state, events].
    def apply(state, _ctx, _grant) = state

    # Reactions this node hosts, by content id. Chemistry is data; a node just declares
    # which reactions can happen inside it.
    def reactions = []

    # Derived from the failure MODE, so a node that never included `Wearing` — a `Load`, an
    # `Atmosphere` — answers false without carrying a key it has no use for.
    def broken?(state) = !state.fetch(:failure, nil).nil?

    # Defaults for nodes that are not Thermal, so the Operation can treat every node
    # uniformly without asking what it includes. Depositing energy into a node that cannot
    # hold any would silently destroy it, so that one raises rather than returning quietly —
    # it can only happen through a wiring mistake, and a loud one is far cheaper to find.
    def rebalance(state, _content) = state

    def add_joules(_state, _joules, _content)
      raise Error, "#{@id} has no thermal mass but was given energy"
    end

    private

    # ReactorSim::Concerns::Thermal -> "thermal"
    def concern_key(mod)
      mod.name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
    end
  end
end
