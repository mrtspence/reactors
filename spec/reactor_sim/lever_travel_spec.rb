# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **A lever that takes time to move, and the person moving it.**
#
# `ControlPoint#actuate` has always converged `actual` toward `target` at a finite rate, and
# `Tick#crew_multiplier` has always worked out how fast whoever is stood there can manage it.
# Neither did anything, because every shipped lever was `Float::INFINITY` and `actuate` returns
# on its second line — so phase 0 was inert on every machine in the game and every spec passed
# regardless. The mine's valves ship finite figures, which is what makes the phase reachable.
#
# Nothing here is about the mine in particular. It is about the phase, and the mine is the only
# operation that currently exercises it.
#
# See `docs/design_sketches/mine-follow-ups.md` Part 1.
module LeverCrew
  def self.archetype(strength)
    { label: "Hand", mass_kg: 70.0, strength: strength, toughness: 1.0, endurance: 1.0e6,
      intelligence: 1.0, dexterity: 1.0, charisma: 1.0, tags: {} }
  end

  HANDS = { weak: 0.4, strong: 2.5 }.freeze

  CONTENT = ReactorSim::Content.default.merging(
    archetypes: HANDS.to_h { |name, strength| [ :"hand_#{name}", archetype(strength) ] },
    minions: HANDS.keys.to_h { |name|
      [ :"hand_#{name}", { name: name.to_s, archetype: :"hand_#{name}", hireable: false } ]
    }
  )
end

RSpec.describe "lever travel" do
  include PitRig

  # **`LeverCrew` rather than the rig's collier**, because strength is the experiment: how fast a
  # lever moves depends on who is pulling it.
  before { allow(ReactorSim::Content).to receive(:default).and_return(LeverCrew::CONTENT) }

  # The fan, because it is the slowest thing with a number on it and the one a player most wants
  # to be sure of: forty seconds hard over, which is 160 ticks at a quarter-second each.
  FAN_TICKS = 160

  # Two seats rather than the rig's four, because this spec is about one hand on one lever.
  def match(hand: :strong)
    build_match(id: "l", seed: 1,
                crew: (1..2).to_h { |i| [ :"crew_#{i}", { minion: :"hand_#{hand}" } ] })
  end

  def pit(...) = match(...).operation(:pit)

  def actual(op, id) = op.state.fetch(:controls).fetch(id).fetch(:actual)

  describe "a valve" do
    it "travels toward the target instead of snapping to it" do
      op = pit
      op.set_control(:ventilation, 0)
      run!(op, 1)

      expect(actual(op, :ventilation)).to be > 0.0
      expect(actual(op, :ventilation)).to be < 100.0
    end

    it "arrives at its rated speed and then stops" do
      op = pit
      op.set_control(:ventilation, 0)
      run!(op, FAN_TICKS - 8)
      expect(actual(op, :ventilation)).to be > 0.0

      run!(op, 16, from: FAN_TICKS - 8)
      expect(actual(op, :ventilation)).to eq(0.0)
    end

    # Travel is a rate, so a shorter journey takes proportionally less time. Asserted as a ratio
    # rather than in ticks, which is the figure rather than the shape.
    it "takes half as long to go half as far" do
      far = pit
      far.set_control(:ventilation, 0)
      near = pit
      near.set_control(:ventilation, 50)

      run!(far, FAN_TICKS / 2)
      run!(near, FAN_TICKS / 2)

      expect(actual(far, :ventilation)).to be_within(0.01).of(50.0)
      expect(actual(near, :ventilation)).to eq(50.0)
    end
  end

  # **An effort station still snaps, and that is a decision rather than an oversight.** The lever
  # there is the player's intent and `Minion#capability` already supplies the rate, so a finite
  # travel would charge the same person twice — and would let a weak minion reach full effort
  # late and then deliver exactly as much as a strong one.
  it "leaves an effort station frictionless" do
    op = pit
    op.set_control(:hewing, 100)
    run!(op, 1)

    expect(actual(op, :hewing)).to eq(100.0)
  end

  describe "who is working it" do
    def travelled(hand:, posted:, ticks: 20)
      op = pit(hand: hand)
      op.assign_minion(:crew_1, :ventilation) if posted
      run!(op, 400) if posted # let them walk to bank before the lever is touched
      op.set_control(:ventilation, 0)
      run!(op, ticks, from: 400)
      100.0 - actual(op, :ventilation)
    end

    it "is worked faster by a strong hand than a weak one" do
      expect(travelled(hand: :strong, posted: true))
        .to be > travelled(hand: :weak, posted: true)
    end

    # **The decided rule for an unattended lever: it travels at its rated speed.** Surface plant
    # is the overseer's own, and a colliery's fan, pump and winder are at bank where nobody is
    # normally posted — a lever that froze without a body would be a pit whose fan could never
    # be started. Posting somebody makes it faster or slower than rated, never possible at all.
    it "travels at its rated speed with nobody posted at all" do
      expect(travelled(hand: :strong, posted: false, ticks: 20)).to be_within(0.01).of(12.5)
    end

    it "is worked faster than rated by somebody stronger than a competent human" do
      expect(travelled(hand: :strong, posted: true))
        .to be > travelled(hand: :strong, posted: false)
    end
  end

  # **Idempotence is the invariant most at risk here**, because a lever now has a position that
  # a command does not set. It survives because a command still writes `target` and never
  # `actual`: the journey is state, the instruction is absolute.
  describe "the command protocol" do
    it "is unchanged by re-sending the same target mid-travel" do
      once = match
      once.operation(:pit).set_control(:ventilation, 0)
      run!(once.operation(:pit), 30)
      run!(once.operation(:pit), 60, from: 30)

      thrice = match
      thrice.operation(:pit).set_control(:ventilation, 0)
      run!(thrice.operation(:pit), 30)
      3.times { thrice.operation(:pit).set_control(:ventilation, 0) }
      run!(thrice.operation(:pit), 60, from: 30)

      expect(thrice.digest).to eq(once.digest)
    end

    it "lets the player change their mind mid-travel and turns the lever round" do
      op = pit
      op.set_control(:ventilation, 0)
      run!(op, 40)
      halfway = actual(op, :ventilation)

      op.set_control(:ventilation, 100)
      run!(op, 40, from: 40)

      expect(actual(op, :ventilation)).to be > halfway
    end
  end

  describe "what the player is shown" do
    # Without this a slow lever is indistinguishable from the game ignoring you.
    it "reports the lever as settling, and sends both numbers" do
      op = pit
      op.set_control(:ventilation, 0)
      run!(op, 1)

      control = op.control_points.fetch(:ventilation)
      expect(control.settling?(op.state.fetch(:controls).fetch(:ventilation))).to be(true)

      sent = op.project(viewer: :player, tick: 1).controls.fetch(:ventilation)
      expect(sent.fetch(:target)).to eq(0.0)
      expect(sent.fetch(:actual)).to be > 0.0
    end

    it "stops reporting it once the lever has arrived" do
      op = pit
      op.set_control(:ventilation, 0)
      run!(op, FAN_TICKS + 4)

      control = op.control_points.fetch(:ventilation)
      expect(control.settling?(op.state.fetch(:controls).fetch(:ventilation))).to be(false)
    end
  end

  # A lever caught mid-travel is new state, so it has to survive the wire like everything else.
  it "comes back from a snapshot still part way there" do
    op = pit
    op.set_control(:ventilation, 0)
    run!(op, 40)
    mid = actual(op, :ventilation)

    restored = ReactorSim::Match.from_h(match.to_h.merge(
      operations: [ op.to_h ]
    )).operation(:pit)

    expect(actual(restored, :ventilation)).to eq(mid)
    expect(restored.state.fetch(:controls).fetch(:ventilation).fetch(:target)).to eq(0.0)
  end
end
