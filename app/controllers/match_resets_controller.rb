# frozen_string_literal: true

# Rebuilding a match from cold.
#
# **A reset is a resource, not a verb on the match.** Asking for one is `create`; what it creates
# is a request that the runner tear the machine down and build it again. Naming it that way is
# what keeps this a standard action — see `app/CLAUDE.md`, "Controllers are routing, not logic".
#
# It goes through `match.commands` rather than reaching for the runner directly, because the
# runner is a different process and this is the only channel between them that already exists. It
# also means a reset is ORDERED against the control commands around it — "reset, then open the
# throttle" does what it says, which a side channel could not promise.
#
# TODO: expedient — belongs on `match.lifecycle` with created/started/ended semantics, and a reset
# should archive the finished match's seed + command log rather than discarding it, since that
# pair *is* the replay (docs/architecture.md §8).
class MatchResetsController < ApplicationController
  include DevMatchScoped

  before_action :require_dev_match

  def create
    CommandProducer.instance.produce(match_id: DevMatch::ID, command: DevMatch.reset_command)
    head :accepted
  rescue StandardError => e
    Rails.logger.error("match_resets: produce failed: #{e.class}: #{e.message}")
    head :service_unavailable
  end
end
