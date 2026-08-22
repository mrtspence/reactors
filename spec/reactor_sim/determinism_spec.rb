# frozen_string_literal: true

require "reactor_sim"
require "json"

# The other keystone. `seed + command log => this exact match` is what makes crash
# recovery exact, replays a few kilobytes instead of a frame recording, and spectating
# free. See docs/architecture.md §4a, §6, §8.
RSpec.describe "ReactorSim determinism" do
  def build(seed: 4242)
    ReactorSim::Match.create(
      id: "det", seed: seed, operations: [ { id: :vats, type: :chemical_vats } ]
    )
  end

  def commands(**controls)
    controls.map do |control_point_id, value|
      { type: "set_control", operation_id: "vats",
        control_point_id: control_point_id.to_s, value: value }
    end
  end

  # A representative run: settle in, then change the levers mid-flight so the command
  # log has more in it than a single opening move.
  def play(match, ticks: 80)
    match.apply(commands(feed_a_rate: 65, feed_b_rate: 60, throttle: 90, coolant: 55))
    (ticks / 2).times { match.step! }
    match.apply(commands(coolant: 80, feed_a_rate: 40))
    (ticks - ticks / 2).times { match.step! }
    match
  end

  it "produces identical state from the same seed and the same commands" do
    expect(play(build).digest).to eq(play(build).digest)
  end

  it "diverges on a different seed" do
    expect(play(build(seed: 1)).digest).not_to eq(play(build(seed: 2)).digest)
  end

  it "survives a snapshot round-trip through JSON" do
    original = play(build)

    # Exactly what the runner does: serialise, and later rebuild from the compacted
    # snapshot topic. Going through a real JSON encode/decode matters, because that is
    # what turns every symbol key in the state into a string.
    restored = ReactorSim::Match.from_h(JSON.parse(JSON.generate(original.to_h)))

    expect(restored.digest).to eq(original.digest)
  end

  it "continues identically after being restored from a snapshot" do
    original = play(build)
    restored = ReactorSim::Match.from_h(JSON.parse(JSON.generate(original.to_h)))

    30.times do
      original.step!
      restored.step!
    end

    expect(restored.digest).to eq(original.digest)
  end

  describe "at-least-once delivery" do
    # Kafka redelivers on rebalance and on crash-before-commit. Because commands carry
    # absolute values rather than deltas, redelivery has to be a no-op — otherwise we
    # would need a dedup table (docs/architecture.md §6).
    it "is unaffected by a command being delivered several times" do
      once = build
      thrice = build

      once.apply(commands(feed_a_rate: 60, coolant: 45))
      3.times { thrice.apply(commands(feed_a_rate: 60, coolant: 45)) }

      40.times { once.step!; thrice.step! }

      expect(thrice.digest).to eq(once.digest)
    end

    it "is unaffected by the order of commands to different control points" do
      forward = build
      reverse = build

      forward.apply(commands(feed_a_rate: 70, feed_b_rate: 65, throttle: 50, coolant: 30))
      reverse.apply(commands(coolant: 30, throttle: 50, feed_b_rate: 65, feed_a_rate: 70))

      40.times { forward.step!; reverse.step! }

      expect(reverse.digest).to eq(forward.digest)
    end

    it "applies last-write-wins within a batch" do
      match = build
      match.apply(commands(coolant: 10) + commands(coolant: 90))

      expect(match.project(operation_id: :vats).controls[:coolant]).to eq(90.0)
    end
  end

  describe "projection" do
    # A tick may be projected any number of times — a player view, a spectator view, a
    # resync of either. If projecting drew entropy, the RNG stream would depend on how
    # many people happened to be watching, and two runners replaying the same log would
    # diverge. See the note in Diagnostic.
    it "does not advance any RNG stream" do
      match = play(build, ticks: 20)
      before = match.digest

      10.times do
        match.project(operation_id: :vats)
        match.project(operation_id: :vats, viewer: :spectator)
      end

      expect(match.digest).to eq(before)
    end

    it "returns the same values however many times a tick is projected" do
      match = play(build, ticks: 20)

      expect(match.project(operation_id: :vats).gauges)
        .to eq(match.project(operation_id: :vats).gauges)
    end
  end

  describe "the RNG itself" do
    it "resumes exactly from its serialised state" do
      rng = ReactorSim::Rng.stream(99, "vats/vessel")
      5.times { rng.next_u64 }

      snapshot = rng.to_h
      expected = Array.new(5) { rng.next_u64 }
      resumed = ReactorSim::Rng.from_h(snapshot)

      expect(Array.new(5) { resumed.next_u64 }).to eq(expected)
    end

    it "gives different streams different sequences" do
      a = ReactorSim::Rng.stream(7, "vats/vessel")
      b = ReactorSim::Rng.stream(7, "vats/turbine")

      expect(Array.new(5) { a.next_u64 }).not_to eq(Array.new(5) { b.next_u64 })
    end

    it "does not depend on String#hash, which is randomised per process" do
      # Same seed and name must give the same stream in any process. If Rng.stream
      # used String#hash this would pass in-process and fail across restarts, which is
      # the worst possible failure mode.
      expect(ReactorSim::Rng.stream(7, "vats/vessel").state)
        .to eq(ReactorSim::Rng.stream(7, "vats/vessel").state)
    end
  end
end
