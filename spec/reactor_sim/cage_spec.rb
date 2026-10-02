# frozen_string_literal: true

require "reactor_sim"

# **The cage: buying your way out of the walk.**
#
# The spatial model made distance expensive; this is the purchase that makes it cheaper, and it
# is the reason the whole thing was worth building. A ladderway is free and awful. A cage is
# quick and hangs off the same line shaft as the fan, the pump and the winder — so calling it
# takes something away from all three.
#
# Its own crew for the same reason `firedamp_spec` has one: these examples time journeys, and a
# day-labourer's pace turns every figure into a measurement of the labour exchange.
#
# See `docs/design_sketches/mine.md` §4.6 stage E.
module CageCrew
  ARCHETYPE = { label: "Collier", strength: 1.0, toughness: 1.0, endurance: 1.0e6,
                intelligence: 1.0, dexterity: 1.0, charisma: 1.0,
                # `darkvision` because hewing and timbering are **gated** on light, not merely
                # aided by it: a fixture with no lamp cuts exactly nothing, which is the design
                # and a poor way to measure a cage.
                tags: { mining_effectiveness: 0.6, shovelling: 0.5,
                        darkvision: 0.8 } }.freeze

  MINIONS = (1..4).to_h { |i| [ :"hand_#{i}",
                                { name: "Hand #{i}", archetype: :collier,
                                  hireable: false } ] }.freeze

  CONTENT = ReactorSim::Content.default.merging(archetypes: { collier: ARCHETYPE },
                                                minions: MINIONS)

  CREW = (1..4).to_h { |i| [ :"crew_#{i}", { minion: :"hand_#{i}" } ] }.freeze
end

RSpec.describe "the cage" do
  before { allow(ReactorSim::Content).to receive(:default).and_return(CageCrew::CONTENT) }

  SUPPLY_J = 9.0e4

  def pit(manriding: :cage_gear)
    op = ReactorSim::Match
         .create(id: "c", seed: 3,
                 operations: [ { id: "pit", type: :mine,
                                 loadout: { manriding: manriding || :none },
                                 ground: ReactorSim::Operations::Mine::Ground::ORDINARY,
                                 crew: CageCrew::CREW } ])
         .operation(:pit)
    op.set_control(:winding, 100)
    op
  end

  def run!(op, ticks, from: 0, supply: SUPPLY_J)
    ticks.times do |i|
      op.receive_supply(:line_shaft, supply)
      op.step!(tick: from + i + 1)
    end
    op
  end

  # Ticks until `seat` is actually working `station`, or nil.
  def ticks_to_arrive(op, seat, station, limit: 6_000, supply: SUPPLY_J)
    op.assign_minion(seat, station)
    limit.times do |i|
      op.receive_supply(:line_shaft, supply)
      op.step!(tick: i + 1)
      return i + 1 if op.state.fetch(:minions).fetch(seat)[:station] == station
    end
    nil
  end

  def rpm(op)
    op.state.fetch(:nodes).fetch(:line_shaft).fetch(:angular_momentum) / 900.0 * 60 /
      (2 * Math::PI)
  end

  def gas_pct(op)
    parcels = op.state.fetch(:nodes).fetch(:district).fetch(:parcels)
    total = parcels.sum { |p| p.fetch(:kg) }
    return 0.0 unless total.positive?

    (parcels.find { |p| p.fetch(:resource) == :firedamp }&.fetch(:kg) || 0.0) / total * 100.0
  end

  describe "the man-riding slot" do
    # **Where every mine starts.** Man riding is its own slot rather than a property of the
    # winder, because raising coal and raising men are different machines — a man engine winds
    # no coal at all. Empty is legal and means the ladders.
    it "leaves a mine with nothing fitted to its ladders" do
      op = pit(manriding: nil)

      expect(op.control_points).not_to have_key(:man_winding)
      expect(op.layout.passages.map(&:label)).to contain_exactly("Ladderway", "Main Road")
    end

    it "gives a fitted cage a way through the shaft and a lever to call it" do
      op = pit

      expect(op.control_points).to have_key(:man_winding)
      expect(op.layout.passages.map(&:label)).to include("Cage")
    end

    # The tier between ladders and a cage, and the machine the research is fondest of: at
    # Tresavean it cut the journey from an hour to twenty-four minutes.
    it "offers a man engine between the two" do
      rod = pit(manriding: :man_engine)

      expect(rod.layout.passages.map(&:label)).to include("Man Engine")
      expect(rod.layout.passages.find { |p| p.label == "Man Engine" }.speed_m_s)
        .to be_between(0.6, 4.2).exclusive
    end
  end

  describe "riding it" do
    # The ladderway is always there, so fitting a cage takes nothing away — it only adds a
    # faster way that has to be called for.
    it "leaves them on the ladders while nobody calls it" do
      bare = ticks_to_arrive(pit(manriding: nil), :crew_1, :haulage)
      idle = ticks_to_arrive(pit, :crew_1, :haulage)

      expect(idle).to eq(bare)
    end

    # The whole tech tree in one assertion: each tier is quicker than the last.
    it "gets them down quicker the better the gear is" do
      ladders = ticks_to_arrive(pit(manriding: nil), :crew_1, :haulage)

      rod = pit(manriding: :man_engine)
      rod.set_control(:man_winding, 100)
      by_rod = ticks_to_arrive(rod, :crew_1, :haulage)

      cage = pit
      cage.set_control(:man_winding, 100)
      by_cage = ticks_to_arrive(cage, :crew_1, :haulage)

      expect(by_rod).to be < ladders
      expect(by_cage).to be < by_rod
    end

    it "gets them down far quicker once it is called" do
      walked = ticks_to_arrive(pit, :crew_1, :haulage)

      called = pit
      called.set_control(:man_winding, 100)
      rode = ticks_to_arrive(called, :crew_1, :haulage)

      expect(rode).to be < walked / 2
    end
  end

  describe "what it costs" do
    # **The men-or-air choice**, which is where the cost actually landed. The cage is on the
    # same line shaft as the fan, so calling it slows the shaft and the fan slows with it — and
    # the district gets gassier while the shift is being wound. Historically exact: a winding
    # engine and a fan competed for the same boiler.
    it "loads the line shaft" do
      idle = run!(pit, 3_000)

      busy = pit
      busy.set_control(:man_winding, 100)
      run!(busy, 3_000)

      expect(rpm(busy)).to be < rpm(idle)
    end

    it "takes air away from the workings while it runs" do
      idle = run!(pit, 4_000)

      busy = pit
      busy.set_control(:man_winding, 100)
      run!(busy, 4_000)

      expect(gas_pct(busy)).to be > gas_pct(idle)
    end
  end

  describe "when the supply fails" do
    # A cage that has stopped is not a slow way up, it is no way up — but the ladders are still
    # there, which is why nobody is ever completely stranded. Awful, and survivable.
    it "falls back to the ladders rather than stranding the shift" do
      op = pit
      op.set_control(:man_winding, 100)

      arrived = ticks_to_arrive(op, :crew_1, :haulage, supply: 0.0)

      expect(arrived).not_to be_nil
      expect(arrived).to be > 400
    end
  end

  it "conserves mass and energy with the cage running" do
    op = pit
    op.set_control(:man_winding, 100)
    op.assign_minion(:crew_1, :hewing)
    mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

    run!(op, 3_000)

    mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    expect((mass - mass0).abs / mass0.abs).to be < 1e-9, "mass drifted by #{mass - mass0}"
    expect((joules - joules0).abs / joules0.abs).to be < 1e-9,
      "energy drifted by #{joules - joules0}"
  end
end
