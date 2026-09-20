# frozen_string_literal: true

# Projections out. The only thing that ever leaves the simulation.
#
# Raw state never reaches a browser: every value here has been through an instrument, which is
# what keeps ground truth inside the engine and lets the client be legitimately dumb
# (docs/reference/diagnostics.md).
class ViewBroadcaster
  # A full view every 10 s regardless of what changed. Three lines that make the protocol
  # self-healing with NO client cooperation at all — a stale tab, a bugged client, or a message
  # missed during a reconnect all recover on their own.
  FULL_VIEW_TICKS = 40

  def initialize(logger: Rails.logger)
    @logger = logger
    @previous = {}
    @last_sent_tick = {}
    @since_full = Hash.new(0)
  end

  # `operation` is nil when the runner wants a full view for every operation — a resync.
  #
  # `run_id` names the build of the match these values came from, and `supersedes` names the
  # build this one replaced. Both go on the wire so a client can tell one runner's views from
  # another's; see the envelope below.
  def publish(match, operation, full: false, run_id: nil, supersedes: nil)
    operations = operation ? [ operation ] : match.operations
    operations.each do |op|
      publish_one(match, op, full: full, run_id: run_id, supersedes: supersedes)
    end
  rescue StandardError => e
    # Telemetry must never be able to stop a match. A dropped view self-heals on the next tick,
    # and failing here would cost the simulation itself.
    @logger.error("broadcast: failed: #{e.class}: #{e.message}")
  end

  # A reset rebuilds the Match, so every client's accumulated view is now about a match that no
  # longer exists. Dropping our memory of what they last saw forces the next publish to be full.
  def reset(match_id)
    @previous.delete_if { |key, _| key.start_with?("#{match_id}:") }
    @last_sent_tick.delete_if { |key, _| key.start_with?("#{match_id}:") }
    @since_full.delete_if { |key, _| key.start_with?("#{match_id}:") }
  end

  def close = nil

  private

  def publish_one(match, operation, full:, run_id: nil, supersedes: nil)
    key = "#{match.id}:#{operation.id}"
    view = match.project(operation_id: operation.id)
    previous = @previous[key]

    send_full = full || previous.nil? || (@since_full[key] += 1) >= FULL_VIEW_TICKS

    # Skipping an unchanged tick is what the library's delta compression is FOR, and it is a
    # real saving: every broadcast is a Postgres INSERT through Solid Cable, and a cold or
    # steady engine changes nothing for long stretches.
    #
    # It only works because Filters::Noise holds its offset until the signal actually moves —
    # set `deadband: 0` on any gauge and this stops firing forever.
    return if !send_full && view.unchanged_from?(previous)

    ActionCable.server.broadcast(
      StreamNames.operation(match_id: match.id, operation_id: operation.id),
      payload(view, previous, key, full: send_full, run_id: run_id, supersedes: supersedes)
    )

    @previous[key] = view
    @last_sent_tick[key] = view.tick
    @since_full[key] = 0 if send_full
  end

  # An explicit envelope, rather than letting the client sniff which shape it got.
  #
  # A full view has seven keys and a delta has five, so sniffing would work today and would
  # break in silence the day PlayerView#to_h changes. One field decouples the wire format from
  # the library's struct.
  #
  # `prev_tick` is what the client compares against — NOT `tick - 1`. Because unchanged ticks
  # are skipped, gaps in the tick sequence are normal, and a client treating a gap as a lost
  # message would resync several times a minute for no reason.
  #
  # `run_id` is what makes a stream carrying two runners diagnosable. Nothing stops a second
  # `bin/match_runner` broadcasting here, and it holds its own match at its own tick with its own
  # levers, so tick alone cannot tell its views from the real one's. `supersedes` separates the
  # legitimate change of run — a reset — from a stranger.
  def payload(view, previous, key, full:, run_id: nil, supersedes: nil)
    { kind: full ? "full" : "delta",
      tick: view.tick,
      prev_tick: full ? nil : @last_sent_tick[key],
      run_id: run_id,
      supersedes: supersedes,
      view: full ? view.to_h : view.delta_from(previous) }
  end
end
