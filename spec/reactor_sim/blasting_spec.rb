# frozen_string_literal: true

require "support/open_pit_rig"
require "support/conservation"

# **Blasting and hard ground**: a powder gang at each face drilling, charging and firing on the word,
# a shot breaking the ground ahead so the face digs it loose; flyrock across the pit; misfires; an
# unticketed gang's extra accidents; frost; dynamite freezing, and the thawing house that keeps it.
# Zero ticks for the arithmetic, a few from a constructed state for the rest. Relational — no figure
# here is a tuning target.
RSpec.describe ReactorSim::Operations::OpenPit do
  before { allow(ReactorSim::Content).to receive(:default).and_return(OpenPitRig::CONTENT) }

  def pit(loadout = {}, **opts)
    OpenPitRig.build(id: :pit, seed: 1, loadout: { quarters: :barracks, blasting: :jumper_holes }.merge(loadout),
                     crew: OpenPitRig.crew(OpenPitRig::MOST_SEATS), **opts)
  end

  def tick(op, ticks = 1) = OpenPitRig.tick(op, ticks)
  def state(op, id) = OpenPitRig.node_state(op, id)
  def hole(op) = state(op, :stripping_shot_hole)
  def status(op) = ReactorSim::Nodes::ShotHole::STATUSES.fetch(hole(op).fetch(:status))
  def bench = described_class::Bench
  def gang = %i[crew_20 crew_21]

  # The stripping face at work with its powder gang at the hole, a breath from charged.
  def ready(loadout = {}, fire: 100.0, **opts)
    op = OpenPitRig.posted(OpenPitRig.at_work(pit(loadout, **opts)), stripping_powder_gang: gang)
    op = OpenPitRig.seed(op, nodes: { stripping_shot_hole: { progress: 0.999 } })
    op.set_control(:stripping_fire, fire)
    op
  end

  describe "a shot" do
    it "waits charged for the word, and fires on it" do
      held = tick(ready(fire: 0.0), 3)
      fired = tick(ready, 3)

      expect(status(held)).to be(:charged)
      expect(state(held, :stripping_bench).fetch(:broken_kg)).to eq(0.0)
      expect(hole(fired).fetch(:brought_down_kg)).to be_positive
    end

    it "breaks the ground ahead, and the face digs it loose — a hard stretch included" do
      fired = tick(ready, 4)
      unbroken = tick(OpenPitRig.at_work(pit), 4)
      stretch = [ { at_m: 0.0, length_m: 100.0, hardness: 3.0 } ]
      node = pit.nodes.fetch(:stripping_bench)
      in_stretch = state(pit, :stripping_bench).merge(stretches: stretch)

      expect(state(fired, :stripping_bench).fetch(:broken_kg)).to be_positive
      expect(state(fired, :stripping_getting).fetch(:carried_kg)).to be > state(unbroken, :stripping_getting).fetch(:carried_kg)
      expect(node.face_hardness(in_stretch.merge(broken_kg: 100.0), 1.0)).to be < node.face_hardness(in_stretch, 1.0)
      expect(node.face_hardness(in_stretch.merge(broken_kg: 100.0), 1.0)).to be < 1.0
    end

    it "charges only with the gang at it, and a gopher hole breaks more for longer" do
      idle = OpenPitRig.seed(OpenPitRig.at_work(pit), nodes: { stripping_shot_hole: { progress: 0.5 } })
      jumper = pit.nodes.fetch(:stripping_shot_hole)
      gopher = pit({ blasting: :gopher_holes }).nodes.fetch(:stripping_shot_hole)

      expect(hole(tick(idle, 4)).fetch(:progress)).to eq(0.5)
      expect(gopher.yield_kg).to be > jumper.yield_kg
      expect(gopher.shot_s).to be > jumper.shot_s
    end
  end

  describe "flyrock" do
    it "comes down only in the seconds after a shot, hardest at the face it was fired at and least at the bank" do
      node = pit.nodes.fetch(:stripping_shot_hole)
      thrown = node.perils.select { |p| p.scales_with == :flying }.to_h { |p| [ p.places, p.severity * p.rate ] }

      expect(node.activity(hole(pit).merge(since_fired_s: 0.5), :flying, 0.25)).to eq(1.0)
      expect(node.activity(hole(pit), :flying, 0.25)).to eq(0.0)
      expect(thrown.fetch([ :stripping_bench ])).to be > thrown.fetch(%i[ore_bench haul_road])
      expect(thrown.fetch(%i[ore_bench haul_road])).to be > thrown.fetch(%i[bank spoil_dump dams])
    end
  end

  describe "misfires" do
    it "waits for a known misfire to be dug out, and fires nothing meanwhile" do
      op = OpenPitRig.seed(ready, nodes: { stripping_shot_hole: { misfires: 1, progress: 0.0 } })
      tick(op, 3)

      expect(status(op)).to be(:clearing)
      expect(hole(op).fetch(:brought_down_kg)).to eq(0.0)
    end

    it "leaves a misjudged charge live for whoever digs the face to strike" do
      live = tick(OpenPitRig.seed(OpenPitRig.at_work(pit), nodes: { stripping_shot_hole: { live: 1 } }))
      node = live.nodes.fetch(:stripping_shot_hole)

      expect(node.activity(hole(live), :live, 0.25)).to be_positive
      expect(node.perils.find { |p| p.id == :struck_live_charge }.stations).to include(:stripping_getters)
    end

    it "lays more accidents on an unticketed gang than a ticketed one" do
      perils = pit.nodes.fetch(:stripping_shot_hole).perils.select { |p| p.unless_tagged == :shotfirer }
      green = ReactorSim::Minion.new(id: :green, mass_kg: 70.0, stats: { toughness: 1.0 }, tags: {})
      ticketed = ReactorSim::Minion.new(id: :old_hand, mass_kg: 70.0, stats: { toughness: 1.0 }, tags: { shotfirer: true })

      expect(perils).not_to be_empty
      expect(perils.map { |p| p.weight_for(green) }).to all(be_positive)
      expect(perils.map { |p| p.weight_for(ticketed) }).to all(eq(0.0))
    end
  end

  describe "frost" do
    it "builds below freezing, thaws above it, and hardens the face" do
      node = pit.nodes.fetch(:stripping_bench)
      frozen = state(pit, :stripping_bench).merge(frost: 1.0)

      expect(node.frosted(0.0, 263.15, 60.0)).to be_positive
      expect(node.frosted(0.5, 283.15, 60.0)).to be < 0.5
      expect(node.frosted(nil, 263.15, 0.25)).to eq(1.0)
      expect(node.face_hardness(frozen, 0.0)).to be > node.face_hardness(frozen.merge(frost: 0.0), 0.0)
    end
  end

  describe "dynamite" do
    def magazine_at(op, kelvin)
      { joules: op.nodes.fetch(:magazine).heat_capacity * kelvin, parcels: OpenPitRig.parcels_at(kelvin, dynamite: 60.0) }
    end

    it "is frozen in a cold magazine, and misfires the more for it" do
      op = pit({ blasting: :dynamite_shots })
      cold = tick(OpenPitRig.seed(op, nodes: { magazine: magazine_at(op, 265.0) }))
      warm = tick(OpenPitRig.seed(op, nodes: { magazine: magazine_at(op, 290.0) }))
      node = op.nodes.fetch(:stripping_shot_hole)

      expect(hole(cold).fetch(:frozen)).to be(true)
      expect(hole(warm).fetch(:frozen)).to be(false)
      expect(node.perils.select { |p| p.scales_with == :frozen }.map(&:mishap).map { |m| m.fetch(:kind) })
        .to contain_exactly(:misfire, :misjudged)
    end

    it "wears a thawing house kept too warm toward going up, and not one kept thawed" do
      op = pit({ blasting: :dynamite_shots, magazine: :thawing_house })
      house = op.nodes.fetch(:magazine)
      seen = Struct.new(:content).new(op.content)
      stress = ->(kelvin) { house.stress_per_second(state(op, :magazine).merge(magazine_at(op, kelvin)), seen) }

      expect(stress.(335.0)).to be_positive
      expect(stress.(290.0)).to eq(0.0)
      expect(house.failure_hazards).to have_key(:rupture)
    end

    # Somebody at the bank by the thawing house, and the house sweating its last.
    def going_up(dynamite_kg)
      op = pit({ blasting: :dynamite_shots, magazine: :thawing_house })
      op = OpenPitRig.posted(op, thawing_heat: %i[crew_30])
      house = magazine_at(op, 340.0).merge(durability: 1.0e-6)
      house[:parcels] = dynamite_kg.positive? ? OpenPitRig.parcels_at(340.0, dynamite: dynamite_kg) : []
      tick(OpenPitRig.seed(op, nodes: { magazine: house }), 4)
    end

    it "goes up with everything in it, and the bigger for what was there" do
      full = going_up(60.0)
      empty = going_up(0.0)
      dynamite = ->(op, id) { state(op, id).fetch(:parcels).sum { |p| p.fetch(:resource) == :dynamite ? p.fetch(:kg) : 0.0 } }

      expect(state(full, :magazine).fetch(:failure)).to be(:rupture)
      expect(dynamite.(full, :magazine) + dynamite.(full, :magazine_blast)).to eq(0.0)
      expect(full.ledger.fetch(:mass_vented)).to be > empty.ledger.fetch(:mass_vented)
      expect(full.state.dig(:minions, :crew_30, :wounds)).to be_any
      expect(empty.state.dig(:minions, :crew_30, :wounds)).to be_empty
    end
  end

  describe "a train at the face" do
    # A dinky's crew on its footplate at the stripping face, a shot fired there, and their margins.
    def margins(fire:)
      op = pit({ stripping_train_train: :dinkey_train })
      op = OpenPitRig.posted(op, stripping_powder_gang: gang)
      op = OpenPitRig.seed(op, nodes: { stripping_shot_hole: { progress: fire ? 0.999 : 0.0 } })
      crew = op.state.fetch(:minions).select { |_, m| m[:place] == :stripping_train_footplate }.keys
      tick(op, 6)
      crew.map { |seat| op.state.dig(:minions, seat, :margin) }
    end

    it "puts the crew on its footplate under the flyrock fired there" do
      expect(margins(fire: true).sum).to be < margins(fire: false).sum
      expect(margins(fire: false)).not_to be_empty
    end
  end

  describe "the books" do
    it "closes mass and energy through a shot" do
      op = ready
      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      tick(op, 10)

      expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass).abs / mass.abs).to be < Conservation::TOLERANCE
      expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules).abs / joules.abs)
        .to be < Conservation::TOLERANCE
    end

    it "replays bit for bit through a snapshot" do
      straight = tick(ready, 8)
      resumed = OpenPitRig.seed(tick(ready, 4))
      4.times do |t|
        resumed.receive_supply(:line_shaft, OpenPitRig::SUPPLY_J)
        resumed.step!(tick: t + 5)
      end

      expect(ReactorSim.canonical(resumed.state)).to eq(ReactorSim.canonical(straight.state))
    end
  end
end
