# frozen_string_literal: true

require "reactor_sim"

# **A fuel hot enough lights itself.** Past a reaction's `autoignition_k` the fire seeds itself, read
# against the node's own temperature or the hottest thing its fuel touches (`Vessel#hot_spot`) — a
# timber headframe on a seized sheave. See `design_sketches/mine-accidents-unit3b.md` §4.
RSpec.describe "self-ignition" do
  def timber(temperature_k: 290.0, hot_spot: nil)
    ReactorSim::Nodes::Vessel.new(
      id: :timber, volume_m3: 20.0, heat_capacity: 1.0e3, initial_temperature_k: temperature_k,
      initial_contents: [ { resource: :wood, kg: 20.0 }, { resource: :air, kg: 20.0 } ],
      reactions: %i[wood_combustion], hot_spot: hot_spot
    )
  end

  def bearing(temperature_k)
    ReactorSim::Nodes::Vessel.new(id: :bearing, volume_m3: 0.01, heat_capacity: 1.0e3,
                                  initial_temperature_k: temperature_k)
  end

  def lit_after(nodes, ticks: 4)
    op = ReactorSim::Operation.new(id: :rig, type: :self_ignition_rig, seed: 1, nodes: nodes)
    ticks.times { |t| op.step!(tick: t + 1) }
    op.state.dig(:nodes, :timber, :ignition, :wood_combustion, :kg)
  end

  let(:autoignition_k) { ReactorSim::Content.default.reaction(:wood_combustion).dig(:ignition, :autoignition_k) }

  it "lights timber held past its autoignition temperature, with nothing alight beside it" do
    expect(lit_after([ timber(temperature_k: autoignition_k + 5.0) ])).to be > 0.0
    expect(lit_after([ timber(temperature_k: autoignition_k - 5.0) ])).to eq(0.0)
  end

  it "lights cold timber against a hot spot past it, and not against a cooler one" do
    expect(lit_after([ timber(hot_spot: :bearing), bearing(autoignition_k + 20.0) ])).to be > 0.0
    expect(lit_after([ timber(hot_spot: :bearing), bearing(autoignition_k - 20.0) ])).to eq(0.0)
  end

  it "leaves a reaction with no autoignition temperature needing a light" do
    spec = ReactorSim::Content.default.reaction(:oil_combustion)

    expect(ReactorSim::Resources::Ignition.self_seed_kg(spec, 5_000.0, 0.25)).to eq(0.0)
  end
end
