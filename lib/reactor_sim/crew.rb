# frozen_string_literal: true

module ReactorSim
  # How many hands an operation can field, and who is in each seat.
  #
  # **A seat is a person you brought; a station is somewhere they can stand.** The two are
  # declared independently and the gap between them is the game: jobs come from the machine
  # (every `ControlPoint` with `effort:`), hands come from the fitted crew quarters, and when
  # there are more of the first than the second somebody has to decide what is not being done.
  #
  # > **The roster used to be keyed by JOB, and it filled every job.** A machine declaring three
  # > jobs got three bodies whether anybody had been hired or not, so nothing in the model could
  # > express scarcity of people and an operation with enough stations to be interesting ran
  # > itself. It also contradicted a noun correction this codebase had already made and written
  # > down: what a player unlocks is Jim, not the fireman's post.
  #
  # See docs/design_sketches/crew_capacity.md.
  module Crew
    # Who turns up when nobody better will. Not a constant in code: an ordinary individual in
    # `content/minions/` marked `hireable: false`, so there is exactly ONE way a sheet is folded
    # rather than a special case through the most safety-critical arithmetic in the feature.
    STANDIN = :kobold_temp

    # Seats are positional and their ids are stable per capacity, because they key the flat id
    # namespace and the rng table exactly as role ids did.
    SEAT_PREFIX = "crew_"

    module_function

    # `[:crew_1, :crew_2]` for a capacity of two. Ordinal rather than named: "the first person
    # you brought" is a fact about the roster, where "the fireman" was a fact about the machine.
    def seats(capacity) = Array.new([ capacity.to_i, 0 ].max) { |i| :"#{SEAT_PREFIX}#{i + 1}" }

    def seat?(id) = id.to_s.start_with?(SEAT_PREFIX)

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
    # **A roster naming more seats than the operation has is refused, never truncated.**
    # Truncating silently discards somebody the player chose, which is the class of failure this
    # codebase keeps writing rules against — and the cause is always a real mismatch: a
    # downgraded quarters, or a snapshot predating a capacity change.
    def normalise(crew, capacity:)
      crew = (crew || {}).to_h { |k, v| [ k.to_sym, v ] }
      available = seats(capacity)

      # **Every unrecognised key raises, not just seat-shaped ones.** A roster that named a job
      # (`fireman`) rather than a seat would otherwise resolve to a full complement of standins
      # and look like a machine nobody had crewed — which is precisely the silent substitution
      # this release exists to remove. The delivery tier decides what to do about a stale stored
      # roster; the library's answer is to say so.
      extra = crew.keys - available
      if extra.any?
        raise Error, "roster names #{extra.join(', ')} but the fitted quarters seats " \
                     "#{available.length} (#{available.join(', ')})"
      end

      available.to_h do |seat|
        given = (crew[seat] || {}).to_h { |k, v| [ k.to_sym, v ] }
        [ seat, normalise_posting(given).freeze ]
      end.freeze
    end

    # **No `station:` here, deliberately.** Everybody starts in the quarters and is *sent*
    # somewhere, so deploying the shift is the opening move of a match rather than a field on a
    # form. A starting station in the posting is the same defect as filling every role: the
    # machine handing over, for free, the thing it was built to make scarce.
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
