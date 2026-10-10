# frozen_string_literal: true

require "reactor_sim"
require "support/reference_crew"

# **What the heat where somebody is standing does to them.**
#
# The second route into harm that is not a part breaking, after bad air — and the one that
# finally makes a burning district dangerous to be in. A roadway at 1300 K used to be survivable
# indefinitely: the men in it died when the roof eventually came down, not from the fire.
#
# Everything here is a **shape or a ratio**, never a figure, except the two calibration points
# the whole law is pinned to, which say so.
#
# See `docs/design_sketches/thermal-injury.md` Part 2.
RSpec.describe ReactorSim::Scorch do
  def hand(toughness: 1.0, tags: {})
    ReactorSim::Minion.new(
      id: :m, name: "Probe", tags: tags, mass_kg: ReferenceCrew::HUMAN_KG,
      stats: { strength: 1.0, toughness: toughness, endurance: 1.0,
               intelligence: 1.0, dexterity: 1.0, charisma: 1.0 }
    )
  end

  def unhurt = { resilience: 1.0, initial_resilience: 1.0, injury: nil, burns: 0.0 }

  # A room full of air at a temperature, in the shape `Scorch.gas` reports.
  def air_at(kelvin) = [ kelvin, 1_231.0 ]

  # Seconds of exposure before a tier is announced, or nil inside the window given.
  def seconds_to(minion, gas, tier, limit: 1_800.0)
    state = unhurt
    ((limit / 0.25).to_i).times do |i|
      state, mode = described_class.advance(minion, state, gas, 0.25)
      return (i + 1) * 0.25 if mode == tier
    end
    nil
  end

  describe "when nothing is wrong" do
    # **This must cost nothing in the overwhelming majority of every match**, which is the same
    # discipline `Breath.rate` keeps by returning early above `SAFE`.
    it "does nothing at all at a temperature a body is comfortable in" do
      expect(described_class.rate(air_at(295.0), hand)).to eq(0.0)
    end

    it "does nothing right up to the threshold" do
      expect(described_class.rate(air_at(described_class::TOLERATED_K), hand)).to eq(0.0)
    end

    it "leaves a minion untouched where there is no gas to stand in" do
      state, mode = described_class.advance(hand, unhurt, nil, 0.25)

      expect(mode).to be_nil
      expect(state).to eq(unhurt)
    end
  end

  describe "the law" do
    # The two points the whole thing is pinned to, and the only figures in this file.
    it "carries a fit hand off in about ten seconds at thirteen hundred kelvin" do
      expect(seconds_to(hand, air_at(1_300.0), :severe)).to be_within(2.0).of(10.0)
    end

    it "takes minutes rather than seconds in air that is merely far too hot" do
      expect(seconds_to(hand, air_at(400.0), :severe)).to be > 240.0
    end

    # **Superlinear, and that is what makes the two cases different in kind.** Linear in ΔT
    # would make 1300 K twelve times worse than 400 K where it should be nearer fifty, and a
    # furnace would be an inconvenience rather than a death.
    it "is far more than proportionally worse as it gets hotter" do
      ratio = described_class.rate(air_at(1_300.0), hand) /
              described_class.rate(air_at(400.0), hand)

      expect(ratio).to be > 30.0
    end

    # **The medium, not just the temperature**, which is the whole reason the quantity is heat
    # delivered rather than degrees: water carries three thousand times the heat of air per
    # degree per cubic metre, so boiling water is worse than a furnace full of gas.
    it "makes boiling water worse than air three times as hot" do
      boiling = [ 373.0, 4_168_457.0 ]

      expect(described_class.rate(boiling, hand))
        .to be > described_class.rate(air_at(1_300.0), hand)
    end
  end

  describe "who it reaches" do
    it "spares a tough minion longer than a frail one" do
      expect(seconds_to(hand(toughness: 1.8), air_at(400.0), :severe))
        .to be > seconds_to(hand(toughness: 0.6), air_at(400.0), :severe)
    end

    # **Gear is a threshold, not a multiplier**, which is what makes a tier worth buying: below
    # its rating it is not "better", it is *nothing happening*. A suit rated for the furnace
    # makes 1300 K no worse than ordinary bad air is to a bare hand.
    it "lets a suit stand in a furnace about as long as a bare hand stands in hot air" do
      suited = seconds_to(hand(tags: { heat_resistance: 1.0 }), air_at(1_300.0), :severe)
      bare = seconds_to(hand, air_at(400.0), :severe)

      expect(suited).to be_within(bare * 0.2).of(bare)
    end

    it "pays for every step up in the tier" do
      at = ->(r) { seconds_to(hand(tags: { heat_resistance: r }), air_at(1_300.0), :severe) }

      expect(at.call(0.3)).to be > at.call(0.0)
      expect(at.call(0.7)).to be > at.call(0.3)
    end

    # A gate rather than a resistance, the same shape as `Breath#unbreathing?`.
    it "does not touch something that does not burn" do
      elemental = hand(tags: { unburning: 1.0 })

      expect(described_class.rate(air_at(2_000.0), elemental)).to eq(0.0)
    end
  end

  describe "what it leaves behind" do
    it "grinds resilience rather than tiring anybody" do
      state, = described_class.advance(hand, unhurt, air_at(800.0), 0.25)

      expect(state.fetch(:resilience)).to be < 1.0
      expect(state).not_to have_key(:fatigue)
    end

    # **Burns do not drain, and that is the difference from suffocation.** Walking out of the
    # fire stops the accrual; it does not undo it. Bad air recovers on its own because the
    # counterplay is the fan — there is no equivalent for having been burnt.
    it "does not heal when somebody walks out of it" do
      state = unhurt
      40.times { state, = described_class.advance(hand, state, air_at(800.0), 0.25) }
      burnt = state.fetch(:resilience)

      400.times { state, = described_class.advance(hand, state, air_at(290.0), 0.25) }

      expect(state.fetch(:resilience)).to eq(burnt)
    end

    # **The dwell, and the trap it exists for.** Grinding resilience to zero proposes `:severe`,
    # and every bite after proposes `:severe` again — which `Severity.escalate` rightly refuses
    # to announce twice. Without a counter past zero a minion stands in a furnace permanently
    # stood down and never dies.
    it "goes on to kill somebody left in it" do
      expect(seconds_to(hand, air_at(1_300.0), :mortal)).not_to be_nil
    end

    it "announces each tier exactly once" do
      state = unhurt
      modes = []
      400.times do
        state, mode = described_class.advance(hand, state, air_at(1_300.0), 0.25)
        modes << mode if mode
      end

      expect(modes).to eq(modes.uniq)
      expect(modes.last).to be(:mortal)
    end
  end

  # No dice anywhere: the uncertainty was spent rolling `resilience` at `initial_state`, which
  # is why a burning minion replays bit for bit and survives a snapshot.
  it "draws no entropy" do
    runs = Array.new(2) do
      state = unhurt
      100.times { state, = described_class.advance(hand, state, air_at(900.0), 0.25) }
      state
    end

    expect(runs.first).to eq(runs.last)
  end
end
