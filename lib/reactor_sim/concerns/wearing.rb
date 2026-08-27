# frozen_string_literal: true

module ReactorSim
  module Concerns
    # A node that can break.
    #
    # Durability is a depleting resource rather than accumulating wear. Same seeded hidden
    # starting value, sign flipped — but the flip matters: wear measured against a secret
    # maximum is literally undisplayable, whereas a depleting quantity can be shown through
    # bands and prose without ever revealing a number
    # (docs/simulation_architecture.md §7).
    #
    # Incidents are never a per-tick dice roll. Stress accumulates deterministically from
    # operating conditions and the node fails when durability hits zero, so a player can
    # learn "I ran it too hot for too long" rather than being told the dice disliked them.
    #
    #   config: durability_range, stress model (via #stress_per_second)
    #   state:  durability, broken
    module Wearing
      DEFAULT_DURABILITY_RANGE = (850.0..1150.0)

      def wearing_initial_state(rng, _content)
        rolled = rng.between(durability_range.begin, durability_range.end)
        # The starting value is kept so `integrity` can be a fraction. The player never
        # sees either number; hiding the roll is what keeps the failure point uncertain.
        { durability: rolled, initial_durability: rolled, broken: false }
      end

      def durability_range = DEFAULT_DURABILITY_RANGE

      # Subclasses override. Returns durability units consumed per simulated second under
      # the given conditions; 0.0 while operating within limits.
      def stress_per_second(_state, _ctx) = 0.0

      # Some things wear out. Others simply let go.
      #
      # Fatigue is the default and the right model for most failures — it is what lets a
      # player learn "I ran it too hot for too long". But a brittle part past its tensile
      # limit does not gradually deteriorate; it fails, now, on the tick the limit was
      # passed. Forcing that through durability accumulation would misrepresent it.
      #
      # Override to return true when the current conditions exceed what the part can take
      # at all. `integrity` is passed so the threshold can be scaled by remaining
      # durability — a worn wheel bursts sooner than a new one, which keeps the accumulated
      # history meaningful rather than discarding it.
      def overload?(_state, _ctx, _integrity) = false

      # Returns [next_state, events].
      def apply_wear(state, ctx)
        return [ state, [] ] if state.fetch(:broken)

        if overload?(state, ctx, integrity(state))
          return [ state.merge(durability: 0.0, broken: true),
                   [ failure_event(state, ctx).merge(cause: :overload) ] ]
        end

        lost = stress_per_second(state, ctx) * ctx.dt
        return [ state, [] ] if lost <= 0.0

        remaining = state.fetch(:durability) - lost
        return [ state.merge(durability: remaining), [] ] if remaining.positive?

        [ state.merge(durability: 0.0, broken: true),
          [ failure_event(state, ctx).merge(cause: :fatigue) ] ]
      end

      # Remaining durability as a fraction of what this part started with, 0..1. Never
      # shown as a number — diagnostics band it and put it into prose.
      def integrity(state)
        start = state.fetch(:initial_durability, nil)
        return 1.0 if start.nil? || start <= 0.0

        (state.fetch(:durability) / start).clamp(0.0, 1.0)
      end

      def failure_event(state, ctx)
        { type: failure_type,
          node: id,
          label: label,
          severity: :critical,
          tick: ctx.tick,
          detail: failure_detail(state, ctx) }
      end

      def failure_type = :"#{id}_failure"
      def failure_detail(_state, _ctx) = {}
    end
  end
end
