# frozen_string_literal: true

# Send librdkafka's own logging through Rails' logger.
#
# This is the only Kafka setup that belongs in an initializer: it sets a class attribute and
# opens nothing. Building a producer or consumer here would open a broker connection — and
# spawn librdkafka's background polling thread — inside `assets:precompile`, `rails console`,
# `db:migrate` and the test suite. Clients are built lazily instead; see CommandProducer.
#
# Without this, librdkafka writes to $stdout from its own thread and interleaves mid-line with
# Rails' log.
require "rdkafka"

Rdkafka::Config.logger = Rails.logger
