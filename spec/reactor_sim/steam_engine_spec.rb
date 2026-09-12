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
  #
  # The **blower** is new and it is not optional. Draught is real now: a cold stack has no
  # buoyancy and the blastpipe cannot help until the engine is already turning, so nothing
  # would raise the first steam without forced draught. It comes off once the engine is
  # running and the exhaust takes over — which is exactly the handover a fireman performs.
  #
  # That handover is also why this takes ~3600 ticks where it used to take 1600: raising steam
  # from cold on a blower is genuinely slower than it was when the flue simply hauled gas out
  # regardless of pressure. It is the single biggest cost in the suite.
  LIGHT = { igniter: 100, blower: 100, damper_open: 85, stoking: 70, feed: 45,
            throttle_open: 0, load_demand: 0 }.freeze

  # `shed_at:` throws the mill off the belt partway through — the one thing that genuinely
  # destroys this engine. See the failure-mode group for why that is the hazard rather than
  # simply opening the regulator.
  # `damper:` overrides `LIGHT`'s 85 for the whole run. It exists because **85 puts the boiler on
  # its safety valve**, and a saturated boiler reports every upstream change as zero — see the
  # ashpan example below.
  # `each_tick:` is called after every step with the tick number. It exists because some
  # behaviour is a **transient** — the warm-through condensate clears the moment the engine is
  # turning properly — and an end-state assertion would pass on a startup that had been knocking
  # badly the whole way up.
  def light_and_run(op, throttle: 60, stoking: 60, load: 80, ticks: 3600, blower_off: 1600,
                    shed_at: nil, damper: nil, each_tick: nil)
    LIGHT.each { |k, v| op.set_control(k, v) }
    op.set_control(:damper_open, damper) if damper

    events = []
    (1..ticks).each do |t|
      op.set_control(:igniter, 0) if t == 300
      # **The mill goes on the belt before the regulator opens, and the order is the point.**
      # It used to be the other way round, which was safe only because the mill was a
      # constant-torque brake. Against a fan-law load, running at open throttle with nothing
      # engaged is the single most dangerous thing a driver can do — every configuration that
      # made more steam burst the wheel inside that window, which is exactly right and is now
      # a procedure a player has to know rather than an accident of the test.
      op.set_control(:load_demand, load) if t == 1150
      if t == 1200
        op.set_control(:throttle_open, throttle)
        op.set_control(:stoking, stoking)
      end
      op.set_control(:blower, 0) if t == blower_off
      op.set_control(:load_demand, 0) if shed_at && t == shed_at
      events.concat(op.step!(tick: t))
      each_tick&.call(t)
    end
    events
  end

  def rpm(op) = op.nodes.fetch(:flywheel).rpm(op.state.fetch(:nodes).fetch(:flywheel))

  # What the crank was measurably given, not what the indicator diagram claimed. The two
  # diverge whenever the regulator is the restriction — see the note on `engine_power` in
  # `panel.rb`.
  def shaft_power(op) = op.state.fetch(:nodes).fetch(:cylinder).fetch(:shaft_power_w, 0.0)

  def pressure_of(op, node)
    op.nodes.fetch(node).pressure_pa(op.state.fetch(:nodes).fetch(node), op.content)
  end

  # How far the regulator has throttled the steam below the boiler that raised it.
  def chest_drop(op) = pressure_of(op, :boiler) - pressure_of(op, :steam_chest)

  def contents(op, node, resource)
    op.state.fetch(:nodes).fetch(node).fetch(:parcels, [])
      .select { |p| p.fetch(:resource).to_sym == resource }.sum { |p| p.fetch(:kg) }
  end
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
      light_and_run(op, ticks: 1900)

      expect(truth(op, :firebox_temp)).to be > 300 # °C at the gauge, not K
      expect(truth(op, :fire_state)).not_to eq("cold")
    end

    # Air starvation needs no special case — the reaction is limited by whichever reagent
    # runs out first, so shutting the damper chokes the fire through the same code path an
    # empty bunker would.
    it "chokes when the damper is shut" do
      open_fire = engine.tap { |o| light_and_run(o, ticks: 1900) }
      shut = engine.tap do |o|
        light_and_run(o, ticks: 500)
        o.set_control(:damper_open, 0)
        400.times { |i| o.step!(tick: 500 + i) }
      end

      expect(truth(shut, :firebox_temp)).to be < truth(open_fire, :firebox_temp)
    end

    it "burns fuel and leaves ash behind" do
      op = engine
      light_and_run(op, ticks: 1900)
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

    # **Moves one lever, and it has to.** This used to open the throttle from 40 to 80 and raise
    # the stoking from 50 to 70 in the same breath, which made it a test of two levers whose
    # effects turned out to point in opposite directions — it passed on the balance between
    # them rather than on either one.
    #
    # Isolated, the throttle is clean and monotone (40 → 161.1 rpm / 322 kW, 80 → 167.8 rpm /
    # 358 kW). Isolated, **stoking is inverted at these settings**: 50 → 169.5 rpm / 368 kW
    # against 70 → 161.5 rpm / 325 kW, because at a fixed damper the fire is air-limited and the
    # extra coal does not burn — it sits in the firebox absorbing heat, taking it from 966 K to
    # 938 K and the boiler from 537 to 501 kPa. Smothering a fire by over-stoking it is real,
    # and whether the optimum belongs below 70 at damper 85 is a **balance question that has not
    # been answered yet**; see `current_progress.md`.
    it "runs faster with the throttle further open" do
      slow = engine.tap { |o| light_and_run(o, throttle: 40, stoking: 60) }
      fast = engine.tap { |o| light_and_run(o, throttle: 80, stoking: 60) }

      expect(rpm(fast)).to be > rpm(slow)
    end

    # Speed is a poor instrument for this, and the load curve is why: a fan law absorbs power as
    # ω³, so a large power range shows up as a small speed range. That is the mill doing exactly
    # what it was given a torque curve to do — holding the engine near its duty point — so the
    # quantity that actually answers "is the regulator working" is the power it lets through.
    #
    # Measured at nominal after equal-percentage trim landed: **124.4 → 296.1 kW from throttle 20
    # to 100**, which is 112.5 → 155.9 rpm. On linear trim the same span was 217.4 → 296.1 kW,
    # and the top 70% of the lever carried 21% of it — see `Conduit#open_fraction`.
    it "makes more power with the throttle further open" do
      slow = engine.tap { |o| light_and_run(o, throttle: 40, stoking: 60) }
      fast = engine.tap { |o| light_and_run(o, throttle: 80, stoking: 60) }

      expect(shaft_power(fast)).to be > shaft_power(slow) * 1.05
    end

    # **The regulator is a restriction, not a ration**, and this is the difference. The throttle
    # is a conductance, so flow through it costs a pressure drop that grows with the flow, and
    # the steam chest behind it sits below the boiler by an amount the driver controls. That gap
    # IS the wire-drawing, and it is what the panel's chest gauge is for.
    #
    # Before the chest existed the regulator could not affect torque at all — it rationed how
    # much steam arrived but not the pressure it arrived at — and the `extractable_joules` bound
    # in `Tick#transmit_torque` silently became the throttling mechanism, discarding 30–50% of
    # the declared work. A conservation clamp is not a mechanism.
    it "wire-draws: closing the regulator drops the steam chest further below the boiler" do
      open = engine.tap { |o| light_and_run(o, throttle: 100, stoking: 60) }
      shut = engine.tap { |o| light_and_run(o, throttle: 20, stoking: 60) }

      expect(chest_drop(shut)).to be > chest_drop(open) * 1.3
    end

    it "converts the fire's heat into shaft work on the ledger" do
      op = engine
      light_and_run(op)

      expect(op.ledger.fetch(:joules_added)).to be > 0.0
      expect(op.ledger.fetch(:joules_to_work)).to be > 0.0
    end
  end

  describe "the grate silts up" do
    def ash(op) = contents(op, :firebox, :ash)

    # Ash is produced by both combustion reactions and consumed by nothing. Before `Obstructs`
    # it accumulated forever and did nothing at all but add thermal mass — 10.8 kg in normal
    # running, which is 0.26% of six cubic metres and therefore invisible against the vessel's
    # own volume. Measured against the **void between the fuel** it is the fire's own waste
    # filling the gaps the air has to come through, which is what banking a grate actually does.
    it "chokes the fire slowly as its own waste banks up" do
      op = engine
      light_and_run(op, ticks: 7200)

      expect(ash(op)).to be > 15.0
      expect(op.nodes.fetch(:firebox)
               .reaction_throttle(op.state.fetch(:nodes).fetch(:firebox), op.content)).to be < 0.97
    end

    # **The remedy is not optional chrome.** Without a way out the choke is a slow dead end and
    # no lever a player can reach will help, which is a worse game than not modelling it at all.
    #
    # **`damper: 60`, and the reason is the whole point of this comment.** At `LIGHT`'s damper 85
    # the drum holds 608.0 kPa against a 607.95 kPa relief setting — it is feathering its safety
    # valve continuously — so a slightly choked fire changes the power not at all, because the
    # surplus was going over the roof anyway. Measured across the damper, raked against banked:
    #
    #     damper 60   397.3 vs 380.4 kW   off the valve   <- here
    #     damper 70   400.8 vs 401.9 kW   on the valve
    #     damper 78   402.0 vs 401.8 kW   on the valve
    #     damper 85   401.7 vs 402.7 kW   on the valve
    #
    # `reaction_throttle` falls to 0.954-0.966 in **every** one of those, so the choke happens
    # regardless; only its consequence is masked. This example used to pass at damper 85 purely
    # because the fire was oversized enough to be choked and still saturate, and it began failing
    # by 0.23% — noise, not a reversal — when the stoker was re-rated to match what the fire can
    # actually burn. **A saturated system reports every upstream change as zero**, which is
    # indistinguishable from a mechanic that does not work. Assert against a state the quantity
    # can actually move.
    it "clears when the ashpan is raked, and the engine gets the power back" do
      raked = engine.tap { |o| o.set_control(:ash_raking, 40); light_and_run(o, ticks: 7200, damper: 60) }
      banked = engine.tap { |o| light_and_run(o, ticks: 7200, damper: 60) }

      expect(ash(raked)).to be < 0.5
      expect(ash(banked)).to be > 15.0
      expect(shaft_power(raked)).to be > shaft_power(banked)
    end
  end

  describe "water in the cylinder" do
    # **Warming through is a procedure now, and these two examples are the whole of why the
    # drain cocks exist.** A cold cylinder condenses a great deal of what is admitted to it, so
    # the driver's job is: cocks open, crack the regulator, let it blow through, shut the cocks
    # once it is hot. That was impossible to demonstrate until the cylinder was given the thermal
    # mass its casting actually has — at `heat_capacity: 6.0e4` the metal warmed from ambient to
    # steam temperature in about a dozen ticks and peak occupancy over a whole startup was 0.188.
    #
    # Assert the **peak**, not the end state: the water is swept out as soon as the engine is
    # turning properly (it ends at 0.004 either way), so an end-state assertion would pass on a
    # startup that had been knocking badly the whole way up.
    def peak_occupancy(op, ticks:, cocks:, shut_at: nil)
      op.set_control(:cylinder_cocks, cocks)
      peak = 0.0
      watch = lambda do |t|
        op.set_control(:cylinder_cocks, 0) if shut_at && t == shut_at
        peak = [ peak, op.nodes.fetch(:cylinder)
                        .occupancy(op.state.fetch(:nodes).fetch(:cylinder), op.content) ].max
      end
      light_and_run(op, ticks: ticks, each_tick: watch)
      peak
    end

    it "fills with its own condensate if the cocks are left shut through warming through" do
      op = engine
      peak = peak_occupancy(op, ticks: 2600, cocks: 0)

      # 0.859 measured — past the 0.85 band, so the gauge is calling it "knocking badly" and the
      # cylinder relief valve is lifting. A real scare, and recoverable: no damage, and it
      # clears once the engine is away.
      expect(peak).to be > 0.5
      expect(op.nodes.fetch(:cylinder).integrity(op.state.fetch(:nodes).fetch(:cylinder))).to eq(1.0)
    end

    it "stays dry through the same startup if they are opened and then shut" do
      op = engine
      peak = peak_occupancy(op, ticks: 2600, cocks: 100, shut_at: 1600)

      expect(peak).to be < 0.1
    end

    # The cylinder condenses its own charge — genuine expansion cooling, and the reason a
    # saturated engine loses so much steam to its walls. While the engine turns, the exhaust
    # stroke sweeps it out; the hazard belongs to standing, not to running.
    it "stays far away from hydraulic lock in normal running" do
      %i[high_pressure atmospheric].each do |variant|
        op = engine(variant: variant)
        light_and_run(op, ticks: 4800)

        expect(op.nodes.fetch(:cylinder)
                 .occupancy(op.state.fetch(:nodes).fetch(:cylinder), op.content)).to be < 0.1
      end
    end

    # **A relief valve pointed at the wrong quantity is worse than none**, because it looks like
    # protection. This one senses the pressure at top dead centre, which is what actually
    # destroys a cylinder, and it must cost nothing while the engine is working properly.
    it "leaves the cylinder relief valve shut throughout an ordinary run" do
      op = engine
      light_and_run(op)

      node = op.nodes.fetch(:cylinder)
      state = op.state.fetch(:nodes).fetch(:cylinder)
      expect(node.compression_pressure_pa(state, op.content))
        .to be < op.nodes.fetch(:cylinder_relief).relief_pressure_pa
    end
  end

  # **Priming, end to end, and the failure this engine exists to be able to suffer.**
  #
  # A full glass is safe until you pull on it. Open the regulator sharply and the drum's pressure
  # falls, its water flashes, the level swells past the steam offtake, and what goes down the pipe
  # is water — which the piston then swallows *by volume*, because that is what a
  # positive-displacement machine does. The clearance holds 14 kg and it takes far more than that.
  #
  # Every step of that chain was missing or wrong until 2026-09-09; the run below reached
  # **56.6 kg in the cylinder and occupancy 4.06**. Design and the corrections:
  # `docs/design_sketches/obstruction.md`.
  describe "priming and hydraulic lock" do
    # Fast and lean first, then flood the glass while it is still running hard, then slam the
    # regulator wide. The ORDER is the mechanic — a high level reached slowly while the engine
    # idles is not the same predicament at all.
    def prime_and_slam(op, cocks: 0, flood_at: 2000, slam_at: 4500, ticks: 6200)
      LIGHT.each { |k, v| op.set_control(k, v) }
      op.set_control(:feed, 40)
      op.set_control(:cylinder_cocks, cocks)

      events = []
      peak = 0.0
      (1..ticks).each do |t|
        op.set_control(:igniter, 0) if t == 300
        op.set_control(:load_demand, 80) if t == 1150
        op.set_control(:throttle_open, 60) if t == 1200
        op.set_control(:blower, 0) if t == 1600
        op.set_control(:feed, 100) if t == flood_at
        op.set_control(:throttle_open, 100) if t == slam_at
        events.concat(op.step!(tick: t))
        peak = [ peak, occupancy(op) ].max
      end
      [ events, peak ]
    end

    def occupancy(op)
      op.nodes.fetch(:cylinder).occupancy(op.state.fetch(:nodes).fetch(:cylinder), op.content)
    end

    # **Assert the peak, not the end state.** A broken cylinder declares `Intent.none` and stops
    # drawing, so what it still holds when the run ends says nothing about how full it got — this
    # read 0.21 on a run whose cylinder had been at 4.06 and was already destroyed.
    # **Pending because the demonstration this asserted was withdrawn, not because it is flaky.**
    #
    # It passed against a boiler whose swell saturated on a single-tick pressure spike — see the
    # smoothing traps in `current_progress.md`. With an honest signal the same run peaks at
    # wetness 0.509 and occupancy 0.163, and the cylinder survives.
    #
    # The *mechanism* is proven in `obstruction_spec`: a flooded chest makes the intake ask for
    # 50× more, matching swept volume × supply bulk density, enough to fill the clearance inside
    # twenty ticks. What is unproven is that the engine has a **reachable operating point** where
    # the boiler is wet enough and the crank still turning — every way of raising the glass runs
    # the feed pump, whose 293 K water puts the fire out, and a dead fire makes no pressure
    # transient to swell on. Un-pend this after the balance pass decides that, and do not "fix"
    # it by making the swell signal twitchy again.
    it "destroys the cylinder when a full boiler is opened up at speed" do
      pending("no reachable operating point yet: filling the boiler kills the fire — see " \
              "current_progress.md, the feedwater preheat row")
      op = engine
      events, peak = prime_and_slam(op)

      expect(events.map { |e| e[:type] }).to include(:cylinder_failure)
      expect(peak).to be > 1.0
      expect(op.state.fetch(:nodes).fetch(:cylinder).fetch(:broken)).to be true
    end

    # **The remedy acts on the cylinder, not on the boiler**, and that is the point of it: the
    # drum primes exactly as hard either way — same level, same swell, same wetness reaching the
    # chest — and the engine survives only because the water has somewhere to go.
    it "survives the same run with the cylinder cocks open" do
      op = engine
      events, peak = prime_and_slam(op, cocks: 100)

      expect(events.map { |e| e[:type] }).not_to include(:cylinder_failure)
      expect(peak).to be < 0.5
    end

    # Swell is driven by the *rate* the pressure falls, so steady running of any intensity costs
    # nothing. Without this the mechanic is just a worse baseline: the first attempt scaled it by
    # offtake and put a hard-pulling engine at a safe level into permanent carryover.
    it "leaves an engine held at a steady throttle dry, however hard it is working" do
      op = engine
      light_and_run(op, throttle: 100, ticks: 4800)

      boiler = op.nodes.fetch(:boiler)
      expect(boiler.swell_fraction(op.state.fetch(:nodes).fetch(:boiler))).to be < 0.05
      expect(occupancy(op)).to be < 0.1
    end
  end

  describe "failure modes" do
    # The headline one, and **it is shedding the load, not opening the regulator.**
    #
    # That is a change of scenario, not of assertion, and it is worth saying why. The mill was
    # a constant-torque brake, which has no stable intersection with the cylinder's torque
    # curve — so the way to hurt the engine was to open up *against* full load, and demand 100
    # was the most dangerous setting on the panel. It is a fan-law load now, so the mill holds
    # the engine at its duty point and full demand is the *safe* setting; what kills it is
    # taking the load away, which is how real machinery has always destroyed itself.
    #
    # Measured: steady at 116.9 rpm on 76.8 kW, the mill comes off, and fifteen seconds later
    # the wheel is through 265 rpm and lets go at 311.7 against a limit of 321.6.
    it "bursts the flywheel when the load is thrown off" do
      op = engine
      events = light_and_run(op, throttle: 100, stoking: 80, load: 90, ticks: 4200,
                             shed_at: 3400)

      expect(events.map { |e| e[:type] }).to include(:flywheel_burst)
    end

    it "reports how fast it was going when it let go" do
      op = engine
      events = light_and_run(op, throttle: 100, stoking: 80, load: 90, ticks: 4200,
                             shed_at: 3400)
      burst = events.find { |e| e[:type] == :flywheel_burst }

      expect(burst.fetch(:cause)).to eq(:overload)
      expect(burst.dig(:detail, :rpm)).to be > 100.0
    end

    # Working it hard is not the same as abusing it. Full throttle against a mill that can
    # take it is a legitimate way to run — hot, loud, and inside the wheel's limit.
    it "runs at full throttle indefinitely as long as the mill is taking the power" do
      op = engine
      events = light_and_run(op, throttle: 100, stoking: 80, load: 100, ticks: 4000)

      expect(events).to be_empty
      expect(rpm(op)).to be > 100.0
    end

    # **`broken` used to be decoration.** `Wearing` set the flag, `Flywheel` never read it and
    # nothing generic acted on it, so a wheel that burst at 400.8 rpm against a 321.6 limit was
    # turning at **2364.7 rpm and making 3.97 MW** six hundred ticks later. A player could
    # power through every incident the game had.
    it "stops turning and stops making power once the flywheel has burst" do
      op = engine
      events = light_and_run(op, throttle: 100, stoking: 80, load: 90, ticks: 4200,
                             shed_at: 3400)
      expect(events.map { |e| e[:type] }).to include(:flywheel_burst)

      600.times { |i| op.step!(tick: 4200 + i) }
      state = op.state.fetch(:nodes)

      expect(state.fetch(:flywheel).fetch(:broken)).to be(true)
      expect(rpm(op)).to be_within(1e-9).of(0.0)
      expect(state.fetch(:cylinder).fetch(:indicated_power_w)).to be_within(1e-9).of(0.0)
    end

    # The wheel was carrying megajoules when it let go. Lossy is fine, silent is not.
    it "puts the wrecked flywheel's energy on the ledger" do
      op = engine
      before = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      light_and_run(op, throttle: 100, stoking: 80, load: 90, ticks: 4200, shed_at: 3400)
      after = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

      expect(op.ledger.fetch(:joules_to_friction)).to be > 0.0
      expect((after - before).abs / before.abs).to be < 1e-9
    end

    it "survives a moderate hand on the controls" do
      op = engine
      events = light_and_run(op, throttle: 60, stoking: 60, load: 80, ticks: 4000)

      expect(events).to be_empty
      expect(rpm(op)).to be > 10.0
    end

    # Papin fitted one of these in 1679, and for good reason: a fire does not know how much
    # steam the engine wants.
    #
    # **The blower stays on, and that is the whole scenario.** With the regulator shut the
    # engine cannot turn, so there is no exhaust and no blastpipe, and a fire left to natural
    # draught quietly subsides instead — which is the engine correctly refusing to hurt itself.
    # Leaving forced draught on with nowhere for the steam to go is the classic way to put a
    # boiler on its safety valves, and now it is the way to do it here too.
    it "lifts the safety valve rather than bursting the boiler" do
      op = engine
      light_and_run(op, throttle: 0, stoking: 80, load: 0, ticks: 4000, blower_off: nil)

      # This used to assert the valve was HOLDING steam. A relief valve is a conduit, and
      # conduits stopped holding anything when transport moved to paths — so that proxy now
      # reads nil forever. Ask the valve whether it is lifting instead, which is what the
      # test was always trying to find out.
      #
      # **Sampled over a window rather than at one tick.** Once mass transport became a
      # stable implicit solve the valve got far more authority: it now holds the boiler
      # within a few kPa of its own setting instead of letting it run well past, so the
      # pressure straddles the threshold and `lifting?` at any single instant is a coin
      # flip. A relief valve that pins the vessel at its setting is the correct behaviour —
      # the assertion was reading an equilibrium as a failure.
      lifting_now = lambda do
        ctx = ReactorSim::Tick::Context.new(
          controls: op.state.fetch(:controls).to_h { |id, s| [ id, s.fetch(:actual) ] },
          dt: ReactorSim::DT, tick: 0, content: op.content,
          nodes: op.nodes, states: op.state.fetch(:nodes)
        )
        op.nodes.fetch(:relief).lifting?(ctx)
      end

      lifted = (1..40).any? { |i| op.step!(tick: 4000 + i); lifting_now.call }
      pressure = op.nodes.fetch(:boiler).pressure_pa(op.state.fetch(:nodes).fetch(:boiler), op.content)
      setting = op.nodes.fetch(:relief).relief_pressure_pa

      expect(lifted).to be(true), "the valve never lifted"
      # Held AT its setting, which is the thing that makes it a safety valve rather than an
      # ornament: the fire is pouring in enough to burst the shell and the pressure does not
      # climb regardless.
      expect(pressure).to be_within(0.05 * setting).of(setting)
      expect(op.state.fetch(:nodes).fetch(:boiler).fetch(:broken)).to be(false)
    end
  end

  describe "conservation" do
    it "balances mass and energy through combustion, boiling and shaft work" do
      op = engine
      before_mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      before_joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

      light_and_run(op, ticks: 2600)

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
      light_and_run(watt, throttle: 70, stoking: 60, load: 60, ticks: 3600)

      boiler_pa = watt.nodes.fetch(:boiler).pressure_pa(
        watt.state.fetch(:nodes).fetch(:boiler), watt.content
      )

      expect(rpm(watt)).to be > 5.0, "the atmospheric engine never turned"
      expect(boiler_pa).to be < 2.5 * ReactorSim::Units::STANDARD_PRESSURE_PA
    end

    it "gives the atmospheric engine a condenser vacuum below atmospheric" do
      watt = engine(variant: :atmospheric)
      light_and_run(watt, throttle: 70, stoking: 60, load: 60, ticks: 3600)

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
