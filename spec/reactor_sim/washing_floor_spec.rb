# frozen_string_literal: true

require "support/open_pit_rig"
require "support/conservation"

# **Washing at scale**: a washhouse of bays, each a washer of its own on the one bin, the one pump
# and the one dam; bigger washers; a crusher ahead of them and a belt feeding it. A few ticks from a
# constructed state. Relational — no figure here is a tuning target.
RSpec.describe ReactorSim::Operations::OpenPit do
  before { allow(ReactorSim::Content).to receive(:default).and_return(OpenPitRig::CONTENT) }

  def pit(loadout = {})
    OpenPitRig.build(id: :pit, seed: 1, loadout: { quarters: :barracks }.merge(loadout),
                     crew: OpenPitRig.crew(OpenPitRig::MOST_SEATS))
  end

  def tick(op, ticks = 1, supply: OpenPitRig::SUPPLY_J) = OpenPitRig.tick(op, ticks, supply: supply)
  def state(op, id) = OpenPitRig.node_state(op, id)
  def held(op, id) = OpenPitRig.held_kg(op, id)
  def bays(op) = op.nodes.keys.grep(/\Abay_\d_washer\z/)
  def signal(op, id) = described_class::LogWasher::SIGNALS.keys.fetch(state(op, id).fetch(:signal))
  def of(op, id, resource) = state(op, id).fetch(:parcels).sum { |p| p.fetch(:resource) == resource ? p.fetch(:kg) : 0.0 }
  def momentum(op) = state(op, :line_shaft).fetch(:angular_momentum)

  def turning(op) = op.nodes.fetch(:line_shaft).moment_of_inertia * described_class::WORKING_OMEGA

  def wash_ore(kg) = OpenPitRig.parcels_at(293.15, limonite: kg * 0.25, clay: kg * 0.75)

  # Each fitted bay's hands at their washer, `per` to a bay, and whoever else is named; the shaft at
  # speed unless said otherwise.
  def at_work(op, per: 3, shaft: nil, nodes: {}, **others)
    seats = (1..OpenPitRig::MOST_SEATS).map { |i| :"crew_#{i}" }
    posts = bays(op).to_h { |washer| [ :"#{washer.to_s.delete_suffix('_washer')}_hands", seats.shift(per) ] }
    posts.merge!(others.transform_values { |n| seats.shift(n) })
    op = OpenPitRig.posted(op, **posts)
    OpenPitRig.seed(op, nodes: { line_shaft: { angular_momentum: shaft || turning(op) } }.merge(nodes))
  end

  # A bay's washer holding wash ore and water, as if it had been fed.
  def holding(kg: 400.0, water: 1_200.0) = { parcels: wash_ore(kg) + OpenPitRig.parcels_at(293.15, water: water) }

  describe "the washhouse" do
    it "builds a bay past the third only in a washhouse with room for it" do
      three = pit(bay_4: :thomas_washer)
      four = pit(washhouse: :extended_washhouse, bay_4: :thomas_washer, bay_5: :thomas_washer)

      expect(bays(three)).to eq(%i[bay_1_washer])
      expect(bays(four)).to contain_exactly(:bay_1_washer, :bay_4_washer)
      expect(three.options.dig(:loadout, :bay_4)).to be(:thomas_washer)
    end

    it "washes more with two bays than one, from the same bin" do
      washed = ->(loadout) {
        op = at_work(pit(loadout), nodes: { ore_bin: { parcels: wash_ore(4_000.0) } })
        held(tick(op, 10), :washed_ore)
      }

      expect(washed.({ bay_2: :single_log_washer })).to be > washed.({})
    end

    it "starves its bays of water on one small pump" do
      dry = ->(loadout) {
        op = pit(loadout)
        seeded = bays(op).to_h { |washer| [ washer, holding(water: 0.0) ] }
        tick(at_work(op, nodes: seeded), 14)
      }
      one = dry.({})
      three = dry.({ bay_2: :single_log_washer, bay_3: :single_log_washer })

      expect(state(one, :bay_1_washer).fetch(:short)).to be(false)
      expect(bays(three).map { |washer| state(three, washer).fetch(:short) }).to all(be(true))
      expect(state(dry.({ bay_2: :single_log_washer, bay_3: :single_log_washer, pump: :duplex_pump }), :bay_2_washer)
               .fetch(:short)).to be(false)
    end
  end

  describe "the washers" do
    def washed(washer)
      tick(at_work(pit(bay_1: washer, pump: :compound_pump), nodes: { bay_1_washer: holding(kg: 2_000.0, water: 6_000.0) }), 4)
    end

    it "washes more in a double Thomas washer than a Thomas, and draws more off the shaft" do
      thomas = washed(:thomas_washer)
      double = washed(:double_thomas_washer)

      expect(state(double, :bay_1_washer).fetch(:washing_kg)).to be > state(thomas, :bay_1_washer).fetch(:washing_kg)
      expect(momentum(double)).to be < momentum(thomas)
    end

    it "keeps more of the ore in a series washer, for more off the shaft" do
      kept = ->(op) { of(op, :washed_ore, :limonite) / (of(op, :washed_ore, :limonite) + of(op, :mud_dam, :limonite)) }
      double = washed(:double_thomas_washer)
      series = washed(:series_washer)

      expect(kept.(series)).to be > kept.(double)
      expect(momentum(series)).to be < momentum(double)
    end
  end

  describe "crushing" do
    it "feeds a washer faster from the crusher's hopper than from the bin" do
      raked = ->(loadout, from) {
        op = at_work(pit({ bay_1: :double_thomas_washer, pump: :duplex_pump }.merge(loadout)),
                     nodes: { from => { parcels: wash_ore(4_000.0) } })
        state(tick(op, 2), :bay_1_feed).fetch(:carried_kg)
      }

      expect(raked.({ crusher: :blake_jaw_crusher }, :crushed_ore)).to be > raked.({}, :ore_bin)
    end

    it "wears the logs faster on uncrushed ore" do
      worn = ->(loadout) {
        op = tick(at_work(pit(loadout), nodes: { bay_1_washer: holding }), 4)
        state(op, :bay_1_washer).then { |s| s.fetch(:initial_durability) - s.fetch(:durability) }
      }

      expect(worn.({})).to be > worn.({ crusher: :blake_jaw_crusher })
    end

    it "washes nothing once the logs are worn through, and says so" do
      op = tick(at_work(pit, nodes: { bay_1_washer: holding.merge(durability: 1.0e-6) }), 3)

      expect(state(op, :bay_1_washer).fetch(:failure)).to be(:logs_broken)
      expect(state(op, :bay_1_washer).fetch(:washing_kg)).to eq(0.0)
      expect(signal(op, :bay_1_washer)).to be(:logs_broken)
    end

    it "crushes into the hopper only while the shaft turns" do
      fed = ->(shaft, supply) {
        op = at_work(pit(crusher: :blake_jaw_crusher), shaft: shaft, crusher_feeders: 6,
                                                      nodes: { ore_bin: { parcels: wash_ore(4_000.0) } })
        tick(op, 3, supply: supply)
      }
      turned = fed.(nil, OpenPitRig::SUPPLY_J)
      stopped = fed.(0.0, 0.0)
      board = ->(op) { described_class::Crusher::SIGNALS.keys.fetch(state(op, :crusher).fetch(:signal)) }

      expect(held(turned, :crushed_ore)).to be_positive
      expect(held(stopped, :crushed_ore)).to eq(0.0)
      expect(board.(turned)).to be(:crushing)
      expect(board.(stopped)).to be(:stopped)
    end

    it "feeds the crusher by belt with nobody at it, and stalls fed past its grip" do
      belted = at_work(pit(crusher: :blake_jaw_crusher, feed_belt: :pit_feed_belt),
                       nodes: { ore_bin: { parcels: wash_ore(4_000.0) } })
      running = tick(belted, 3)
      overfed = OpenPitRig.seed(running)
      overfed.set_control(:belt_feed, 100.0)
      tick(overfed, 2)
      board = ->(op) { ReactorSim::Nodes::Belt::SIGNALS.keys.fetch(state(op, :feed_belt).fetch(:signal)) }

      expect(running.control_points).not_to have_key(:crusher_feeders)
      expect(held(running, :crushed_ore)).to be_positive
      expect(board.(running)).to be(:carrying)
      expect(board.(overfed)).to be(:stalled)
      expect(state(overfed, :feed_belt).fetch(:carried_kg)).to eq(0.0)
    end
  end

  describe "the books" do
    it "balances mass and energy with a full floor washing" do
      full = { washhouse: :double_washhouse, crusher: :gyratory_crusher, feed_belt: :pit_feed_belt,
               pump: :compound_pump }.merge((1..6).to_h { |n| [ :"bay_#{n}", :series_washer ] })
      op = at_work(pit(full), nodes: { ore_bin: { parcels: wash_ore(20_000.0) } })
      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      tick(op, 12)

      expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass).abs / mass.abs).to be < Conservation::TOLERANCE
      expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules).abs / joules.abs)
        .to be < Conservation::TOLERANCE
    end
  end
end
