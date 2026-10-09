# frozen_string_literal: true

module ReactorSim
  # The arithmetic every layer of a minion's sheet folds through.
  #
  # A minion is four layers — archetype, individual, training, equipment — each offsetting the
  # last. `Content::Registry` folds the first two and `Crew` folds the rest at build, a split
  # forced by the boundary: content knows about people, and only the delivery tier knows what a
  # player *owns*. **One implementation, because two copies would drift silently** — a tag that
  # sums in one path and overwrites in the other reads as a balance problem, not a bug.
  #
  # See `docs/design_sketches/minions.md` §4.
  module Sheet
    # The six every archetype declares. Fixed rather than open because the simulation's own
    # machinery reads them and needs a number with a meaning rather than an absence.
    #
    #   strength      strength-to-WEIGHT ratio         — pace, and the root of `force`
    #   toughness     what they shrug off              — the Danger Check
    #   endurance     how slowly they tire             — Fatigue.accrual
    #   intelligence  what they notice                 — the `observer:` gauge path
    #   dexterity     how finely they can work         — precision work
    #   charisma      how others take them             — reserved
    #
    # **`strength` is a RATIO, not an absolute, and 1.0 is a human's.** Below 1.0 means worse
    # pound-for-pound than a person, which is where most large things sit — strength grows with
    # cross-section and weight grows with volume, so an ogre is overwhelming because there is half
    # a tonne of him rather than because he is efficient. It is also why nothing large can carry
    # its own kind, and that falls out of the arithmetic rather than being a rule.
    #
    # What a job actually gets is therefore **derived** from the ratio and the body — see
    # `DERIVED` and `Minion#force` — and `strength` itself is read directly only where
    # strength-to-weight is genuinely the question, which is moving your own body: `Minion::PACE`.
    #
    # `dexterity` does NOT replace the `clumsy` tag. How finely somebody works and how often they
    # drop things are two statements about one person.
    #
    # **`endurance` is not `strength` slowed down, and it is not `toughness`.** What somebody gets
    # done and what it costs them are separate claims — an ogre who shifts coal twice as fast and
    # tires twice as fast is only expressible with both — and toughness is about a blow landing,
    # which is a different event from a long shift.
    STATS = %i[strength toughness endurance intelligence dexterity charisma].freeze

    # The body a `strength` of 1.0 is the ratio for. Changing this rescales every derived figure
    # in the game at once, which is why it lives here rather than beside any one consumer.
    REFERENCE_MASS_KG = 70.0

    # **What an `effort:` blend may name beyond the six, because mass pays off differently per
    # job.** Both are 1.0 for a reference human, so a station's declared throughput stays true and
    # weights still sum to 1.0 meaningfully.
    #
    #   force   strength × mass ÷ reference. Pushing a tub, heaving rock, a heavy lever — work
    #           where friction and leverage decide, and where bulk pays linearly.
    #   swing   √force. A tool at the end of an arm: a pick can only be swung so fast and bites
    #           only so deep, so bulk stops paying in proportion. An ogre lands about twice a
    #           human's work with the same pick, and a *bigger* pick is then the upgrade.
    #
    # **A station may still name `strength` directly**, and some should — a more specific caller
    # wins over a general rule. These are additions to what `effort:` accepts, not a replacement.
    DERIVED = %i[force swing].freeze

    # A stat can be driven to zero and no further. Negative strength would drive a lever *away*
    # from its target, which is not "very weak" — it is a different machine.
    MIN_STAT = 0.0

    # A valued tag answers "how much of this do you have", so it lives in 0..1. The floor is what
    # makes a negative contribution mean what it should: the lucky amulet's `clumsy: -0.15`
    # reduces clumsiness toward *not clumsy*, and cannot invent anti-clumsiness below that.
    TAG_RANGE = (0.0..1.0)

    # **Mass is neither a stat nor a tag, and it is never defaulted.**
    #
    # Not a stat: stats pass through `Minion#effective`, which multiplies by `Injury.derating`, so
    # a broken arm would make somebody *lighter*. Mass is a property of the body and nothing about
    # being hurt changes it. Not a tag either: `TAG_RANGE` is 0..1, and an ogre heavier than a
    # human cannot be said at all.
    #
    # **Absent is an error rather than a default.** It is load-bearing in two formulas — the lift
    # limit and the burden ratio — and a quiet 70 kg cannot be seen in the content. An archetype
    # that omits it raises at boot, exactly as one omitting `strength` already does.
    #
    # This floor is therefore **only** for a runaway negative offset — enough "slight build" to
    # reach zero would be a division by zero in `burden`. It never covers an absent declaration;
    # those are different failures and only one of them is allowed to be quiet.
    MIN_MASS_KG = 1.0

    module_function

    # **Merge adds; use multiplies.** Gear reads as "+0.25 mining_effectiveness", which is how
    # the content is written — so folding is addition. Whoever *reads* a sheet multiplies, which
    # is why a crude pick and a candle is a punishing 0.25 × 0.1 rather than a middling 0.35.
    # Getting these round the wrong way makes every piece of kit a rounding error.
    def add_stats(base, offsets)
      return base if offsets.nil? || offsets.empty?

      base.merge(offsets.slice(*STATS)) { |_stat, a, b| a.to_f + b.to_f }
    end

    # `true` means a trait is simply present. Adding to it would be nonsense, so it wins outright
    # rather than being coerced into arithmetic — an item that makes somebody `undead` does not
    # make them 1.4 undead.
    def add_tags(base, extra)
      return base if extra.nil? || extra.empty?

      base.merge(extra) do |_key, a, b|
        a == true || b == true ? true : a.to_f + b.to_f
      end
    end

    # Applied once, at the end of all four layers, never between them. Clamping each layer as it
    # lands would make the ORDER of the layers matter — a penalty applied before a bonus would
    # floor at zero and the bonus would then lift from there, so the same kit in a different
    # order would give a different worker.
    def settle(stats, tags)
      [ stats.to_h { |stat, value| [ stat, [ value.to_f, MIN_STAT ].max ] }.freeze,
        tags.to_h { |key, value|
          [ key, value == true ? true : value.to_f.clamp(TAG_RANGE.begin, TAG_RANGE.end) ]
        }.freeze ]
    end
  end
end
