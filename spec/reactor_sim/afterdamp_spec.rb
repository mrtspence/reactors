# frozen_string_literal: true

require "reactor_sim"

# **Afterdamp: what fills a mine after the fire, and what kills more people than the fire did.**
#
# The claim this file exists to prove is that it needed **no new content at all**. Firedamp
# combustion already consumes 17.2 kg of air per kilogram of gas and already hands back
# `flue_gas`; the only thing missing was anybody asking whether the people standing in the
# result could breathe. One tag on `air` and the whole hazard was already in the box.
#
# Its own crew rather than `ReferenceCrew`, and **with a real `endurance`** — the reference hand
# is `1e6` to make them tireless, and `Breath::RESERVE` clamps that so they are not immune, but
# an example about how long somebody lasts should not be measuring a clamp. See the traps list.
#
# See `docs/design_sketches/breathable-air.md`.
module AfterdampCrew
  ARCHETYPE = { label: "Collier", strength: 1.0, toughness: 1.0, endurance: 1.0,
                intelligence: 1.0, dexterity: 1.0, charisma: 1.0,
                tags: { mining_effectiveness: 0.6, shovelling: 0.5,
                        darkvision: 0.8 } }.freeze

  MINIONS = (1..4).to_h { |i| [ :"hand_#{i}", { name: "Hand #{i}", archetype: :collier,
                                                hireable: false } ] }.freeze

  CONTENT = ReactorSim::Content.default.merging(archetypes: { collier: ARCHETYPE },
                                                minions: MINIONS)

  CREW = (1..4).to_h { |i| [ :"crew_#{i}", { minion: :"hand_#{i}" } ] }.freeze
end

RSpec.describe "afterdamp" do
  before { allow(ReactorSim::Content).to receive(:default).and_return(AfterdampCrew::CONTENT) }

  SUPPLY = 9.0e4

  def pit
    ReactorSim::Match
      .create(id: "a", seed: 3,
              operations: [ { id: "pit", type: :mine, loadout: { manriding: :cage_gear },
                              ground: ReactorSim::Operations::Mine::Ground::ORDINARY,
                              crew: AfterdampCrew::CREW } ])
      .operation(:pit)
  end

  def run!(op, ticks, from: 0)
    ticks.times.flat_map do |i|
      op.receive_supply(:line_shaft, SUPPLY)
      op.step!(tick: from + i + 1)
    end
  end

  def air(op, place)
    ReactorSim::Breath.breathable_fraction(
      op.state.fetch(:nodes).fetch(op.layout.breathes(place)).fetch(:parcels), op.content
    )
  end

  def crew(op, id) = op.state.fetch(:minions).fetch(id)

  # A worked district with the shift at their posts and the fan doing its job.
  def worked(ventilation: 100, settle: 3_000)
    op = pit
    op.set_control(:winding, 100)
    op.set_control(:man_winding, 100)
    op.assign_minion(:crew_1, :hewing)
    op.assign_minion(:crew_2, :haulage)
    op.assign_minion(:crew_3, :timbering)
    run!(op, 600)

    op.set_control(:man_winding, 0)
    %i[hewing haulage timbering].each { |c| op.set_control(c, 100) }
    op.set_control(:ventilation, ventilation)
    run!(op, settle, from: 600)
    op
  end

  describe "before anything goes wrong" do
    it "leaves a ventilated pit breathable everywhere" do
      op = worked

      expect(air(op, :bank)).to eq(1.0)
      expect(air(op, :district)).to be > ReactorSim::Breath::SAFE
      expect(air(op, :pit_bottom)).to be > ReactorSim::Breath::SAFE
    end

    it "hurts nobody, however long the shift runs" do
      op = worked(settle: 4_000)

      expect(op.state.fetch(:minions).values.map { |s| s[:injury] }).to all(be_nil)
    end
  end

  describe "once the gas has been lit" do
    # **The fire eats the air**, and that is the whole mechanism: no new resource, no new
    # reaction, no new hazard declaration. Burning firedamp turns breathable air into flue gas.
    it "turns the district's air into something nobody can breathe" do
      op = worked
      before = air(op, :district)

      op.set_control(:naked_flame, 100)
      run!(op, 600, from: 3_600)

      expect(air(op, :district)).to be < before
      expect(air(op, :district)).to be < ReactorSim::Breath::SAFE
    end

    it "reaches the pit bottom as well as the face" do
      op = worked
      op.set_control(:naked_flame, 100)
      worst = 1.0
      600.times do |i|
        run!(op, 1, from: 3_600 + i)
        worst = [ worst, air(op, :pit_bottom) ].min
      end

      expect(worst).to be < ReactorSim::Breath::SAFE
    end

    # The men at the surface are never in it, which is what makes sending somebody down a
    # decision rather than a formality.
    it "never touches the pit bank" do
      op = worked
      op.set_control(:naked_flame, 100)
      run!(op, 2_000, from: 3_600)

      expect(air(op, :bank)).to eq(1.0)
      expect(crew(op, :crew_4)[:injury]).to be_nil
    end

    it "stands the shift down and puts the cause on the record" do
      op = worked
      op.set_control(:naked_flame, 100)
      events = run!(op, 2_000, from: 3_600)
      hurt = events.select { |e| e[:type] == :minion_hurt }

      expect(hurt).not_to be_empty
      expect(hurt.map { |e| e[:cause] }).to include(:asphyxia)
      expect(crew(op, :crew_1)[:injury]).not_to be_nil
    end

    # The clock, and the counterplay. **The pit bottom clears and the district does not**, so
    # who lives is decided by where they were standing — which is the entire argument for
    # hazards belonging to places.
    it "kills at the face and only stands down at the pit bottom" do
      op = worked
      op.set_control(:naked_flame, 100)
      run!(op, 6_000, from: 3_600)

      expect(crew(op, :crew_1)[:injury]).to be(:mortal)
      expect(crew(op, :crew_2)[:injury]).to be(:severe)
    end
  end
end
