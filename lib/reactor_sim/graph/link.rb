# frozen_string_literal: true

module ReactorSim
  # An edge in the graph: one node's outlet joined to another node's inlet.
  #
  # Links hold no state. All the interesting behaviour of a join — restriction, a control
  # valve, the ability to fail — belongs to a `Conduit`, which is a node. A link is just
  # the wire, and a join earns promotion to a node only when it is interesting
  # (docs/simulation_architecture.md §5).
  #
  # Because every node reads the previous tick's state, a link costs exactly one tick of
  # delay. That is where delay comes from now; there is no `delay:` parameter anywhere.
  class Link
    attr_reader :from_node, :from_port, :to_node, :to_port

    def initialize(from:, to:)
      @from_node, @from_port = from
      @to_node, @to_port = to
      @from_node = @from_node.to_sym
      @from_port = @from_port.to_sym
      @to_node = @to_node.to_sym
      @to_port = @to_port.to_sym
      freeze
    end

    def id = :"#{@from_node}.#{@from_port}->#{@to_node}.#{@to_port}"

    def source = [ @from_node, @from_port ]
    def sink   = [ @to_node, @to_port ]
  end

  # A conductive path for heat, with no mass crossing it.
  #
  # Structure is declared, never sequenced. Because every link resolves from the previous
  # tick's temperatures simultaneously, there is no "thermal chain order" to get right —
  # you state which things touch and how well, and the tick sorts it out.
  class ThermalLink
    attr_reader :a, :b, :conductance

    def initialize(a:, b:, conductance:)
      @a = a.to_sym
      @b = b.to_sym
      @conductance = conductance.to_f
      raise Error, "conductance must be positive" unless @conductance.positive?

      freeze
    end

    def id = :"#{@a}<->#{@b}"
  end

  # A shaft, belt, chain or gear train: a path for angular momentum.
  #
  # Deliberately the same shape as ThermalLink, because the physics is the same shape.
  # `conductance` here is coupling stiffness — how hard the two ends are held to a common
  # speed. A keyed shaft is very stiff; a flat leather belt is not, and the difference is
  # one number rather than one class.
  #
  # A rigid coupling relaxes toward a shared speed over a few ticks rather than instantly.
  # That is not a compromise: it *is* shaft compliance, and it is what makes transmitted
  # torque a real quantity rather than an accounting fiction. `transferred / dt` gives the
  # torque this coupling is carrying, which is what a shaft's wear should be driven by and
  # what a belt should snap from.
  class DriveLink
    attr_reader :a, :b, :conductance, :max_torque

    def initialize(a:, b:, stiffness:, max_torque: Float::INFINITY)
      @a = a.to_sym
      @b = b.to_sym
      @conductance = stiffness.to_f
      @max_torque = max_torque.to_f
      raise Error, "stiffness must be positive" unless @conductance.positive?

      freeze
    end

    def id = :"#{@a}=#{@b}"
  end
end
