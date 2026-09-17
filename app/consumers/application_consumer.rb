# frozen_string_literal: true

# What every egress consumer shares: decoding, and the rule that a bad record must never stop
# the stream.
#
# The same discipline `CommandConsumer#decode` follows at the other end of the system, and the
# same one `ReactorSim::Command.parse` follows inside it. A malformed payload is one lost fact;
# a consumer that raises on it is a crash loop that blocks every fact behind it, forever,
# because the offset never advances past the poison.
class ApplicationConsumer < Karafka::BaseConsumer
  private

  def decode(message)
    payload = message.payload
    return payload if payload.is_a?(Hash)

    Rails.logger.warn("events: ignoring non-object record at offset #{message.offset}")
    nil
  rescue StandardError => e
    Rails.logger.warn("events: undecodable record at offset #{message.offset}: #{e.message}")
    nil
  end
end
