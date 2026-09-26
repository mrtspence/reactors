# frozen_string_literal: true

require "reactor_sim"

# **Coal dust: what turns an accident into a catastrophe.**
#
# Firedamp is dangerous. Dust is why a firedamp ignition became Courrières (1,099 dead) and
# Senghenydd (439). The gas burns in whatever volume held it; the dust is lying along every
# roadway in the mine, gets raised by the blast ahead of the flame, and carries the fire the
# whole length of the workings.
#
# The two examples that matter most here are the ones about **settled** dust: it is made by
# cutting rather than vented by the strata, and the ventilation does not touch it. A
# well-ventilated pit with dusty roads is exactly the pit that was destroyed.
#
# See `docs/design_sketches/mine.md` §4.6 stage F.
module DustCrew
  ARCHETYPE = { label: "Collier", strength: 1.0, toughness: 1.0, endurance: 1.0e6,
                intelligence: 1.0, dexterity: 1.0, charisma: 1.0,
                tags: { mining_effectiveness: 0.6, shovelling: 0.5,
                        darkvision: 0.8 } }.freeze

  MINIONS = (1..4).to_h { |i| [ :"hand_#{i}",
                                { name: "Hand #{i}", archetype: :collier,
                                  hireable: false } ] }.freeze

  CONTENT = ReactorSim::Content.default.merging(archetypes: { collier: ARCHETYPE },
                                                minions: MINIONS)

  CREW = (1..4).to_h { |i| [ :"crew_#{i}", { minion: :"hand_#{i}" } ] }.freeze
end

RSpec.describe "coal dust" do
  before { allow(ReactorSim::Content).to receive(:default).and_return(DustCrew::CONTENT) }

  SUPPLY_J = 9.0e4

  def pit
    ReactorSim::Match
      .create(id: "d", seed: 3,
              operations: [ { id: "pit", type: :mine, loadout: { manriding: :cage_gear },
                              crew: DustCrew::CREW } ])
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

  def held(op, node, resource)
    (op.state.fetch(:nodes).fetch(node).fetch(:parcels)
       .find { |p| p.fetch(:resource) == resource }&.fetch(:kg)) || 0.0
  end

  # How much coal has come out of the seam. Measured against a fresh pit rather than against
  # the figure in the fixture, so the seam can be resized without silently inverting a test.
  def cut(op) = held(pit, :seam, :coal) - held(op, :seam, :coal)

  def dust_per_kg(op) = held(op, :district, :coal_dust) / cut(op)

  # Firedamp as a percentage of what the district holds, which is the quantity a flame responds
  # to — kilograms mean different things with the fan on and off.
  def gas_pct(op)
    parcels = op.state.fetch(:nodes).fetch(:district).fetch(:parcels)
    total = parcels.sum { |p| p.fetch(:kg) }
    return 0.0 unless total.positive?

    held(op, :district, :firedamp) / total * 100.0
  end

  # A district being worked, with the shift already at their posts. Dusting is standing
  # practice, so it is laid down before anything is allowed to go wrong.
  def worked(hewing: 100, dusting: 0, ventilation: 100, settle: 3_000)
    op = pit
    op.set_control(:winding, 100)
    op.set_control(:man_winding, 100)
    op.assign_minion(:crew_1, :hewing)
    op.assign_minion(:crew_2, :haulage)
    op.assign_minion(:crew_3, :timbering)
    run!(op, 600)

    op.set_control(:man_winding, 0)
    op.set_control(:hewing, hewing)
    op.set_control(:haulage, 100)
    op.set_control(:timbering, 100)
    op.set_control(:stone_dusting, dusting)
    op.set_control(:ventilation, ventilation)
    run!(op, settle, from: 600)
    op
  end

  def ignite!(op, ticks: 8_000, from: 3_600)
    op.set_control(:naked_lights, 100)
    run!(op, ticks, from: from)
  end

  describe "where it comes from" do
    it "is made by cutting, not vented by the ground" do
      idle = worked(hewing: 0, settle: 4_000)
      cutting = worked(hewing: 100, settle: 4_000)

      expect(held(idle, :district, :coal_dust)).to eq(0.0)
      expect(held(cutting, :district, :coal_dust)).to be > 0.0
    end

    # **The fan does not touch it, and that is the whole point.** Settled dust lies on the
    # floor and the ledges for months; a pit could be ventilated to the standard of the day and
    # still be destroyed by what was lying in its roadways.
    #
    # Asserted as dust **per kilogram cut** rather than as a total, because the two totals are
    # no longer equal and the reason is worth knowing: an unventilated district is one its
    # hewer cannot breathe properly in, so he cuts less and makes less dust. The fan changes
    # how much is won; it does not change what fraction of it hangs in the air.
    it "is not carried away by the ventilation" do
      blowing = worked(hewing: 100, ventilation: 100, settle: 4_000)
      still = worked(hewing: 100, ventilation: 0, settle: 4_000)

      expect(dust_per_kg(blowing)).to be_within(1e-6).of(dust_per_kg(still))
    end

    # And the confound itself, stated so nobody reads the example above as the fan mattering.
    it "is made more slowly in air its hewer cannot breathe" do
      blowing = worked(hewing: 100, ventilation: 100, settle: 4_000)
      still = worked(hewing: 100, ventilation: 0, settle: 4_000)

      expect(cut(still)).to be < cut(blowing)
      expect(held(still, :district, :coal_dust)).to be < held(blowing, :district, :coal_dust)
    end

    it "has no way out of a district once it has settled" do
      op = worked(hewing: 100, settle: 4_000)
      dusty = held(op, :district, :coal_dust)

      # Wind and ventilate as hard as the mine can for a long while, and it is still there.
      op.set_control(:hewing, 0)
      run!(op, 4_000, from: 3_600)

      expect(held(op, :district, :coal_dust)).to be_within(1e-6).of(dusty)
    end
  end

  describe "when it goes up" do
    # **Senghenydd.** The fan is running and the gas is cleared, so the firedamp alone could
    # not do this — the dust does, and it consumes every kilogram of itself doing it.
    it "carries the explosion even with the gas held below the explosive limit" do
      op = worked(hewing: 100, ventilation: 100)
      # The fan is doing its job: firedamp will not carry a flame below about 5%, so whatever
      # happens next is not the gas doing it.
      expect(gas_pct(op)).to be < 5.0
      # Dust is the dominant fuel in the district, which is the claim — not a threshold in
      # kilograms, which is a balance figure and lands wherever the tuning puts it.
      dusty = held(op, :district, :coal_dust)
      expect(dusty).to be > held(op, :district, :firedamp)

      ignite!(op)

      expect(held(op, :district, :coal_dust)).to be < dusty * 0.1
      expect(op.state.fetch(:nodes).fetch(:district)[:failure]).to be(:rupture)
    end
  end

  describe "stone dusting" do
    # The least dramatic thing in the game: it wins no coal, spends stores, and does nothing
    # whatever until the day the district goes up.
    it "leaves most of the dust unburned" do
      bare = worked(hewing: 100, dusting: 0)
      dusted = worked(hewing: 100, dusting: 100)
      expect(held(dusted, :district, :stone_dust)).to be > 0.0

      ignite!(bare)
      ignite!(dusted)

      expect(held(dusted, :district, :coal_dust)).to be > held(bare, :district, :coal_dust)
    end

    it "costs stores that run down" do
      op = worked(hewing: 100, dusting: 100)

      expect(held(op, :dust_store, :stone_dust)).to be < 6_000.0
    end

    # **It saves you from the dust, not from the gas.** Historically stone dusting is why
    # ignitions stopped becoming disasters, not why they stopped happening — and a throttle that
    # damped both alike left a dusted district sitting at ambient through a naked light in 12%
    # gas, which cancelled the entire firedamp hazard.
    it "does not stop the gas burning" do
      op = worked(hewing: 100, dusting: 100, ventilation: 0)
      expect(held(op, :district, :firedamp)).to be > 10.0

      ignite!(op)

      expect(op.state.fetch(:nodes).fetch(:district)[:failure]).to be(:rupture)
    end
  end

  it "conserves mass and energy through a dust explosion" do
    op = worked(hewing: 100, ventilation: 100)
    mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

    ignite!(op)

    mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    expect((mass - mass0).abs / mass0.abs).to be < 1e-9, "mass drifted by #{mass - mass0}"
    expect((joules - joules0).abs / joules0.abs).to be < 1e-9,
      "energy drifted by #{joules - joules0}"
  end
end
