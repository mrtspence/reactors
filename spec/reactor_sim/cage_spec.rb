# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **The cage: buying your way out of the walk.**
#
# The spatial model made distance expensive; this is the purchase that makes it cheaper. A
# ladderway is free and awful. Every pit has a hoist — the starting whim's kibble, or a cage — a drum
# and two balanced cages on the line shaft, wound by an engineman to wherever the player names; so
# it is a way down only while somebody is winding it and the shaft is turning, and what it costs is
# the load in it. A man engine is a separate fitting beside it.
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
#     kibble   0.97   8.84  17.54  26.39
#     cage     1.88  17.82  35.86  54.29
#
# Sixty ticks is where the ordering is clean: at twenty the man engine is still indistinguishable
# from the ladders, and the hoists are behind both while their riders take three seconds to get in.
RSpec.describe "the cage" do
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  def pit(winder: :cage_gear, manriding: nil, wound: false)
    op = build_pit(id: "c", seed: 3, loadout: { winder: winder, manriding: manriding || :none },
                   crew: PitRig::WOUND_CREW)
    engineman!(op) if wound
    op
  end

  # How far along their road a hand has got after `ticks`. The putter's post, at the near end.
  def progress_after(op, ticks, supply: PitRig::SUPPLY_J)
    op.set_control(:rods, 100) if op.control_points.key?(:rods)
    op.assign_minion(:crew_1, :haulage)
    run!(op, ticks, supply: supply, wind: true)

    op.state.fetch(:minions).fetch(:crew_1).fetch(:progress)
  end

  describe "the hoist and the man-riding slot" do
    # **Where every mine starts**: a steam whim, whose kibble is a way down for men who will stand
    # in a bucket. A cage is the same post and a better way.
    it "gives every pit a hoist to ride and a post to wind it from" do
      expect(pit(winder: :steam_whim).layout.passages.map(&:label)).to include("Kibble")
      expect(pit.layout.passages.map(&:label)).to include("Cage")
      expect(pit(winder: :steam_whim).control_points).to have_key(:man_winding)
    end

    it "offers a man engine beside it, as its own fitting" do
      rod = pit(manriding: :man_engine)

      expect(rod.layout.passages.map(&:label)).to include("Man Engine", "Cage")
      expect(rod.layout.passages.find { |p| p.label == "Man Engine" }.speed_m_s)
        .to be_between(0.6, 4.2).exclusive
    end
  end

  describe "riding it" do
    # With nobody winding it, a hoist is not a way down at all, and the shift takes the ladders
    # **bit for bit** whichever hoist it is.
    it "leaves them on the ladders while nobody is winding it" do
      kibble = progress_after(pit(winder: :steam_whim), 10)
      cage = progress_after(pit, 10)

      expect(cage).to eq(kibble)
    end

    # The whole tech tree in one assertion, at 60 ticks: 9.00 m, 13.55 m, 35.86 m.
    it "gets them down quicker the better the gear is" do
      got = [ pit, pit(manriding: :man_engine), pit(wound: true) ]
            .map { |op| progress_after(op, 60) }

      expect(got.each_cons(2).all? { |slower, faster| faster > slower }).to be(true), got.inspect
    end

    it "gets them down far quicker with somebody winding it" do
      wound = progress_after(pit(wound: true), 60)
      unwound = progress_after(pit, 60)

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
      laddered = progress_after(pit, 40)

      expect(starved).to be > 0.0, "a stopped cage must not strand the shift"
      expect(starved).to be_within(1e-6).of(laddered)
    end
  end

  # **The man engine's own accidents.** A missed step every stroke, more the faster it runs; a
  # strap that wears per stroke and per man and tears out at a hard overspeed; and catches that
  # hold a rod whose strap wore through but not one torn out. Constructed states, a few ticks each.
  describe "the man engine" do
    def rods(part = :man_engine) = build_pit(id: "r", seed: 1, chassis: :single_shaft,
                                             loadout: { manriding: part })

    def rod(op) = op.nodes.fetch(:man_engine)

    # The line shaft and the rod both turning at `over` × rated, with a man part-way down it.
    def running(part, over:, strap: 1.0, rider: :crew_1, margin: nil)
      op = rods(part)
      line = op.nodes.fetch(:line_shaft)
      omega = rod(op).rated_omega * over
      durability = strap * op.state.dig(:nodes, :man_engine, :initial_durability)
      op = seed(op, nodes: { line_shaft: { angular_momentum: line.moment_of_inertia * omega },
                             man_engine: { angular_momentum: rod(op).moment_of_inertia * omega,
                                           durability: durability } },
                    minions: { rider => { place: :bank, posting: :haulage, progress: 30.0,
                                          riding: :man_engine, margin: margin }.compact })
      op.set_control(:rods, 100.0)
      op
    end

    def failed(events) = events.find { |e| e[:type] == :part_failed && e[:node] == :man_engine }

    it "carries somebody part-way down it as a rider of the rods" do
      line = rods.nodes.fetch(:line_shaft)
      op = seed(rods, nodes: { line_shaft: { angular_momentum: line.moment_of_inertia * 20.0 } },
                      controls: { rods: { target: 100.0, actual: 100.0 } })
      op.assign_minion(:crew_1, :haulage)
      run!(op, 20)

      expect(op.state.dig(:minions, :crew_1, :riding)).to be(:man_engine)
    end

    it "makes a missed step likelier the faster it strokes" do
      man_engine = rod(rods)
      working = { angular_momentum: man_engine.moment_of_inertia * man_engine.rated_omega }
      surging = { angular_momentum: working[:angular_momentum] * 1.3 }

      expect(man_engine.activity(surging, :strokes, 0.25)).to be > man_engine.activity(working, :strokes, 0.25)
      expect(man_engine.perils.map(&:riders)).to all(include(:man_engine))
    end

    it "costs a man on the rods a missed step when his margin runs out" do
      events = run!(running(:man_engine, over: 1.0, margin: 1.0e-9), 3)

      expect(events.find { |e| e[:type] == :minion_hurt && e[:node] == :crew_1 }).to include(cause: :misstep)
    end

    it "wears its strap faster with men on it" do
      man_engine = rod(rods)
      state = { angular_momentum: man_engine.moment_of_inertia * man_engine.rated_omega }
      ctx = ->(kg) { ReactorSim::Tick::Context.new(controls: {}, dt: 0.25, cargo: { man_engine: kg }) }

      expect(man_engine.stress_per_second(state, ctx.call(280.0)))
        .to be > man_engine.stress_per_second(state, ctx.call(0.0))
    end

    it "tears a worn strap out at an overspeed, and keeps it at working speed" do
      outcomes = [ 1.0, 1.5 ].map { |over| failed(run!(running(:man_engine, over: over, strap: 0.3), 6)) }

      expect(outcomes.first).to be_nil
      expect(outcomes.last).to include(mode: :torn_out, cause: :overload)
    end

    it "takes its load off the line shaft, and the shaft with it, when it goes" do
      op = running(:man_engine, over: 1.5, strap: 0.3)
      before = op.state.dig(:nodes, :shaft, :durability)
      run!(op, 6)

      expect(op.state.dig(:nodes, :shaft, :durability)).to be < before
      expect(op.state.dig(:nodes, :brattice, :durability)).to be < op.state.dig(:nodes, :brattice, :initial_durability)
    end

    # **Levant, by mode.** Catches hold a rod whose strap wore through; one torn out by an overspeed
    # takes them out of line with it.
    it "is held by its catches when the strap wears through, and not when it is torn out" do
      hazards = ->(part) { rod(rods(part)).failure_hazards }

      expect(Array(hazards.call(:caught_man_engine)[:parted][:causes])).not_to include(:fall)
      expect(hazards.call(:caught_man_engine)[:torn_out][:causes]).to include(:fall)
      expect(hazards.call(:man_engine)[:parted][:causes]).to include(:fall)
    end

    it "parts by wearing through when the strap is spent at working speed" do
      expect(failed(run!(running(:man_engine, over: 1.0, strap: 1.0e-6), 4))).to include(mode: :parted)
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
