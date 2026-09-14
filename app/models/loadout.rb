# frozen_string_literal: true

# Which parts a machine is built from, durably.
#
# **This is not the authority during a match.** The runner is handed a loadout inside the reset
# command that rebuilds the match, so it never reads this table at a moment when the web process
# might have just written it. What this row is for is the two things Kafka cannot do: survive a
# runner restart, and let the outfitting screen show what is currently fitted before anything has
# been sent anywhere.
#
# See `docs/design_sketches/modular_components.md` §8 for the two alternatives this was chosen
# over — the runner publishing its panel on a compacted topic (right long-term, too much
# machinery for a dev harness) and no persistence at all (cannot survive the restart).
class Loadout < ApplicationRecord
  validates :match_id, :operation_id, :chassis, presence: true
  validates :operation_id, uniqueness: { scope: :match_id }

  # **Symbols on the way out, and this is the fourth time this trap has been paid for.**
  # `parts` is jsonb, so it comes back with String keys AND String values, and a part id that
  # stays a String misses every `Parts.fetch`. That is not a nil — it is a different machine,
  # assembled in silence, and no digest can see the difference because JSON makes `:x` and `"x"`
  # the same thing. `Assembly` symbolises defensively too; this is the other end of the same
  # pipe. See `lib/reactor_sim/CLAUDE.md`.
  #
  # A null value means a slot left deliberately empty, and it has to survive as a null: dropping
  # it would let the slot fall back to its default and grow the part back.
  def to_sim
    parts.to_h { |slot_id, part_id| [ slot_id.to_sym, part_id&.to_sym ] }
  end

  def chassis_sym = chassis.to_sym

  # Upsert rather than create-or-update, because the outfitting form is idempotent by
  # construction — it submits the whole loadout every time, exactly as a command does.
  def self.fit(match_id:, operation_id:, chassis:, parts:)
    record = find_or_initialize_by(match_id: match_id.to_s, operation_id: operation_id.to_s)
    record.chassis = chassis.to_s
    # Stringified going in so a round trip through jsonb cannot change the shape of the hash
    # between "just saved" and "reloaded" — which would make a subtle bug appear only after a
    # restart.
    record.parts = parts.to_h { |slot_id, part_id| [ slot_id.to_s, part_id&.to_s ] }
    record.save!
    record
  end
end
