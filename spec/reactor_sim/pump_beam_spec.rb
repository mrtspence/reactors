# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"
require "support/pit_rig"

# **The Cornish set's beam, and Hartley.** The beam is a power sink on the line shaft that works the
# pump; it wears per stroke, breaks on a surge, and broken it falls into the shaft. See
# `design_sketches/mine-accidents-unit3b.md` §5.
RSpec.describe "the Cornish beam" do
  include Constructed
  include PitRig

  let(:beam_class) { ReactorSim::Operations::Mine::PumpBeam }

  def cornish(chassis: :two_shaft, crew: {}) = build_pit(id: "c", seed: 3, crew: crew, chassis: chassis,
                                                         loadout: { pump: :cornish_set })

  def wet(op) = seed(op, nodes: { pit_bottom: { parcels: parcels_at(PitRig::AMBIENT_K, air: 1_100.0,
                                                                                     water: 8_000.0) } })

  def beam(op) = op.state.fetch(:nodes).fetch(:pump_beam)

  def omega_of(op, id) = op.nodes.fetch(id).omega(op.state.fetch(:nodes).fetch(id))

  # The beam's state at a multiple of working speed.
  def turning(node, ratio) = { angular_momentum: node.moment_of_inertia * ratio * ReactorSim::Operations::Mine::WORKING_OMEGA }

  # Both shafts already at working speed, and the beam all but worn through.
  def failing(op)
    spin = ->(id) { { angular_momentum: op.nodes.fetch(id).moment_of_inertia * ReactorSim::Operations::Mine::WORKING_OMEGA } }
    seed(op, nodes: { line_shaft: spin.(:line_shaft), pump_beam: spin.(:pump_beam).merge(durability: 1.0e-3) })
  end

  # What the beam reads of the pump: how much it carried last tick.
  Ctx = Struct.new(:dt, :states) do
    def node_state(id) = states[id]
  end

  it "is driven off the line shaft, and works the pump" do
    op = wet(cornish)
    run!(op, 20)

    expect(op.nodes.fetch(:pump).driven_by).to be(:pump_beam)
    expect(omega_of(op, :pump_beam)).to be_within(0.1 * omega_of(op, :line_shaft)).of(omega_of(op, :line_shaft))
    expect(op.state.dig(:nodes, :pump, :carried_kg)).to be > 0.0
  end

  it "wears harder lifting water than running light, and not at all standing" do
    node = cornish.nodes.fetch(:pump_beam)
    lifting = Ctx.new(0.25, { pump: { carried_kg: 26.0 * 0.25 } })
    light = Ctx.new(0.25, { pump: { carried_kg: 0.0 } })

    expect(node.stress_per_second(turning(node, 1.0), lifting))
      .to be_within(1e-12).of(beam_class::STROKE_PER_S)
    expect(node.stress_per_second(turning(node, 1.0), light))
      .to be_within(1e-12).of(beam_class::STROKE_PER_S * beam_class::UNLADEN)
    expect(node.stress_per_second(turning(node, 0.0), lifting)).to eq(0.0)
  end

  it "breaks on a surge, and sooner when worn" do
    node = cornish.nodes.fetch(:pump_beam)

    expect(node.overload?(turning(node, 1.4), nil, 1.0)).to be(false)
    expect(node.overload?(turning(node, 1.6), nil, 1.0)).to be(true)
    expect(node.overload?(turning(node, 1.3), nil, 0.5)).to be(true)
  end

  it "falls into the shaft and chokes it, stopping the pump" do
    op = failing(wet(cornish))
    run!(op, 5)

    expect(beam(op).fetch(:failure)).to be(:broken)
    expect(op.state.dig(:nodes, :shaft, :failure)).to be(:choked)
    expect(op.state.dig(:nodes, :pump, :carried_kg).to_f).to eq(0.0)
  end

  it "tears out the brattice in a single shaft" do
    op = failing(wet(cornish(chassis: :single_shaft)))
    run!(op, 5)

    expect(op.state.dig(:nodes, :brattice, :failure)).not_to be_nil
  end
end
