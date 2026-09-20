# frozen_string_literal: true

# `match.events` → the durable incident feed.
#
# Separate from progression on purpose: this one exists so a spectator who joins a tick after
# the flywheel burst can still be told about it, and it must keep working whether or not
# anything is being awarded.
#
# **Every severity is stored, not just the ones the panel shows.** The log is complete and the
# feed is curated — `ReactorSim::Operation#incidents` does the curating on the way to a client,
# and `Incident.backfill` applies the same shape on the way back out.
class IncidentConsumer < ApplicationConsumer
  def consume
    messages.each do |message|
      record = decode(message) or next
      next unless record["kind"] == "event"

      MatchRun.observe!(run_id: record.fetch("run_id"), match_id: record.fetch("match_id"))
      Incident.record!(record)
    end
  end
end
