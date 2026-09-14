# frozen_string_literal: true

class MatchesController < ApplicationController
  # **The loadout rides INSIDE the reset command, not merely referenced by it.**
  #
  # The runner could read the `loadouts` table itself — it has Rails booted. It must not: the
  # web process writes that row and then produces this command, so a runner reading the table
  # would be reading it at whatever moment the record happened to reach it, and a reset that
  # raced a save would rebuild the previous machine with no sign anything went wrong. Carried in
  # the payload, the command says exactly which machine it means, and it stays ordered against
  # the lever commands around it because it rides the same key on the same topic.
  #
  # The table is still what a cold runner boots from. It is just not what a reset consults.
  def self.reset_command
    stored = DevMatch.stored

    { "type" => "reset_match" }.tap do |command|
      next unless stored

      command["chassis"] = stored.chassis
      command["loadout"] = stored.parts
    end
  end

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

    CommandProducer.instance.produce(match_id: DevMatch::ID, command: MatchesController.reset_command)
    head :accepted
  rescue StandardError => e
    Rails.logger.error("matches: reset failed: #{e.class}: #{e.message}")
    head :service_unavailable
  end
end
