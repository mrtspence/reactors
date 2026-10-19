# frozen_string_literal: true

require "reactor_sim"
require "support/conservation"
require "support/ignition_rig"

# **A room's walls at their own temperature.** A district's gas and the rock round it are different
# temperatures, so they are different nodes: the hot gas a blast leaves loses its heat to the rock
# face in seconds, and the rock warms a little and passes it on into the ground. A face left hot
# enough lights the next gas with no flame near it. See `design_sketches/prompt-reactions.md` §4.
RSpec.describe "walls" do
  let(:content) { ReactorSim::Content.default }

  def rock(temperature_k: 293.15, area_m2: 2_000.0)
    ReactorSim::Nodes::Wall.new(id: :rock, material: :coal_measures, area_m2: area_m2, skin_m: 0.02,
                                content: content, initial_temperature_k: temperature_k)
  end

  def face(area_m2: 2_000.0)
    ReactorSim::ThermalLink.new(a: :district, b: :rock, conductance: 15.0 * area_m2,
                                emissivity: 0.2, radiating_area_m2: area_m2)
  end

  # A district of hot flue gas, as a blast leaves it.
  def burnt(temperature_k = 2_400.0)
    ReactorSim::Nodes::Vessel.new(id: :district, volume_m3: 1_400.0, heat_capacity: 2.0e4,
                                  initial_temperature_k: temperature_k,
                                  initial_contents: [ { resource: :flue_gas, kg: 1_600.0,
                                                        temperature_k: temperature_k } ])
  end

  def op(nodes, links = [])
    ReactorSim::Operation.new(id: :rig, type: :test, seed: 1, nodes: nodes, thermal_links: links)
  end

  def run(operation, ticks) = ticks.times { |i| operation.step!(tick: i + 1) }

  def temperature(operation, id)
    operation.nodes.fetch(id).temperature_k(operation.state.dig(:nodes, id), operation.content)
  end

  it "is a skin of its material, holding and passing heat by its own figures" do
    wall = rock
    skin = 2_000.0 * 0.02

    expect(wall.heat_capacity).to eq(skin * content.density(:coal_measures) * content.specific_heat(:coal_measures))
    expect(wall.ambient_conductance).to eq(2_000.0 * content.thermal_conductivity_w_per_m_k(:coal_measures) / 0.02)
  end

  it "refuses a material that does not say how it conducts" do
    expect { ReactorSim::Nodes::Wall.new(id: :w, material: :coal, area_m2: 1.0, skin_m: 0.01, content: content) }
      .to raise_error(ReactorSim::Error, /coal.*thermal_conductivity_w_per_m_k/)
  end

  # Measured, sealed: 2,400 K → 1,486 K in five seconds, 923 K in twenty, 549 K in a minute; the
  # rock face peaks about 36 K warm and then soaks it away into the ground.
  it "takes a blast's heat out of the gas in seconds, and warms the rock only a little" do
    walled = op([ burnt, rock ], [ face ])
    bare = op([ burnt ])
    [ walled, bare ].each { |o| run(o, 80) }

    expect(temperature(walled, :district)).to be < 1_000.0
    expect(temperature(bare, :district)).to be > 2_300.0
    expect(temperature(walled, :rock) - 293.15).to be_between(1.0, 50.0)
  end

  describe "hot strata" do
    # A district at 9% firedamp whose fuel touches the rock.
    def gassy(rock_k)
      district = ReactorSim::Nodes::Vessel.new(
        id: :district, volume_m3: IgnitionRig::VOLUME_M3, heat_capacity: 2.0e4,
        initial_temperature_k: IgnitionRig::AMBIENT_K, hot_spot: %i[rock],
        initial_contents: [ { resource: :air, kg: IgnitionRig::AIR_KG },
                            { resource: :firedamp, kg: IgnitionRig.firedamp_kg(0.09, IgnitionRig::AIR_KG) } ]
          .map { |p| p.merge(temperature_k: IgnitionRig::AMBIENT_K) },
        reactions: %i[firedamp_combustion]
      )
      op([ district, rock(temperature_k: rock_k) ])
    end

    def fired?(operation) = 3.times.flat_map { |i| operation.step!(tick: i + 1) }.any? { |e| e[:type] == :explosion }

    let(:autoignition_k) { content.reaction(:firedamp_combustion).dig(:ignition, :autoignition_k) }

    it "light gas past its ignition point with no flame near it, where cooler strata do not" do
      expect(fired?(gassy(autoignition_k + 30.0))).to be(true)
      expect(fired?(gassy(autoignition_k - 30.0))).to be(false)
    end
  end

  it "conserves energy as the gas cools into it" do
    walled = op([ burnt, rock ], [ face ])
    joules0 = ReactorSim::Ledger.energy_balance(walled.total_joules, walled.ledger)
    run(walled, 20)

    joules = ReactorSim::Ledger.energy_balance(walled.total_joules, walled.ledger)
    expect((joules - joules0).abs / joules0.abs).to be < Conservation::TOLERANCE
  end
end
