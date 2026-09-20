# frozen_string_literal: true

# **A machine in a match, and who it belongs to.**
#
# One player per operation is the rule; this row is where that stops being a comment. Before it,
# every controller answered "may you touch this" by comparing a path segment against
# `DevMatch::ID` — four copies of a rule with no owner, and the reason a second operation could
# not exist.
#
# > **Not `ReactorSim::Operation`.** That is the simulation's machine — nodes, links, state, a
# > tick. This is the delivery tier's *record* of one: an id, a kind and an owner, and nothing
# > about physics. `MatchRun` is the same division for a match. The sim must never learn that
# > ownership exists (`app/CLAUDE.md`), so nothing here is ever handed to it.
#
# See docs/design_sketches/operator_identity.md §2.
class Operation < ApplicationRecord
  validates :match_id, :operation_id, :kind, :owner_id, presence: true
  validates :operation_id, uniqueness: { scope: :match_id }

  scope :in_match, ->(match_id) { where(match_id: match_id.to_s).order(:operation_id) }
  scope :owned_by, ->(owner_id) { where(owner_id: owner_id.to_s) }

  # What a request is addressing, or nil. **Nil is an answer**, not an error: an operation that
  # does not exist and one you may not see have to be indistinguishable from outside, and that
  # is easier to keep true when the lookup simply returns nothing.
  def self.locate(match_id, operation_id)
    return nil if match_id.blank? || operation_id.blank?

    find_by(match_id: match_id.to_s, operation_id: operation_id.to_s)
  end

  # Idempotent, so a seed or a rake task can call it as often as it likes. **Never touches
  # `owner_id` on an existing row** — fitting parts, posting a crew and resetting a match must
  # not be able to transfer a machine, which is the whole reason ownership is not a column on
  # `loadouts`.
  def self.provision(match_id:, operation_id:, kind:, owner_id:)
    record = find_or_initialize_by(match_id: match_id.to_s, operation_id: operation_id.to_s)
    record.kind = kind.to_s
    record.owner_id ||= owner_id.to_s
    record.save!
    record
  end

  # --- the two permissions ------------------------------------------------------------
  #
  # **Written as two from the start, because they diverge the moment spectators exist.** Today
  # they give the same answer. A single `authorised?` would have to be split at exactly the
  # point where a live feature depended on what it currently meant — and the projection already
  # distinguishes them (`project(viewer: :player)` against `:spectator`), so `viewable_by?` is
  # what will choose between those.

  # May this player pull a lever here.
  def operable_by?(candidate)
    return true if Operator.bypass?

    owner_id == candidate.to_s
  end

  # May this player watch the dials. Identical to `operable_by?` until spectating lands, at which
  # point this widens and the other does not.
  def viewable_by?(candidate) = operable_by?(candidate)

  # For `Match.create(operations: [...])`. The sim takes a symbol for both.
  def to_spec = { id: operation_id.to_sym, type: kind.to_sym }
end
