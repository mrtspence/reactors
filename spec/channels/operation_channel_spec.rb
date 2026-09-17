# frozen_string_literal: true

require "rails_helper"

# Subscribing, and the backfill that arrives with it.
#
# **The backfill is the fix for the thing that was actually broken.** An incident used to exist
# only inside whatever projection happened to be broadcast, so the list a browser built up
# covered exactly the ticks it had been connected for — a spectator joining one tick after the
# flywheel burst was told nothing had gone wrong, beside a wrecked engine.
RSpec.describe OperationChannel do
  def incident(tick:, severity: "critical", type: "part_failed", run:)
    Incident.record!({ "run_id" => run, "operation_id" => "engine", "tick" => tick, "seq" => 0,
                       "type" => type, "node" => "flywheel", "mode" => "burst",
                       "severity" => severity, "detail" => { "rpm" => 311.7 } })
  end

  def subscribe_to_engine
    subscribe(match_id: DevMatch::ID, operation_id: DevMatch::OPERATION_ID.to_s)
  end

  # Channel tests hand back the payload as it was passed, with its Symbol keys; the real path
  # JSON-encodes it on the way to the browser and the client sees Strings. Read it the way the
  # wire does, so the spec cannot pass on a shape a client would never receive.
  def backfill
    transmissions.map(&:with_indifferent_access).find { |t| t["kind"] == "backfill" }
  end

  it "refuses a match it does not host" do
    subscribe(match_id: "somebody-elses", operation_id: "engine")

    expect(subscription).to be_rejected
  end

  it "streams the telemetry the runner broadcasts on" do
    subscribe_to_engine

    expect(subscription).to have_stream_from(
      StreamNames.operation(match_id: DevMatch::ID, operation_id: DevMatch::OPERATION_ID.to_s)
    )
  end

  describe "backfill" do
    it "sends what already went wrong to a client that has just arrived" do
      run = MatchRun.observe!(run_id: "run-a", match_id: DevMatch::ID)
      incident(tick: 412, run: run.run_id)

      subscribe_to_engine

      expect(backfill["incidents"].map { |i| i["tick"] }).to eq([ 412 ])
    end

    # A reset rebuilds the match, and the previous run's wreckage is about a machine that no
    # longer exists. Newest run only.
    it "carries only the current run" do
      MatchRun.create!(run_id: "old", match_id: DevMatch::ID, created_at: 1.hour.ago)
      incident(tick: 1, run: "old")
      MatchRun.observe!(run_id: "new", match_id: DevMatch::ID)
      incident(tick: 2, run: "new")

      subscribe_to_engine

      expect(backfill["run_id"]).to eq("new")
      expect(backfill["incidents"].map { |i| i["tick"] }).to eq([ 2 ])
    end

    it "says nothing at all when the run has been clean" do
      MatchRun.observe!(run_id: "run-a", match_id: DevMatch::ID)

      subscribe_to_engine

      expect(backfill).to be_nil
    end

    # A panel with no history is worth far more than no panel, so a failure here must cost the
    # backfill and nothing else.
    it "still subscribes when the log cannot be read" do
      allow(MatchRun).to receive(:for_match).and_raise(ActiveRecord::StatementInvalid, "boom")

      subscribe_to_engine

      expect(subscription).to be_confirmed
      expect(subscription).not_to be_rejected
    end
  end
end
