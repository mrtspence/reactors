# frozen_string_literal: true

# A wound one of a player's people is still carrying from an earlier match.
#
# Taken in play (`minion_hurt`, each wound in its `detail`), handed back to the simulation at build
# through `options:`, and healed a little each match start (`ReactorSim::Wounds.heal`, faster for
# `regeneration`, slower for `slow_healer`). **Somebody is unavailable while any of their wounds
# would carry them out**, so how long they are out is how long that takes to heal — deterministic,
# and readable as "back in two matches". The standin carries nothing.
class Wound < ApplicationRecord
  validates :owner_id, :minion_id, :kind, :run_id, presence: true
  validates :slot, uniqueness: { scope: %i[owner_id minion_id run_id] }
  validates :depth, numericality: { greater_than_or_equal_to: 0.0 }

  scope :owned_by, ->(owner_id) { where(owner_id: owner_id.to_s) }

  # A wound this deep or deeper stands somebody down.
  OUT = ReactorSim::Wounds::BANDS.fetch(:severe)

  # `{ person => [{ kind:, depth:, variant:, cause:, ref: }] }`, as the simulation takes it.
  def self.carried_for(owner_id)
    owned_by(owner_id).order(:id).each_with_object({}) do |row, acc|
      (acc[row.minion_id] ||= []) << { "kind" => row.kind, "depth" => row.depth, "variant" => row.variant,
                                       "cause" => row.cause, "ref" => row.id }.compact
    end
  end

  # **Idempotent, because the event that reports it is at-least-once**, and absolute: a wound is
  # written at the depth the simulation reports, so a replay changes nothing and a wound that
  # deepens is the same row. `ref` is a wound carried in from an earlier match, by its own row.
  def self.record!(owner_id:, minion_id:, run_id:, wound:)
    row = row_for(owner_id, minion_id, run_id, wound) or return nil

    row.update!(kind: wound.fetch("kind").to_s, depth: wound.fetch("depth").to_f,
                variant: wound.fetch("variant").to_i, cause: wound["cause"]&.to_s)
    row
  end

  def self.row_for(owner_id, minion_id, run_id, wound)
    return owned_by(owner_id).find_by(id: wound["ref"]) if wound["ref"]

    find_or_initialize_by(owner_id: owner_id.to_s, minion_id: minion_id.to_s, run_id: run_id.to_s,
                          slot: wound.fetch("slot"))
  end

  # Called once per match START. Healed past the first band, a wound is gone.
  def self.heal!(owner_id, content: ReactorSim::Content.default)
    owned_by(owner_id).find_each do |row|
      left = ReactorSim::Wounds.heal(row.depth, tags_of(row.minion_id, content))
      ReactorSim::Wounds.tier(left) ? row.update!(depth: left) : row.destroy!
    end
  end

  # `{ minion_id => matches until they can be fielded }`, for everybody who cannot be yet. One
  # query, then lookups — the roster screen asks about every candidate in every role.
  def self.remaining_for(owner_id, content: ReactorSim::Content.default)
    owned_by(owner_id).where(depth: OUT..).group_by(&:minion_id).to_h do |minion_id, rows|
      tags = tags_of(minion_id, content)
      [ minion_id, rows.map { |row| matches_to_heal(row.depth, tags) }.max ]
    end
  end

  def self.available?(owner_id, minion_id) = !remaining_for(owner_id).key?(minion_id.to_s)

  def self.matches_to_heal(depth, tags)
    matches = 0
    while depth >= OUT
      depth = ReactorSim::Wounds.heal(depth, tags)
      matches += 1
    end
    matches
  end

  def self.tags_of(minion_id, content)
    content.minions.key?(minion_id.to_sym) ? content.sheet(minion_id).fetch(:tags) : {}
  end
end
