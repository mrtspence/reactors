# frozen_string_literal: true

module ReactorSim
  # Somebody stood at a lever.
  #
  # A minion is the reason `ControlPoint` has both a `target` and an `actual`: a command says
  # where the lever should be, and a minion is what moves it there, at whatever rate they can
  # manage (docs/simulation_architecture.md §7). Without one the distinction is decorative.
  #
  # Shaped exactly like ControlPoint on purpose — frozen configuration plus pure transforms
  # over a state hash it does not own. Nothing here reads a clock or draws entropy; the one
  # place a minion is allowed to be unpredictable is phase 0, which is where `Tick` consults
  # them and where all actuation entropy already lives.
  #
  #   config: archetype (strength, from content), default station
  #   state:  health, fatigue, station
  class Minion
    attr_reader :id, :name, :archetype, :default_station

    # `station` here is the lever this minion *starts* at. Where they actually are lives in
    # state, because assignment is a command — hence the deliberately different name from
    # `#station(state)` below. Conflating the two would make a reassigned minion snap back to
    # their original post on the next restore.
    def initialize(id:, archetype:, name: nil, station: nil)
      @id = id.to_sym
      @archetype = archetype.to_sym
      @name = name || @id.to_s.tr("_", " ").capitalize
      @default_station = station&.to_sym
      freeze
    end

    # Health and fatigue start fixed rather than rolled. A minion who begins the match already
    # tired would be indistinguishable from one the player has worn out, which is exactly the
    # causality Wearing goes to such lengths to preserve elsewhere.
    #
    # TODO: expedient — the rng is unused, so every minion starts identical. A proper
    # implementation rolls condition (and probably a hidden aptitude) from this stream, which
    # is already named per-minion and already snapshotted.
    def initial_state(_rng)
      { health: 1.0, fatigue: 0.0, station: @default_station }
    end

    def station(state) = state.fetch(:station)

    # How fast this minion can work a lever, as a multiple of its rated stiffness.
    #
    # Multiplicative rather than additive so the terms compose without needing to agree on a
    # scale: a strong minion who is exhausted is slow, and no term can rescue another. Clamped
    # at zero because a negative rate would drive the lever away from its target.
    def rate_multiplier(state, content)
      strength = content.minion_archetype(@archetype).fetch(:strength).to_f
      condition = state.fetch(:health) * (1.0 - state.fetch(:fatigue))

      [ strength * condition, 0.0 ].max
    end

    # Absolute, like every other command. Assigning the same station twice is a no-op, which
    # is what lets minion assignment ride the same at-least-once log as `set_control` without
    # a dedup table (docs/reference/invariants.md §4).
    def assign(state, station_id)
      state.merge(station: station_id&.to_sym)
    end
  end
end
