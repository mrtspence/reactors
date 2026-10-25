# frozen_string_literal: true

require "support/mobile_rig"
require "support/conservation"

# **A mobile engine: the stationary engine's pieces, a tenth the size, worked by its own two
# people.** On the rig, from the state one was observed at work in. All relational — no figure here
# is a tuning target.
RSpec.describe ReactorSim::Operations::MobileEngine do
  def me = described_class
  def rig(**opts) = MobileRig.build(id: :rig, seed: 1, **opts)
  def at_work(op = rig, **opts) = MobileRig.at_work(op, **opts)

  def run(op, ticks, from: 0)
    ticks.times { |t| op.step!(tick: from + t + 1) }
    op
  end

  def work_joules(op) = op.ledger.fetch(:joules_to_work)

  def driver(water_step: 0.02, pressure_step_pa: 1_000.0)
    me::Driver.new(boiler: :b, throttle: :t, feed: :f, working_pa: 7.0 * MobileRig::ATM,
                   water_step: water_step, pressure_step_pa: pressure_step_pa)
  end

  # A drum that reads what it is told to, for the driver to govern from.
  def drum(pressure_atm:, fill:)
    Struct.new(:pressure, :level) do
      def pressure_pa(*) = pressure
      def effective_fill(*) = level
    end.new(pressure_atm * MobileRig::ATM, fill)
  end

  def govern(driver, drum, commanded: 60.0, feed: 50.0, frozen: false)
    driver.govern(commanded: commanded, nodes: { b: drum }, states: { b: {} }, content: nil, dt: 1.0,
                  frozen: frozen, held: { t: 0.0, f: feed })
  end

  describe "names" do
    it "builds every piece of a second engine under its own name, sharing only the air" do
      op = rig(engines: %i[shovel_1 shovel_2])
      ids = op.nodes.keys - %i[atmosphere]

      expect(ids.count { |id| id.start_with?("shovel_1_") }).to eq(ids.count { |id| id.start_with?("shovel_2_") })
      expect(ids.reject { |id| id.start_with?("shovel_1_", "shovel_2_") }).to be_empty
      expect(op.nodes.fetch(:shovel_2_relief).senses).to be(:shovel_2_boiler)
      expect(op.nodes.fetch(:shovel_2_boiler).fired_by).to be(:shovel_2_firebox)
    end

    it "leaves one engine's work untouched by what the other is asked" do
      engines = %i[a b]
      a = rig(engines: engines)
      b = rig(engines: engines)
      [ a, b ].each { |op| engines.each { |e| op.set_control(:"#{e}_driving", 60.0) } }
      b.set_control(:b_driving, 0.0)
      [ a, b ].each { |op| run(op, 8) }

      expect(ReactorSim.canonical(a.state.dig(:nodes, :a_flywheel))).to eq(ReactorSim.canonical(b.state.dig(:nodes, :a_flywheel)))
      expect(b.state.dig(:controls, :b_throttle_open, :actual)).to eq(0.0)
    end
  end

  describe "at work" do
    it "carries on from the seeded state with no transient" do
      op = at_work
      pressure = MobileRig.pressure_atm(op)
      omega = MobileRig.omega(op)
      run(op, 20)

      expect(MobileRig.pressure_atm(op)).to be_within(0.03 * pressure).of(pressure)
      expect(MobileRig.omega(op)).to be_within(0.03 * omega).of(omega)
    end

    it "makes more work asked for more" do
      hard = run(at_work(demand: 100.0), 20)
      easy = run(at_work(demand: 30.0), 20)

      expect(work_joules(hard)).to be > work_joules(easy)
    end

    it "lands no coal on the grate with the bunker empty, where a full one feeds it" do
      fed = at_work
      starved = MobileRig.seed(fed, nodes: { engine_bunker: { parcels: [] } })
      [ fed, starved ].each { |op| op.step!(tick: 1) }
      carried = ->(op) { MobileRig.state(op, :engine_stoker).fetch(:carried_kg, 0.0) }

      expect(carried.(fed)).to be_positive
      expect(carried.(starved)).to eq(0.0)
    end

    it "loses water from the drum with the tank empty, where a full tank keeps it" do
      wet = at_work
      dry = MobileRig.seed(wet, nodes: { engine_supply: { parcels: [] } })
      [ wet, dry ].each { |op| op.set_control(:engine_driving, 100.0) }
      water = ->(op) { MobileRig.state(op, :engine_boiler).fetch(:parcels).select { |p| p[:resource] == :water }.sum { |p| p[:kg] } }
      start = water.(wet)
      [ wet, dry ].each { |op| run(op, 20) }

      expect(water.(dry)).to be < start
      expect(water.(dry)).to be < water.(wet)
    end

    it "balances mass and energy through a working spell" do
      op = at_work
      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      run(op, 20)

      expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass).abs / mass.abs).to be < Conservation::TOLERANCE
      expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules).abs / joules.abs).to be < Conservation::TOLERANCE
    end
  end

  describe "the driver" do
    it "opens the throttle to what he is asked, eases it as she falls off, and shuts it asked for nothing" do
      full = govern(driver, drum(pressure_atm: 7.0, fill: 0.55))
      falling = govern(driver, drum(pressure_atm: 4.5, fill: 0.55))
      idle = govern(driver, drum(pressure_atm: 7.0, fill: 0.55), commanded: 0.0)

      expect(full.fetch(:t)).to eq(60.0)
      expect(falling.fetch(:t)).to be_between(0.0, 60.0).exclusive
      expect(idle.fetch(:t)).to eq(0.0)
    end

    it "feeds a low water and holds off a high one" do
      expect(govern(driver, drum(pressure_atm: 7.0, fill: 0.4)).fetch(:f)).to be > 50.0
      expect(govern(driver, drum(pressure_atm: 7.0, fill: 0.7)).fetch(:f)).to be < 50.0
    end

    # **Try-cocks are a coarser instrument, and a coarse reading is a wrong-way move**: a water just
    # under the mark reads as over it to a man with taps at fifths, so he holds off when a man at a
    # glass would feed.
    it "reads the water coarsely through try-cocks and nearly true through a glass" do
      just_low = drum(pressure_atm: 7.0, fill: 0.52)

      expect(govern(driver(water_step: 0.02), just_low).fetch(:f)).to be > 50.0
      expect(govern(driver(water_step: 0.2), just_low).fetch(:f)).to be < 50.0
    end

    it "does nothing while frozen at his post" do
      expect(govern(driver, drum(pressure_atm: 3.0, fill: 0.2), frozen: true)).to eq(t: 0.0, f: 50.0)
    end

    it "reads by what the loadout fitted" do
      op = rig(loadout: { engine_water_reading: :mobile_gauge_glass, engine_pressure_reading: :mobile_pressure_gauge })
      bare = rig(loadout: { engine_water_reading: nil })

      expect(op.control_points.fetch(:engine_driving).governor.instance_variable_get(:@water_step)).to be < 0.2
      expect(bare.control_points.fetch(:engine_driving).governor.instance_variable_get(:@water_step))
        .to eq(me::BLIND_WATER_STEP)
    end
  end

  describe "the blueprint" do
    it "holds the levers nobody works at what the parts say, off the panel and out of the player's reach" do
      op = rig

      expect(op.control_points.fetch(:engine_damper_open)).to be_internal
      expect(MobileRig.lever(op, :engine_damper_open)).to eq(me::VERTICAL.fetch(:damper_open))
      expect(op.set_control(:engine_damper_open, 10.0)).to be(false)
      expect(op.set_control(:engine_driving, 10.0)).to be(true)
    end

    it "fits a spring valve that is wide open closer to its setting than a dead weight" do
      reading = Struct.new(:pa) do
        def node_reading(*) = pa
        def controls = {}
      end.new(8.2 * MobileRig::ATM)
      lift = ->(part) { rig(loadout: { engine_safety_valve: part }).nodes.fetch(:engine_relief).lift(reading) }

      expect(lift.(:spring_safety_valve)).to be > lift.(:dead_weight_valve)
    end

    it "puts a fitted plug between this engine's own drum and its own fire" do
      op = rig(engines: %i[a b], loadout: { b_fusible_plug: :mobile_fusible_plug })

      expect(op.nodes.fetch(:b_fusible_plug).senses).to be(:b_boiler)
      expect(op.links.map { |l| [ l.from_node, l.to_node ] }).to include([ :b_fusible_plug, :b_firebox ])
      expect(op.nodes).not_to have_key(:a_fusible_plug)
    end
  end
end
