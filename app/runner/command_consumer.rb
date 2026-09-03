# frozen_string_literal: true

# The runner's end of the command log.
#
# Non-blocking by construction: the tick loop calls `drain` at the barrier and must never wait
# on a broker. Anything that has arrived is taken; anything that has not will be there next
# tick, 250 ms later.
class CommandConsumer
  TOPIC = "match.commands"
  GROUP = "match-runners"

  # One tick's worth of commands. Far above anything a human can generate — it exists so a
  # backlog cannot make a single drain unbounded and blow the tick budget.
  MAX_PER_DRAIN = 500

  def self.build(logger: Rails.logger)
    consumer = default_config.consumer
    consumer.subscribe(TOPIC)
    new(consumer: consumer, logger: logger)
  end

  def self.default_config
    Rdkafka::Config.new(
      "bootstrap.servers": ENV.fetch("KAFKA_BROKERS", "localhost:19092"),
      "group.id": GROUP,
      "client.id": "reactor-runner",
      # TODO: expedient — auto-commit means a crash can lose up to 5 s of commands. Tolerable
      # only because commands are absolute: a lost `set_control` means one lever did not move
      # and the player moves it again. The real design commits offsets AFTER writing a snapshot
      # that embeds them, which is what makes recovery exact (docs/architecture.md §6).
      "enable.auto.commit": true,
      "auto.commit.interval.ms": 5_000,
      # Load-bearing. The dev match is rebuilt from a fixed seed at every boot, so `earliest`
      # would replay up to seven days of stale commands into a cold engine on every restart.
      # TODO: with snapshots this becomes `earliest` plus an explicit seek to the offset the
      # snapshot carries.
      "auto.offset.reset": "latest",
      # One string now, because the eager default stops the world on every rebalance — adding a
      # second runner would pause every live match. There are no rebalance callbacks to write
      # while there is one consumer, but the strategy has to be set before there are two.
      "partition.assignment.strategy": "cooperative-sticky",
      # The runner does simulation work between polls.
      "max.poll.interval.ms": 60_000,
      "enable.partition.eof": false
    )
  end

  def initialize(consumer:, logger:)
    @consumer = consumer
    @logger = logger
  end

  # Appends to `inboxes[match_id]`. Never blocks, never raises.
  def drain(inboxes)
    @consumer.poll_batch_nb(0, max_items: MAX_PER_DRAIN).each do |message|
      # poll_batch_nb returns errors INLINE in the same array as messages. Not filtering them
      # means calling #payload on an exception object.
      next @logger.warn("kafka: #{message}") if message.is_a?(Rdkafka::RdkafkaError)

      record = decode(message)
      inboxes[message.key] << record if record
    end
  rescue StandardError => e
    # The tick barrier must survive a sick broker. A drain that raises would take down every
    # match on this runner, so a failure here costs one tick's commands and nothing else.
    @logger.error("kafka: drain failed: #{e.class}: #{e.message}")
  end

  def close
    @consumer.close
  rescue StandardError => e
    @logger.warn("kafka: consumer close failed: #{e.class}: #{e.message}")
  end

  private

  # A malformed record in the log must never stop a match — the same rule Command.parse
  # already follows inside the simulation, applied one layer out.
  def decode(message)
    parsed = JSON.parse(message.payload)
    return parsed if parsed.is_a?(Hash)

    @logger.warn("kafka: ignoring non-object record at offset #{message.offset}")
    nil
  rescue JSON::ParserError => e
    @logger.warn("kafka: undecodable record at offset #{message.offset}: #{e.message}")
    nil
  end
end
