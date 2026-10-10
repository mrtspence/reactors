# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **Afterdamp: what fills a mine after the fire, and what kills more people than the fire did.**
#
# The claim this file exists to prove is that it needed **no new content at all**. Firedamp
# combustion already consumes 17.2 kg of air per kilogram of gas and already hands back
# `flue_gas`; the only thing missing was anybody asking whether the people standing in the result
# could breathe. One tag on `air` and the whole hazard was already in the box.
#
# Its own crew rather than `ReferenceCrew`, and **with a real `endurance`** — the reference hand is
# `1e6` to make them tireless, and `Breath::RESERVE` clamps that so they are not immune, but an
# example about how long somebody lasts should not be measuring a clamp. See the traps list.
#
# ## The gassy district is built, not waited for
#
# A mixture carries a flame only between about 5% and 15% by volume, so these examples need a
# district inside that band — which used to mean running the pit with the fan off and lighting it
# at a hand-tuned tick, because too early will not light and too late is past the rich limit. The
# tuned moment went stale every time anything upstream moved. `district_mix` puts the mixture
# exactly where it is wanted; where the limits *are* is `district_fire_spec`'s claim.
#
# The air is therefore already poor when the fire starts, which is **correct rather than
# tolerated**: you cannot have an explosion in a well-ventilated district, and that is the whole
# point of the limit. Every claim below is about what the fire adds.
#
# See `docs/design_sketches/breathable-air.md`.
RSpec.describe "afterdamp" do
  include PitRig

  # **Hands who tire**, because bad air drains `fatigue` rather than a pool of its own.
  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::TIRING_CONTENT) }

  # 8% by mass, about 15% by volume — good and gassy, and comfortably inside the band.
  def gassy_pct = 8.0

  def pit = build_pit(id: "a", seed: 3, loadout: { manriding: :cage_gear })

  def pit_with(**mix) = at_the_face(seed(pit, nodes: { district: district_mix(pit, **mix) }))

  def work!(op, ticks, ventilation: 100, naked_flame: 0, hewing: 100, from: 0, **levers)
    levers!(op, hewing: hewing, haulage: 100, timbering: 100, winding: 100, pumping: 100,
                ventilation: ventilation, naked_flame: naked_flame, **levers)

    run!(op, ticks, from: from)
  end

  def gassy = pit_with(firedamp: gas_kg(gassy_pct))

  describe "before anything goes wrong" do
    it "leaves a ventilated pit breathable everywhere" do
      op = pit_with
      work!(op, 200)

      expect(air(op, :bank)).to eq(1.0)
      expect(air(op, :district)).to be > ReactorSim::Breath::SAFE
      expect(air(op, :pit_bottom)).to be > ReactorSim::Breath::SAFE
    end

    it "hurts nobody, however hard the shift is worked" do
      op = pit_with
      work!(op, 200)

      expect(op.state.fetch(:minions).values.map { |s| s[:injury] }).to all(be_nil)
    end
  end

  describe "once the gas has been lit" do
    # **The fire eats the air**, and that is the whole mechanism: no new resource, no new reaction,
    # no new hazard declaration. Burning firedamp turns breathable air into flue gas — measured,
    # the district goes to 0.036 breathable.
    it "turns the district's air into something nobody can breathe" do
      op = gassy
      before = air(op, :district)

      work!(op, 60, ventilation: 0, naked_flame: 100, hewing: 0)

      expect(air(op, :district)).to be < before
      expect(air(op, :district)).to be < ReactorSim::Breath::SAFE
    end

    # The roadway carries it: the pit bottom is not where the gas was and is foul anyway.
    it "reaches the pit bottom as well as the face" do
      op = gassy
      work!(op, 60, ventilation: 0, naked_flame: 100, hewing: 0)

      expect(air(op, :pit_bottom)).to be < air(op, :bank)
    end

    # The men at the surface are never in it, which is what makes sending somebody down a decision
    # rather than a formality.
    it "never touches the pit bank" do
      op = gassy
      work!(op, 60, ventilation: 0, naked_flame: 100, hewing: 0)

      expect(air(op, :bank)).to eq(1.0)
      expect(crew(op, :crew_4)[:injury]).to be_nil
    end

    it "stands the shift down and puts the cause on the record" do
      op = gassy
      events = work!(op, 60, ventilation: 0, naked_flame: 100, hewing: 0)
      hurt = events.select { |e| e[:type] == :minion_hurt }

      # **The heat beats the gas to them, and that is correct.** An ignition takes the district to
      # 2,300 K and the roadway carries it to the pit bottom; a shift underground is burnt long
      # before anybody could suffocate. Afterdamp is what kills whoever comes down *afterwards*,
      # which is the historical case and is why rescue parties went in with apparatus — see
      # `breath_spec` for the suffocation clock itself.
      expect(hurt).not_to be_empty
      expect(hurt.map { |e| e[:cause] }.uniq).to all(be_a(Symbol))
      expect(hurt.map { |e| e[:cause] }).to include(:burns)
      expect(crew(op, :crew_1)[:injury]).not_to be_nil
    end

    # **Who it reaches worst is decided by where they were standing**, which is the entire argument
    # for hazards belonging to places.
    #
    # The gradient is stark rather than graded, and stating it that way is the durable claim: the
    # face is **burnt** and the pit bottom is not burnt at all — 3.006 against exactly 0.000 — yet
    # the putter is not safe either, because the blast still spends his hidden margin. Asserting
    # the pit bottom's burns as some fraction of the face's would be asserting against zero.
    it "burns the face, spends the putter's margin, and leaves the bank alone" do
      op = gassy
      intact = crew(op, :crew_2).fetch(:resilience)
      work!(op, 60, ventilation: 0, naked_flame: 100, hewing: 0)

      expect(crew(op, :crew_1).fetch(:burns)).to be > 0.0
      expect(crew(op, :crew_2).fetch(:burns)).to be_within(1e-9).of(0.0)
      expect(crew(op, :crew_2).fetch(:resilience)).to be < intact
      expect(crew(op, :crew_4)[:injury]).to be_nil, "the pit bank is never in it"
    end
  end
end
