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
    #   state:  durability, initial_durability, failure
    module Wearing
      DEFAULT_DURABILITY_RANGE = (850.0..1150.0)

      # What a part becomes when its class has not said otherwise.
      #
      # `failure` is a MODE, not a boolean, and that is the whole point of it: "broken" cannot
      # distinguish a seam weeping steam from a drum letting go, and those are the two ends of
      # the only interesting axis a failure has. A node names its own mode; this is the
      # fallback, and a fallback that nothing overrides is a part with no failure story.
      # See docs/design_sketches/failure_model.md.
      GENERIC_FAILURE = :failed

      def wearing_initial_state(rng, _content)
        rolled = rng.between(durability_range.begin, durability_range.end)
        # The starting value is kept so `integrity` can be a fraction. The player never
        # sees either number; hiding the roll is what keeps the failure point uncertain.
        { durability: rolled, initial_durability: rolled, failure: nil }
      end

      def durability_range = DEFAULT_DURABILITY_RANGE

      # The modes this part can enter, **in ascending order of severity**.
      #
      # The order is load-bearing and it is the hash's own insertion order, because Ruby
      # preserves it — so the escalation ordering needs no second declaration that could
      # disagree with the first. `escalate_to` only ever moves forward through this list.
      #
      # The values are the consequences each mode carries — a breach fraction, a derating,
      # damage to its neighbours. **Nothing consumes them yet**; they are staged in
      # docs/design_sketches/failure_model.md §8. A node that declares no table at all has no
      # failure story, which `failure_spec` treats as a defect rather than a default.
      def failure_modes = { GENERIC_FAILURE => {} }

      # What this part became, decided at the moment it failed from the conditions at that
      # moment. Override to split on the cause, on how far past a rating the part went, or on
      # both — see `Nodes::Boiler`.
      def failure_mode(_state, _ctx, _cause) = failure_modes.keys.first

      # What this part takes with it, per mode: `{ mode => { node_id => share } }`, where the
      # share is of that node's *starting* durability so the same figure means the same thing
      # to a light fitting and a heavy one.
      #
      # **Wiring, not physics, which is why it is separate from `failure_modes`.** That a drum
      # letting go wrecks what is around it belongs to the class; *what* is around it belongs to
      # the machine, and a node under `nodes/` may not know that a `:cylinder` exists. So the
      # modes are declared in the class and their casualties are configured per instance.
      # `Tick#spread_damage` spends it; see docs/design_sketches/failure_model.md §6 for why
      # this is fiat rather than a release-energy model.
      def failure_damages = {}

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
      #
      # A strict fetch, unlike `Node#broken?`: anything reaching here included this concern, so
      # a missing key is a wiring mistake and a loud one is far cheaper to find. `broken?` is
      # the lenient reader because it is asked about nodes that never wear out at all.
      #
      # ## A broken part keeps being evaluated
      #
      # This used to return early on a failed node, and that was a footgun rather than an
      # optimisation: **an early, mild failure must never immunise a part against a
      # catastrophic one.** A cracked pipe that goes on being fed should be able to tear open;
      # a reactor that has lost a seal must still be able to melt down. Left as it was, the
      # first failure a part suffered was the last thing that could ever happen to it, which
      # makes a minor failure a *safe harbour* on exactly the machines where that is most
      # wrong.
      #
      # **Fatigue cannot escalate; overload can.** Durability is already spent once a part has
      # failed, so `stress_per_second` has nothing left to consume — which is the right story
      # anyway: a split drum that keeps being fired reaches bursting conditions, and one that
      # has been shut down does not.
      def apply_wear(state, ctx)
        unless state.fetch(:failure).nil?
          return overload?(state, ctx, integrity(state)) ? break_part(state, ctx, :overload) : [ state, [] ]
        end

        return break_part(state, ctx, :overload) if overload?(state, ctx, integrity(state))

        lost = stress_per_second(state, ctx) * ctx.dt
        return [ state, [] ] if lost <= 0.0

        remaining = state.fetch(:durability) - lost
        return [ state.merge(durability: remaining), [] ] if remaining.positive?

        break_part(state, ctx, :fatigue)
      end

      # The one place a part's failure changes — sound to failed, or failed to worse. Both
      # causes and both directions land here so that naming the mode is a single decision
      # rather than several that can drift apart.
      #
      # **An event is emitted only on a transition.** Recomputing the mode every tick without
      # this would announce the same failure at the tick rate, forever.
      def break_part(state, ctx, cause)
        was = state.fetch(:failure)
        mode = escalate_to(was, failure_mode(state, ctx, cause))
        return [ state, [] ] if mode == was

        [ state.merge(durability: 0.0, failure: mode),
          [ failure_event(state, ctx).merge(cause: cause, mode: mode, escalated_from: was).compact ] ]
      end

      # Severity is the ORDER of `failure_modes`, so a part that has exploded can never relax
      # back into a seam split — which is what a re-evaluated `failure_mode` would otherwise do
      # the moment the conditions that destroyed it subsided, and a drum whose pressure has
      # gone to zero through its own hole is precisely that case.
      #
      # A mode the table does not name sorts last. It is a node saying something its own
      # declaration does not describe, and quietly discarding that would hide the bug rather
      # than the symptom; `failure_spec` is what stops it happening in the first place.
      def escalate_to(current, proposed)
        return proposed if current.nil?

        order = failure_modes.keys
        [ current, proposed ].max_by { |mode| order.index(mode) || order.length }
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
