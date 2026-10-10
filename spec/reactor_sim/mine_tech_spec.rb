# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **What a player buys, and what happens when they have not.**
#
# Three things that were owed after the mine landed and are settled here: light and tools as a
# *gate* rather than a bonus, inundation as a failure that is not merely the pump stopping, and
# the cutting tier the tech tree was missing.
#
# ## Built, not waited for
#
# This file was the most expensive in the suite: six runs of 12,000 ticks for the inundation
# group alone, because a fissure only gives way after a face has been driven hard for hours.
# **Seed the fissure part-worn** and the failure is reached in 150 ticks — which tests the
# breach rather than the erosion rate that leads to it.
#
# The ventilation tier is the one claim here that is genuinely about a *rate*: what a better fan
# buys is the equilibrium between its throughput and the ground's make, and an equilibrium takes
# thousands of ticks to settle into. It is tested by its **sign** instead — seed the district at a
# working concentration and see which way each fan moves it, which is the same claim and is
# decided in 200 ticks. See `docs/design_sketches/suite-runtime.md` §7.
#
# See `docs/design_sketches/mine.md` §4.6 stage F.
module MineTech
  # Four fixtures differing only in what they are carrying, so a comparison between them is a
  # comparison of the kit and nothing else.
  KITS = {
    bare: {},
    pick: { mining_effectiveness: 0.8 },
    candle: { mining_effectiveness: 0.25, darkvision: 0.1 },
    lamp: { mining_effectiveness: 0.25, darkvision: 0.45 },
    proper: { mining_effectiveness: 0.8, darkvision: 0.75 }
  }.freeze

  def self.archetype(tags)
    { label: "Hand", mass_kg: 70.0, strength: 1.0, toughness: 1.0, endurance: 1.0e6,
      intelligence: 1.0, dexterity: 1.0, charisma: 1.0, tags: tags.merge(shovelling: 0.5) }
  end

  CONTENT = ReactorSim::Content.default.merging(
    archetypes: KITS.to_h { |name, tags| [ :"hand_#{name}", archetype(tags) ] },
    minions: KITS.keys.to_h { |name|
      [ :"hand_#{name}", { name: name.to_s, archetype: :"hand_#{name}", hireable: false } ]
    }
  )

  # A fissure with almost nothing left, so driving the face breaks it inside 150 ticks instead of
  # twelve thousand. The erosion rate itself is `Inrush#stress_per_second`'s business.
  WORN_FISSURE = 20.0
end

RSpec.describe "the mine's tech tree" do
  include PitRig

  # **Its own content rather than the rig's**, because the kit is the experiment: `MineTech`
  # carries one archetype per tier so a comparison between two fixtures is a comparison of what
  # they are holding and nothing else. Everything *around* the experiment comes from the rig.
  before { allow(ReactorSim::Content).to receive(:default).and_return(MineTech::CONTENT) }

  def pit(kit: :proper, ground: PitRig::ORDINARY, **loadout)
    hand = :"hand_#{kit}"
    build_pit(id: "t", seed: 5, ground: ground,
              loadout: { manriding: :cage_gear, **loadout },
              crew: (1..4).to_h { |i| [ :"crew_#{i}", { minion: hand } ] })
  end

  def coal_in_seam(op) = held(op, :seam, :coal)

  def water(op) = held(op, :pit_bottom, :water)

  # A shift at the face with the levers over. `worn:` seeds the fissure's remaining durability;
  # `damp:` and `firedamp:` seed the district.
  def cutting(op, hewing: 100, timbering: 100, worn: nil, damp: 0.0, firedamp: 0.0, **levers)
    nodes = {}
    nodes[:seepage] = { durability: worn } if worn
    if damp.positive? || firedamp.positive?
      nodes[:district] = district_mix(op, blackdamp: gas_kg(damp), firedamp: gas_kg(firedamp))
    end

    at_the_face(seed(op, nodes: nodes)).tap do |ready|
      levers!(ready, hewing: hewing, haulage: 100, timbering: timbering,
                     winding: 100, pumping: 100, **levers)
    end
  end

  def cut_over(op, ticks)
    before = coal_in_seam(op)
    run!(op, ticks)
    before - coal_in_seam(op)
  end

  def breathable(op, place = :district)
    ReactorSim::Breath.breathable_fraction(
      op.state.fetch(:nodes).fetch(op.layout.breathes(place)).fetch(:parcels), op.content
    )
  end

  describe "light and tools are a gate, not a bonus" do
    # **The claim the sketch made and the code did not keep.** `aided_by:` adds, so a hewer with
    # no pick was merely unaided; `gated_by:` multiplies, so they are useless — which is the
    # honest model of a job that cannot be done without the thing.
    it "wins no coal at all from a hewer with neither pick nor light" do
      expect(cut_over(cutting(pit(kit: :bare)), 50)).to eq(0.0)
    end

    it "wins none from somebody who can see but has nothing to cut with" do
      lit = MineTech.archetype(darkvision: 1.0)
      content = ReactorSim::Content.default.merging(
        archetypes: { hand_lit: lit },
        minions: { hand_lit: { name: "Lit", archetype: :hand_lit, hireable: false } }
      )
      allow(ReactorSim::Content).to receive(:default).and_return(content)

      op = build_pit(id: "t", seed: 5, loadout: { manriding: :cage_gear },
                     crew: (1..4).to_h { |i| [ :"crew_#{i}", { minion: :hand_lit } ] })

      expect(cut_over(cutting(op), 50)).to eq(0.0)
    end

    # Ratios, never figures: the shape is the claim. Measured at 100 ticks — 0.0 / 0.88 / 3.94 /
    # 21.0 kg across bare, candle, lamp and a proper kit.
    it "pays for every step up in kit" do
      won = %i[candle lamp proper].map { |kit| cut_over(cutting(pit(kit: kit)), 50) }

      expect(won.first).to be > 0.0
      expect(won.each_cons(2).all? { |worse, better| better > worse }).to be(true), won.inspect
    end
  end

  describe "the cutting tier" do
    # Measured at 100 ticks: 84.0 kg against 21.0 by hand.
    it "gets far more coal out of the same face with a machine" do
      by_hand = cut_over(cutting(pit), 50)
      by_machine = cut_over(cutting(pit(cutting: :coal_cutter)), 50)

      expect(by_machine).to be > by_hand
    end

    # The part that actually changes a shift: a hewer is spent in twenty minutes and a machine is
    # not, so the seat the cutter frees is worth more than the coal it adds.
    it "costs the hewer far less of themselves" do
      expect(pit(cutting: :coal_cutter).control_points.fetch(:hewing).exertion)
        .to be < pit.control_points.fetch(:hewing).exertion
    end
  end

  # **Light is a gate, so the lighting tier is the one upgrade that can take output from nothing
  # to something.** Hewing multiplies `darkvision`, and a gate is a zero when it is missing — a
  # shift at an unlit face is being paid to stand in the dark.
  describe "the lighting tier" do
    # The `:pick` kit throughout — tools and no lamp — so the only light at the face is the room's
    # and `Minion#gate`'s better-of-the-two has nothing carried to prefer.
    def won(tier, light:)
      op = cutting(pit(kit: :pick, lighting: tier), ventilation: 100)
      op.set_control(op.control_points.key?(:naked_flame) ? :naked_flame : :safe_light, light)
      cut_over(op, 60)
    end

    it "lights a face for somebody carrying no lamp" do
      expect(won(:oil_flares, light: 0)).to eq(0.0)
      expect(won(:oil_flares, light: 100)).to be > 0.0
    end

    # The trade, in both directions: the brightest flame beats the safe lantern that replaces it,
    # and the safe lantern is the one that does not fire the district.
    it "pays for light, and the safe tier costs some of it" do
      candles = won(:tallow_candles, light: 100)
      flares = won(:oil_flares, light: 100)
      lanterns = won(:gauze_lanterns, light: 100)

      expect(flares).to be > candles
      expect(lanterns).to be < flares
      expect(lanterns).to be > candles
    end

    # **The whole point of a safety lamp, as a lever rather than a tag.** The district's igniter
    # names the open-flame control; a safe tier declares a different one, so there is no ignition
    # source in the room at all however gassy it gets.
    #
    # **The gas is constructed rather than left to build with the fan stopped**, which is what made
    # this a 2,500-tick example per tier. Where the explosive band is is `district_fire_spec`'s.
    it "fires the district on an open flame and never on a safe one" do
      fired = %i[tallow_candles oil_flares gauze_lanterns electric_lamps].to_h do |tier|
        op = cutting(pit(lighting: tier), hewing: 0, firedamp: 8.0, ventilation: 0)
        lever = op.control_points.key?(:naked_flame) ? :naked_flame : :safe_light
        op.set_control(lever, 100)
        events = run!(op, 60)
        [ tier, events.any? { |e| e[:node] == :district && e[:type] == :fire_lit } ]
      end

      expect(fired.select { |_, lit| lit }.keys).to contain_exactly(:tallow_candles, :oil_flares)
    end

    # **What the fan is actually buying, and the open flame is the reason to buy it.** A mixture
    # carries a flame only between about 5% and 15% by volume, so a district the fan is holding at
    # a trace is safe with a naked light in it, and the same light in a district whose fan has
    # stopped is the end of the pit.
    #
    # The tier is therefore a **risk a player is carrying**, not a hazard that fires on a timer,
    # and the two upgrade ladders are coupled: buying light off a flame is only as safe as the air.
    # That the fan *does* hold a worked district at a trace is `firedamp_spec`'s claim.
    it "is harmless at the concentration a running fan holds, and fatal above it" do
      trace = cutting(pit(kit: :pick, lighting: :oil_flares), firedamp: 1.0, ventilation: 100)
      gassy = cutting(pit(kit: :pick, lighting: :oil_flares), firedamp: 8.0, ventilation: 0)
      [ trace, gassy ].each { |op| op.set_control(:naked_flame, 100) }

      quiet = run!(trace, 60)
      loud = run!(gassy, 60)

      district = ->(events) { events.any? { |e| e[:node] == :district && e[:type] == :fire_lit } }
      expect(district.call(quiet)).to be(false)
      expect(district.call(loud)).to be(true)
    end
  end

  # **What a better fan actually buys, and it is not a bigger number on a gauge.**
  #
  # Historically the Guibal is why Victorian pits stopped being places you could suffocate in
  # while working normally — the upgrade is measured in breathable air, not in airflow.
  describe "the ventilation tier" do
    def airflow(fan)
      op = cutting(pit(fan: fan), ventilation: 100)
      run!(op, 50)
      op.state.fetch(:nodes).fetch(:upcast).fetch(:carried_kg)
    end

    # Where each fan settles a district seeded at a working concentration. **The sign is the
    # claim**: a fan whose throughput beats the ground's make pulls the district back above the
    # safe line, and one that does not leaves it below, which is the equilibrium stated without
    # waiting for it.
    def settles_at(fan, ground: PitRig::ORDINARY, damp: 7.0)
      op = cutting(pit(fan: fan, ground: ground), damp: damp, ventilation: 100)
      run!(op, 200)
      breathable(op)
    end

    # The direct measurement, and the plainest statement of what the tier is: half again as much
    # air through the same pit. 3.873 kg/tick against 2.569.
    it "moves half again as much air" do
      expect(airflow(:guibal_fan)).to be > airflow(:waddle_fan) * 1.4
    end

    it "leaves a worked district breathable on either fan" do
      expect(settles_at(:waddle_fan)).to be > ReactorSim::Breath::SAFE
      expect(settles_at(:guibal_fan)).to be > ReactorSim::Breath::SAFE
    end

    # **And on the worst ground the cheap fan does not hold the line at all**, which is what makes
    # `Ground` a mechanic rather than a flavour. A range the starting machine always copes with
    # changes nothing; some pits have to be bought out of.
    #
    # Measured on the gassiest ground from a district at 7% blackdamp: the waddle settles at
    # 0.92479 and the Guibal at 0.93081, either side of the 0.93 safe line.
    it "is not enough on the gassiest ground, where the Guibal still is" do
      worst = ReactorSim::Operations::Mine::Ground::RANGE.end

      expect(settles_at(:waddle_fan, ground: worst)).to be < ReactorSim::Breath::SAFE
      expect(settles_at(:guibal_fan, ground: worst)).to be > ReactorSim::Breath::SAFE
    end
  end

  describe "inundation" do
    # Not merely the pump stopping: a face driven hard for long enough breaks into whatever is
    # standing behind it, and then the water arrives faster than the set can lift it.
    #
    # **The fissure is seeded part-worn**, so what is tested is the breach rather than the hours
    # of driving that cause it — `Inrush#stress_per_second` owns the rate.
    it "breaks into old workings on a face that is driven hard" do
      op = cutting(pit, worn: MineTech::WORN_FISSURE)
      events = run!(op, 150)

      inrush = events.find { |e| e[:type] == :part_failed && e[:node] == :seepage }
      expect(inrush).not_to be_nil
      expect(inrush[:mode]).to be(:inrush)
    end

    # **The pair, and the sharper half of the claim**: the same nearly-gone fissure, and the only
    # thing keeping it intact is that nobody is cutting.
    it "does not break into anything on a face nobody is driving" do
      op = cutting(pit, hewing: 0, worn: MineTech::WORN_FISSURE)
      events = run!(op, 150)

      expect(events.select { |e| e[:node] == :seepage }).to be_empty
    end

    it "overwhelms the starting pump and floods the pit bottom" do
      op = cutting(pit, worn: MineTech::WORN_FISSURE)
      run!(op, 300)

      expect(water(op)).to be > 100.0
    end

    # The reason to buy the bigger set, and the shape of every upgrade in this mine: it does
    # nothing at all until the day it matters. Measured at 150 ticks: 63.9 kg against 4.4.
    it "is held by a Cornish set where a sinking set is not" do
      small = cutting(pit, worn: MineTech::WORN_FISSURE)
      big = cutting(pit(pump: :cornish_set), worn: MineTech::WORN_FISSURE)
      run!(small, 150)
      run!(big, 150)

      expect(water(big)).to be < water(small)
    end
  end

  it "conserves mass and energy through an inrush" do
    op = cutting(pit, worn: MineTech::WORN_FISSURE)
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
