# frozen_string_literal: true

module ReactorSim
  # Player intent, as it arrives from the command log.
  #
  # Commands cross a JSON boundary on the way in, so they may arrive with string keys
  # and string ids. Parsing is deliberately forgiving: a command that cannot be
  # understood is rejected and counted, never raised, because a malformed record in
  # the log must not be able to stop a match.
  module Command
    SET_CONTROL = "set_control"

    Parsed = Struct.new(:type, :operation_id, :control_point_id, :value, keyword_init: true)

    def self.parse(raw)
      hash = raw.to_h { |k, v| [ k.to_sym, v ] }

      Parsed.new(
        type: hash[:type].to_s,
        operation_id: symbol_or_nil(hash[:operation_id]),
        control_point_id: symbol_or_nil(hash[:control_point_id]),
        value: hash[:value]
      )
    rescue StandardError
      Parsed.new(type: "", operation_id: nil, control_point_id: nil, value: nil)
    end

    def self.symbol_or_nil(value)
      return nil if value.nil?

      value.to_sym
    end
    private_class_method :symbol_or_nil
  end
end
