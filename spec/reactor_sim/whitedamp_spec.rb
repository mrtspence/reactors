# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **Whitedamp: the one that does not have to displace anything.**
#
# Blackdamp kills by taking the place of air. A lungful that is still 99.8% good air will kill you
# just as dead if the rest is carbon monoxide, and there is nothing to see, smell or read off a
# flame — a lamp burns perfectly well in air that is killing you.
#
# It is also the only damp the mine **makes** rather than receives. Firedamp and blackdamp come out
# of the ground whatever anybody does; this appears because a fire was smothered, which is why it
# needed reaction pathways rather than a seep: the causation is the thing a player can act on, and
# a source node would have reproduced the gas and lost it.
#
# Its own crew with a real `endurance` — bad air drains `fatigue` rather than a pool of its own, so
# with the tireless fixture every claim below would pass while proving the opposite.
#
# See `docs/design_sketches/reaction-pathways.md` stage B and `design_sketches/suite-runtime.md`.
RSpec.describe "whitedamp" do
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::TIRING_CONTENT) }

  # **Where in the explosive range the mixture is when it lights decides what it makes**, and that
  # is the whole experiment. At the lean end there is air to spare and the gas burns clean; at the
  # rich end the district cannot supply the oxygen to finish the job, so the carbon comes away as
  # monoxide.
  #
  # **Stated by mass**, because that is what `district_mix` and `gas_pct` speak and mixing the two
  # bases moves every figure by nearly a factor of two. These correspond to about 11% and 15% by
  # volume. Measured whitedamp made across the band: 4% and 5% by mass make **none at all**, 6%
  # makes 0.97 kg, 7% makes 10.6, 8% makes 16.0 — and 10% does not light, being past the rich
  # limit, which is `district_fire_spec`'s claim rather than this file's.
  def clean_pct = 6.0

  def starved_pct = 8.0

  # Enough monoxide to poison the district, which is a very small amount: `toxic_fraction` is
  # 0.0015 of the volume, so the line sits between 1 and 3 kg in a 1,400 m³ district.
  def poisonous_kg = 3.0

  def pit = build_pit(id: "w", seed: 3, loadout: { manriding: :cage_gear })

  def poisoned?(op, node) = ReactorSim::Breath.poisoned?(parcels(op, node), op.content)

  def canary(op)
    state = op.state.dig(:diagnostics, :canary)
    op.diagnostics.fetch(:canary).display.render(state.fetch(:value), state.fetch(:flags, []))
  end

  def pit_with(**mix) = at_the_face(seed(pit, nodes: { district: district_mix(pit, **mix) }))

  def work!(op, ticks, ventilation: 0, naked_flame: 0, hewing: 0, from: 0, **levers)
    levers!(op, hewing: hewing, haulage: 100, timbering: 100, winding: 100, pumping: 100,
                ventilation: ventilation, naked_flame: naked_flame, **levers)

    run!(op, ticks, from: from)
  end

  # Light a constructed mixture and let it burn out.
  def ignited(pct, ticks: 60)
    op = pit_with(firedamp: gas_kg(pct))
    work!(op, ticks, ventilation: 0, naked_flame: 100)
    op
  end

  describe "where it comes from" do
    it "is not in the ground — an unlit district has none of it" do
      op = pit_with
      work!(op, 200, hewing: 100, ventilation: 100)

      expect(held(op, :district, :whitedamp)).to eq(0.0)
    end

    # **The causation, and the reason this needed pathways rather than a seep.** The same ignition
    # in the same district makes a twentieth as much when the air is there to burn cleanly.
    #
    # A ratio, never a figure: any ignition makes a little monoxide, because the burn runs far
    # faster than the air reaches it and goes momentarily short even with plenty to spare. What
    # the causation claims is the **gap**, which measures at about sixteen times.
    it "is made by fire that could not get air, and not by fire that could" do
      starved = ignited(starved_pct)
      clean = ignited(clean_pct)

      expect(held(starved, :district, :whitedamp)).to be > 0.0
      expect(held(clean, :district, :whitedamp)).to be > 0.0
      expect(held(clean, :district, :whitedamp))
        .to be < held(starved, :district, :whitedamp) * 0.3
    end
  end

  describe "what makes it different from every other damp" do
    # The distinguishing claim: the air is *mostly fine* and lethal anyway. Blackdamp and afterdamp
    # cannot do this — they have to take up the room to hurt you.
    it "poisons air that is still overwhelmingly breathable by volume" do
      op = pit_with(whitedamp: poisonous_kg)

      expect(poisoned?(op, :district)).to be(true)
      expect(held(op, :district, :whitedamp)).to be < 20.0
      # And the point: by volume there is essentially nothing wrong with it.
      expect(ReactorSim::Breath.breathable_fraction(parcels(op, :district), op.content))
        .to be > ReactorSim::Breath::SAFE
    end

    it "weighs almost nothing next to the afterdamp beside it" do
      op = ignited(starved_pct)

      expect(held(op, :district, :whitedamp)).to be < held(op, :district, :flue_gas) * 0.1
    end

    # Poisoned air reads as no air at all, which is how `Breath` is told about a hazard that has
    # nothing to do with displacement.
    it "leaves nobody in the district able to breathe" do
      op = ignited(starved_pct)

      expect(crew(op, :crew_1).fetch(:injury)).not_to be_nil
    end
  end

  describe "the counterplay" do
    # It clears fast *because* there is so little of it — the opposite of afterdamp, which is
    # hundreds of kilograms and takes hours. Turning the fan on is the whole answer.
    #
    # **Seeded rather than burnt**, because what is claimed is that the fan clears monoxide, not
    # how much a particular explosion made: a 16 kg charge from a starved burn needs well over a
    # thousand ticks, which measures the size of that explosion instead.
    it "is swept out by the ventilation in minutes" do
      op = pit_with(whitedamp: poisonous_kg)
      expect(poisoned?(op, :district)).to be(true)

      work!(op, 200, ventilation: 100)

      expect(poisoned?(op, :district)).to be(false)
    end
  end

  describe "the canary" do
    it "sings in a district that is merely being worked" do
      op = pit_with
      work!(op, 100, hewing: 100, ventilation: 100)

      expect(canary(op)).to eq("singing")
    end

    # **The bird goes over before the air is lethal, and that gap is the rescue window.** It is the
    # only warning there is: whitedamp has no smell and no effect on a flame.
    it "goes down in air that has been poisoned" do
      op = pit_with(whitedamp: poisonous_kg)
      work!(op, 60, ventilation: 0)

      expect(canary(op)).to match(/distressed|down/)
    end
  end

  it "conserves mass and energy through a starved ignition" do
    op = pit_with(firedamp: gas_kg(starved_pct))
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
