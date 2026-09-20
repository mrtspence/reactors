# frozen_string_literal: true

require "rails_helper"

# The tick barrier and the command routing over it. Deliberately NOT the timing: the loop's
# 4 Hz cadence and its drift behaviour are verified by running it, because a spec that asserts
# on sleep is slow, flaky, and tests the machine's mood rather than the code.
#
# What is worth guarding here is the routing — that simulation commands reach `Match#apply`
# before the step, that runner-addressed ones never do, and that a bad record cannot take the
# process down with it.
RSpec.describe MatchRunner do
  # Feeds a fixed script of commands, one batch per tick, then stops the loop. Stopping from
  # the source rather than from a timer is what keeps this deterministic.
  class ScriptedSource
    attr_reader :closed

    def initialize(batches, runner_ref)
      @batches = batches
      @runner_ref = runner_ref
      @closed = false
    end

    def drain(inboxes)
      batch = @batches.shift
      @runner_ref[:runner].stop if @batches.empty?
      Array(batch).each { |command| inboxes[DevMatch::ID] << command }
    end

    def close = @closed = true
  end

  class RecordingSink
    attr_reader :published, :resets, :closed

    def initialize = (@published = []; @resets = []; @closed = false)

    def publish(match, operation, full: false, run_id: nil, supersedes: nil)
      @published << { tick: match.tick, operation_id: operation&.id, full: full,
                      run_id: run_id, supersedes: supersedes, match: match }
    end

    def reset(match_id) = @resets << match_id
    def close = @closed = true
  end

  # Stands in for `EventProducer` so the durable path can be exercised with no broker at all —
  # the same reason the sink is injected.
  class RecordingEvents
    attr_reader :facts, :meters, :closed

    def initialize = (@facts = []; @meters = []; @closed = false)

    def publish(match, events, run_id:)
      events.each { |e| @facts << e.merge(match_id: match.id, run_id: run_id) }
    end

    def publish_meters(match, tick, run_id:)
      @meters << { tick: tick, run_id: run_id, ledger: match.operations.first.ledger }
    end

    def stats = { sent: @facts.length, failed: 0 }
    def close = @closed = true
  end

  def run_with(batches)
    ref = {}
    sink = RecordingSink.new
    events = RecordingEvents.new
    source = ScriptedSource.new(batches, ref)
    match = DevMatch.build
    runner = described_class.new(matches: { DevMatch::ID => match },
                                 logger: Logger.new(File::NULL),
                                 source: source, sink: sink, events: events)
    ref[:runner] = runner
    runner.run
    { match: match, sink: sink, source: source, runner: runner, events: events }
  end

  def control(id, value)
    { "type" => "set_control", "operation_id" => DevMatch::PRIMARY.to_s,
      "control_point_id" => id.to_s, "value" => value }
  end

  def target(match, control_point_id)
    match.operation(DevMatch::PRIMARY).state.fetch(:controls)
         .fetch(control_point_id).fetch(:target)
  end

  it "applies a command before stepping, so it takes effect on the same tick" do
    result = run_with([ [ control(:damper_open, 80) ] ])
    controls = result[:match].operation(DevMatch::PRIMARY).state.fetch(:controls)

    expect(controls.fetch(:damper_open).fetch(:target)).to eq(80.0)
    expect(result[:match].tick).to eq(1)
  end

  # **Each operation, every tick** — which is what the name always said and what only became
  # checkable once there was more than one machine. Two operations in lockstep means two views
  # per tick, each naming itself.
  it "publishes a view for each operation every tick" do
    result = run_with([ [], [], [] ])
    published = result[:sink].published

    expect(published.map { |p| p[:tick] }).to eq([ 1, 1, 2, 2, 3, 3 ])
    expect(published.map { |p| p[:operation_id] }.uniq).to match_array(DevMatch.operation_ids)
  end

  # A malformed record must not be able to stop a match. Command.parse and Match#apply are
  # both written not to raise on this, and the sim specs hold them to it — this proves the
  # runner survives the whole path.
  it "survives a command whose value is not a number" do
    result = run_with([ [ control(:damper_open, { "a" => 1 }) ], [ control(:damper_open, 70) ] ])
    controls = result[:match].operation(DevMatch::PRIMARY).state.fetch(:controls)

    expect(result[:match].tick).to eq(2)
    expect(controls.fetch(:damper_open).fetch(:target)).to eq(70.0)
  end

  it "survives a record the simulation has never heard of" do
    result = run_with([ [ { "type" => "nonsense" } ], [] ])

    expect(result[:match].tick).to eq(2)
  end

  describe "commands addressed to the runner" do
    # These ride the same log as control commands specifically so they stay ORDERED against
    # them — "reset, then open the throttle" has to mean what it says.
    it "rebuilds the match on reset rather than passing it to the simulation" do
      result = run_with([ [ control(:damper_open, 80) ], [ { "type" => "reset_match" } ], [] ])
      controls = result[:match].operation(DevMatch::PRIMARY).state.fetch(:controls)

      expect(result[:sink].resets).to eq([ DevMatch::ID ])
      # The original object is untouched — reset swaps in a new Match, it does not mutate.
      expect(controls.fetch(:damper_open).fetch(:target)).to eq(80.0)
    end

    # The ordering these share a log for. A reset swaps in a new Match, so everything after it
    # in the same batch belongs to that one — holding the object from before the barrier steps
    # and publishes the match that was just discarded.
    it "applies a command that follows a reset to the rebuilt match, not the discarded one" do
      result = run_with([ [ { "type" => "reset_match" }, control(:damper_open, 80) ], [] ])
      rebuilt = result[:sink].published.last[:match]

      expect(rebuilt).not_to equal(result[:match])
      expect(target(rebuilt, :damper_open)).to eq(80.0)
      expect(target(result[:match], :damper_open)).not_to eq(80.0)
    end

    it "asks the sink for a full view on resync" do
      result = run_with([ [ { "type" => "resync" } ], [] ])

      expect(result[:sink].published.count { |p| p[:full] }).to eq(1)
    end

    # **The reset hazard, and the reason `run_id` exists at all.** A rebuilt match restarts at
    # tick 0 under the same `match_id`, so a durable log keyed on `(match_id, tick)` would have
    # two different moments claiming tick 412 — and a consumer folding that stream corrupts
    # itself the first time somebody recovers from a burst flywheel.
    it "starts a new run on reset, so a rebuilt match cannot collide with the old one" do
      quiet = Array.new(EventProducer::METER_TICKS) { [] }
      result = run_with(quiet + [ [ { "type" => "reset_match" } ] ] + quiet)
      meters = result[:events].meters

      # A reset restarts the tick count, so both readings are stamped tick 40 — which is
      # exactly the collision. Only the run id separates them.
      expect(meters.map { |m| m[:tick] }).to eq([ EventProducer::METER_TICKS ] * 2)
      expect(meters.map { |m| m[:run_id] }.uniq.length).to eq(2)
    end

    # A restarted runner announces nothing, so a client falls back to a grace period; a reset
    # can do better, and saying so is what keeps a legitimate rebuild from looking like a second
    # runner broadcasting over the first.
    it "names the run it replaced, so a watching client adopts it rather than ignoring it" do
      result = run_with([ [], [ { "type" => "reset_match" } ], [] ])
      before, after = result[:sink].published.partition { |p| p[:supersedes].nil? }

      expect(before).not_to be_empty
      expect(after).not_to be_empty
      expect(after.map { |p| p[:supersedes] }.uniq).to eq([ before.first[:run_id] ])
      expect(after.map { |p| p[:run_id] }.uniq).not_to eq([ before.first[:run_id] ])
    end
  end

  describe "the durable record" do
    # The dual write. The projection is a cache that self-heals; this is the record that does
    # not, and it carries everything rather than the curated subset the panel shows.
    it "samples the ledger on the meter interval, absolutely rather than as a delta" do
      result = run_with(Array.new(EventProducer::METER_TICKS + 1) { [] })
      meters = result[:events].meters

      expect(meters.map { |m| m[:tick] }).to eq([ EventProducer::METER_TICKS ])
      expect(meters.first[:ledger]).to include(:joules_to_work, :mass_added)
    end

    it "stamps one run id across a match's whole stream" do
      result = run_with(Array.new(EventProducer::METER_TICKS + 1) { [] })

      expect(result[:events].meters.map { |m| m[:run_id] }.uniq.length).to eq(1)
    end
  end

  it "closes its source and sink on the way out" do
    result = run_with([ [] ])

    expect(result[:source].closed).to be(true)
    expect(result[:sink].closed).to be(true)
  end
end
