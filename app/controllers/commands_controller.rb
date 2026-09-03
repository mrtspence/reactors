# frozen_string_literal: true

# Player intent in. Validate, produce, 202 — the tick barrier decides the rest.
#
# TODO: expedient — NO AUTH, AT ALL. Anyone who can reach this endpoint can drive the engine,
# and anyone who can reach the broker bypasses it entirely. A proper implementation
# authenticates the player and authorises that they own this operation's control point
# (docs/architecture.md §7); the ingress path is the only place player identity matters.
class CommandsController < ApplicationController
  # A lever id, and nothing that could be mistaken for anything else.
  CONTROL_ID = /\A[a-z][a-z0-9_]{0,39}\z/

  # Coalescing on the client is what keeps this from ever firing (send-on-change, ~10/s), so
  # tripping it means something is wrong rather than someone is enthusiastic.
  #
  # NOTE: Rails 8 `rate_limit` uses Rails.cache, which is :memory_store in development — so the
  # limit is per Puma worker, not per application. Fine at WEB_CONCURRENCY=1.
  rate_limit to: 30, within: 1.second, by: -> { request.remote_ip },
             with: -> { head :too_many_requests }

  def create
    return head :not_found unless params[:match_id] == DevMatch::ID

    command = build_command
    return head :unprocessable_content unless command

    CommandProducer.instance.produce(match_id: DevMatch::ID, command: command)
    head :accepted
  rescue StandardError => e
    # The broker being unreachable is a 503, not a 500 — the request was fine, we could not
    # forward it. Optimistic UI will roll the lever back when no projection confirms it.
    Rails.logger.error("commands: produce failed: #{e.class}: #{e.message}")
    head :service_unavailable
  end

  private

  # Returns nil for anything malformed, which becomes a 422.
  #
  # This is defence in depth rather than the only defence: `Command.parse` coerces the value
  # and `Match#apply` rejects what it cannot read, because this controller is not the only
  # producer to the topic. But rejecting junk here means it never occupies a partition, and it
  # gives the player an actual error instead of silence.
  def build_command
    case params[:type]
    when ReactorSim::Command::SET_CONTROL   then set_control
    when ReactorSim::Command::ASSIGN_MINION then assign_minion
    when "resync", "reset_match"            then { "type" => params[:type] }
    end
  end

  def set_control
    value = Float(params[:value], exception: false)
    return unless value && params[:control_point_id].to_s.match?(CONTROL_ID)

    { "type" => ReactorSim::Command::SET_CONTROL,
      "operation_id" => DevMatch::OPERATION_ID.to_s,
      "control_point_id" => params[:control_point_id].to_s,
      "value" => value }
  end

  def assign_minion
    return unless params[:minion_id].to_s.match?(CONTROL_ID)
    # A nil station is legitimate: it means "stand this minion down".
    return unless params[:control_point_id].nil? ||
                  params[:control_point_id].to_s.match?(CONTROL_ID)

    { "type" => ReactorSim::Command::ASSIGN_MINION,
      "operation_id" => DevMatch::OPERATION_ID.to_s,
      "minion_id" => params[:minion_id].to_s,
      "control_point_id" => params[:control_point_id]&.to_s }
  end
end
