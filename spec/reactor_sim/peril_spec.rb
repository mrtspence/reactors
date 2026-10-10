# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **The accident that needed nothing to break.**
#
# `failure_hazards` answers "a part let go, who was near it". This is the other half, and it is
# the majority of what a haulage road ever did to anybody: nothing broke, the tubs simply kept
# going past until one of them caught somebody.
#
# Every worker carries a hidden **margin of safety**, rolled from a wide spread. Dangerous work
# spends it in bursts tied to how hard the place is being worked; safe work mends it; when it
# runs out, something happens to them. It is closer to a stamina bar than to a durability bar
# and that is the point — a man who has had a bad hour on the haulage road is not condemned, he
# needs taking off it.
#
# **No dice are thrown here.** The roll happens at `initial_state` and in phase 0; everything in
# between is a deterministic comparison, exactly as the Danger Check is. The uncertainty is the
# hidden threshold, not a die at the moment of harm.
#
# ## Most of this file never needed a pit, and the rest needed a thin margin rather than an hour
#
# Over half the examples here call `Blunder.advance`, `Blunder.spend` or `accident_avoided?`
# directly and cost no ticks at all — which is the right level for them, because they are claims
# about the arithmetic. What the remaining ones need is somebody **about to** have an accident, and
# that is a precondition rather than a claim: seeding the posted crew's `margin` at 0.05 reaches
# the crossing on tick 131 instead of somewhere in eight thousand.
#
# **0.05 and not 0.10**, which is worth recording — at 0.10 the road mends faster than it spends
# over a 200-tick window and nothing happens at all. The margin is a stamina bar, so a seed has to
# be inside the distance the road can actually close.
#
# That also removed the `Settled` caching and the shared `SHIFTS` events hash this file used to
# need: a shift is two seconds now, so every example runs its own and nothing is shared.
#
# See `docs/design_sketches/mine-follow-ups.md` Part 4 and `design_sketches/suite-runtime.md` §7.
module PerilCrew
  HANDS = {
    sound: { toughness: 1.3, tags: { hazard_sense: 0.5, practised: true } },
    poor: { toughness: 0.8, tags: { clumsy: 0.6, green: true } },
    ogre: { toughness: 1.4, tags: { hulking: true } }
  }.freeze

  def self.archetype(spec)
    { label: "Hand", mass_kg: 70.0, strength: 1.2, toughness: spec[:toughness], endurance: 1.0e6,
      intelligence: 1.0, dexterity: 1.0, charisma: 1.0,
      tags: spec[:tags].merge(darkvision: 0.9, mining_effectiveness: 0.6, shovelling: 0.6) }
  end

  CONTENT = ReactorSim::Content.default.merging(
    archetypes: HANDS.to_h { |name, spec| [ :"arch_#{name}", archetype(spec) ] },
    minions: HANDS.keys.to_h { |name|
      [ :"hand_#{name}", { name: name.to_s, archetype: :"arch_#{name}", hireable: false } ]
    }
  )

  # **The seats these examples actually posted.** The chassis seats ten and sends the last
  # three down ahead of the shift, so a pit staffed with four still has strangers standing in
  # the district — exposed to the road like anybody else, and ordinary content minions rather
  # than the hand under test. Counting every accident in the pit measures them, which is how a
  # run once reported a *sound* crew suffering more than a poor one.
  POSTED = %i[crew_1 crew_2 crew_3].freeze

  # **What to seed a posted hand's margin at to put them on the edge of an accident.** The road
  # closes the last of it inside a couple of hundred ticks; at 0.10 it mends faster than it spends
  # and nothing happens. In the module rather than in the `describe` because a constant assigned
  # inside an example group lands on `Object`, where it collides with every other spec file's idea
  # of what that name means.
  ON_THE_EDGE = 0.05
end

RSpec.describe "perils" do
  include PitRig

  # **`PerilCrew` rather than the rig's collier**, because who the hand *is* decides what the
  # road does to them: three fixtures differing in the tags that select and scale an accident.
  before { allow(ReactorSim::Content).to receive(:default).and_return(PerilCrew::CONTENT) }

  ROAD_PERILS = %i[caught_in_haulage wedged struck_by_tub].freeze

  def pit(hand, seed: 1, loadout: {})
    build_pit(id: "r", seed: seed,
              loadout: { manriding: :cage_gear }.merge(loadout),
              crew: (1..4).to_h { |i| [ :"crew_#{i}", { minion: :"hand_#{hand}" } ] })
  end

  # A shift at work, with the haulage run at `rate`. Returns the accidents it produced — or
  # whatever `causes:` asks for, which is how the near-miss examples read the same shift.
  #
  # `edge: true` seeds the **posted** crew on the brink of an accident, which is what makes the
  # examples about what happens *when the margin runs out* short. The hand at the pit bank is
  # deliberately left alone, because "nobody spends it where nothing is trying to hurt them" is one
  # of the claims.
  def shift(hand, rate: 100, seed: 1, ticks: 200, loadout: {}, causes: nil, edge: false)
    op = at_the_face(seed(pit(hand, seed: seed, loadout: loadout), minions: edge ? brink : {}))
    levers!(op, hewing: rate, haulage: rate, timbering: 100,
                winding: 100, pumping: 100, ventilation: 100)

    events = run!(op, ticks)
    wanted = if causes
      events.select { |e| causes.include?(e[:type]) && PerilCrew::POSTED.include?(e[:node]) }
    else
      events.select { |e|
        ROAD_PERILS.include?(e[:cause]) && PerilCrew::POSTED.include?(e[:node]) &&
          e[:type] == :minion_hurt
      }
    end

    [ wanted, op ]
  end

  def brink = PerilCrew::POSTED.to_h { |seat| [ seat, { margin: PerilCrew::ON_THE_EDGE } ] }

  def margin(op, id) = op.state.dig(:minions, id, :margin)

  describe "the margin itself" do
    # **A sound hand, because the measurement needs somebody who survives the window.** A poor
    # one on this road is carried out part-way through, and the margin of a man at the pit bank
    # with a broken rib reads exactly full — the bar refills the moment he is out of the road,
    # which is the design working and is useless to measure against.
    it "starts full and is spent by being somewhere dangerous" do
      _, op = shift(:sound)

      expect(margin(op, :crew_2)).to be < op.state.dig(:minions, :crew_2, :margin_full)
    end

    # **Nobody is spending it at the pit bank**, which is what makes rotating a shift through
    # safe and dangerous posts a real strategy rather than a tax on playing at all.
    it "leaves somebody standing where nothing is trying to hurt them alone" do
      _, op = shift(:poor)

      expect(margin(op, :crew_4)).to eq(op.state.dig(:minions, :crew_4, :margin_full))
    end

    # The spread is wide on purpose: its whole job is to stop the player ever being sure, so
    # that eight minutes on the haulage road never becomes a budget to spend down.
    it "deals a different hand to the same worker in a different match" do
      fulls = [ 1, 2, 3, 4 ].map { |s| pit(:poor, seed: s).state.dig(:minions, :crew_2, :margin_full) }

      expect(fulls.uniq.length).to be > 1
    end

    # **The regression that hid the whole mechanic.** "Filled back up" written as
    # `margin >= margin_full` is also true of everybody who has never spent anything, so every
    # quiet tick re-rolled the margin back to full, no exposure accumulated, and the haulage
    # road became a corridor nobody could be hurt on. Nothing failed — the state looked
    # healthy and the events were simply absent.
    it "does not deal a fresh margin to somebody who has spent nothing" do
      hand = pit(:poor).minions.fetch(:crew_2)
      state = { margin: 1.4, margin_full: 1.4, fatigue: 0.0 }

      after, = ReactorSim::Blunder.advance({}, hand, state, 0.25, 9.9)

      expect(after.fetch(:margin_full)).to eq(1.4)
    end

    it "deals one the moment a margin that WAS spent fills back up" do
      hand = pit(:poor).minions.fetch(:crew_2)
      state = { margin: 1.4 - 1.0e-6, margin_full: 1.4, fatigue: 0.0 }

      after, = ReactorSim::Blunder.advance({}, hand, state, 0.25, 9.9)

      expect(after.fetch(:margin_full)).to eq(9.9)
    end

    # **A lull between tubs is not recovery.** Traffic is bursty, so handing margin back on
    # any tick that happened to cost nothing returns several times what the road takes.
    it "hands nothing back to somebody still standing in the road" do
      hand = pit(:poor).minions.fetch(:crew_2)
      quiet = { ReactorSim::Peril.new(id: :caught_in_haulage, severity: 2.2,
                                      places: %i[pit_bottom]) => 0.0 }
      state = { margin: 0.5, margin_full: 1.4, fatigue: 0.0 }

      after, = ReactorSim::Blunder.advance(quiet, hand, state, 0.25, 9.9)

      expect(after.fetch(:margin)).to eq(0.5)
    end

    it "keeps every margin inside the declared spread" do
      op = pit(:poor)
      fulls = op.state.fetch(:minions).values.map { |s| s.fetch(:margin_full) }

      expect(fulls).to all(be_between(ReactorSim::Blunder::SPREAD.begin,
                                      ReactorSim::Blunder::SPREAD.end))
    end
  end

  describe "what spends it" do
    # **Activity, not time**, which is the shape decision the whole model rests on: the danger
    # of a haulage road is the tub going past. Running the pit harder runs it more dangerously,
    # so production and safety are the same dial.
    it "costs more on a road being worked hard than on an idle one" do
      _, busy = shift(:sound, rate: 100)
      _, idle = shift(:sound, rate: 0)

      expect(margin(busy, :crew_2)).to be < margin(idle, :crew_2)
    end

    # Superlinear in the mismatch, for the reason `Fatigue` is squared: what the work demands
    # against what the worker brings should compound rather than add.
    #
    # **On the spend itself rather than on two shifts.** Measuring the residual margin compares
    # whatever each hand has left *since their last re-roll*, which says nothing once one of
    # them has had an accident — and the hand this example calls worse is precisely the one
    # that will have had one. The claim is about the rate, so assert the rate.
    it "costs a poor hand far more than a sound one at the same post" do
      road = ReactorSim::Operations::Mine.build(id: "w", seed: 1).nodes.fetch(:tub_road)
      working = road.perils.to_h { |peril| [ peril, 0.14 ] }
      fresh = { margin: 1.0, margin_full: 1.0, fatigue: 0.0 }
      bite = ->(hand) { ReactorSim::Blunder.spend(working, hand, fresh, 0.25).first }

      expect(bite.call(pit(:poor).minions.fetch(:crew_2)))
        .to be > bite.call(pit(:sound).minions.fetch(:crew_2)) * 2.0
    end
  end

  # **`edge: true` throughout this group**, because every claim in it is about what happens once
  # the margin is gone rather than about how long the road takes to take it. The crossing lands on
  # tick 131 and catches all three posted hands.
  describe "when it runs out" do
    it "hurts somebody, and says which peril did it" do
      accidents, = shift(:poor, edge: true)

      expect(accidents).not_to be_empty
      expect(accidents.map { |e| e[:cause] }.uniq - ROAD_PERILS).to be_empty
      expect(accidents.map { |e| e[:type] }.uniq).to eq([ :minion_hurt ])
    end

    # **A tag selects a kind of accident, not only its likelihood.** The ogre is wedged against
    # the side where a smaller hand has room; everybody else is struck by a tub that would have
    # been seen coming for him. Neither is simply better in the road, which is the whole reason
    # to do it this way rather than with one scalar.
    #
    # Asserted on **which perils can reach whom** rather than on an accident happening. Whether
    # one does inside any given shift is the margin's business, and the spread is wide on
    # purpose — pinning this to an outcome would make it a test of how unlucky one fixture
    # happened to be on one seed.
    it "exposes a hulking minion to an accident a small one cannot have" do
      road = ReactorSim::Operations::Mine.build(id: "w", seed: 1).nodes.fetch(:tub_road)
      reaches = ->(hand) { road.perils.select { |p| p.applies_to?(hand) }.map(&:id) }
      crew = ->(h) { pit(h).minions.fetch(:crew_2) }

      expect(reaches.call(crew.call(:ogre))).to contain_exactly(:caught_in_haulage, :wedged)
      expect(reaches.call(crew.call(:poor)))
        .to contain_exactly(:caught_in_haulage, :struck_by_tub)
    end

    it "never wedges somebody small enough to have room" do
      poor, = shift(:poor, edge: true)

      expect(poor).not_to be_empty
      expect(poor.map { |e| e[:cause] }).not_to include(:wedged)
    end

    # **The information leak this closes.** A worker who survives a long exposure has revealed
    # a high roll, and with a bar that refills they would be known-safe forever — so the roll
    # is a property of *this stretch of work* and both transitions end it.
    # Against the margins the same seed *dealt*, rather than against each other: four workers
    # start on four different rolls, so "they are not all the same" passes with the re-roll
    # switched off entirely.
    it "deals a fresh margin rather than letting a survivor stay lucky" do
      dealt = pit(:poor).state.fetch(:minions).transform_values { |s| s.fetch(:margin_full) }
      _, op = shift(:poor, edge: true)

      changed = op.state.fetch(:minions).count { |id, s| s.fetch(:margin_full) != dealt.fetch(id) }

      expect(changed).to be_positive
    end
  end

  # **The boring purchase**: it wins no coal, shows nothing on a gauge, and its entire value is
  # the accidents that did not happen. Which is exactly why the engine has to *say so* — a
  # fitting nobody is told about is indistinguishable from money wasted.
  describe "safety equipment" do
    def saved?(effectiveness, attention, roll)
      ReactorSim::Blunder.accident_avoided?(effectiveness, attention, roll)
    end

    it "does nothing where none is fitted" do
      expect(saved?(0.0, 1.0, 0.01)).to be(false)
    end

    it "saves more often the better it is" do
      rolls = (1..99).map { |i| i / 100.0 }
      sparse = rolls.count { |r| saved?(0.5, 0.9, r) }
      good = rolls.count { |r| saved?(0.85, 0.9, r) }

      expect(good).to be > sparse
    end

    # **Still requires an attentive minion**, which is the whole reason this is not simply a
    # discount on the risk. The same refuges are worth far less to somebody who never saw the
    # tub coming — and `Minion#wits` is gated on being able to see at all, so a dark roadway
    # takes the fitting's value with it.
    it "is worth more to somebody paying attention" do
      rolls = (1..99).map { |i| i / 100.0 }
      sharp = rolls.count { |r| saved?(0.85, 1.6, r) }
      dull = rolls.count { |r| saved?(0.85, 0.3, r) }

      expect(sharp).to be > dull * 2
    end

    # **Buying safety must never buy immunity.** The best gear in the best hands still lets
    # one in six through, and that is what keeps the road a risk being managed rather than one
    # that has been closed.
    it "never saves everybody, however good the gear and the hand" do
      expect(saved?(1.0, 10.0, ReactorSim::Blunder::MOST_EQUIPMENT_SAVES + 0.01)).to be(false)
    end

    # **The same accident, a different ending.** Every die is thrown in phase 0 for everybody,
    # so fitting the manholes does not move *when* a man gets into trouble — it changes what
    # happens when he does. The bare pit's casualty and the fitted pit's near miss are one
    # crossing, at one tick, to one man, and asserting them against each other is what makes
    # this a claim about the fitting rather than about how a shift happened to go.
    it "tells the player when it kept somebody out of trouble" do
      bare, = shift(:poor, edge: true)
      hurt = bare.first
      expect(hurt).not_to be_nil, "the bare pit must hurt somebody or this proves nothing"

      saved, = shift(:poor, edge: true, loadout: { manholes: :whitewashed_manholes },
                     causes: %i[minion_near_miss])
      miss = saved.find { |e| e[:tick] == hurt[:tick] }

      expect(miss).not_to be_nil, "the fitting must change this accident, not displace it"
      expect(miss[:severity]).to eq(:warning), "a near miss must reach the incident feed"
      expect(miss[:node]).to be(hurt[:node])
      expect(miss[:cause]).to be(hurt[:cause])
      expect(miss.dig(:detail, :saved_by)).to be(:manholes)
    end

    # And the stronger half of the same pairing, which the seeded margin makes checkable: the
    # fitting turns **every** casualty of that crossing into a near miss rather than thinning them
    # out. Three hurt bare, three saved fitted, all on the one tick.
    it "changes the whole crossing rather than displacing part of it" do
      bare, = shift(:poor, edge: true)
      fitted_hurt, = shift(:poor, edge: true, loadout: { manholes: :whitewashed_manholes })
      fitted_misses, = shift(:poor, edge: true, loadout: { manholes: :whitewashed_manholes },
                             causes: %i[minion_near_miss])

      expect(bare.length).to be > 0
      expect(fitted_hurt).to be_empty
      expect(fitted_misses.length).to eq(bare.length)
    end

    it "says nothing at all in a pit that bought none" do
      misses, = shift(:poor, edge: true, causes: %i[minion_near_miss])

      expect(misses).to be_empty
    end
  end

  # Nothing above throws a die at the moment of harm: everything uncertain was decided at
  # `initial_state` and in phase 0, which is what keeps replay bit-identical.
  it "replays bit for bit" do
    digests = Array.new(2) do
      match = build_match(id: "r", seed: 1, loadout: { manriding: :cage_gear },
                          crew: (1..4).to_h { |i| [ :"crew_#{i}", { minion: :hand_poor } ] })
      op = match.operation(:pit)
      op.assign_minion(:crew_2, :haulage)
      op.set_control(:haulage, 100)
      run!(op, 400)
      match.digest
    end

    expect(digests.first).to eq(digests.last)
  end
end
