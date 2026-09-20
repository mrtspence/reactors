# frozen_string_literal: true

# A cumulative quantity, folded from the ledger.
#
# Two kinds of row, separated by `run_id`: one per run holding that run's contribution, and one
# with a null `run_id` holding the owner's lifetime total. Values arrive as **absolute** meter
# readings rather than deltas, which is what makes the fold idempotent — see
# `ProgressionDigest`.
class Progress < ApplicationRecord
  validates :owner_id, :metric, presence: true
  validates :value, numericality: true

  scope :owned_by, ->(owner_id) { where(owner_id: owner_id.to_s) }
  scope :lifetime, -> { where(run_id: nil) }
  scope :for_run, ->(run_id) { where(run_id: run_id) }

  # Every lifetime figure one owner holds, as `{ metric => value }`. One query, then lookups —
  # the same shape as `Unlock.owned_ids`, for the same reason.
  def self.lifetime_totals(owner_id)
    owned_by(owner_id).lifetime.pluck(:metric, :value).to_h
  end
end
