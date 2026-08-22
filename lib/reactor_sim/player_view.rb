# frozen_string_literal: true

module ReactorSim
  # The only thing that ever leaves the simulation.
  #
  # Produced by Operation#project. Two flavours: :player gets the delayed, noisy,
  # clamped instrument readings; :spectator gets a god-view of the truth. Both are
  # projections — even the god-view goes through here rather than exposing raw state,
  # which keeps the door open for a shadow-a-player spectator mode later.
  PlayerView = Struct.new(:tick, :operation_id, :viewer, :gauges, :controls, :incidents, :power,
                          keyword_init: true) do
    def to_h
      {
        tick: tick,
        operation_id: operation_id,
        viewer: viewer,
        gauges: gauges,
        controls: controls,
        incidents: incidents,
        power: power
      }
    end

    # Only what changed since the previous view. This is what actually goes over the
    # wire each tick (docs/architecture.md §7); the full view is sent on subscribe
    # and on resync.
    def delta_from(previous)
      return to_h if previous.nil?

      changed = gauges.reject { |id, value| previous.gauges[id] == value }
      controls_changed = controls.reject { |id, value| previous.controls[id] == value }

      {
        tick: tick,
        changed: changed,
        controls: controls_changed,
        incidents: incidents,
        power: power
      }
    end
  end
end
