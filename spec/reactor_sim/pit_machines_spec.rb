# frozen_string_literal: true

require "support/open_pit_rig"
require "support/conservation"

# **Machines in the pit**: a steam shovel and a dinky at the stripping face, each an upgrade, each
# working with or without the other. A tick or two from a constructed state. Relational — no
# figure here is a tuning target.
RSpec.describe "machines in the open pit" do
  before { allow(ReactorSim::Content).to receive(:default).and_return(OpenPitRig::CONTENT) }

  def me = ReactorSim::Operations::MobileEngine
  def pit_module = ReactorSim::Operations::OpenPit
  def shovel = { stripping_shovel_dipper: :yard_dipper }
  def dinky = { stripping_train_train: :dinkey_train }

  def pit(loadout = {})
    OpenPitRig.build(id: :pit, seed: 1, loadout: { quarters: :changing_house }.merge(loadout),
                     crew: OpenPitRig.crew(OpenPitRig.seats_in(:changing_house)))
  end

  # Everybody not already at an engine, at the stripping face's jobs.
  def crewed(loadout = {})
    op = pit(loadout)
    free = op.state.fetch(:minions).select { |_, s| s[:station].nil? || s[:station] == :quarters }.keys
    posts = { stripping_getters: free[0, 3], stripping_barrowmen: free[3, 3], dumpmen: free[6, 1] }
    posts[:stripping_shovel_craneman] = free[7, 1] if loadout.key?(:stripping_shovel_dipper)
    posts[:stripping_shovel_pitmen] = free[8, 5] if loadout.key?(:stripping_shovel_dipper)
    posts[:stripping_train_loaders] = free[13, 4] if loadout.key?(:stripping_train_train)
    OpenPitRig.posted(op, **posts)
  end

  def tick(op, ticks = 1) = OpenPitRig.tick(op, ticks)
  def state(op, id) = OpenPitRig.node_state(op, id)
  def held(op, id) = OpenPitRig.held_kg(op, id)
  def overburden(kg) = OpenPitRig.parcels_at(293.15, overburden: kg)
  def dumping(kg = 1_000.0) = { stripping_shovel_dipper: { phase: me::Dipper::PHASES.index(:dumping), phase_s: 0.0, parcels: overburden(kg) } }
  def train_at(op, metres, m_s: 0.0)
    train = op.nodes.fetch(:stripping_train_train)
    { stripping_train_train: { position_m: metres, angular_momentum: m_s / train.radius_m * train.moment_of_inertia } }
  end
  def loading = pit_module::TRACKS.fetch(:stripping).mark(:loading)
  def away = 150.0
  def lever(value) = { target: value, actual: value }

  describe "the slots" do
    it "builds no machine and asks for none while nothing is fitted" do
      op = pit

      expect(pit_module.assembly_for(:sunk_pit, {}).verdict).to be_ok
      expect(op.nodes.keys.grep(/stripping_(shovel|train)_/)).to be_empty
    end

    it "brings a whole working shovel, or a whole dinky, with one part" do
      shoveled = pit(shovel)
      trained = pit(dinky)

      expect(shoveled.nodes).to include(:stripping_shovel_boiler, :stripping_shovel_dipper, :stripping_shovel_chain)
      expect(trained.nodes).to include(:stripping_train_boiler, :stripping_train_train, :stripping_train_brake)
      expect(shoveled.nodes.keys.grep(/stripping_train_/)).to be_empty
    end
  end

  describe "the start" do
    it "starts a fitted engine at work and its crew at their posts" do
      op = pit(shovel)
      water = state(op, :stripping_shovel_boiler).fetch(:parcels).sum { |p| p.fetch(:resource) == :water ? p.fetch(:kg) : 0.0 }
      posted = op.state.fetch(:minions).values.map { |s| s[:station] }

      expect(water).to be_within(1e-6).of(me::AT_WORK.dig(:boiler, :water))
      expect(op.nodes.fetch(:stripping_shovel_flywheel).omega(state(op, :stripping_shovel_flywheel))).to be_positive
      expect(posted).to include(:stripping_shovel_driving, :stripping_shovel_stoking)
    end
  end

  describe "the four ways a face is worked" do
    it "casts onto the muck with a shovel and no dinky, past what the barrows clear" do
      op = tick(OpenPitRig.seed(crewed(shovel), nodes: dumping), 4)

      expect(held(op, :stripping_muck)).to be > 900.0
    end

    it "loads a standing train by hand from the muck with a dinky and no shovel, and nothing while it is away" do
      muck = { stripping_muck: { parcels: overburden(2_000.0) } }
      standing = crewed(dinky)
      standing = tick(OpenPitRig.seed(standing, nodes: muck.merge(train_at(standing, loading))), 2)
      gone = crewed(dinky)
      gone = tick(OpenPitRig.seed(gone, nodes: muck.merge(train_at(gone, away, m_s: 3.0))), 2)

      expect(held(standing, :stripping_train_cars)).to be_positive
      expect(held(gone, :stripping_train_cars)).to eq(0.0)
    end

    it "loads a standing train with both, casts while it is away, and waits if told not to cast" do
      both = shovel.merge(dinky)
      standing = crewed(both)
      standing = tick(OpenPitRig.seed(standing, nodes: dumping.merge(train_at(standing, loading))), 4)
      casting = crewed(both)
      casting = tick(OpenPitRig.seed(casting, nodes: dumping.merge(train_at(casting, away, m_s: 3.0))), 4)
      waiting = crewed(both)
      waiting = tick(OpenPitRig.seed(waiting, nodes: dumping.merge(train_at(waiting, away, m_s: 3.0)),
                                              controls: { stripping_shovel_casting: lever(0.0) }))

      expect(held(standing, :stripping_train_cars)).to be > 900.0
      expect(held(casting, :stripping_muck)).to be > 900.0
      expect(held(waiting, :stripping_shovel_dipper)).to be > 900.0
      expect(me::Dipper::SIGNALS.keys.fetch(state(waiting, :stripping_shovel_dipper).fetch(:signal))).to be(:waiting_on_cars)
    end

    it "is worked by hand alone with nothing fitted, as before" do
      expect(pit.nodes.keys).to match_array(OpenPitRig.build(id: :pit, seed: 1).nodes.keys)
    end
  end

  describe "the face" do
    # The shovel reads its bench as getters do: the stripping stopped, an ore shovel moves up no
    # further than is uncovered.
    it "moves an ore shovel up no further than the stripping has uncovered" do
      op = pit(ore_shovel_dipper: :yard_dipper)
      seats = op.state.fetch(:minions).select { |_, s| s[:station].nil? || s[:station] == :quarters }.keys
      op = OpenPitRig.posted(op, ore_shovel_pitmen: seats[0, 5])
      stopped = tick(OpenPitRig.faces_at(op, stripping_m: pit_module::STRIPPING_LEAD_M,
                                             ore_m: pit_module::STRIPPING_LEAD_M - pit_module::BERM_M), 2)
      open = tick(op, 2)

      expect(state(stopped, :ore_shovel_moving_up).fetch(:carried_kg, 0.0)).to eq(0.0)
      expect(state(open, :ore_shovel_moving_up).fetch(:carried_kg)).to be_positive
    end

    # Zero ticks, against a context that reads what it is told.
    it "costs the shovel's engine more to cut a hard stretch" do
      dipper = pit(shovel).nodes.fetch(:stripping_shovel_dipper)
      cut = ->(hardness) {
        ctx = Struct.new(:dt, :bench) do
          def node_omega(_id) = 34.0
          def node_state(id) = id == :stripping_bench ? bench : nil
        end.new(ReactorSim::DT, { hardness: hardness })
        dipper.drag_conductances({ dug_kg: 20.0, phase: 0 }, ctx).fetch(:friction)
      }

      expect(cut.(3.0)).to be > cut.(1.0)
    end
  end

  describe "the trains" do
    it "tips the stripping train at the spoil dump" do
      op = crewed(dinky)
      seats = op.state.fetch(:minions).select { |_, s| s[:station].nil? || s[:station] == :quarters }.keys
      dump = pit_module::TRACKS.fetch(:stripping).mark(:dump)
      op = OpenPitRig.posted(op, stripping_train_dumpmen: seats.last(2))
      op = tick(OpenPitRig.seed(op, nodes: train_at(op, dump).merge(stripping_train_cars: { parcels: overburden(5_000.0) })), 2)

      expect(held(op, :spoil_dump)).to be_positive
    end
  end

  describe "the books" do
    it "balances mass and energy with both machines at work" do
      op = OpenPitRig.seed(crewed(shovel.merge(dinky)), nodes: dumping)
      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      tick(op, 20)

      expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass).abs / mass.abs).to be < Conservation::TOLERANCE
      expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules).abs / joules.abs).to be < Conservation::TOLERANCE
    end

    it "replays bit for bit through a snapshot" do
      straight = tick(crewed(shovel.merge(dinky)), 12)
      paused = tick(crewed(shovel.merge(dinky)), 6)
      resumed = OpenPitRig.seed(paused)
      6.times do |t|
        resumed.receive_supply(:line_shaft, OpenPitRig::SUPPLY_J)
        resumed.step!(tick: t + 7)
      end

      expect(ReactorSim.canonical(resumed.state)).to eq(ReactorSim.canonical(straight.state))
    end
  end
end
