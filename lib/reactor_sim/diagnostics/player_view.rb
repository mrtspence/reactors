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
                          :incidents, keyword_init: true) do
    def to_h
      { tick:, operation_id:, viewer:, gauges:, flags:, controls:, incidents: }
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
        flags: flags.reject { |id, v| previous.flags[id] == v },
        controls: controls.reject { |id, v| previous.controls[id] == v },
        incidents: incidents }
    end

    # True when nothing at all moved. The runner can skip the broadcast entirely.
    def unchanged_from?(previous)
      return false if previous.nil?

      delta = delta_from(previous)
      delta[:gauges].empty? && delta[:flags].empty? &&
        delta[:controls].empty? && delta[:incidents].empty?
    end
  end
end
