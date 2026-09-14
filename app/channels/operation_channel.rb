# frozen_string_literal: true

# One operation's telemetry, streaming to whoever is watching it.
#
# Read-only by design. Commands go over HTTP to `/matches/:id/commands` and into the log, not
# down the cable — including the client's own resync request. That keeps every input on one
# ordered path, and it is why this channel has no `receive` and no actions.
class OperationChannel < ApplicationCable::Channel
  def subscribed
    # TODO: expedient — anyone may watch anything, and everyone gets the player view. A proper
    # implementation checks that this player is in this match and streams the spectator
    # projection to everyone else (`project(viewer: :spectator)` already exists for it).
    return reject unless params[:match_id] == DevMatch::ID

    stream_from StreamNames.operation(match_id: params[:match_id],
                                      operation_id: params[:operation_id])
  end
end
