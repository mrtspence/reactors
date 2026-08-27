# frozen_string_literal: true

module ReactorSim
  # Anything in an operation's graph. Mechanisms and conduits are both nodes.
  #
  # A node is **configuration and behaviour only** — it holds no mutable state. All state
  # lives in the Operation's frozen hash and is passed in. A node physically cannot write
  # to the tick it is reading from, which is what makes the double buffer enforceable
  # rather than merely intended, and what keeps evaluation order irrelevant.
  #
  # The authoring surface is deliberately two methods:
  #
  #   plan(state, ctx)         -> Intent   what I want to draw and push
  #   apply(state, ctx, grant) -> state    what I actually got, and what it does to me
  #
  # Heat transfer, phase change, reactions, wear, failure and observation are all driven by
  # the concerns a node includes and by engine machinery. A new mechanism should be a
  # little config and those two methods — not a re-implementation of physics.
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

    # --- lifecycle -----------------------------------------------------------

    # Merges every included concern's fragment over the node's own base state, so a node
    # that includes Thermal and Holds automatically has `joules` and `parcels`.
    def initial_state(rng, content)
      self.class.concerns.reduce(base_initial_state(rng, content)) do |acc, mod|
        fragment = :"#{concern_key(mod)}_initial_state"
        respond_to?(fragment, true) ? acc.merge(send(fragment, rng, content)) : acc
      end.freeze
    end

    def base_initial_state(_rng, _content) = {}

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

    def broken?(state) = state.fetch(:broken, false)

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
