# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"
require "support/pit_rig"

# **What the winding rope is made of**: hemp, iron wire or steel wire, each a part in the rope slot.
# The rope's own weight is load on it and on the drum, and the sheave carries what the ropes pull.
# See `design_sketches/mine-accidents-unit3b.md` §6b.
RSpec.describe "rope tiers" do
  include Constructed
  include PitRig

  def pit(rope) = build_pit(id: "r", seed: 5, loadout: { winder: :cage_gear, rope: rope }, crew: {})

  def ctx(op, cargo: 0.0)
    ReactorSim::Tick::Context.new(controls: {}, dt: 0.25, nodes: op.nodes, states: op.state.fetch(:nodes),
                                  cargo: { cage_drive: cargo })
  end

  def at(op, depth_m) = seed(op, nodes: { cage_drive: { position_m: depth_m } })

  let(:g) { ReactorSim::Units::GRAVITY_M_PER_S2 }

  it "fits the rope a tier names" do
    ReactorSim::Operations::Mine::ROPES.each do |id, tier|
      rope = pit(id).nodes.fetch(:winding_rope)

      expect([ rope.breaking_kn, rope.kg_per_m ]).to eq(tier.values_at(:breaking_kn, :kg_per_m))
    end
  end

  it "carries its own weight below the sheave, with the cage empty" do
    op = at(pit(:iron_wire_rope), 80.0)
    rope = op.nodes.fetch(:winding_rope)
    cage_kg = op.nodes.fetch(:cage_drive).cage_kg

    expect(rope.tension_n(ctx(op))).to be_within(1e-6).of((cage_kg + (5.5 * 80.0)) * g)
  end

  it "makes the drum lift the longer side's rope" do
    op = at(pit(:iron_wire_rope), 90.0)
    drum = op.nodes.fetch(:cage_drive)

    expect(drum.drive_torque(op.state.dig(:nodes, :cage_drive), ctx(op)))
      .to be_within(1e-6).of(g * drum.radius_m * 5.5 * 90.0)
  end

  it "presses the sheave harder with a laden cage than an empty one" do
    op = at(pit(:steel_wire_rope), 45.0)
    rope = op.nodes.fetch(:winding_rope)

    expect(rope.bearing_load_n(ctx(op, cargo: 1_000.0)) - rope.bearing_load_n(ctx(op)))
      .to be_within(1e-6).of(Math.sqrt(2.0) * 1_000.0 * g)
  end

  it "parts a worn hemp rope under a laden cage where a steel one holds" do
    worn = ->(op) { seed(op, nodes: { winding_rope: { durability: 0.2 * op.state.dig(:nodes, :winding_rope, :initial_durability) } }) }
    laden = ->(op) { seed(op, nodes: { cage_deck: { parcels: parcels_at(PitRig::AMBIENT_K, coal: 950.0) } }) }
    hemp = worn.(laden.(at(pit(:hemp_rope), 60.0)))
    steel = worn.(laden.(at(pit(:steel_wire_rope), 60.0)))
    [ hemp, steel ].each { |op| run!(op, 4) }

    expect(hemp.state.dig(:nodes, :winding_rope, :failure)).to be(:parted)
    expect(steel.state.dig(:nodes, :winding_rope, :failure)).to be_nil
  end
end
