# frozen_string_literal: true

module ReactorSim
  module Mechanisms
    # A reagent reservoir and its pump. The simplest mechanism in the game: one lever,
    # one output, one way to break it.
    class ReagentFeed < Mechanism
      MAX_RATE      = 12.0  # units/sec at 100% throttle
      RESERVOIR     = 900.0
      CAVITATION_AT = 85.0  # running the pump above this wears it out
      WEAR_RATE     = 0.010 # wear per second at full cavitation

      attr_reader :control_id, :out_buffer

      def initialize(id:, label:, control_id:, out_buffer:)
        super(id: id, label: label)
        @control_id = control_id
        @out_buffer = out_buffer
      end

      def initial_state(rng)
        {
          reservoir: RESERVOIR,
          delivered: 0.0,
          wear: 0.0,
          threshold: roll_threshold(rng),
          failed: false
        }
      end

      def step(state, ctx)
        return idle(state) if state.fetch(:failed)

        rate = ctx.controls.fetch(@control_id, 0.0)
        wanted = (rate / 100.0) * MAX_RATE * ctx.dt
        delivered = [ wanted, state.fetch(:reservoir) ].min

        wear = state.fetch(:wear) + cavitation_wear(rate, ctx.dt)
        failed = wear >= state.fetch(:threshold)

        next_state = state.merge(
          reservoir: state.fetch(:reservoir) - delivered,
          delivered: delivered,
          wear: wear,
          failed: failed
        )

        Result.new(
          state: next_state,
          pushes: { @out_buffer => delivered },
          events: failed ? [ failure_event(next_state, :pump_seizure) ] : []
        )
      end

      private

      def cavitation_wear(rate, dt)
        return 0.0 if rate <= CAVITATION_AT

        severity = (rate - CAVITATION_AT) / (100.0 - CAVITATION_AT)
        severity * WEAR_RATE * dt
      end

      def idle(state)
        Result.new(state: state.merge(delivered: 0.0), pushes: { @out_buffer => 0.0 })
      end
    end
  end
end
