# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"
require "support/conservation"

# The mine, end to end.
#
# The second operation, and the first that **buys** its power: everything that costs anything
# hangs off one line shaft turned from somewhere else, so the interesting failures are all
# variations on "the supply went away".
#
# Driven from a steady supply rather than from a real engine — the coupling itself is proved in
# `coupling_spec`, and a mine spec that first has to raise steam is measuring the wrong machine.
#
# ## This file owns the walk, and that is why it is the one that cannot be constructed
#
# Every other mine spec now starts its shift at the face with `at_the_face`, which writes the
# arrival straight into state. That is sound only while a real walk still gets there — a
# constructed arrival cannot fail when the walking breaks. So the guards live here:
#
# - a **complete** walk, start to station. The putter's is 167 ticks by cage, which exercises
#   posting, travel, arrival and taking up a station on the whole of the same machinery the face
#   crew use over a longer road.
# - the face crew's journey **advancing**, since theirs is 834 ticks by cage and 1,267 down the
#   ladderway, and watching it tick down is the same claim as watching it finish.
# - a constructed arrival being **field-for-field identical** to a walked one, which is what makes
#   `at_the_face` honest everywhere else.
#
# See `docs/design_sketches/mine.md` §4.6 stage C and `design_sketches/suite-runtime.md` §7.
RSpec.describe "the mine" do
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  # No cage by default: this spec is partly *about* the walk, so the shift goes down the
  # ladderway and `describe "the shift has to get there"` has something to measure.
  def mine(**opts) = build_pit(id: "m", seed: 11, **opts)

  def caged = mine(loadout: { manriding: :cage_gear })

  # Send the shift underground the long way, and open everything up.
  def work!(op)
    op.assign_minion(:crew_1, :hewing)
    op.assign_minion(:crew_2, :haulage)
    op.set_control(:hewing, 100)
    op.set_control(:haulage, 100)
    op.set_control(:winding, 100)
    op
  end

  def working(ticks, **opts)
    op = work!(mine(**opts))
    run!(op, ticks)
    op
  end

  # A pit already at work, for the claims that are not about getting there.
  def worked(ticks, hewing: 100, supply: PitRig::SUPPLY_J, from: 0, **levers)
    op = at_the_face(mine)
    levers!(op, hewing: hewing, haulage: 100, timbering: 100, winding: 100, pumping: 100,
                ventilation: 100, **levers)
    [ op, run!(op, ticks, supply: supply, from: from) ]
  end

  it "builds with a shaft, a circuit, a seam and somewhere to stand" do
    op = mine

    expect(op.layout.places).to contain_exactly(:bank, :pit_bottom, :district)
    expect(op.control_points.keys).to include(:hewing, :haulage, :winding, :ventilation,
                                              :pumping, :quarters)
    expect(held(op, :seam, :coal)).to be > 0.0
  end

  describe "the shift has to get there" do
    # The claim the whole spatial release exists for. A mine is not an engine: the levers that
    # matter are at the far end of a shaft and a road, and nobody is at them yet.
    it "leaves nobody at the face on the tick they are sent" do
      op = work!(mine)

      expect(crew(op, :crew_1)[:posting]).to be(:hewing)
      expect(crew(op, :crew_1)[:station]).to be_nil
      expect(crew(op, :crew_1)[:place]).to be(:bank)
    end

    it "wins no coal at all until somebody is actually at the face" do
      op = working(200)

      expect(crew(op, :crew_1)[:station]).to be_nil
      expect(op.ledger.fetch(:mass_delivered)).to be > 0.0 # water, which needs nobody
      expect(held(op, :seam, :coal)).to eq(90_000.0)
    end

    # **A walk, all the way through.** The putter's road is the short one — 167 ticks by cage
    # against the hewer's 834 — and it is a *complete* journey rather than a shortened one, so it
    # exercises every part of the machinery the longer roads use.
    it "puts a hand at their post once their walk is done" do
      op = caged
      op.set_control(:winding, 100)
      op.set_control(:man_winding, 100)
      op.assign_minion(:crew_2, :haulage)
      run!(op, 200)

      expect(crew(op, :crew_2)[:place]).to be(:pit_bottom)
      expect(crew(op, :crew_2)[:station]).to be(:haulage)
    end

    # And the long road, asserted as it is being walked. 290 m at the hewer's pace is well over a
    # thousand ticks, so what is checkable quickly is that the distance is going down.
    it "walks the face crew down a road that takes them a good while" do
      op = work!(mine)
      remaining = (1..4).map do |leg|
        run!(op, 50, from: (leg - 1) * 50)
        crew(op, :crew_1).fetch(:remaining)
      end

      expect(crew(op, :crew_1)[:station]).to be_nil, "the hewer should still be on the road"
      expect(remaining.each_cons(2).all? { |far, nearer| nearer < far }).to be(true),
                                                                           remaining.inspect
    end

    # **What makes `at_the_face` legitimate in every other mine spec.** If the walk ever stops
    # producing this state, the constructed one diverges and this fails — which is the only way a
    # suite built on constructed arrivals can notice.
    it "arrives in exactly the state at_the_face constructs" do
      walked = caged
      walked.set_control(:winding, 100)
      walked.set_control(:man_winding, 100)
      walked.assign_minion(:crew_2, :haulage)
      run!(walked, 200)

      built = at_the_face(caged, hewing: nil, timbering: nil)

      %i[posting station place progress remaining journey].each do |field|
        expect(crew(built, :crew_2).fetch(field)).to eq(crew(walked, :crew_2).fetch(field)),
                                                     "#{field} differs"
      end
    end

    # **Except for the ones who are already down.** A pit whose every hand starts at bank is a pit
    # where the opening five minutes of a match are a walk, so the last seats are an advance shift
    # standing in the district when the whistle goes.
    describe "the advance shift" do
      it "is already in the district, posted to nothing" do
        op = mine
        below = op.state.fetch(:minions).select { |_, s| s[:place] == :district }

        expect(below.keys).to eq(%i[crew_8 crew_9 crew_10])
        expect(below.values.map { |s| s[:posting] }).to all(be_nil)
      end

      # The point of them: coal on the first tick they are told to cut, with no walk first.
      it "takes up a face post on the spot, where a hand at bank cannot" do
        op = mine
        op.assign_minion(:crew_8, :hewing)
        op.step!(tick: 1)

        expect(crew(op, :crew_8)[:station]).to be(:hewing)
        expect(crew(op, :crew_1)[:place]).to be(:bank)
      end
    end
  end

  describe "output" do
    it "cuts coal and sends it to the surface" do
      op, = worked(100)

      expect(held(op, :seam, :coal)).to be < 90_000.0
      expect(op.ledger.fetch(:mass_delivered)).to be > 0.0
      # **Not the winder's `carried_kg`**, which is what one tick happened to be carrying. A
      # winder's output is a cycle rather than a flow and there are always ticks with nothing on
      # the rope, so an instantaneous reading is a coin toss dressed as an assertion. The ledger
      # is the measurement; `coal_raised` averages over twelve ticks for the same reason.
    end

    # A ratio rather than a figure: the shape is what is being asserted, not the balance.
    # Measured at 100 ticks: 16.80 kg against 6.72.
    it "cuts more with the lever further over" do
      hard, = worked(100, hewing: 100)
      easy, = worked(100, hewing: 40)

      expect(90_000.0 - held(hard, :seam, :coal)).to be > (90_000.0 - held(easy, :seam, :coal))
    end

    it "is the first thing in the game to write mass_delivered" do
      op, = worked(100)

      expect(op.ledger.fetch(:mass_delivered)).to be > 0.0
    end
  end

  describe "when the supply fails" do
    # The mine's signature failure, and the reason drainage is on the same shaft as everything
    # else: stop paying and the water starts winning.
    #
    # **The shaft is seeded stopped**, because a line shaft coasts on its own inertia for a good
    # while after the supply goes — which is the behaviour the buffer exists to give, and which
    # made this a 2,500-tick example. What is claimed is what happens once it *has* run down.
    # Measured at 200 ticks: 45.6 kg of water against a paid pit's 0.24.
    it "drowns the workings once the pump stops" do
      paid, = worked(200)
      unpaid = at_the_face(seed(mine, nodes: { line_shaft: { angular_momentum: 0.0 } }))
      levers!(unpaid, hewing: 100, haulage: 100, timbering: 100, winding: 100, pumping: 100,
                      ventilation: 100)
      run!(unpaid, 200, supply: 0.0)

      expect(omega(unpaid)).to be < 1.0
      expect(held(paid, :pit_bottom, :water)).to be < 5.0
      expect(held(unpaid, :pit_bottom, :water)).to be > 20.0
    end

    # A winding drum is positive displacement: it raises coal because it is turning, and at rest
    # raises none. Without `displacement:` on the fitting, `driven_by:` is only a *bill* — the pump
    # lifted its water 90 m for nothing with the shaft stopped, and the winder did the same.
    it "stops raising coal, because a drum that is not turning raises nothing" do
      op = at_the_face(seed(mine, nodes: { line_shaft: { angular_momentum: 0.0 } }))
      levers!(op, hewing: 100, haulage: 100, timbering: 100, winding: 100, pumping: 100,
                  ventilation: 100)
      before = op.ledger.fetch(:mass_delivered)
      run!(op, 100, supply: 0.0)

      expect(omega(op)).to be < 0.5
      expect(op.state.fetch(:nodes).fetch(:winder).fetch(:carried_kg)).to be < 0.01
      expect(op.ledger.fetch(:mass_delivered) - before).to be < 1.0
    end
  end

  describe "ventilation" do
    it "courses air from the downcast round the workings and out through the fan" do
      op, = worked(200)

      expect(op.state.fetch(:nodes).fetch(:upcast).fetch(:carried_kg)).to be > 0.0
      expect(op.ledger.fetch(:mass_added)).to be > 0.0
      expect(op.ledger.fetch(:mass_vented)).to be > 0.0
    end
  end

  # **A pit whose numbers are identical every match is a pit you learn once.** How fiery a panel
  # is, how sour the waste runs and how wet the strata is are properties of the ground, drawn when
  # the match is made — so an overseer has to feel out which colliery they were given rather than
  # apply a remembered counter-measure. All build-time, so all free.
  describe "the ground" do
    def ground(seed, node)
      ReactorSim::Match
        .create(id: "g", seed: seed, operations: [ { id: "pit", type: :mine } ])
        .operation(:pit).state.fetch(:nodes).fetch(node).fetch(:ground)
    end

    it "gives two matches different ground" do
      expect(ground(11, :blower)).not_to eq(ground(12, :blower))
    end

    # **Its own RNG stream per node**, so a fiery pit is not also a wet one — otherwise one
    # reading would tell a player everything and the variation would buy nothing.
    it "varies each seep independently of the others" do
      seeds = (1..12).map { |s| [ ground(s, :blower), ground(s, :goaf_seep) ] }
      firedamp, blackdamp = seeds.transpose

      expect(firedamp.each_with_index.max[1]).not_to eq(blackdamp.each_with_index.max[1])
    end

    # Entropy at `initial_state` only, which is what keeps it replayable: the same seed is the
    # same mine, every time, on any machine.
    it "is the same mine for the same seed" do
      expect(ground(7, :seepage)).to eq(ground(7, :seepage))
    end

    # The waste makes a little carbon monoxide on its own, and how much is the ground's business
    # too — a sour goaf is a pit where the canary is the only warning there will be.
    it "varies how sour the old workings are" do
      sour = (1..10).map do |seed|
        parcels = ReactorSim::Match
                  .create(id: "g", seed: seed, operations: [ { id: "pit", type: :mine } ])
                  .operation(:pit).state.fetch(:nodes).fetch(:goaf).fetch(:parcels)
        ReactorSim::Parcel.total_kg(parcels.select { |p| p[:resource] == :whitedamp })
      end

      expect(sour.uniq.length).to be > 1
      expect(sour.min).to be < sour.max
    end
  end

  describe "conservation" do
    # The spec that catches real physics bugs. It found two here: air reversing out of the
    # downcast into a port nothing was counting, and a pump lifting water for free with the shaft
    # stopped.
    it "holds through a shift of cutting, winding and pumping" do
      op = at_the_face(mine)
      mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

      levers!(op, hewing: 100, haulage: 100, timbering: 100, winding: 100, pumping: 100,
                  ventilation: 100)
      run!(op, 200)

      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      expect((mass - mass0).abs / mass0.abs).to be < Conservation::TOLERANCE,
                                                "mass drifted by #{mass - mass0}"
      expect((joules - joules0).abs / joules0.abs).to be < Conservation::TOLERANCE,
                                                      "energy drifted by #{joules - joules0}"
    end

    # **The walk is on the ledger too**, so this one deliberately does not construct the arrival:
    # a shift travelling is mass and energy moving about, and it is the path `at_the_face` skips.
    it "holds with the shift still walking and the supply cut" do
      op = work!(mine)
      mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)

      run!(op, 100)
      run!(op, 100, supply: 0.0, from: 100)

      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      expect((mass - mass0).abs / mass0.abs).to be < Conservation::TOLERANCE
    end
  end

  it "runs a shift at moderate settings with nothing to report" do
    _, events = worked(200, hewing: 50, haulage: 50)

    expect(events).to be_empty
  end

  describe "snapshot" do
    it "round-trips chassis, loadout and a shift part-way down the shaft" do
      op = working(100)

      restored = ReactorSim::Operation.from_h(
        ReactorSim.deep_symbolize(JSON.parse(JSON.generate(op.to_h)))
      )

      expect(restored.options.fetch(:chassis)).to be(:two_shaft)
      expect(restored.options.fetch(:loadout).fetch(:winder)).to be(:steam_whim)
      expect(restored.state.fetch(:minions).fetch(:crew_1)[:posting]).to be(:hewing)
      expect(ReactorSim.canonical(restored.to_h)).to eq(ReactorSim.canonical(op.to_h))
    end

    it "carries on identically after a restore" do
      op = working(100)
      restored = ReactorSim::Operation.from_h(
        ReactorSim.deep_symbolize(JSON.parse(JSON.generate(op.to_h)))
      )

      run!(op, 200, from: 100)
      run!(restored, 200, from: 100)

      expect(ReactorSim.canonical(restored.to_h)).to eq(ReactorSim.canonical(op.to_h))
    end
  end
end
