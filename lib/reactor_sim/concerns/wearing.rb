# frozen_string_literal: true

module ReactorSim
  module Concerns
    # A node that can break.
    #
    # **Durability is a depleting resource rather than accumulating wear**, because a depleting
    # quantity can be shown through bands and prose without revealing a number, where wear
    # against a secret maximum is undisplayable.
    #
    # **Incidents are never a per-tick dice roll.** Stress accumulates deterministically from
    # operating conditions and the node fails when durability hits zero, so a player learns "I
    # ran it too hot for too long" rather than being told the dice disliked them. The uncertainty
    # is the hidden starting roll.
    #
    #   config: durability_range, stress model (via #stress_per_second)
    #   state:  durability, initial_durability, failure
    module Wearing
      DEFAULT_DURABILITY_RANGE = (850.0..1150.0)

      # What a part becomes when its class has not said otherwise. `failure` is a MODE, not a
      # boolean: "broken" cannot distinguish a seam weeping steam from a drum letting go, which
      # is the only interesting axis a failure has. A part left on this fallback has no failure
      # story, and `failure_spec` treats that as a defect.
      GENERIC_FAILURE = :failed

      def wearing_initial_state(rng, _content)
        rolled = rng.between(durability_range.begin, durability_range.end)
        # The starting value is kept so `integrity` can be a fraction. The player never
        # sees either number; hiding the roll is what keeps the failure point uncertain.
        { durability: rolled, initial_durability: rolled, failure: nil }
      end

      def durability_range = DEFAULT_DURABILITY_RANGE

      # The modes this part can enter, **in ascending order of severity**. The order is the
      # hash's own insertion order, so the escalation ordering needs no second declaration that
      # could disagree with the first; `escalate_to` only moves forward through this list. The
      # values are the consequences each mode carries.
      def failure_modes = { GENERIC_FAILURE => {} }

      # What this part became, decided at the moment it failed from the conditions at that
      # moment. Override to split on the cause, on how far past a rating the part went, or on
      # both — see `Nodes::Boiler`.
      def failure_mode(_state, _ctx, _cause) = failure_modes.keys.first

      # How well this part still does `key`, given whatever has happened to it: 1.0 while sound,
      # 0.0 when the mode says it no longer does that thing at all.
      #
      # **What a derating MEANS is the node's business.** This only looks it up — the same
      # division `Obstructs` draws, where the concern hands you `occupancy` and stops, because a
      # cylinder and a firebox mean genuinely different things by it. A mode that names no
      # derating for `key` leaves the part fully capable of it, so a hole in the casing does not
      # accidentally imply a worn bore.
      def derating(state, key, default: 1.0)
        mode = state.fetch(:failure, nil)
        return default if mode.nil?

        failure_modes.dig(mode, :derates, key) || default
      end

      # What this part takes with it, per mode: `{ mode => { node_id => share } }`, the share
      # being of that node's *starting* durability, so one figure means the same to a light
      # fitting and a heavy one.
      #
      # **Configured per instance, not in `failure_modes`**, because everything under `nodes/` is
      # generic: which modes exist belongs to the class, but `Nodes::Boiler` cannot name a
      # `:cylinder` — a boiler in another machine has none near it. Spent by
      # `Tick#spread_damage`; see `docs/design_sketches/failure_model.md` §6 for why it is fiat
      # rather than a release-energy model.
      def failure_damages = {}

      # **What a failure does to the people near it**, declared like `failure_damages` and per
      # instance for the same reason:
      # `{ mode => { tags: [...], stations: { station_id => severity } } }`.
      #
      # **It names STATIONS, never minions.** A station is fixed by the machine; a roster is the
      # player's, so a part naming a minion would name something it cannot know. That also makes
      # it a coarse notion of *place* with no geometry — the machine knows which levers sit
      # beside which parts — which upgrades cleanly when volumes arrive.
      def failure_hazards = {}

      # Subclasses override. Returns durability units consumed per simulated second under
      # the given conditions; 0.0 while operating within limits.
      def stress_per_second(_state, _ctx) = 0.0

      # Some things wear out; others simply let go. Fatigue is the default and right for most
      # failures, but a brittle part past its tensile limit does not deteriorate — it fails on
      # the tick the limit was passed. Override to return true when conditions exceed what the
      # part can take at all. `integrity` is passed so the threshold scales with remaining
      # durability: a worn wheel bursts sooner than a new one.
      def overload?(_state, _ctx, _integrity) = false

      # Returns `[next_state, events]`.
      #
      # A strict fetch, unlike `Node#broken?`: anything reaching here included this concern, so a
      # missing key is a wiring mistake and a loud one is cheaper to find.
      #
      # **A broken part keeps being evaluated**, because an early, mild failure must never
      # immunise a part against a catastrophic one — a cracked pipe that goes on being fed should
      # be able to tear open. Returning early makes a minor failure a *safe harbour* on exactly
      # the machines where that is most wrong.
      #
      # **Fatigue cannot escalate; overload can.** Durability is already spent once a part has
      # failed, so `stress_per_second` has nothing left to consume — which is the right story: a
      # split drum that keeps being fired reaches bursting conditions, one shut down does not.
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

        # `damaged:` is what this mode takes with it, named on the event rather than left for a
        # reader to look up. A player watching a drum let go needs to be told it wrecked the
        # cylinder — otherwise the consequence arrives later as an unexplained second failure.
        harmed = failure_damages[mode]
        event = failure_event(state, ctx)
                .merge(cause: cause, mode: mode, escalated_from: was,
                       damaged: (harmed&.keys&.freeze unless harmed.nil? || harmed.empty?))
                .compact

        [ state.merge(durability: 0.0, failure: mode), [ event ] ]
      end

      # Severity is the ORDER of `failure_modes`, so a part that has exploded can never relax
      # back into a seam split — which is what a re-evaluated `failure_mode` would do the moment
      # the conditions that destroyed it subsided, and a drum whose pressure has gone to zero
      # through its own hole is exactly that case.
      #
      # A mode the table does not name sorts last: quietly discarding it would hide the bug
      # rather than the symptom. Delegated to `Severity`, which `Injury` shares, because a ladder
      # moving backwards in one path and not the other reads as a balance quirk, not a bug.
      def escalate_to(current, proposed)
        Severity.escalate(current, proposed, failure_modes.keys)
      end

      # Remaining durability as a fraction of what this part started with, 0..1. Never
      # shown as a number — diagnostics band it and put it into prose.
      def integrity(state)
        start = state.fetch(:initial_durability, nil)
        return 1.0 if start.nil? || start <= 0.0

        (state.fetch(:durability) / start).clamp(0.0, 1.0)
      end

      # **One type for every part failure, because `mode:` is the axis that matters.** A part
      # distinguishes itself through `node`, `mode` and `failure_detail`, none of which can drift
      # from a second list. See `ReactorSim::Event::TYPES`.
      def failure_event(state, ctx)
        Event.build(type: :part_failed,
                    node: id,
                    label: label,
                    severity: :critical,
                    tick: ctx.tick,
                    detail: failure_detail(state, ctx))
      end

      def failure_detail(_state, _ctx) = {}
    end
  end
end
