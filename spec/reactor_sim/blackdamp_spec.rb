# frozen_string_literal: true

require "reactor_sim"

# **Blackdamp: the quiet one, and the opposite of firedamp in every way that matters.**
#
# Air with the oxygen already taken out of it, left where coal has slowly oxidised in the
# worked-out ground. It does not burn and it does not explode; it kills by being there instead
# of air, and there is nothing to smell. Heavier than air, so it lies in the dips — which makes
# it **the pit bottom's hazard where firedamp is the face's**.
#
# The warning is the instrument, and it is the only gauge in this operation that trips before
# the danger does: a flame lamp dulls and goes out in blackdamp well before a man collapses in
# it. That is why the lamp was still worth carrying for something other than light.
#
# Its own crew, with a real `endurance` — see `afterdamp_spec` for why.
#
# See `docs/design_sketches/breathable-air.md` stage C.
module BlackdampCrew
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

RSpec.describe "blackdamp" do
  before { allow(ReactorSim::Content).to receive(:default).and_return(BlackdampCrew::CONTENT) }

  def pit
    ReactorSim::Match
      .create(id: "b", seed: 3,
              operations: [ { id: "pit", type: :mine, loadout: { manriding: :cage_gear },
                              crew: BlackdampCrew::CREW } ])
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

  def air(op, place)
    ReactorSim::Breath.breathable_fraction(
      op.state.fetch(:nodes).fetch(op.layout.breathes(place)).fetch(:parcels), op.content
    )
  end

  def lamp(op)
    state = op.state.dig(:diagnostics, :lamp_flame)
    op.diagnostics.fetch(:lamp_flame)
      .display.render(state.fetch(:value), state.fetch(:flags, []))
  end

  # A pit with the putter at the bottom, where the blackdamp is.
  def worked(ventilation:, ticks: 3_000)
    op = pit
    op.set_control(:winding, 100)
    op.set_control(:man_winding, 100)
    op.assign_minion(:crew_2, :haulage)
    run!(op, 600)

    op.set_control(:man_winding, 0)
    op.set_control(:haulage, 100)
    op.set_control(:ventilation, ventilation)
    run!(op, ticks, from: 600)
    op
  end

  describe "where it comes from" do
    # Unlike firedamp, which the face gives off while it is being worked, blackdamp comes out of
    # ground nobody goes into any more — so it arrives whether or not anybody is cutting.
    it "seeps out of the old workings with nobody doing anything" do
      op = pit
      run!(op, 2_000)

      expect(held(op, :pit_bottom, :blackdamp)).to be > 0.0
      expect(op.state.dig(:controls, :hewing, :actual)).to eq(0.0)
    end

    # **The low point of the mine, because it is heavier than air.** Firedamp collects in the
    # roof at the face; this lies in the dips, and the deepest dip is the shaft bottom.
    it "collects at the pit bottom rather than at the face" do
      op = worked(ventilation: 0)

      expect(held(op, :pit_bottom, :blackdamp)).to be > held(op, :district, :blackdamp)
    end

    # **It is inert because no reaction names it**, which is the whole mechanism — a substance
    # is a reagent by being listed, so being left out of every list is what "will not burn"
    # means. Asserted against the registry rather than by weighing a district afterwards: an
    # explosion drives the atmosphere out through the return, so blackdamp does leave, and a
    # mass test would be measuring the blast rather than the chemistry.
    it "is in no reaction at all, as a reagent or as a product" do
      named = ReactorSim::Content.default.reactions.values.flat_map do |spec|
        spec.fetch(:consumes, {}).keys + spec.fetch(:produces, {}).keys
      end

      expect(named).not_to include(:blackdamp)
    end

    # And the consequence a player sees: it is still down there after the blast. It does lose
    # some — an explosion drives the atmosphere out through the return — but it is dispersed
    # rather than consumed, where a fuel in the same volume is spent.
    it "is still there after an ignition" do
      op = worked(ventilation: 0)
      damp = held(op, :pit_bottom, :blackdamp)

      op.set_control(:naked_lights, 100)
      run!(op, 2_000, from: 3_600)

      expect(held(op, :pit_bottom, :blackdamp)).to be > damp * 0.5
    end

    # **And it makes the explosion worse at its job**, which is the nicest thing the model does
    # here and nobody wired it: firedamp combustion consumes 17.2 kg of air per kilogram of gas,
    # so a district whose air has been displaced cannot burn what is in it. An unventilated
    # working is both the gassiest and the hardest to set off properly.
    it "starves the fire it cannot feed" do
      op = worked(ventilation: 0)
      gas = held(op, :district, :firedamp)

      op.set_control(:naked_lights, 100)
      run!(op, 2_000, from: 3_600)

      expect(held(op, :district, :firedamp)).to be_between(gas * 0.2, gas * 0.9)
    end
  end

  describe "ventilation is the whole answer to it" do
    it "keeps the pit breathable with the fan running" do
      op = worked(ventilation: 100)

      expect(air(op, :pit_bottom)).to be > ReactorSim::Breath::SAFE
      expect(air(op, :district)).to be > ReactorSim::Breath::SAFE
    end

    it "hurts nobody at all while the fan is running" do
      op = worked(ventilation: 100, ticks: 6_000)

      expect(op.state.fetch(:minions).values.map { |s| s[:injury] }).to all(be_nil)
    end

    # **Spent is not collapsed**, and this is where the distinction earns its keep: the putter
    # works himself to the fatigue ceiling in good air and is merely tired.
    it "leaves a worker spent in good air rather than stood down" do
      op = worked(ventilation: 100, ticks: 6_000)

      expect(op.state.dig(:minions, :crew_2, :fatigue)).to eq(1.0)
      expect(op.state.dig(:minions, :crew_2, :injury)).to be_nil
    end

    it "fills the bottom once the fan stops" do
      blowing = worked(ventilation: 100)
      still = worked(ventilation: 0)

      expect(held(still, :pit_bottom, :blackdamp))
        .to be > held(blowing, :pit_bottom, :blackdamp) * 3
      expect(air(still, :pit_bottom)).to be < ReactorSim::Breath::SAFE
    end

    it "stands the shift down if the fan stays off long enough" do
      op = worked(ventilation: 0, ticks: 8_000)

      expect(op.state.dig(:minions, :crew_2, :injury)).not_to be_nil
    end
  end

  describe "the lamp, which is the warning" do
    it "burns clear in a ventilated pit" do
      expect(lamp(worked(ventilation: 100))).to eq("burning clear")
    end

    # **The gauge trips before the hazard does**, which nothing else in this operation manages.
    # By the time the flame is visibly struggling the air is still breathable, and that gap is
    # the entire reason to carry the lamp.
    it "is already warning while the air is still breathable" do
      op = pit
      op.set_control(:ventilation, 0)
      warned_at = nil

      120.times do |i|
        run!(op, 25, from: i * 25)
        warned_at ||= air(op, :pit_bottom) if lamp(op) != "burning clear"
        break if warned_at && air(op, :pit_bottom) < ReactorSim::Breath::SAFE
      end

      expect(warned_at).not_to be_nil
      expect(warned_at).to be > ReactorSim::Breath::SAFE
    end

    it "goes out in air nobody could work in" do
      op = worked(ventilation: 0, ticks: 8_000)

      expect(lamp(op)).to match(/will not stay lit|is out/)
    end
  end

  it "conserves mass and energy while it seeps" do
    op = worked(ventilation: 0, ticks: 4_000)
    mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

    fresh = pit
    mass0 = ReactorSim::Ledger.mass_balance(fresh.total_mass, fresh.ledger)
    joules0 = ReactorSim::Ledger.energy_balance(fresh.total_joules, fresh.ledger)

    expect((mass - mass0).abs / mass0.abs).to be < 1e-9, "mass drifted by #{mass - mass0}"
    expect((joules - joules0).abs / joules0.abs).to be < 1e-9,
                                                    "energy drifted by #{joules - joules0}"
  end
end
