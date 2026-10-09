# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **You give the order; they do something else.**
#
# The third route into trouble, after a part breaking and a place being dangerous: the person at
# the lever simply gets it wrong. Gated on being **boneheaded**, or on being at a post that is
# genuinely complicated without the wit or the ticket for it — a strong idiot stokes perfectly well
# and sets the cut-off wrong, which is why `complexity:` is a separate axis from `effort:` rather
# than a harder version of it.
#
# **A slip changes `actual` and never `target`.** The command log still carries absolute
# destinations, still replays identically and still needs no dedup table: the mistake is in the
# execution, not in the instruction. That is both the honest model of a real mistake and the only
# version that leaves invariant 4 standing.
#
# ## Sampling, which is what made this file slow
#
# A slip count is a **statistical** claim rather than a state one, so there is nothing to construct
# — what there is instead is a sample long enough to be stable, and this file was taking a 3,000-
# tick settle plus 6,000 ticks of sampling for every call. Neither is needed:
#
# - **The settle bought nothing.** `:winding` is a bank post and the shift starts at bank, so
#   there is no walk to wait out. It changed the counts (13 slips became 65) by letting fatigue and
#   margin drift, which is a different experiment from the one being run.
# - **The lever has to travel for a slip to spoil anything**, and the cycle was 400 ticks long — so
#   a sample shorter than that never reversed the lever at all and `target` only ever took one
#   value. At a 50-tick cycle a 400-tick sample sees eight reversals.
#
# See `docs/design_sketches/mine-follow-ups.md` Part 3 and `design_sketches/suite-runtime.md` §7.
module SlipCrew
  # Same wit in the first two; what differs is the ticket, which is the claim. The third and fourth
  # are temperament, at two levels — `boneheaded` is a **weight**, not a flag, and the pump
  # examples below are the only place that difference is visible.
  HANDS = {
    certificated: { intelligence: 1.2, tags: { certificated: true, practised: true } },
    uncertificated: { intelligence: 1.2, tags: {} },
    kobold: { intelligence: 0.3, tags: { boneheaded: 0.5 } },
    witless: { intelligence: 0.1, tags: { boneheaded: 1.0 } }
  }.freeze

  def self.archetype(spec)
    { label: "Hand", mass_kg: 70.0, strength: 1.0, toughness: 1.0, endurance: 1.0e6,
      intelligence: spec[:intelligence], dexterity: 1.0, charisma: 1.0,
      tags: spec[:tags].merge(darkvision: 0.9, mining_effectiveness: 0.6, shovelling: 0.5) }
  end

  CONTENT = ReactorSim::Content.default.merging(
    archetypes: HANDS.to_h { |name, spec| [ :"arch_#{name}", archetype(spec) ] },
    minions: HANDS.keys.to_h { |name|
      [ :"hand_#{name}", { name: name.to_s, archetype: :"arch_#{name}", hireable: false } ]
    }
  )
end

RSpec.describe "doing the wrong thing" do
  include PitRig

  # **`SlipCrew` rather than the rig's collier**, because the hands are the experiment here: what a
  # slip costs depends on who is at the lever. The pit around them is the rig's.
  before { allow(ReactorSim::Content).to receive(:default).and_return(SlipCrew::CONTENT) }

  # The one certificated post in the pit, because overwinding puts a cage through the headgear.
  POST = :winding

  # How often the lever is sent the other way. Short enough that a 400-tick sample sees eight
  # reversals — a slip needs travel to spoil, so a cycle longer than the sample tests nothing.
  CYCLE = 50

  def pit(hand)
    build_pit(id: "s", seed: 2,
              crew: (1..4).to_h { |i| [ :"crew_#{i}", { minion: :"hand_#{hand}" } ] })
  end

  # Somebody at the lever with it being worked back and forth, so there is always travel for a slip
  # to spoil. Returns every tick's lever state.
  def worked(hand, post: POST, ticks: 400)
    op = pit(hand)
    op.assign_minion(:crew_1, post)

    Array.new(ticks) do |i|
      op.set_control(post, (i / CYCLE).even? ? 100 : 20)
      run!(op, 1, from: i)
      op.state.fetch(:controls).fetch(post)
    end
  end

  def slipping(states) = states.count { |s| s[:slip] }

  describe "who gets it wrong" do
    # **The ticket is the whole counterplay**, and it has to be worth buying: the same wit with a
    # certificate behind it never fumbles the winder at all.
    it "never catches out somebody certificated for the post" do
      expect(slipping(worked(:certificated))).to eq(0)
    end

    it "catches the same man out without his ticket" do
      expect(slipping(worked(:uncertificated))).to be > 0
    end

    it "catches somebody boneheaded far more often again" do
      expect(slipping(worked(:kobold))).to be > slipping(worked(:uncertificated))
    end

    # The first clause of the gate, and the reason it is separate: being boneheaded is not about
    # the post. It follows somebody to the pump, where being merely unsuited does not.
    #
    # **The wholly boneheaded hand, because the tag is a weight.** At `boneheaded: 0.5` the rate at
    # a plain valve is low enough to need thousands of ticks to see — which is itself the right
    # behaviour and worth saying: being a bit absent-minded rarely spoils a valve. At 1.0 it is 13
    # fumbles in 200 ticks.
    it "follows somebody boneheaded to a lever nobody could get wrong" do
      expect(slipping(worked(:witless, post: :pumping, ticks: 200))).to be > 0
    end

    # **A valve goes where you put it and who put it there is irrelevant**, which is why
    # `complexity:` is declared on one lever rather than assumed everywhere. The hand here is the
    # one who fumbles the winder constantly — at the pump he is simply fine.
    #
    # Not a boneheaded hand, deliberately: that is the *other* clause of the gate and makes
    # somebody capable of getting any job wrong, pumps included. The two routes are separate on
    # purpose and this example is about the second one.
    it "leaves an ordinary valve alone however poorly suited the hand" do
      expect(slipping(worked(:uncertificated, post: :pumping, ticks: 200))).to eq(0)
    end

    # And that the gate reads the **level** rather than the presence of the tag, which nothing else
    # here distinguishes: at a lever with no `complexity:` the half-boneheaded kobold is as safe as
    # the certificated man, and only the wholly boneheaded one is not.
    it "scales with how boneheaded somebody is, not merely whether they are" do
      expect(slipping(worked(:kobold, post: :pumping, ticks: 200))).to eq(0)
      expect(slipping(worked(:witless, post: :pumping, ticks: 200))).to be > 0
    end
  end

  describe "what going wrong looks like" do
    # All three are visible in `actual` diverging from `target`, which the panel already draws.
    it "freezes, reverses, or reaches for a different lever entirely" do
      kinds = worked(:kobold).filter_map { |s| s[:slip] }.uniq

      expect(kinds).not_to be_empty
      expect(kinds - ReactorSim::Tick::SLIPS).to be_empty
    end

    # **Which other lever is a question about where they are standing**, which is why this waited
    # for the spatial model. Everything they grab is at bank with them, and none of it is the lever
    # they were sent to.
    it "only reaches levers in the same room" do
      grabbed = worked(:kobold).filter_map { |s| s[:slip_at] }.uniq
      bank = ReactorSim::Operations::Mine.build(id: "l", seed: 1)
                                         .control_points.values
                                         .select { |c| c.place == :bank && c.lever? }.map(&:id)

      expect(grabbed).not_to be_empty
      expect(grabbed - (bank - [ POST ])).to be_empty
    end

    # **Seconds, not a tick.** At a quarter-second tick a single reversed step is a rounding error
    # nobody could see; held, the lever visibly walks the wrong way and the player swears and
    # re-commands.
    it "holds a mistake long enough to be noticed" do
      runs = worked(:kobold).chunk_while { |a, b| a[:slip] && b[:slip] }
                            .select { |run| run.first[:slip] }

      expect(runs.map(&:length).max).to be > 1
    end
  end

  # The invariant most at risk, because a lever now has a position no command set.
  describe "the command protocol" do
    it "never touches the target, however badly it is worked" do
      states = worked(:kobold)

      expect(states.map { |s| s[:target] }.uniq.sort).to eq([ 20.0, 100.0 ])
    end

    it "replays bit for bit" do
      digests = Array.new(2) do
        match = build_match(
          id: "s", seed: 2,
          crew: (1..4).to_h { |i| [ :"crew_#{i}", { minion: :hand_kobold } ] }
        )
        op = match.operation(:pit)
        op.assign_minion(:crew_1, POST)
        op.set_control(POST, 100)
        run!(op, 400)
        match.digest
      end

      expect(digests.first).to eq(digests.last)
    end

    # A slip kind is a Symbol living as a VALUE, which is the sixth instance of that trap and the
    # first to reach `controls` — a String matches no branch, so a restored lever silently stops
    # being mishandled. The kobold's first slip at the winder lands on tick 153.
    it "brings a slip back from a snapshot as a Symbol" do
      op = pit(:kobold)
      op.assign_minion(:crew_1, POST)
      slipped = 400.times.find do |i|
        op.set_control(POST, (i / CYCLE).even? ? 100 : 20)
        run!(op, 1, from: i)
        op.state.fetch(:controls).fetch(POST)[:slip]
      end
      expect(slipped).not_to be_nil, "the kobold never slipped"

      restored = ReactorSim::Operation.from_h(
        JSON.parse(JSON.generate(op.to_h), symbolize_names: true)
      )

      expect(restored.state.fetch(:controls).fetch(POST)[:slip]).to be_a(Symbol)
    end
  end
end
