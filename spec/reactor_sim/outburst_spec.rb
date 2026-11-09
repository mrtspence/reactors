# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"
require "support/pit_rig"

# **Sudden outbursts.** Gas held in the coal ahead of the face, drawn per match and told to nobody:
# the face reaching a pocket empties it into the district in seconds, and an auger driven ahead
# finds it and draws it off first. See `design_sketches/mine-accidents-unit3b.md` §7.
RSpec.describe "sudden outbursts" do
  include Constructed
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  let(:pocket) { ReactorSim::Operations::Mine::GasPocket }

  # A pocket of `firedamp_kg` at `at_m`, with the face at its starting place.
  def with_pocket(at_m:, firedamp_kg: 150.0, borer: false)
    op = at_the_face(build_pit(id: "o", seed: 3), hewing: :crew_1, haulage: :crew_2,
                                                  timbering: (borer ? nil : :crew_3))
    op = seed(op, nodes: { gas_pocket: { parcels: parcels_at(PitRig::AMBIENT_K, firedamp: firedamp_kg),
                                         pockets: [ { at_m: at_m, coal_t: 20.0, kg: firedamp_kg } ] } })
    op = seed(op, minions: { crew_3: { posting: :boring, station: :boring, place: :district } }) if borer
    op
  end

  def district_firedamp(op) = held(op, :district, :firedamp)

  describe "the draw" do
    # **Heavy-tailed, as real outbursts are**: most a few tonnes to a few tens of tonnes of coal,
    # the rare one hundreds — and the gas goes with the coal.
    it "sizes a pocket log-normally on the coal it throws" do
      coal = (1..2_000).map { |seed| pocket.drawn(ReactorSim::Rng.stream(seed, :pocket), 5.0, 1.0).fetch(:coal_t) }.sort

      expect(coal[1_000]).to be_within(3.0).of(pocket::COAL_MEDIAN_T)
      expect(coal[1_800] / coal[200]).to be > 10.0
      expect(coal.first).to be >= (pocket::COAL_MEDIAN_T * Math.exp(-pocket::COAL_SIGMA * pocket::COAL_TAIL)) - 1e-9
    end

    it "makes a gassier ground's pocket hold more gas for the same coal" do
      rng = -> { ReactorSim::Rng.stream(7, :pocket) }

      expect(pocket.drawn(rng.(), 5.0, 2.0).fetch(:firedamp_kg))
        .to be_within(1e-9).of(2.0 * pocket.drawn(rng.(), 5.0, 1.0).fetch(:firedamp_kg))
    end

    it "draws no pockets for a spec that pins the ground" do
      expect(build_pit(id: "o", seed: 3).state.dig(:nodes, :gas_pocket, :pockets)).to eq([])
    end
  end

  # A gram of coal ahead of the face, so any cutting at all reaches it on the first tick and the
  # claim does not depend on how fast a face cuts.
  AT_THE_FACE_M = 0.001 / ReactorSim::Operations::Mine::Ahead::FACE_KG_PER_M

  def driven(naked_flame:)
    op = with_pocket(at_m: AT_THE_FACE_M)
    levers!(op, hewing: 100, haulage: 100, timbering: 100, naked_flame: naked_flame)
    peak = 0.0
    events = (1..20).flat_map do |t|
      run!(op, 1, from: t - 1).tap { peak = [ peak, district_firedamp(op) ].max }
    end
    [ op, events, peak ]
  end

  # The pocket, at 15 kg a tick, is through before the twentieth.
  # **In the dark**, so what is measured is the gas arriving rather than what a candle makes of it.
  it "throws a pocket into the district when the face reaches it" do
    op, events, peak = driven(naked_flame: 0)

    burst = events.find { |e| e[:type] == :part_failed && e[:node] == :outburst }
    expect(burst).not_to be_nil
    expect(peak).to be > 100.0
    expect(op.state.dig(:nodes, :gas_pocket, :pockets)).to be_empty
    expect(op.state.dig(:nodes, :outburst, :failure)).to be_nil
  end

  # **An outburst into a candle-lit district is an explosion** — Agrappe. The pocket goes into the
  # flammable band at once, and the naked lights are already there.
  it "fires the district when it is lit by naked flame" do
    _op, events, _peak = driven(naked_flame: 100)

    expect(events.map { |e| e[:type] }).to include(:fire_lit)
  end

  it "throws nothing at a face nobody is driving" do
    op = with_pocket(at_m: 0.0005)
    levers!(op, hewing: 0, haulage: 100, timbering: 100)
    events = run!(op, 20)

    expect(events.select { |e| e[:node] == :outburst }).to be_empty
    expect(district_firedamp(op)).to be < 5.0
  end

  # The auger reaches a pocket a few metres off, and draws it into the district slowly — gas the fan
  # must carry — where one out of reach is left alone. The holes are how anybody finds out.
  it "draws a pocket within the auger's reach off slowly, and leaves one beyond it" do
    near = with_pocket(at_m: 2.0, borer: true)
    far = with_pocket(at_m: 9.0, borer: true)
    [ near, far ].each { |op| run!(op, 12) }

    expect(near.state.dig(:nodes, :gas_pocket, :pockets).first.fetch(:kg)).to be < 150.0
    expect(near.state.dig(:nodes, :bore_line, :found_kg)).to be > 0.0
    expect(far.state.dig(:nodes, :gas_pocket, :pockets).first.fetch(:kg)).to eq(150.0)
    expect(near.project(viewer: :player).to_h.dig(:gauges, :bore_holes)).to eq("gas blowing hard from the holes")
  end
end
