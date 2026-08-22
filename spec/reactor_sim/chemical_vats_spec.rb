# frozen_string_literal: true

require "reactor_sim"

# Behavioural spec for the v0 operation. These are game-design invariants as much as
# technical ones: they pin down that the machine is dangerous, that its levers pull
# against each other, and that nothing it does is instant. Balance constants will get
# tuned; these properties should survive the tuning.
RSpec.describe ReactorSim::Operations::ChemicalVats do
  def build(seed: 7)
    ReactorSim::Match.create(
      id: "vats-spec", seed: seed, operations: [ { id: :vats, type: :chemical_vats } ]
    )
  end

  def set(match, **controls)
    match.apply(
      controls.map do |id, value|
        { type: "set_control", operation_id: "vats", control_point_id: id.to_s, value: value }
      end
    )
  end

  def run(match, ticks)
    Array.new(ticks) { match.step! }.flatten
  end

  def truth(match) = match.project(operation_id: :vats, viewer: :spectator).gauges

  describe "the operating envelope" do
    it "produces nothing at all when idle" do
      match = build
      run(match, 40)

      expect(truth(match)[:power_output]).to eq(0.0)
    end

    it "sustains a steady output when run within its limits" do
      match = build
      set(match, feed_a_rate: 60, feed_b_rate: 60, throttle: 100, coolant: 60)
      incidents = run(match, 200)

      expect(incidents).to be_empty
      expect(truth(match)[:power_output]).to be > 500
      expect(truth(match)[:vessel_temp]).to be < described_class_temp_safe
    end

    it "rewards running hotter with more power" do
      cautious = build.tap { |m| set(m, feed_a_rate: 40, feed_b_rate: 40, throttle: 100, coolant: 70) }
      hard     = build.tap { |m| set(m, feed_a_rate: 70, feed_b_rate: 70, throttle: 100, coolant: 70) }
      run(cautious, 150)
      run(hard, 150)

      expect(truth(hard)[:power_output]).to be > truth(cautious)[:power_output]
      expect(truth(hard)[:vessel_temp]).to be > truth(cautious)[:vessel_temp]
    end

    it "destroys itself when run wide open with no coolant" do
      match = build
      set(match, feed_a_rate: 100, feed_b_rate: 100, throttle: 100, coolant: 0)
      incidents = run(match, 400)

      expect(incidents.map { |e| e[:type] }).to include(:vessel_rupture)
    end

    it "does not repair itself after a rupture" do
      match = build
      set(match, feed_a_rate: 100, feed_b_rate: 100, throttle: 100, coolant: 0)
      run(match, 400)

      run(match, 100)
      expect(truth(match)[:power_output]).to eq(0.0)
    end
  end

  describe "the levers pulling against each other" do
    # Coolant protects the vessel and throws away the heat you are paid for.
    it "trades power for safety on the coolant valve" do
      cool = build.tap { |m| set(m, feed_a_rate: 75, feed_b_rate: 75, throttle: 100, coolant: 100) }
      warm = build.tap { |m| set(m, feed_a_rate: 75, feed_b_rate: 75, throttle: 100, coolant: 70) }
      run(cool, 150)
      run(warm, 150)

      expect(truth(warm)[:power_output]).to be > truth(cool)[:power_output]
      expect(truth(cool)[:vessel_temp]).to be < truth(warm)[:vessel_temp]
    end

    # Throttling down backs the steam line up, which the vessel feels as pressure.
    # This is what makes the throttle a safety control and not just an output dial.
    it "raises vessel pressure when the turbine stops drawing steam" do
      open   = build.tap { |m| set(m, feed_a_rate: 60, feed_b_rate: 60, throttle: 100, coolant: 60) }
      sealed = build.tap { |m| set(m, feed_a_rate: 60, feed_b_rate: 60, throttle: 0,   coolant: 60) }
      run(open, 200)
      run(sealed, 200)

      expect(truth(sealed)[:vessel_pressure]).to be > truth(open)[:vessel_pressure] * 2
    end

    it "eventually ruptures a vessel that is never allowed to vent" do
      match = build
      set(match, feed_a_rate: 60, feed_b_rate: 60, throttle: 0, coolant: 60)
      incidents = run(match, 400)

      expect(incidents.map { |e| e[:type] }).to include(:vessel_rupture)
    end

    # Reagents only react in balanced pairs, so feeding one hard while starving the
    # other banks unreacted slurry rather than making power.
    it "banks unreacted slurry when the feeds are unbalanced" do
      match = build
      set(match, feed_a_rate: 100, feed_b_rate: 0, throttle: 100, coolant: 60)
      run(match, 60)

      expect(truth(match)[:slurry_a]).to be > 20
      expect(truth(match)[:slurry_b]).to be < 1
      expect(truth(match)[:power_output]).to eq(0.0)
    end

    it "wears out a pump driven past its cavitation point" do
      match = build
      set(match, feed_a_rate: 100, feed_b_rate: 100, throttle: 100, coolant: 100)
      incidents = run(match, 400)

      expect(incidents.map { |e| e[:type] }).to include(:pump_seizure)
    end

    it "runs the reservoirs dry eventually" do
      match = build
      set(match, feed_a_rate: 100, feed_b_rate: 100, throttle: 100, coolant: 100)
      run(match, 400)

      expect(truth(match)[:vitriol_level]).to eq(0.0)
    end
  end

  describe "nothing being instant" do
    # The feed lines run two ticks behind and the steam line one, so a change at the
    # top of the chain cannot be felt at the bottom in the same tick. This is the whole
    # source of tension in overseeing one of these (docs/architecture.md §4b).
    it "does not deliver a lever change downstream within the same tick" do
      match = build
      set(match, feed_a_rate: 100, feed_b_rate: 100, throttle: 100, coolant: 50)
      match.step!

      expect(truth(match)[:power_output]).to eq(0.0)
    end

    it "keeps producing for several ticks after the feed is cut" do
      match = build
      set(match, feed_a_rate: 60, feed_b_rate: 60, throttle: 100, coolant: 55)
      run(match, 60)
      at_cut = truth(match)[:power_output]

      set(match, feed_a_rate: 0, feed_b_rate: 0)
      match.step!

      expect(truth(match)[:power_output]).to be_within(0.01).of(at_cut).or be > at_cut
    end

    it "eventually winds down once the feed is cut" do
      match = build
      set(match, feed_a_rate: 60, feed_b_rate: 60, throttle: 100, coolant: 55)
      run(match, 60)
      at_cut = truth(match)[:power_output]

      set(match, feed_a_rate: 0, feed_b_rate: 0)
      run(match, 60)

      expect(truth(match)[:power_output]).to be < at_cut * 0.5
    end
  end

  describe "what the player is allowed to see" do
    it "shows the player a delayed, noisy reading and the spectator the truth" do
      match = build
      set(match, feed_a_rate: 60, feed_b_rate: 60, throttle: 100, coolant: 55)
      run(match, 40)

      player = match.project(operation_id: :vats).gauges
      god    = match.project(operation_id: :vats, viewer: :spectator).gauges

      expect(player[:vessel_temp]).not_to eq(god[:vessel_temp])
    end

    it "clamps a runaway reading to the instrument's scale" do
      match = build
      set(match, feed_a_rate: 100, feed_b_rate: 100, throttle: 100, coolant: 0)
      run(match, 90)

      # The vessel goes well past 600°C before it lets go, but the gauge cannot say so.
      # A pegged instrument is itself information, which is why the scale is an upgrade.
      expect(match.project(operation_id: :vats).gauges[:vessel_temp]).to be <= 600.0
    end

    it "never leaks raw mechanism state into a view" do
      match = build
      run(match, 5)
      view = match.project(operation_id: :vats)

      expect(view.gauges.keys).to all(be_a(Symbol))
      expect(view.gauges.keys).not_to include(:wear, :threshold, :failed, :trapped)
    end

    it "reports only what changed in a delta" do
      match = build
      set(match, feed_a_rate: 60, feed_b_rate: 60, throttle: 100, coolant: 55)
      run(match, 20)

      previous = match.project(operation_id: :vats)
      match.step!
      delta = match.project(operation_id: :vats).delta_from(previous)

      expect(delta[:changed].keys).not_to include(:vitriol_level, :quicklime_level) if
        truth(match)[:vitriol_level] == previous.gauges[:vitriol_level]
      expect(delta[:tick]).to eq(match.tick)
    end
  end

  describe "commands" do
    it "clamps a value outside the control's range" do
      match = build
      set(match, coolant: 5_000)

      expect(match.project(operation_id: :vats).controls[:coolant]).to eq(100.0)
    end

    it "rejects junk without disturbing the match" do
      match = build
      before = match.digest

      result = match.apply([ { type: "nonsense" }, { type: "set_control" }, {} ])

      expect(result[:applied]).to eq(0)
      expect(result[:rejected].size).to eq(3)
      expect(match.digest).to eq(before)
    end

    it "rejects a command for an unknown control point" do
      match = build
      result = match.apply([
        { type: "set_control", operation_id: "vats", control_point_id: "warp_core", value: 1 }
      ])

      expect(result[:applied]).to eq(0)
    end
  end

  def described_class_temp_safe = ReactorSim::Mechanisms::ReactionVessel::TEMP_SAFE
end
