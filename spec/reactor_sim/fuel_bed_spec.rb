# frozen_string_literal: true

require "reactor_sim"
require "support/engine_rig"
require "support/conservation"

# **The fire as a bed of its own**: the coal on the grate at its own temperature, the gas over it in
# the firebox. Zero ticks for the arithmetic, a few from the stationary engine at work or banked for
# the rest. Relational — no figure here is a tuning target. See `design_sketches/coal-bed.md` §9.
RSpec.describe ReactorSim::Nodes::FuelBed, crew: :reference do
  include EngineRig

  def bed(op) = op.nodes.fetch(:fire_bed)
  def lit_kg(op) = node_state(op, :fire_bed).dig(:ignition, :coal_combustion, :kg).to_f
  def share(op) = bed(op).radiant_share(node_state(op, :fire_bed), op.content)
  def levers(lever) = Struct.new(:controls).new({ damper_open: lever })

  describe "the bed" do
    # A lit lump lasts about a quarter of an hour, so what is on the grate is minutes of burning.
    it "holds minutes of burning on its grate at work" do
      op = at_work(engine)
      burning_kg_per_s = lit_kg(op) * op.content.reaction(:coal_combustion).fetch(:rate_per_s)

      expect(held(op, :fire_bed, :coal) / burning_kg_per_s).to be > 600.0
    end

    it "burns down over minutes unstoked, not seconds" do
      op = at_work(engine)
      was = lit_kg(op)
      run!(op, 40, stoking: 0)

      expect(lit_kg(op)).to be > 0.9 * was
    end

    it "is deeper the more is on it" do
      shallow = at_work(engine, coal: 50.0)
      deep = at_work(engine, coal: 300.0)

      expect(bed(deep).depth_m(node_state(deep, :fire_bed), deep.content))
        .to be > bed(shallow).depth_m(node_state(shallow, :fire_bed), shallow.content)
    end

    # **Short of air the lit coal goes to carbon monoxide**: the pathway, and the firebox smokes.
    it "makes monoxide with the damper shut on a working bed" do
      shut = at_work(engine)
      open = at_work(engine)
      run!(shut, 20, damper_open: 0)
      run!(open, 20)

      expect(held(shut, :firebox, :whitedamp)).to be > held(open, :firebox, :whitedamp)
    end
  end

  describe "the grate" do
    it "draws less through a thicker bed" do
      shallow = at_work(engine, coal: 50.0)
      deep = at_work(engine, coal: 400.0)
      run!(shallow, 2, stoking: 0)
      run!(deep, 2, stoking: 0)

      expect(draught_kg(deep)).to be < draught_kg(shallow)
    end
  end

  describe "a damper set to zero" do
    it "still passes its leak, and a valve declaring none passes nothing" do
      damper = engine.nodes.fetch(:damper)
      sealed = ReactorSim::Nodes::Conduit.new(id: :sealed, max_kg_per_s: 1.0, conductance: 1.0, control_id: :damper_open)

      expect(damper.open_fraction(levers(0.0))).to eq(damper.leak_fraction)
      expect(damper.leak_fraction).to be_positive
      expect(damper.open_fraction(levers(100.0))).to eq(1.0)
      expect(sealed.open_fraction(levers(0.0))).to eq(0.0)
    end
  end

  # **What holds a banked core hot**: only the glowing share of a bed radiates, so a small core under
  # green coal hardly loses anything to the water.
  describe "radiance" do
    it "glows by the share of it alight" do
      expect(share(engine)).to be < 0.05
      expect(share(at_work(engine))).to be > 0.9
    end

    it "leaves a radiant link between two nodes that answer no share as it was" do
      link = ReactorSim::ThermalLink.new(a: :a, b: :b, conductance: 10.0, emissivity: 0.9, radiating_area_m2: 2.0)
      plain = Struct.new(:id)
      nodes = { a: plain.new(:a), b: plain.new(:b) }
      coupling = ReactorSim::Arbiter.heat_couplings([ link ], { a: 1_000.0, b: 400.0 }, nodes, { a: {}, b: {} }, nil).first

      expect(coupling.conductance).to eq(10.0 + link.radiative_conductance(1_000.0, 400.0))
    end
  end

  describe "banked" do
    # The engine is built banked: the damper shut and the core under its green coal stays alight and
    # above coal's ignition point, where the same bed opened up and unstoked burns.
    it "keeps its core alight and hot with the damper at zero" do
      op = engine
      run!(op, 40, damper_open: 0, stoking: 0, throttle_open: 0, load_demand: 0)
      ignites_k = op.content.reaction(:coal_combustion).fetch(:min_temperature_k)

      expect(lit_kg(op)).to be_positive
      expect(temperature_k(op, :fire_bed)).to be > ignites_k
      expect(temperature_k(op, :fire_bed)).to be > temperature_k(op, :firebox)
    end
  end

  it "closes mass and energy bringing a banked fire through" do
    op = engine
    mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    op.assign_minion(:crew_2, :blower)
    run!(op, 40, blower: 100, throttle_open: 0, load_demand: 0)

    expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass).abs / mass.abs).to be < Conservation::TOLERANCE
    expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules).abs / joules.abs)
      .to be < Conservation::TOLERANCE
  end
end
