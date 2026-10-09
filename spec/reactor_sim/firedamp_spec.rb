# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **Firedamp: the thing the ventilation is for.**
#
# The mine gives off gas whether anybody is watching or not, and the only question is whether
# enough air is going past to take it away. Everything in this file is a consequence of that one
# sentence — the fan is not a machine that makes a number go up, it is the reason the district is
# survivable.
#
# Its own crew rather than `ReferenceCrew`: these examples are about **who was standing where when
# it went up**, so they need people who can get there.
#
# ## The district is built, not waited for
#
# Every example here used to run a pit for thousands of ticks so that gas could seep its way to the
# concentration being tested — around 62,000 ticks across the file, to assert things that are
# decided in tens. `district_mix` puts the mixture there directly and `at_the_face` puts the shift
# at their posts, both of which are checked in `mine_stages_spec`.
#
# **What belongs to `district_fire_spec` instead:** where the flammability limits *are*. That is
# chemistry, it is stated by volume, and it is probed from both sides there in 0.55 s. What is here
# is the mine's own wiring — that a seam seeps, that a fan clears, that a flame in a gassy district
# kills the people standing in it.
#
# See `docs/design_sketches/mine.md` §4.6 stage D and `design_sketches/suite-runtime.md` §7.
RSpec.describe "firedamp" do
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  def pit(**opts) = build_pit(id: "f", seed: 7, loadout: { manriding: :cage_gear }, **opts)

  def station_of(op, seat) = crew(op, seat)[:station]

  # A pit with the shift at their posts and the district holding whatever is asked for. `worn:`
  # seeds the district's remaining durability, which is how an example about *rupture* gets to be
  # short: the roadway erodes under sustained over-temperature, so starting it part-worn tests the
  # failure rather than the erosion rate.
  def pit_with(firedamp: 0.0, worn: nil, posts: {}, **mix)
    op = pit
    district = district_mix(op, firedamp: gas_kg(firedamp), **mix)
    district = district.merge(durability: worn) if worn

    at_the_face(seed(op, nodes: { district: district }), **posts)
  end

  # Work the pit. `ventilation:` and `naked_flame:` are the two levers every example here moves.
  # `from:` is explicit rather than swept into `**levers`, because `set_control` ignores an id it
  # does not know — so a stray keyword became a lever nobody has and the run restarted at tick 1.
  def work!(op, ticks, from: 0, ventilation: 100, naked_flame: 0, hewing: 0, **levers)
    levers!(op, hewing: hewing, haulage: 100, timbering: 100, winding: 100, pumping: 100,
                ventilation: ventilation, naked_flame: naked_flame, **levers)

    run!(op, ticks, from: from)
  end

  describe "emission" do
    # **Not constructed**, deliberately: this is the claim that the ground gives gas off at all, so
    # it has to start from a district holding nothing but air and watch some arrive.
    it "gives off gas with nobody doing anything at all" do
      op = at_the_face(pit)
      work!(op, 100, ventilation: 0)

      expect(gas_pct(op)).to be > 0.0
    end

    # The blower is **pressure-driven**, so what it vents depends on what it is venting against. A
    # fixed rate could not express this, and it is the reason a cleared working vents harder.
    #
    # Asserted across four concentrations rather than as one pair, because the spread is narrow —
    # 0.05551 down to 0.05448 kg/tick from a clear district to a 60% one — and a monotone fall
    # across the range is a far stronger statement than one comparison that happens to differ.
    it "vents harder into a clear district than a gassy one" do
      vented = [ 0.0, 10.0, 30.0, 60.0 ].map do |pct|
        op = pit_with(firedamp: pct)
        work!(op, 20, ventilation: 0)
        op.state.fetch(:nodes).fetch(:blower).fetch(:carried_kg)
      end

      expect(vented.each_cons(2).all? { |clearer, gassier| gassier < clearer }).to be(true),
                                                                                  vented.inspect
    end
  end

  describe "ventilation" do
    # **The claim the whole subsystem exists for.** Same mine, same gas, one lever.
    it "holds the district at a trace with the fan running" do
      op = at_the_face(pit)
      work!(op, 200, ventilation: 100)

      expect(gas_pct(op)).to be < 3.0
    end

    # **The rate at which a stopped fan lets a pit become dangerous is a separate question from
    # where the danger is**, and conflating them is what made this a 6,000-tick run. What is
    # asserted here is the direction and that the fan is the only thing acting against it; that a
    # district at 5–15% by volume then explodes is `district_fire_spec`'s, from both sides.
    it "lets it build up with the fan stopped, and nothing else takes it away" do
      op = at_the_face(pit)
      work!(op, 100, ventilation: 0)
      early = gas_pct(op)
      work!(op, 100, ventilation: 0, from: 100)

      expect(early).to be > 0.0
      expect(gas_pct(op)).to be > early
    end

    it "clears a gassy district once the fan is restarted" do
      op = pit_with(firedamp: 8.0)
      gassy = gas_pct(op)
      work!(op, 200, ventilation: 100)

      expect(gassy).to be > 5.0
      expect(gas_pct(op)).to be < gassy
    end
  end

  describe "the flame cap" do
    # **Somebody has to be holding the lamp.** The cap is a deputy's word and the gauge says so —
    # it names `:timbering` as its observer, the one post that is in the district and wins no coal.
    def watched(firedamp: 0.0, ticks: 30)
      op = pit_with(firedamp: firedamp)
      work!(op, ticks)
      op
    end

    # The decision the observer rule exists to create: no deputy, no reading. **The timbering seat
    # has to be left empty for this**, which is what `posts:` is for — the advance shift are
    # already standing in the district, so a reading appears the moment one of them is posted.
    it "reads nothing at all with nobody in the district to look" do
      op = pit_with(posts: { timbering: nil })
      work!(op, 20)

      expect(op.project(tick: 20).gauges.fetch(:flame_cap)).to be_nil
    end

    # The instrument is prose and must stay prose. A number here would be a different game —
    # nobody in a pit measured 4.2%, they looked at the height of a blue cone.
    it "reads as prose rather than a figure" do
      expect(watched.project(tick: 30).gauges.fetch(:flame_cap)).to be_a(String)
    end

    # **Read off the spectator's copy, because this is a claim about the scale rather than about the
    # deputy.** What the player gets is his opinion of it, complete with the chance he is
    # confidently wrong — which is `Filters::Misread`'s own spec, not this one.
    it "says there is no cap on a clear lamp and a tall one on a gassy district" do
      clear = watched
      gassy = watched(firedamp: 8.0)

      expect(clear.project(viewer: :spectator, tick: 30).gauges.fetch(:flame_cap))
        .to match(/no cap|trace/)
      expect(gassy.project(viewer: :spectator, tick: 30).gauges.fetch(:flame_cap))
        .to match(/tall cap|firing/)
    end
  end

  describe "ignition" do
    it "does not light with safety lamps, however gassy it gets" do
      op = pit_with(firedamp: 8.0)
      events = work!(op, 60, ventilation: 0, naked_flame: 0)

      expect(gas_pct(op)).to be > 5.0
      expect(events.map { |e| e[:type] }).not_to include(:fire_lit)
      expect(op.state.fetch(:nodes).fetch(:district)[:failure]).to be_nil
    end

    # **The decision the whole period turns on.** Naked lights are not a fitting you buy, they are
    # a standing order to the shift — and the entire cost of them is that the district then
    # contains a flame. Ten ticks is enough: an ignition is immediate, and what used to need
    # thousands was the *waiting for a mixture*.
    it "lights with naked lights in a gassy district" do
      op = pit_with(firedamp: 8.0)
      events = work!(op, 20, ventilation: 0, naked_flame: 100)

      expect(events.map { |e| e[:type] }).to include(:fire_lit)
    end

    # **Two claims, because a rupture is erosion and not a bang.** The roadway comes apart under
    # sustained over-temperature, so from full durability it takes ~600 ticks — which measures the
    # erosion rate, not the failure. The rate is the first example; the failure is the second, from
    # a district already part-worn, which is a state a pit that has been burnt once is really in.
    it "eats the district's durability while it burns" do
      op = pit_with(firedamp: 8.0)
      sound = op.state.fetch(:nodes).fetch(:district).fetch(:durability)
      work!(op, 60, ventilation: 0, naked_flame: 100)

      expect(op.state.fetch(:nodes).fetch(:district).fetch(:durability)).to be < sound
    end

    it "wrecks a district that has already taken damage" do
      op = pit_with(firedamp: 8.0, worn: 60.0)
      events = work!(op, 40, ventilation: 0, naked_flame: 100)

      expect(events.select { |e| e[:type] == :part_failed }.map { |e| e[:node] }).to include(:district)
      expect(op.state.fetch(:nodes).fetch(:district)[:failure]).to be(:rupture)
    end

    # The point of all of it. An explosion in an empty district hurts nobody, which is correct and
    # is why `at_the_face` puts the shift underground first.
    it "hurts the people who were down there" do
      op = pit_with(firedamp: 8.0)
      expect(station_of(op, :crew_1)).to be(:hewing)

      events = work!(op, 60, ventilation: 0, naked_flame: 100)

      hurt = events.select { |e| e[:type] == :minion_hurt }
      expect(hurt).not_to be_empty
      expect(hurt.map { |e| e[:node] }).to include(:crew_1)
      expect(op.state.fetch(:minions).fetch(:crew_1)[:injury]).not_to be_nil
    end

    # **Asserted on resilience rather than on an event**, and the difference is the point: a hazard
    # that gets through somebody's resistance always costs them, but it only becomes an *injury*
    # when the bite crosses a tier. The putter is a long way from the face and is not safe — he
    # takes the blast and walks away from it, this time. A spec demanding an event here would be
    # demanding that the pit bottom be as lethal as the face, which it is not.
    it "reaches the pit bottom as well as the face" do
      op = pit_with(firedamp: 8.0)
      expect(station_of(op, :crew_2)).to be(:haulage)
      intact = op.state.fetch(:minions).fetch(:crew_2).fetch(:resilience)

      work!(op, 60, ventilation: 0, naked_flame: 100)

      expect(op.state.fetch(:minions).fetch(:crew_2).fetch(:resilience)).to be < intact
    end
  end

  describe "conservation" do
    # The explosion is a reaction like any other and has to balance like one.
    it "holds through ignition, rupture and everything after it" do
      op = pit_with(firedamp: 8.0, worn: 60.0)
      mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

      work!(op, 100, ventilation: 0, naked_flame: 100)

      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      expect((mass - mass0).abs / mass0.abs).to be < 1e-9, "mass drifted by #{mass - mass0}"
      expect((joules - joules0).abs / joules0.abs).to be < 1e-9,
             "energy drifted by #{joules - joules0}"
    end
  end
end
