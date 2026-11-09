# frozen_string_literal: true

require "support/open_pit_rig"
require "support/conservation"

# **The mud dam and the reservoir's bank**: a pond settling behind a wall that wears held full, is
# puddled by a gang, comes over the top at once, breaches into the pit below, and is rebuilt; the
# decant that gives the dam's water back; the bigger tiers. Zero ticks for the arithmetic, a few
# from a constructed state for the rest. Relational — no figure here is a tuning target.
RSpec.describe ReactorSim::Operations::OpenPit do
  before { allow(ReactorSim::Content).to receive(:default).and_return(OpenPitRig::CONTENT) }

  def pit(loadout = {}, ground: OpenPitRig::ORDINARY)
    OpenPitRig.build(id: :pit, seed: 1, loadout: { quarters: :barracks }.merge(loadout), ground: ground,
                     crew: OpenPitRig.crew(OpenPitRig::MOST_SEATS))
  end

  def tick(op, ticks = 1) = OpenPitRig.tick(op, ticks)
  def state(op, id) = OpenPitRig.node_state(op, id)
  def held(op, id) = OpenPitRig.held_kg(op, id)
  def of(op, id, resource) = state(op, id).fetch(:parcels).sum { |p| p.fetch(:resource) == resource ? p.fetch(:kg) : 0.0 }
  def wall(op, id = :mud_dam) = described_class::Embankment::SIGNALS.keys.fetch(state(op, id).fetch(:signal))
  def hands(op) = OpenPitRig.posted(op, dam_hands: %i[crew_1 crew_2 crew_3])
  def dam(op) = op.nodes.fetch(:mud_dam)

  # A pond `share` of the dam full, settled, with `free_kg` of water on top.
  def pond(op, share, free_kg: 0.0)
    node = dam(op)
    clay_m3 = share * node.capacity_m3
    clay = clay_m3 / ((1.0 / 1_700.0) + (described_class::MudDam::PORE_WATER / 1_000.0))
    water = (described_class::MudDam::PORE_WATER * clay) + free_kg
    { parcels: OpenPitRig.parcels_at(293.15, clay: clay, water: water) }
  end

  # What a wall sees of the tick, for the arithmetic: a struct of its own, so no other spec's can
  # stand in for it.
  def seen(op) = Struct.new(:content, :dt).new(op.content, 0.25)

  describe "the pond" do
    it "starts part full, drawn per match, and a pinned ground at the median" do
      wild = pit(ground: nil)
      fills = Array.new(200) do |i|
        drawn = dam(wild).initial_state(ReactorSim::Rng.stream(i, :mud_dam), OpenPitRig::CONTENT)
        dam(wild).fill(drawn, OpenPitRig::CONTENT)
      end
      range = described_class::MudDam::STARTING_FILL

      expect(fills).to all(be_between(range.begin - 0.01, range.end + 0.01))
      expect(fills.uniq.length).to be > 1
      expect(dam(pit).fill(state(pit, :mud_dam), pit.content)).to be_within(0.01).of((range.begin + range.end) / 2.0)
    end

    it "decants its free water to the reservoir, and none of the clay or the water it keeps" do
      op = pit
      settled = pond(op, 0.4, free_kg: 2_000.0)
      open = tick(OpenPitRig.seed(op, nodes: { mud_dam: settled, reservoir: { parcels: [] } }), 3)
      shut = OpenPitRig.seed(op, nodes: { mud_dam: settled })
      shut.set_control(:decanting, 0.0)
      tick(shut, 3)
      clay = settled.fetch(:parcels).sum { |p| p.fetch(:resource) == :clay ? p.fetch(:kg) : 0.0 }

      expect(held(open, :reservoir)).to be_between(0.0, 2_000.0 + 1e-6).exclusive
      expect(of(open, :mud_dam, :clay)).to eq(clay)
      expect(dam(open).free_water_kg(state(open, :mud_dam), open.content)).to be < 2_000.0
      expect(state(shut, :decant).fetch(:carried_kg, 0.0)).to eq(0.0)
    end
  end

  describe "the wall" do
    def stress(op, share) = dam(op).stress_per_second(pond(op, share).merge(state(op, :mud_dam).slice(:durability)), seen(op))

    it "wears held above its safe fill and not below, and the fuller the faster" do
      op = pit

      expect(stress(op, 0.5)).to eq(0.0)
      expect(stress(op, 0.95)).to be > stress(op, 0.8)
      expect(stress(op, 0.8)).to be_positive
    end

    it "is puddled back by the dam hands" do
      op = pit
      worn = state(op, :mud_dam).fetch(:initial_durability) * 0.5
      tended = tick(OpenPitRig.seed(hands(op), nodes: { mud_dam: { durability: worn } }), 4)
      left = tick(OpenPitRig.seed(op, nodes: { mud_dam: { durability: worn } }), 4)

      expect(state(tended, :mud_dam).fetch(:durability)).to be > state(left, :mud_dam).fetch(:durability)
    end

    it "weeps, then slumps, before it goes" do
      op = pit
      whole = state(op, :mud_dam).fetch(:initial_durability)
      worn = ->(share) { tick(OpenPitRig.seed(op, nodes: { mud_dam: { durability: whole * share } })) }

      expect(wall(worn.(0.9))).to be(:sound)
      expect(wall(worn.(0.4))).to be(:weeping)
      expect(wall(worn.(0.1))).to be(:slumping)
    end

    it "breaches at once over the crest" do
      over = tick(OpenPitRig.seed(pit, nodes: { mud_dam: pond(pit, 0.6, free_kg: 1.3e6) }), 2)

      expect(state(over, :mud_dam).fetch(:failure)).to be(:breached)
      expect(wall(over)).to be(:breached)
    end
  end

  describe "a breach" do
    def breached
      op = hands(pit)
      tick(OpenPitRig.seed(op, nodes: { mud_dam: pond(op, 0.6, free_kg: 1.3e6) }), 4)
    end

    it "runs the pond's water into the pit, leaves the clay, and hurts whoever is on the wall" do
      op = breached
      clay = pond(pit, 0.6).fetch(:parcels).sum { |p| p.fetch(:resource) == :clay ? p.fetch(:kg) : 0.0 }

      expect(state(op, :mud_dam_breach).fetch(:carried_kg)).to be_positive
      expect(held(op, :sump)).to be > held(tick(pit, 4), :sump)
      expect(of(op, :mud_dam, :clay)).to be_within(1e-6).of(clay)
      expect(op.state.fetch(:minions).values_at(:crew_1, :crew_2, :crew_3).map { |m| m.fetch(:wounds) }).to all(be_any)
    end

    it "shuts once the dam hands have rebuilt the wall" do
      op = hands(pit)
      whole = state(op, :mud_dam).fetch(:initial_durability)
      rebuilt = tick(OpenPitRig.seed(op, nodes: { mud_dam: { failure: :breached, durability: whole - 0.1 } }), 3)

      expect(state(rebuilt, :mud_dam).fetch(:failure)).to be_nil
      expect(state(tick(rebuilt), :mud_dam_breach).fetch(:carried_kg, 0.0)).to eq(0.0)
    end
  end

  describe "the tiers" do
    it "holds more in a bigger dam" do
      expect(dam(pit({ mud_dam: :raised_dam })).capacity_m3).to be > dam(pit).capacity_m3
      expect(dam(pit({ mud_dam: :settling_ponds })).capacity_m3).to be > dam(pit({ mud_dam: :raised_dam })).capacity_m3
    end

    it "wears a larger reservoir's bank held full, where the small one's does not wear in a match" do
      wear = ->(op) {
        node = op.nodes.fetch(:reservoir)
        full = { parcels: OpenPitRig.parcels_at(293.15, water: node.capacity_kg) }
        node.stress_per_second(full.merge(durability: 1_000.0), seen(op))
      }

      expect(wear.(pit({ reservoir: :large_reservoir }))).to be > wear.(pit) * 10.0
      expect(pit.control_points).not_to have_key(:bankmen)
    end

    it "draws a larger reservoir down through its scour valve" do
      op = pit({ reservoir: :large_reservoir })
      scoured = OpenPitRig.seed(op)
      scoured.set_control(:scour_valve, 100.0)
      tick(scoured, 3)

      expect(state(scoured, :scour).fetch(:carried_kg)).to be_positive
      expect(held(scoured, :reservoir)).to be < held(tick(op, 3), :reservoir)
    end
  end

  describe "the books" do
    def bursting
      op = hands(pit)
      OpenPitRig.seed(op, nodes: { mud_dam: pond(op, 0.6, free_kg: 1.3e6) })
    end

    it "closes mass and energy through a breach" do
      op = bursting
      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      tick(op, 10)

      expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass).abs / mass.abs).to be < Conservation::TOLERANCE
      expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules).abs / joules.abs)
        .to be < Conservation::TOLERANCE
    end

    it "replays bit for bit through a snapshot" do
      straight = tick(bursting, 8)
      resumed = OpenPitRig.seed(tick(bursting, 4))
      4.times do |t|
        resumed.receive_supply(:line_shaft, OpenPitRig::SUPPLY_J)
        resumed.step!(tick: t + 5)
      end

      expect(ReactorSim.canonical(resumed.state)).to eq(ReactorSim.canonical(straight.state))
    end
  end
end
