# frozen_string_literal: true

# Player intent, on its way to the log.
#
# Every command is keyed by `match_id`, which is what puts a match's whole command stream on
# one partition and therefore in order. It is also what will make partition assignment *be*
# match ownership once there is more than one runner (docs/architecture.md §6).
class CommandProducer
  TOPIC = "match.commands"

  class << self
    # Memoised per PROCESS, not per class.
    #
    # rdkafka is an FFI client with a background polling thread, and its handles are NOT
    # fork-safe: one created before Puma forks is inherited broken, and the failure mode is
    # silent — `produce` returns a delivery handle that never delivers. `config/puma.rb` has no
    # `workers` line today so this is latent, but setting WEB_CONCURRENCY would make it real
    # with no code change, and it would present as "commands vanish sometimes".
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

  def initialize(config: nil)
    @producer = (config || self.class.default_config).producer
  end

  def self.default_config
    Rdkafka::Config.new(
      "bootstrap.servers": ENV.fetch("KAFKA_BROKERS", "localhost:19092"),
      "client.id": "reactor-web",
      # Idempotence implies acks=all and bounded in-flight requests; acks is stated anyway
      # because the intent is worth reading at the call site rather than inferring.
      acks: "all",
      "enable.idempotence": true,
      # The 5 ms default batches for throughput. That is the wrong trade inside a 250 ms
      # control loop, where the tick barrier already dominates the latency budget.
      "linger.ms": 0,
      # Bound it. A broker outage must fail the send, not hang a Puma thread holding a request.
      "message.timeout.ms": 5_000,
      "socket.keepalive.enable": true
    )
  end

  # Fire and forget, deliberately.
  #
  # Waiting on the delivery handle would turn a 202 into a broker round trip inside the request
  # cycle, which is the whole thing the 202 exists to avoid.
  #
  # TODO: expedient — a delivery failure is therefore invisible here; 202 means "accepted from
  # you", not "written". A proper implementation sets a delivery callback and either surfaces
  # the failure or accepts the loss explicitly. Accepting it is defensible: commands are
  # absolute, so a lost one is corrected by the next move of the same lever — but that should
  # be a decision, not an accident.
  # Returns nothing meaningful on purpose: this is a command, not a query, and there is no
  # honest success value to hand back without waiting on the delivery handle.
  def produce(match_id:, command:)
    @producer.produce(topic: TOPIC, key: match_id.to_s, payload: JSON.generate(command))
    nil
  end

  def close
    # `close` blocks until outstanding deliveries settle or time out. Safe here because this is
    # only ever called from ordinary code, never from a signal handler.
    @producer.close
  end
end
