# frozen_string_literal: true

# The ActionCable stream an operation's telemetry rides on.
#
# One definition shared by the runner (which broadcasts) and the channel (which subscribes),
# because a mismatch between them is silent: the runner publishes happily, the client
# subscribes happily, and nothing ever arrives.
module StreamNames
  module_function

  def operation(match_id:, operation_id:) = "operation:#{match_id}:#{operation_id}"
end
