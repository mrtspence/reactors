# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"
require "support/pit_rig"

# **What an inrush does to the people in its way.** Water to the roof of the pit bottom leaves no
# air there to breathe, and closes every way that runs through it — the shaft's and the main road —
# so the district above becomes an air pocket. See `design_sketches/mine-accidents-unit3b.md` §3.
RSpec.describe "inundation" do
  include Constructed
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::TIRING_CONTENT) }

  let(:sump) { ReactorSim::Operations::Mine::Sump }

  def flooded(chassis: :two_shaft, water: sump::ROOF_KG + 500.0, **minions)
    op = build_pit(id: "i", seed: 3, chassis: chassis)
    bottom = parcels_at(PitRig::AMBIENT_K, air: PitRig::BOTTOM_AIR_KG, water: water)
    seed(op, nodes: { pit_bottom: { parcels: bottom } }, minions: minions)
  end

  def standing(place, **posting)
    { place: place, posting: nil, station: nil, progress: 0.0, remaining: 0.0, journey: 0.0, **posting }
  end

  def breathable_air(op) = ReactorSim::Tick.new(op, op.state).send(:breathable_air, op.state.fetch(:nodes))

  it "breathes the gas in a room, and none of the water standing in it" do
    wet = flooded(water: sump::ROOF_KG - 500.0)
    dry = flooded(water: 0.0)

    expect(breathable_air(wet).fetch(:pit_bottom)).to eq(breathable_air(dry).fetch(:pit_bottom))
  end

  it "is drowned, and in the way, from the roof mark up" do
    node = build_pit(id: "i", seed: 3).nodes.fetch(:pit_bottom)
    content = PitRig::TIRING_CONTENT
    state = ->(kg) { { parcels: parcels_at(PitRig::AMBIENT_K, air: 1_100.0, water: kg) } }

    expect(node.submerged?(state.(sump::ROOF_KG - 1.0), content)).to be(false)
    expect(node.submerged?(state.(sump::ROOF_KG), content)).to be(true)
    expect(node.blocks_passage?(state.(sump::ROOF_KG), content)).to be(true)
    expect(breathable_air(flooded).fetch(:pit_bottom)).to eq(0.0)
  end

  it "drowns whoever is in the pit bottom and leaves the district breathing" do
    op = flooded(crew_4: standing(:pit_bottom), crew_1: standing(:district))
    run!(op, 20)

    expect(crew(op, :crew_4).fetch(:fatigue)).to be > 0.09
    expect(crew(op, :crew_1).fetch(:fatigue)).to eq(0.0)
  end

  # Through the far shaft where there is one, and nowhere where there is not: the district is an
  # air pocket.
  it "sends the district out the long way, or strands it" do
    two = flooded(crew_1: standing(:district))
    two.assign_minion(:crew_1, :quarters)
    run!(two, 1)

    one = flooded(chassis: :single_shaft, crew_1: standing(:district))
    one.assign_minion(:crew_1, :quarters)
    run!(one, 1)

    expect(crew(two, :crew_1).fetch(:journey)).to be_within(1.0).of(ReactorSim::Operations::Mine.escape.metres)
    expect(crew(one, :crew_1).fetch(:place)).to be(:district)
    expect(crew(one, :crew_1).fetch(:journey)).to eq(0.0)
  end

  # Read by the borer, so somebody is boring.
  def plans(water_at_m)
    op = at_the_face(build_pit(id: "i", seed: 3))
    op = seed(op, nodes: { seepage: { waters: water_at_m ? [ { at_m: water_at_m, kg: 40_000.0 } ] : [] } },
                  minions: { crew_4: { posting: :boring, station: :boring, place: :district } })
    run!(op, 12)
    op.project(viewer: :player).to_h.dig(:gauges, :survey)
  end

  it "reads the barrier between the face and the old workings from the plans" do
    expect(plans(0.4)).to eq("water standing in the cut")
    expect(plans(nil)).to eq("forty yards of solid coal")
  end

  describe "what lies ahead of the face" do
    let(:ahead) { ReactorSim::Operations::Mine::Ahead }
    let(:inrush) { ReactorSim::Operations::Mine::Inrush }

    # **Drawn with the ground**: none, one or two, never in the first couple of metres.
    it "is none, one or two bodies of water, never in the first couple of metres" do
      draws = (1..2_000).map { |seed| ahead.depths(ReactorSim::Rng.stream(seed, :ahead)) }
      shares = draws.map(&:size).tally.transform_values { |n| n / 2_000.0 }

      expect(shares.fetch(0)).to be_within(0.04).of(0.5)
      expect(shares.fetch(1)).to be_within(0.04).of(0.45)
      expect(shares.fetch(2)).to be_within(0.02).of(0.05)
      expect(draws.flatten.min).to be >= ahead::DEPTHS_M.begin
    end

    it "draws no water at all for a spec that pins the ground" do
      expect(build_pit(id: "i", seed: 3).state.dig(:nodes, :seepage, :waters)).to eq([])
    end

    it "weeps harder as the barrier thins" do
      node = build_pit(id: "i", seed: 3).nodes.fetch(:seepage)

      expect(node.weeping(inrush::WEEPS_WITHIN_M)).to eq(1.0)
      expect(node.weeping(0.0)).to eq(inrush::WEEPS_UP_TO)
    end

    # A body of water runs out, and what lies beyond it is the next event.
    it "goes back to a seep once a body's tonnes are through, with the next one ahead" do
      op = build_pit(id: "i", seed: 3)
      op = seed(op, nodes: { seepage: { failure: :inrush, durability: 0.0, drained_kg: 39_990.0,
                                        waters: [ { at_m: 0.0, kg: 40_000.0 }, { at_m: 9.0, kg: 30_000.0 } ] } })
      run!(op, 4)

      state = op.state.dig(:nodes, :seepage)
      expect(state.fetch(:failure)).to be_nil
      expect(state.fetch(:waters).map { |w| w.fetch(:at_m) }).to eq([ 9.0 ])
    end
  end
end
