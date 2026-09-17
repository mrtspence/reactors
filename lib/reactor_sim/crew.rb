# frozen_string_literal: true

module ReactorSim
  # Who an operation needs, and who is actually standing there.
  #
  # **A role is what the machine asks for; a minion is who fills it.** The steam engine needs a
  # fireman and a yardhand whoever is on the payroll — those are jobs, fixed by the machine — and
  # the roster decides that this match the fireman is Jim. Keeping them separate is the noun
  # correction that ran through this whole release, applied one layer further out.
  #
  # See docs/design_sketches/minions.md §2 and §7.
  module Crew
    # Who turns up when nobody better will. Not a constant in code: an ordinary individual in
    # `content/minions/` marked `hireable: false`, so there is exactly ONE way a sheet is folded
    # rather than a special case through the most safety-critical arithmetic in the feature.
    STANDIN = :kobold_temp

    # What the machine asks for. `station:` is where they START — `Minion#station(state)` is
    # where they are, because posting is a command and must survive a restore.
    #
    # Named `Role` rather than `Slot` deliberately: `ReactorSim::Slot` answers "what happens to
    # the wiring when this is empty", and a job has no wiring.
    Role = Struct.new(:id, :label, :station, keyword_init: true) do
      def to_s = label || id.to_s
    end

    module_function

    # Layers three and four, on top of the two `Content::Registry#sheet` has already folded.
    #
    # **This is where the boundary shows.** Training and equipment are things a player OWNS, and
    # ownership is not something this library may know about — so they arrive as ids in
    # `options:` and are resolved here, at build, once. Nothing on the tick path ever folds a
    # sheet.
    #
    # A posting with no `minion:` is the standin, which is what makes an unfilled crew slot and
    # a minion on the injury list the same thing to the engine: somebody turned up, and they are
    # not who you wanted.
    def resolve(posting, content:)
      posting ||= {}
      minion_id = (posting[:minion] || STANDIN).to_sym
      sheet = content.sheet(minion_id)

      stats, tags = fold(sheet, posting)
      stats, tags = Sheet.settle(stats, tags)

      { minion: minion_id,
        # A name override exists for one reason: the standin is drawn in any number, and four
        # crew all called "Day-Labourer" reads as one entry repeated rather than as a gang.
        name: posting[:name] || sheet.fetch(:name),
        archetype: sheet.fetch(:archetype),
        stats: stats, tags: tags,
        training: training_ids(posting).freeze,
        equipment: equipment_ids(posting).freeze }.freeze
    end

    # Every id symbolised and every slot named, including the empty ones — the same discipline
    # `Assembly#resolve_loadout` follows, and for the same reason. **A posting that arrives back
    # from a snapshot is JSON**, so its values are Strings; a partial one would let an equipment
    # slot a player deliberately emptied quietly refill itself on restore.
    def normalise(crew, roles:)
      crew = crew.to_h { |k, v| [ k.to_sym, v ] }

      roles.to_h do |role|
        given = (crew[role.id] || {}).to_h { |k, v| [ k.to_sym, v ] }
        [ role.id, normalise_posting(given).freeze ]
      end.freeze
    end

    def normalise_posting(given)
      posting = { minion: symbolise(given[:minion]),
                  name: given[:name],
                  training: Array(given[:training]).filter_map { |id| symbolise(id) } }

      Equipment::SLOTS.each { |slot| posting[slot] = symbolise(given[slot]) }
      posting.compact
    end

    # `:none` is how an explicitly empty slot can be written down without becoming a nil that
    # `fetch` would re-default — the same escape `Assembly#normalise_part_id` provides.
    def symbolise(value)
      return nil if value.nil? || value.to_s.empty?

      id = value.to_sym
      id == :none ? nil : id
    end

    def fold(sheet, posting)
      stats = sheet.fetch(:stats)
      tags  = sheet.fetch(:tags)

      training_ids(posting).each do |id|
        course = Training.fetch(id)
        stats = Sheet.add_stats(stats, course.stats)
        tags  = Sheet.add_tags(tags, course.tags)
      end

      equipment_ids(posting).each do |slot, id|
        item = fitted(slot, id)
        stats = Sheet.add_stats(stats, item.stats)
        tags  = Sheet.add_tags(tags, item.tags)
      end

      [ stats, tags ]
    end

    def training_ids(posting) = Array(posting[:training]).map(&:to_sym)

    def equipment_ids(posting)
      Equipment::SLOTS.to_h { |slot| [ slot, posting[slot]&.to_sym ] }.compact
    end

    # **The item's own slot has to match the slot it was fitted in.** Checking only that the slot
    # exists would let a pair of gloves be posted as a tool and silently grant its bonus from the
    # wrong place — and a pre-match screen that offered the wrong list would then be wrong in a
    # way nothing complained about. Three slots, one item each, and each item knows which.
    def fitted(slot, id)
      item = Equipment.fetch(id)
      return item if item.slot == slot

      raise Error, "equipment #{id} is #{item.slot} and cannot be fitted as #{slot}"
    end
  end
end
