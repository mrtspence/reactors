# frozen_string_literal: true

module ReactorSim
  # An edge in the graph: one node's outlet joined to another node's inlet.
  #
  # Links hold no state. Everything interesting about a join — restriction, a control valve, the
  # ability to fail — belongs to a `Conduit`, which is a node; a link is just the wire.
  #
  # **Delay is emergent, and there is no `delay:` parameter anywhere.** Every node reads the
  # previous tick, so a hop costs exactly one tick — and a hop is one `Path`, holder to holder,
  # not one link. Links through a `Conduit` resolve into a single path and cross together, so a
  # valve in a line adds no latency.
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

  # A shaft, belt, chain or gear train: a path for angular momentum. The same shape as
  # `ThermalLink`, because the physics is the same shape. `conductance` is coupling stiffness —
  # how hard the two ends are held to a common speed. A keyed shaft is very stiff, a flat leather
  # belt is not, and the difference is one number rather than one class.
  #
  # A coupling relaxes toward a shared speed over a few ticks rather than instantly, which *is*
  # shaft compliance and is what makes transmitted torque a real quantity: `transferred / dt` is
  # what a shaft's wear should be driven by and what a belt should snap from.
  #
  # TODO: **MUST ADDRESS — the steam engine's coupling dissipates 60% of its shaft power.** At
  # full controls the cylinder delivers ~499 kW, the mill receives **199.7 kW** and
  # `joules_to_friction` takes **297.5 kW**. The books balance, and a slipping coupling genuinely
  # does dissipate, but a real belt drive loses single-digit percent.
  #
  # The suspect is `stiffness:` (9 000 on `flywheel=load`) held against a fan-law load at a large
  # steady speed difference: a soft coupling that never stops slipping is a brake, and
  # `Relaxation` charges it faithfully forever. **Check the steady-state slip first** — if two
  # ends that should converge sit at a permanent offset, the stiffness is wrong rather than the
  # loss model.
  #
  # **Do not tune this in isolation.** Frictional bearings will put a second,
  # physically-motivated dissipation term on the same shafts, so do the pass when they land and
  # re-measure `joules_to_friction` as part of it.
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
