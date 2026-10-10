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
# ## How far they have got, not how long they took
#
# The journeys are real — the time *is* the claim here — but a journey does not have to be
# **finished** to be measured. Timing arrivals meant 600 ticks for the ladderway, 281 for the man
# engine and 167 for the cage, three times over; reading how far down the road each one is after
# sixty ticks says the same thing and is strictly ordered by then:
#
#     after    20t    40t    60t    80t
#     ladders  3.00   6.00   9.00  12.00
#     rod      3.00   6.99  13.55  20.47
#     cage     3.24  11.37  23.96  36.53
#
# **Twenty ticks is too early and that is worth knowing**: all three are still on the first leg of
# the road, so the gear has not come into it and the man engine is indistinguishable from the
# ladders. Sixty is where the ordering is clean.
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

  # How far along their road a hand has got after `ticks`, with the gear called or left standing.
  # The putter's post, at the near end: the face crew's road is longer and says nothing more.
  def progress_after(op, ticks, called: true, supply: PitRig::SUPPLY_J)
    op.set_control(:man_winding, 100) if called && op.control_points.key?(:man_winding)
    op.assign_minion(:crew_1, :haulage)
    run!(op, ticks, supply: supply)

    op.state.fetch(:minions).fetch(:crew_1).fetch(:progress)
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
    # way that has to be called for. **Bit-identical**, which is the strongest form of "takes
    # nothing away" and is true from the first tick.
    it "leaves them on the ladders while nobody calls it" do
      bare = progress_after(pit(manriding: nil), 10, called: false)
      idle = progress_after(pit, 10, called: false)

      expect(idle).to eq(bare)
    end

    # The whole tech tree in one assertion: each tier carries them further than the last.
    # Measured at 60 ticks — 9.00 m, 13.55 m, 23.96 m.
    it "gets them down quicker the better the gear is" do
      got = [ nil, :man_engine, :cage_gear ].map { |gear| progress_after(pit(manriding: gear), 60) }

      expect(got.each_cons(2).all? { |slower, faster| faster > slower }).to be(true), got.inspect
    end

    it "gets them down far quicker once it is called" do
      called = progress_after(pit, 40, called: true)
      standing = progress_after(pit, 40, called: false)

      expect(called).to be > standing * 1.5
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
    # **Asserted as "still walking", which is what not being stranded means.** The old form waited
    # for the arrival and checked it had taken the slow road; the same fact is visible at once in
    # the fact that they are making ladder-rate progress rather than none at all.
    it "falls back to the ladders rather than stranding the shift" do
      starved = progress_after(pit, 40, called: true, supply: 0.0)
      laddered = progress_after(pit(manriding: nil), 40, called: false)

      expect(starved).to be > 0.0, "a stopped cage must not strand the shift"
      expect(starved).to be_within(1e-6).of(laddered)
    end
  end

  it "conserves mass and energy with the cage running" do
    op = pit
    op.set_control(:man_winding, 100)
    op.assign_minion(:crew_1, :hewing)
    mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

    run!(op, 50)

    mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    expect((mass - mass0).abs / mass0.abs).to be < 1e-9, "mass drifted by #{mass - mass0}"
    expect((joules - joules0).abs / joules0.abs).to be < 1e-9,
           "energy drifted by #{joules - joules0}"
  end
end
