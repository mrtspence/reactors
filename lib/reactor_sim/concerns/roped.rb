# frozen_string_literal: true

module ReactorSim
  module Concerns
    # **One end of a rope between two operations.**
    #
    # A rope is a viscous coupling of conductance `k` between two shafts, and each operation holds
    # one end of it. Each end sees the far end's speed **as of last tick**, written into its state
    # at the match's tick barrier (`Match#exchange!`), and treats it as a reservoir:
    #
    #   slower than the far end   a DRIVER — `k·(ω_far − ω)`, paid for from `supply_joules`, which
    #                             is what the far end sent
    #   faster than the far end   a BRAKE — the same law linearised as `τ(ω)/ω`; what it takes out
    #                             is booked to `:work` and sent to the far end
    #
    # So a shed load, an overrunning cage and a surging engine all cross the boundary with no rule
    # saying they do.
    #
    # **The braking end sends everything it takes; the driven end spends what its shaft
    # measurably gained** and loses the rest when its buffer overflows — which is the slip, booked
    # as friction where the rope is driving. Sending only `τ·ω_far` instead looks tidier and cannot
    # start a stopped shaft: at rest `ω_far` is zero, nothing is sent, and nothing ever turns.
    # Neither side trusts the other's arithmetic and the books close on each.
    #
    #   config: rope_capacity_joules, control_id (the clutch)
    #   state:  supply_joules, remote_omega (nil until coupled), remote_grip, rope_k
    module Roped
      def roped_initial_state(_rng, _content)
        { supply_joules: 0.0, remote_omega: nil, remote_grip: 1.0, rope_k: nil }
      end

      def roped?(state) = !state[:remote_omega].nil?

      # Carries its own rotor, so `transmit_torque` charges it directly.
      def drives = id

      def supply_joules(state) = state.fetch(:supply_joules, 0.0)

      def extractable_joules(state) = [ supply_joules(state), 0.0 ].max

      # **Deliberately unclamped**: `transmit_torque` never charges more than
      # `extractable_joules`, so a negative balance means the bill was computed wrong.
      def add_joules(state, joules, _content = nil)
        state.merge(supply_joules: supply_joules(state) + joules)
      end

      # What the far end sent, at the barrier. Returns `[state, wasted]`: anything past what this
      # end can hold has already left the far end's books, so it is wasted as friction here rather
      # than refused — the rope slipping against a shaft with nothing to drive.
      def receive(state, joules)
        total = supply_joules(state) + joules
        return [ state.merge(supply_joules: total), 0.0 ] if total <= rope_capacity_joules

        [ state.merge(supply_joules: rope_capacity_joules), total - rope_capacity_joules ]
      end

      # What the far end said about itself, at the barrier, in this end's frame.
      def hear(state, omega:, grip:, conductance:)
        state.merge(remote_omega: omega.to_f, remote_grip: grip.to_f, rope_k: conductance.to_f)
      end

      # How hard the rope is held: both clutches, this end's as actuated this tick and the far
      # end's as it was last tick. An end whose state says `tripped` has thrown its clutch out
      # whatever the lever says.
      def grip(state, ctx) = own_grip(state, ctx) * state.fetch(:remote_grip, 1.0)

      def own_grip(state, ctx)
        return 0.0 if state.fetch(:tripped, false)
        return 1.0 unless control_id

        (ctx.controls.fetch(control_id, 0.0) / 100.0).clamp(0.0, 1.0)
      end

      # The driver half. Nothing while starved: `transmit_torque` would scale it to nothing anyway,
      # and declaring it would read as a shaft being pushed.
      def rope_torque(state, ctx, conductance:, reservoir:)
        slip = reservoir - omega(state)
        return 0.0 unless slip.positive? && extractable_joules(state).positive?

        conductance * grip(state, ctx) * slip
      end

      # The brake half, coupled only: an end with nobody on the other side of it has nothing to
      # drag against.
      def rope_drags(state, ctx)
        return {} unless roped?(state)

        w = omega(state)
        far = state.fetch(:remote_omega)
        return {} unless w.positive? && w > far

        brake = [ state.fetch(:rope_k) * grip(state, ctx) * (w - far) / w,
                  max_drag_conductance(ctx.dt) ].min
        brake.positive? ? { rope: brake } : {}
      end

      # What this end reports at the barrier. `joules_roped` is only what the rope braked off —
      # booked apart from every other `:work` drag on the same shaft by `Tick#book_drive`.
      def rope_report(state, controls)
        lever = control_id ? (controls.fetch(control_id, 0.0) / 100.0).clamp(0.0, 1.0) : 1.0
        lever = 0.0 if state.fetch(:tripped, false)
        { omega: omega(state), grip: lever, joules: state.fetch(:joules_roped, 0.0) }
      end
    end
  end
end
