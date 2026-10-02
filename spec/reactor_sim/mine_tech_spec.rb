# frozen_string_literal: true

require "reactor_sim"

# **What a player buys, and what happens when they have not.**
#
# Three things that were owed after the mine landed and are settled here: light and tools as a
# *gate* rather than a bonus, inundation as a failure that is not merely the pump stopping, and
# the cutting tier the tech tree was missing.
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
    { label: "Hand", strength: 1.0, toughness: 1.0, endurance: 1.0e6, intelligence: 1.0,
      dexterity: 1.0, charisma: 1.0, tags: tags.merge(shovelling: 0.5) }
  end

  CONTENT = ReactorSim::Content.default.merging(
    archetypes: KITS.to_h { |name, tags| [ :"hand_#{name}", archetype(tags) ] },
    minions: KITS.keys.to_h { |name|
      [ :"hand_#{name}", { name: name.to_s, archetype: :"hand_#{name}", hireable: false } ]
    }
  )
end

RSpec.describe "the mine's tech tree" do
  before { allow(ReactorSim::Content).to receive(:default).and_return(MineTech::CONTENT) }

  SUPPLY_J = 9.0e4

  # **Ordinary ground unless an example asks for worse.** How gassy and how wet a pit is is
  # drawn per match, and a spec comparing two fittings has to hold it still or it is comparing
  # luck — the same argument that keeps `ReferenceCrew` out of `content/minions/`.
  ORDINARY = ReactorSim::Operations::Mine::Ground::ORDINARY

  def pit(kit: :proper, ground: ORDINARY, **loadout)
    hand = :"hand_#{kit}"
    ReactorSim::Match
      .create(id: "t", seed: 5,
              operations: [ { id: "pit", type: :mine,
                              loadout: { manriding: :cage_gear, **loadout },
                              ground: ground,
                              crew: (1..4).to_h { |i| [ :"crew_#{i}", { minion: hand } ] } } ])
      .operation(:pit)
  end

  def run!(op, ticks, from: 0)
    events = []
    ticks.times do |i|
      op.receive_supply(:line_shaft, SUPPLY_J)
      events.concat(op.step!(tick: from + i + 1))
    end
    events
  end

  def coal_in_seam(op)
    op.state.fetch(:nodes).fetch(:seam).fetch(:parcels)
      .find { |p| p.fetch(:resource) == :coal }.fetch(:kg)
  end

  def water(op)
    (op.state.fetch(:nodes).fetch(:pit_bottom).fetch(:parcels)
       .find { |p| p.fetch(:resource) == :water }&.fetch(:kg)) || 0.0
  end

  # A shift at the face with the levers over, and the walk already done.
  def cutting(op, hewing: 100, timbering: 100)
    op.set_control(:winding, 100)
    op.set_control(:man_winding, 100)
    op.assign_minion(:crew_1, :hewing)
    op.assign_minion(:crew_2, :haulage)
    op.assign_minion(:crew_3, :timbering)
    run!(op, 600)
    op.set_control(:man_winding, 0)
    op.set_control(:hewing, hewing)
    op.set_control(:haulage, 100)
    op.set_control(:timbering, timbering)
    op
  end

  def cut_over(op, ticks, from: 600)
    before = coal_in_seam(op)
    run!(op, ticks, from: from)
    before - coal_in_seam(op)
  end

  describe "light and tools are a gate, not a bonus" do
    # **The claim the sketch made and the code did not keep.** `aided_by:` adds, so a hewer with
    # no pick was merely unaided; `gated_by:` multiplies, so they are useless — which is the
    # honest model of a job that cannot be done without the thing.
    it "wins no coal at all from a hewer with neither pick nor light" do
      op = cutting(pit(kit: :bare))

      expect(cut_over(op, 2_000)).to eq(0.0)
    end

    it "wins none from somebody who can see but has nothing to cut with" do
      lit = MineTech.archetype(darkvision: 1.0)
      content = ReactorSim::Content.default.merging(
        archetypes: { hand_lit: lit },
        minions: { hand_lit: { name: "Lit", archetype: :hand_lit, hireable: false } }
      )
      allow(ReactorSim::Content).to receive(:default).and_return(content)

      op = ReactorSim::Match
           .create(id: "t", seed: 5,
                   operations: [ { id: "pit", type: :mine,
                                   loadout: { manriding: :cage_gear },
                                   ground: ORDINARY,
                                   crew: (1..4).to_h { |i|
                                     [ :"crew_#{i}", { minion: :hand_lit } ]
                                   } } ])
           .operation(:pit)

      expect(cut_over(cutting(op), 2_000)).to eq(0.0)
    end

    # Ratios, never figures: the shape is the claim.
    it "pays for every step up in kit" do
      candle = cut_over(cutting(pit(kit: :candle)), 2_000)
      lamp = cut_over(cutting(pit(kit: :lamp)), 2_000)
      proper = cut_over(cutting(pit(kit: :proper)), 2_000)

      expect(candle).to be > 0.0
      expect(lamp).to be > candle
      expect(proper).to be > lamp
    end
  end

  describe "the cutting tier" do
    it "gets far more coal out of the same face with a machine" do
      by_hand = cut_over(cutting(pit), 2_000)
      by_machine = cut_over(cutting(pit(cutting: :coal_cutter)), 2_000)

      expect(by_machine).to be > by_hand
    end

    # The part that actually changes a shift: a hewer is spent in twenty minutes and a machine
    # is not, so the seat the cutter frees is worth more than the coal it adds.
    it "costs the hewer far less of themselves" do
      expect(pit(cutting: :coal_cutter).control_points.fetch(:hewing).exertion)
        .to be < pit.control_points.fetch(:hewing).exertion
    end
  end

  # **Light is a gate, so the lighting tier is the one upgrade that can take output from
  # nothing to something.** Hewing multiplies `darkvision`, and a gate is a zero when it is
  # missing — a shift at an unlit face is being paid to stand in the dark.
  #
  describe "the lighting tier" do
    # The `:pick` kit throughout — tools and no lamp — so the only light at the face is the
    # room's and `Minion#gate`'s better-of-the-two has nothing carried to prefer.
    #
    # **The window is short on purpose.** An open flame fires the district even with the fan
    # hard over, so measuring far enough out compares how long each pit lasted rather than how
    # well it was lit — and inverts the order. That the flame tiers go up at all is the next
    # example's claim, not this one's.
    def won(tier, light:)
      op = cutting(pit(kit: :pick, lighting: tier))
      op.set_control(:ventilation, 100)
      op.set_control(op.control_points.key?(:naked_flame) ? :naked_flame : :safe_light, light)
      cut_over(op, 600)
    end

    it "lights a face for somebody carrying no lamp" do
      expect(won(:oil_flares, light: 0)).to eq(0.0)
      expect(won(:oil_flares, light: 100)).to be > 0.0
    end

    # The trade, in both directions: the brightest flame beats the safe lantern that replaces
    # it, and the safe lantern is the one that does not fire the district.
    it "pays for light, and the safe tier costs some of it" do
      candles = won(:tallow_candles, light: 100)
      flares = won(:oil_flares, light: 100)
      lanterns = won(:gauze_lanterns, light: 100)

      expect(flares).to be > candles
      expect(lanterns).to be < flares
      expect(lanterns).to be > candles
    end

    # **The whole point of a safety lamp, as a lever rather than a tag.** The district's
    # igniter names the open-flame control; a safe tier declares a different one, so there is
    # no ignition source in the room at all however gassy it gets.
    it "fires the district on an open flame and never on a safe one" do
      fired = %i[tallow_candles oil_flares gauze_lanterns electric_lamps].to_h do |tier|
        op = pit(lighting: tier)
        lever = op.control_points.key?(:naked_flame) ? :naked_flame : :safe_light
        op.set_control(lever, 100)
        # No supply at all, so the fan is stopped and the gas builds: the worst case there is.
        events = 2_500.times.flat_map { |i| op.step!(tick: i + 1) }
        [ tier, events.any? { |e| e[:node] == :district && e[:type] == :part_failed } ]
      end

      expect(fired.select { |_, lit| lit }.keys).to contain_exactly(:tallow_candles, :oil_flares)
    end

    # **And the fan does not buy it off.** A worked district lit by flares goes up with the
    # ventilation hard over and a shift cutting at it — so an open flame is not a hazard a
    # player can ventilate their way out of, only one they can replace.
    it "goes up on an open flame even with the fan hard over" do
      op = cutting(pit(kit: :pick, lighting: :oil_flares))
      op.set_control(:ventilation, 100)
      op.set_control(:naked_flame, 100)
      events = run!(op, 1_200, from: 600)

      expect(events.any? { |e| e[:node] == :district && e[:type] == :part_failed }).to be(true)
    end
  end

  # **What a better fan actually buys, and it is not a bigger number on a gauge.**
  #
  # Historically the Guibal is why Victorian pits stopped being places you could suffocate in
  # while working normally — the upgrade is measured in breathable air, not in airflow. Both
  # tiers keep a worked district above `Breath::SAFE`, so this is not about surviving; it is
  # about **how much margin there is before anything goes wrong**, which is what a player is
  # buying and what they never see directly.
  describe "the ventilation tier" do
    def margin(fan, ground: ORDINARY)
      op = cutting(pit(fan: fan, ground: ground))
      op.set_control(:ventilation, 100)
      worst = 1.0
      2_000.times do |t|
        run!(op, 1, from: 600 + t)
        worst = [ worst, breathable(op, :district) ].min
      end
      worst - ReactorSim::Breath::SAFE
    end

    def breathable(op, place)
      ReactorSim::Breath.breathable_fraction(
        op.state.fetch(:nodes).fetch(op.layout.breathes(place)).fetch(:parcels), op.content
      )
    end

    it "leaves a worked district breathable on either fan" do
      expect(margin(:waddle_fan)).to be > 0.0
      expect(margin(:guibal_fan)).to be > 0.0
    end

    # The cheap fan holds the line and nothing more; the Guibal buys room to be unlucky in.
    it "buys several times the margin before anybody is suffering" do
      expect(margin(:guibal_fan)).to be > margin(:waddle_fan) * 2.0
    end

    # **And on the worst ground the cheap fan does not hold the line at all**, which is what
    # makes `Ground` a mechanic rather than a flavour. A range the starting machine always
    # copes with changes nothing; some pits have to be bought out of.
    it "is not enough on the gassiest ground, where the Guibal still is" do
      worst = ReactorSim::Operations::Mine::Ground::RANGE.end

      expect(margin(:waddle_fan, ground: worst)).to be < 0.0
      expect(margin(:guibal_fan, ground: worst)).to be > margin(:waddle_fan, ground: worst)
    end
  end

  describe "inundation" do
    # Not merely the pump stopping: a face driven hard for long enough breaks into whatever is
    # standing behind it, and then the water arrives faster than the set can lift it.
    it "breaks into old workings on a face that is driven hard" do
      op = cutting(pit)
      events = run!(op, 12_000, from: 600)

      inrush = events.find { |e| e[:type] == :part_failed && e[:node] == :seepage }
      expect(inrush).not_to be_nil
      expect(inrush[:mode]).to be(:inrush)
    end

    it "does not break into anything on a face nobody is driving" do
      op = cutting(pit, hewing: 0)
      events = run!(op, 12_000, from: 600)

      expect(events.select { |e| e[:node] == :seepage }).to be_empty
    end

    it "overwhelms the starting pump and floods the pit bottom" do
      op = cutting(pit)
      op.set_control(:pumping, 100)
      run!(op, 12_000, from: 600)

      expect(water(op)).to be > 1_000.0
    end

    # The reason to buy the bigger set, and the shape of every upgrade in this mine: it does
    # nothing at all until the day it matters.
    it "is held by a Cornish set where a sinking set is not" do
      small = cutting(pit)
      small.set_control(:pumping, 100)
      run!(small, 12_000, from: 600)

      big = cutting(pit(pump: :cornish_set))
      big.set_control(:pumping, 100)
      run!(big, 12_000, from: 600)

      expect(water(big)).to be < water(small)
    end
  end

  it "conserves mass and energy through an inrush" do
    op = cutting(pit)
    mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

    run!(op, 12_000, from: 600)

    mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    expect((mass - mass0).abs / mass0.abs).to be < 1e-9, "mass drifted by #{mass - mass0}"
    expect((joules - joules0).abs / joules0.abs).to be < 1e-9,
      "energy drifted by #{joules - joules0}"
  end
end
