# frozen_string_literal: true

class MatchesController < ApplicationController
  # Rebuild the match from cold.
  #
  # This goes through `match.commands` rather than reaching for the runner directly, because
  # the runner is a different process and this is the only channel between them that already
  # exists. It also means a reset is ORDERED against the control commands around it — "reset,
  # then open the throttle" does what it says, which a side channel could not promise.
  #
  # TODO: expedient — belongs on `match.lifecycle` with created/started/ended semantics, and a
  # reset should archive the finished match's seed + command log rather than discarding it,
  # since that pair *is* the replay (docs/architecture.md §8).
  def reset
    return head :not_found unless params[:match_id] == DevMatch::ID

    CommandProducer.instance.produce(match_id: DevMatch::ID, command: { "type" => "reset_match" })
    head :accepted
  rescue StandardError => e
    Rails.logger.error("matches: reset failed: #{e.class}: #{e.message}")
    head :service_unavailable
  end
end
