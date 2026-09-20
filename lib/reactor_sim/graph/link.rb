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
    # thing every fireman knows — that a *bright* fire is worth far more than a merely hot one.
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
  # TODO: **the steam engine's coupling dissipates 60% of its shaft power, and the cause is not
  # here.** `Load#apply` integrates its brake explicitly and runs past the stability limit at
  # working speed, so the mill is spun up and slammed to a standstill every tick; the coupling
  # then slips ~100% against a load that is stationary whenever it is read. Measured: flywheel
  # 18.24 rad/s, load 0.13 rad/s, yet the load extracting 40 kJ a tick — which is 14.1 rad/s of
  # kinetic energy, not 0.13.
  #
  # **Fix the integrator first and re-measure before touching `stiffness:`.** Stiffening a
  # coupling into a ratchet transmits more torque and dissipates more. See
  # `docs/design_sketches/bearings.md` §1.1.
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
