# frozen_string_literal: true

require "support/mobile_rig"
require "support/conservation"

# **The steam shovel**: 4a's engine digging a bench into a car, a dipperful at a time. One tick
# from a constructed state for what the dipper does, zero for the arithmetic its chain, boom and
# driver run on. Relational — no figure here is a tuning target.
RSpec.describe ReactorSim::Operations::MobileEngine::Dipper do
  def me = ReactorSim::Operations::MobileEngine
  def shovel(**opts) = MobileRig.at_work(MobileRig.build(id: :rig, seed: 1, engines: [], shovels: [ :shovel ], **opts), :shovel)
  def dipper_state(op) = MobileRig.state(op, :shovel_dipper)
  def phase(op) = op.nodes.fetch(:shovel_dipper).phase(dipper_state(op))
  def board(op) = me::Dipper::SIGNALS.keys.fetch(dipper_state(op).fetch(:signal))
  def overburden(kg) = MobileRig.parcels_at(293.15, overburden: kg)
  def phase_index(name) = me::Dipper::PHASES.index(name)

  # A dipper at a given point in its round, with the reach stocked unless said otherwise.
  def at(phase, held: 0.0, reach: 2_000.0, nodes: {}, minions: {}, op: shovel)
    MobileRig.seed(op, nodes: {
      shovel_dipper: { phase: phase_index(phase), phase_s: 0.0, parcels: overburden(held) },
      shovel_reach: { parcels: overburden(reach) }
    }.merge(nodes), minions: minions)
  end

  def tick(op, ticks = 1)
    ticks.times { |t| op.step!(tick: t + 1) }
    op
  end

  # Reads what it is told to, for the zero-tick arithmetic.
  def context(omega: 37.0, dipper: {}, controls: {})
    Struct.new(:omega, :dipper, :controls) do
      def dt = ReactorSim::DT
      def node_omega(*) = omega
      def node_state(*) = dipper
    end.new(omega, dipper, controls)
  end

  def unposted(*ids) = ids.to_h { |id| [ id, { station: nil, posting: nil } ] }

  describe "the round" do
    it "digs from the reach while the engine turns, and nothing with the engine stopped" do
      turning = tick(at(:digging))
      stopped = tick(at(:digging, nodes: { shovel_flywheel: { angular_momentum: 0.0 } }))

      expect(dipper_state(turning).fetch(:dug_kg)).to be_positive
      expect(dipper_state(stopped).fetch(:dug_kg)).to eq(0.0)
    end

    it "digs nothing with nobody at the craneman's post" do
      op = tick(at(:digging, minions: unposted(:shovel_crane_hand)))

      expect(dipper_state(op).fetch(:dug_kg)).to eq(0.0)
    end

    it "swings once full, and holds what it dug while it swings" do
      op = tick(at(:digging, held: me::YARD.fetch(:capacity_kg)))
      swung = tick(at(:swinging, held: 1_000.0), 4)

      expect(phase(op)).to be(:swinging)
      expect(MobileRig.held_kg(swung, :shovel_dipper)).to be_within(1e-6).of(1_000.0)
    end

    it "takes longer over a swing on a slower engine" do
      quick = tick(at(:swinging, held: 1_000.0))
      slow = tick(at(:swinging, held: 1_000.0, nodes: { shovel_flywheel: { angular_momentum: 400.0 } }))

      expect(dipper_state(slow).fetch(:phase_s)).to be < dipper_state(quick).fetch(:phase_s)
    end

    it "dumps into the car, and waits on cars while the car is full" do
      full = (MobileRig::CAR_M3 * 1_800.0) - 1.0
      dumping = tick(at(:dumping, held: 1_000.0))
      waiting = tick(at(:dumping, held: 1_000.0, nodes: { shovel_car: { parcels: overburden(full) } }))

      expect(MobileRig.held_kg(dumping, :shovel_car)).to be_positive
      expect(MobileRig.held_kg(waiting, :shovel_dipper)).to be > 990.0
      expect(board(waiting)).to be(:waiting_on_cars)
    end

    it "stands moving up with the reach empty and nobody to bring the face to it" do
      op = tick(at(:digging, reach: 0.0, minions: unposted(*(1..5).map { |i| :"shovel_pitman_#{i}" })))

      expect(dipper_state(op).fetch(:dug_kg)).to eq(0.0)
      expect(board(op)).to be(:moving_up)
    end

    it "is kept in reach by the pitmen" do
      op = tick(at(:digging, reach: 0.0))

      expect(MobileRig.state(op, :shovel_moving_up).fetch(:carried_kg, 0.0)).to be_positive
    end
  end

  describe "what the engine pays" do
    it "pays more for harder ground" do
      soft, hard = [ 1_000.0, 2_000.0 ].map do |work|
        op = shovel
        node = op.nodes.fetch(:shovel_dipper)
        harder = described_class.new(**node.instance_variables.to_h { |iv| [ iv.to_s.delete("@").to_sym, node.instance_variable_get(iv) ] }
                                         .slice(:capacity_kg, :fill_kg_per_s, :swing_s, :lift_m, :swing_w, :driven_by, :rated_omega,
                                                :crane_control, :demand_control, :chain, :boom, :engine, :reach, :perils)
                                         .merge(id: :d, work_j_per_kg: work))
        harder.drag_conductances({ dug_kg: 20.0, phase: 0 }, context).fetch(:friction)
      end

      expect(hard).to be > soft
    end
  end

  describe "the chain" do
    def chain(**opts)
      me::Chain.new(id: :c, dipper: :d, breaking_kn: 500.0, wear_per_s: 1.0, shows_wear: true, splice_control: :p, **opts)
    end

    it "wears only while digging, and harder the harder it is drawn" do
      light = chain.stress_per_second({}, context(dipper: { dug_kg: 10.0, tension_n: 50_000.0 }))
      heavy = chain.stress_per_second({}, context(dipper: { dug_kg: 10.0, tension_n: 150_000.0 }))
      idle = chain.stress_per_second({}, context(dipper: { dug_kg: 0.0, tension_n: 150_000.0 }))

      expect(heavy).to be > light
      expect(idle).to eq(0.0)
    end

    it "parts on a snatch past what is left of it, and not while it is sound" do
      digging = context(dipper: { dug_kg: 10.0, tension_n: 150_000.0 })

      expect(chain.overload?({}, digging, 1.0)).to be(false)
      expect(chain.overload?({}, digging, 0.4)).to be(true)
    end

    it "stops the dipper parted, and is spliced by the pitmen" do
      parted = { failure: :parted, splicing: 0.9999 }
      op = tick(at(:digging, nodes: { shovel_chain: parted }))
      idle = tick(at(:digging, nodes: { shovel_chain: parted }, minions: unposted(*(1..5).map { |i| :"shovel_pitman_#{i}" })))

      expect(dipper_state(op).fetch(:dug_kg)).to eq(0.0)
      expect(MobileRig.state(op, :shovel_chain).fetch(:failure)).to be_nil
      expect(MobileRig.state(idle, :shovel_chain).fetch(:failure)).to be(:parted)
      expect(board(idle)).to be(:splicing)
    end

    it "shows its wear if it is iron, and says nothing if it is steel" do
      worn = ->(part) {
        op = shovel(loadout: { shovel_chain: part })
        low = MobileRig.state(op, :shovel_chain).fetch(:initial_durability) * 0.3
        MobileRig.state(tick(MobileRig.seed(op, nodes: { shovel_chain: { durability: low } })), :shovel_chain).fetch(:worn)
      }

      expect(worn.(:iron_chain)).to be(true)
      expect(worn.(:steel_chain)).to be(false)
    end
  end

  describe "the boom" do
    it "tires only past its rating" do
      boom = me::Boom.new(id: :b, dipper: :d, rated_n: 200_000.0, fatigue_per_s: 2.0)

      expect(boom.stress_per_second({}, context(dipper: { tension_n: 150_000.0 }))).to eq(0.0)
      expect(boom.stress_per_second({}, context(dipper: { tension_n: 300_000.0 }))).to be_positive
    end

    it "stops the shovel down" do
      op = tick(at(:digging, nodes: { shovel_boom: { failure: :down } }))

      expect(dipper_state(op).fetch(:dug_kg)).to eq(0.0)
      expect(board(op)).to be(:boom_down)
    end
  end

  describe "the swing" do
    it "endangers the pitmen and the craneman while it swings and never while it digs" do
      node = shovel.nodes.fetch(:shovel_dipper)
      peril = node.perils.first

      expect(peril.stations).to contain_exactly(:shovel_pitmen, :shovel_craneman)
      expect(peril.opportunity).to be(true)
      expect(node.activity({ phase: phase_index(:swinging) }, :swinging, 0.25)).to eq(1.0)
      expect(node.activity({ phase: phase_index(:digging) }, :swinging, 0.25)).to be_nil
    end
  end

  describe "the driver" do
    def driver(**opts)
      me::Driver.new(boiler: :b, throttle: :t, feed: :f, working_pa: 7.0 * MobileRig::ATM, water_step: 0.02,
                     pressure_step_pa: 1_000.0, **opts)
    end

    def nodes(tank_kg: 1_000.0, omega: 37.0)
      drum = Struct.new(:p) do
        def pressure_pa(*) = p
        def effective_fill(*) = 0.55
      end.new(7.0 * MobileRig::ATM)
      tank = Struct.new(:kg) { def contents_kg(*) = kg }.new(tank_kg)
      wheel = Struct.new(:w) { def omega(*) = w }.new(omega)
      { b: drum, tank: tank, wheel: wheel }
    end

    def states = { b: {}, tank: {}, wheel: {} }

    it "calls for water with the tank low, keeps the hose open until she is full, and shuts it full" do
      hosed = driver(hose: :h, tank: :tank, tank_kg: 1_500.0)
      govern = ->(kg, open) {
        hosed.govern(commanded: 60.0, nodes: nodes(tank_kg: kg), states: states, content: nil, dt: 1.0, frozen: false,
                     held: { t: 0.0, f: 50.0, h: open }).fetch(:h)
      }

      expect(govern.(500.0, 0.0)).to eq(100.0)
      expect(govern.(1_200.0, 100.0)).to eq(100.0)
      expect(govern.(1_200.0, 0.0)).to eq(0.0)
      expect(govern.(1_499.0, 100.0)).to eq(0.0)
    end

    it "shuts her off as she races past her governed speed" do
      governed = driver(shaft: :wheel, governed_omega: 37.0)
      throttle = ->(omega) {
        governed.govern(commanded: 60.0, nodes: nodes(omega: omega), states: states, content: nil, dt: 1.0, frozen: false,
                        held: { t: 0.0, f: 50.0 }).fetch(:t)
      }

      expect(throttle.(37.0)).to eq(60.0)
      expect(throttle.(41.0)).to be_between(0.0, 60.0).exclusive
      expect(throttle.(46.0)).to eq(0.0)
    end
  end

  describe "the shovel" do
    it "says in words on the player's board what holds it up" do
      full = (MobileRig::CAR_M3 * 1_800.0) - 1.0
      op = tick(at(:dumping, held: 1_000.0, nodes: { shovel_car: { parcels: overburden(full) } }), 2)

      expect(op.project(viewer: :player).to_h.dig(:gauges, :shovel_board)).to eq("waiting on cars")
    end

    it "balances mass and energy through a round of work" do
      op = at(:digging)
      op.set_control(:shovel_unload, 100.0)
      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      tick(op, 20)

      expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass).abs / mass.abs).to be < Conservation::TOLERANCE
      expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules).abs / joules.abs).to be < Conservation::TOLERANCE
    end

    it "replays bit for bit through a snapshot taken mid-round" do
      straight = tick(at(:swinging, held: 1_000.0), 12)
      paused = tick(at(:swinging, held: 1_000.0), 6)
      resumed = MobileRig.seed(paused)
      6.times { |t| resumed.step!(tick: t + 7) }

      expect(ReactorSim.canonical(resumed.state)).to eq(ReactorSim.canonical(straight.state))
    end
  end
end
