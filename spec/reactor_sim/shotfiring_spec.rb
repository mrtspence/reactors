# frozen_string_literal: true

require "reactor_sim"
require "support/conservation"
require "support/constructed"
require "support/pit_rig"

# **Shotfiring: a tonne and a half at a time, and the accidents that come with it.** A shot hole
# worked by a shotfirer fires a charge from the magazine, the charge's fumes land in the district,
# and the coal and dust it brings down follow. A blown-out shot is a flame in the room for a tick; a
# misfire stays in the hole, at full weight, until it is dug out. On constructed states — a hole
# about to fire — so nothing waits on a shotfirer's hour. See
# `design_sketches/mine-accidents-unit4.md` §3 and §9.
RSpec.describe "shotfiring" do
  include Constructed
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  let(:hole_class) { ReactorSim::Operations::Mine::ShotHole }

  def pit(tier = :powder_shots) = build_pit(id: "s", seed: 5, loadout: { blasting: tier })

  def shotfirer = { crew_1: { place: :district, posting: :shotfiring, station: :shotfiring } }

  # The hole a breath from firing, with the shotfirer at it.
  def ready(op = pit, district: nil, **hole)
    nodes = { shot_hole: { progress: 0.9999 }.merge(hole) }
    nodes[:district] = district if district
    seed(op, nodes: nodes, minions: shotfirer)
  end

  def hole(op) = op.state.dig(:nodes, :shot_hole)

  it "fires a charge from the magazine and brings down a tonne and a half" do
    op = ready
    before = held(op, :magazine, :black_powder)
    run!(op, 3)

    expect(hole(op).fetch(:brought_down_kg)).to eq(hole_class::SHOT_COAL_KG)
    expect(before - held(op, :magazine, :black_powder)).to be_within(1e-9).of(0.5)
  end

  it "leaves its fumes in the district, and the coal and dust come down after it" do
    op = ready
    coal = held(op, :district, :coal)
    dust = held(op, :district, :coal_dust)
    run!(op, 12)

    expect(held(op, :district, :whitedamp)).to be > 0.0
    expect(held(op, :district, :coal) - coal).to be > 100.0
    expect(held(op, :district, :coal_dust)).to be > dust
  end

  it "fires nothing with nobody at the shot holes" do
    op = seed(pit, nodes: { shot_hole: { progress: 0.9999 } })
    run!(op, 3)

    expect(hole(op).fetch(:brought_down_kg)).to eq(0.0)
  end

  describe "a blown-out shot" do
    def blown(firedamp_pct)
      op = pit
      ready(op, district: district_mix(op, firedamp: gas_kg(firedamp_pct)), blowout_pending: true)
    end

    it "fires a district with gas in its range, and brings down only part of the coal" do
      op = blown(5.0)
      events = run!(op, 5)

      expect(events.map { |e| e[:type] }).to include(:explosion)
      expect(hole(op).fetch(:brought_down_kg)).to eq(hole_class::SHOT_COAL_KG * hole_class::BLOWN_OUT_YIELD)
    end

    it "leaves a district with too little gas alone" do
      expect(run!(blown(1.0), 5).map { |e| e[:type] }).not_to include(:explosion)
    end

    it "is far rarer with a permitted explosive" do
      rate = ->(tier) { pit(tier).nodes.fetch(:shot_hole).perils.find { |p| p.id == :blown_out_shot }.rate }

      expect(rate.(:permitted_shots)).to be < rate.(:powder_shots) * 0.2
    end
  end

  describe "a misfire" do
    def peril(op, id) = op.nodes.fetch(:shot_hole).perils.find { |p| p.id == id }

    def hand(boneheaded: 0.0)
      ReactorSim::Minion.new(id: :m, name: "Hand", tags: { boneheaded: boneheaded }, mass_kg: 70.0,
                             stats: { strength: 1.0, toughness: 1.0, endurance: 1.0,
                                      intelligence: 1.0, dexterity: 1.0, charisma: 1.0 })
    end

    def fresh = { health: 1.0, fatigue: 0.0 }

    # **One misfire, split by who reads it**: the two shares make the whole rate, and a bonehead
    # misreads it all but always.
    # In a lit district; in the dark nobody can see whether a shot went off at all.
    it "is recognised by a sound hand and misjudged by a bonehead" do
      op = pit
      rightly = peril(op, :misfired_shot)
      wrongly = peril(op, :misjudged_misfire)
      sound = hand
      daft = hand(boneheaded: 1.0)
      lit = { darkvision: 1.0 }
      wrong = ->(who, ambient = lit) { wrongly.weight_for(who, fresh, ambient: ambient) }

      expect(rightly.weight_for(sound, fresh, ambient: lit) + wrong.(sound)).to be_within(1e-9).of(1.0)
      expect(wrong.(sound)).to be < 0.2
      expect(wrong.(daft)).to be > 0.85
      expect(wrong.(sound, {})).to be > wrong.(sound)
    end

    it "misjudged, is left live in the face and brings nothing down" do
      op = ready(misjudged_pending: true)
      run!(op, 3)

      expect(hole(op).fetch(:live)).to eq(1)
      expect(hole(op).fetch(:misfires)).to eq(0)
      expect(hole(op).fetch(:brought_down_kg)).to eq(0.0)
    end

    # The live charge is struck by working the face: a hazard to the hewer, by how hard he hews.
    it "left live, is a hazard to whoever hews the face, and only while they hew it" do
      op = pit
      node = op.nodes.fetch(:shot_hole)
      live = hole(op).merge(live: 1)

      expect(peril(op, :struck_live_charge).stations).to eq(%i[hewing])
      expect(node.activity(live.merge(hewing: 1.0), :live, 0.25)).to eq(1.0)
      expect(node.activity(live.merge(hewing: 0.0), :live, 0.25)).to eq(0.0)
    end

    it "struck, goes off: the charge is spent and the room has a flame in it for a tick" do
      op = pit
      node = op.nodes.fetch(:shot_hole)
      struck, = node.suffer(hole(op).merge(live: 1), { kind: :struck }, nil)

      expect(struck.fetch(:live)).to eq(0)
      expect(node.ignition(struck, {})).to include(cause: :blown_out_shot)
    end

    it "recognised, stays in the hole for the shotfirer to dig out" do
      op = ready(misfire_pending: true)
      run!(op, 3)

      expect(hole(op).fetch(:misfires)).to eq(1)
      expect(op.project(viewer: :player).to_h.dig(:gauges, :shot_holes)).to match(/misfire/)
    end

    def misfired(clearing) = seed(pit, nodes: { shot_hole: { misfires: 1, clearing: clearing } }, minions: shotfirer)

    # **All or nothing**: half dug out is a whole charge in the hole.
    it "recognised, is a hazard to the shotfirer at full weight until it is dug out completely" do
      op = misfired(0.5)
      node = op.nodes.fetch(:shot_hole)
      run!(op, 4)

      expect(node.activity(hole(op), :misfired, 0.25)).to eq(1.0)
      expect(peril(op, :set_off_misfire).stations).to eq(%i[shotfiring])
    end

    it "goes all at once the tick the digging is done" do
      op = misfired(0.99999)
      run!(op, 2)

      expect(hole(op).fetch(:misfires)).to eq(0)
      expect(op.nodes.fetch(:shot_hole).activity(hole(op), :misfired, 0.25)).to eq(0.0)
    end
  end

  it "conserves mass and energy through a shot" do
    op = ready
    mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    run!(op, 12)

    mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    expect((mass - mass0).abs / mass0.abs).to be < Conservation::TOLERANCE
    expect((joules - joules0).abs / joules0.abs).to be < Conservation::TOLERANCE
  end
end
