# frozen_string_literal: true

# Grudges formed in play, written down so they outlast the match.
#
# A third question about the stream beside the digest and the injury list: "who will hate whom
# next time". Standins are nobody in particular and are never written.
class GrudgeList
  def initialize(owner_id: DevPlayer::ID, logger: Rails.logger)
    @owner_id = owner_id.to_s
    @logger = logger
  end

  # Returns `[holder, target]` when a grudge was deepened.
  def call(record)
    return [] unless record["kind"] == "event" && record["type"] == "grudge_formed"

    detail = record["detail"] || {}
    holder = detail["holder"]
    target = detail["target"]
    return [] if holder.nil? || target.nil? || holder == target
    return [] if [ holder, target ].any? { |id| id.to_s == ReactorSim::Crew::STANDIN.to_s }

    Grudge.deepen!(owner_id: @owner_id, holder_id: holder, target_id: target,
                   amount: detail["amount"], run_id: record.fetch("run_id"), tick: record["tick"])
    [ holder.to_s, target.to_s ]
  rescue StandardError => e
    # One bad record must not stop the stream; see `InjuryList`.
    @logger.error("grudges: skipped #{holder} → #{target}: #{e.class}: #{e.message}")
    []
  end
end
