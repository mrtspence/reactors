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

  def self.build(logger: Rails.logger, source: nil, sink: nil)
    new(matches: { DevMatch::ID => DevMatch.build }, logger: logger,
        source: source || CommandConsumer.build(logger: logger),
        sink: sink || ViewBroadcaster.new(logger: logger))
  end

  def initialize(matches:, logger:, source: nil, sink: nil)
    @matches = matches
    @logger = logger
    # Injected so the loop can be exercised without a broker or a database. Both arrive in
    # later steps; until then commands come from nowhere and views go nowhere.
    @source = source
    @sink = sink
    @stopping = false
    @inboxes = Hash.new { |h, k| h[k] = [] }
    @applied = 0
  end

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
      @matches.each_value { |match| advance(match) }
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

  def advance(match)
    pending = @inboxes.delete(match.id) || []
    commands, local = pending.partition { |c| SIM_TYPES.include?(c["type"]) }

    local.each { |command| handle_local(match, command) }
    apply(match, commands)

    # Events also reach a client inside the projection's `incidents`, so nothing is lost by
    # not publishing them separately yet.
    # TODO: these belong on `match.events` as the durable record. Today they exist only in
    # whatever projection happens to be broadcast, so a spectator who joins a tick later never
    # learns the flywheel burst.
    match.step!
    publish(match)
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

    match.operations.each { |operation| @sink.publish(match, operation) }
  end

  # Commands addressed to the runner rather than to the simulation. They ride the same log as
  # everything else so they stay ORDERED against the control commands — "reset, then open the
  # throttle" has to mean what it says.
  def handle_local(match, command)
    case command["type"]
    when "reset_match" then reset(match)
    when "resync"      then @sink&.publish(match, nil, full: true)
    else @logger.warn("runner: unknown command type #{command['type'].inspect}")
    end
  end

  # TODO: expedient — rebuilds the match in place from the same fixed seed, discarding
  # everything that happened. It exists so a tester can recover from a burst flywheel without
  # restarting the process. A proper implementation puts this on `match.lifecycle` with
  # created/started/ended semantics and archives the finished match's seed + command log
  # rather than throwing it away, since that pair IS the replay.
  def reset(match)
    @logger.info("runner: resetting #{match.id}")
    @matches[match.id] = DevMatch.build
    @sink&.reset(match.id)
  end

  # `lateness` is measured against the ABSOLUTE schedule, so it reports drift accumulated
  # since the loop started rather than the last tick's cost. A loop that sleeps a fixed
  # interval shows near-zero here while silently running slow; this one does not.
  def heartbeat(ticks, lateness)
    match = @matches.values.first
    telemetry = match&.telemetry(operation_id: DevMatch::OPERATION_ID) || {}
    controls = match&.operation(DevMatch::OPERATION_ID)&.state&.fetch(:controls) || {}

    @logger.info(
      "runner: tick #{ticks} drift #{(lateness * 1000).round(1)}ms applied #{@applied} " \
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
