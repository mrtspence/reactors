# frozen_string_literal: true

# The tick loop. One process, owning match state in memory, advancing it at a fixed 4 Hz.
#
# This is deliberately NOT a job: a self-enqueueing TickJob would inherit Solid Queue's ~1 s
# polling jitter, and a retry would produce a double tick — silent state corruption. A job
# queue is for work that must happen, not work that must happen on a schedule
# (docs/architecture.md §4).
class MatchRunner
  # Commands the simulation understands. Anything else is ours to interpret before the barrier
  # — see #handle_local.
  SIM_TYPES = [ ReactorSim::Command::SET_CONTROL, ReactorSim::Command::ASSIGN_MINION ].freeze

  # Every 10 s at 4 Hz. Reports the drift between where the clock says we are and where the
  # tick count says we should be, which is the one number that tells you the loop is healthy.
  HEARTBEAT_TICKS = 40

  def self.build(logger: Rails.logger, source: nil, sink: nil, events: nil)
    new(matches: { DevMatch::ID => DevMatch.build }, logger: logger,
        source: source || CommandConsumer.build(logger: logger),
        sink: sink || ViewBroadcaster.new(logger: logger),
        events: events || EventProducer.instance)
  end

  def initialize(matches:, logger:, source: nil, sink: nil, events: nil)
    @matches = matches
    @logger = logger
    # Injected so the loop can be exercised without a broker or a database. Both arrive in
    # later steps; until then commands come from nowhere and views go nowhere.
    @source = source
    @sink = sink
    @events = events
    @stopping = false
    @inboxes = Hash.new { |h, k| h[k] = [] }
    @applied = 0
    # **One id per BUILD of a match, not per match**, and it is what keeps the durable log
    # honest. `Match.create` starts at `tick: 0` and `#reset` rebuilds in place under the same
    # `match_id`, so `(match_id, tick)` names two different moments in two different runs —
    # and a consumer folding that stream corrupts itself the first time a tester recovers from
    # a burst flywheel. Assigned HERE because the simulation may not have a clock; this is
    # also the identifier `match.lifecycle` will carry when matches are created on demand.
    @run_ids = @matches.keys.to_h { |id| [ id, new_run_id ] }
    # The run each current run replaced, for as long as it is the current one. A client watching
    # the old run needs to be told this one is its successor rather than a stranger.
    @superseded = {}
  end

  # Time-ordered, so a listing of runs sorts chronologically without a join.
  def new_run_id = SecureRandom.uuid_v7

  # Signal handlers may only set this flag. Closing an rdkafka handle from inside a trap
  # deadlocks — it is an FFI client with a background polling thread — so every teardown
  # happens in the ensure below, on the main thread, after the loop has exited.
  def stop = @stopping = true

  def run
    install_signal_handlers
    @logger.info("runner: #{@matches.keys.join(', ')} at #{hz} Hz, time_scale #{DevMatch.time_scale}")

    start = monotonic
    ticks = 0

    until @stopping
      # An ABSOLUTE deadline measured from start, never `sleep(DT)`. Sleeping a fixed interval
      # adds every scheduling delay to a running total that can only grow; this one absorbs
      # them, so a slow tick is repaid by the next rather than shifting the clock forever.
      deadline = start + ((ticks += 1) * ReactorSim::DT)

      # Lateness is measured HERE, at the top of the tick, against when this tick was due to
      # begin. Measuring after the work but before the sleep would report the idle time
      # instead — always about −DT, and identically so whether the loop is healthy or slowly
      # falling behind, which is the one thing it exists to distinguish.
      lateness = monotonic - (deadline - ReactorSim::DT)

      drain
      @matches.each_key { |match_id| advance(match_id) }
      heartbeat(ticks, lateness) if (ticks % HEARTBEAT_TICKS).zero?
      sleep_until(deadline)
    end

    @logger.info("runner: stopped after #{ticks} ticks")
  ensure
    shutdown
  end

  private

  def hz = (1.0 / ReactorSim::DT).round

  def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # The tick barrier. Commands are collected here, applied together, and only then stepped —
  # so a command either lands before this tick or after it, never during one.
  def drain
    return unless @source

    @source.drain(@inboxes)
  end

  def advance(match_id)
    match = @matches.fetch(match_id)
    pending = @inboxes.delete(match_id) || []
    commands, local = pending.partition { |c| SIM_TYPES.include?(c["type"]) }

    local.each { |command| handle_local(match, command) }
    # A reset swapped in a new Match, and the rest of this tick belongs to it — that is what
    # makes "reset, then open the throttle" mean what it says. Holding the object from before
    # the barrier steps and publishes the match that was just discarded.
    match = @matches.fetch(match_id)
    apply(match, commands)

    # **The dual write** (docs/architecture.md §7): the record, then the cache. Order matters
    # only in one direction — the projection self-heals if it is dropped and the log does not —
    # but neither may wait on the other, and neither may wait on a broker.
    #
    # The projection carries a *curated* subset of these under `incidents` (warnings and
    # criticals only, see `Operation#incidents`); the log gets everything, including the
    # ordinary transitions an achievement is folded from.
    record(match, match.step!)
    publish(match)
  end

  # Both halves of the durable record: the facts this tick produced, and — every
  # `METER_TICKS` — the ledger as an absolute reading.
  #
  # > When snapshots land, they go AFTER this and the command-offset commit goes after them.
  # > `Operation#to_h` deliberately drops `:events` because they are output rather than state,
  # > so a snapshot taken first would make that tick's events unrecoverable. A crash between
  # > the two replays the tick and re-emits them, which is harmless: same `run_id`, same tick,
  # > same `seq`, so a consumer recognises them. See the sketch, §7.
  def record(match, events)
    return unless @events

    run_id = @run_ids[match.id] ||= new_run_id
    @events.publish(match, events, run_id: run_id) if events.any?
    return unless (match.tick % EventProducer::METER_TICKS).zero?

    @events.publish_meters(match, match.tick, run_id: run_id)
  end

  def apply(match, commands)
    return if commands.empty?

    result = match.apply(commands)
    @applied += result[:applied]
    # Applied commands are counted rather than logged one by one: a slider drag produces ~10 a
    # second and would bury everything else. A rejection is rare and always worth seeing.
    return if result[:rejected].empty?

    @logger.warn("runner: #{result[:applied]} applied, " \
                 "#{result[:rejected].size} rejected: #{result[:rejected].map(&:to_h)}")
  rescue StandardError => e
    # Belt and braces. Command.parse and Match#apply are both written not to raise on bad
    # input, and a spec holds them to it — but this loop is the only thing keeping every match
    # on this runner alive, and it must not die for one bad record.
    @logger.error("runner: apply failed, dropping #{commands.size} command(s): #{e.class}: #{e.message}")
  end

  def publish(match)
    return unless @sink

    match.operations.each { |operation| @sink.publish(match, operation, **run_stamp(match)) }
  end

  # Which build of this match the values describe. Every projection carries it.
  def run_stamp(match)
    { run_id: @run_ids[match.id], supersedes: @superseded[match.id] }
  end

  # Commands addressed to the runner rather than to the simulation. They ride the same log as
  # everything else so they stay ORDERED against the control commands — "reset, then open the
  # throttle" has to mean what it says.
  def handle_local(match, command)
    case command["type"]
    when "reset_match" then reset(match, command)
    when "resync"      then @sink&.publish(match, nil, full: true, **run_stamp(match))
    else @logger.warn("runner: unknown command type #{command['type'].inspect}")
    end
  end

  # **The loadout and crew come from the command, not from the database.** The web process writes
  # those rows and *then* produces this, so reading a table here would read it at whatever moment
  # the record happened to arrive, and a reset racing a save would rebuild the previous machine.
  # A command carrying neither — the plain "put it back how it was" reset — falls through to
  # whatever is stored.
  #
  # TODO: expedient — rebuilds the match in place from the same fixed seed, discarding everything
  # that happened, so a tester can recover from a burst flywheel without restarting the process.
  # A proper implementation puts this on `match.lifecycle` with created/started/ended semantics
  # and archives the finished match's seed + command log, since that pair IS the replay.
  def reset(match, command = {})
    # **Keyed by operation**, because a match holds several and a reset rebuilds all of them.
    # Symbolising and defaulting are `DevMatch#operation_spec`'s job, so this hands the payload
    # over as it arrived rather than becoming a second place the two can disagree.
    specs = command["operations"] || {}

    @logger.info("runner: resetting #{match.id} (#{specs.keys.join(', ')})")
    @matches[match.id] = DevMatch.build(specs: specs)
    # A new build is a new run, and the durable log has to say so. Ticks restart at zero, so
    # reusing the id would make the next run's events collide with this one's — and it also
    # tells a consumer to abandon any interval it had open, rather than closing it against a
    # transition from a machine that is not the same machine.
    #
    # Naming the run it replaces is what lets a watching client adopt this one immediately
    # instead of treating an unfamiliar run as a second runner shouting over the first.
    @superseded[match.id] = @run_ids[match.id]
    @run_ids[match.id] = new_run_id
    @sink&.reset(match.id)
  rescue ReactorSim::Error => e
    # A loadout that cannot assemble must not take the runner down with it. The controller
    # refuses invalid builds, so reaching here means something got past it — log loudly and
    # leave the running match alone rather than killing every match on this runner.
    @logger.error("runner: reset refused for #{match.id}: #{e.message}")
  end

  # `lateness` is measured against the ABSOLUTE schedule, so it reports drift accumulated
  # since the loop started rather than the last tick's cost. A loop that sleeps a fixed
  # interval shows near-zero here while silently running slow; this one does not.
  def heartbeat(ticks, lateness)
    # The first machine, named rather than stumbled into. A heartbeat reporting every operation
    # would be one line per machine per tick; this is a pulse, not a readout.
    match = @matches.values.first
    telemetry = match&.telemetry(operation_id: DevMatch::PRIMARY) || {}
    controls = match&.operation(DevMatch::PRIMARY)&.state&.fetch(:controls) || {}

    # `lost` is the count of event deliveries the broker did not accept. It is on the heartbeat
    # rather than raised because the tick loop may never wait on a delivery handle — so the
    # honest thing is to make the loss visible, not to pretend it cannot happen.
    lost = @events.respond_to?(:stats) ? @events.stats[:failed] : 0

    @logger.info(
      "runner: tick #{ticks} drift #{(lateness * 1000).round(1)}ms applied #{@applied} " \
      "#{"lost #{lost} events " if lost.positive?}" \
      "| boiler #{fmt_k(telemetry[:boiler])} #{fmt_kpa(telemetry[:boiler])} " \
      "firebox #{fmt_k(telemetry[:firebox])} " \
      "| #{controls.map { |id, s| "#{id}=#{s.fetch(:actual).round}" }.join(' ')}"
    )
  rescue StandardError => e
    # A heartbeat is diagnostics. It must never be the thing that stops the match.
    @logger.warn("runner: heartbeat failed: #{e.class}: #{e.message}")
  end

  def fmt_k(node) = node && node[:temperature_k] ? "#{node[:temperature_k].round(1)}K" : "-"
  def fmt_kpa(node) = node && node[:pressure_pa] ? "#{(node[:pressure_pa] / 1000).round(1)}kPa" : "-"

  def sleep_until(deadline)
    remaining = deadline - monotonic
    # TODO: a negative remaining means the tick overran and has silently borrowed from the
    # next one. A real runner counts overruns and either catches up or declares the match
    # degraded. Ignored here because the budget is enormous: the performance guard is 55 ms
    # for a hundred-node tick and a steam engine has twelve.
    sleep(remaining) if remaining.positive?
  end

  def install_signal_handlers
    %w[INT TERM].each { |signal| Signal.trap(signal) { stop } }
  end

  def shutdown
    @source&.close
    @sink&.close
  end
end
