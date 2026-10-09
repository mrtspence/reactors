# frozen_string_literal: true

require "reactor_sim"
require "support/engine_rig"

# The low-water hazard, and the two parts that make it one.
#
# The water lever had a ceiling (priming) and **no floor** since the day it was built: feed 0 ran
# happily at 357 kW while the drum emptied. The missing half is the failure everyone in the
# high-pressure era actually feared, and it could not be expressed by rating the boiler node,
# because **a lumped drum at 5% water is not hot, merely empty** — its temperature is the same
# saturation temperature a full one has, held by a smaller mass.
#
# So the hazard is positional and the plate gets a derived temperature of its own. These examples
# guard the three things that were each got wrong on the way in.
#
# ## A low drum is a state, so it is built rather than boiled down to
#
# This was the slowest file in the suite — six examples at 12,000 ticks each, nearly a quarter of
# the whole run, spent lighting an engine from cold and then waiting for 2,000 kg of water to boil
# away. `at_work(water:)` puts the drum where the claim is. The water levels are not
# interchangeable and the choice of each is recorded below, because **how much water is left
# decides which failure you get**:
#
#     water    exposure   integrity   what happens
#     2000 kg    0.00        1.000     nothing: ordinary work
#      800 kg    0.47        1.000     the plug wins the race — it goes, the shell is unmarked
#      600 kg    0.62        0.963     the plate gets a bite in before the plug can act
#      400 kg    0.78          —       with no plug fitted: EXPLOSION, 364 kg spilled
#      200 kg    0.94        0.909     the plate is bare, and it has cost the shell 9%
#
# Two of those rows are the model working rather than quirks, and both are worth knowing:
#
# - **The 400 kg row explodes and the 200 kg row does not.** Severity scales with the water left
#   to flash, so an emptier drum `seam_split`s where a fuller one unzips.
# - **Below about 800 kg the plug no longer gets there first.** The ~9% the shell loses at 200 kg
#   is taken once, in the first hundred-odd ticks, and does not accumulate — identical at 150 and
#   at 600 ticks, and unchanged by dropping the fire. A seed below 800 kg is therefore a drum that
#   was *already* being damaged when the example started, which is a different claim from the one
#   about the plug saving it.
#
# See `design_sketches/suite-runtime.md` §7.
RSpec.describe "the crown sheet", crew: :reference do
  include EngineRig

  # Water levels, named for what they are for. Methods rather than constants — a constant assigned
  # inside an example group resolves lexically against `Object`.
  def ordinary_water = EngineRig::DRUM.fetch(:water)

  # Low enough that the plate is substantially bare.
  def bare_plate_water = 200.0

  # Low enough to be dangerous, with enough left to flash violently when the shell opens.
  def explosive_water = 400.0

  # **The level where the plug gets there first** — it melts, and the shell is still unmarked. Also
  # the level at which the glass is still flattering the drum, which is the same fact twice: this
  # is the moment the hazard is survivable *and* invisible, which is what makes it the accident.
  def saved_water = 800.0

  def boiler_state(op) = op.state.fetch(:nodes).fetch(:boiler)
  def plug_state(op) = op.state.fetch(:nodes).fetch(:fusible_plug)

  # The drum with the feed shut, which is the neglect this whole file is about.
  def starved(op, ticks, water:, **levers)
    ready = at_work(op, water: water)
    [ ready, run!(ready, ticks, feed: 0, **levers) ]
  end

  def glass(op) = op.nodes.fetch(:boiler).effective_fill(boiler_state(op), op.content)

  def water_fill(op)
    held(op, :boiler, :water) / (op.nodes.fetch(:boiler).volume_m3 * 1_000.0)
  end

  describe "while there is water over it" do
    # The whole mechanic has to be invisible in ordinary work, or it is not a hazard, it is a tax.
    # Measured: crown peak 432.3 K at exposure 0.00, and the engine making 468 kW.
    it "sits at the water temperature and costs the engine nothing" do
      op, = starved(engine, 100, water: ordinary_water)

      expect(boiler_state(op).fetch(:crown_exposure)).to eq(0.0)
      expect(boiler_state(op).fetch(:crown_temperature_k)).to be < 500.0
      expect(plug_state(op).fetch(:melted)).to be(false)
      expect(shaft_power_w(op)).to be > 250_000.0
    end
  end

  describe "when the water goes" do
    # The hazard is reachable, and it scales with neglect rather than arriving as a cliff —
    # exposure runs 0.89 / 0.94 / 0.98 across 100, 200 and 300 ticks from a 200 kg drum.
    it "uncovers the plate and blows the fusible plug" do
      op, events = starved(engine, 200, water: bare_plate_water)

      expect(boiler_state(op).fetch(:crown_exposure)).to be > 0.9
      expect(plug_state(op).fetch(:melted)).to be(true)
      expect(events.map { |e| e[:type] }).to include(:fusible_plug_melted)
    end

    # **The plug must go before the plate does**, which is the entire reason it exists and the
    # reason the fusible alloy is rated 620 K against wrought iron's 750. If this ever inverts, the
    # safety device has become decoration.
    it "goes before the plate does, leaving the shell unmarked" do
      op, events = starved(engine, 200, water: saved_water)

      expect(plug_state(op).fetch(:melted)).to be(true)
      expect(events.map { |e| e.values_at(:type, :node) }).not_to include([ :part_failed, :boiler ])
      expect(op.nodes.fetch(:boiler).integrity(boiler_state(op))).to eq(1.0)
    end

    # **And the cost of the save**: steam onto the grate puts the fire out, so the engine stops.
    #
    # Asserted as the **collapse** rather than as an absolute figure. A stopped engine coasts, so
    # "under a kilowatt" is a statement about how long somebody waited — where the power falling
    # from 468 kW to a seventh of that is the plug doing its job. Measured across 100 / 200 / 400
    # ticks from this drum: 305 / 180 / 70 kW.
    it "puts the engine out of service by putting its fire out" do
      ordinary, = starved(engine, 100, water: ordinary_water)
      saved, = starved(engine, 400, water: saved_water)

      expect(shaft_power_w(saved)).to be < 0.25 * shaft_power_w(ordinary)
      expect(temperature_k(saved, :firebox)).to be < temperature_k(ordinary, :firebox)
    end

    # **The other half of the plug's story, and what makes it a save rather than a nuisance.**
    # Leave it out and the same neglect destroys the drum.
    #
    # Two things worth knowing here, both measured rather than assumed:
    #
    # **This is the only route by which this engine can destroy its boiler.** Firing hard with the
    # safety valve removed, the drum peaks at 0.53× its cold rating and never loses a point of
    # durability — the shell is rated at nearly 2.4× its working pressure, which is a correct
    # boiler. Over-pressure is not the hazard; low water is, which is what the period sources say.
    #
    # **And it is an EXPLOSION, which is the whole reason the failure model measures flash steam
    # rather than a pressure ratio.** What flashes the instant the shell opens is many times the
    # drum's own volume in steam, and no rent passes twenty vessel-volumes in the time a flash
    # takes, so the plate peels back and the shell unzips. That is exactly what the accident
    # reports describe: a low-water crown-sheet failure at ordinary working pressure was *the*
    # catastrophic locomotive boiler explosion. An earlier version called this a gentle seam split,
    # on a pressure-ratio rule that could never fire at all.
    #
    # **Hence `explosive_water` rather than `bare_plate_water`**: at 200 kg there is too little
    # left to flash and the same drum merely `seam_split`s, which is the severity model working.
    it "explodes, and spills itself, when the plug has been left out" do
      op, events = starved(engine(loadout: { fusible_plug: nil }), 200, water: explosive_water)

      expect(events).to include(hash_including(type: :part_failed, node: :boiler, mode: :explosion))
      expect(boiler_state(op).fetch(:failure)).to be(:explosion)
      # **The whole point of the failure model: a failed drum is not a sealed drum.** Before
      # `Nodes::Breach` a burst boiler kept its contents and went on making steam.
      expect(op.ledger.fetch(:mass_spilled)).to be > 0.0
    end

    # **A fuse, not a valve.** Built on `ReliefValve` this would re-seat the moment the water came
    # back over the plate, and a boiler that quietly heals itself is exactly the consequence-free
    # behaviour the hazard exists to not have.
    it "stays melted once it has melted, even with the feed restored" do
      op, = starved(engine, 200, water: bare_plate_water)
      expect(plug_state(op).fetch(:melted)).to be(true)

      run!(op, 200, from: 200, feed: 100)

      expect(plug_state(op).fetch(:melted)).to be(true)
    end
  end

  # The glass shows the swelled level because that is what a real glass shows; the plate is cooled
  # by water, not by froth. So the needle reads comfortable exactly when a hard pull is uncovering
  # the plate. This is the classic accident rather than a contrivance, and it is why every firing
  # manual tells you to trust the try-cocks over the glass.
  #
  # **Asserted as the glass reading ABOVE the truth**, which is the deception itself. The old form
  # asked only that the glass read under 25%, and that is nearly free on a drum which is in fact
  # nearly empty — it would have passed on a glass that was telling the driver exactly how bad
  # things were. Measured here: the plug has already gone, and the glass reads **0.178 against a
  # true 0.151**, which is a figure a driver reads as low-but-working rather than as an emergency.
  it "lets the gauge glass read high while the plate is already bare" do
    op, = starved(engine, 60, water: saved_water)

    expect(plug_state(op).fetch(:melted)).to be(true), "the plate must already be bare"
    expect(boiler_state(op).fetch(:crown_exposure)).to be > 0.0
    expect(glass(op)).to be > water_fill(op), "the glass has to flatter the drum, not report it"
    expect(glass(op)).to be > 0.15, "and read like a drum somebody could still work"
  end
end
