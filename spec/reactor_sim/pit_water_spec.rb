# frozen_string_literal: true

require "support/open_pit_rig"
require "support/conservation"

# **The pit's water**: seepage from the strata and the springs the ore face meets, rain on the pit,
# the sump at the bottom of the ore bench, the bailers and the pumps that lift it to the reservoir,
# and the water a person can be out of their depth in. Zero ticks for the arithmetic, a few from a
# constructed state for the rest. Relational — no figure here is a tuning target.
RSpec.describe ReactorSim::Operations::OpenPit do
  before { allow(ReactorSim::Content).to receive(:default).and_return(OpenPitRig::TIRING_CONTENT) }

  def pit(loadout = {}, content: OpenPitRig::TIRING_CONTENT, ground: OpenPitRig::ORDINARY)
    OpenPitRig.build(id: :pit, seed: 1, loadout: { quarters: :barracks }.merge(loadout), ground: ground,
                     content: content, crew: OpenPitRig.crew(OpenPitRig::MOST_SEATS))
  end

  def tick(op, ticks = 1, supply: OpenPitRig::SUPPLY_J) = OpenPitRig.tick(op, ticks, supply: supply)
  def state(op, id) = OpenPitRig.node_state(op, id)
  def held(op, id) = OpenPitRig.held_kg(op, id)
  def water(kg) = { parcels: OpenPitRig.parcels_at(293.15, water: kg) }
  def turning(op) = op.nodes.fetch(:line_shaft).moment_of_inertia * described_class::WORKING_OMEGA
  def flood_kg = described_class::SUMP_FLOOD_KG
  def deep_kg = described_class::SUMP_DEEP_KG
  def minion(op, seat) = op.state.dig(:minions, seat)

  # A node's view of the last tick, for the arithmetic: a struct of its own, so no other spec's can
  # stand in for it.
  def looking(states) = Struct.new(:states) { def node_state(id) = states[id] }.new(states)

  describe "seepage" do
    def seepage = pit.nodes.fetch(:seepage)
    def drawn(**over) = { wetness: 1.0, springs: [] }.merge(over)
    def at(depth_m: 7.0, advanced_m: 0.0) = looking({ ore_bench: { depth_m: depth_m, advanced_m: advanced_m } })

    it "seeps more from a deeper pit, and from wetter ground" do
      expect(seepage.kg_per_s(drawn, at(depth_m: 10.0))).to be > seepage.kg_per_s(drawn, at(depth_m: 5.0))
      expect(seepage.kg_per_s(drawn(wetness: 2.0), at)).to be > seepage.kg_per_s(drawn(wetness: 0.5), at)
    end

    it "flows from a spring once the ore face has reached it, and not before" do
      spring = drawn(springs: [ { at_m: 1.0, kg_per_s: 4.0 } ])

      expect(seepage.kg_per_s(spring, at(advanced_m: 1.1)) - seepage.kg_per_s(spring, at(advanced_m: 0.9)))
        .to be_within(1e-9).of(4.0)
    end

    it "draws its ground per match, and a pinned ground draws the median and no springs" do
      wild = pit(ground: nil).nodes.fetch(:seepage)
      draws = Array.new(2_000) { |i| wild.initial_state(ReactorSim::Rng.stream(i, :seepage), OpenPitRig::CONTENT) }
      ground = described_class::Ground
      counts = draws.map { |d| d.fetch(:springs).length }

      expect(state(pit, :seepage).slice(:wetness, :springs)).to eq(wetness: 1.0, springs: [])
      expect(draws.map { |d| d.fetch(:wetness) }).to all(be_between(ground::WETNESS.begin, ground::WETNESS.end))
      expect(counts.uniq.sort).to eq([ 0, 1, 2 ])
      expect(draws.flat_map { |d| d.fetch(:springs).map { |s| s.fetch(:at_m) } })
        .to all(be_between(ground::SPRING_AHEAD_M.begin, ground::SPRING_AHEAD_M.end))
      expect(draws.first(2).map { |d| d.fetch(:wetness) }.uniq.length).to eq(2)
    end
  end

  describe "rain" do
    it "drains the rain on the pit into the sump, and none on a dry day" do
      wet = tick(OpenPitRig.seed(pit, nodes: { outdoors: { runoff: 1.0e-3 } }), 2)
      dry = tick(pit, 2)

      expect(held(wet, :sump)).to be > held(dry, :sump)
    end
  end

  describe "the ore bench" do
    def getting(sump_kg)
      op = OpenPitRig.at_work(OpenPitRig.build(id: :pit, seed: 1))
      tick(OpenPitRig.seed(op, nodes: { sump: water(sump_kg) }), 3)
    end

    it "makes the ore face harder with water on its floor, and the getters win less" do
      hole = described_class::SUMP_HOLE_KG
      dry = getting(0.0)
      wet = getting((hole + flood_kg) / 2.0)

      expect(state(wet, :ore_bench).fetch(:hardness)).to be > state(dry, :ore_bench).fetch(:hardness)
      expect(state(wet, :ore_getting).fetch(:carried_kg)).to be < state(dry, :ore_getting).fetch(:carried_kg)
      expect(described_class::Bench::SIGNALS.keys.fetch(state(wet, :ore_bench).fetch(:signal))).to be(:water_on_floor)
    end

    it "wins nothing at the flood mark, and says so" do
      flooded = getting(flood_kg + 100.0)

      expect(state(flooded, :ore_getting).fetch(:carried_kg, 0.0)).to eq(0.0)
      expect(state(flooded, :ore_bench).fetch(:uncovered_kg)).to eq(0.0)
      expect(described_class::Bench::SIGNALS.keys.fetch(state(flooded, :ore_bench).fetch(:signal))).to be(:flooded)
    end
  end

  describe "drowning" do
    # One navvy posted at the ore face, in water `sump_kg` deep, `fatigue` spent.
    def standing_in(sump_kg, fatigue: 0.0, asphyxia: 0.0, content: OpenPitRig::TIRING_CONTENT, ticks: 4)
      allow(ReactorSim::Content).to receive(:default).and_return(content)
      op = OpenPitRig.posted(pit(content: content), ore_getters: [ :crew_1 ])
      op = OpenPitRig.seed(op, nodes: { sump: water(sump_kg) },
                               minions: { crew_1: { fatigue: fatigue, asphyxia: asphyxia } })
      tick(op, ticks)
    end

    it "tires somebody out of their depth faster than at the same post on a dry floor" do
      deep = standing_in(deep_kg + 500.0, fatigue: 0.2)
      dry = standing_in(0.0, fatigue: 0.2)

      expect(minion(deep, :crew_1).fetch(:fatigue)).to be > minion(dry, :crew_1).fetch(:fatigue)
    end

    it "takes somebody spent in deep water under, and drowns them" do
      drowned = standing_in(deep_kg + 500.0, fatigue: 1.0, asphyxia: 0.99, ticks: 4)
      wound = minion(drowned, :crew_1).fetch(:wounds).find { |w| w.fetch(:kind) == :breath }

      expect(minion(drowned, :crew_1).fetch(:injury)).to be(:mortal)
      expect(wound.slice(:id, :cause)).to eq(id: :drowned, cause: :drowning)
    end

    it "takes nobody under short of their depth, however spent" do
      wading = standing_in(flood_kg + 500.0, fatigue: 1.0)

      expect(minion(wading, :crew_1).fetch(:asphyxia)).to eq(0.0)
    end

    it "keeps afloat whoever resists drowning" do
      at_home = OpenPitRig.content(OpenPitRig::NAVVY.merge(endurance: 1.0,
                                                           tags: OpenPitRig::NAVVY.fetch(:tags).merge(drowning_resistance: 1.0)))
      afloat = standing_in(deep_kg + 500.0, fatigue: 1.0, content: at_home)

      expect(minion(afloat, :crew_1).fetch(:asphyxia)).to eq(0.0)
    end

    it "puts somebody into the water only over the flood mark, and only on the ore bench" do
      sump = pit.nodes.fetch(:sump)
      over = ->(kg) { sump.activity({ over_the_mark: ((kg - flood_kg) / (deep_kg - flood_kg)).clamp(0.0, 1.0) }, :over_the_mark, 0.25) }

      expect(over.(flood_kg)).to eq(0.0)
      expect(over.(deep_kg)).to be_positive
      expect(sump.perils.flat_map(&:places)).to eq(%i[ore_bench])
    end
  end

  describe "drainage" do
    def lifting(loadout = {}, posts: {}, shaft: :turning, supply: OpenPitRig::SUPPLY_J)
      op = OpenPitRig.posted(pit(loadout), **posts)
      momentum = shaft == :turning ? turning(op) : 0.0
      op = OpenPitRig.seed(op, nodes: { sump: water(20_000.0), line_shaft: { angular_momentum: momentum } })
      tick(op, 3, supply: supply)
    end

    it "bails the sump up to the reservoir, and nothing with nobody bailing" do
      bailed = lifting(posts: { bailers: %i[crew_1 crew_2 crew_3 crew_4] })
      idle = lifting

      expect(state(bailed, :bailing).fetch(:carried_kg)).to be_positive
      expect(state(idle, :bailing).fetch(:carried_kg, 0.0)).to eq(0.0)
    end

    it "pumps the sump only while the shaft turns, and a bigger pump lifts more" do
      lift = lifting({ sump_pump: :lift_pump })
      plunger = lifting({ sump_pump: :plunger_pump })
      stopped = lifting({ sump_pump: :plunger_pump }, shaft: :stopped, supply: 0.0)
      pumped = ->(op) { state(op, :sump_pump).fetch(:carried_kg, 0.0) }

      expect(pumped.(plunger)).to be > pumped.(lift)
      expect(pumped.(lift)).to be_positive
      expect(pumped.(stopped)).to eq(0.0)
      expect(pit.nodes).not_to have_key(:sump_pump)
    end

    it "spills only what is over the reservoir's crest" do
      crest = described_class::RESERVOIR_KG
      over = tick(OpenPitRig.seed(pit, nodes: { reservoir: water(crest + 5_000.0) }), 2)
      under = tick(OpenPitRig.seed(pit, nodes: { reservoir: water(crest - 5_000.0) }), 2)

      expect(state(over, :spillway).fetch(:carried_kg)).to be_positive
      expect(state(under, :spillway).fetch(:carried_kg, 0.0)).to eq(0.0)
    end
  end

  describe "the books" do
    it "balances mass and energy with rain falling, the water seeping and the pump lifting" do
      op = OpenPitRig.posted(pit({ sump_pump: :lift_pump }), bailers: %i[crew_1 crew_2])
      op = OpenPitRig.seed(op, nodes: { outdoors: { runoff: 1.0e-3 }, sump: water(20_000.0),
                                        line_shaft: { angular_momentum: turning(op) } })
      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      tick(op, 12)

      expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass).abs / mass.abs).to be < Conservation::TOLERANCE
      expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules).abs / joules.abs)
        .to be < Conservation::TOLERANCE
    end

    it "replays bit for bit through a snapshot" do
      fresh = -> { OpenPitRig.seed(pit, nodes: { outdoors: { runoff: 1.0e-3 }, sump: water(deep_kg) }) }
      straight = tick(fresh.(), 8)
      resumed = OpenPitRig.seed(tick(fresh.(), 4))
      4.times do |t|
        resumed.receive_supply(:line_shaft, OpenPitRig::SUPPLY_J)
        resumed.step!(tick: t + 5)
      end

      expect(ReactorSim.canonical(resumed.state)).to eq(ReactorSim.canonical(straight.state))
    end
  end
end
