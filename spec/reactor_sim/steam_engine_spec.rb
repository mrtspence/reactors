# frozen_string_literal: true

require "reactor_sim"

# The first real operation, and the one the architecture was tested against.
#
# `docs/design_sketches/boiler.md` set the bar: *if an atmospheric engine and a
# high-pressure engine can be the same operation with different parts swapped in, the
# abstractions are the right ones.* The thesis group at the bottom is that test.
RSpec.describe "the steam engine" do
  # Starting from cold and lighting the fire takes real time, so most examples share one
  # warmed-up engine rather than paying for the startup in every one.
  def engine(variant: :high_pressure, seed: 42)
    ReactorSim::Match
      .create(id: "e", seed: seed, operations: [ { id: "eng", type: :steam_engine, variant: variant } ])
      .operation(:eng)
  end

  # Light it, get the fire going, then open up. This is the actual operating procedure,
  # not a test convenience — a cold engine cannot simply be switched on.
  def light_and_run(op, throttle: 60, stoking: 60, load: 80, ticks: 1600)
    { igniter: 100, damper_open: 85, stoking: 70, feed: 45,
      throttle_open: 0, load_demand: 0 }.each { |k, v| op.set_control(k, v) }

    events = []
    (1..ticks).each do |t|
      if t == 400
        op.set_control(:igniter, 0)
        op.set_control(:throttle_open, throttle)
        op.set_control(:stoking, stoking)
      end
      op.set_control(:load_demand, load) if t == 700
      events.concat(op.step!(tick: t))
    end
    events
  end

  def rpm(op) = op.nodes.fetch(:flywheel).rpm(op.state.fetch(:nodes).fetch(:flywheel))
  def truth(op, gauge) = op.project(viewer: :spectator).gauges.fetch(gauge)

  describe "combustion" do
    it "will not light a cold firebox without the igniter" do
      op = engine
      { damper_open: 85, stoking: 70, igniter: 0 }.each { |k, v| op.set_control(k, v) }
      400.times { |i| op.step!(tick: i + 1) }

      expect(truth(op, :fire_state)).to eq("cold")
    end

    it "catches once the igniter has brought the firebox up, and keeps burning without it" do
      op = engine
      light_and_run(op, ticks: 900)

      expect(truth(op, :firebox_temp)).to be > 300 # °C at the gauge, not K
      expect(truth(op, :fire_state)).not_to eq("cold")
    end

    # Air starvation needs no special case — the reaction is limited by whichever reagent
    # runs out first, so shutting the damper chokes the fire through the same code path an
    # empty bunker would.
    it "chokes when the damper is shut" do
      open_fire = engine.tap { |o| light_and_run(o, ticks: 900) }
      shut = engine.tap do |o|
        light_and_run(o, ticks: 500)
        o.set_control(:damper_open, 0)
        400.times { |i| o.step!(tick: 500 + i) }
      end

      expect(truth(shut, :firebox_temp)).to be < truth(open_fire, :firebox_temp)
    end

    it "burns fuel and leaves ash behind" do
      op = engine
      light_and_run(op, ticks: 900)
      firebox = op.state.fetch(:nodes).fetch(:firebox).fetch(:parcels)

      expect(firebox.find { |p| p.fetch(:resource) == :ash }).not_to be_nil
      expect(op.telemetry.fetch(:bunker)[:kg]).to be < 12_000.0
    end
  end

  describe "running" do
    # No special case makes this happen: the cylinder fills, its pressure rises, and the
    # torque that results is what turns the wheel. Torque is computed from pressure rather
    # than from power precisely so that a stopped engine can start.
    it "starts itself once there is steam and the throttle is open" do
      op = engine
      light_and_run(op)

      expect(rpm(op)).to be > 10.0
    end

    it "makes real power" do
      op = engine
      light_and_run(op)

      expect(op.state.fetch(:nodes).fetch(:cylinder).fetch(:indicated_power_w)).to be > 5_000.0
    end

    it "runs faster with the throttle further open" do
      slow = engine.tap { |o| light_and_run(o, throttle: 40, stoking: 50) }
      fast = engine.tap { |o| light_and_run(o, throttle: 80, stoking: 70) }

      expect(rpm(fast)).to be > rpm(slow)
    end

    it "converts the fire's heat into shaft work on the ledger" do
      op = engine
      light_and_run(op)

      expect(op.ledger.fetch(:joules_added)).to be > 0.0
      expect(op.ledger.fetch(:joules_to_work)).to be > 0.0
    end
  end

  describe "failure modes" do
    # The headline one. Shed the load and everything the boiler is pouring in goes into
    # acceleration, with only the wheel's tensile limit in the way.
    it "bursts the flywheel when driven far past its limit" do
      op = engine
      events = light_and_run(op, throttle: 100, stoking: 80, load: 100, ticks: 2000)

      expect(events.map { |e| e[:type] }).to include(:flywheel_burst)
    end

    it "reports how fast it was going when it let go" do
      op = engine
      events = light_and_run(op, throttle: 100, stoking: 80, load: 100, ticks: 2000)
      burst = events.find { |e| e[:type] == :flywheel_burst }

      expect(burst.fetch(:cause)).to eq(:overload)
      expect(burst.dig(:detail, :rpm)).to be > 100.0
    end

    it "survives a moderate hand on the controls" do
      op = engine
      events = light_and_run(op, throttle: 60, stoking: 60, load: 80, ticks: 2000)

      expect(events).to be_empty
      expect(rpm(op)).to be > 10.0
    end

    # Papin fitted one of these in 1679, and for good reason: a fire does not know how much
    # steam the engine wants.
    it "lifts the safety valve rather than bursting the boiler" do
      op = engine
      light_and_run(op, throttle: 0, stoking: 80, load: 0, ticks: 2000)

      relief = op.telemetry.fetch(:relief)
      expect(relief[:kg]).to be > 0.0, "the valve never lifted"
      expect(op.state.fetch(:nodes).fetch(:boiler).fetch(:broken)).to be(false)
    end
  end

  describe "conservation" do
    it "balances mass and energy through combustion, boiling and shaft work" do
      op = engine
      before_mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      before_joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

      light_and_run(op, ticks: 1200)

      after_mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      after_joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

      expect((after_mass - before_mass).abs / before_mass.abs).to be < 1e-9
      expect((after_joules - before_joules).abs / before_joules.abs).to be < 1e-9
    end
  end

  # The reason this operation was built.
  describe "the architectural thesis" do
    it "builds both engines from the same parts" do
      shared = %i[atmosphere bunker stoker damper firebox flue supply feed_pump
                  boiler relief throttle cylinder flywheel load]

      %i[high_pressure atmospheric].each do |variant|
        expect(engine(variant: variant).nodes.keys).to include(*shared)
      end
    end

    # One line in the operation definition decides which engine this is.
    it "differs only in what the cylinder exhausts into" do
      expect(engine(variant: :high_pressure).nodes.fetch(:cylinder).exhausts_to).to eq(:atmosphere)
      expect(engine(variant: :atmospheric).nodes.fetch(:cylinder).exhausts_to).to eq(:condenser)
    end

    it "gives the atmospheric engine a condenser and the high-pressure engine none" do
      expect(engine(variant: :atmospheric).nodes).to have_key(:condenser)
      expect(engine(variant: :high_pressure).nodes).not_to have_key(:condenser)
    end

    # The real payoff. Watt's engine makes power from a vacuum with a boiler barely above
    # atmospheric; Trevithick's throws the condenser away and pushes with boiler pressure.
    # Same Cylinder class, same torque formula, different graph.
    it "runs an atmospheric engine on a boiler pressure the high-pressure engine could not use" do
      watt = engine(variant: :atmospheric)
      light_and_run(watt, throttle: 70, stoking: 60, load: 60, ticks: 1600)

      boiler_pa = watt.nodes.fetch(:boiler).pressure_pa(
        watt.state.fetch(:nodes).fetch(:boiler), watt.content
      )

      expect(rpm(watt)).to be > 5.0, "the atmospheric engine never turned"
      expect(boiler_pa).to be < 2.5 * ReactorSim::Units::STANDARD_PRESSURE_PA
    end

    it "gives the atmospheric engine a condenser vacuum below atmospheric" do
      watt = engine(variant: :atmospheric)
      light_and_run(watt, throttle: 70, stoking: 60, load: 60, ticks: 1600)

      vacuum = watt.nodes.fetch(:condenser).pressure_pa(
        watt.state.fetch(:nodes).fetch(:condenser), watt.content
      )

      expect(vacuum).to be < ReactorSim::Units::STANDARD_PRESSURE_PA
    end

    # The closed water loop — condenser to hotwell to feed — is exactly the topology a
    # topological resolution order could not have handled.
    it "closes the water loop on the atmospheric engine" do
      watt = engine(variant: :atmospheric)

      expect(watt.links.map(&:id)).to include(:"hotwell.outlet->supply.in")
    end
  end

  describe "snapshots" do
    # The variant is builder configuration, not state. Without persisting it, an
    # atmospheric engine would restore as a high-pressure one — a total, silent divergence.
    it "restores an atmospheric engine as an atmospheric engine" do
      watt = engine(variant: :atmospheric)
      light_and_run(watt, ticks: 500)

      restored = ReactorSim::Operation.from_h(
        ReactorSim.deep_symbolize(JSON.parse(JSON.generate(watt.to_h)))
      )

      expect(restored.nodes).to have_key(:condenser)
      expect(ReactorSim.canonical(restored.to_h)).to eq(ReactorSim.canonical(watt.to_h))
    end
  end

  # The crew is wired up but deliberately inert: every lever here is frictionless, so the
  # rate multiplier a minion contributes is discarded before it is used. That is what let a
  # crew be added without re-measuring the skill gradient — and it is also why the seam
  # itself is proved in minion_spec, on a rig with a stiff lever, rather than here.
  describe "the crew" do
    it "posts everyone to a lever that exists" do
      op = engine
      stations = op.state.fetch(:minions).values.filter_map { |m| m.fetch(:station) }

      expect(stations).to all(satisfy { |s| op.control_points.key?(s) })
      expect(stations).not_to be_empty
    end

    # Pins the inertness deliberately, so that giving a work station a finite stiffness shows
    # up here as a failing expectation rather than as a quietly shifted skill gradient.
    it "leaves a manned lever frictionless, so the minion cannot yet slow it down" do
      op = engine
      op.set_control(:stoking, 100.0)
      op.step!(tick: 1)
      lever = op.state.fetch(:controls).fetch(:stoking)

      expect(op.state.fetch(:minions).fetch(:fireman).fetch(:station)).to eq(:stoking)
      expect(lever.fetch(:actual)).to eq(lever.fetch(:target))
    end
  end
end
