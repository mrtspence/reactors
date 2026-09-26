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

  def pit(kit: :proper, **loadout)
    hand = :"hand_#{kit}"
    ReactorSim::Match
      .create(id: "t", seed: 5,
              operations: [ { id: "pit", type: :mine,
                              loadout: { manriding: :cage_gear, **loadout },
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

  # **What a better fan actually buys, and it is not a bigger number on a gauge.**
  #
  # Historically the Guibal is why Victorian pits stopped being places you could suffocate in
  # while working normally — the upgrade is measured in breathable air, not in airflow. Both
  # tiers keep a worked district above `Breath::SAFE`, so this is not about surviving; it is
  # about **how much margin there is before anything goes wrong**, which is what a player is
  # buying and what they never see directly.
  describe "the ventilation tier" do
    def margin(fan)
      op = cutting(pit(fan: fan))
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
