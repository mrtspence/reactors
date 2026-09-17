# frozen_string_literal: true

require "rails_helper"

# One build of one match, and the retention policy that hangs off it.
RSpec.describe MatchRun do
  # The runner never writes this — it holds the match in memory and talks to Kafka, and may not
  # reach a database at all. The log is what tells this side a run exists, so first sight of a
  # record creates the row.
  it "is created on first sight and not again" do
    2.times { described_class.observe!(run_id: "run-a", match_id: "dev") }

    expect(described_class.count).to eq(1)
  end

  it "keeps two builds of the same match apart" do
    described_class.observe!(run_id: "run-a", match_id: "dev")
    described_class.observe!(run_id: "run-b", match_id: "dev")

    expect(described_class.for_match("dev").count).to eq(2)
  end

  describe "the sweep" do
    # **What is swept is working material; what survives is the player's permanent record.**
    # That split is the policy, so it is worth asserting both halves rather than only that
    # something was deleted.
    before do
      old = described_class.create!(run_id: "old", match_id: "dev",
                                    created_at: 8.days.ago, updated_at: 8.days.ago)
      Incident.record!({ "run_id" => old.run_id, "operation_id" => "engine", "tick" => 1,
                         "seq" => 0, "type" => "part_failed", "severity" => "critical" })
      AchievementAttempt.create!(owner_id: "t", run_id: old.run_id,
                                 achievement_id: "burst_a_flywheel", opened_at_tick: 1)
      Progress.create!(owner_id: "t", run_id: old.run_id, metric: "joules_to_work", value: 5.0)
      Progress.create!(owner_id: "t", run_id: nil, metric: "joules_to_work", value: 5.0)
      Award.grant(owner_id: "t", achievement_id: :burst_a_flywheel, run_id: old.run_id)
    end

    it "takes the run's working material with it" do
      described_class.sweep!

      expect(described_class.count).to eq(0)
      expect(Incident.count).to eq(0)
      expect(AchievementAttempt.count).to eq(0)
      expect(Progress.where.not(run_id: nil).count).to eq(0)
    end

    # An award outlives every match that produced it. It is keyed to an owner rather than to a
    # run precisely so a sweep cannot reach it — and so can the lifetime total, which is why the
    # null-`run_id` row survives while the per-run one does not.
    it "leaves the permanent record alone" do
      described_class.sweep!

      expect(Award.count).to eq(1)
      expect(Progress.lifetime.count).to eq(1)
    end

    it "leaves a run inside the retention window alone" do
      described_class.observe!(run_id: "fresh", match_id: "dev")

      described_class.sweep!

      expect(described_class.pluck(:run_id)).to eq([ "fresh" ])
    end
  end
end
