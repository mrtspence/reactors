# frozen_string_literal: true

require "reactor_sim"
require "support/engine_rig"

# **The steam engine, one stage at a time, each from the state that stage begins in.**
#
# A steam engine is a chain — fuel burns, the heat crosses into the water, the water becomes steam
# at a pressure, the regulator decides what reaches the chest, the chest pushes the piston, the
# piston turns the wheel. Every link is a separate physical claim, and each one is cheap to check
# *if you start it at its own beginning*. What is expensive is insisting on starting all of them
# at a cold firebox: raising the first steam is 3,600 ticks of waiting that proves nothing about
# the regulator, and it was being paid again by every example that wanted a working engine.
#
# So the state is **constructed** — see `EngineRig`, where every figure was read off a running
# engine rather than invented — and only the ticks that decide a claim are run. Measured: a
# seeded engine is in its working regime on tick 20, against 3,600 for a cold start.
#
# ## What is not here
#
# **Cold-starting the engine by its real operating procedure**, which is a claim about the
# *procedure* and genuinely needs the whole run: blower on, igniter in, mill on the belt before
# the regulator opens. That lives in `steam_engine_spec` along with the other things only a whole
# machine can answer — that both chassis build, that a snapshot restores, that conservation holds
# end to end. One slow run there, not thirty-eight.
#
# See `docs/design_sketches/suite-runtime.md`.
RSpec.describe "the steam engine, stage by stage", crew: :reference do
  include EngineRig

  # **The example that makes every other example in this file trustworthy.**
  #
  # A constructed state is only worth testing against if the simulation could have reached it. The
  # check is that a seeded engine **carries on** rather than lurching: if the state were
  # inconsistent — a wall at ambient beside boiling water, a fire with no draught memory — the
  # first few ticks would be a scramble back to equilibrium, and every measurement taken after it
  # would be a measurement of that scramble.
  #
  # Measured across 400 ticks the drum holds 607.5 → 608.3 kPa and the fire 1025.0 → 1024.1 K.
  describe "the constructed state" do
    it "carries on from the state it was given, with no transient" do
      op = at_work(engine)
      drum = pressure_pa(op, :boiler)
      fire = temperature_k(op, :firebox)

      run!(op, 200)

      expect(pressure_pa(op, :boiler)).to be_within(0.02 * drum).of(drum)
      expect(temperature_k(op, :firebox)).to be_within(0.02 * fire).of(fire)
      expect(rpm(op)).to be_within(0.1 * EngineRig::RPM).of(EngineRig::RPM)
    end

    # The cylinder runs far cooler than the steam that feeds it, and seeding it at drum
    # temperature is a mistake that **looks** harmless: the compression pressure then sits above
    # the cylinder relief valve's setting, so the valve lifts on every stroke and an "ordinary
    # run" is quietly an engine in trouble. Asserted here so the seed cannot drift into it.
    it "leaves the cylinder relief valve shut, as an ordinary run must" do
      op = at_work(engine)
      run!(op, 20)

      compression = op.nodes.fetch(:cylinder)
                      .compression_pressure_pa(node_state(op, :cylinder), op.content)

      expect(compression).to be < op.nodes.fetch(:cylinder_relief).relief_pressure_pa
    end

    # A patch naming a key the node does not read is ignored by everything downstream, which is
    # how a constructed state becomes a state that merely looks constructed.
    it "refuses a state key the node does not have" do
      expect { seed(engine, nodes: { boiler: { temperature_k: 440.0 } }) }
        .to raise_error(ArgumentError, /no nodes state key/)
      expect { seed(engine, nodes: { nonsense: { joules: 1.0 } }) }
        .to raise_error(ArgumentError, /no nodes entry/)
    end
  end

  # Stage one: fuel and air meet, and the result is heat.
  describe "the fire" do
    it "will not light a cold firebox without the igniter" do
      cold = at_work(engine, fire_k: 320.0, ignited: 0.0)
      run!(cold, 20, igniter: 0)

      expect(node_state(cold, :firebox).dig(:ignition, :coal_combustion, :kg)).to be_within(1e-9).of(0.0)
      expect(temperature_k(cold, :firebox)).to be < 400.0
    end

    it "keeps burning once it is alight, with no igniter at all" do
      op = at_work(engine)
      run!(op, 20, igniter: 0)

      expect(node_state(op, :firebox).dig(:ignition, :coal_combustion, :kg)).to be > 0.1
      expect(temperature_k(op, :firebox)).to be > 900.0
    end

    it "burns fuel and leaves ash behind" do
      op = at_work(engine, ash: 0.0)
      bunker = op.telemetry.fetch(:bunker)[:kg]
      run!(op, 30)

      expect(held(op, :firebox, :ash)).to be > 0.0
      expect(held(op, :firebox, :flue_gas)).to be > 0.0
      expect(op.telemetry.fetch(:bunker)[:kg]).to be < bunker
    end

    # Air starvation needs no special case — the reaction is limited by whichever reagent runs out
    # first, so shutting the damper chokes the fire through the same path an empty bunker would.
    it "chokes when the damper is shut" do
      open = at_work(engine)
      shut = at_work(engine)
      run!(open, 20, damper_open: 85)
      run!(shut, 20, damper_open: 0)

      expect(temperature_k(shut, :firebox)).to be < temperature_k(open, :firebox)
    end

    # **The grate silting up, measured with no ticks at all.** Ash is produced by combustion and
    # consumed by nothing, and what it does is fill the void the air has to come through — so the
    # choke is a property of the state, not of how long the engine ran to reach it. Asserted
    # across the range rather than at one point, which is what makes it a curve rather than a
    # coincidence: 0 / 60 / 150 / 300 kg give 1.000 / 0.881 / 0.702 / 0.405.
    it "chokes further the more of its own waste is banked up" do
      throttles = [ 0.0, 60.0, 150.0, 300.0 ].map { |ash| reaction_throttle(at_work(engine, ash: ash)) }

      expect(throttles.first).to be_within(1e-9).of(1.0)
      expect(throttles.each_cons(2).all? { |a, b| b < a }).to be(true), throttles.inspect
      expect(throttles.last).to be < 0.5
    end

    # **The remedy is not optional chrome.** Without a way out the choke is a slow dead end and no
    # lever a player can reach would help, which is a worse game than not modelling it.
    #
    # **Somebody has to be standing there.** Raking is effort, not a valve, so the lever alone
    # moves no ash — clearing the grate costs a pair of hands that were doing something else.
    it "clears when somebody rakes the ashpan out" do
      raked = at_work(engine, ash: 300.0)
      banked = at_work(engine, ash: 300.0)
      run!(raked, 20, raking: :crew_2, ash_raking: 100)
      run!(banked, 20, ash_raking: 100)

      expect(held(raked, :firebox, :ash)).to be < held(banked, :firebox, :ash)
      expect(reaction_throttle(raked)).to be > reaction_throttle(banked)
    end
  end

  # **The three things that make a fire draw**, each on its own: somebody or something paying for
  # a blast, the heat of the stack, and the engine's own exhaust thrown up it. Each is a discrete
  # scenario and none of them needs steam raised from cold to answer — the old form of these
  # claims did exactly that, at up to 6,000 ticks apiece.
  #
  # All of them are measured as `draught_kg`, the air **crossing** the damper. The air a firebox
  # holds is a stock, and it only tracks the draught while the fire's consumption is equal on both
  # sides of the comparison — which it is not when one side's fire is out.
  describe "paying for the blast" do
    def draught(op, ticks: 100, hand: nil, **levers)
      op.assign_minion(hand, :blower) if hand
      run!(op, ticks, **levers)
      draught_kg(op)
    end

    # **An unmanned bellows is identical to no blower at all.** Nothing implements that — an
    # unmanned effort station already delivered nothing — and it is why the bellows is a real cost
    # rather than a slower button. Measured: 0.84814 kg/tick either way, to five decimals.
    it "delivers nothing at all from a bellows nobody is working" do
      unmanned = draught(at_work(engine(loadout: { blower: :hand_bellows })), blower: 100)
      none = draught(at_work(engine(loadout: { blower: nil })))

      expect(unmanned).to be_within(1e-6).of(none)
    end

    it "delivers real draught from a bellows somebody is working" do
      manned = draught(at_work(engine(loadout: { blower: :hand_bellows })),
                       hand: :crew_2, blower: 100)
      unmanned = draught(at_work(engine(loadout: { blower: :hand_bellows })), blower: 100)

      expect(manned).to be > unmanned
    end

    # The bellows is the starting blueprint and the donkey is the unlock, so the donkey has to be
    # meaningfully better — and it costs nobody, which is the upgrade.
    it "draws harder on the donkey than on a bellows, and costs nobody" do
      donkey = draught(at_work(engine(loadout: { blower: :donkey_blower })), blower: 100)
      manned = draught(at_work(engine(loadout: { blower: :hand_bellows })),
                       hand: :crew_2, blower: 100)

      expect(donkey).to be > manned
    end

    # It burns its own charge rather than the engine's, which is what makes running out something
    # the player watches rather than a surprise. A fuel-oil line to the main grate would let a
    # player burn the donkey's fuel in the firebox; a separate tank makes that unexpressible.
    it "burns the donkey's own fuel and leaves the bunker alone" do
      op = at_work(engine(loadout: { blower: :donkey_blower }))
      before = held(op, :donkey_tank, :fuel_oil)
      run!(op, 30, blower: 100)

      expect(held(op, :donkey_tank, :fuel_oil)).to be < before
      expect(node_state(op, :donkey).fetch(:angular_momentum)).to be > 0.0
    end

    # **The fire is its own draught**, which is the whole reason a cold engine needs a blower: the
    # stack pulls because the gas in it is hot and light, so an engine with no fire has nothing
    # drawing it. Buoyancy is `stack_height_m` against the gas temperature, in `Arbiter.path_head`.
    #
    # TODO: isolating stack HEIGHT from the fire that heats it wants two chimneys of different
    # heights, which no part offers — the first caller would be a `transport_spec` rig, where the
    # generic machinery belongs. Until then this proves the fire drives the draught and not that
    # ten metres is worth more than five.
    # Measured: 0.845 kg/tick up a stack at 462.8 K against 0.601 up one at 382.0 K.
    it "draws less up a cold stack than up a hot one" do
      lit = at_work(engine)
      dead = at_work(engine, fire_k: 300.0, ignited: 0.0)
      run!(lit, 20, blower: 0)
      run!(dead, 20, blower: 0, stoking: 0)

      expect(temperature_k(dead, :flue)).to be < temperature_k(lit, :flue)
      expect(draught_kg(dead)).to be < draught_kg(lit)
    end

    # **The blastpipe ties the draught to how hard the engine is working**, which is the feedback
    # loop that makes a locomotive boiler what it is: the exhaust is thrown up the stack, so
    # pulling harder draws harder and makes more steam to pull with.
    #
    # Asserted as the *gain from working the engine*, which is the mechanism rather than a
    # figure — and it is exact on the control side. Measured over 100 ticks: with the blastpipe,
    # standing 0.089 kg/tick against working 0.845, a **9.4× gain**; with a plain chimney, 0.0872
    # against 0.0872, a gain of exactly 1.00.
    it "draws harder the harder the engine works, but only through a blastpipe" do
      gains = %i[blastpipe_chimney plain_chimney].map do |chimney|
        standing = at_work(engine(loadout: { chimney: chimney }), rpm: 0.0)
        working = at_work(engine(loadout: { chimney: chimney }))
        run!(standing, 20, blower: 0, throttle_open: 0, load_demand: 0)
        run!(working, 20, blower: 0)

        draught_kg(working) / draught_kg(standing)
      end

      expect(gains.first).to be > 2.0, "the blastpipe bought no draught: #{gains.inspect}"
      expect(gains.last).to be_within(0.01).of(1.0)
      expect(engine(loadout: { chimney: :plain_chimney }).nodes.fetch(:flue).blast_from).to be_nil
    end
  end

  # Stage two: the fire's heat reaches the water. Asserted as **joules into the drum**, because
  # that is the claim — a 2-tonne drum takes thousands of ticks to show it as a pressure, and
  # insisting on the pressure is how this became a long run rather than a quick one.
  describe "fire to water" do
    def drum_joules(op) = op.nodes.fetch(:boiler).total_joules(node_state(op, :boiler))

    it "carries the fire's heat into the drum" do
      lit = at_work(engine, drum_k: 400.0)
      out = at_work(engine, drum_k: 400.0, fire_k: 300.0, ignited: 0.0)
      was = [ drum_joules(lit), drum_joules(out) ]
      # **Forty, not twenty.** Heat crossing into a 2-tonne drum is a rate, so the gap between a
      # lit fire and a dead one takes a little while to open: at 20 ticks it is 4.5× and this asks
      # for 5. One of the two windows in this file that is a time constant rather than a wait.
      run!(lit, 40)
      run!(out, 40, stoking: 0)

      expect(drum_joules(lit) - was.first).to be > 5.0 * (drum_joules(out) - was.last)
    end

    # **The biggest upgrade on the machine.** With no tube bundle the only fire-to-water path is
    # radiant, which is a plain shell boiler. Measured over 40 ticks: 30.3 MJ against 18.1.
    it "carries much more of it through the tubes than through the shell alone" do
      full = at_work(engine, drum_k: 400.0)
      bare = at_work(engine(loadout: { boiler_tubes: nil }), drum_k: 400.0)
      was = [ drum_joules(full), drum_joules(bare) ]
      [ full, bare ].each { |op| run!(op, 20) }

      expect(drum_joules(full) - was.first).to be > 1.3 * (drum_joules(bare) - was.last)
      expect(bare.nodes).not_to have_key(:boiler_tubes)
      # The convective path leaves with the bundle; only the radiant one is left.
      expect(bare.thermal_links.length).to eq(1)
    end
  end

  # Stage three: the drum has steam and the regulator decides what the engine gets.
  describe "the drum to the steam chest" do
    # **The regulator is a restriction, not a ration**, and this is the difference. The throttle
    # is a conductance, so flow through it costs a pressure drop that grows with the flow, and the
    # chest sits below the drum by an amount the driver controls. That gap IS the wire-drawing.
    #
    # Before the chest existed the regulator could not affect torque at all, and a conservation
    # clamp silently became the throttling mechanism. A clamp is not a mechanism.
    it "wire-draws: the further it is shut, the further the chest falls below the drum" do
      drops = [ 100, 60, 20 ].map do |lever|
        op = at_work(engine)
        run!(op, 20, throttle_open: lever)
        chest_drop_pa(op)
      end

      expect(drops.each_cons(2).all? { |a, b| b > a }).to be(true), drops.inspect
      expect(drops.last).to be > 1.5 * drops.first
    end

    it "fills the chest higher the further it is opened" do
      pressures = [ 20, 60, 100 ].map do |lever|
        op = at_work(engine)
        run!(op, 20, throttle_open: lever)
        pressure_pa(op, :steam_chest)
      end

      expect(pressures.each_cons(2).all? { |a, b| b > a }).to be(true), pressures.inspect
      expect(pressures.last).to be < pressure_pa(at_work(engine), :boiler)
    end
  end

  # Stage four: the chest pushes the piston and the piston turns the wheel.
  describe "the steam chest to the crank" do
    # No special case makes this happen: the cylinder fills, its pressure rises, and the torque
    # that results is what turns the wheel. Torque comes from pressure rather than from power
    # precisely so that a stopped engine can start — dividing a power figure by ω is infinite at
    # rest, and the machine could never be started at all.
    it "starts itself from a standstill once there is steam and the throttle is open" do
      op = at_work(engine, rpm: 0.0)
      expect(rpm(op)).to be_within(1e-9).of(0.0)

      run!(op, 20)

      expect(rpm(op)).to be > 100.0
      expect(shaft_power_w(op)).to be > 100_000.0
    end

    # Speed is a poor instrument for this and the load curve is why: a fan law absorbs power as
    # ω³, so a large power range shows up as a small speed range. The quantity that answers "is
    # the regulator working" is the power it lets through. Measured at 40 ticks: 205.9 kW at
    # lever 20 against 618.8 at 100.
    it "makes more power the further the throttle is opened" do
      powers = [ 20, 40, 60, 100 ].map do |lever|
        op = at_work(engine)
        run!(op, 20, throttle_open: lever)
        shaft_power_w(op)
      end

      expect(powers.each_cons(2).all? { |a, b| b > a * 1.05 }).to be(true),
                                                                  powers.map { |w| (w / 1000).round(1) }.inspect
    end

    it "puts the fire's heat on the ledger as shaft work" do
      op = at_work(engine)
      run!(op, 20)

      expect(op.ledger.fetch(:joules_added)).to be > 0.0
      expect(op.ledger.fetch(:joules_to_work)).to be > 0.0
    end
  end

  # Stage five: the wheel, which is the part that kills people.
  describe "the flywheel" do
    # **It is shedding the load, not opening the regulator.** The mill is a fan-law load, so it
    # holds the engine at its duty point and full demand is the *safe* setting; what destroys the
    # engine is taking the load away, which is how real machinery has always destroyed itself.
    #
    # Measured: the wheel lets go at 417.7 rpm against a limit of 413.5, inside 20 ticks.
    it "bursts when the load is thrown off" do
      events = at_work(engine).then { |op| run!(op, 20, throttle_open: 100, stoking: 80, load_demand: 0) }
      burst = failures_of(events, :flywheel).first

      expect(burst).not_to be_nil, "the wheel survived having the load taken off"
      expect(burst.fetch(:mode)).to be(:burst)
      expect(burst.fetch(:cause)).to be(:overload)
      expect(burst.dig(:detail, :rpm)).to be > 100.0
    end

    # Working it hard is not the same as abusing it. Full throttle against a mill that can take
    # it is a legitimate way to run — hot, loud, and inside the wheel's limit.
    it "survives full throttle as long as the mill is taking the power" do
      op = at_work(engine)
      events = run!(op, 20, throttle_open: 100, stoking: 80, load_demand: 90)

      expect(events.select { |e| e[:type] == :part_failed }).to be_empty
      expect(rpm(op)).to be > 100.0
    end

    # **`broken` used to be decoration.** `Wearing` set the flag, `Flywheel` never read it and
    # nothing generic acted on it, so a wheel that burst at 400 rpm against a 321 limit was
    # turning at 2,364 rpm and making 3.97 MW six hundred ticks later.
    it "stops turning and stops making power once it has burst" do
      op = at_work(engine)
      events = run!(op, 20, throttle_open: 100, stoking: 80, load_demand: 0)
      expect(failures_of(events, :flywheel)).not_to be_empty

      run!(op, 20, from: 40, throttle_open: 100, stoking: 80, load_demand: 0)

      expect(node_state(op, :flywheel).fetch(:failure)).to be(:burst)
      expect(rpm(op)).to be_within(1e-9).of(0.0)
      expect(node_state(op, :cylinder).fetch(:indicated_power_w)).to be_within(1e-9).of(0.0)
    end

    # The wheel was carrying megajoules when it let go. Lossy is fine, silent is not.
    it "puts the wrecked wheel's energy on the ledger" do
      op = at_work(engine)
      before = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      run!(op, 20, throttle_open: 100, stoking: 80, load_demand: 0)
      after = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

      expect(op.ledger.fetch(:joules_to_friction)).to be > 0.0
      expect((after - before).abs / before.abs).to be < 1e-9
    end
  end

  # Stage six: the devices that stop the above killing anybody, and what they are worth — proved
  # by taking them off, which is the claim the design rests on and was untestable while they were
  # welded in.
  describe "the safeguards" do
    # Papin fitted one of these in 1679, and for good reason: a fire does not know how much steam
    # the engine wants. **Held AT its setting**, which is what makes it a safety valve rather than
    # an ornament — the fire is pouring in enough to burst the shell and the pressure does not
    # climb regardless of how hot the drum was to start with.
    it "holds the drum at the safety valve's setting, however hard it is fired" do
      setting = engine.nodes.fetch(:relief).relief_pressure_pa

      [ 440.0, 460.0, 480.0 ].each do |seeded_k|
        op = at_work(engine, drum_k: seeded_k, rpm: 0.0)
        events = run!(op, 30, throttle_open: 0, load_demand: 0, stoking: 80)

        expect(events.map { |e| e[:type] }).to include(:blew_off)
        expect(pressure_pa(op, :boiler)).to be_within(0.02 * setting).of(setting)
        expect(node_state(op, :boiler).fetch(:failure)).to be_nil
      end
    end

    # **The safety valve costs power, and that is the whole point of being allowed to remove it.**
    # Measured over 60 ticks: 608 kPa pinned with the valve fitted, 1,223 kPa without — and the
    # shell's own derived rating, 1,458 kPa, is then the only thing in the way.
    it "lets the drum run away with no safety valve fitted, up toward the shell's rating" do
      fitted = at_work(engine, drum_k: 460.0, rpm: 0.0)
      stripped = at_work(engine(loadout: { safety_valve: nil }), drum_k: 460.0, rpm: 0.0)
      [ fitted, stripped ].each { |op| run!(op, 30, throttle_open: 0, load_demand: 0, stoking: 80) }

      expect(pressure_pa(stripped, :boiler)).to be > 1.5 * pressure_pa(fitted, :boiler)
      expect(pressure_pa(stripped, :boiler))
        .to be < stripped.nodes.fetch(:boiler).rated_pressure_pa(stripped.content)
      # The gauges and levers go with the part, which is what makes the choice legible: there is
      # no Safety Valve reading to watch because there is no safety valve.
      expect(stripped.diagnostics).not_to have_key(:safety_valve)
      expect(stripped.control_points).not_to have_key(:valve_setting)
    end

    # **A decision, not a safety net.** A standing cylinder fills with its own condensate: while
    # the engine turns the exhaust stroke sweeps the water out, but `exhaust_demand_kg` scales
    # with revolutions, so a stopped engine carries nothing away and the water collects.
    #
    # The cocks are permissive on purpose — real ones blow steam as well as water, so leaving them
    # open is a choice rather than a free win.
    # **Swell is driven by the RATE the drum's pressure falls**, so steady running of any
    # intensity costs nothing and only a sharp change in demand lifts the water. Without that the
    # mechanic is just a worse baseline: the first attempt scaled it by offtake and put a
    # hard-pulling engine at a safe level into permanent carryover.
    it "leaves an engine held at a steady throttle dry, however hard it is working" do
      op = at_work(engine)
      run!(op, 20, throttle_open: 100, stoking: 80)

      expect(op.nodes.fetch(:boiler).swell_fraction(node_state(op, :boiler))).to be < 0.05
      expect(occupancy(op)).to be < 0.1
    end
  end

  # **Warming through, in its parts.** Leaving a cold cylinder's cocks shut through a startup
  # fills it with its own condensate and the engine ends up knocking badly — but that composite is
  # the *sum* of the four mechanisms below, and each is a discrete scenario a constructed state
  # reaches directly. The composite cannot be constructed faithfully anyway: a cold cylinder on a
  # working engine reads occupancy 0.011, not the 0.859 a slow warm-up reaches, because a turning
  # engine sweeps the water straight out. Which is itself the third claim here.
  #
  # **The load stays on in all of these.** With `load_demand: 0` the wheel runs away and bursts
  # inside 40 ticks, and then every reading is about the wheel rather than the cylinder.
  describe "water in the cylinder" do
    def peak_occupancy(op, ticks, **levers)
      peak = 0.0
      # Qualified, because a bare constant inside an example group resolves lexically against
      # `Object` rather than through the `include` — `EngineRig::WORKING` is the only spelling
      # that finds it.
      EngineRig::WORKING.merge(levers).each { |id, value| op.set_control(id, value) }
      op.assign_minion(:crew_1, :stoking)
      ticks.times { |i| op.step!(tick: i + 1); peak = [ peak, occupancy(op) ].max }
      peak
    end

    # A cold casting condenses much of what is admitted to it, which is the whole reason the
    # procedure exists. **Only the wall temperature differs** — both start empty, because seeding
    # the warm arm with the working cylinder's own contents (0.059 kg of water) puts condensate in
    # it before the example begins and collapses the ratio from 3.3× to 1.2×.
    # Measured over 100 ticks: 0.0196 against 0.0060.
    it "condenses more in a cold cylinder than in a warm one" do
      cold = peak_occupancy(at_work(engine, rpm: 0.0, cylinder: body(engine, :cylinder, 292.0)), 100)
      warm = peak_occupancy(
        at_work(engine, rpm: 0.0, cylinder: body(engine, :cylinder, EngineRig::CYLINDER_K)), 100
      )

      expect(cold).to be > 2.0 * warm
    end

    # **Permissive on purpose**: real cocks blow steam as well as water, so leaving them open is a
    # choice rather than a free win — note the engine ends slower for it (139 rpm against 171).
    it "drains it through the cocks, at the price of the steam that goes with it" do
      shut = at_work(engine, rpm: 0.0, cylinder: body(engine, :cylinder, 292.0))
      open = at_work(engine, rpm: 0.0, cylinder: body(engine, :cylinder, 292.0))
      shut_peak = peak_occupancy(shut, 40, cylinder_cocks: 0)
      open_peak = peak_occupancy(open, 40, cylinder_cocks: 100)

      expect(open_peak).to be < shut_peak
      expect(rpm(open)).to be < rpm(shut)
    end

    # **What empties a cylinder is revolutions**, because `exhaust_demand_kg` scales with them —
    # so the hazard belongs to standing, not to running. The middle row is the warming-through
    # trap itself: an engine barely turning with steam on gets **wetter**, because it is admitting
    # steam to condense faster than its few strokes carry away.
    #
    #     throttle 0, shut in     0.430 -> 0.369    0 rpm   stays wet
    #     throttle 5, cracked     0.430 -> 0.513   68 rpm   GETS WETTER
    #     throttle 60, working    0.430 -> 0.001  170 rpm   swept dry
    it "is swept out by revolutions, and collects in an engine barely turning" do
      wet = body(engine, :cylinder, 360.0, water: 6.0, steam: 0.4)
      # **A hundred, not forty.** Sweeping a cylinder out is a rate — `exhaust_demand_kg` carries
      # a little per stroke — so a shorter window catches the working engine mid-clear at 0.395
      # rather than dry. The other time constant in this file; everything else here is 20 ticks.
      ends = [ 0, 5, 60 ].map do |lever|
        op = at_work(engine, rpm: 0.0, cylinder: wet)
        peak_occupancy(op, 100, throttle_open: lever)
        occupancy(op)
      end

      expect(ends[1]).to be > ends[0], "a cracked regulator should accumulate: #{ends.inspect}"
      expect(ends[2]).to be < 0.01, "a working engine should sweep itself dry: #{ends.inspect}"
    end

    # **The cylinder relief valve's setting rarely matters; its presence does.** Seeded with 10 kg
    # of water the compression pressure at top dead centre reaches 3,413 kPa against the valve's
    # 912 kPa setting — the valve lifts and vents the charge, and without one the head goes.
    #
    # Note it is `compression_pressure_pa` that is dangerous, not `pressure_pa`: the charge spread
    # over the whole cylinder barely moves as the clearance fills, so a valve pointed at the
    # average would give no warning at all.
    it "is what the cylinder relief valve exists for, and the head goes without one" do
      wet = body(engine, :cylinder, 360.0, water: 10.0, steam: 0.4)
      fitted = at_work(engine, rpm: 0.0, cylinder: wet)
      stripped = at_work(engine(loadout: { cylinder_relief: nil }), rpm: 0.0, cylinder: wet)

      expect(fitted.nodes.fetch(:cylinder)
               .compression_pressure_pa(node_state(fitted, :cylinder), fitted.content))
        .to be > fitted.nodes.fetch(:cylinder_relief).relief_pressure_pa

      kept = run!(fitted, 30, cylinder_cocks: 0)
      lost = run!(stripped, 30, cylinder_cocks: 0)

      expect(failures_of(kept, :cylinder)).to be_empty
      expect(failures_of(lost, :cylinder).map { |e| e.fetch(:mode) }).to include(:blown_head)
    end
  end

  # **Conservation over several different states rather than one long run**, which is better
  # coverage and not merely faster: a conservation bug lives in a *code path*, so what finds it is
  # entering the path at all, not staying in it for thousands of ticks. One 2,600-tick startup
  # visited one trajectory; these five visit a working engine, a drum blowing off, a wheel
  # tearing itself apart, a choked grate and an engine throwing steam out of its cocks.
  #
  # Measured relative error across all five at this window: **mass ≤ 1.2e-16, energy ≤ 2.2e-16**,
  # against a contract of 1e-9 — seven orders of magnitude of headroom, so a drift large enough to
  # matter cannot hide in it. The figures are identical at 400 ticks, which is why this is 100.
  describe "conservation" do
    # **Not a constant**, because a constant assigned inside an example group resolves lexically
    # and lands on `Object` — so two spec files naming one would silently overwrite each other,
    # and which won would depend on the randomised file order. See `EngineRig` for the shared
    # figures that legitimately are constants, on a module.
    states = {
      "a working engine" => [ {}, {} ],
      "a drum blowing off" => [ { drum_k: 470.0, rpm: 0.0 },
                                { throttle_open: 0, load_demand: 0, stoking: 80 } ],
      "a wheel bursting" => [ {}, { throttle_open: 100, stoking: 80, load_demand: 0 } ],
      "a banked grate" => [ { ash: 300.0 }, {} ],
      "steam out of the cocks" => [ {}, { cylinder_cocks: 100 } ]
    }

    states.each do |label, (seeded, levers)|
      it "balances mass and energy through #{label}" do
        op = at_work(engine, **seeded)
        before_mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
        before_joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

        run!(op, 20, **levers)

        expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - before_mass).abs /
               before_mass.abs).to be < 1e-9
        expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - before_joules).abs /
               before_joules.abs).to be < 1e-9
      end
    end
  end

  # The atmospheric engine is the architectural thesis, and it is the same claim one stage at a
  # time: Watt's engine makes power from a vacuum on a boiler barely above atmospheric.
  describe "the atmospheric chassis" do
    it "runs on a boiler pressure the high-pressure engine could not use" do
      watt = at_work(engine(chassis: :atmospheric), drum_k: 380.0, rpm: 10.0)
      run!(watt, 30, throttle_open: 70, load_demand: 60)

      expect(rpm(watt)).to be > 5.0, "the atmospheric engine never turned"
      expect(pressure_pa(watt, :boiler)).to be < 2.5 * ReactorSim::Units::STANDARD_PRESSURE_PA
    end

    it "holds its condenser below atmospheric, which is what drives it" do
      watt = at_work(engine(chassis: :atmospheric), drum_k: 380.0, rpm: 10.0)
      run!(watt, 30, throttle_open: 70, load_demand: 60)

      expect(pressure_pa(watt, :condenser)).to be < ReactorSim::Units::STANDARD_PRESSURE_PA
    end
  end
end
