# frozen_string_literal: true

# Wounds, written down so they outlast the match.
#
# Kept apart from `ProgressionDigest` because it is a different question about the same stream:
# the digest asks "what has this player achieved", and this asks "who can they field next time,
# and how hurt are they". Every wound a harm left is on its event (`detail["wounds"]`), with its
# place among the person's wounds, so this keeps no second copy of the ladder.
class WoundList
  def initialize(owner_id: DevPlayer::ID, logger: Rails.logger)
    @owner_id = owner_id.to_s
    @logger = logger
  end

  # Returns the minion ids whose wounds this record wrote.
  def call(record)
    return [] unless record["kind"] == "event" && record["type"] == "minion_hurt"

    detail = record["detail"] || {}
    minion_id = detail["minion"] or return []
    wounds = Array(detail["wounds"])
    return [] if wounds.empty?
    # The standin carries nothing between matches: there is an inexhaustible supply, and the
    # whole point of a last resort is that it is always there.
    return [] if minion_id.to_s == ReactorSim::Crew::STANDIN.to_s

    wounds.each do |wound|
      Wound.record!(owner_id: @owner_id, minion_id: minion_id, run_id: record.fetch("run_id"), wound: wound)
    end
    [ minion_id.to_s ]
  rescue StandardError => e
    # One bad record must not stop the stream: the log is at-least-once and ordered, and a crash
    # loop on a single payload blocks every fact behind it forever.
    @logger.error("wounds: skipped #{minion_id}: #{e.class}: #{e.message}")
    []
  end
end
