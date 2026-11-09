# frozen_string_literal: true

require "reactor_sim"
require "support/reference_crew"
require "support/engine_rig"

# **What is left of the engine's spec once every claim has been put where it is decided.**
#
# Each *stage* of this engine lives in `engine_stages_spec`, built from constructed state and
# measured in tens of ticks. **A whole startup is the composition of those stages**, so running
# one is not a separate claim — it re-proves each slice in sequence at a hundred times the price.
# What is genuinely only answerable here:
#
# - **That the engine as built can be brought to work.** It is built banked, and a constructed
#   state cannot catch a bug in the path that *reaches* a working engine — so the banked fire is
#   brought through for real, on the bellows.
# - **That a cold machine can be lit at all**, from a bare grate, for an engine whose fire has
#   gone out.
# - **Conservation through lighting up**, the one trajectory the five constructed states in
#   `engine_stages_spec` cannot visit, because all of them start hot.
# - **The architectural thesis**: both engines from the same parts. All build-time.
# - **Snapshots**, where a round trip has to rebuild the same machine.
#
# **Nothing here runs past 100 ticks except the 50-tick snapshot.** If a claim seems to need
# thousands, it is a composition of stage claims and belongs there instead — that is how this file
# went from 38 runs of up to 7,200 ticks to this.
#
# `docs/design_sketches/boiler.md` set the bar: *if an atmospheric engine and a high-pressure
# engine can be the same operation with different parts swapped in, the abstractions are the right
# ones.* The thesis group is that test.
RSpec.describe "the steam engine", crew: :reference do
  # `chassis:` — the frame, which decides where the exhaust goes and therefore which slots exist.
  # An empty loadout is the stock engine.
  #
  # **The crew is part of the machine**, and it is a fixture rather than anybody real. Stoking is
  # effort, so a lever position is an instruction and what comes of it depends on who is carrying
  # it out — with no roster at all the engine is crewed by day-labourers and never raises steam.
  # `ReferenceCrew` is a flat 1.0 at every stat, which is the baseline every work station's
  # throughput is declared against, and it cannot drift when real people are tuned.
  def engine(chassis: :high_pressure, seed: 42, loadout: {})
    ReactorSim::Match
      .create(id: "e", seed: seed,
              operations: [ { id: "eng", type: :steam_engine, chassis: chassis,
                              loadout: ReferenceCrew.loadout(loadout) }
                              .merge(ReferenceCrew.options) ])
      .operation(:eng)
  end

  # **Light the fire, and nothing beyond that**: the igniter in, the blower on, a hand on the
  # shovel, the igniter out at `igniter_out`. The lever positions are `ReferenceCrew::LIGHT`,
  # because `diagnostic_spec` lights the same engine.
  #
  # **The shift has to be DEPLOYED, and that is the opening move of a match.** Crew start in the
  # quarters rather than at a lever, so a run that posts nobody gets no fire at all. `firing:` is
  # the hand on the shovel and `blowing:` the hand on the bellows.
  def light!(op, ticks: 100, igniter_out: 30, firing: :crew_1, blowing: :crew_2)
    ReferenceCrew::LIGHT.each { |id, value| op.set_control(id, value) }
    op.assign_minion(firing, :stoking) if firing
    op.assign_minion(blowing, :blower) if blowing && op.control_points.key?(:blower)

    (1..ticks).flat_map do |t|
      op.set_control(:igniter, 0) if t == igniter_out
      op.step!(tick: t)
    end
  end

  # **Bring the banked fire through**: the damper open and the bellows worked with the regulator
  # shut, the way a fireman livens a fire banked overnight — the blastpipe has nothing to blow
  # with until there is steam.
  def bring_up!(op, ticks:, blowing: :crew_2, from: 0)
    ReferenceCrew::LIGHT.merge(igniter: 0, stoking: 60).each { |id, value| op.set_control(id, value) }
    op.assign_minion(:crew_1, :stoking)
    op.assign_minion(blowing, :blower) if blowing && op.control_points.key?(:blower)
    (1..ticks).flat_map { |t| op.step!(tick: from + t) }
  end

  def lit_share(op) = ignited_kg(op) / contents(op, :fire_bed, :coal)

  # **"Nothing went wrong" is not "no events".** These examples used to assert an empty event
  # list, which meant the right thing when the only events were failures. The engine reports
  # ordinary transitions too — a fire catching, a drum reaching working pressure — so a healthy
  # run emits several and the old assertion would fail on a perfect one.
  def breakages(events) = events.select { |e| e[:type] == :part_failed }

  def rpm(op) = op.nodes.fetch(:flywheel).rpm(op.state.fetch(:nodes).fetch(:flywheel))

  def pressure_of(op, node)
    op.nodes.fetch(node).pressure_pa(op.state.fetch(:nodes).fetch(node), op.content)
  end

  def contents(op, node, resource)
    op.state.fetch(:nodes).fetch(node).fetch(:parcels, [])
      .select { |p| p.fetch(:resource).to_sym == resource }.sum { |p| p.fetch(:kg) }
  end

  def truth(op, gauge) = op.project(viewer: :spectator).gauges.fetch(gauge)

  def ignited_kg(op)
    op.state.fetch(:nodes).fetch(:fire_bed).dig(:ignition, :coal_combustion, :kg).to_f
  end

  # **The one that keeps the rest of the suite honest.** Run for real, by the procedure — never from
  # a snapshot, because a fixture restored from a hot engine cannot fail when the path to a hot
  # engine breaks.
  describe "a banked start, by the book" do
    # **The match opens on a fire banked by the shift before**, a small core under green coal, and
    # the bellows bring it through: the whole bed is alight inside forty seconds and the drum at
    # working pressure in about two and a half minutes. 200 ticks decides it — the bed through and
    # the drum gaining.
    it "brings the banked fire through on the bellows" do
      op = engine
      expect(lit_share(op)).to be < 0.05
      events = bring_up!(op, ticks: 20)
      was = pressure_of(op, :boiler)
      events += bring_up!(op, ticks: 180, from: 20)

      expect(lit_share(op)).to be > 0.9
      expect(pressure_of(op, :boiler)).to be > was
      expect(truth(op, :fire_state)).not_to eq("cold")
      expect(breakages(events)).to be_empty
    end

    # **A fire already burning does not announce that it caught**, or every match would open on a
    # `fire_lit` and the delivery tier would read a cold start into it.
    it "reports no fire catching when it was banked alight" do
      events = bring_up!(engine, ticks: 20)

      expect(events.map { |e| e[:type] }).not_to include(:fire_lit)
    end
  end

  describe "a cold start, by the book" do
    # **That a bare, cold grate can be lit at all**, for an engine whose fire has gone out: an
    # igniter, the bellows and a shovel take a 293 K grate to a fire that goes on spreading with the
    # igniter out. Measured: 0.23 kg alight when it comes out at tick 30, 1.31 kg at tick 100.
    it "takes a cold grate to a fire that sustains itself" do
      op = EngineRig.cold(engine)
      events = light!(op, ticks: 30)
      lit = ignited_kg(op)
      events += light!(op, ticks: 70, igniter_out: 1)

      # The difference between a fire and a heater somebody left on.
      expect(ignited_kg(op)).to be > 2.0 * lit
      expect(contents(op, :fire_bed, :ash)).to be > 0.0
      expect(op.telemetry.fetch(:bunker)[:kg]).to be < 12_000.0
      expect(breakages(events)).to be_empty
    end
  end

  # **Going without a safety device has to be a decision, not a strictly-worse choice** — and only
  # one of those claims is about the *startup* rather than about a stage. The safety valve, the
  # tube bundle and the cylinder relief are all measured in `engine_stages_spec` in tens of ticks.
  describe "going without the safety devices" do
    # **A banked fire on natural draught alone only smokes.** With the regulator shut the blastpipe
    # has nothing to blow, and a stack over a banked fire hardly draws, so the bed does not come
    # through and the drum falls. Measured at 200 ticks: 15 kg of the bed alight against all of it
    # on the bellows.
    it "cannot bring a banked fire through with no blower fitted" do
      stripped = engine(loadout: { blower: nil })
      bring_up!(stripped, ticks: 20)
      was = pressure_of(stripped, :boiler)
      bring_up!(stripped, ticks: 180, from: 20)
      bellows = engine.tap { |op| bring_up!(op, ticks: 200) }

      expect(rpm(stripped)).to be_within(1e-6).of(0.0)
      expect(pressure_of(stripped, :boiler)).to be < was
      expect(ignited_kg(stripped)).to be < 0.5 * ignited_kg(bellows)
    end
  end

  # **Priming, and the failure this engine exists to be able to suffer.** A full glass is safe
  # until you pull on it: open the regulator sharply and the drum's pressure falls, its water
  # flashes, the level swells past the steam offtake, and what goes down the pipe is water — which
  # the piston then swallows *by volume*. Design and corrections:
  # `docs/design_sketches/obstruction.md`.
  describe "priming and hydraulic lock" do
    # **Skipped because the demonstration this asserted was withdrawn, not because it is flaky.**
    #
    # It passed against a boiler whose swell saturated on a single-tick pressure spike — see the
    # smoothing traps in `current_progress.md`. With an honest signal the same run peaks at
    # wetness 0.509 and occupancy 0.163, and the cylinder survives.
    #
    # The *mechanism* is proven in `obstruction_spec`: a flooded chest makes the intake ask for
    # 50× more, enough to fill the clearance inside twenty ticks. What is unproven is that the
    # engine has a **reachable operating point** where the boiler is wet enough and the crank
    # still turning — every way of raising the glass runs the feed pump, whose 293 K water puts
    # the fire out, and a dead fire makes no pressure transient to swell on.
    #
    # `skip` rather than `pending` on purpose: `pending` executes the body, and this one is 6,200
    # ticks of a run that is expected not to demonstrate anything.
    #
    # TODO: settle this with `EngineRig` rather than another long run — a constructed state can be
    # put at a wet drum *and* a turning crank directly, which is exactly the point this is stuck
    # on. Do not "fix" it by making the swell signal twitchy again.
    it "destroys the cylinder when a full boiler is opened up at speed" do
      skip("no reachable operating point yet: filling the boiler kills the fire — see " \
           "current_progress.md, the feedwater preheat row")
    end
  end

  describe "conservation" do
    # **The one trajectory the constructed states cannot visit: lighting up.**
    # `engine_stages_spec` balances five different working states for 400 ticks each, which is
    # better coverage of the code paths — but all five start from an engine that is already hot,
    # so the ledger lines a cold start writes (an igniter injecting, a fire first catching) are
    # only crossed here.
    it "balances mass and energy through lighting up" do
      op = EngineRig.cold(engine)
      before_mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      before_joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

      light!(op, ticks: 100)

      after_mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      after_joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

      expect((after_mass - before_mass).abs / before_mass.abs).to be < 1e-9
      expect((after_joules - before_joules).abs / before_joules.abs).to be < 1e-9
    end
  end

  # The reason this operation was built. All build-time, so all free.
  describe "the architectural thesis" do
    it "builds both engines from the same parts" do
      shared = %i[atmosphere bunker stoker damper grate fire_bed firebox flue supply feed_pump
                  boiler relief throttle cylinder flywheel load]

      %i[high_pressure atmospheric].each do |variant|
        expect(engine(chassis: variant).nodes.keys).to include(*shared)
      end
    end

    # One line in the operation definition decides which engine this is.
    it "differs only in what the cylinder exhausts into" do
      expect(engine(chassis: :high_pressure).nodes.fetch(:cylinder).exhausts_to).to eq(:atmosphere)
      expect(engine(chassis: :atmospheric).nodes.fetch(:cylinder).exhausts_to).to eq(:condenser)
    end

    it "gives the atmospheric engine a condenser and the high-pressure engine none" do
      expect(engine(chassis: :atmospheric).nodes).to have_key(:condenser)
      expect(engine(chassis: :high_pressure).nodes).not_to have_key(:condenser)
    end

    # The closed water loop — condenser to hotwell to feed — is exactly the topology a
    # topological resolution order could not have handled.
    it "closes the water loop on the atmospheric engine" do
      watt = engine(chassis: :atmospheric)

      expect(watt.links.map(&:id)).to include(:"hotwell.outlet->supply.in")
    end
  end

  describe "snapshots" do
    # The chassis is builder configuration, not state. Without persisting it, an atmospheric
    # engine would restore as a high-pressure one — a total, silent divergence.
    it "restores an atmospheric engine as an atmospheric engine" do
      watt = engine(chassis: :atmospheric)
      light!(watt, ticks: 50)

      restored = ReactorSim::Operation.from_h(
        ReactorSim.deep_symbolize(JSON.parse(JSON.generate(watt.to_h)))
      )

      expect(restored.nodes).to have_key(:condenser)
      expect(ReactorSim.canonical(restored.to_h)).to eq(ReactorSim.canonical(watt.to_h))
    end

    # **`eq` cannot catch this and `canonical` cannot either.** The loadout is symbols living as
    # VALUES in `options:`, and JSON preserves neither: `deep_symbolize` converts keys only, so a
    # part id comes back as `"locomotive_boiler"` and misses every `Parts.fetch`. That is not a
    # nil — it is a different machine, rebuilt in silence. And `canonical` runs through
    # `JSON.generate`, where `:locomotive_boiler` and the string are the same thing, so the digest
    # assertion above passes with the bug present.
    #
    # Fourth instance of this trap after parcel resource ids, instrument flags and a minion's
    # station. Only an identity assertion finds it.
    it "restores the loadout as symbols, not as strings" do
      restored = ReactorSim::Operation.from_h(
        ReactorSim.deep_symbolize(JSON.parse(JSON.generate(engine.to_h)))
      )

      loadout = restored.options.fetch(:loadout)
      expect(loadout).not_to be_empty
      expect(loadout.fetch(:boiler)).to be(:locomotive_boiler)
      expect(restored.options.fetch(:chassis)).to be(:high_pressure)
    end

    # A slot left deliberately empty must STAY empty. A loadout that recorded only what was fitted
    # would fall back to `slot.default` on restore and quietly grow the part back — which is why
    # `Assembly#loadout` names every slot, empty ones included.
    it "keeps a deliberately empty slot empty across a snapshot" do
      resolved = ReactorSim::Assembly.new(
        slots: [ ReactorSim::Slot.new(id: :s, accepts: :k, default: :whatever) ],
        loadout: { s: nil }
      ).loadout

      expect(resolved).to eq({ s: nil })
      expect(ReactorSim.deep_symbolize(JSON.parse(JSON.generate(resolved)))).to eq({ s: nil })
    end
  end

  # The crew is wired up but deliberately inert here: every lever on this machine is frictionless,
  # so the rate multiplier a minion contributes is discarded before it is used. That is what let a
  # crew be added without re-measuring the skill gradient — and it is also why the seam itself is
  # proved in `minion_spec`, on a rig with a stiff lever, rather than here.
  describe "the crew" do
    it "posts everyone to a lever that exists" do
      op = engine
      stations = op.state.fetch(:minions).values.filter_map { |m| m.fetch(:station) }

      expect(stations).to all(satisfy { |s| op.control_points.key?(s) })
      expect(stations).not_to be_empty
    end

    # Pins the inertness deliberately, so that giving a work station a finite stiffness shows up
    # here as a failing expectation rather than as a quietly shifted skill gradient.
    it "leaves a manned lever frictionless, so the minion cannot yet slow it down" do
      op = engine
      op.assign_minion(:crew_1, :stoking)
      op.set_control(:stoking, 100.0)
      op.step!(tick: 1)
      lever = op.state.fetch(:controls).fetch(:stoking)

      expect(op.state.fetch(:minions).fetch(:crew_1).fetch(:station)).to eq(:stoking)
      expect(lever.fetch(:actual)).to eq(lever.fetch(:target))
    end
  end
end
