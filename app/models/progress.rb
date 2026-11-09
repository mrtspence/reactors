# frozen_string_literal: true

# A cumulative quantity, folded from the ledger.
#
# Two kinds of row, separated by `run_id`: one per operation per run holding its contribution,
# and one with a null `run_id` holding the owner's lifetime total on that kind of machine
# (`operation_type`). Values arrive as **absolute** meter readings rather than deltas, which is
# what makes the fold idempotent — see `ProgressionDigest`.
class Progress < ApplicationRecord
  validates :owner_id, :metric, :operation_type, presence: true
  validates :value, numericality: true

  scope :owned_by, ->(owner_id) { where(owner_id: owner_id.to_s) }
  scope :lifetime, -> { where(run_id: nil) }
  scope :for_run, ->(run_id) { where(run_id: run_id) }

  # Every lifetime figure one owner holds on one kind of machine, as `{ metric => value }`. One
  # query, then lookups — the same shape as `Unlock.owned_ids`, for the same reason.
  def self.lifetime_totals(owner_id, operation_type)
    owned_by(owner_id).lifetime.where(operation_type: operation_type.to_s).pluck(:metric, :value).to_h
  end
end
