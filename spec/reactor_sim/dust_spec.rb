# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **Coal dust: what turns an accident into a catastrophe.**
#
# Firedamp is dangerous. Dust is why a firedamp ignition became Courrières (1,099 dead) and
# Senghenydd (439). The gas burns in whatever volume held it; the dust is lying along every roadway
# in the mine, gets raised by the blast ahead of the flame, and carries the fire the whole length
# of the workings.
#
# The claims that matter most are the ones about **settled** dust: it is made by cutting rather
# than vented by the strata, and the ventilation does not touch it. A well-ventilated pit with
# dusty roads is exactly the pit that was destroyed.
#
# ## Built, not waited for
#
# A dusty district is `district_mix(coal_dust:)`, and a limewashed one adds `stone_dust:`. What
# used to take 3,000 ticks of cutting per fixture and an 8,000-tick ignition is decided in sixty.
# **The ratio is the thing to get right**: stone dust suppresses by diluting, so a seed with less
# stone than coal is below the suppression threshold and makes dusting look useless. Measured
# against 108 kg of coal dust — the amount 3,000 ticks of cutting actually lays down:
#
#     stone     0 kg   peak 1963 K     0% of the coal dust left
#     stone   130 kg   peak  733 K    65% left
#     stone   400 kg   peak  293 K   100% left — it does not fire at all
#
# See `docs/design_sketches/mine.md` §4.6 stage F and `design_sketches/suite-runtime.md` §7.
RSpec.describe "coal dust" do
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  # What 3,000 ticks of cutting lays down, so the suppression figures mean what they say. **A
  # method rather than a constant**: a constant assigned inside an example group resolves
  # lexically against `Object`, so two spec files naming one overwrite each other silently and
  # which wins depends on the randomised file order.
  def shift_of_dust_kg = 108.0

  def pit = build_pit(id: "d", seed: 3, loadout: { manriding: :cage_gear })

  # How much coal has come out of the seam. Measured against a fresh pit rather than against the
  # figure in the fixture, so the seam can be resized without silently inverting a test.
  def cut(op) = held(pit, :seam, :coal) - held(op, :seam, :coal)

  def dust_per_kg(op) = held(op, :district, :coal_dust) / cut(op)

  def district_k(op)
    op.nodes.fetch(:district).temperature_k(op.state.fetch(:nodes).fetch(:district), op.content)
  end

  # `worn:` seeds the district's remaining durability, which is how an example about *rupture* is
  # short: the roadway erodes under sustained over-temperature, so starting it part-worn tests the
  # failure rather than the erosion rate.
  def pit_with(worn: nil, **mix)
    op = pit
    district = district_mix(op, **mix)
    district = district.merge(durability: worn) if worn

    at_the_face(seed(op, nodes: { district: district }))
  end

  def work!(op, ticks, hewing: 100, ventilation: 100, **levers)
    levers!(op, hewing: hewing, haulage: 100, timbering: 100, winding: 100, pumping: 100,
                ventilation: ventilation, **levers)

    run!(op, ticks)
  end

  # Hold a flame to it and report the hottest it got. The peak rather than the end state, because
  # the fan carries the heat away in seconds and an end reading would miss the explosion entirely.
  def peak_on_ignition(op, ticks: 60)
    levers!(op, hewing: 0, haulage: 100, timbering: 100, winding: 100, pumping: 100,
                ventilation: 0, naked_flame: 100)

    peak = 0.0
    events = []
    ticks.times do |i|
      op.receive_supply(:line_shaft, PitRig::SUPPLY_J)
      events.concat(op.step!(tick: i + 1))
      peak = [ peak, district_k(op) ].max
    end
    [ peak, events ]
  end

  describe "where it comes from" do
    it "is made by cutting, not vented by the ground" do
      idle = pit_with
      cutting = pit_with
      work!(idle, 100, hewing: 0)
      work!(cutting, 100, hewing: 100)

      expect(held(idle, :district, :coal_dust)).to eq(0.0)
      expect(held(cutting, :district, :coal_dust)).to be > 0.0
    end

    # **The fan does not touch it, and that is the whole point.** Settled dust lies on the floor
    # and the ledges for months; a pit could be ventilated to the standard of the day and still be
    # destroyed by what was lying in its roadways.
    #
    # Asserted as dust **per kilogram cut** rather than as a total, because the two totals need
    # not be equal and the reason is worth knowing: an unventilated district is one its hewer
    # cannot breathe properly in, so he cuts less and makes less dust. The fan changes how much is
    # won; it does not change what fraction of it hangs in the air. Measured identical at
    # 0.214286 kg/kg either way.
    it "is not carried away by the ventilation" do
      blowing = pit_with
      still = pit_with
      work!(blowing, 200, ventilation: 100)
      work!(still, 200, ventilation: 0)

      expect(dust_per_kg(blowing)).to be_within(1e-6).of(dust_per_kg(still))
    end

    # And the confound itself, stated so nobody reads the example above as the fan mattering. **The
    # foul air is constructed**, because at 200 ticks a stopped fan has not yet made a district
    # unbreathable — the old form of this example needed 4,000 ticks to reach air the hewer
    # noticed, and what it was testing is what bad air does to a worker, not how long a fan takes
    # to fail.
    it "is made more slowly in air its hewer cannot breathe" do
      good = pit_with
      foul = pit_with(blackdamp: gas_kg(50.0))
      work!(good, 200, ventilation: 0)
      work!(foul, 200, ventilation: 0)

      expect(air(foul, :district)).to be < air(good, :district)
      expect(cut(foul)).to be < cut(good)
      expect(held(foul, :district, :coal_dust)).to be < held(good, :district, :coal_dust)
    end

    # Wind and ventilate as hard as the mine can, and it is still there — to the kilogram.
    it "has no way out of a district once it has settled" do
      op = pit_with(coal_dust: 400.0)
      dusty = held(op, :district, :coal_dust)
      work!(op, 200, hewing: 0, ventilation: 100)

      expect(held(op, :district, :coal_dust)).to be_within(1e-6).of(dusty)
    end
  end

  describe "when it goes up" do
    # **Senghenydd.** The gas is held below the limit, so the firedamp alone could not do this —
    # the dust does, and it consumes every kilogram of itself doing it.
    it "carries the explosion even with the gas held below the explosive limit" do
      op = pit_with(coal_dust: shift_of_dust_kg, firedamp: gas_kg(2.0))
      # Firedamp will not carry a flame at this concentration, so whatever happens next is not
      # the gas doing it. Where the limits are is `district_fire_spec`'s claim, from both sides.
      expect(gas_pct(op)).to be < 5.0
      dusty = held(op, :district, :coal_dust)
      expect(dusty).to be > held(op, :district, :firedamp)

      peak, = peak_on_ignition(op)

      # **A district that was at 292 K reaching nineteen hundred is the explosion**, and that is
      # the claim — not a rupture, which is a question about how *long* the heat lasted.
      expect(peak).to be > 1_000.0
      # It burns essentially all of itself: nothing is left to carry a flame any further.
      expect(held(op, :district, :coal_dust)).to be < dusty * 0.5
    end
  end

  describe "stone dusting" do
    # The least dramatic thing in the game: it wins no coal, spends stores, and does nothing
    # whatever until the day the district goes up — on which it does everything.
    #
    # **Stated as the whole suppression curve**, because a single pair would not show that this is
    # a dilution rather than a switch, and because the threshold is the part a player has to learn:
    # laying down less stone than there is coal dust buys very little.
    it "smothers a dust explosion in proportion to how much is laid down" do
      peaks = [ 0.0, 130.0, 400.0 ].map do |stone|
        op = pit_with(coal_dust: shift_of_dust_kg, stone_dust: stone, firedamp: gas_kg(2.0))
        peak, = peak_on_ignition(op)
        [ peak, held(op, :district, :coal_dust) ]
      end

      expect(peaks.map(&:first).each_cons(2).all? { |hotter, cooler| cooler < hotter }).to be(true),
                                                                                          peaks.inspect
      # Bare, it burns the lot. Properly dusted, the district does not fire at all and every
      # kilogram of coal dust is still lying there afterwards.
      expect(peaks.first.last).to be < 1.0
      expect(peaks.last.first).to be < 400.0
      expect(peaks.last.last).to be_within(1e-6).of(shift_of_dust_kg)
    end

    it "costs stores that run down" do
      op = pit_with
      work!(op, 100, stone_dusting: 100)

      expect(held(op, :dust_store, :stone_dust)).to be < 6_000.0
      expect(held(op, :district, :stone_dust)).to be > 0.0
    end

    # **It saves you from the dust, not from the gas.** Historically stone dusting is why ignitions
    # stopped becoming disasters, not why they stopped happening — and a throttle that damped both
    # alike would cancel the entire firedamp hazard.
    #
    # Measured at 8% firedamp: even a thousand kilograms of stone dust still reaches 1,584 K and
    # still ruptures the roadway, where the same district on a *dust-only* ignition sits at 292 K.
    it "does not stop the gas burning" do
      op = pit_with(firedamp: gas_kg(8.0), coal_dust: shift_of_dust_kg,
                    stone_dust: 1_000.0, worn: 60.0)
      expect(held(op, :district, :firedamp)).to be > 10.0

      _, events = peak_on_ignition(op)

      expect(events.map { |e| e[:type] }).to include(:fire_lit)
      expect(op.state.fetch(:nodes).fetch(:district)[:failure]).to be(:rupture)
    end

    # The pair to it, and the reason dusting is worth buying: the same roadway, the same flame, the
    # gas below its limit — ruptured bare, untouched when it has been limewashed.
    it "saves the same district from a dust-only ignition" do
      bare = pit_with(firedamp: gas_kg(2.0), coal_dust: shift_of_dust_kg, worn: 60.0)
      dusted = pit_with(firedamp: gas_kg(2.0), coal_dust: shift_of_dust_kg,
                        stone_dust: 400.0, worn: 60.0)
      peak_on_ignition(bare)
      peak_on_ignition(dusted)

      expect(bare.state.fetch(:nodes).fetch(:district)[:failure]).to be(:rupture)
      expect(dusted.state.fetch(:nodes).fetch(:district)[:failure]).to be_nil
    end
  end

  it "conserves mass and energy through a dust explosion" do
    op = pit_with(coal_dust: shift_of_dust_kg, firedamp: gas_kg(2.0))
    mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

    peak_on_ignition(op)

    mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    expect((mass - mass0).abs / mass0.abs).to be < 1e-9, "mass drifted by #{mass - mass0}"
    expect((joules - joules0).abs / joules0.abs).to be < 1e-9,
           "energy drifted by #{joules - joules0}"
  end
end
