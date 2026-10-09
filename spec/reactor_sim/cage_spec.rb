# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **The cage: buying your way out of the walk.**
#
# The spatial model made distance expensive; this is the purchase that makes it cheaper, and it is
# the reason the whole thing was worth building. A ladderway is free and awful. A cage is quick and
# hangs off the same line shaft as the fan, the pump and the winder — so calling it takes something
# away from all three.
#
# Its own crew for the same reason `firedamp_spec` has one: these examples time journeys, and a
# day-labourer's pace turns every figure into a measurement of the labour exchange.
#
# **The journeys here are real and timed, not constructed**, because the time *is* the claim — and
# they are cheap because the post being timed is the putter's, at the near end of the road. The
# ladderway takes 600 ticks, the man engine 281 and the cage 167, which is the whole tech tree
# inside one short window. (The face posts are 1,267 and 834 and would say nothing more.)
#
# See `docs/design_sketches/mine.md` §4.6 stage E.
RSpec.describe "the cage" do
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  def pit(manriding: :cage_gear)
    op = build_pit(id: "c", seed: 3, loadout: { manriding: manriding || :none })
    op.set_control(:winding, 100)
    op
  end

  # Ticks until `seat` is actually working `station`, or nil. The limit is a ceiling rather than a
  # duration: the putter's longest road is the ladderway's 600.
  def ticks_to_arrive(op, seat, station, limit: 800, supply: PitRig::SUPPLY_J)
    op.assign_minion(seat, station)
    limit.times do |i|
      op.receive_supply(:line_shaft, supply)
      op.step!(tick: i + 1)
      return i + 1 if op.state.fetch(:minions).fetch(seat)[:station] == station
    end
    nil
  end

  describe "the man-riding slot" do
    # **Where every mine starts.** Man riding is its own slot rather than a property of the winder,
    # because raising coal and raising men are different machines — a man engine winds no coal at
    # all. Empty is legal and means the ladders.
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

    # The tier between ladders and a cage, and the machine the research is fondest of: at Tresavean
    # it cut the journey from an hour to twenty-four minutes.
    it "offers a man engine between the two" do
      rod = pit(manriding: :man_engine)

      expect(rod.layout.passages.map(&:label)).to include("Man Engine")
      expect(rod.layout.passages.find { |p| p.label == "Man Engine" }.speed_m_s)
        .to be_between(0.6, 4.2).exclusive
    end
  end

  describe "riding it" do
    # The ladderway is always there, so fitting a cage takes nothing away — it only adds a faster
    # way that has to be called for.
    it "leaves them on the ladders while nobody calls it" do
      bare = ticks_to_arrive(pit(manriding: nil), :crew_1, :haulage)
      idle = ticks_to_arrive(pit, :crew_1, :haulage)

      expect(idle).to eq(bare)
    end

    # The whole tech tree in one assertion: each tier is quicker than the last. 600 / 281 / 167.
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
    # **The men-or-air choice**, which is where the cost actually landed. The cage is on the same
    # line shaft as the fan, so calling it slows the shaft and the fan slows with it — and the
    # district gets gassier while the shift is being wound. Historically exact: a winding engine
    # and a fan competed for the same boiler.
    def idle_and_busy(ticks)
      idle = pit
      busy = pit
      busy.set_control(:man_winding, 100)
      run!(idle, ticks)
      run!(busy, ticks)
      [ idle, busy ]
    end

    # Measured at 50 ticks: 177.15 rpm against 143.19.
    it "loads the line shaft" do
      idle, busy = idle_and_busy(50)

      expect(rpm(busy)).to be < rpm(idle)
    end

    # **The mechanism, measured where it happens.** A slower shaft is a slower fan, so the air
    # crossing the upcast falls the moment the cage is called — 2.619 kg/tick to 1.686, a third of
    # the ventilation gone — and the gas in the district follows from that rather than the other
    # way round.
    it "takes air away from the workings while it runs" do
      idle, busy = idle_and_busy(50)

      expect(busy.state.fetch(:nodes).fetch(:upcast).fetch(:carried_kg))
        .to be < idle.state.fetch(:nodes).fetch(:upcast).fetch(:carried_kg) * 0.8
    end

    # And the consequence a player reads off a gauge, which needs a little longer because the gas
    # has to accumulate against the weaker fan: 0.573% against 0.606% at 200 ticks.
    it "leaves the district gassier for having wound the shift" do
      idle, busy = idle_and_busy(200)

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

    run!(op, 200)

    mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    expect((mass - mass0).abs / mass0.abs).to be < 1e-9, "mass drifted by #{mass - mass0}"
    expect((joules - joules0).abs / joules0.abs).to be < 1e-9,
           "energy drifted by #{joules - joules0}"
  end
end
