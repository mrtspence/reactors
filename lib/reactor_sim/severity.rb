# frozen_string_literal: true

module ReactorSim
  # Escalation, shared by the two things that get worse and never better: a part failing and a
  # person being hurt.
  #
  # **One implementation on purpose.** `Concerns::Wearing` and `Injury` are deliberately separate
  # — a part has a `durability` and a minion has a `resilience`, and forcing one vocabulary on
  # both would bend each out of shape — but this single rule must not drift between them, because
  # a drift would be invisible. A ladder that moved backwards in one path and not the other reads
  # as a balance quirk, not as a bug.
  module Severity
    module_function

    # **Forward only.** A drum that has exploded must never be re-described as merely split, and
    # a minion who has been carried out must never be re-described as walking wounded — in both
    # cases because the conditions that caused the worse outcome are *gone precisely because it
    # happened*. A boiler that let go has no pressure left; a minion who is out is not standing
    # anywhere dangerous.
    #
    # A mode the table does not name sorts LAST rather than being discarded, so something saying
    # what its own declaration does not describe surfaces as an obviously-wrong escalation rather
    # than as silence.
    def escalate(current, proposed, order)
      return proposed if current.nil?
      return current if proposed.nil?

      [ current, proposed ].max_by { |mode| order.index(mode) || order.length }
    end
  end
end
