# frozen_string_literal: true

module ReactorSim
  # Somebody stood at a lever.
  #
  # Shaped like `ControlPoint`: frozen configuration plus pure transforms over a state hash it
  # does not own. Nothing here reads a clock or draws entropy.
  #
  #   config: a RESOLVED sheet — stats and tags, all four layers already folded — plus who they
  #           are, which job they hold, and the station they start at
  #   state:  health, fatigue, station, resilience, injury
  #
  # **`id` is the JOB and `minion` is the person.** `:fireman` is what the steam engine asks for;
  # Jim is who turned up.
  class Minion
    attr_reader :id, :name, :minion, :archetype, :stats, :tags, :default_station

    # **Stats arrive folded, never looked up.** A content lookup per manned lever per tick, for a
    # number that cannot change during a match, is waste — and folding at build puts training and
    # equipment behind one boundary: `Crew.resolve` is the only thing that knows a player owns
    # anything, and nothing on the tick path can learn it.
    #
    # `station:` is the lever this minion *starts* at; where they actually are lives in state,
    # because assignment is a command — hence the different name from `#station(state)`.
    # Conflating them makes a reassigned minion snap back to their original post on restore.
    def initialize(id:, name: nil, minion: nil, archetype: nil, stats: {}, tags: {},
                   station: nil)
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
      { health: 1.0, fatigue: 0.0, spent: false, station: @default_station }
        .merge(Injury.initial_state(rng, toughness))
    end

    def station(state) = state.fetch(:station)

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
    def capability(state, effort:, aided_by: nil)
      condition = state.fetch(:health) * (1.0 - state.fetch(:fatigue))
      blended = effort.sum { |stat, weight| effective(stat, state) * weight }
      aid = aided_by ? Injury.numeric(tag(aided_by)) : 0.0

      [ blended * (1.0 + aid) * condition, 0.0 ].max
    end

    def injured?(state) = !state.fetch(:injury, nil).nil?

    # Absolute, like every other command. Assigning the same station twice is a no-op, which
    # is what lets minion assignment ride the same at-least-once log as `set_control` without
    # a dedup table (docs/reference/invariants.md §4).
    def assign(state, station_id)
      state.merge(station: station_id&.to_sym)
    end
  end
end
