# frozen_string_literal: true

# One build of one match.
#
# **Not one row per match**, and the difference is the whole reason this table exists.
# `MatchRunner#reset` rebuilds a match in place under the same `match_id` and the tick count
# restarts at zero, so `(match_id, tick)` names two different moments in two different runs.
# Everything durable hangs off `run_id` instead.
#
# It is also the identity `match.lifecycle` will carry when matches are created on demand
# rather than at runner boot, which is why it was introduced now rather than deferred: the dev
# match's reset button forces the concept early.
class MatchRun < ApplicationRecord
  # One week, matching `match.commands` retention — which is what bounds replay anyway, so
  # there is one number to change rather than two that can silently disagree.
  #
  # `awards` and the lifetime rows in `progresses` are the permanent record and are NOT swept:
  # they are keyed to an owner rather than to a run, and they are the only things here meant to
  # outlive the match that produced them.
  RETENTION = 7.days

  validates :run_id, :match_id, presence: true
  validates :run_id, uniqueness: true

  has_many :incidents, foreign_key: :run_id, primary_key: :run_id, dependent: :delete_all,
                       inverse_of: false

  scope :for_match, ->(match_id) { where(match_id: match_id.to_s) }
  scope :newest_first, -> { order(created_at: :desc) }
  scope :stale, ->(before = RETENTION.ago) { where(created_at: ...before) }

  # Created on first sight rather than by the runner, because the runner may not reach a
  # database at all — it holds the match in memory and talks to Kafka. The log is what tells
  # this side a run exists.
  def self.observe!(run_id:, match_id:)
    find_or_create_by!(run_id: run_id, match_id: match_id.to_s) do |row|
      row.started_at = Time.current
    end
  rescue ActiveRecord::RecordNotUnique
    find_by(run_id: run_id)
  end

  # Incidents and open attempts go with the run; the player's permanent record does not.
  def self.sweep!(before = RETENTION.ago)
    stale(before).find_each do |run|
      Incident.for_run(run.run_id).delete_all
      AchievementAttempt.where(run_id: run.run_id).delete_all
      Progress.for_run(run.run_id).delete_all
      run.destroy!
    end
  end
end
