# frozen_string_literal: true

require "support/open_pit_rig"
require "support/conservation"

# **Benches and slides**: a face undercut by digging hangs, the barmen bar it down, and left
# hanging past a hidden threshold it slides onto the face and buries it; a dump's edge loads as
# spoil is tipped on it and breaks back past one of its own. Zero ticks for the arithmetic, a few
# from a constructed state for the rest. Relational — no figure here is a tuning target.
RSpec.describe ReactorSim::Operations::OpenPit do
  before { allow(ReactorSim::Content).to receive(:default).and_return(OpenPitRig::CONTENT) }

  def pit(loadout = {}, ground: OpenPitRig::ORDINARY)
    OpenPitRig.build(id: :pit, seed: 1, loadout: { quarters: :barracks }.merge(loadout), ground: ground,
                     crew: OpenPitRig.crew(OpenPitRig::MOST_SEATS))
  end

  def working(**posts) = OpenPitRig.posted(OpenPitRig.at_work(pit), **posts)
  def tick(op, ticks = 1) = OpenPitRig.tick(op, ticks)
  def state(op, id) = OpenPitRig.node_state(op, id)
  def held(op, id) = OpenPitRig.held_kg(op, id)
  def board(op) = described_class::Bench::SIGNALS.keys.fetch(state(op, :stripping_bench).fetch(:signal))
  def edge(op) = described_class::TipHead::SIGNALS.keys.fetch(state(op, :tip_head).fetch(:signal))
  def threshold(op, id) = state(op, id).fetch(:thresholds).first
  def hurt(op) = op.state.fetch(:minions).select { |_, m| m.fetch(:wounds).any? }.keys
  def bench = described_class::Bench
  def spoil(kg) = OpenPitRig.parcels_at(293.15, overburden: kg)

  # What a bench sees of the sky and the sump, for the arithmetic: a struct of its own, so no
  # other spec's can stand in for it.
  def seen(sky)
    Struct.new(:sky, :nodes, :states) { def node_state(id) = states[id] }.new(sky, {}, {})
  end

  describe "the face hanging" do
    it "hangs the more the more is dug, and the barmen bring it down into the muck" do
      two = tick(OpenPitRig.seed(working, minions: { crew_3: { station: nil, posting: nil },
                                                     crew_4: { station: nil, posting: nil } }), 8)
      four = tick(working, 8)
      barred = tick(OpenPitRig.seed(working(stripping_barmen: %i[crew_15 crew_16]),
                                    nodes: { stripping_bench: { overhang_kg: 500.0 } }), 8)

      expect(state(four, :stripping_bench).fetch(:overhang_kg)).to be > state(two, :stripping_bench).fetch(:overhang_kg)
      expect(state(barred, :stripping_bench).fetch(:overhang_kg)).to be < 500.0
      expect(state(barred, :stripping_barring).fetch(:carried_kg)).to be_positive
    end

    it "holds less for a taller bench, and less again in the rain" do
      node = pit.nodes.fetch(:stripping_bench)
      drawn = state(pit, :stripping_bench)
      holds = ->(thickness, wet) { node.holds_kg(drawn.merge(thickness_m: thickness), seen({ wet: wet })) }

      expect(holds.(6.0, 0.0)).to be < holds.(3.0, 0.0)
      expect(holds.(4.0, 1.0)).to be < holds.(4.0, 0.0)
    end

    it "draws every threshold afresh, the first the largest, and a pinned ground the median" do
      wild = pit(ground: nil).nodes.fetch(:stripping_bench)
      draws = Array.new(500) { |i| wild.initial_state(ReactorSim::Rng.stream(i, :stripping_bench), OpenPitRig::CONTENT) }
      runs = draws.map { |d| d.fetch(:thresholds) }
      mean = ->(xs) { xs.sum / xs.length }

      expect(mean.(runs.map(&:first))).to be > mean.(runs.map { |r| r[1] })
      expect(runs.map { |r| r.uniq.length }).to all(eq(runs.first.length))
      expect(threshold(pit, :stripping_bench)).to eq(bench::HANGING_KG * bench::FIRST_HANGING)
    end

    it "says the face is hanging before it goes" do
      hanging = tick(OpenPitRig.seed(working, nodes: { stripping_bench: { overhang_kg: threshold(pit, :stripping_bench) * 0.8 } }))

      expect(board(hanging)).to be(:hanging)
      expect(state(hanging, :stripping_bench).fetch(:failure)).to be_nil
    end
  end

  describe "a slide" do
    def slid(over:)
      op = working
      op = OpenPitRig.seed(op, nodes: { stripping_bench: { overhang_kg: threshold(op, :stripping_bench) + over } })
      tick(op, 3)
    end

    it "comes when the overhang reaches the threshold, and not before" do
      held_up = slid(over: -50.0)
      came = slid(over: 1.0)

      expect(held(held_up, :stripping_slip) + held(held_up, :stripping_muck)).to be < held(came, :stripping_slip) + held(came, :stripping_muck)
      expect(state(came, :stripping_bench).fetch(:overhang_kg)).to be < 50.0
      expect(threshold(came, :stripping_bench)).not_to eq(threshold(pit, :stripping_bench))
    end

    it "hurts whoever is on that bench, and nobody on the other" do
      came = slid(over: 1.0)
      at = ->(place) { came.state.fetch(:minions).select { |_, m| m[:place] == place }.keys }

      expect(hurt(came)).to include(*at.(:stripping_bench))
      expect(hurt(came) & at.(:ore_bench)).to be_empty
    end

    it "takes a share of a fitted shovel's boom with it" do
      shovelled = pit({ stripping_shovel_dipper: :yard_dipper }).nodes.fetch(:stripping_bench)

      expect(shovelled.failure_damages.dig(:slid, :stripping_shovel_boom)).to be_positive
      expect(pit.nodes.fetch(:stripping_bench).failure_damages).to be_empty
    end

    it "buries the face under its pile until the pile is cleared, and the pile drains into the muck" do
      buried = tick(OpenPitRig.seed(working, nodes: { stripping_slip: { parcels: spoil(800.0) },
                                                      stripping_muck: { parcels: spoil(3_000.0) } }), 2)
      draining = tick(OpenPitRig.seed(working, nodes: { stripping_slip: { parcels: spoil(800.0) } }), 2)

      expect(board(buried)).to be(:buried)
      expect(state(buried, :stripping_getting).fetch(:carried_kg, 0.0)).to eq(0.0)
      expect(held(draining, :stripping_slip)).to be < 800.0
    end
  end

  describe "the dump's edge" do
    it "loads faster in the rain, and settles with time" do
      tipping = ->(nodes) { tick(OpenPitRig.seed(working, nodes: nodes), 8) }
      dry = tipping.({ tip_head: { parcels: [] } })
      # Just stopped raining: wet underfoot for a while yet.
      wet = tipping.({ outdoors: { wet: 1.0, dry_s: 0.0 } })
      settling = tick(OpenPitRig.seed(pit, nodes: { tip_head: { edge_load_kg: 10_000.0 } }), 8)

      expect(state(wet, :tip_head).fetch(:edge_load_kg)).to be > state(dry, :tip_head).fetch(:edge_load_kg)
      expect(state(settling, :tip_head).fetch(:edge_load_kg)).to be < 10_000.0
    end

    it "breaks back at its threshold, sends the tip head into the dump, and hurts whoever is on it" do
      op = working
      over = OpenPitRig.seed(op, nodes: { tip_head: { edge_load_kg: threshold(op, :tip_head) + 50.0, parcels: spoil(800.0) } })
      broke = tick(over, 4)
      cracked = tick(OpenPitRig.seed(op, nodes: { tip_head: { edge_load_kg: threshold(op, :tip_head) * 0.8 } }))

      expect(edge(broke)).to be(:broken_back)
      expect(held(broke, :tip_head)).to be < 800.0
      expect(hurt(broke)).to include(*OpenPitRig.gang(broke, :dumpmen))
      expect(threshold(broke, :tip_head)).not_to eq(threshold(op, :tip_head))
      expect(edge(cracked)).to be(:cracking)
    end
  end

  describe "the books" do
    def falling
      op = working
      OpenPitRig.seed(op, nodes: { stripping_bench: { overhang_kg: threshold(op, :stripping_bench) + 1.0 },
                                   tip_head: { edge_load_kg: threshold(op, :tip_head) + 1.0, parcels: spoil(800.0) } })
    end

    it "closes mass and energy through a slide and a breakback" do
      op = falling
      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      tick(op, 10)

      expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass).abs / mass.abs).to be < Conservation::TOLERANCE
      expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules).abs / joules.abs)
        .to be < Conservation::TOLERANCE
    end

    it "replays bit for bit through a snapshot" do
      straight = tick(falling, 8)
      resumed = OpenPitRig.seed(tick(falling, 4))
      4.times do |t|
        resumed.receive_supply(:line_shaft, OpenPitRig::SUPPLY_J)
        resumed.step!(tick: t + 5)
      end

      expect(ReactorSim.canonical(resumed.state)).to eq(ReactorSim.canonical(straight.state))
    end
  end
end
