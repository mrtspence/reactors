# frozen_string_literal: true

# One operation's telemetry, streaming to whoever is watching it.
#
# Read-only by design. Commands go over HTTP and into the log, not down the cable — including
# the client's own resync request. That keeps every input on one ordered path, and it is why this
# channel has no `receive` and no actions.
#
# **Subscription is gated on `viewable_by?`**, which is the permission that widens when
# spectating lands; `operable_by?` is the one that will not. Everyone still gets the player view
# — `project(viewer: :spectator)` exists and is what a non-owner should receive, and choosing
# between them is stage E of `operator_identity.md`.
class OperationChannel < ApplicationCable::Channel
  def subscribed
    operation = Operation.locate(params[:match_id], params[:operation_id])
    return reject unless operation&.viewable_by?(DevPlayer::ID)

    stream_from StreamNames.operation(match_id: operation.match_id,
                                      operation_id: operation.operation_id)
    backfill
  end

  private

  # **What a joining client missed.** An incident carried only in a broadcast projection is lost
  # to anyone who was not connected for it, so a spectator joining one tick after the flywheel
  # burst would see "nothing has gone wrong yet" beside a wrecked engine.
  #
  # One query against the durable log, in the same shape the projection carries, so the client
  # has one renderer rather than two. Its own message kind rather than folded into a view: a view
  # is about *now*, and this is about what already happened.
  #
  # Failing here must not cost the subscription — a panel with no history beats no panel.
  def backfill
    run = MatchRun.for_match(params[:match_id]).newest_first.first
    return if run.nil?

    incidents = Incident.backfill(run.run_id)
    return if incidents.empty?

    # **Braces are load-bearing.** `transmit` takes one positional Hash plus a `via:` keyword,
    # so `transmit(kind: "backfill", …)` passes Ruby *keywords* and raises "wrong number of
    # arguments (given 0, expected 1)" — which the rescue below then swallowed, leaving the
    # backfill silently doing nothing. Found by a spec, not by running it.
    transmit({ kind: "backfill", run_id: run.run_id, incidents: incidents })
  rescue StandardError => e
    Rails.logger.error("channel: backfill failed: #{e.class}: #{e.message}")
  end
end
