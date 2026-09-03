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

    def publish(match, operation, full: false)
      @published << { tick: match.tick, operation_id: operation&.id, full: full }
    end

    def reset(match_id) = @resets << match_id
    def close = @closed = true
  end

  def run_with(batches)
    ref = {}
    sink = RecordingSink.new
    source = ScriptedSource.new(batches, ref)
    match = DevMatch.build
    runner = described_class.new(matches: { DevMatch::ID => match },
                                 logger: Logger.new(File::NULL),
                                 source: source, sink: sink)
    ref[:runner] = runner
    runner.run
    { match: match, sink: sink, source: source, runner: runner }
  end

  def control(id, value)
    { "type" => "set_control", "operation_id" => DevMatch::OPERATION_ID.to_s,
      "control_point_id" => id.to_s, "value" => value }
  end

  it "applies a command before stepping, so it takes effect on the same tick" do
    result = run_with([ [ control(:damper_open, 80) ] ])
    controls = result[:match].operation(DevMatch::OPERATION_ID).state.fetch(:controls)

    expect(controls.fetch(:damper_open).fetch(:target)).to eq(80.0)
    expect(result[:match].tick).to eq(1)
  end

  it "publishes a view for each operation every tick" do
    result = run_with([ [], [], [] ])

    expect(result[:sink].published.map { |p| p[:tick] }).to eq([ 1, 2, 3 ])
    expect(result[:sink].published.map { |p| p[:operation_id] }.uniq).to eq([ DevMatch::OPERATION_ID ])
  end

  # A malformed record must not be able to stop a match. Command.parse and Match#apply are
  # both written not to raise on this, and the sim specs hold them to it — this proves the
  # runner survives the whole path.
  it "survives a command whose value is not a number" do
    result = run_with([ [ control(:damper_open, { "a" => 1 }) ], [ control(:damper_open, 70) ] ])
    controls = result[:match].operation(DevMatch::OPERATION_ID).state.fetch(:controls)

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
      controls = result[:match].operation(DevMatch::OPERATION_ID).state.fetch(:controls)

      expect(result[:sink].resets).to eq([ DevMatch::ID ])
      # The original object is untouched — reset swaps in a new Match, it does not mutate.
      expect(controls.fetch(:damper_open).fetch(:target)).to eq(80.0)
    end

    it "asks the sink for a full view on resync" do
      result = run_with([ [ { "type" => "resync" } ], [] ])

      expect(result[:sink].published.count { |p| p[:full] }).to eq(1)
    end
  end

  it "closes its source and sink on the way out" do
    result = run_with([ [] ])

    expect(result[:source].closed).to be(true)
    expect(result[:sink].closed).to be(true)
  end
end
