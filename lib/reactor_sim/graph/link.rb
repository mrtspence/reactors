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
    attr_reader :a, :b, :conductance, :emissivity, :radiating_area_m2

    # `conductance` is conduction and convection, in W/K, and is constant.
    #
    # `emissivity:` and `radiating_area_m2:` add a **radiant** path on top, and that one is not
    # constant: it goes as T⁴, so the conductance it contributes is recomputed each tick from
    # both ends. See `radiative_conductance` and `docs/design_sketches/radiation.md`.
    #
    # **A firebox heats its water legs mostly by radiation**, and a linear term cannot say the
    # thing everybody who tends a fire knows — that a *bright* fire is worth far more than a merely hot one.
    def initialize(a:, b:, conductance:, emissivity: 0.0, radiating_area_m2: 0.0)
      @a = a.to_sym
      @b = b.to_sym
      @conductance = conductance.to_f
      @emissivity = emissivity.to_f
      @radiating_area_m2 = radiating_area_m2.to_f
      raise Error, "conductance must be positive" unless @conductance.positive?

      freeze
    end

    def radiative? = (@emissivity * @radiating_area_m2).positive?

    # The same factoring `Concerns::Thermal` uses, with the far end standing in for the sink:
    # `T_h⁴ − T_c⁴ ≡ (T_h² + T_c²)(T_h + T_c)·(T_h − T_c)`, so the bracketed part is a
    # conductance and the whole thing stays inside one backward-Euler solve.
    def radiative_conductance(temperature_a, temperature_b)
      return 0.0 unless radiative?
      return 0.0 unless temperature_a.positive? && temperature_b.positive?

      @emissivity * @radiating_area_m2 * Units::STEFAN_BOLTZMANN *
        ((temperature_a**2) + (temperature_b**2)) * (temperature_a + temperature_b)
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
  # **Geared**: with `ratio` g the torque is `k·(g·ω_a − ω_b)`, `b` gains `τ·dt` of momentum and
  # `a` loses `g·τ·dt`, because a gear multiplies torque. Momentum is not conserved across a gear;
  # energy is, and the slip is `τ·(g·ω_a − ω_b)`, never negative. A reverser is `g = −1`.
  #
  # **Clutched**: `control_id` scales the conductance by the lever, and a disengaged link drops out
  # of the network. Two links between one pair — forward and reverse — need their own `id`.
  # `cut_by:` names a node that can throw the clutch out whatever the lever says — an overwind
  # trip cutting the drive — by answering `cuts_drive?(ctx)`.
  class DriveLink
    attr_reader :a, :b, :conductance, :max_torque, :ratio, :control_id, :id, :cut_by

    def initialize(a:, b:, stiffness:, max_torque: Float::INFINITY, ratio: 1.0, control_id: nil,
                   id: nil, cut_by: nil)
      @a = a.to_sym
      @b = b.to_sym
      @conductance = stiffness.to_f
      @max_torque = max_torque.to_f
      @ratio = ratio.to_f
      @control_id = control_id&.to_sym
      @id = (id || :"#{@a}=#{@b}").to_sym
      @cut_by = cut_by&.to_sym
      raise Error, "stiffness must be positive" unless @conductance.positive?
      raise Error, "drive link #{@id}: ratio must not be zero" if @ratio.zero?

      freeze
    end

    # This link as the solve sees it this tick: its conductance scaled by the clutch, or nil when
    # the clutch is out or cut.
    def engaged(controls, ctx = nil)
      return nil if cut?(ctx)
      return self unless @control_id

      fraction = (controls.fetch(@control_id, 0.0) / 100.0).clamp(0.0, 1.0)
      return nil unless fraction.positive?

      DriveLink.new(a: @a, b: @b, stiffness: @conductance * fraction, max_torque: @max_torque,
                    ratio: @ratio, id: @id)
    end

    def cut?(ctx)
      return false unless @cut_by && ctx

      ctx.nodes[@cut_by]&.cuts_drive?(ctx) || false
    end
  end
end
