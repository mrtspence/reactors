# frozen_string_literal: true

module ReactorSim
  # The only thing that ever leaves the simulation.
  #
  # Raw state never reaches a browser. Everything the client sees has been through a
  # Diagnostic, which is what keeps ground truth inside the engine and makes the client
  # legitimately dumb — a player with devtools open learns nothing they were not shown.
  #
  # Two flavours: `:player` gets the instruments as they actually read; `:spectator` gets a
  # god-view of the truth. Both are projections, and both go through the same path.
  PlayerView = Struct.new(:tick, :operation_id, :viewer, :gauges, :flags, :controls,
                          :incidents, :crew, keyword_init: true) do
    def to_h
      { tick:, operation_id:, viewer:, gauges:, flags:, controls:, incidents:, crew: }
    end

    # Only what changed since the last view. This is what actually goes over the wire each
    # tick; the full view is sent on subscribe and on resync (docs/architecture.md §7).
    #
    # Worth knowing what makes this work: the delta is only meaningful because noise is
    # held steady until the underlying value moves (Filters::Noise). With a fresh draw every
    # tick, every noisy gauge changed every tick and this compressed nothing.
    def delta_from(previous)
      return to_h if previous.nil?

      { tick: tick,
        gauges: gauges.reject { |id, v| previous.gauges[id] == v },
        flags: flag_delta(previous),
        controls: controls.reject { |id, v| previous.controls[id] == v },
        incidents: incidents,
        # **Not sparse, so a plain reject is honest here.** Every role is always present — an
        # unfilled one is filled by the standin — so unlike `flags` there is no "this entry
        # vanished" case to emit explicitly. A minion who is stood down has `station: nil`,
        # which is a value rather than an absence.
        crew: (crew || {}).reject { |id, v| previous.crew&.dig(id) == v } }
    end

    # True when nothing at all moved. The runner can skip the broadcast entirely.
    def unchanged_from?(previous)
      return false if previous.nil?

      delta = delta_from(previous)
      delta[:gauges].empty? && delta[:flags].empty? && delta[:controls].empty? &&
        delta[:incidents].empty? && delta[:crew].empty?
    end

    private

    # `flags` is SPARSE — an instrument with nothing to say has no key at all, because
    # Operation#project only writes the key when the flag list is non-empty.
    #
    # So rejecting unchanged entries is not enough: `reject` iterates the CURRENT flags, and
    # an instrument whose flags cleared is not in them. The cleared flag was therefore never
    # mentioned in the delta, and a client merging deltas went on showing `:pegged_high`
    # forever after a single pressure excursion. `:warming_up` was worse — every lagged gauge
    # raises it for its first few ticks, so a fresh panel lit up with warnings that could
    # never be retracted.
    #
    # Instruments that fell silent are emitted explicitly as an empty list, so a merge clears
    # them. This is what makes `unchanged_from?` honest too, since it reads this.
    def flag_delta(previous)
      changed = flags.reject { |id, v| previous.flags[id] == v }
      previous.flags.each_key { |id| changed[id] = [].freeze unless flags.key?(id) }
      changed
    end
  end
end
