# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **The cage: buying your way out of the walk.**
#
# The spatial model made distance expensive; this is the purchase that makes it cheaper. A
# ladderway is free and awful. A cage is a drum and two balanced cages on the line shaft, wound by an
# engineman to wherever the player names — so it is a way down only while somebody is winding it and
# the shaft is turning, and what it costs is the load in it.
#
# Its own crew for the same reason `firedamp_spec` has one: these examples time journeys, and a
# day-labourer's pace turns every figure into a measurement of the labour exchange. The cage is wound
# by a banksman (`PitRig#wind!`), with `WOUND_CREW`'s engineman at the post.
#
# ## How far they have got, not how long they took
#
# A journey does not have to be finished to be measured. How far down the road the putter has got:
#
#     after    20t    40t    60t    80t
#     ladders  3.00   6.00   9.00  12.00
#     rod      3.00   6.99  13.55  20.47
#     cage     7.01  24.34  43.94  63.96
#
# Sixty ticks is where the ordering is clean; at twenty the man engine is still indistinguishable
# from the ladders.
RSpec.describe "the cage" do
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  def pit(manriding: :cage_gear, wound: false)
    op = build_pit(id: "c", seed: 3, loadout: { manriding: manriding || :none },
                   crew: PitRig::WOUND_CREW)
    op.set_control(:winding, 100)
    engineman!(op) if wound
    op
  end

  # How far along their road a hand has got after `ticks`. The putter's post, at the near end.
  def progress_after(op, ticks, supply: PitRig::SUPPLY_J)
    op.set_control(:man_winding, 100) if op.nodes.fetch(:cage_drive, nil).is_a?(ReactorSim::Nodes::Load)
    op.assign_minion(:crew_1, :haulage)
    run!(op, ticks, supply: supply, wind: true)

    op.state.fetch(:minions).fetch(:crew_1).fetch(:progress)
  end

  describe "the man-riding slot" do
    # **Where every mine starts.** Man riding is its own slot rather than a property of the winder,
    # because raising coal and raising men are different machines. Empty is legal and means the
    # ladders.
    it "leaves a mine with nothing fitted to its ladders" do
      op = pit(manriding: nil)

      expect(op.control_points).not_to have_key(:man_winding)
      expect(op.layout.passages.map(&:label)).to contain_exactly("Ladderway", "Main Road")
    end

    it "gives a fitted cage a way through the shaft and a post to wind it from" do
      op = pit

      expect(op.control_points).to have_key(:man_winding)
      expect(op.layout.passages.map(&:label)).to include("Cage")
    end

    it "offers a man engine between the two" do
      rod = pit(manriding: :man_engine)

      expect(rod.layout.passages.map(&:label)).to include("Man Engine")
      expect(rod.layout.passages.find { |p| p.label == "Man Engine" }.speed_m_s)
        .to be_between(0.6, 4.2).exclusive
    end
  end

  describe "riding it" do
    # Fitting a cage takes nothing away: with nobody winding it, it is not a way down at all, and
    # the shift takes the ladders **bit for bit** as a pit with no cage does.
    it "leaves them on the ladders while nobody is winding it" do
      bare = progress_after(pit(manriding: nil), 10)
      unwound = progress_after(pit, 10)

      expect(unwound).to eq(bare)
    end

    # The whole tech tree in one assertion, at 60 ticks: 9.00 m, 13.55 m, 43.94 m.
    it "gets them down quicker the better the gear is" do
      got = [ pit(manriding: nil), pit(manriding: :man_engine), pit(wound: true) ]
            .map { |op| progress_after(op, 60) }

      expect(got.each_cons(2).all? { |slower, faster| faster > slower }).to be(true), got.inspect
    end

    it "gets them down far quicker with somebody winding it" do
      wound = progress_after(pit(wound: true), 40)
      unwound = progress_after(pit, 40)

      expect(wound).to be > unwound * 3.0
    end
  end

  # **The cages are in balance, so what costs is what is in them.** Four hands aboard at the bottom
  # landing, wound up or down, against the same wind empty. Constructed aboard, because how they
  # got there is the riding examples' business.
  #
  # **Small, and measured as small**: 280 kg of hands is 174.25 rpm against 174.32 empty. Men are
  # light against a balanced drum; a laden coal deck is what makes the shaft feel a cage.
  describe "what it costs" do
    def aboard(place)
      %i[crew_1 crew_2 crew_3 crew_4].to_h do |seat|
        [ seat, { via: :cage_drive, place: place, posting: nil, station: nil } ]
      end
    end

    def winding(from_m, to_pct, laden:)
      op = pit(wound: true)
      place = from_m.zero? ? :bank : :pit_bottom
      op = seed(op, nodes: { cage_drive: { position_m: from_m } },
                    minions: laden ? aboard(place) : {})
      op.set_control(:man_winding, to_pct)
      run!(op, 40)
      op
    end

    it "loads the line shaft while a laden deck is raised" do
      laden = winding(90.0, 0, laden: true)
      empty = winding(90.0, 0, laden: false)

      expect(rpm(laden)).to be < rpm(empty)
      expect(laden.nodes.fetch(:cage_drive).position_m(laden.state.dig(:nodes, :cage_drive)))
        .to be < 90.0, "the laden cage never left the bottom"
    end

    # And the other way: a laden deck going down drives the shaft rather than costing it.
    it "gives the shaft work back while a laden deck is lowered" do
      laden = winding(0.0, 100, laden: true)
      empty = winding(0.0, 100, laden: false)

      expect(rpm(laden)).to be > rpm(empty)
    end
  end

  describe "when the supply fails" do
    # A cage with no power behind it is not a way down, so nobody boards it — but the ladders are
    # still there, which is why nobody is ever completely stranded. Awful, and survivable.
    it "falls back to the ladders rather than stranding the shift" do
      starved = progress_after(pit(wound: true), 40, supply: 0.0)
      laddered = progress_after(pit(manriding: nil), 40)

      expect(starved).to be > 0.0, "a stopped cage must not strand the shift"
      expect(starved).to be_within(1e-6).of(laddered)
    end
  end

  it "conserves mass and energy with the cage running" do
    op = pit(wound: true)
    op.assign_minion(:crew_1, :hewing)
    mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

    run!(op, 50, wind: true)

    mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    expect((mass - mass0).abs / mass0.abs).to be < 1e-9, "mass drifted by #{mass - mass0}"
    expect((joules - joules0).abs / joules0.abs).to be < 1e-9,
           "energy drifted by #{joules - joules0}"
  end
end
