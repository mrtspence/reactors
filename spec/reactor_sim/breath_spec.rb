# frozen_string_literal: true

require "reactor_sim"

# **Whether the air where somebody is standing will keep them alive.**
#
# `air` is the only substance tagged `breathable`; everything else asphyxiates by taking up the
# room it was in. That one tag is the whole model, and the reason afterdamp needed no content of
# its own: firedamp combustion eats 17.2 kg of air per kilogram of gas and hands back `flue_gas`.
#
# Bad air drains `fatigue` rather than a pool of its own, so somebody works worse before they
# drop and recovers when they reach clean air. Pinned at the ceiling **in bad air** is the
# collapse; the clock from there to a mortal injury is what makes rescue worth doing.
#
# See `docs/design_sketches/breathable-air.md`.
RSpec.describe ReactorSim::Breath do
  STATS = { strength: 1.0, toughness: 1.0, endurance: 1.0,
            intelligence: 1.0, dexterity: 1.0, charisma: 1.0 }.freeze

  def content = ReactorSim::Content.default

  def parcels(mix)
    mix.map { |resource, kg| ReactorSim::Parcel.build(resource:, kg:, temperature_k: 293.15,
                                                      content: content) }
  end

  def volume(id, mix)
    ReactorSim::Nodes::Vessel.new(
      id: id, label: id.to_s, volume_m3: 50.0, heat_capacity: 1.0e4, ambient_conductance: 0.0,
      ports: [ ReactorSim::Port.new(id: :vent, direction: :inlet, accepts: [ :gas ]) ],
      initial_contents: mix.map { |r, kg| { resource: r, kg: kg, temperature_k: 293.15 } }
    )
  end

  # Two rooms a short walk apart: the one with the mixture in it, and clean air outside. The
  # walk is what lets an example get somebody out of the bad air without moving the air.
  def room(mix, tags: {}, stats: STATS)
    ReactorSim::Operation.new(
      id: :rig, type: :test, seed: 1,
      nodes: [ volume(:room, mix), volume(:outside, { air: 60.0 }) ],
      places: [ ReactorSim::Place.new(id: :room, nodes: [ :room ]),
                ReactorSim::Place.new(id: :outside, nodes: [ :outside ]) ],
      passages: [ ReactorSim::Passage.new(a: :room, b: :outside, metres: 4.0) ],
      control_points: [ ReactorSim::ControlPoint.new(id: :post, place: :room),
                        ReactorSim::ControlPoint.new(id: :door, place: :outside) ],
      minions: [ ReactorSim::Minion.new(id: :hand, name: "Hand", stats: stats, tags: tags,
                                        station: :post, place: :room) ]
    )
  end

  def run!(op, ticks) = ticks.times.flat_map { |i| op.step!(tick: i + 1) }

  def hand(op) = op.state.fetch(:minions).fetch(:hand)

  # 60 kg of air is about 49 m³; 1 kg of firedamp is 1.5 m³ — a hair under 3%.
  GOOD = { air: 60.0 }.freeze
  FOUL = { air: 30.0, flue_gas: 40.0 }.freeze

  describe "what counts as breathable" do
    it "measures by volume, not by mass" do
      # Equal masses of air and firedamp. Firedamp is 0.668 kg/m³ against air's 1.225, so by
      # mass this reads as half breathable and by volume as barely a third — and it is
      # displacement that suffocates.
      fraction = described_class.breathable_fraction(parcels({ air: 10.0, firedamp: 10.0 }),
                                                     content)

      expect(fraction).to be < 0.4
    end

    it "is everything when the room holds only air" do
      expect(described_class.breathable_fraction(parcels({ air: 10.0 }), content)).to eq(1.0)
    end

    # Nothing to breathe is not clean air. A vacuum must not read as the safest place in the mine.
    it "is nothing at all when the room holds nothing" do
      expect(described_class.breathable_fraction([], content)).to eq(0.0)
    end

    # The claim the whole release rests on: the product of combustion is not breathable, so
    # afterdamp needs no resource of its own.
    it "does not count what a fire leaves behind" do
      expect(described_class.breathable_fraction(parcels({ flue_gas: 10.0 }), content)).to eq(0.0)
    end
  end

  describe "what bad air does" do
    it "costs nothing at all in clean air" do
      op = room(GOOD)
      run!(op, 200)

      expect(hand(op)[:fatigue]).to eq(0.0)
    end

    it "drains fatigue when the air is foul" do
      op = room(FOUL)
      run!(op, 100)

      expect(hand(op)[:fatigue]).to be > 0.0
    end

    it "drains faster the worse the air is" do
      bad = room({ air: 40.0, flue_gas: 30.0 })
      worse = room({ air: 10.0, flue_gas: 60.0 })
      run!(bad, 60)
      run!(worse, 60)

      expect(hand(worse)[:fatigue]).to be > hand(bad)[:fatigue]
    end

    # Recovery needs no mechanism of its own: fatigue already does it, so walking out is enough.
    it "recovers once they are breathing again" do
      op = room(FOUL)
      run!(op, 100)
      choked = hand(op)[:fatigue]

      op.assign_minion(:hand, :door)
      run!(op, 400)

      expect(hand(op)[:place]).to be(:outside)
      expect(hand(op)[:fatigue]).to be < choked
    end
  end

  describe "who it does not reach" do
    it "leaves the unbreathing alone entirely" do
      op = room(FOUL, tags: { unbreathing: true })
      run!(op, 200)

      expect(hand(op)[:fatigue]).to eq(0.0)
    end

    # Apparatus, and apparatus is imperfect: it slows the air down, it does not shut it out.
    #
    # **`respirator_air` is not optional**: a set with no air in it is a mask full of the same
    # air as the room, so every example about filtering has to charge one.
    it "is slower through a respirator, and still gets through" do
      bare = room({ air: 5.0, flue_gas: 70.0 })
      masked = room({ air: 5.0, flue_gas: 70.0 },
                    tags: { respirator: 0.8, respirator_air: 9_600 })
      run!(bare, 60)
      run!(masked, 60)

      expect(hand(masked)[:fatigue]).to be < hand(bare)[:fatigue]
      expect(hand(masked)[:fatigue]).to be > 0.0
    end

    # **Ordinary recovery is doing real work here**, and it is why a respirator is worth buying
    # rather than merely worth having: in air this bad it nets the drain to nothing and the
    # wearer is simply fine, where the same air spends an unmasked man.
    it "makes moderately foul air survivable for as long as the set lasts" do
      op = room(FOUL, tags: { respirator: 0.8, respirator_air: 9_600 })
      run!(op, 400)

      expect(hand(op)[:fatigue]).to eq(0.0)
    end

    # **Apparatus runs out, and the set is worth nothing the moment it does.** No taper: there
    # is no half a breath. This is what makes a rescue a race rather than a decision.
    it "stops protecting once the set is empty" do
      op = room({ air: 5.0, flue_gas: 70.0 }, tags: { respirator: 0.85, respirator_air: 100 })
      run!(op, 100)
      masked = hand(op)[:fatigue]
      expect(hand(op)[:apparatus]).to eq(0.0)

      run!(op, 100)

      # The second hundred ticks, unprotected, cost far more than the first hundred did.
      expect(hand(op)[:fatigue] - masked).to be > masked
    end

    it "spends the set only where the air is bad" do
      good = room(GOOD, tags: { respirator: 0.85, respirator_air: 100 })
      foul = room(FOUL, tags: { respirator: 0.85, respirator_air: 100 })
      run!(good, 50)
      run!(foul, 50)

      expect(hand(good)[:apparatus]).to eq(100.0)
      expect(hand(foul)[:apparatus]).to eq(50.0)
    end

    # Somebody with no set is unaffected by the accounting, which is every minion in the game
    # until one is bought.
    it "leaves the unequipped alone" do
      op = room(FOUL)

      run!(op, 50)

      expect(hand(op)[:apparatus]).to eq(0.0)
    end

    # **`ReferenceCrew` sets `endurance: 1e6` to make a reference hand tireless.** Unclamped as a
    # divisor that would make them immune to suffocating, and every spec built on them would
    # pass while proving nothing — the same trap `Minion::PACE` fell into with `TIRELESS`.
    it "still reaches somebody the fixtures made tireless" do
      op = room(FOUL, stats: STATS.merge(endurance: 1.0e6))
      run!(op, 200)

      expect(hand(op)[:fatigue]).to be > 0.0
    end
  end

  describe "collapse" do
    # Pinned at the ceiling is not enough on its own — a stoker flat out reaches it too.
    it "does not touch somebody merely spent in good air" do
      op = room(GOOD)
      200.times { |i| op.step!(tick: i + 1) }
      expect(hand(op)[:injury]).to be_nil
    end

    it "stands somebody down once they are pinned at the ceiling in bad air" do
      op = room({ air: 5.0, flue_gas: 70.0 })
      run!(op, 400)

      expect(hand(op)[:fatigue]).to eq(1.0)
      expect(hand(op)[:injury]).to be(:severe)
      expect(hand(op)[:station]).to be_nil
    end

    # The clock, and it is the reason to go back for anybody.
    it "runs a clock from stood down to the injury list" do
      op = room({ air: 5.0, flue_gas: 70.0 })
      events = run!(op, 400)
      expect(hand(op)[:asphyxia]).to be < 1.0

      events.concat(run!(op, 1_200))

      expect(hand(op)[:injury]).to be(:mortal)
      modes = events.select { |e| e[:type] == :minion_hurt }.map { |e| e[:mode] }
      expect(modes).to eq(%i[severe mortal])
    end

    it "reports the cause, so a mortal from the air is not a mortal from a blast" do
      op = room({ air: 5.0, flue_gas: 70.0 })
      event = run!(op, 400).find { |e| e[:type] == :minion_hurt }

      expect(event[:cause]).to be(:asphyxia)
      expect(event.dig(:detail, :place)).to be(:room)
    end
  end

  # Nothing here draws a die, exactly as the Danger Check does not — so a suffocating minion
  # replays bit for bit.
  it "draws no entropy" do
    first = room({ air: 5.0, flue_gas: 70.0 })
    second = room({ air: 5.0, flue_gas: 70.0 })
    run!(first, 500)
    run!(second, 500)

    expect(hand(first)).to eq(hand(second))
  end
end
