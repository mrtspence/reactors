# frozen_string_literal: true

# What one of a player's people holds against another, from earlier matches.
#
# Formed in play (`grudge_formed`), handed back to the simulation at build through `options:`, and
# worn down each match start by the holder's spite (`ReactorSim::Animosity.faded`). Race and
# authored grudges are content and never written here.
class Grudge < ApplicationRecord
  # Below this a grudge is forgotten, and the row goes.
  FORGOTTEN = 0.01

  validates :owner_id, :holder_id, :target_id, presence: true
  validates :target_id, uniqueness: { scope: %i[owner_id holder_id] }
  validates :amount, numericality: { greater_than_or_equal_to: 0.0, less_than_or_equal_to: 1.0 }

  scope :owned_by, ->(owner_id) { where(owner_id: owner_id.to_s) }

  # `{ holder => { target => amount } }`, as the simulation takes it.
  def self.carried_for(owner_id)
    owned_by(owner_id).each_with_object({}) do |row, acc|
      (acc[row.holder_id] ||= {})[row.target_id] = row.amount
    end
  end

  # **Idempotent, because the event that causes it is at-least-once.** The same tick of the same
  # run deepens a grudge once however many times it is delivered.
  def self.deepen!(owner_id:, holder_id:, target_id:, amount:, run_id:, tick:)
    row = find_or_initialize_by(owner_id: owner_id.to_s, holder_id: holder_id.to_s, target_id: target_id.to_s)
    row.applied_ticks = [] unless row.run_id == run_id.to_s
    return row if row.applied_ticks.include?(tick)

    row.update!(run_id: run_id.to_s, applied_ticks: row.applied_ticks + [ tick ],
                amount: (row.amount.to_f + amount.to_f).clamp(0.0, 1.0))
    row
  end

  # Called once per match START, beside the healing of wounds.
  def self.fade!(owner_id, content: ReactorSim::Content.default)
    owned_by(owner_id).find_each do |row|
      tags = content.minions.key?(row.holder_id.to_sym) ? content.sheet(row.holder_id).fetch(:tags) : {}
      kept = ReactorSim::Animosity.faded(row.amount, tags)
      kept < FORGOTTEN ? row.destroy! : row.update!(amount: kept)
    end
  end
end
