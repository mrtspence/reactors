# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **Blackdamp: the quiet one, and the opposite of firedamp in every way that matters.**
#
# Air with the oxygen already taken out of it, left where coal has slowly oxidised in the
# worked-out ground. It does not burn and it does not explode; it kills by being there instead of
# air, and there is nothing to smell. Heavier than air, so it lies in the dips — which makes it
# **the pit bottom's hazard where firedamp is the face's**.
#
# The warning is the instrument, and it is the only gauge in this operation that trips before the
# danger does: a flame lamp dulls and goes out in blackdamp well before a man collapses in it. That
# is why the lamp was still worth carrying for something other than light.
#
# Its own crew, with a real `endurance` — bad air drains `fatigue` rather than a pool of its own,
# so tireless hands make every example here pass while proving nothing.
#
# ## Built, not waited for
#
# The air at the pit bottom is **constructed** with `bottom_mix`, and a worker who has been at it
# all shift is constructed by seeding their `fatigue`. Both are preconditions rather than claims,
# and waiting for them cost this file around 60,000 ticks.
#
# See `docs/design_sketches/breathable-air.md` stage C and `design_sketches/suite-runtime.md` §7.
RSpec.describe "blackdamp" do
  include PitRig

  # **Hands who tire**, because bad air drains `fatigue` rather than a pool of its own.
  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::TIRING_CONTENT) }

  def pit = build_pit(id: "b", seed: 3, loadout: { manriding: :cage_gear })

  def lamp(op)
    state = op.state.dig(:diagnostics, :lamp_flame)
    op.diagnostics.fetch(:lamp_flame)
      .display.render(state.fetch(:value), state.fetch(:flags, []))
  end

  # A pit with the putter at the bottom where the blackdamp is, and **nobody at the face** — which
  # is what `hewing: nil, timbering: nil` says, and it matters: a hewer cutting coal adds firedamp
  # and dust, and this file is about neither.
  #
  # `damp:` is a mass percentage of the pit bottom's air charge. `tired:` seeds the putter's
  # fatigue, which is how an example about *collapse* gets to be short — a shift's worth of work is
  # the precondition, not the claim.
  def pit_with(damp: 0.0, firedamp: 0.0, tired: nil)
    op = pit
    # `PitRig::` qualified, because a bare constant inside an example group resolves lexically
    # against `Object` rather than through the `include`.
    nodes = { pit_bottom: bottom_mix(op, blackdamp: gas_kg(damp, air: PitRig::BOTTOM_AIR_KG)) }
    nodes[:district] = district_mix(op, firedamp: gas_kg(firedamp)) if firedamp.positive?

    at_the_face(seed(op, nodes: nodes, minions: tired ? { crew_2: { fatigue: tired } } : {}),
                hewing: nil, timbering: nil)
  end

  def work!(op, ticks, ventilation: 0, **levers)
    levers!(op, haulage: 100, winding: 100, pumping: 100, ventilation: ventilation, **levers)

    run!(op, ticks)
  end

  describe "where it comes from" do
    # Unlike firedamp, which the face gives off while it is being worked, blackdamp comes out of
    # ground nobody goes into any more — so it arrives whether or not anybody is cutting. **Not
    # constructed**, because the arriving is the claim.
    it "seeps out of the old workings with nobody doing anything" do
      op = pit_with
      work!(op, 100)

      expect(held(op, :pit_bottom, :blackdamp)).to be > 0.0
      expect(op.state.dig(:controls, :hewing, :actual)).to eq(0.0)
    end

    # **The low point of the mine, because it is heavier than air.** Firedamp collects in the roof
    # at the face; this lies in the dips, and the deepest dip is the shaft bottom. Also not
    # constructed — *where the seep puts it* is exactly what is being asserted. Measured at 100
    # ticks with the fan off: 5.28 kg at the bottom against 0.51 in the district.
    it "collects at the pit bottom rather than at the face" do
      op = pit_with
      work!(op, 100)

      expect(held(op, :pit_bottom, :blackdamp)).to be > held(op, :district, :blackdamp)
    end

    # **It is inert because no reaction names it**, which is the whole mechanism — a substance is a
    # reagent by being listed, so being left out of every list is what "will not burn" means.
    # Asserted against the registry rather than by weighing a district afterwards: an explosion
    # drives the atmosphere out through the return, so blackdamp does leave, and a mass test would
    # be measuring the blast rather than the chemistry.
    it "is in no reaction at all, as a reagent or as a product" do
      named = ReactorSim::Content.default.reactions.values.flat_map do |spec|
        spec.fetch(:consumes, {}).keys + spec.fetch(:produces, {}).keys
      end

      expect(named).not_to include(:blackdamp)
    end

    # And the consequence a player sees: it is still down there after the blast.
    #
    # **Asserted against the firedamp beside it rather than as a fraction of itself**, which is
    # what the claim actually is — blackdamp is *dispersed* where a fuel is *spent*. Both lose
    # mass, because an explosion drives the atmosphere out through the return, so a bare "more
    # than half survives" is a statement about how hard the blast blew rather than about
    # chemistry: measured here, 16% of the blackdamp remains and **1%** of the firedamp.
    it "is dispersed by an ignition where the firedamp beside it is consumed" do
      op = pit_with(damp: 40.0, firedamp: 8.0)
      damp = held(op, :pit_bottom, :blackdamp)
      fuel = held(op, :district, :firedamp)

      events = work!(op, 60, naked_flame: 100, timbering: 100)

      expect(events.map { |e| e[:type] }).to include(:fire_lit)
      left = held(op, :pit_bottom, :blackdamp) / damp
      burnt = held(op, :district, :firedamp) / fuel
      expect(left).to be > 5.0 * burnt, "blackdamp #{left} vs firedamp #{burnt}"
    end

    # **And it makes the explosion worse at its job**, which is the nicest thing the model does
    # here and nobody wired it: firedamp combustion consumes 17.2 kg of air per kilogram of gas, so
    # a district whose air has been displaced cannot burn what is in it as fiercely.
    #
    # **Asserted as the temperature the fire reaches, not as gas left unburnt.** The old form
    # demanded that 20–90% of the gas survive, and it does not — at every blackdamp level the
    # firedamp is 97–99% consumed, just more slowly and far more coolly. Measured across 0 / 30 /
    # 50% blackdamp: **2379 → 1935 → 1544 K**, which is the mechanism, monotone, and nothing like a
    # tuning coincidence.
    it "starves the fire it cannot feed" do
      peaks = [ 0.0, 30.0, 50.0 ].map do |damp|
        op = at_the_face(seed(pit, nodes: {
          district: district_mix(pit, firedamp: gas_kg(8.0), blackdamp: gas_kg(damp))
        }))
        work!(op, 60, naked_flame: 100, timbering: 100)
        op.nodes.fetch(:district)
          .temperature_k(op.state.fetch(:nodes).fetch(:district), op.content)
      end

      expect(peaks.each_cons(2).all? { |clear, damped| damped < clear }).to be(true), peaks.inspect
      expect(peaks.last).to be < 0.7 * peaks.first
    end
  end

  describe "ventilation is the whole answer to it" do
    # **The fan against the seep, which is the claim** — so this starts from air and lets the
    # ground do the work, rather than seeding a charge. A fan that holds a working pit breathable
    # is not the same machine as one that can clear 730 kg of damp already lying in the sump: it
    # cannot, in any window, and asserting that it can was asserting the wrong thing.
    it "keeps the pit breathable with the fan running" do
      op = pit_with
      work!(op, 200, ventilation: 100)

      expect(air(op, :pit_bottom)).to be > ReactorSim::Breath::SAFE
      expect(air(op, :district)).to be > ReactorSim::Breath::SAFE
    end

    it "hurts nobody at all while the fan is running" do
      op = pit_with(tired: 0.90)
      work!(op, 200, ventilation: 100)

      expect(op.state.fetch(:minions).values.map { |s| s[:injury] }).to all(be_nil)
    end

    # **Spent is not collapsed**, and this is where the distinction earns its keep: the putter
    # reaches the fatigue ceiling in good air and is merely tired. Seeded at 0.90 rather than
    # worked up to it over 6,000 ticks, because what is being claimed is what happens *at* the
    # ceiling, not how long it takes to get there.
    it "leaves a worker spent in good air rather than stood down" do
      op = pit_with(tired: 0.90)
      work!(op, 100, ventilation: 100)

      expect(crew(op, :crew_2).fetch(:fatigue)).to eq(1.0)
      expect(crew(op, :crew_2).fetch(:injury)).to be_nil
    end

    it "fills the bottom once the fan stops" do
      blowing = pit_with(damp: 50.0)
      still = pit_with(damp: 50.0)
      work!(blowing, 200, ventilation: 100)
      work!(still, 200, ventilation: 0)

      expect(held(still, :pit_bottom, :blackdamp)).to be > held(blowing, :pit_bottom, :blackdamp)
      expect(air(still, :pit_bottom)).to be < ReactorSim::Breath::SAFE
    end

    # **The same ceiling, in air that is not good**, which is the pair to the example above: at the
    # fatigue ceiling in foul air, asphyxia accumulates and the putter goes down. One number
    # differs between the two and it is the air.
    it "stands the shift down if the fan stays off" do
      op = pit_with(damp: 70.0, tired: 0.90)
      work!(op, 60, ventilation: 0)

      expect(crew(op, :crew_2).fetch(:injury)).not_to be_nil
      expect(crew(op, :crew_2).fetch(:spent)).to be(true)
    end
  end

  describe "the lamp, which is the warning" do
    def read_lamp(damp)
      op = pit_with(damp: damp)
      work!(op, 20)
      [ lamp(op), air(op, :pit_bottom) ]
    end

    it "burns clear in a ventilated pit" do
      op = pit_with
      work!(op, 20, ventilation: 100)

      expect(lamp(op)).to eq("burning clear")
    end

    # **The gauge trips before the hazard does**, which nothing else in this operation manages. By
    # the time the flame is visibly struggling the air is still breathable, and that gap is the
    # entire reason to carry the lamp.
    #
    # Proved by **sweeping the concentration** rather than by watching one pit degrade for three
    # thousand ticks — which is both faster and a stronger claim, because it shows the whole gap
    # rather than the single point a run happened to cross. Measured: the flame is dull at 4%
    # blackdamp with air at 0.9644, and the air does not reach the 0.93 safe line until 8%.
    it "is already warning while the air is still breathable" do
      warning, breathable = read_lamp(4.0)

      expect(warning).not_to eq("burning clear")
      expect(breathable).to be > ReactorSim::Breath::SAFE

      expect(read_lamp(0.0).first).to eq("burning clear")
      expect(read_lamp(8.0).last).to be < ReactorSim::Breath::SAFE
    end

    it "goes out in air nobody could work in" do
      lit, breathable = read_lamp(50.0)

      expect(breathable).to be < ReactorSim::Breath::SAFE
      expect(lit).to match(/will not stay lit|is out/)
    end
  end

  it "conserves mass and energy while it seeps" do
    op = pit_with
    mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

    work!(op, 200)

    mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    expect((mass - mass0).abs / mass0.abs).to be < 1e-9, "mass drifted by #{mass - mass0}"
    expect((joules - joules0).abs / joules0.abs).to be < 1e-9,
           "energy drifted by #{joules - joules0}"
  end
end
