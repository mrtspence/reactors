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
# ## One state per claim, and a handful of ticks each
#
# This was the slowest file in the suite — six examples at 12,000 ticks, nearly a quarter of the
# whole run. Everything it was waiting for turns out to be **derived from state it could have been
# handed**:
#
# | What the claim needs | Where it comes from | Ticks |
# |---|---|---|
# | the plate exposed | the water in the drum, read at tick 1 | 1 |
# | the plug blown | the plate being hot, one tick after that | 2 |
# | the plug *already* blown | `melted:` and `fusible_remaining_kg:` | 1 |
# | the shell letting go | the drum's `durability:` | 10 |
# | the glass flattering the drum | swell, which has a rise time of its own | 20 |
#
# Exposure against seeded water, at tick 1 — the whole gradient, with no waiting at all:
#
#     water   1200   800    400    200    100    50 kg
#     expose  0.04   0.36   0.68   0.84   0.92   0.96
#     crown    454   644    835    930    977  1001 K
#
# **Two of the water levels are load-bearing and not interchangeable.** At 800 kg the plug gets
# there first and the shell is unmarked; below that the plate has already taken a bite out of it
# (integrity 0.99 at 400 kg and under). And an explosion needs water *left to flash* — 400 kg
# unzips the shell where 200 kg merely seam-splits, because severity scales with the flash.
#
# See `design_sketches/suite-runtime.md` §7.
RSpec.describe "the crown sheet", crew: :reference do
  include EngineRig

  # Water levels, named for what they are for. Methods rather than constants — a constant assigned
  # inside an example group resolves lexically against `Object`.
  def ordinary_water = EngineRig::DRUM.fetch(:water)

  # Exposure 0.92 on the first tick: the plate is bare.
  def bare_plate_water = 100.0

  # Dangerous, with enough left to flash violently when the shell opens.
  def explosive_water = 400.0

  # **The level where the plug gets there first** — it melts, and the shell is still unmarked. Also
  # the level at which the glass is still flattering the drum, which is the same fact twice: this
  # is the moment the hazard is survivable *and* invisible, which is what makes it the accident.
  def saved_water = 800.0

  # A drum whose shell has already been worked, so the failure itself is what gets tested rather
  # than the hundreds of ticks of erosion that lead to it.
  def worn_shell = 20.0

  # **A plug that has already gone.** `melted` alone is not enough: the plug re-derives it from
  # `fusible_remaining_kg` every tick, so seeding the flag without the metal reads back as `false`
  # on tick 1 — the same stored-versus-derived distinction as the firebox's `alight`.
  def plug_gone = { melted: true, fusible_remaining_kg: 0.0 }

  def boiler_state(op) = op.state.fetch(:nodes).fetch(:boiler)
  def plug_state(op) = op.state.fetch(:nodes).fetch(:fusible_plug)

  # The drum with the feed shut, which is the neglect this whole file is about.
  def starved(op, ticks, water:, nodes: {}, **levers)
    ready = seed(at_work(op, water: water), nodes: nodes)
    [ ready, run!(ready, ticks, feed: 0, **levers) ]
  end

  def glass(op) = op.nodes.fetch(:boiler).effective_fill(boiler_state(op), op.content)

  def water_fill(op)
    held(op, :boiler, :water) / (op.nodes.fetch(:boiler).volume_m3 * 1_000.0)
  end

  describe "while there is water over it" do
    # The whole mechanic has to be invisible in ordinary work, or it is not a hazard, it is a tax.
    # Measured: crown 432.1 K at exposure 0.00, and the engine making 463 kW.
    it "sits at the water temperature and costs the engine nothing" do
      op, = starved(engine, 2, water: ordinary_water)

      expect(boiler_state(op).fetch(:crown_exposure)).to eq(0.0)
      expect(boiler_state(op).fetch(:crown_temperature_k)).to be < 500.0
      expect(plug_state(op).fetch(:melted)).to be(false)
      expect(shaft_power_w(op)).to be > 250_000.0
    end
  end

  describe "when the water goes" do
    # Two ticks: the plate is bare on the first and the plug has gone on the second.
    it "uncovers the plate and blows the fusible plug" do
      op, events = starved(engine, 2, water: bare_plate_water)

      expect(boiler_state(op).fetch(:crown_exposure)).to be > 0.9
      expect(plug_state(op).fetch(:melted)).to be(true)
      expect(events.map { |e| e[:type] }).to include(:fusible_plug_melted)
    end

    # **The plug must go before the plate does**, which is the entire reason it exists and the
    # reason the fusible alloy is rated 620 K against wrought iron's 750. If this ever inverts, the
    # safety device has become decoration.
    it "goes before the plate does, leaving the shell unmarked" do
      op, events = starved(engine, 2, water: saved_water)

      expect(plug_state(op).fetch(:melted)).to be(true)
      expect(events.map { |e| e.values_at(:type, :node) }).not_to include([ :part_failed, :boiler ])
      expect(op.nodes.fetch(:boiler).integrity(boiler_state(op))).to eq(1.0)
    end

    # **And the cost of the save**, as its own claim from its own state: a plug that has already
    # gone is dumping the drum onto the grate, so the fire goes down and the engine with it.
    # Starting from a plug that is *already* blown is what makes this a claim about the
    # consequence rather than a second measurement of how long the plug takes to melt.
    #
    # Measured over 10 ticks: 728.6 K in the firebox against an intact engine's 1024.5, with 1.5 kg
    # of water and steam sitting in the fire.
    it "puts the engine out of service by putting its fire out" do
      doused, = starved(engine, 10, water: bare_plate_water, nodes: { fusible_plug: plug_gone })
      intact, = starved(engine, 10, water: ordinary_water)

      expect(held(doused, :firebox, :water) + held(doused, :firebox, :steam)).to be > 0.0
      expect(temperature_k(doused, :firebox)).to be < temperature_k(intact, :firebox)
      expect(shaft_power_w(doused)).to be < shaft_power_w(intact)
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
    # **Hence `explosive_water` rather than `bare_plate_water`**: severity scales with the water
    # left to flash, so an emptier drum seam-splits instead.
    it "explodes, and spills itself, when the plug has been left out" do
      op, events = starved(engine(loadout: { fusible_plug: nil }), 10,
                           water: explosive_water, nodes: { boiler: { durability: worn_shell } })

      expect(events).to include(hash_including(type: :part_failed, node: :boiler, mode: :explosion))
      expect(boiler_state(op).fetch(:failure)).to be(:explosion)
      # **The whole point of the failure model: a failed drum is not a sealed drum.** Before
      # `Nodes::Breach` a burst boiler kept its contents and went on making steam.
      expect(op.ledger.fetch(:mass_spilled)).to be > 0.0
    end

    # **A fuse, not a valve.** Built on `ReliefValve` this would re-seat the moment the water came
    # back over the plate, and a boiler that quietly heals itself is exactly the consequence-free
    # behaviour the hazard exists to not have.
    #
    # **The plate is genuinely covered again here** — a full drum, full feed, exposure 0.0000 —
    # which is the precise condition a re-seating valve would open its way out of. The old form
    # starved a drum for 12,000 ticks and then turned the feed up, which left the plate still bare
    # and so never actually offered the plug the chance to heal.
    it "stays melted once it has melted, even with the water back over it" do
      op, = starved(engine, 1, water: ordinary_water,
                    nodes: { fusible_plug: plug_gone }, feed: 100)

      expect(boiler_state(op).fetch(:crown_exposure)).to eq(0.0)
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
  # nearly empty — it would have passed on a glass telling the driver exactly how bad things were.
  #
  # **Twenty ticks rather than two**, because swell is the one thing here with a time constant of
  # its own: `swell_rise_s` is two seconds, so a single tick finds the bubbles have not formed and
  # the glass still agrees with the drum.
  it "lets the gauge glass read high while the plate is already bare" do
    op, = starved(engine, 20, water: saved_water)

    expect(plug_state(op).fetch(:melted)).to be(true), "the plate must already be bare"
    expect(boiler_state(op).fetch(:crown_exposure)).to be > 0.0
    expect(glass(op)).to be > water_fill(op), "the glass has to flatter the drum, not report it"
  end
end
