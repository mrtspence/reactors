# frozen_string_literal: true

module ReactorSim
  # Somebody stood at a lever.
  #
  # Shaped like `ControlPoint`: frozen configuration plus pure transforms over a state hash it
  # does not own. Nothing here reads a clock or draws entropy.
  #
  #   config: a RESOLVED sheet — stats and tags, all four layers already folded — plus who they
  #           are, which job they hold, and the station they start at
  #   state:  health, fatigue, posting, station, place, progress, remaining, journey,
  #           resilience, injury
  #
  # **`posting` is where they have been SENT; `station` is what they are actually working.** In an
  # operation with no geometry the two are always equal and the distinction costs nothing. Where
  # there is geometry they differ for as long as the walk takes, and that gap is the point: a
  # shift ordered to the far district is a shift that is not at the face yet.
  #
  # **`id` is the JOB and `minion` is the person.** `:fireman` is what the steam engine asks for;
  # Jim is who turned up.
  class Minion
    attr_reader :id, :name, :minion, :archetype, :stats, :tags, :default_station, :default_place

    # What a journey draws on. Blended for the same reason every `effort:` is, and it runs
    # through `capability`, so fatigue and injury slow a walk exactly as they slow a shovel — a
    # spent minion stops where they stand until they have rested.
    #
    # > **Deliberately NOT `endurance`, however obviously walking is an endurance job.**
    # > `endurance` is a *divisor* in `Fatigue.accrual` and enters no capability blend, which is
    # > what lets `spec/support/reference_crew.rb` set it to 1e6 to make a reference hand
    # > tireless without moving a single throughput baseline. Put it in a blend and that fixture
    # > walks at seven hundred thousand times human pace, and every spec built on it is wrong in
    # > a way that looks like a physics bug. Weights still sum to 1.0, so a competent unaided
    # > human paces exactly 1.0.
    PACE = { strength: 0.6, toughness: 0.4 }.freeze

    # **Stats arrive folded, never looked up.** A content lookup per manned lever per tick, for a
    # number that cannot change during a match, is waste — and folding at build puts training and
    # equipment behind one boundary: `Crew.resolve` is the only thing that knows a player owns
    # anything, and nothing on the tick path can learn it.
    #
    # `station:` is the lever this minion *starts* at; where they actually are lives in state,
    # because assignment is a command — hence the different name from `#station(state)`.
    # Conflating them makes a reassigned minion snap back to their original post on restore.
    def initialize(id:, name: nil, minion: nil, archetype: nil, stats: {}, tags: {},
                   station: nil, place: nil)
      @default_place = place&.to_sym
      @id = id.to_sym
      @minion = minion&.to_sym
      @archetype = archetype&.to_sym
      @name = name || @id.to_s.tr("_", " ").capitalize
      @stats = Sheet::STATS.to_h { |stat| [ stat, stats.fetch(stat, 0.0).to_f ] }.freeze
      @tags = tags.to_h { |k, v| [ k.to_sym, v ] }.freeze
      @default_station = station&.to_sym
      freeze
    end

    # Named rather than `stats[:x]` at call sites, so a typo is a NoMethodError rather than a
    # nil that quietly becomes zero somewhere downstream.
    Sheet::STATS.each { |stat| define_method(stat) { @stats.fetch(stat) } }

    # Valued, and absent means zero — which is what makes `tag(:clumsy)` safe to read anywhere
    # without asking first. `true` is a trait that is simply present.
    def tag(key) = @tags.fetch(key.to_sym, 0.0)

    def tag?(key) = !@tags.fetch(key.to_sym, nil).nil?

    # Health and fatigue start fixed rather than rolled: a minion who begins already tired would
    # be indistinguishable from one the player has worn out.
    #
    # **`resilience` is the exception, and it is the whole of the Danger Check's uncertainty.**
    # Rolled here — one of the three places entropy is permitted — so every check afterwards is a
    # deterministic comparison, which makes injuries replayable, order-independent and
    # snapshot-safe at no cost. See `Injury`.
    def initial_state(rng)
      { health: 1.0, fatigue: 0.0, spent: false, asphyxia: 0.0,
        apparatus: Injury.numeric(tag(:respirator_air)),
        posting: @default_station, station: @default_station,
        place: @default_place, progress: 0.0, remaining: 0.0, journey: 0.0 }
        .merge(Injury.initial_state(rng, toughness))
    end

    def station(state) = state.fetch(:station)

    def posting(state) = state.fetch(:posting, nil)

    def place(state) = state.fetch(:place, nil)

    # How fast this minion covers ground, as a multiple of a competent unaided human.
    def pace(state) = capability(state, effort: PACE)

    # Which gated passages this minion may use. Read once at build to pick their routing table,
    # so nothing searches tags during a tick.
    def capabilities(gates)
      gates.select { |tag| tag?(tag) && Injury.numeric(tag(tag)).positive? }.freeze
    end

    # How fast this minion can work a lever, as a multiple of its rated stiffness. Multiplicative
    # so the terms compose without agreeing on a scale and no term can rescue another: a strong
    # minion who is exhausted AND hurt is slower than either alone. Clamped at zero, because a
    # negative rate would drive the lever away from its target.
    def rate_multiplier(state, _content = nil)
      condition = state.fetch(:health) * (1.0 - state.fetch(:fatigue))

      [ strength * condition * Injury.derating(state, :strength), 0.0 ].max
    end

    # What this minion is actually worth at a stat right now, injury included. Named so a caller
    # cannot forget the derating by reading `minion.strength` and getting the fresh figure.
    def effective(stat, state) = @stats.fetch(stat, 0.0) * Injury.derating(state, stat)

    # **What they get done at a job, as a multiple of a competent human — the rate, not a rate of
    # change.** A work station's lever is the player's intent; this is what comes of it. 1.0 is a
    # fit, unaided human, so a station's declared throughput is what such a person achieves and
    # somebody better *exceeds* it rather than reaching it sooner.
    #
    # `effort` is a weighted blend, because almost no real job draws on one stat. The weights sum
    # to 1.0 (`ControlPoint` refuses otherwise), which keeps that baseline true at every station.
    #
    # `blend × (1 + aid)` rather than `blend + aid`, so a specialised tool is worth more in
    # capable hands. Condition and injury multiply in too, which makes a hurt fireman a worse
    # fireman rather than merely a slower one.
    #
    # **`condition` is also what makes fatigue a runaway.** `Fatigue` accrues on
    # `intent ÷ capability`, so a tiring worker's falling capability raises their own load and
    # tires them faster still — true of people, and why `Fatigue::LOAD_CEILING` has to exist.
    # `gated_by:` is the other kind of help entirely, and the difference matters. `aided_by:`
    # **adds**: a shovel makes shovelling better and its absence makes it merely unaided.
    # `gated_by:` **multiplies**, and a missing tag is therefore a zero — which is the honest
    # model of a job that cannot be done at all without the thing.
    #
    # Hewing is gated on `mining_effectiveness` and `darkvision`: an ogre with no pick gets no
    # coal out of a seam however strong they are, and nobody gets any in the dark. A crude kit
    # and a tallow candle is a punishing 0.25 × 0.45; a proper pick and a Davy lamp is 0.8 × 1.0.
    # That spread is the whole reason equipment is worth buying.
    # `ambient:` is what the ROOM supplies toward the same gates — light on the roadway against
    # a lamp on your belt. See `Tick#ambient_tags`.
    def capability(state, effort:, aided_by: nil, gated_by: nil, ambient: nil)
      condition = state.fetch(:health) * (1.0 - state.fetch(:fatigue))
      blended = effort.sum { |stat, weight| effective(stat, state) * weight }
      aid = aided_by ? Injury.numeric(tag(aided_by)) : 0.0

      [ blended * (1.0 + aid) * gate(gated_by, ambient) * condition, 0.0 ].max
    end

    # One for a job that needs nothing, so a station declaring no gates is unchanged.
    #
    # **The better of what you carry and what the room gives, never the sum.** Two lamps do not
    # let you see twice, and adding them would make a well-lit district turn a blind minion into
    # a better hewer than a sighted one somewhere dark.
    def gate(tags, ambient = nil)
      return 1.0 if tags.nil? || tags.empty?

      tags.reduce(1.0) do |acc, key|
        acc * [ Injury.numeric(tag(key)), Injury.numeric(ambient&.fetch(key, nil)) ].max
      end
    end

    def injured?(state) = !state.fetch(:injury, nil).nil?

    # Absolute, like every other command. Assigning the same station twice is a no-op, which
    # is what lets minion assignment ride the same at-least-once log as `set_control` without
    # a dedup table (docs/reference/invariants.md §4).
    #
    # **The command names a destination and never a journey.** `arrived:` is the operation
    # telling this minion whether they are already standing where they have been sent — always
    # true where there is no geometry, so this stays exactly what it was. Where there is, they
    # leave their post at once and the walk happens inside the tick, which is what keeps an
    # at-least-once log safe: replaying "be at the far face" is still idempotent, while
    # replaying "take a step" would not be.
    #
    # `progress` deliberately survives a reassignment. Somebody part-way along a roadway when
    # their orders change finishes that stretch and re-routes from the other end; they do not
    # snap back to where they set off from.
    def assign(state, station_id, arrived: true)
      station = station_id&.to_sym

      state.merge(posting: station, station: arrived ? station : nil)
    end

    # Where a journey has got to: `progress` along the passage currently being walked,
    # `remaining` to the far end of the whole walk.
    #
    # `journey` is set before the walking (see `Tick#walk`) and only cleared here, on arrival.
    def advance_to(state, place:, progress:, remaining:, station: nil)
      arrived = !station.nil? || remaining <= 0.0

      state.merge(place: place, progress: progress,
                  remaining: arrived ? 0.0 : remaining,
                  journey: arrived ? 0.0 : state.fetch(:journey, 0.0),
                  station: station)
    end

    # Nought to one across the walk they were sent on, and zero for somebody standing still.
    def journey_fraction(state)
      journey = state.fetch(:journey, 0.0)
      return 0.0 unless journey.positive?

      (1.0 - (state.fetch(:remaining, 0.0) / journey)).clamp(0.0, 1.0)
    end
  end
end
