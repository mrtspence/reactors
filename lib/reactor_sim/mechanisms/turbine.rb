# frozen_string_literal: true

module ReactorSim
  module Mechanisms
    # Converts vented steam into power — the operation's actual product.
    #
    # RPM follows a first-order lag rather than tracking steam directly, so the
    # turbine keeps spinning after the steam stops and takes time to spool up. That
    # lag is another thing the overseer has to lead rather than react to.
    class Turbine < Mechanism
      # Matched to the vessel's relief vent (VENT_RATE) so that a fully open throttle
      # can just about keep up with a fully venting vessel. Anything less and the steam
      # line backs up, which the vessel feels as pressure.
      MAX_STEAM       = 40.0   # units/sec consumed at full throttle
      MAX_RPM         = 3600.0
      SPOOL_RATE      = 0.9    # how fast rpm converges on target, per second
      POWER_PER_RPM   = 0.85
      REDLINE         = 3100.0
      WEAR_RATE       = 0.075

      attr_reader :control_id, :in_buffer

      def initialize(id:, label:, control_id:, in_buffer:)
        super(id: id, label: label)
        @control_id = control_id
        @in_buffer = in_buffer
      end

      def initial_state(rng)
        {
          rpm: 0.0,
          power: 0.0,
          steam_drawn: 0.0,
          wear: 0.0,
          threshold: roll_threshold(rng),
          failed: false
        }
      end

      def step(state, ctx)
        return seized(state, ctx.dt) if state.fetch(:failed)

        throttle = ctx.controls.fetch(@control_id, 0.0)
        wanted = (throttle / 100.0) * MAX_STEAM * ctx.dt
        drawn = [ ctx.available.fetch(@in_buffer, 0.0), wanted ].min

        target = (drawn / (MAX_STEAM * ctx.dt)) * MAX_RPM
        rpm = spool(state.fetch(:rpm), target, ctx.dt)

        wear = state.fetch(:wear) + overspeed_wear(rpm, ctx.dt)
        failed = wear >= state.fetch(:threshold)

        next_state = state.merge(
          rpm: rpm,
          power: rpm * POWER_PER_RPM,
          steam_drawn: drawn,
          wear: wear,
          failed: failed
        )

        Result.new(
          state: next_state,
          draws: { @in_buffer => drawn },
          events: failed ? [ failure_event(next_state, :turbine_failure, rpm: rpm) ] : []
        )
      end

      private

      def spool(rpm, target, dt)
        rpm + (target - rpm) * SPOOL_RATE * dt
      end

      def overspeed_wear(rpm, dt)
        return 0.0 if rpm <= REDLINE

        ((rpm - REDLINE) / (MAX_RPM - REDLINE)) * WEAR_RATE * dt
      end

      # A failed turbine coasts to a stop and produces nothing.
      def seized(state, dt)
        rpm = [ state.fetch(:rpm) - MAX_RPM * 0.5 * dt, 0.0 ].max
        Result.new(state: state.merge(rpm: rpm, power: 0.0, steam_drawn: 0.0))
      end
    end
  end
end
