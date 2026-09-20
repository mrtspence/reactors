# frozen_string_literal: true

# Mortal injuries, written down.
#
# Kept apart from `ProgressionDigest` because it is a different question about the same stream:
# the digest asks "what has this player achieved", and this asks "who can they field next time".
# Folding them together would make one object that has to be reasoned about twice.
#
# **Only `:mortal` reaches here.** Minor and severe are match state and die with the match — a
# scratch and a bad shift do not follow somebody into next week — and the simulation says which
# is which on the event itself rather than leaving this side to keep a second copy of the ladder.
class InjuryList
  def initialize(owner_id: DevPlayer::ID, logger: Rails.logger)
    @owner_id = owner_id.to_s
    @logger = logger
  end

  # Returns the minion ids taken off the board by this record, which is what a caller would
  # announce.
  def call(record)
    return [] unless record["kind"] == "event" && record["type"] == "minion_hurt"

    detail = record["detail"] || {}
    # **Read from the event rather than re-derived.** The engine owns the ladder and says on the
    # record whether this one lasts; a second copy of that rule here would be one more thing to
    # keep in step, and it would fail silently in the direction of losing people forever.
    return [] unless detail["lasting"]

    minion_id = detail["minion"] or return []
    # The standin cannot be put on the injury list. There is an inexhaustible supply and the
    # whole point of a last resort is that it is always there — a row for one would take the
    # floor out from under every future match.
    return [] if minion_id.to_s == ReactorSim::Crew::STANDIN.to_s

    lay_off(minion_id, record)
  end

  private

  def lay_off(minion_id, record)
    condition = MinionCondition.record!(
      owner_id: @owner_id, minion_id: minion_id, run_id: record.fetch("run_id"),
      cause: record["label"] || record["node"]
    )
    @logger.info("injuries: #{minion_id} out for #{condition.matches_remaining} match(es)")
    [ minion_id.to_s ]
  rescue StandardError => e
    # One bad record must not stop the stream: the log is at-least-once and ordered, and a crash
    # loop on a single payload blocks every fact behind it forever.
    @logger.error("injuries: skipped #{minion_id}: #{e.class}: #{e.message}")
    []
  end
end
