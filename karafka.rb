# frozen_string_literal: true

# Karafka boot file.
#
# Karafka drives the EGRESS consumers only — persistence, archival, analytics — which
# are genuinely message-driven. The match runner does not appear here: it needs a
# non-blocking poll inside its own tick loop and manual offset commits at the tick
# barrier, so it uses rdkafka directly. See docs/architecture.md §6.

ENV["RAILS_ENV"] ||= "development"
require ::File.expand_path("config/environment", __dir__)

Rails.application.eager_load!

class KarafkaApp < Karafka::App
  setup do |config|
    config.kafka = {
      "bootstrap.servers": ENV.fetch("KAFKA_BROKERS", "localhost:19092"),
      # **`earliest`, and the opposite choice on the command topic is not an inconsistency.**
      #
      # `CommandConsumer` sets `latest` because a command is an *instruction*, and replaying
      # seven days of stale instructions into a cold engine on every restart would be actively
      # wrong. An event is a *record of something that already happened*: replaying it is
      # harmless, because every write downstream is idempotent — incidents upsert on
      # `(run_id, operation_id, tick, seq)`, awards on `(owner_id, achievement_id)`, and meters
      # are absolute.
      #
      # With `latest` a consumer that was down for an hour would silently skip that hour, which
      # is data loss in the one part of the system whose entire purpose is not losing things.
      "auto.offset.reset": "earliest"
    }
    config.client_id = "reactor"
    # Reloading consumers between messages in development means code changes are
    # picked up without a restart; in production they are long-lived.
    config.consumer_persistence = !Rails.env.development?
  end

  routes.draw do
    # **Two groups on one topic, not one group doing two jobs.** That fan-out is the reason
    # `match.events` is a topic at all rather than a direct write from the runner: each group
    # keeps its own offsets and its own lag, so one can be restarted, rewound or replayed
    # without touching the other — and a bug in progression does not stop a player watching
    # their boiler explode. See docs/design_sketches/event_system.md §8.
    consumer_group :progression do
      topic EventProducer::TOPIC do
        consumer ProgressionConsumer
      end
    end

    consumer_group :incidents do
      topic EventProducer::TOPIC do
        consumer IncidentConsumer
      end
    end
  end
end
