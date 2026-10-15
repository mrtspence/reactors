# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"
require "support/pit_rig"

# **Goaf falls and the windblast.** The roof behind the face hangs as the face advances, less what has
# been packed, and falls at spans drawn per match: the gas is flushed out and the air driven down the
# roads. See `design_sketches/mine-accidents-unit3b.md` §7.
RSpec.describe "goaf falls" do
  include Constructed
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  let(:goaf_class) { ReactorSim::Operations::Mine::OldWorkings }

  def goaf(op) = op.state.dig(:nodes, :goaf)

  # The face `advance_m` in, with `spans` ahead of the roof.
  def worked(advance_m:, spans:, **goaf_state)
    op = build_pit(id: "g", seed: 3)
    won = advance_m * ReactorSim::Operations::Mine::Ahead::FACE_KG_PER_M
    coal = ReactorSim::Operations::Mine::SEAM_KG - won
    seed(op, nodes: { seam: { parcels: parcels_at(PitRig::AMBIENT_K, coal: coal, firedamp: 4_000.0) },
                      goaf: { spans: spans, **goaf_state } })
  end

  it "draws spans log-normally, the first weighting the largest" do
    node = build_pit(id: "g", seed: 3).nodes.fetch(:goaf)
    draws = ->(median) { (1..2_000).map { |s| node.span(ReactorSim::Rng.stream(s, :goaf), median) }.sort[1_000] }

    expect(draws.(goaf_class::FIRST_SPAN_M)).to be_within(0.5).of(goaf_class::FIRST_SPAN_M)
    expect(draws.(goaf_class::SPAN_M)).to be_within(0.3).of(goaf_class::SPAN_M)
  end

  it "draws no spans for a spec that pins the ground" do
    expect(goaf(build_pit(id: "g", seed: 3)).fetch(:spans)).to eq([])
  end

  it "hangs by the coal won, and less where it has been packed" do
    bare = worked(advance_m: 1.0, spans: [ 6.0 ])
    packed = at_the_face(worked(advance_m: 1.0, spans: [ 6.0 ]), hewing: nil, haulage: nil, timbering: nil)
    packed = seed(packed, minions: { crew_1: { posting: :packing, station: :packing, place: :district } })
    [ bare, packed ].each { |op| run!(op, 8) }

    expect(goaf(bare).fetch(:hanging_m)).to be_within(1e-6).of(1.0)
    expect(goaf(packed).fetch(:packed_m)).to be_positive
    expect(goaf(packed).fetch(:hanging_m)).to be < goaf(bare).fetch(:hanging_m)
  end

  it "falls past its span, hurting the district, and starts hanging again toward the next" do
    op = worked(advance_m: 6.5, spans: [ 6.0, 3.0 ])
    op = seed(op, minions: { crew_1: { place: :district, posting: nil, station: nil, progress: 0.0,
                                       remaining: 0.0, journey: 0.0 } })
    events = run!(op, 4)

    fell = events.find { |e| e[:type] == :part_failed && e[:node] == :goaf }
    expect(fell).to include(mode: :fell)
    expect(events.map { |e| e[:type] }).to include(:minion_hurt)
    expect(goaf(op).fetch(:spans)).to eq([ 3.0 ])
    expect(goaf(op).fetch(:hanging_m)).to eq(0.0)
    expect(goaf(op).fetch(:flushing_s)).to be_positive
  end

  it "drives its gas out while it is falling" do
    falling = worked(advance_m: 6.5, spans: [ 6.0 ])
    quiet = worked(advance_m: 1.0, spans: [ 6.0 ])
    [ falling, quiet ].each { |op| run!(op, 12) }

    expect(held(falling, :pit_bottom, :blackdamp)).to be > held(quiet, :pit_bottom, :blackdamp) * 10.0
  end

  it "is quiet again once the flush is spent" do
    op = worked(advance_m: 6.5, spans: [ 9.0 ], failure: :fell, flushing_s: 0.2, fallen_at_m: 6.5)
    run!(op, 2)

    expect(goaf(op).fetch(:failure)).to be_nil
    expect(goaf(op).fetch(:flushing_s)).to eq(0.0)
  end
end
