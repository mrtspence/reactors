# frozen_string_literal: true

# Somebody who is not available, and for how much longer.
#
# The injury list. `:mortal` is the only tier that reaches here — minor and severe are match
# state and die with the match, so a bad shift does not follow somebody into next week, but
# being carried out in a box does.
#
# **This is what gives the standin its sting.** A player who loses a favourite does not merely
# lose some stats; they get a kobold from the labour exchange in that job for the next two or
# three matches, and the kobold is `clumsy`, which makes the next accident likelier. That
# compounding is the point.
class MinionCondition < ApplicationRecord
  # A mortal injury costs somewhere between one and three matches. Seeded from the run rather
  # than rolled at random, so the same match replays to the same consequence — the determinism
  # the whole injury model is built on does not stop at the simulation's edge.
  RECOVERY = (1..3).freeze

  validates :owner_id, :minion_id, presence: true
  validates :minion_id, uniqueness: { scope: :owner_id }
  validates :matches_remaining, numericality: { greater_than_or_equal_to: 0 }

  scope :owned_by, ->(owner_id) { where(owner_id: owner_id.to_s) }
  scope :unavailable, -> { where(matches_remaining: 1..) }

  # `{ minion_id => matches_remaining }` for one owner. One query, then lookups — the roster
  # screen asks about every candidate in every role.
  def self.remaining_for(owner_id)
    owned_by(owner_id).unavailable.pluck(:minion_id, :matches_remaining).to_h
  end

  def self.available?(owner_id, minion_id)
    !unavailable.exists?(owner_id: owner_id.to_s, minion_id: minion_id.to_s)
  end

  # **Idempotent, because the event that causes it is at-least-once.** A replayed tick re-emits
  # the injury, and a consumer seeing it twice must not extend the sentence. Pinned to `run_id`:
  # the same run hurting the same person is one injury however many times it is delivered, and a
  # *later* run is a genuinely new one.
  def self.record!(owner_id:, minion_id:, run_id:, cause: nil, matches: nil)
    row = find_or_initialize_by(owner_id: owner_id.to_s, minion_id: minion_id.to_s)
    return row if row.persisted? && row.run_id == run_id.to_s

    row.update!(run_id: run_id.to_s, cause: cause,
                matches_remaining: matches || recovery_for(owner_id, minion_id, run_id))
    row
  end

  # Derived from the run and the person rather than drawn, so a replay of the same match takes
  # the same person out for the same length of time.
  def self.recovery_for(owner_id, minion_id, run_id)
    stream = ReactorSim::Rng.stream(0, "il/#{run_id}/#{owner_id}/#{minion_id}")

    RECOVERY.begin + (stream.float * RECOVERY.count).floor.clamp(0, RECOVERY.count - 1)
  end

  # Called once per match START, which is what makes the clock advance. A row at zero is somebody
  # who has recovered and is left in place rather than deleted, so the screen can still say what
  # happened to them.
  def self.advance!(owner_id)
    owned_by(owner_id).unavailable.update_all("matches_remaining = matches_remaining - 1")
  end
end
