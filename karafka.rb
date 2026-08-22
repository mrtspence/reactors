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
      "bootstrap.servers": ENV.fetch("KAFKA_BROKERS", "localhost:19092")
    }
    config.client_id = "reactor"
    # Reloading consumers between messages in development means code changes are
    # picked up without a restart; in production they are long-lived.
    config.consumer_persistence = !Rails.env.development?
  end

  routes.draw do
    # Egress consumers are added here as they are built. The first will be the
    # persistence consumer that writes progression and archives the seed + command log
    # for replay at end of match.
  end
end
