# frozen_string_literal: true

require "support/open_pit_rig"
require "support/conservation"

# **The open pit by hand**: two benches as geometry, each face got into its muck and carried out by
# barrow, the stripping uncovering the ore. A few ticks from a constructed state for what the pit
# does, zero for the arithmetic it runs on. Relational — no figure here is a tuning target.
RSpec.describe ReactorSim::Operations::OpenPit do
  before { allow(ReactorSim::Content).to receive(:default).and_return(OpenPitRig::CONTENT) }

  def pit(**opts) = OpenPitRig.build(id: :pit, seed: 1, **opts)
  def working(**opts) = OpenPitRig.at_work(pit(**opts))
  def tick(op, ticks = 1, supply: OpenPitRig::SUPPLY_J) = OpenPitRig.tick(op, ticks, supply: supply)
  def state(op, id) = OpenPitRig.node_state(op, id)
  def held(op, id) = OpenPitRig.held_kg(op, id)
  def board(op, face) = OpenPitRig.board(op, face)
  def got(op, face) = state(op, :"#{face}_getting").fetch(:carried_kg, 0.0)
  def unposted(*seats) = seats.to_h { |seat| [ seat, { station: nil, posting: nil } ] }
  def ground = described_class::Ground
  def lead = described_class::STRIPPING_LEAD_M
  def berm = described_class::BERM_M

  describe "the benches" do
    it "advances a face by what is dug off it" do
      op = working
      before = state(op, :stripping_bench).fetch(:advanced_m)
      dug = Array.new(20) { |t| op.step!(tick: t + 1) && got(op, :stripping) }.sum
      bench = op.nodes.fetch(:stripping_bench)

      expect(dug).to be_positive
      expect(state(op, :stripping_bench).fetch(:advanced_m) - before)
        .to be_within(1e-9).of(dug / bench.kg_per_m(state(op, :stripping_bench)))
    end

    it "works the ore only a berm behind the stripping face, and again once the stripping goes on" do
      stood_down = OpenPitRig.seed(working, minions: unposted(:crew_1, :crew_2, :crew_3, :crew_4))
      caught_up = tick(OpenPitRig.faces_at(stood_down, stripping_m: lead, ore_m: lead - berm), 2)
      stripped_on = tick(OpenPitRig.faces_at(working, stripping_m: lead + 0.5, ore_m: lead - berm), 2)

      expect(got(caught_up, :ore)).to eq(0.0)
      expect(board(caught_up, :ore)).to be(:stripping_behind)
      expect(got(stripped_on, :ore)).to be_positive
    end

    # Zero ticks: the same tonnage off a thicker bench is a shorter advance, so a thick overburden
    # uncovers less ore for the same stripping.
    it "advances a thicker bench less for the same tonnage stripped" do
      op = pit
      bench = op.nodes.fetch(:stripping_bench)
      advance = ->(thickness) {
        kg = bench.length_m * bench.width_m * thickness * bench.bulk_kg_m3
        bench.advanced_m({ thickness_m: thickness, initial_kg: kg, parcels: OpenPitRig.parcels_at(293.15, overburden: kg - 10_000.0) })
      }

      expect(advance.(6.0)).to be < advance.(3.0)
    end
  end

  describe "the ground" do
    it "wins less for the same effort in a hard stretch, and as before out of it" do
      hard = [ { at_m: lead - 0.1, length_m: 1.0, hardness: 3.0 } ]
      ordinary = tick(working, 2)
      boulders = tick(OpenPitRig.seed(working, nodes: { stripping_bench: { stretches: hard, hardness: 3.0 } }), 2)
      past = tick(OpenPitRig.faces_at(OpenPitRig.seed(working, nodes: { stripping_bench: { stretches: hard } }),
                                      stripping_m: lead + 1.0), 2)

      expect(got(boulders, :stripping)).to be_within(1e-9).of(got(ordinary, :stripping) / 3.0)
      expect(board(boulders, :stripping)).to be(:hard_ground)
      expect(got(past, :stripping)).to be_within(1e-9).of(got(ordinary, :stripping))
    end

    # The pit has no light of its own: by night only somebody who sees in the dark gets anything.
    it "wins nothing in the dark, except by hands who see in it" do
      night = ->(content) {
        allow(ReactorSim::Content).to receive(:default).and_return(content)
        op = OpenPitRig.at_work(pit(content: content))
        tick(OpenPitRig.seed(op, nodes: { outdoors: { daylight: 0.0 } }))
      }

      expect(got(night.(OpenPitRig::CONTENT), :stripping)).to eq(0.0)
      expect(got(night.(OpenPitRig::DARK_EYED_CONTENT), :stripping)).to be_positive
    end

    it "draws nothing when pinned, a different pit for another seed, and the same for the same" do
      drawn = ->(seed) { OpenPitRig.build(id: :pit, seed: seed, ground: nil).state.dig(:nodes, :stripping_bench) }
      pinned = state(pit, :stripping_bench)

      expect(pinned.fetch(:stretches)).to be_empty
      expect(pinned.fetch(:thickness_m)).to eq(op_median(:stripping_bench))
      expect(drawn.(1).fetch(:thickness_m)).to eq(drawn.(1).fetch(:thickness_m))
      expect(drawn.(1).slice(:thickness_m, :stretches)).not_to eq(drawn.(2).slice(:thickness_m, :stretches))
    end

    def op_median(id) = pit.nodes.fetch(id).median_thickness_m

    it "lays its hard stretches where a match's work reaches, none to three of them" do
      draws = Array.new(2_000) { |i| ground.stretches(ReactorSim::Rng.stream(i, :stretches), lead) }
      at = draws.flatten.map { |s| s.fetch(:at_m) - lead }

      expect(draws.map(&:length).uniq.sort).to eq([ 0, 1, 2, 3 ])
      expect(at).to all(be_between(ground::STRETCH_AHEAD_M.begin, ground::STRETCH_AHEAD_M.end))
      expect(draws).to all(satisfy { |d| d.map { |s| s.fetch(:at_m) } == d.map { |s| s.fetch(:at_m) }.sort })
    end
  end

  describe "carrying out" do
    it "barrows the stripping to the tip and the ore to the bin" do
      op = tick(OpenPitRig.seed(working, nodes: { stripping_muck: { parcels: OpenPitRig.parcels_at(293.15, overburden: 500.0) },
                                                  ore_muck: { parcels: OpenPitRig.parcels_at(293.15, limonite: 100.0, clay: 300.0) } }), 3)

      expect(held(op, :tip_head) + held(op, :spoil_dump)).to be_positive
      expect(held(op, :ore_bin)).to be_positive
    end

    # Zero ticks: a barrowman's pace against the depth his ramp climbs.
    it "is slower up a deeper pit" do
      trip = described_class::Barrowing.method(:trip_s)

      expect(trip.(7.0, 25.0)).to be > trip.(4.0, 25.0)
    end

    it "leaves the muck piling up with nobody barrowing, and the getters waiting on it" do
      full = described_class::MUCK_M3 * described_class::OVERBURDEN_KG_M3
      op = working
      op = tick(OpenPitRig.seed(op, nodes: { stripping_muck: { parcels: OpenPitRig.parcels_at(293.15, overburden: full) } },
                                    minions: unposted(*OpenPitRig.gang(op, :stripping_barrowmen))), 2)

      expect(got(op, :stripping)).to eq(0.0)
      expect(board(op, :stripping)).to be(:waiting_on_barrows)
    end

    it "fills the tip with nobody spreading, and the barrows have nowhere to tip" do
      full = described_class::TIP_HEAD_M3 * described_class::OVERBURDEN_KG_M3
      muck = OpenPitRig.parcels_at(293.15, overburden: 500.0)
      tipping = tick(OpenPitRig.seed(working, nodes: { stripping_muck: { parcels: muck } }), 2)
      op = working
      full_tip = tick(OpenPitRig.seed(op, nodes: { stripping_muck: { parcels: muck },
                                                   tip_head: { parcels: OpenPitRig.parcels_at(293.15, overburden: full) } },
                                          minions: unposted(*OpenPitRig.gang(op, :dumpmen))), 2)

      expect(state(tipping, :stripping_carrying).fetch(:carried_kg)).to be_positive
      expect(state(full_tip, :stripping_carrying).fetch(:carried_kg)).to eq(0.0)
    end
  end

  describe "the shift" do
    it "starts some of the shift in each outbuilding and the rest at bank" do
      places = pit.state.fetch(:minions).values.map { |m| m.fetch(:place) }.tally
      huts = ReactorSim::Operations::OpenPit::OUTBUILDINGS

      expect(places.fetch(:stripping_bench)).to eq(huts.dig(:bench_hut, :seats))
      expect(places.fetch(:ore_bench)).to eq(huts.dig(:bench_hut, :seats))
      expect(places.fetch(:spoil_dump)).to eq(huts.dig(:dump_shelter, :seats))
      expect(places.fetch(:bank)).to eq(OpenPitRig::SEATS - places.values_at(:stripping_bench, :ore_bench, :spoil_dump).sum)
    end

    it "rests a tired getter in the bench hut faster than standing at the face" do
      allow(ReactorSim::Content).to receive(:default).and_return(OpenPitRig::TIRING_CONTENT)
      tired = ->(station) {
        op = OpenPitRig.posted(pit(content: OpenPitRig::TIRING_CONTENT), **(station ? { station => [ :crew_12 ] } : {}))
        op = OpenPitRig.seed(op, minions: { crew_12: { fatigue: 0.6 } })
        tick(op, 20).state.dig(:minions, :crew_12, :fatigue)
      }

      expect(tired.(:stripping_hut)).to be < tired.(nil)
    end
  end

  describe "washing" do
    def washer = described_class::LogWasher
    def turning = op_turning_momentum

    # The line shaft at its working speed, as it is once the supply has brought it up.
    def op_turning_momentum = pit.nodes.fetch(:line_shaft).moment_of_inertia * described_class::WORKING_OMEGA

    # A washer holding wash ore and water, its shaft at speed unless said otherwise.
    def washing(limonite: 100.0, clay: 300.0, water: 1_200.0, shaft: turning, minions: {}, nodes: {})
      OpenPitRig.seed(working, minions: minions, nodes: {
        line_shaft: { angular_momentum: shaft },
        bay_1_washer: { parcels: OpenPitRig.parcels_at(293.15, limonite: limonite, clay: clay, water: water) }
      }.merge(nodes))
    end

    def held_of(op, id, resource) = state(op, id).fetch(:parcels).sum { |p| p.fetch(:resource) == resource ? p.fetch(:kg) : 0.0 }

    it "parts wash ore into clean limonite and slurry, and washes nothing with the shaft stopped" do
      settled = held_of(working, :mud_dam, :clay)
      turned = tick(washing, 4)
      stopped = tick(washing(shaft: 0.0), 4, supply: 0.0)

      expect(held_of(turned, :washed_ore, :limonite)).to be_positive
      expect(held_of(turned, :washed_ore, :clay)).to eq(0.0)
      expect(held_of(turned, :mud_dam, :clay)).to be > settled
      expect(held_of(stopped, :washed_ore, :limonite)).to eq(0.0)
      expect(held_of(stopped, :mud_dam, :clay)).to eq(settled)
    end

    # **The efficiency is the whole of the loss**: of the limonite it washes, the rest goes to the
    # dam with the clay.
    it "loses the rest of the ore it washes to the dam, by its efficiency" do
      op = tick(washing, 6)
      clean = held_of(op, :washed_ore, :limonite)
      lost = held_of(op, :mud_dam, :limonite)
      efficiency = described_class::WASHERS.dig(:single_log_washer, :efficiency)

      expect(clean / (clean + lost)).to be_within(1e-4).of(efficiency)
    end

    it "washes less short of water, and nothing dry" do
      wet = tick(washing, 2)
      short = tick(washing(water: 0.5, nodes: { reservoir: { parcels: [] } }), 1)
      dry = tick(washing(water: 0.0, nodes: { reservoir: { parcels: [] } }), 2)

      expect(state(short, :bay_1_washer).fetch(:washing_kg)).to be_between(0.0, state(wet, :bay_1_washer).fetch(:washing_kg)).exclusive
      expect(state(dry, :bay_1_washer).fetch(:washing_kg)).to eq(0.0)
      expect(described_class::LogWasher::SIGNALS.keys.fetch(state(dry, :bay_1_washer).fetch(:signal))).to be(:short_of_water)
    end

    it "costs the shaft more the more it washes" do
      empty = tick(washing(limonite: 0.0, clay: 0.0), 10)
      full = tick(washing, 10)
      shaft = ->(op) { state(op, :line_shaft).fetch(:angular_momentum) }

      expect(shaft.(full)).to be < shaft.(empty)
    end

    it "pumps water up to the washer only while the shaft turns" do
      dry = { bay_1_washer: { parcels: [] } }
      turned = tick(washing(limonite: 0.0, clay: 0.0, water: 0.0), 2)
      stopped = tick(washing(limonite: 0.0, clay: 0.0, water: 0.0, shaft: 0.0, nodes: dry), 2, supply: 0.0)

      expect(state(turned, :water_pump).fetch(:carried_kg)).to be_positive
      expect(state(stopped, :water_pump).fetch(:carried_kg, 0.0)).to eq(0.0)
    end

    it "waits on the washer hands with ore in the bin and nobody raking it in" do
      op = working
      bin = { ore_bin: { parcels: OpenPitRig.parcels_at(293.15, limonite: 500.0, clay: 1_500.0) } }
      waiting = tick(washing(limonite: 0.0, clay: 0.0, nodes: bin, minions: unposted(*OpenPitRig.gang(op, :bay_1_hands))), 2)

      expect(state(waiting, :bay_1_feed).fetch(:carried_kg, 0.0)).to eq(0.0)
      expect(described_class::LogWasher::SIGNALS.keys.fetch(state(waiting, :bay_1_washer).fetch(:signal))).to be(:waiting_on_hand)
    end

    it "catches a washer hand in the logs only while they turn" do
      turned = tick(washing, 2)
      stopped = tick(washing(shaft: 0.0), 2, supply: 0.0)
      logs = turned.nodes.fetch(:bay_1_washer)

      expect(logs.activity(state(turned, :bay_1_washer), :turning, ReactorSim::DT)).to be_positive
      expect(logs.activity(state(stopped, :bay_1_washer), :turning, ReactorSim::DT)).to eq(0.0)
    end

    it "fills its reservoir in nearly every match, and leaves it nearly dry in very few" do
      reservoir = pit(ground: nil).nodes.fetch(:reservoir)
      fills = Array.new(2_000) { |i|
        drawn = reservoir.initial_state(ReactorSim::Rng.stream(i, :reservoir), OpenPitRig::CONTENT)
        ReactorSim::Parcel.total_kg(drawn.fetch(:parcels)) / reservoir.capacity_kg
      }
      dry = fills.count { |f| f < 0.2 }

      expect(dry).to be_between(1, 100)
      expect(fills.count { |f| f > 0.5 }).to be > 1_900
      expect(ReactorSim::Parcel.total_kg(state(pit, :reservoir).fetch(:parcels))).to eq(reservoir.capacity_kg)
    end
  end

  describe "the panel" do
    it "reckons the reservoir in the washer hand's words" do
      low = tick(OpenPitRig.seed(working, nodes: { reservoir: { parcels: OpenPitRig.parcels_at(293.15, water: 20_000.0) } }), 8)

      expect(low.project(viewer: :player).to_h.dig(:gauges, :water_supply)).to eq("nearly dry")
      expect(tick(working, 8).project(viewer: :player).to_h.dig(:gauges, :water_supply)).to eq("plenty of water")
    end

    it "says in the ore gang's words how much ore is uncovered" do
      uncovered = ->(stripping_m) {
        op = tick(OpenPitRig.faces_at(working, stripping_m: stripping_m, ore_m: 0.0), 6)
        op.project(viewer: :player).to_h.dig(:gauges, :uncovered_ore)
      }

      expect(uncovered.(berm)).to eq("stripping behind")
      expect(uncovered.(berm + 0.2)).to eq("running short")
      expect(uncovered.(berm + 2.0)).to eq("plenty uncovered")
    end

    it "shows each face's board in words" do
      op = tick(working)

      expect(op.project(viewer: :player).to_h.dig(:gauges, :stripping_face)).to eq("getting")
    end
  end

  describe "the books" do
    it "balances mass and energy through a stretch of work" do
      op = working
      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      tick(op, 20)

      expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass).abs / mass.abs).to be < Conservation::TOLERANCE
      expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules).abs / joules.abs).to be < Conservation::TOLERANCE
    end

    it "replays bit for bit through a snapshot" do
      straight = tick(working, 12)
      paused = tick(working, 6)
      resumed = OpenPitRig.seed(paused)
      6.times do |t|
        resumed.receive_supply(:line_shaft, OpenPitRig::SUPPLY_J)
        resumed.step!(tick: t + 7)
      end

      expect(ReactorSim.canonical(resumed.state)).to eq(ReactorSim.canonical(straight.state))
    end
  end
end
