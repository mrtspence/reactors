# frozen_string_literal: true

module ReactorSim
  # What a hazard does to a person. `Concerns::Wearing`, for minions.
  #
  # The shape is copied and the vocabulary is not: a part has `durability` and a `failure`, a
  # person has `resilience` and an `injury`. What they share is the one rule that must never
  # drift between them, `Severity.escalate`.
  #
  # **The Danger Check draws no dice.** A minion's `resilience` is rolled ONCE, at
  # `initial_state`, and every check after that is a deterministic comparison — which buys
  # determinism, order-independence, replay and snapshot safety for nothing, and needs no
  # amendment to the entropy invariant, since `initial_state` is one of the three places entropy
  # is permitted. The uncertainty is the hidden threshold, exactly as for a part.
  #
  # Two routes into harm, which are `Wearing`'s two:
  #
  #   accumulation  a long shift in a hot place grinds `resilience` down
  #   overload      one blow big enough that what is left does not matter
  #
  # A worn minion is hurt sooner, which keeps their history meaningful.
  #
  # See `docs/design_sketches/minions.md` §5.
  module Injury
    # Ascending severity. The order is the hash's own insertion order, so the escalation ladder
    # needs no second declaration that could disagree with the first — the same trick
    # `failure_modes` uses.
    MODES = {
      # Walking wounded. Still at their post, and worse at it.
      minor: { derates: { strength: 0.6, dexterity: 0.7, intelligence: 0.85 } },
      # Carried out. Their station is cleared, so whatever they were doing stops being done.
      severe: { derates: { strength: 0.0, dexterity: 0.0, intelligence: 0.0 },
                stood_down: true },
      # The injury list. The only tier that outlives the match.
      mortal: { derates: { strength: 0.0, dexterity: 0.0, intelligence: 0.0 },
                stood_down: true, lasting: true }
    }.freeze

    ORDER = MODES.keys.freeze

    # A bite this large is nobody's good day regardless of what they had left. This is the
    # `overload?` half: a drum letting go beside somebody is not a question about their stamina.
    MORTAL_BITE = 2.5

    # Resilience below this fraction of what they started with is the walking-wounded band. Above
    # it a bite still costs them, it simply does not show yet, which makes a long shift tell later
    # rather than immediately.
    #
    # **Keep this wide.** Bites large enough to get through a minion's resistance at all are a
    # decent fraction of what they have, so a narrow band takes a worker from unmarked to
    # carried-out in two hits and `:minor` fires only on a coincidence.
    WALKING_WOUNDED = 0.6

    # Hidden, and multiplied by toughness so a tough minion has more in reserve as well as
    # shrugging more off. The spread is what a player cannot see and cannot plan around; it is
    # the same design as `durability_range` and it is why an incident feels uncertain without
    # the system being arbitrary.
    RESILIENCE_SPREAD = (0.85..1.35)

    module_function

    def initial_state(rng, toughness)
      rolled = toughness * rng.between(RESILIENCE_SPREAD.begin, RESILIENCE_SPREAD.end)

      { resilience: rolled, initial_resilience: rolled, injury: nil }
    end

    # How much of a hazard actually reaches somebody.
    #
    # **A hazard tag `:x` is resisted by the minion tag `:x_resistance`** — one naming convention
    # rather than a lookup table, so adding a hazard kind means adding gear that names it and
    # nothing else. `clumsy` works the other way and makes the bite worse, which is what turns a
    # day-labourer from merely useless into genuinely dangerous to employ.
    def resistance(minion, hazard)
      resisted = Array(hazard[:tags]).sum { |tag| numeric(minion.tag(:"#{tag}_resistance")) }

      minion.toughness + resisted + numeric(minion.tag(:hazard_sense)) -
        numeric(minion.tag(:clumsy))
    end

    # The Danger Check. Pure, and no entropy: everything uncertain about it was decided at
    # `initial_state`.
    #
    # Returns `[next_state, mode_or_nil]`. A mode comes back only on a TRANSITION — the discipline
    # `break_part` follows, and for the same reason: re-deciding every tick would announce the
    # same injury at the tick rate forever.
    def check(minion, state, hazard)
      bite = hazard.fetch(:severity).to_f - resistance(minion, hazard)
      return [ state, nil ] if bite <= 0.0

      remaining = [ state.fetch(:resilience) - bite, 0.0 ].max
      state = state.merge(resilience: remaining)

      proposed = tier(bite, remaining, state.fetch(:initial_resilience))
      worsened = Severity.escalate(state.fetch(:injury), proposed, ORDER)
      return [ state, nil ] if worsened.nil? || worsened == state.fetch(:injury)

      [ apply_mode(state, worsened), worsened ]
    end

    def tier(bite, remaining, started)
      return :mortal if bite >= MORTAL_BITE
      return :severe if remaining <= 0.0
      return :minor if started.positive? && remaining < (started * WALKING_WOUNDED)

      nil
    end

    # Being carried out clears the station, which is the whole mechanical consequence of a severe
    # injury: whatever that lever needed doing stops being done, and somebody else has to be
    # moved onto it.
    def apply_mode(state, mode)
      state = state.merge(injury: mode)
      MODES.dig(mode, :stood_down) ? state.merge(station: nil) : state
    end

    # What this injury leaves of a stat, 0..1. Returns 1.0 for an unhurt minion, so callers can
    # multiply unconditionally.
    def derating(state, key)
      mode = state.fetch(:injury, nil)
      return 1.0 if mode.nil?

      MODES.dig(mode, :derates, key) || 1.0
    end

    # An injury that outlives the match — the only tier the delivery tier has to write down.
    def lasting?(mode) = !mode.nil? && !MODES.dig(mode, :lasting).nil?

    # `true` is a trait that is simply present, and in arithmetic it means "fully".
    def numeric(value)
      return 1.0 if value == true

      value.to_f
    end
  end
end
