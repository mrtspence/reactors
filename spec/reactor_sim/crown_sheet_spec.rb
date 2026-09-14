# frozen_string_literal: true

require "reactor_sim"

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
RSpec.describe "the crown sheet" do
  def engine = ReactorSim::Operations::SteamEngine.build(id: :engine, seed: 7)

  COLD_START = { igniter: 100, blower: 100, damper_open: 100, stoking: 70, feed: 45,
            throttle_open: 0, load_demand: 0, ash_raking: 20, ease_safety: 0,
            cutoff: 40, cylinder_cocks: 0 }.freeze

  # Light from cold the normal way, then drop the feed to `feed` and leave it there.
  def starve(op, feed:, ticks: 12_000)
    COLD_START.each { |k, v| op.set_control(k, v) }
    events = []
    (1..ticks).each do |t|
      op.set_control(:igniter, 0) if t == 300
      op.set_control(:load_demand, 80) if t == 1150
      if t == 1200
        op.set_control(:throttle_open, 60)
        op.set_control(:stoking, 60)
        op.set_control(:feed, feed)
      end
      op.set_control(:blower, 0) if t == 1600
      events.concat(op.step!(tick: t))
    end
    events
  end

  def boiler_state(op) = op.state.fetch(:nodes).fetch(:boiler)
  def plug_state(op) = op.state.fetch(:nodes).fetch(:fusible_plug)

  describe "while there is water over it" do
    # The whole mechanic has to be invisible in ordinary work, or it is not a hazard, it is a
    # tax. Measured across feed 40/50/60: crown peak 432.4 K at exposure 0.00 in every one.
    it "sits at the water temperature and costs the engine nothing" do
      op = engine
      starve(op, feed: 50, ticks: 4000)

      expect(boiler_state(op).fetch(:crown_exposure)).to eq(0.0)
      expect(boiler_state(op).fetch(:crown_temperature_k)).to be < 500.0
      expect(plug_state(op).fetch(:melted)).to be(false)
      expect(op.state.fetch(:nodes).fetch(:cylinder).fetch(:shaft_power_w)).to be > 250_000.0
    end
  end

  describe "when the water goes" do
    # The hazard is reachable, and it scales with neglect rather than arriving as a cliff:
    # the plug blows at tick 5538 / 6522 / 8079 / 10930 at feed 0 / 10 / 20 / 30.
    it "uncovers the plate and blows the fusible plug" do
      op = engine
      events = starve(op, feed: 0)

      expect(boiler_state(op).fetch(:crown_exposure)).to be > 0.9
      expect(plug_state(op).fetch(:melted)).to be(true)
      expect(events.map { |e| e[:type] }).to include(:fusible_plug_melted)
    end

    # **The plug must go before the plate does**, which is the entire reason it exists and the
    # reason the fusible alloy is rated 620 K against wrought iron's 750. If this ever inverts,
    # the safety device has become decoration.
    it "puts the engine out of service without destroying the boiler" do
      op = engine
      events = starve(op, feed: 0)

      expect(events.map { |e| e[:type] }).not_to include(:vessel_rupture)
      expect(op.nodes.fetch(:boiler).integrity(boiler_state(op))).to eq(1.0)
      # Steam onto the grate puts the fire out, so the engine stops. That is the cost.
      expect(op.state.fetch(:nodes).fetch(:cylinder).fetch(:shaft_power_w)).to be < 1_000.0
    end

    # **A fuse, not a valve.** Built on `ReliefValve` this would re-seat the moment the water came
    # back over the plate, and a boiler that quietly heals itself is exactly the consequence-free
    # behaviour the hazard exists to not have.
    it "stays melted once it has melted, even with the feed restored" do
      op = engine
      starve(op, feed: 0)
      expect(plug_state(op).fetch(:melted)).to be(true)

      op.set_control(:feed, 100)
      2000.times { |i| op.step!(tick: 12_001 + i) }

      expect(plug_state(op).fetch(:melted)).to be(true)
    end
  end

  # The glass shows the swelled level because that is what a real glass shows; the plate is
  # cooled by water, not by froth. So the needle reads comfortable exactly when a hard pull is
  # uncovering the plate — measured, the glass read **20.1%** on the tick the plug went.
  #
  # This is the classic accident rather than a contrivance, and it is why every firing manual
  # tells you to trust the try-cocks over the glass.
  it "lets the gauge glass read high while the plate is already bare" do
    op = engine
    starve(op, feed: 0)

    glass = op.nodes.fetch(:boiler).effective_fill(boiler_state(op), op.content)
    expect(boiler_state(op).fetch(:crown_exposure)).to be > 0.9
    expect(glass).to be < 0.25
  end
end
