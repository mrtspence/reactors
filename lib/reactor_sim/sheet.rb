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
    # The five every archetype declares. Fixed rather than open because the simulation's own
    # machinery reads them and needs a number with a meaning rather than an absence.
    #
    #   strength      what they bring to a lever       — Minion#rate_multiplier
    #   toughness     what they shrug off              — the Danger Check
    #   intelligence  what they notice                 — the `observer:` gauge path (reserved)
    #   dexterity     how finely they can work         — reserved
    #   charisma      how others take them             — reserved
    #
    # `dexterity` does NOT replace the `clumsy` tag. How finely somebody works and how often they
    # drop things are two statements about one person.
    STATS = %i[strength toughness intelligence dexterity charisma].freeze

    # A stat can be driven to zero and no further. Negative strength would drive a lever *away*
    # from its target, which is not "very weak" — it is a different machine.
    MIN_STAT = 0.0

    # A valued tag answers "how much of this do you have", so it lives in 0..1. The floor is what
    # makes a negative contribution mean what it should: the lucky amulet's `clumsy: -0.15`
    # reduces clumsiness toward *not clumsy*, and cannot invent anti-clumsiness below that.
    TAG_RANGE = (0.0..1.0)

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
