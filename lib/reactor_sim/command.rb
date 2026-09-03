# frozen_string_literal: true

module ReactorSim
  # Player intent, as it arrives from the command log.
  #
  # Commands cross a JSON boundary on the way in, so they may arrive with string keys
  # and string ids. Parsing is deliberately forgiving: a command that cannot be
  # understood is rejected and counted, never raised, because a malformed record in
  # the log must not be able to stop a match.
  module Command
    SET_CONTROL   = "set_control"
    ASSIGN_MINION = "assign_minion"

    Parsed = Struct.new(:type, :operation_id, :control_point_id, :value, :minion_id,
                        keyword_init: true)

    def self.parse(raw)
      hash = raw.to_h { |k, v| [ k.to_sym, v ] }

      Parsed.new(
        type: hash[:type].to_s,
        operation_id: symbol_or_nil(hash[:operation_id]),
        control_point_id: symbol_or_nil(hash[:control_point_id]),
        value: numeric_or_nil(hash[:value]),
        minion_id: symbol_or_nil(hash[:minion_id])
      )
    rescue StandardError
      Parsed.new(type: "")
    end

    def self.symbol_or_nil(value)
      return nil if value.nil?

      value.to_sym
    end
    private_class_method :symbol_or_nil

    # The value is the one field that used to leave this method untouched, and it was the
    # only one that could still hurt anybody. It travels on to ControlPoint#set_target,
    # which calls `.to_f` — and a Hash does not answer to that, so a single malformed record
    # raised NoMethodError straight out of Match#apply, which does not rescue. In the runner
    # that is the whole process and every match on it, from one bad line in the log.
    #
    # Coercing here rather than at the caller is deliberate: this module already promises
    # never to raise, and the log has producers other than our own controller.
    def self.numeric_or_nil(value)
      Float(value, exception: false)
    end
    private_class_method :numeric_or_nil
  end
end
