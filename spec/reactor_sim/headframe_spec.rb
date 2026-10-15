# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"
require "support/pit_rig"

# **Fire on the intake.** A timber headframe catches from the sheave it carries, its smoke goes
# down the shaft with the air, a reversible fan sends it back up, and burnt through the frame comes
# down. See `design_sketches/mine-accidents-unit3b.md` §6.
RSpec.describe "the headframe" do
  include Constructed
  include PitRig

  def pit(**loadout) = build_pit(id: "f", seed: 3, crew: {}, loadout: loadout)

  # The sheave dry and past timber's ignition point.
  def hot_sheave(op) = seed(op, nodes: { sheave: { joules: op.nodes.fetch(:sheave).heat_capacity * 650.0, parcels: [] } })

  def lit_kg(op) = op.state.dig(:nodes, :headframe, :ignition, :wood_combustion, :kg).to_f

  it "catches from a sheave hot enough, where an iron one has nothing to catch" do
    timber = hot_sheave(pit)
    iron = hot_sheave(pit(headframe: :iron_headframe))
    cool = pit
    [ timber, iron, cool ].each { |op| run!(op, 10) }

    expect(lit_kg(timber)).to be > 0.0
    expect(lit_kg(iron)).to eq(0.0)
    expect(lit_kg(cool)).to eq(0.0)
  end

  it "draws the same share of the intake whatever it is made of" do
    timber = pit
    iron = pit(headframe: :iron_headframe)
    [ timber, iron ].each { |op| run!(op, 20) }

    drawn = timber.state.dig(:nodes, :headframe_smoke, :carried_kg)
    expect(iron.state.dig(:nodes, :headframe_smoke, :carried_kg)).to be_within(0.01 * drawn).of(drawn)
  end

  # Smoke standing in the frame: the fan draws it down the shaft, and reversed sends it back up.
  it "sends its smoke down the shaft, and a reversed fan sends it back up" do
    smoky = ->(reversed) do
      op = pit(fan: :reversible_fan)
      seed(op, nodes: { headframe: { parcels: parcels_at(PitRig::AMBIENT_K, air: 110.0, flue_gas: 250.0,
                                                                         wood: 4_000.0) } },
               controls: { fan_reversed: { target: reversed, actual: reversed } })
    end
    forward = smoky.(0.0)
    reversed = smoky.(100.0)
    [ forward, reversed ].each { |op| run!(op, 20) }

    # Reversed, only the first tick's draw gets in before the pressures turn round.
    expect(held(forward, :pit_bottom, :flue_gas)).to be > 1.0
    expect(held(reversed, :pit_bottom, :flue_gas)).to be < held(forward, :pit_bottom, :flue_gas) / 5.0
  end

  it "costs the same to turn reversed as forward" do
    fan = pit(fan: :reversible_fan).nodes.fetch(:upcast)
    ctx = ->(reversed) { ReactorSim::Tick::Context.new(controls: { ventilation: 100.0, fan_reversed: reversed }, dt: 0.25, states: {}, nodes: {}) }

    expect(fan.hydraulic_w({ carried_m3: 3.0 }, ctx.(100.0))).to eq(fan.hydraulic_w({ carried_m3: 3.0 }, ctx.(0.0)))
    expect(fan.head_pa(ctx.(100.0))).to eq(-fan.head_pa(ctx.(0.0)))
  end

  it "comes down burnt through, and brings the sheave down with it" do
    op = pit
    left = (op.nodes.fetch(:headframe).timber_kg * (1.0 - ReactorSim::Operations::Mine::Headframe::BURNT_THROUGH)) - 100.0
    op = seed(op, nodes: { headframe: { parcels: parcels_at(PitRig::AMBIENT_K, air: 360.0, wood: left) } })
    run!(op, 4)

    expect(op.state.dig(:nodes, :headframe, :failure)).to be(:collapsed)
    expect(op.state.dig(:nodes, :sheave, :failure)).not_to be_nil
    expect(op.nodes.fetch(:shaft).integrity(op.state.dig(:nodes, :shaft))).to be < 0.5
  end
end
