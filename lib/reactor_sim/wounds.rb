# frozen_string_literal: true

module ReactorSim
  # **What a harm does to a body, and what it leaves.** A harm declares the kinds of wound it deals
  # and its causes; each kind is a bite of its own, and each bite past the first band leaves a
  # wound — a kind, a depth and a tier read from it, and one of three named variants out of the
  # catalogue in `content/wounds/`. Wounds stack. See `docs/design_sketches/wounds.md`.
  #
  # Pure arithmetic and validation. Who is hurt, and when, is `Injury`'s.
  module Wounds
    # What a body suffers. The last three are continuous: one standing wound deepens while they
    # last (§3.6 of the sketch).
    KINDS = %i[impact crush puncture cut burn scald blast heat cold breath].freeze
    CONTINUOUS = %i[heat cold breath].freeze

    # What did it, as far as protection goes: a helmet against `rockfall`, a belt against `fall`.
    # Never a wound.
    CAUSES = %i[rockfall fall afterdamp].freeze

    TIERS = %i[minor significant severe mortal].freeze

    # **The depth each tier begins at**, absolute, as a bite past resistance. Under `minor` a bite
    # costs resilience and leaves nothing to show.
    BANDS = { minor: 0.15, significant: 0.6, severe: 1.6, mortal: 3.0 }.freeze

    VARIANTS = 3

    # **Healing between matches**: this much depth off every wound a match, plus `regeneration`
    # and less `slow_healer`, and never less than `LEAST_HEAL`, so nobody stops healing altogether
    # and nobody is out for ever. Read by the delivery tier.
    HEAL_PER_MATCH = 0.5
    LEAST_HEAL = 0.05

    # Shares within this of summing to one are taken as summing to one.
    SHARE_SLACK = 1.0e-6

    module_function

    # The tier a wound of this depth is, or nil for one that leaves nothing.
    def tier(depth) = TIERS.reverse.find { |t| depth >= BANDS.fetch(t) }

    def heal(depth, tags)
      rate = HEAL_PER_MATCH + Injury.numeric(tags.fetch(:regeneration, 0.0)) -
             Injury.numeric(tags.fetch(:slow_healer, 0.0))
      [ depth - [ rate, LEAST_HEAL ].max, 0.0 ].max
    end

    # **A harm's kinds as shares of its severity**, `{ crush: 0.6, burn: 0.4 }`, summing to one —
    # refused otherwise, and refused for any kind nobody knows. Nothing is untyped.
    def shares!(owner, wounds)
      raise Error, "#{owner}: says nothing of the wounds it deals (wounds: { kind => share })" if wounds.nil? || wounds.empty?

      shares = wounds.to_h { |kind, share| [ kind.to_sym, share.to_f ] }
      unknown = shares.keys - KINDS
      raise Error, "#{owner}: unknown wound kinds #{unknown.join(', ')} (kinds: #{KINDS.join(', ')})" if unknown.any?
      raise Error, "#{owner}: a wound's share must be positive" unless shares.values.all?(&:positive?)
      raise Error, "#{owner}: wound shares sum to #{shares.values.sum}, not 1" if (shares.values.sum - 1.0).abs > SHARE_SLACK

      shares.freeze
    end

    def causes!(owner, causes)
      causes = Array(causes).map(&:to_sym)
      unknown = causes - CAUSES
      raise Error, "#{owner}: unknown causes #{unknown.join(', ')} (causes: #{CAUSES.join(', ')})" if unknown.any?

      causes.freeze
    end

    # **Wounds from earlier matches as `options:` holds them**: `{ person => [{ kind:, depth:,
    # variant:, cause:, ref: }] }` with symbol keys, or nil for none, so an operation nobody is
    # hurt in snapshots exactly as before.
    def carried_over(account)
      rows = (account || {}).to_h do |person, held|
        [ person.to_sym, Array(held).map { |wound| wound.to_h { |key, value| [ key.to_sym, value ] }.freeze }.freeze ]
      end
      rows = rows.reject { |_, held| held.empty? }
      rows.empty? ? nil : rows.freeze
    end

    # `{ kind => severity }`: what a harm of this severity deals of each kind.
    def dealt(shares, severity) = shares.to_h { |kind, share| [ kind, share * severity ] }

    # **The catalogue, as content holds it**: `{ kind => { tier => { variant => entry } } }`,
    # complete — every kind, every tier, `VARIANTS` variants, each naming only real stats — or
    # refused at boot.
    class Catalogue
      # TODO: `tags:` on an entry — a wound taking from a tag as it takes from a stat; first caller
      # is the scald that takes the edge off `focused`. Needs a state-aware `Minion#tag`, since tags
      # are read without state today. Untested until then.
      ENTRY_KEYS = %i[label weight derates].freeze

      def initialize(spec)
        @variants = KINDS.to_h do |kind|
          tiers = spec.fetch(kind) { raise Error, "wounds: no #{kind} in the catalogue" }
          [ kind, TIERS.to_h { |tier| [ tier, variants(kind, tier, tiers) ] }.freeze ]
        end.freeze
        unknown = spec.keys - KINDS
        raise Error, "wounds: unknown kinds #{unknown.join(', ')}" if unknown.any?

        freeze
      end

      # The entry at this place in a tier: `{ id:, label:, weight:, derates: }`.
      def variant(kind, tier, index) = @variants.fetch(kind).fetch(tier).fetch(index)

      # **Which of a tier's variants, by weight**, on a die thrown in phase 0.
      def pick(kind, tier, die)
        entries = @variants.fetch(kind).fetch(tier)
        mark = die * entries.sum { |entry| entry.fetch(:weight) }
        entries.each_with_index do |entry, index|
          return index if mark < entry.fetch(:weight)

          mark -= entry.fetch(:weight)
        end
        entries.length - 1
      end

      private

      def variants(kind, tier, tiers)
        entries = tiers.fetch(tier) { raise Error, "wounds: #{kind} has no #{tier} tier" }
        unless entries.length == VARIANTS
          raise Error, "wounds: #{kind} #{tier} has #{entries.length} variants, not #{VARIANTS}"
        end

        entries.map { |id, entry| entry(kind, tier, id, entry) }.freeze
      end

      def entry(kind, tier, id, entry)
        owner = "wounds: #{kind} #{tier} #{id}"
        unknown = entry.keys - ENTRY_KEYS
        raise Error, "#{owner}: unknown #{unknown.join(', ')}" if unknown.any?
        raise Error, "#{owner}: no label" unless entry[:label]
        raise Error, "#{owner}: weight must be positive" unless entry.fetch(:weight, 0).to_f.positive?

        derates = Sheet.offsets(owner, entry.fetch(:derates, {}))
        raise Error, "#{owner}: derates are shares of a stat, 0..1" unless derates.values.all? { |v| v.between?(0.0, 1.0) }

        { id: id.to_sym, label: entry.fetch(:label), weight: entry.fetch(:weight).to_f, derates: derates }.freeze
      end
    end
  end
end
