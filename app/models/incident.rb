# frozen_string_literal: true

# One thing that went wrong, durably.
#
# **This is the row that fixes the actual complaint**: before it, an incident existed only
# inside whatever projection happened to be broadcast, so a spectator joining one tick late saw
# "nothing has gone wrong yet" beside a wrecked engine. Backfilled on subscribe.
#
# Every severity the engine emits is recorded, not just the ones the panel shows — the log is
# complete and the feed is curated (`ReactorSim::Operation#incidents` does the curating). What
# a player sees and what the record holds are different questions.
class Incident < ApplicationRecord
  validates :run_id, :operation_id, :type, :severity, presence: true
  validates :tick, :seq, presence: true

  # `type` is an ordinary column here, not Rails' single-table-inheritance column. Declared so,
  # because the inherited meaning would try to instantiate a class named "part_failed".
  self.inheritance_column = nil

  scope :for_run, ->(run_id) { where(run_id: run_id) }
  scope :newest_first, -> { order(tick: :desc, seq: :desc) }

  # Upserted rather than created, because `match.events` is at-least-once: a crash between
  # producing a tick's events and snapshotting past them replays that tick and re-emits every
  # one of them. The unique index on `(run_id, operation_id, tick, seq)` turns that redelivery
  # into a no-op instead of a duplicate line in the feed.
  def self.record!(record)
    upsert(
      { run_id: record.fetch("run_id"), operation_id: record.fetch("operation_id").to_s,
        tick: record.fetch("tick"), seq: record.fetch("seq"),
        type: record.fetch("type").to_s, node: record["node"]&.to_s,
        mode: record["mode"]&.to_s, severity: record.fetch("severity").to_s,
        detail: record["detail"] || {},
        created_at: Time.current, updated_at: Time.current },
      unique_by: %i[run_id operation_id tick seq]
    )
  end

  # What a newly subscribed client is sent, oldest first so it can append in order. Shaped like
  # the events the projection carries, so the client has one renderer rather than two.
  #
  # **Curated to the same severities the live feed shows**, and it has to be: the log holds
  # every transition, so backfilling everything would give a joining spectator a history full
  # of "fire lit" that the live path then never adds to. History and live must agree about what
  # the feed is for, and `ReactorSim::Operation::REPORTED_SEVERITIES` is where that is decided.
  def self.backfill(run_id, limit: 50)
    reported = ReactorSim::Operation::REPORTED_SEVERITIES.map(&:to_s)

    for_run(run_id).where(severity: reported).newest_first.limit(limit).reverse.map do |row|
      { type: row.type, node: row.node, mode: row.mode, severity: row.severity,
        tick: row.tick, detail: row.detail }.compact
    end
  end
end
