# frozen_string_literal: true

# One achievement, earned once, by one owner, permanently.
#
# The same shape as `Unlock` and for the same reason: there is no quantity and no condition,
# because earning a thing is not a resource you spend. Where an unlock is the right to mint a
# part, an award is a fact about what somebody has done — and some unlocks are gated on one
# (`Blueprint#requires_achievement`).
class Award < ApplicationRecord
  validates :owner_id, :achievement_id, presence: true
  validates :achievement_id, uniqueness: { scope: :owner_id }
  validate :achievement_must_exist

  scope :owned_by, ->(owner_id) { where(owner_id: owner_id.to_s) }

  # Idempotent, and that is load-bearing rather than convenient: `match.events` is
  # at-least-once, so the consumer awarding this WILL see the same fact twice after a
  # rebalance or a replayed tick. The unique index is the backstop and this is the path.
  def self.grant(owner_id:, achievement_id:, run_id: nil, tick: nil)
    create_with(run_id: run_id, tick: tick)
      .find_or_create_by!(owner_id: owner_id.to_s, achievement_id: achievement_id.to_s)
  rescue ActiveRecord::RecordNotUnique
    # Two consumers racing the same fact. The row exists, which is the entire point.
    find_by(owner_id: owner_id.to_s, achievement_id: achievement_id.to_s)
  end

  # Every achievement id one owner holds, as a Set of Strings. One query then membership
  # tests, exactly as `Unlock.owned_ids` does — the outfitting screen asks "may I have this?"
  # about every candidate in every slot, and a query per question is hundreds of round trips.
  def self.earned_ids(owner_id) = owned_by(owner_id).pluck(:achievement_id).to_set

  private

  # The same guard `Unlock` applies to blueprint ids, for the same reason: an award naming an
  # achievement nobody defines is a row that can never be explained, and a lookup that silently
  # misses is a feature silently switched off.
  def achievement_must_exist
    return if achievement_id.blank? || Achievement.known?(achievement_id)

    errors.add(:achievement_id, "is not a known achievement")
  end
end
