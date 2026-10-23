# frozen_string_literal: true

module ReactorSim
  # What a hazard does to a person. `Concerns::Wearing`, for minions.
  #
  # The shape is copied and the vocabulary is not: a part has `durability` and a `failure`, a
  # person has `resilience`, `wounds` and an `injury`. What they share is the one rule that must
  # never drift between them, `Severity.escalate`.
  #
  # **The Danger Check draws no dice of its own.** A minion's `resilience` is rolled ONCE, at
  # `initial_state`, and every check after that is a deterministic comparison; the one die it
  # reads, which of a tier's variants a wound is, was thrown in phase 0. So injuries replay
  # exactly and survive a snapshot.
  #
  # **A harm deals wounds of the kinds it declares**, each bitten separately (`Wounds`), and the
  # wounds stack: a second harm of any tier still wounds. **Every bite comes off one pool**,
  # `resilience` — run out and they collapse whatever their wounds; far enough past empty and they
  # die. `injury` is the condition this comes to, derived and never set apart from it: the worst
  # of their wounds and of the pool.
  #
  # See `docs/design_sketches/wounds.md`.
  module Injury
    # Ascending severity. The order is the hash's own insertion order, so the escalation ladder
    # needs no second declaration that could disagree with the first — the same trick
    # `failure_modes` uses. What a wound does to a body is the catalogue's; what being carried out
    # does is here.
    MODES = {
      # A knock, or several. Still at their post, barely slower.
      minor: {},
      # Walking wounded. Still at their post, and worse at it.
      significant: {},
      # Carried out. Their station is cleared, so whatever they were doing stops being done.
      severe: { derates: { strength: 0.0, dexterity: 0.0, intelligence: 0.0, agility: 0.0 },
                stood_down: true },
      # The worst of it. Heals slowest of all, between matches.
      mortal: { derates: { strength: 0.0, dexterity: 0.0, intelligence: 0.0, agility: 0.0 },
                stood_down: true, lasting: true }
    }.freeze

    ORDER = MODES.keys.freeze

    # A bite this large is a mortal wound on its own, whatever was left — the scale willingness to
    # kill is read against (`Animosity::LETHAL`).
    MORTAL_BITE = Wounds::BANDS.fetch(:mortal)

    # **How far past empty a pool goes before it kills**, as a share of what they started with:
    # a beating that goes on is a killing.
    DEATH_SHARE = 0.5

    # **A wound carried into a match takes its depth off the resilience they start with**, never
    # below this share of it, so a chain of bad shifts tells and nobody starts already collapsed.
    CARRIED_FLOOR = 0.25

    # Hidden, and multiplied by toughness so a tough minion has more in reserve as well as
    # shrugging more off. The spread is what a player cannot see and cannot plan around; it is
    # the same design as `durability_range` and it is why an incident feels uncertain without
    # the system being arbitrary.
    #
    # **Roomier than a severe wound bites**, so a body takes more than one bad wound before it
    # collapses, and knocks and wounds wear it down in between.
    RESILIENCE_SPREAD = (1.7..2.7)

    # **Several wounds in one tick each need their own variant die**: the phase-0 die stepped by
    # this for each wound already carried, which keeps the steps uniform and unrelated.
    STEP = 0.618_033_988_749_895

    module_function

    # **A stream of its own per person** for the one die a wound reads, so adding it moved none of
    # the dice already thrown for them.
    def stream(minion_id) = :"#{minion_id}/wounds"

    def initial_state(rng, toughness)
      rolled = toughness * rng.between(RESILIENCE_SPREAD.begin, RESILIENCE_SPREAD.end)

      { resilience: rolled, initial_resilience: rolled, injury: nil, wounds: [].freeze, doses: {}.freeze }
    end

    # **What stands against one kind of a harm.** The body's own share of it — toughness and a
    # sense for danger, less clumsiness — goes by the kind's share of the harm, so somebody with no
    # kit takes the same total as one bite would; protection against the cause (a helmet against
    # `rockfall`) goes the same way; protection against the kind meets it whole.
    #
    # **A hazard tag `:x` is resisted by the minion tag `:x_resistance`** — one naming convention
    # rather than a lookup table, so adding a kind or a cause means adding gear that names it.
    #
    # **A hazard that `pierces:` finds the gap** — a critical blow to a soft spot, round the armour —
    # and meets no `_resistance` kit, and only that share of the body's own toughness.
    def resisted(minion, hazard, kind, share)
      kept = hazard[:pierces]
      return minion.toughness * numeric(kept) * share if kept

      body = minion.toughness + numeric(minion.tag(:hazard_sense)) - numeric(minion.tag(:clumsy))
      against_cause = hazard.fetch(:causes, []).sum { |cause| numeric(minion.tag(:"#{cause}_resistance")) }
      ((body + against_cause) * share) + numeric(minion.tag(:"#{kind}_resistance"))
    end

    # **The Danger Check.** `hazard` is `{ wounds: { kind => severity }, causes: [...] }`, plus
    # `pierces:` and `cause:` where they apply; `catalogue:` is the content's `Wounds::Catalogue`
    # and `die:` this person's `wound:` die for the tick.
    #
    # Returns `[next_state, mode_or_nil, wounds]`: a mode only when this harm left a wound or
    # worsened their condition — the worst of those — and the wounds it left. The discipline
    # `break_part` follows, and for the same reason: re-deciding every tick would announce the
    # same injury at the tick rate forever.
    def check(minion, state, hazard, catalogue:, die:)
      dealt = hazard.fetch(:wounds)
      total = dealt.values.sum
      return [ state, nil, [] ] unless total.positive?

      before = state.fetch(:injury)
      fresh = []
      dealt.sort_by { |kind, _| kind.to_s }.each do |kind, severity|
        bite = severity - resisted(minion, hazard, kind, severity / total)
        next unless bite.positive?

        state = state.merge(resilience: state.fetch(:resilience) - bite)
        tier = Wounds.tier(bite) or next

        wound = inflict(state, kind, bite, tier, hazard, catalogue, die)
        state = state.merge(wounds: (state.fetch(:wounds, []) + [ wound ]).freeze)
        fresh << wound
      end
      settle(state, before, fresh)
    end

    # **A harm that keeps working** — heat, cold, bad air — deepens one standing wound of its kind
    # instead of adding one a tick, and grinds the pool by what it bites. Returns as `check`.
    def endure(state, kind, bite, catalogue:, die:, cause: nil)
      return [ state, nil, [] ] unless bite.positive?

      before = state.fetch(:injury)
      state = state.merge(resilience: state.fetch(:resilience) - bite)
      deepen(state, before, kind, bite, catalogue, die, cause)
    end

    # **Harm that is not a bite**, and so nothing to resist: suffocation past collapse, a burn or
    # a chill held past it. The kind's standing wound is taken at least as deep as `mode` begins,
    # and the escalation rule is still the shared one, which is what keeps a minion from being
    # announced as collapsed twice, or as severely hurt after being mortally so.
    def succumb(state, mode, kind:, catalogue:, die:)
      needed = Wounds::BANDS.fetch(mode) - dose(state, kind)
      return [ state, nil, [] ] unless needed.positive?

      deepen(state, state.fetch(:injury), kind, needed, catalogue, die, nil)
    end

    # **Wounds from earlier matches**, as the delivery tier keeps them — `[{ kind:, depth:, variant:,
    # cause:, ref: }]`, healed already — read back into the catalogue and into what they start with.
    # `ref` is the delivery tier's own name for the wound, carried so it knows the wound again.
    def carried(state, wounds, catalogue)
      kept = Array(wounds).filter_map do |held|
        depth = held.fetch(:depth).to_f
        tier = Wounds.tier(depth) or next

        wound = resolved(held.fetch(:kind).to_sym, depth, tier, held.fetch(:variant).to_i,
                         held[:cause]&.to_sym, catalogue)
        held[:ref] ? wound.merge(ref: held[:ref]).freeze : wound
      end
      return state if kept.empty?

      floor = state.fetch(:initial_resilience) * CARRIED_FLOOR
      started = [ state.fetch(:resilience) - kept.sum { |wound| wound.fetch(:depth) }, floor ].max
      doses = kept.select { |w| Wounds::CONTINUOUS.include?(w.fetch(:kind)) }.to_h { |w| [ w.fetch(:kind), w.fetch(:depth) ] }
      settled, = settle(state.merge(wounds: kept.freeze, resilience: started, doses: doses.freeze), nil, [])
      settled
    end

    # What the pool and the wounds come to: the worst wound, collapsed at an empty pool, dead far
    # past it.
    def condition(state)
      worst = state.fetch(:wounds, []).map { |wound| wound.fetch(:tier) }.max_by { |tier| ORDER.index(tier) }
      Severity.escalate(worst, spent(state), ORDER)
    end

    # What the pool alone comes to: collapsed at empty, dead far past it, or nothing.
    def spent(state)
      left = state.fetch(:resilience)
      return :mortal if left <= -DEATH_SHARE * state.fetch(:initial_resilience)

      :severe if left <= 0.0
    end

    # Being carried out clears the station, which is the whole mechanical consequence of a severe
    # injury: whatever that lever needed doing stops being done, and somebody else has to be
    # moved onto it.
    #
    # **It clears the posting too, or they get up and walk there again.** Where there is geometry
    # a posting is a standing order that the travel phase keeps acting on, so leaving it set
    # would have a stretchered minion resume their journey on the next tick.
    def apply_mode(state, mode)
      state = state.merge(injury: mode)
      MODES.dig(mode, :stood_down) ? state.merge(station: nil, posting: nil) : state
    end

    # What their injuries leave of a stat, 0..1: nothing at all while carried out, and otherwise
    # every wound's derate multiplied. 1.0 for an unhurt minion, so callers can multiply
    # unconditionally.
    def derating(state, key)
      mode = state.fetch(:injury, nil)
      return MODES.dig(mode, :derates, key) || 1.0 if MODES.dig(mode, :stood_down)

      state.fetch(:wounds, []).reduce(1.0) { |left, wound| left * wound.fetch(:derates).fetch(key, 1.0) }
    end

    # An injury that outlives the match on the injury list — the only tier that does.
    def lasting?(mode) = !mode.nil? && !MODES.dig(mode, :lasting).nil?

    # `true` is a trait that is simply present, and in arithmetic it means "fully".
    def numeric(value)
      return 1.0 if value == true

      value.to_f
    end

    # The standing wound of a continuous kind, or nil.
    def standing(state, kind) = state.fetch(:wounds, []).find { |wound| wound.fetch(:kind) == kind }

    # **How much of a continuous harm they have taken**, kept even while it is too little to show,
    # so a little heat for a long time adds up.
    def dose(state, kind) = state.fetch(:doses, {}).fetch(kind, 0.0)

    def deepen(state, before, kind, bite, catalogue, die, cause)
      held = standing(state, kind)
      depth = dose(state, kind) + bite
      state = state.merge(doses: state.fetch(:doses, {}).merge(kind => depth).freeze)
      tier = Wounds.tier(depth)
      return settle(state, before, []) if tier.nil?

      index = held ? held.fetch(:variant) : catalogue.pick(kind, tier, die_for(state, die))
      wound = resolved(kind, depth, tier, index, held ? held[:cause] : cause, catalogue)
      wound = wound.merge(held.slice(:ref)).freeze if held&.key?(:ref)
      # In its own place, so the delivery tier can tell a wound deepening from a new one.
      wounds = held ? state.fetch(:wounds).map { |w| w.equal?(held) ? wound : w } : state.fetch(:wounds, []) + [ wound ]
      state = state.merge(wounds: wounds.freeze)
      settle(state, before, held && held.fetch(:tier) == tier ? [] : [ wound ])
    end

    def inflict(state, kind, depth, tier, hazard, catalogue, die)
      index = catalogue.pick(kind, tier, die_for(state, die))
      resolved(kind, depth, tier, index, hazard[:cause] || hazard.fetch(:causes, []).first, catalogue)
    end

    # **A wound, with what its place in the catalogue says it is.** Its variant is a place in the
    # tier, so a wound that heals or deepens into another tier is the variant at the same place.
    def resolved(kind, depth, tier, index, cause, catalogue)
      entry = catalogue.variant(kind, tier, index)
      { kind: kind, depth: depth, tier: tier, variant: index, id: entry.fetch(:id),
        label: entry.fetch(:label), derates: entry.fetch(:derates), cause: cause }.compact.freeze
    end

    def die_for(state, die) = (die + (STEP * state.fetch(:wounds, []).length)) % 1.0

    # The condition the wounds and the pool now come to, applied if it worsened; and the mode to
    # report — the worst of what this harm left and of a worsened condition — or nil.
    def settle(state, before, fresh)
      now = Severity.escalate(before, condition(state), ORDER)
      state = apply_mode(state, now) unless now == before
      reported = fresh.map { |wound| wound.fetch(:tier) }
      reported << now unless now == before
      [ state, reported.max_by { |tier| ORDER.index(tier) }, fresh ]
    end
  end
end
