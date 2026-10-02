# frozen_string_literal: true

require "reactor_sim"

# **Firedamp: the thing the ventilation is for.**
#
# The mine gives off gas whether anybody is watching or not, and the only question is whether
# enough air is going past to take it away. Everything in this file is a consequence of that one
# sentence — the fan is not a machine that makes a number go up, it is the reason the district
# is survivable.
#
# Its own crew rather than `ReferenceCrew`: these examples are about **who was standing where
# when it went up**, so they need people who can get there. A day-labourer takes fourteen
# simulated minutes to reach the face and the explosion happens without them, which is correct
# behaviour and a useless assertion.
#
# See `docs/design_sketches/mine.md` §4.6 stage D.
module FiredampCrew
  ARCHETYPE = { label: "Collier", strength: 1.0, toughness: 1.0, endurance: 1.0e6,
                intelligence: 1.0, dexterity: 1.0, charisma: 1.0,
                # Hewing and timbering are **gated** on light, so a fixture with no lamp cuts
                # nothing at all.
                tags: { mining_effectiveness: 0.6, shovelling: 0.5,
                        darkvision: 0.8 } }.freeze

  MINIONS = (1..4).to_h { |i| [ :"collier_#{i}",
                                { name: "Collier #{i}", archetype: :collier,
                                  hireable: false } ] }.freeze

  CONTENT = ReactorSim::Content.default.merging(archetypes: { collier: ARCHETYPE },
                                                minions: MINIONS)

  CREW = (1..4).to_h { |i| [ :"crew_#{i}", { minion: :"collier_#{i}" } ] }.freeze
end

RSpec.describe "firedamp" do
  before { allow(ReactorSim::Content).to receive(:default).and_return(FiredampCrew::CONTENT) }

  SUPPLY_J = 9.0e4

  def pit(**opts)
    ReactorSim::Match
      .create(id: "f", seed: 7,
              operations: [ { id: "pit", type: :mine, crew: FiredampCrew::CREW,
                              ground: ReactorSim::Operations::Mine::Ground::ORDINARY,
                              **opts } ])
      .operation(:pit)
  end

  def run!(op, ticks, from: 0, supply: SUPPLY_J)
    events = []
    ticks.times do |i|
      op.receive_supply(:line_shaft, supply)
      events.concat(op.step!(tick: from + i + 1))
    end
    events
  end

  # Percentage, which is the quantity a damp is described in and the one a flame responds to —
  # kilograms mean different things with the fan on and off, because the air went with the fan.
  def gas_pct(op)
    parcels = op.state.fetch(:nodes).fetch(:district).fetch(:parcels)
    total = parcels.sum { |p| p.fetch(:kg) }
    return 0.0 unless total.positive?

    fd = parcels.find { |p| p.fetch(:resource) == :firedamp }&.fetch(:kg) || 0.0
    fd / total * 100.0
  end

  def station_of(op, seat) = op.state.fetch(:minions).fetch(seat)[:station]

  # Get the shift to the face and let the air settle.
  def manned(op, ticks: 1_600)
    op.assign_minion(:crew_1, :hewing)
    op.assign_minion(:crew_2, :haulage)
    run!(op, ticks)
    op
  end

  describe "emission" do
    it "gives off gas with nobody doing anything at all" do
      op = pit
      run!(op, 600)

      expect(gas_pct(op)).to be > 0.0
    end

    # The blower is pressure-driven, so what it vents depends on what it is venting against.
    # A fixed rate could not do this, and it is the reason a cleared working vents harder.
    it "vents harder into a clear district than a gassy one" do
      clear = pit
      run!(clear, 200)
      early = clear.state.fetch(:nodes).fetch(:blower).fetch(:carried_kg)

      run!(clear, 3_000, from: 200, supply: 0.0)
      late = clear.state.fetch(:nodes).fetch(:blower).fetch(:carried_kg)

      expect(late).to be < early
    end
  end

  describe "ventilation" do
    # **The claim the whole subsystem exists for.** Same mine, same gas, one lever.
    it "holds the district at a trace with the fan running" do
      op = pit
      run!(op, 6_000)

      expect(gas_pct(op)).to be < 3.0
    end

    it "lets it build past the explosive limit with the fan stopped" do
      op = pit
      op.set_control(:ventilation, 0)
      run!(op, 6_000)

      expect(gas_pct(op)).to be > 5.0
    end

    it "clears a gassy district once the fan is restarted" do
      op = pit
      op.set_control(:ventilation, 0)
      run!(op, 3_000)
      gassy = gas_pct(op)
      expect(gassy).to be > 3.0

      op.set_control(:ventilation, 100)
      run!(op, 3_000, from: 3_000)

      expect(gas_pct(op)).to be < gassy
    end
  end

  describe "the flame cap" do
    # The instrument is prose and must stay prose. A number here would be a different game —
    # nobody in a pit measured 4.2%, they looked at the height of a blue cone.
    it "reads as prose rather than a figure" do
      op = pit
      run!(op, 400)

      expect(op.project(tick: 400).gauges.fetch(:flame_cap)).to be_a(String)
    end

    it "says there is no cap on a clear lamp and a tall one on a gassy district" do
      clear = pit
      run!(clear, 400)

      gassy = pit
      gassy.set_control(:ventilation, 0)
      run!(gassy, 6_000)

      expect(clear.project(tick: 400).gauges.fetch(:flame_cap)).to match(/no cap|trace/)
      expect(gassy.project(tick: 6_000).gauges.fetch(:flame_cap)).to match(/tall cap|firing/)
    end
  end

  describe "ignition" do
    it "does not light with safety lamps, however gassy it gets" do
      op = pit
      op.set_control(:ventilation, 0)
      events = run!(op, 6_000)

      expect(gas_pct(op)).to be > 5.0
      expect(events.map { |e| e[:type] }).not_to include(:fire_lit)
      expect(op.state.fetch(:nodes).fetch(:district)[:failure]).to be_nil
    end

    # **The decision the whole period turns on.** Naked lights are not a fitting you buy, they
    # are a standing order to the shift — and the entire cost of them is that the district then
    # contains a flame.
    it "lights with naked lights in a gassy district" do
      op = pit
      op.set_control(:ventilation, 0)
      run!(op, 2_000)
      op.set_control(:naked_flame, 100)
      events = run!(op, 2_000, from: 2_000)

      expect(events.map { |e| e[:type] }).to include(:fire_lit)
    end

    it "wrecks the district when it goes up" do
      op = pit
      op.set_control(:ventilation, 0)
      op.set_control(:naked_flame, 100)
      events = run!(op, 4_000)

      failed = events.select { |e| e[:type] == :part_failed }
      expect(failed.map { |e| e[:node] }).to include(:district)
      expect(op.state.fetch(:nodes).fetch(:district)[:failure]).to be(:rupture)
    end

    # The point of all of it. An explosion in an empty district hurts nobody, which is correct
    # and is why this example puts the shift underground first.
    it "hurts the people who were down there" do
      op = manned(pit)
      expect(station_of(op, :crew_1)).to be(:hewing)

      op.set_control(:ventilation, 0)
      op.set_control(:naked_flame, 100)
      events = run!(op, 4_000, from: 1_600)

      hurt = events.select { |e| e[:type] == :minion_hurt }
      expect(hurt).not_to be_empty
      expect(hurt.map { |e| e[:node] }).to include(:crew_1)
      expect(op.state.fetch(:minions).fetch(:crew_1)[:injury]).not_to be_nil
    end

    # **Asserted on resilience rather than on an event**, and the difference is the point: a
    # hazard that gets through somebody's resistance always costs them, but it only becomes an
    # *injury* when the bite crosses a tier. The putter is a long way from the face and is not
    # safe — he takes the blast and walks away from it, this time. A spec demanding an event
    # here would be demanding that the pit bottom be as lethal as the face, which it is not.
    it "reaches the pit bottom as well as the face" do
      op = manned(pit)
      expect(station_of(op, :crew_2)).to be(:haulage)
      intact = op.state.fetch(:minions).fetch(:crew_2).fetch(:resilience)

      op.set_control(:ventilation, 0)
      op.set_control(:naked_flame, 100)
      run!(op, 4_000, from: 1_600)

      expect(op.state.fetch(:minions).fetch(:crew_2).fetch(:resilience)).to be < intact
    end
  end

  describe "conservation" do
    # The explosion is a reaction like any other and has to balance like one.
    it "holds through ignition, rupture and everything after it" do
      op = pit
      op.set_control(:ventilation, 0)
      op.set_control(:naked_flame, 100)
      mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

      run!(op, 4_000)

      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      expect((mass - mass0).abs / mass0.abs).to be < 1e-9, "mass drifted by #{mass - mass0}"
      expect((joules - joules0).abs / joules0.abs).to be < 1e-9,
        "energy drifted by #{joules - joules0}"
    end
  end
end
