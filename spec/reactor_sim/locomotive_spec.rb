# frozen_string_literal: true

require "support/mobile_rig"
require "support/conservation"

# **The locomotive and its train**: 4a's engine on wheels, taking the shovel's dig to the dump. A
# few ticks from a constructed point on the round for what the train does, zero for the driver's
# arithmetic and for where a hazard reaches. Relational — no figure here is a tuning target.
RSpec.describe ReactorSim::Operations::MobileEngine::Train do
  def me = ReactorSim::Operations::MobileEngine
  def track = MobileRig::TRACK
  def pit(**opts)
    op = MobileRig.build(id: :rig, seed: 1, engines: [], shovels: [ :shovel ], trains: { loco: :shovel }, **opts)
    MobileRig.at_work(MobileRig.at_work(op, :shovel), :loco, demand: 100.0)
  end

  def train_state(op) = MobileRig.state(op, :loco_train)
  def train(op) = op.nodes.fetch(:loco_train)
  def speed(op) = train(op).speed_m_s(train_state(op))
  def position(op) = train(op).position_m(train_state(op))
  def board(op) = me::Train::SIGNALS.keys.fetch(train_state(op).fetch(:signal))
  def overburden(kg) = MobileRig.parcels_at(293.15, overburden: kg)
  def full = me::WOODEN_TRAIN.fetch(:load_kg) * 0.95
  def momentum(op, m_s) = m_s / train(op).radius_m * train(op).moment_of_inertia
  def lever(value) = { target: value, actual: value }
  def unposted(*ids) = ids.to_h { |id| [ id, { station: nil, posting: nil } ] }

  # A train at `at` metres along the track, going `m_s`, with `cars` kilograms aboard.
  def at(metres, m_s: 0.0, cars: 0.0, nodes: {}, minions: {}, controls: {}, op: pit)
    MobileRig.seed(op, nodes: {
      loco_train: { position_m: metres, angular_momentum: momentum(op, m_s) },
      loco_cars: { parcels: overburden(cars) }
    }.merge(nodes), minions: minions, controls: controls)
  end

  def tick(op, ticks = 1)
    ticks.times { |t| op.step!(tick: t + 1) }
    op
  end

  def on_the_bank = 300.0
  def loading = track.mark(:loading)
  def dump = track.mark(:dump)

  describe "on the track" do
    it "climbs the bank loaded under its engine" do
      op = tick(at(on_the_bank, m_s: 3.0, cars: full), 20)

      expect(speed(op)).to be > 2.5
    end

    it "rolls back down the bank with nobody driving and the brake off, and holds with it on" do
      off = tick(at(on_the_bank, cars: full, minions: unposted(:loco_driver), controls: { loco_brake_release: lever(100.0) }), 20)
      on = tick(at(on_the_bank, cars: full, minions: unposted(:loco_driver)), 20)

      expect(speed(off)).to be < -0.1
      expect(speed(on).abs).to be < 0.01
    end

    it "is stopped gently by the buffer at the end of the track" do
      op = tick(at(0.2, m_s: -1.0, minions: unposted(:loco_driver), controls: { loco_brake_release: lever(100.0) }), 4)

      expect(train_state(op).fetch(:failure)).to be_nil
      expect(speed(op).abs).to be < 0.05
    end
  end

  describe "loading and tipping" do
    def dipper_dumping = { shovel_dipper: { phase: me::Dipper::PHASES.index(:dumping), phase_s: 0.0, parcels: overburden(1_000.0) } }

    it "takes the shovel's dump only standing at the loading mark, and the shovel waits on cars while it is away" do
      standing = tick(at(loading, nodes: dipper_dumping))
      away = tick(at(on_the_bank, m_s: 3.0, nodes: dipper_dumping), 2)

      expect(MobileRig.held_kg(standing, :loco_cars)).to be_positive
      expect(MobileRig.held_kg(away, :shovel_dipper)).to be > 990.0
      expect(me::Dipper::SIGNALS.keys.fetch(MobileRig.state(away, :shovel_dipper).fetch(:signal))).to be(:waiting_on_cars)
    end

    it "is tipped only at the dump, and only with the dumpmen there" do
      tipped = tick(at(dump, cars: full), 2)
      unmanned = tick(at(dump, cars: full, minions: unposted(:loco_dumpman_1, :loco_dumpman_2)), 2)
      away = tick(at(on_the_bank, m_s: 3.0, cars: full), 2)

      expect(MobileRig.held_kg(tipped, :loco_cars)).to be < full
      expect(MobileRig.held_kg(unmanned, :loco_cars)).to be_within(1e-6).of(full)
      expect(MobileRig.held_kg(away, :loco_cars)).to be_within(1e-6).of(full)
      expect(tipped.ledger.to_h.fetch(:mass_delivered)).to be_positive
    end
  end

  describe "the driver" do
    def levers(op) = op.state.fetch(:controls).transform_values { |c| c.fetch(:actual) }

    it "leaves the shovel full, waits there part-loaded, and comes back from the dump tipped" do
      leaving = levers(tick(at(loading, cars: full)))
      waiting = levers(tick(at(loading, cars: full / 2.0)))
      returning = levers(tick(at(dump)))

      expect(leaving.fetch(:loco_forward_gear)).to be_positive
      expect(leaving.fetch(:loco_brake_release)).to be_positive
      expect(waiting.values_at(:loco_forward_gear, :loco_reverse_gear, :loco_brake_release)).to all(eq(0.0))
      expect(returning.fetch(:loco_reverse_gear)).to be_positive
    end

    it "stands with the brake on asked for nothing" do
      op = tick(at(loading, cars: full, controls: { loco_driving: lever(0.0) }))

      expect(levers(op).values_at(:loco_forward_gear, :loco_reverse_gear, :loco_brake_release)).to all(eq(0.0))
    end

    # The same train closing on the dump: a sound hand is on the brake, a hand out of their depth
    # still driving.
    it "brakes later the further out of their depth he is" do
      op = at(dump - 8.0, m_s: 3.0, cars: full)
      round = op.control_points.fetch(:loco_driving).governor
      held = levers(op).slice(*round.levers)
      govern = ->(lateness) {
        round.govern(commanded: 100.0, nodes: op.nodes, states: op.state.fetch(:nodes), content: op.content,
                     dt: ReactorSim::DT, frozen: false, held: held, lateness: lateness).fetch(:loco_brake_release)
      }

      expect(govern.(1.0)).to eq(0.0)
      expect(govern.(3.0)).to be_positive
    end

    it "puts the brake on against a bank running her past the speed he wants" do
      op = tick(at(on_the_bank, m_s: -4.5))

      expect(levers(op).fetch(:loco_brake_release)).to be < 100.0
    end
  end

  describe "leaving the road" do
    def failure(op) = train_state(op).fetch(:failure)

    it "crashes into the shovel past the buffer, and wrecks its boom" do
      op = tick(at(0.2, m_s: -3.0, minions: unposted(:loco_driver), controls: { loco_brake_release: lever(100.0) }), 2)

      expect(failure(op)).to be(:crashed)
      expect(MobileRig.state(op, :shovel_boom).fetch(:failure)).not_to be_nil
    end

    it "goes over the tip past the buffer at the dump end" do
      op = tick(at(track.length_m - 0.2, m_s: 3.0, minions: unposted(:loco_driver),
                   controls: { loco_brake_release: lever(100.0) }), 2)

      expect(failure(op)).to be(:over_the_tip)
    end

    it "leaves the rails running far past her speed, and not at it" do
      fast = tick(at(on_the_bank, m_s: -6.5, minions: unposted(:loco_driver), controls: { loco_brake_release: lever(100.0) }))
      running = tick(at(on_the_bank, m_s: -3.5, minions: unposted(:loco_driver), controls: { loco_brake_release: lever(100.0) }))

      expect(failure(fast)).to be(:derailed)
      expect(failure(running)).to be_nil
    end
  end

  describe "the footplate" do
    def reached(op, node, mode, detail = {})
      ReactorSim::Tick.new(op, op.state).send(:hazards_from, [ { node: node, mode: mode, detail: detail } ]).places.keys
    end

    it "shares a burst on it with where it stands: the pit beside the shovel, and not the dump" do
      burst = [ :loco_boiler, :explosion, { flash_expansion: 22.0 } ]

      expect(reached(at(loading), *burst)).to include(:loco_footplate, :pit)
      expect(reached(at(dump), *burst)).to include(:loco_footplate, :dump)
      expect(reached(at(dump), *burst)).not_to include(:pit)
    end

    it "is reached by the boom coming down on a train standing under it, and not one at the dump" do
      expect(reached(at(loading), :shovel_boom, :down)).to include(:loco_footplate)
      expect(reached(at(dump), :shovel_boom, :down)).not_to include(:loco_footplate)
    end
  end

  describe "who it can hurt" do
    it "is a danger to the pitmen only while it moves through the pit" do
      op = pit
      activity = ->(where, m_s) {
        state = train_state(at(where, m_s: m_s, op: op))
        train(op).activity(state, :pit, ReactorSim::DT)
      }

      expect(activity.(loading, 2.0)).to be_positive
      expect(activity.(loading, 0.0)).to eq(0.0)
      expect(activity.(on_the_bank, 2.0)).to eq(0.0)
    end

    it "catches a dumpman only while the cars are being tipped" do
      tipping = tick(at(dump, cars: full), 2)
      standing = tick(at(dump), 2)
      landing = tipping.nodes.fetch(:loco_tipping)

      expect(landing.activity(MobileRig.state(tipping, :loco_tipping), :tipping, ReactorSim::DT)).to be_positive
      expect(landing.activity(MobileRig.state(standing, :loco_tipping), :tipping, ReactorSim::DT)).to eq(0.0)
    end
  end

  describe "the board" do
    it "says what holds, in order" do
      expect(board(tick(at(loading)))).to be(:waiting_on_shovel)
      expect(board(tick(at(on_the_bank, m_s: 3.0, cars: full)))).to be(:running_loaded)
      expect(board(tick(at(dump, cars: full, minions: unposted(:loco_dumpman_1, :loco_dumpman_2)), 2))).to be(:waiting_on_dumpmen)
      expect(board(tick(at(0.2, m_s: -3.0, minions: unposted(:loco_driver), controls: { loco_brake_release: lever(100.0) }), 2)))
        .to be(:crashed)
    end

    it "reaches the player in words" do
      op = tick(at(on_the_bank, m_s: 3.0, cars: full))

      expect(op.project(viewer: :player).to_h.dig(:gauges, :loco_board)).to eq("running loaded")
    end
  end

  describe "the books" do
    it "balances mass and energy through a stretch of the round, loading and climbing" do
      op = at(loading, cars: full - 100.0, nodes: { shovel_dipper: { phase: me::Dipper::PHASES.index(:dumping), phase_s: 0.0,
                                                                   parcels: overburden(1_000.0) } })
      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      tick(op, 20)

      expect(position(op)).to be > loading
      expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass).abs / mass.abs).to be < Conservation::TOLERANCE
      expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules).abs / joules.abs).to be < Conservation::TOLERANCE
    end

    it "replays bit for bit through a snapshot taken mid-run" do
      straight = tick(at(on_the_bank, m_s: 3.0, cars: full), 12)
      paused = tick(at(on_the_bank, m_s: 3.0, cars: full), 6)
      resumed = MobileRig.seed(paused)
      6.times { |t| resumed.step!(tick: t + 7) }

      expect(ReactorSim.canonical(resumed.state)).to eq(ReactorSim.canonical(straight.state))
    end
  end
end
