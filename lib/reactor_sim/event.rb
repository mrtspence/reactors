# frozen_string_literal: true

module ReactorSim
  # Something the machine reported: the durable record of a match, as opposed to the projection,
  # which is a picture of one instant.
  #
  # A Hash with a module of functions over it, like `Ledger` and `Parcel` — an event lives inside
  # operation state and is serialised, so a class would add a round trip and buy nothing.
  #
  # **The engine reports transitions in the machine; the app composes them into meaning.** If
  # deciding whether to emit something requires knowing the rules of progression, it does not
  # belong here — a boiler knows the igniter was held in, but only the delivery tier knows what
  # that forfeits. Three things are therefore absent: **no wall-clock time** (`tick` is the
  # better clock, and the one replay already agrees on), **no player id**, and **no progression
  # meaning**.
  #
  # **Nothing that happens every tick may be an event.** A per-tick quantity belongs on the
  # `Ledger`, which already accumulates it and is checked by the conservation specs; emitting it
  # here would cost four records a second per match forever *and* create a second running total
  # that can drift. If a record's interesting content is a number that changed a little, it is a
  # meter reading and the runner samples it.
  #
  # See `docs/design_sketches/event_system.md`.
  module Event
    # Enumerated, because a consumer keyed to a type that no longer exists is a feature silently
    # switched off, and an unenumerable type cannot be checked at all.
    #
    # **There is one failure type and `mode:` is the axis.** A consumer wanting flywheel bursts
    # asks for `node == :flywheel` or `mode == :burst`, either of which survives a rename; the
    # mode vocabulary lives in `failure_modes` and nowhere else, because two lists that must be
    # remembered together are a footgun. A type derived from a node id is worse still — renaming
    # a node would silently rename an event type, and no list of types could exist at all.
    #
    # The transitions are named for what the MACHINE did, never for what it earns:
    # `:heater_engaged` rather than `:igniter_used`, because a vessel's heater is generic and
    # only the delivery tier knows what touching it forfeits.
    TYPES = %i[
      part_failed
      minion_hurt
      fusible_plug_melted
      fire_lit
      fire_out
      heater_engaged
      steam_raised
      blew_off
    ].freeze

    # Ascending. The client colours on these, so a new one is a delivery-tier change too.
    SEVERITIES = %i[info notice warning critical].freeze

    module_function

    def known?(type) = TYPES.include?(type)

    # Validated on every emission, which is affordable precisely because events are transitions:
    # this runs dozens of times in a match, not four times a second. Paying it here catches a bad
    # type at the node that emitted it, rather than three serialisation boundaries later as an
    # achievement that quietly never fires.
    def build(type:, node:, label:, severity:, tick:, **rest)
      raise Error, "unknown event type #{type.inspect}" unless known?(type)
      raise Error, "unknown severity #{severity.inspect}" unless SEVERITIES.include?(severity)

      { type: type, node: node, label: label, severity: severity, tick: tick }
        .merge(rest).compact.freeze
    end
  end
end
