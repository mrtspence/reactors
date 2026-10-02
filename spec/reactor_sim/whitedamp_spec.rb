# frozen_string_literal: true

require "reactor_sim"

# **Whitedamp: the one that does not have to displace anything.**
#
# Blackdamp kills by taking the place of air. A lungful that is still 99.8% good air will kill
# you just as dead if the rest is carbon monoxide, and there is nothing to see, smell or read
# off a flame — a lamp burns perfectly well in air that is killing you.
#
# It is also the only damp the mine **makes** rather than receives. Firedamp and blackdamp come
# out of the ground whatever anybody does; this appears because a fire was smothered, which is
# why it needed reaction pathways rather than a seep: the causation is the thing a player can
# act on, and a source node would have reproduced the gas and lost it.
#
# See `docs/design_sketches/reaction-pathways.md` stage B.
module WhitedampCrew
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

RSpec.describe "whitedamp" do
  before { allow(ReactorSim::Content).to receive(:default).and_return(WhitedampCrew::CONTENT) }

  def pit
    ReactorSim::Match
      .create(id: "w", seed: 3,
              operations: [ { id: "pit", type: :mine, loadout: { manriding: :cage_gear },
                              ground: ReactorSim::Operations::Mine::Ground::ORDINARY,
                              crew: WhitedampCrew::CREW } ])
      .operation(:pit)
  end

  def run!(op, ticks, from: 0)
    ticks.times.flat_map do |i|
      op.receive_supply(:line_shaft, 9.0e4)
      op.step!(tick: from + i + 1)
    end
  end

  def held(op, node, resource)
    (op.state.fetch(:nodes).fetch(node).fetch(:parcels)
       .find { |p| p.fetch(:resource) == resource }&.fetch(:kg)) || 0.0
  end

  def parcels(op, node) = op.state.fetch(:nodes).fetch(node).fetch(:parcels)

  def poisoned?(op, node) = ReactorSim::Breath.poisoned?(parcels(op, node), op.content)

  def displaced(op, node)
    1.0 - ReactorSim::Breath.breathable_fraction(parcels(op, node), op.content)
  end

  def canary(op)
    state = op.state.dig(:diagnostics, :canary)
    op.diagnostics.fetch(:canary).display.render(state.fetch(:value), state.fetch(:flags, []))
  end

  # A worked district, then a naked light in it. `ventilation:` is the whole experiment.
  def ignited(ventilation:, after: 1_000)
    op = pit
    op.set_control(:winding, 100)
    op.set_control(:man_winding, 100)
    op.assign_minion(:crew_1, :hewing)
    op.assign_minion(:crew_3, :timbering)
    run!(op, 600)

    op.set_control(:man_winding, 0)
    op.set_control(:hewing, 100)
    op.set_control(:timbering, 100)
    op.set_control(:ventilation, ventilation)
    run!(op, 3_000, from: 600)

    op.set_control(:naked_flame, 100)
    run!(op, after, from: 3_600)
    op
  end

  describe "where it comes from" do
    it "is not in the ground — an unlit district has none of it" do
      op = pit
      run!(op, 3_000)

      expect(held(op, :district, :whitedamp)).to eq(0.0)
    end

    # **The causation, and the reason this needed pathways rather than a seep.** The same
    # ignition in the same district makes none of it when the air is there to burn cleanly.
    it "is made by fire that could not get air, and not by fire that could" do
      starved = ignited(ventilation: 0)
      clean = ignited(ventilation: 100)

      expect(held(starved, :district, :whitedamp)).to be > 0.0
      expect(held(clean, :district, :whitedamp)).to eq(0.0)
    end
  end

  describe "what makes it different from every other damp" do
    # The distinguishing claim: the air is *mostly fine* and lethal anyway. Blackdamp and
    # afterdamp cannot do this — they have to take up the room to hurt you.
    it "poisons air that is still overwhelmingly breathable by volume" do
      op = ignited(ventilation: 0)

      expect(poisoned?(op, :district)).to be(true)
      expect(held(op, :district, :whitedamp)).to be < 20.0
    end

    it "weighs almost nothing next to the afterdamp beside it" do
      op = ignited(ventilation: 0)

      expect(held(op, :district, :whitedamp)).to be < held(op, :district, :flue_gas) * 0.1
    end

    # Poisoned air reads as no air at all, which is how `Breath` is told about a hazard that
    # has nothing to do with displacement.
    it "leaves nobody in the district able to breathe" do
      op = ignited(ventilation: 0, after: 2_000)

      expect(op.state.dig(:minions, :crew_1, :injury)).not_to be_nil
    end
  end

  describe "the counterplay" do
    # It clears fast *because* there is so little of it — the opposite of afterdamp, which is
    # hundreds of kilograms and takes hours. Turning the fan on is the whole answer.
    it "is swept out by the ventilation in minutes" do
      op = ignited(ventilation: 0)
      expect(poisoned?(op, :district)).to be(true)

      op.set_control(:naked_flame, 0)
      op.set_control(:hewing, 0)
      op.set_control(:ventilation, 100)
      run!(op, 2_000, from: 4_600)

      expect(poisoned?(op, :district)).to be(false)
    end
  end

  describe "the canary" do
    it "sings in a district that is merely being worked" do
      op = pit
      run!(op, 2_000)

      expect(canary(op)).to eq("singing")
    end

    # **The bird goes over before the air is lethal, and that gap is the rescue window.** It is
    # the only warning there is: whitedamp has no smell and no effect on a flame.
    it "goes down in air that has been poisoned" do
      op = ignited(ventilation: 0, after: 2_000)

      expect(canary(op)).to match(/distressed|down/)
    end
  end

  it "conserves mass and energy through a starved ignition" do
    fresh = pit
    mass0 = ReactorSim::Ledger.mass_balance(fresh.total_mass, fresh.ledger)
    joules0 = ReactorSim::Ledger.energy_balance(fresh.total_joules, fresh.ledger)

    op = ignited(ventilation: 0, after: 2_000)
    mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

    expect((mass - mass0).abs / mass0.abs).to be < 1e-9, "mass drifted by #{mass - mass0}"
    expect((joules - joules0).abs / joules0.abs).to be < 1e-9,
                                                    "energy drifted by #{joules - joules0}"
  end
end
