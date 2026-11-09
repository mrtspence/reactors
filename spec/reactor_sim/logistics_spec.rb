# frozen_string_literal: true

require "support/open_pit_rig"
require "support/mobile_rig"
require "support/conservation"

# **Pit logistics**: coal into the pit by a siding and out to the machines by their coalers, a stand
# for coal and water at each road's dump, the heavy engine and the railroad dipper, a second dinky
# sharing a face's road through a loop, the signals its drivers read it by, the collision when they
# read it wrong, and boarding a footplate at a stand. Zero ticks where the claim is a function, a few
# from a constructed state for the rest. Relational — no figure here is a tuning target.
RSpec.describe ReactorSim::Operations::OpenPit do
  before { allow(ReactorSim::Content).to receive(:default).and_return(OpenPitRig::CONTENT) }

  def me = ReactorSim::Operations::MobileEngine
  def tick(op, ticks = 1) = OpenPitRig.tick(op, ticks)
  def state(op, id) = OpenPitRig.node_state(op, id)
  def kg(op, id, resource = nil)
    state(op, id).fetch(:parcels).sum { |p| resource.nil? || p.fetch(:resource) == resource ? p.fetch(:kg) : 0.0 }
  end

  def pit(loadout = {})
    OpenPitRig.build(id: :pit, seed: 1, loadout: { quarters: :barracks }.merge(loadout),
                     crew: OpenPitRig.crew(OpenPitRig::MOST_SEATS))
  end

  def two_trains = { stripping_train_train: :dinkey_train, stripping_passing_track: :passing_track,
                     stripping_train_2_train: :dinkey_train }

  # Cars the driver calls full.
  def full_kg = me::WOODEN_TRAIN.fetch(:load_kg) * 0.95

  # `train` standing at `mark` on the stripping road, its cars holding `cars_kg` of overburden.
  def standing(id, mark, cars_kg: 0.0)
    train = :"#{id}_train"
    track = described_class::TRACKS.fetch(:stripping)
    { train => { position_m: track.mark(mark), angular_momentum: 0.0 },
      :"#{id}_cars" => { parcels: cars_kg.positive? ? OpenPitRig.parcels_at(293.15, overburden: cars_kg) : [] } }
  end

  # `train` out on the stripping road at `position_m`, running at `speed_m_s`.
  def running(op, id, position_m, speed_m_s)
    train = op.nodes.fetch(:"#{id}_train")
    { "#{id}_train": { position_m: position_m, angular_momentum: train.moment_of_inertia * speed_m_s / train.radius_m } }
  end

  def signal(op, id) = me::Train::SIGNALS.keys.fetch(state(op, :"#{id}_train").fetch(:signal))

  describe "bunkers and tanks" do
    it "starts an engine on a third of the next bunker and tank up" do
      stat = ->(part, key) { ReactorSim::Parts.fetch(part).stats.fetch(key) }

      expect(stat.(:small_bunker, :coal_kg) * 3).to eq(stat.(:bunker, :coal_kg))
      expect(stat.(:small_tank, :water_kg) * 3).to eq(stat.(:tank, :water_kg))
    end

    it "burns twice the coal in the heavy engine, carrying on from its seeded state" do
      burnt = lambda { |engine|
        op = MobileRig.at_work(MobileRig.build(id: :rig, seed: 1, loadout: { engine_engine: engine }))
        names = MobileRig.names(:engine)
        before = MobileRig.state(op, names.(:bunker)).fetch(:parcels).sum { |p| p.fetch(:kg) }
        pressure = ->(o) { o.nodes.fetch(names.(:boiler)).pressure_pa(MobileRig.state(o, names.(:boiler)), o.content) }
        start = pressure.(op)
        40.times { |t| op.step!(tick: t + 1) }
        [ before - MobileRig.state(op, names.(:bunker)).fetch(:parcels).sum { |p| p.fetch(:kg) }, pressure.(op) / start ]
      }
      vertical, = burnt.(:vertical_engine)
      heavy, held = burnt.(:heavy_vertical_engine)

      expect(heavy).to be > 1.5 * vertical
      expect(held).to be_within(0.05).of(1.0)
    end

    it "fits a railroad dipper bigger than the yard dipper, wanting more pitmen" do
      stats = ->(part) { ReactorSim::Parts.fetch(part).stats }

      expect(stats.(:railroad_dipper).fetch(:capacity_kg)).to be > stats.(:yard_dipper).fetch(:capacity_kg)
      expect(stats.(:railroad_dipper).fetch(:pitmen)).to be > stats.(:yard_dipper).fetch(:pitmen)
    end
  end

  describe "the siding" do
    it "brings a consignment in on its timetable, booked as added, and holds the next while it is full" do
      op = pit({ siding: :coal_siding })
      siding = op.nodes.fetch(:siding)
      due = OpenPitRig.seed(op, nodes: { siding: { due_s: 0.1 } })
      added = due.ledger.fetch(:mass_added, 0.0)
      tick(due)
      full = OpenPitRig.seed(op, nodes: { siding: { due_s: 0.1, parcels: OpenPitRig.parcels_at(293.15, coal: siding.consignment_kg * 2.0) } })

      expect(kg(due, :siding)).to eq(siding.consignment_kg)
      expect(due.ledger.fetch(:mass_added) - added).to be >= siding.consignment_kg
      expect(kg(tick(full), :siding)).to eq(siding.consignment_kg * 2.0)
    end

    it "fills the yard only with the unloaders at it, and over a staithe with nobody" do
      wagons = ->(op) { OpenPitRig.seed(op, nodes: { siding: { parcels: OpenPitRig.parcels_at(293.15, coal: 1_000.0) },
                                                    coal_yard: { parcels: [] } }) }
      left = tick(wagons.(pit({ siding: :coal_siding })), 4)
      unloaded = tick(OpenPitRig.posted(wagons.(pit({ siding: :coal_siding })), unloaders: %i[crew_30 crew_31]), 4)
      staithe = tick(wagons.(pit({ siding: :coal_staithe })), 4)

      expect(kg(left, :coal_yard)).to eq(0.0)
      expect(kg(unloaded, :coal_yard)).to be_positive
      expect(kg(staithe, :coal_yard)).to be_positive
    end
  end

  describe "coal to the machines" do
    it "tops a shovel's bunker from the face's drop, and the coalers keep the drop" do
      op = pit({ stripping_shovel_dipper: :yard_dipper })
      low = OpenPitRig.seed(op, nodes: { stripping_shovel_bunker: { parcels: OpenPitRig.parcels_at(293.15, coal: 10.0) },
                                         stripping_coal_drop: { parcels: OpenPitRig.parcels_at(293.15, coal: 200.0) } })
      topped = tick(low, 6)
      kept = tick(OpenPitRig.posted(op, stripping_coalers: %i[crew_30 crew_31]), 6)

      expect(kg(topped, :stripping_shovel_bunker, :coal)).to be > 10.0
      expect(kg(kept, :stripping_coal_drop)).to be_positive
      expect(op.nodes).not_to have_key(:ore_coal_drop)
    end

    it "takes water and coal at the stand standing tipped, waits there until topped, and none away" do
      op = pit({ stripping_train_train: :dinkey_train })
      low = { stripping_train_supply: { parcels: OpenPitRig.parcels_at(293.15, water: 50.0) } }
      at_stand = tick(OpenPitRig.seed(op, nodes: standing(:stripping_train, :dump).merge(low)), 8)
      away = tick(OpenPitRig.seed(op, nodes: running(op, :stripping_train, 200.0, 0.0).merge(low)), 8)

      expect(kg(at_stand, :stripping_train_supply, :water)).to be > kg(away, :stripping_train_supply, :water)
      expect(signal(at_stand, :stripping_train)).to be(:at_the_stand)
      expect(state(at_stand, :stripping_train_train).fetch(:position_m))
        .to be_within(me::Train::STANDING_M).of(described_class::TRACKS.fetch(:stripping).mark(:dump))
    end
  end

  describe "two trains" do
    it "builds a second dinky only on a passing track" do
      without = pit({ stripping_train_train: :dinkey_train, stripping_train_2_train: :dinkey_train })
      with = pit(two_trains)

      expect(without.nodes).not_to have_key(:stripping_train_2_train)
      expect(with.nodes).to have_key(:stripping_train_2_train)
      expect(state(with, :stripping_train_2_train).fetch(:position_m)).to eq(described_class::TRACKS.fetch(:stripping).mark(:passing))
    end

    it "keeps the second waiting in the loop while the first has the shovel" do
      op = tick(pit(two_trains), 20)

      expect(signal(op, :stripping_train_2)).to be(:in_the_loop)
      expect(state(op, :stripping_train_2_train).fetch(:position_m))
        .to be_within(me::Train::STANDING_M).of(described_class::TRACKS.fetch(:stripping).mark(:passing))
    end

    it "sends a loaded train out only with the road clear" do
      op = pit(two_trains)
      taken = tick(OpenPitRig.seed(op, nodes: standing(:stripping_train, :loading, cars_kg: full_kg)
                                               .merge(running(op, :stripping_train_2, 200.0, 0.0))), 12)
      clear = tick(OpenPitRig.seed(op, nodes: standing(:stripping_train, :loading, cars_kg: full_kg)), 12)

      expect(signal(taken, :stripping_train)).to be(:waiting_on_road)
      expect(state(clear, :stripping_train_train).fetch(:position_m))
        .to be > described_class::TRACKS.fetch(:stripping).mark(:loading) + me::Train::STANDING_M
    end

    it "wrecks both trains meeting fast on the road, and buffers them up meeting slow" do
      op = pit(two_trains)
      meeting = ->(speed) { tick(OpenPitRig.seed(op, nodes: running(op, :stripping_train, 200.0, speed).merge(running(op, :stripping_train_2, 205.0, -speed))), 2) }
      fast = meeting.(3.0)
      slow = meeting.(0.3)

      expect(%i[stripping_train_train stripping_train_2_train].map { |id| state(fast, id)[:failure] }).to all(be(:collided))
      expect(%i[stripping_train_train stripping_train_2_train].map { |id| state(slow, id)[:failure] }).to all(be_nil)
    end
  end

  describe "the signals" do
    def road(kind) = pit(two_trains.merge(stripping_road_signals: kind))
    def node(op) = op.nodes.fetch(:stripping_road)
    def taken(op) = OpenPitRig.seed(op, nodes: running(op, :stripping_train_2, 200.0, 0.0))
    def reading(op) = state(tick(op), :stripping_road).fetch(:clear).fetch(:stripping_train_train)

    it "has the flagman say nothing with nobody posted, the truth posted, and a false clear once he has misjudged it" do
      op = taken(road(:flagman))
      posted = OpenPitRig.posted(op, stripping_flagman: %i[crew_30])

      expect(reading(op)).to be_nil
      expect(reading(posted)).to be(false)
      expect(reading(OpenPitRig.seed(posted, nodes: { stripping_road: { false_clear_s: 10.0 } }))).to be(true)
      expect(node(op).perils.map(&:mishap)).to all(include(kind: :false_clear))
    end

    it "lets only the train holding the staff go, and hands it over in the loop" do
      op = road(:train_staff)
      handed = OpenPitRig.seed(op, nodes: standing(:stripping_train, :passing).merge(standing(:stripping_train_2, :loading))
                                            .merge(stripping_road: { handover_s: 1.0e3 }))

      expect(state(tick(op), :stripping_road).fetch(:clear)).to eq(stripping_train_train: true, stripping_train_2_train: false)
      expect(state(tick(handed), :stripping_road).fetch(:holder)).to be(:stripping_train_2_train)
    end

    it "reads block signals true, wears them only with a train on the road, and worn they stick at clear" do
      op = road(:block_signals)
      seen = ->(o) { Struct.new(:nodes, :states, :content) { def node_state(id) = states[id] }.new(o.nodes, o.state.fetch(:nodes), o.content) }

      expect(reading(taken(op))).to be(false)
      expect(node(op).stress_per_second(state(op, :stripping_road), seen.(taken(op)))).to be_positive
      expect(node(op).stress_per_second(state(op, :stripping_road), seen.(op))).to eq(0.0)
      expect(reading(OpenPitRig.seed(taken(op), nodes: { stripping_road: { failure: :stuck_clear } }))).to be(true)
    end

    it "has a driver with no signals look for himself, which he can misjudge" do
      peril = pit(two_trains).nodes.fetch(:stripping_train_train).perils.find { |p| p.id == :misjudged_the_road }

      expect(peril.judged).to be(:wrongly)
      expect(peril.mishap).to include(kind: :misjudged_road)
    end
  end

  describe "boarding" do
    it "opens the way onto a footplate only while its train stands there" do
      landing = pit({ stripping_train_train: :dinkey_train }).nodes.fetch(:stripping_train_loading)

      expect(landing.blocks_passage?({ standing: true })).to be(false)
      expect(landing.blocks_passage?({ standing: false })).to be(true)
    end

    it "lets a driver sent off step down at a stand, and keeps him aboard away from one" do
      op = pit({ stripping_train_train: :dinkey_train })
      driver = OpenPitRig.gang(op, :stripping_train_driving).first
      sent = lambda { |nodes|
        o = OpenPitRig.seed(op, nodes: nodes)
        o.assign_minion(driver, :dump_coalers)
        tick(o, 30).state.dig(:minions, driver, :place)
      }

      expect(sent.(standing(:stripping_train, :dump))).not_to be(:stripping_train_footplate)
      expect(sent.(running(op, :stripping_train, 200.0, 0.0))).to be(:stripping_train_footplate)
    end
  end

  describe "the books" do
    it "closes mass and energy with wagons arriving and two trains at work" do
      op = OpenPitRig.seed(pit(two_trains.merge(siding: :coal_siding, stripping_shovel_dipper: :yard_dipper)),
                           nodes: { siding: { due_s: 0.5 } })
      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      tick(op, 12)

      expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass).abs / mass.abs).to be < Conservation::TOLERANCE
      expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules).abs / joules.abs)
        .to be < Conservation::TOLERANCE
    end

    it "replays bit for bit through a snapshot" do
      build = -> { pit(two_trains.merge(stripping_road_signals: :flagman)) }
      straight = tick(build.(), 8)
      resumed = OpenPitRig.seed(tick(build.(), 4))
      4.times do |t|
        resumed.receive_supply(:line_shaft, OpenPitRig::SUPPLY_J)
        resumed.step!(tick: t + 5)
      end

      expect(ReactorSim.canonical(resumed.state)).to eq(ReactorSim.canonical(straight.state))
    end
  end
end
