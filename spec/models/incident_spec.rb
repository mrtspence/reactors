# frozen_string_literal: true

require "rails_helper"

# The durable incident feed, and the identity that makes it safe under at-least-once delivery.
RSpec.describe Incident do
  def record(tick: 10, seq: 0, severity: "critical", type: "part_failed", run: "run-a")
    { "run_id" => run, "operation_id" => "engine", "tick" => tick, "seq" => seq,
      "type" => type, "node" => "flywheel", "mode" => "burst", "severity" => severity,
      "detail" => { "rpm" => 311.7 } }
  end

  # `type` is an ordinary column here. Rails would otherwise read it as the single-table
  # inheritance column and try to instantiate a class called "part_failed" on every load.
  it "treats type as data rather than as a subclass to instantiate" do
    described_class.record!(record)

    expect(described_class.first.type).to eq("part_failed")
  end

  # **The dedupe key is the unique index.** A crash between producing a tick's events and
  # snapshotting past them replays that tick and re-emits every one; determinism guarantees the
  # same `(run_id, operation_id, tick, seq)`, so the redelivery must be a no-op rather than a
  # second line in the feed.
  it "is idempotent under redelivery" do
    2.times { described_class.record!(record) }

    expect(described_class.count).to eq(1)
  end

  it "keeps two events from the same tick apart by their sequence" do
    described_class.record!(record(seq: 0))
    described_class.record!(record(seq: 1))

    expect(described_class.count).to eq(2)
  end

  # A reset restarts the tick count, so the same tick number recurs under a new run. Only the
  # run id separates them, which is the whole reason it exists.
  it "keeps the same tick in two different runs apart" do
    described_class.record!(record(run: "run-a"))
    described_class.record!(record(run: "run-b"))

    expect(described_class.count).to eq(2)
  end

  describe "backfill" do
    # The log is complete and the feed is curated. Storing everything and showing everything
    # would bury a burst flywheel under the ordinary business of driving an engine — and worse,
    # history would disagree with live, which filters at the projection.
    it "hides the transitions the live feed also hides" do
      described_class.record!(record(tick: 1, severity: "info", type: "fire_lit"))
      described_class.record!(record(tick: 2, severity: "critical"))

      expect(described_class.backfill("run-a").map { |i| i[:type] }).to eq([ "part_failed" ])
    end

    it "returns oldest first, so a client can append in order" do
      described_class.record!(record(tick: 30))
      described_class.record!(record(tick: 10))
      described_class.record!(record(tick: 20))

      expect(described_class.backfill("run-a").map { |i| i[:tick] }).to eq([ 10, 20, 30 ])
    end

    # The limit takes the NEWEST, then reverses. A backfill that kept the oldest fifty would
    # show a joining spectator the start of a match and nothing since.
    it "keeps the most recent when there are more than it will send" do
      5.times { |i| described_class.record!(record(tick: i + 1)) }

      expect(described_class.backfill("run-a", limit: 2).map { |i| i[:tick] }).to eq([ 4, 5 ])
    end

    it "says nothing about a run it has never seen" do
      expect(described_class.backfill("nobody")).to be_empty
    end
  end
end
