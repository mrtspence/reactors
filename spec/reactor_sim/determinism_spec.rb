# frozen_string_literal: true

require "reactor_sim"
require "support/loop_rig"

# The other keystone. Exact crash recovery, free replay and spectating all reduce to one
# claim: seed + command log reproduces a match exactly (docs/architecture.md §6, §8).
#
# The command-idempotence examples matter as much as the reproducibility ones. Kafka is
# at-least-once, so redelivery WILL happen on rebalance or crash-before-commit. Absolute,
# clamped, target-only commands are what make that harmless without a dedup table — and
# what lets the runner commit offsets after snapshotting rather than before.
RSpec.describe "determinism" do
  def match(seed: 20_260_824, time_scale: 4.0)
    ReactorSim::Match.create(
      id: "d", seed: seed, operations: [ { id: "rig", type: :loop_rig } ], time_scale:
    )
  end

  def run(match, commands: {}, ticks: 80)
    (1..ticks).each do |t|
      Array(commands[t]).each { |command| match.apply([ command ]) }
      match.step!
    end
    match.digest
  end

  def command(control, value)
    { type: "set_control", operation_id: "rig", control_point_id: control.to_s, value: value }
  end

  it "reproduces a match exactly from the same seed and the same commands" do
    commands = { 1 => [ command(:burner, 60) ], 30 => [ command(:steam_valve, 40) ] }

    expect(run(match, commands:)).to eq(run(match, commands:))
  end

  it "diverges from a different seed" do
    expect(run(match(seed: 1))).not_to eq(run(match(seed: 2)))
  end

  describe "snapshot and restore" do
    it "round-trips through JSON without losing a bit" do
      m = match
      m.apply([ command(:burner, 70) ])
      40.times { m.step! }

      restored = ReactorSim::Match.from_h(JSON.parse(JSON.generate(m.to_h)))

      expect(restored.digest).to eq(m.digest)
    end

    # This is the property crash recovery actually depends on: not just that the snapshot
    # looks the same, but that the match continues identically from it.
    it "continues identically after being restored mid-match" do
      original = match
      original.apply([ command(:burner, 70) ])
      40.times { original.step! }

      restored = ReactorSim::Match.from_h(JSON.parse(JSON.generate(original.to_h)))
      40.times { original.step!; restored.step! }

      expect(restored.digest).to eq(original.digest)
    end

    it "resumes the RNG stream from where the snapshot left it" do
      m = match
      20.times { m.step! }
      restored = ReactorSim::Match.from_h(JSON.parse(JSON.generate(m.to_h)))

      expect(restored.to_h.dig(:operations, 0, :rngs)).to eq(m.to_h.dig(:operations, 0, :rngs))
    end
  end

  describe "command idempotence" do
    it "is unchanged by duplicate delivery" do
      once = match.tap { |m| m.apply([ command(:burner, 60) ]) }
      twice = match.tap { |m| m.apply([ command(:burner, 60), command(:burner, 60) ]) }

      expect(run(twice)).to eq(run(once))
    end

    it "is unchanged by the order commands arrive in" do
      forward = [ command(:burner, 60), command(:steam_valve, 30) ]
      reverse = forward.reverse

      expect(run(match.tap { |m| m.apply(reverse) })).to eq(run(match.tap { |m| m.apply(forward) }))
    end

    it "takes the last value when the same lever is set twice" do
      both = match.tap { |m| m.apply([ command(:burner, 20), command(:burner, 90) ]) }
      last = match.tap { |m| m.apply([ command(:burner, 90) ]) }

      expect(run(both)).to eq(run(last))
    end

    it "clamps rather than rejecting an out-of-range value" do
      m = match
      m.apply([ command(:burner, 500) ])

      expect(m.operation(:rig).state.fetch(:controls).fetch(:burner).fetch(:target)).to eq(100.0)
    end

    # Commands set targets and nothing else. If actuation entropy were drawn here instead
    # of inside the tick, replaying the log would consume the RNG differently and every
    # guarantee above would quietly stop being true.
    it "moves only the target, never the actual" do
      m = match
      m.apply([ command(:burner, 80) ])
      control = m.operation(:rig).state.fetch(:controls).fetch(:burner)

      expect(control.fetch(:target)).to eq(80.0)
      expect(control.fetch(:actual)).to eq(0.0)
    end

    it "rejects a malformed command instead of letting it kill the match" do
      m = match
      result = m.apply([ { type: "nonsense" }, command(:burner, 50) ])

      expect(result[:applied]).to eq(1)
      expect(result[:rejected].size).to eq(1)
    end

    # The value used to be the one field that reached the simulation uninspected. It ends up
    # at ControlPoint#set_target, which calls `.to_f`, and a Hash does not answer to that —
    # so one bad record raised NoMethodError out of #apply, which does not rescue. In the
    # runner that is the process and every match on it, killed from a line in the log that
    # anyone who can reach the topic could write.
    it "rejects a non-numeric value rather than raising out of apply" do
      m = match

      [ { "a" => 1 }, [ 1 ], "abc", true, nil ].each do |bad|
        result = nil
        expect { result = m.apply([ command(:burner, bad) ]) }.not_to raise_error
        expect(result[:applied]).to eq(0), "expected #{bad.inspect} to be rejected"
      end
    end

    it "still accepts a numeric value that arrived as a string over JSON" do
      m = match
      result = m.apply([ command(:burner, "60") ])

      expect(result[:applied]).to eq(1)
      expect(m.operation(:rig).state.fetch(:controls).fetch(:burner).fetch(:target)).to eq(60.0)
    end
  end

  # Observation must not advance the simulation. A tick may be projected any number of
  # times — a player view, a spectator view, a resync of either — and if reading changed
  # anything, how many people happened to be watching would alter the match.
  #
  # This is why noise, sticking and misreads are drawn once in `record` rather than at read
  # time, and it is the reason `Diagnostic#read` is a pure lookup.
  it "is not affected by how many times it is observed" do
    watched = match
    watched.apply([ command(:burner, 60) ])
    ignored = match
    ignored.apply([ command(:burner, 60) ])

    40.times do
      watched.step!
      5.times do
        watched.project(operation_id: :rig)
        watched.project(operation_id: :rig, viewer: :spectator)
        watched.telemetry(operation_id: :rig)
      end
      ignored.step!
    end

    expect(watched.digest).to eq(ignored.digest)
  end
end
