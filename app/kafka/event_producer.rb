# frozen_string_literal: true

# The durable record, on its way to the log.
#
# The counterpart to `ViewBroadcaster`: that publishes the *cache* — a projection delta a client
# draws, which self-heals if dropped — and this publishes the *truth*, which does not. The two
# are not in tension because the engine owns all state: they are a broadcast and a record of one
# already-decided fact, not two parties negotiating.
#
# Keyed by `match_id`, like commands, which puts a match's whole stream on one partition and
# therefore **in tick order**. That is load-bearing: an achievement about an interval is a fold
# over the stream, and a fold that sees the closing transition before the opening one is wrong.
#
# See `docs/design_sketches/event_system.md`.
class EventProducer
  TOPIC = "match.events"

  # The ledger, sampled. Ten seconds of wall clock at 4 Hz — deliberately the same period as
  # `ViewBroadcaster::FULL_VIEW_TICKS` and `MatchRunner::HEARTBEAT_TICKS`, so everything
  # periodic in this system fires on the same beat and there is one number to reason about.
  METER_TICKS = 40

  class << self
    # Memoised per PROCESS, not per class — rdkafka handles are NOT fork-safe and the failure
    # is silent, exactly as `CommandProducer` documents. The runner does not fork today, so
    # this is a copied convention rather than a live hazard; it costs nothing and the day
    # something does fork, it is already right.
    def instance
      @instance = nil if @pid != Process.pid
      @pid = Process.pid
      @instance ||= new
    end

    def reset!
      @instance&.close
      @instance = nil
    end
  end

  def initialize(config: nil, logger: Rails.logger)
    @producer = (config || self.class.default_config).producer
    @logger = logger
    @failed = 0
    @sent = 0
    install_delivery_callback
  end

  def self.default_config
    Rdkafka::Config.new(
      "bootstrap.servers": ENV.fetch("KAFKA_BROKERS", "localhost:19092"),
      "client.id": "reactor-runner-events",
      acks: "all",
      # Redelivery is harmless here without this — every record carries a deterministic
      # identity a consumer dedupes on (see `#fact`) — but idempotence costs nothing and
      # removes the duplicates at the source rather than at every consumer.
      "enable.idempotence": true,
      # Same reasoning as the command path: the 5 ms default batches for throughput, which is
      # the wrong trade inside a 250 ms control loop.
      "linger.ms": 0,
      # Bound it. A broker outage must fail the send, never hold the tick loop.
      "message.timeout.ms": 5_000,
      "socket.keepalive.enable": true
    )
  end

  # **Fire and forget: nothing may block the tick loop, ever.** A lost `part_failed` is a
  # permanent fact about a match that nothing can reconstruct, so the pull toward waiting on the
  # delivery handle is strong — and must be refused. The loop stays cheap enough that a
  # four-player match of much larger machines needs no thought, and a sick broker degrades the
  # record rather than the simulation.
  #
  # Durability improves by making this producer better (idempotence, acks=all, a callback that
  # counts what was lost), never by making the loop wait.
  def publish(match, events, run_id:)
    events.each_with_index do |event, seq|
      produce(match.id, fact(match, event, seq, run_id))
    end
    nil
  rescue StandardError => e
    # The same rule `ViewBroadcaster` follows: telemetry must never be able to stop a match,
    # and neither may the record of one.
    @logger.error("events: publish failed: #{e.class}: #{e.message}")
    nil
  end

  # The ledger as it stands, ABSOLUTE rather than a delta — the trick that makes commands
  # idempotent, applied in the other direction. A duplicate reading writes the same value and a
  # lost one costs nothing, because the next carries the whole total; a consumer's write is
  # `greatest(total, reading)`, which needs no dedup table, tolerates reordering, and loses at
  # most one interval to a crash. Two readings also give **power**, which no event could.
  #
  # **The interval is the loop's to enforce, not this object's.** `METER_TICKS` is declared here
  # because it is a property of the record, but `MatchRunner` decides which ticks sample —
  # beside the heartbeat, which is the same kind of decision. Gating here hides the cadence from
  # anything standing in for this class, and a fake that cannot be wrong about timing tests
  # nothing about it.
  def publish_meters(match, tick, run_id:)
    match.operations.each do |operation|
      produce(match.id,
              envelope(match, run_id).merge(kind: "meter", operation_id: operation.id,
                                            tick: tick, ledger: operation.ledger))
    end
    nil
  rescue StandardError => e
    @logger.error("events: meter failed: #{e.class}: #{e.message}")
    nil
  end

  def stats = { sent: @sent, failed: @failed }

  def close
    # Blocks until outstanding deliveries settle or time out. Only ever called from the
    # runner's `ensure`, on the main thread, never from a signal handler.
    @producer.close
  rescue StandardError => e
    @logger.warn("events: producer close failed: #{e.class}: #{e.message}")
  end

  private

  def produce(match_id, record)
    @producer.produce(topic: TOPIC, key: match_id.to_s, payload: JSON.generate(record))
    @sent += 1
  end

  # **The identity that makes at-least-once delivery harmless.** `(match_id, run_id,
  # operation_id, tick, seq)` is deterministic because the simulation is: replaying a tick from a
  # snapshot emits the same events in the same order, so a consumer recognises a redelivered
  # record rather than double-counting it.
  #
  # `run_id` is not optional. `Match.create` starts at `tick: 0` and `MatchRunner#reset` rebuilds
  # in place under the same `match_id`, so without it two different runs both claim tick 412 and
  # any fold over the stream is corrupted the first time a tester recovers from a burst flywheel.
  def fact(match, event, seq, run_id)
    envelope(match, run_id).merge(kind: "event", seq: seq, **event)
  end

  def envelope(match, run_id)
    { match_id: match.id, run_id: run_id }
  end

  # Logged and counted rather than retried: a retry queue inside the runner would be the first
  # thing to grow a blocking wait, and the count reaching the heartbeat is enough to know the
  # record is lossy.
  #
  # **`report.error` is an error CODE, and 0 means success** — a freshly constructed
  # `DeliveryReport` has it nil, so both must count as delivered. Treating 0 as a failure makes
  # the heartbeat cry wolf permanently, and a real loss is then invisible in the noise.
  def install_delivery_callback
    @producer.delivery_callback = lambda { |report|
      code = report.error
      next if code.nil? || code == 0

      @failed += 1
      @logger.error("events: delivery failed: #{code}")
    }
  end
end
