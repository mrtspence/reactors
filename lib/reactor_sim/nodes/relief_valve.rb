# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A valve that opens itself when the pressure behind it gets too high. A conduit that senses
    # a node's pressure and opens progressively above its setting, so it feathers rather than
    # slams.
    #
    # It is not meant to be relied on: whatever blows off is product going to waste, and the vent
    # has a finite throat — overwhelm it and the vessel still bursts.
    #
    # Deliberately a NODE rather than a property of the vessel, so it can be sized wrongly, wired
    # to the wrong place, and — once linkages can fail — jam shut.
    class ReliefValve < Conduit
      attr_reader :senses, :senses_quantity, :relief_pressure_pa, :full_open_pressure_pa,
                  :ease_control_id, :setting_control_id, :max_relief_pressure_pa

      # Always a check valve: a safety valve lets a vessel breathe out and must never let it
      # breathe in.
      #
      # `senses_quantity:` because **the pressure that destroys a thing is not always the
      # pressure it reports.** A boiler is threatened by its plain vessel pressure; a cylinder is
      # destroyed by what its charge reaches at top dead centre, which no lumped body experiences
      # directly. A valve pointed at the wrong quantity is worse than none, because it looks like
      # protection.
      def initialize(id:, senses:, relief_pressure_pa:, full_open_pressure_pa: nil,
                     senses_quantity: :pressure_pa, ease_control_id: nil,
                     setting_control_id: nil, max_relief_pressure_pa: nil, **options)
        super(id: id, one_way: true, **options)
        @senses = senses.to_sym
        @senses_quantity = senses_quantity.to_sym
        @relief_pressure_pa = relief_pressure_pa.to_f
        # Fully open a quarter above the setting unless told otherwise.
        @full_open_pressure_pa = (full_open_pressure_pa || (@relief_pressure_pa * 1.25)).to_f
        # The easing lever. See `open_fraction`.
        @ease_control_id = ease_control_id&.to_sym
        # The adjusting screw. See `setting_pa`.
        @setting_control_id = setting_control_id&.to_sym
        @max_relief_pressure_pa = (max_relief_pressure_pa || @relief_pressure_pa).to_f
        freeze
      end

      # **The adjusting screw: the margin is the player's to spend.** A third lever and a third
      # distinct thing — the other two open a valve that is already set, this decides where it is
      # set at all.
      #
      # It reads as **margin, not pressure**: 100 is the full safety margin and the setting the
      # part was designed around, 0 is the screw wound right down to `max_relief_pressure_pa`. It
      # defaults to the safe end, so an untouched engine is the safe engine and spending margin is
      # a choice. What it buys is power; what it costs is a crown sheet that fails sooner on the
      # same overheating (`crown_allowable_pressure_pa`), less headroom under the shell's rating,
      # and a driveline asked for work it may not survive.
      #
      # With no lever fitted this is the declared setting, so every other valve is unchanged.
      def setting_pa(ctx)
        return @relief_pressure_pa unless @setting_control_id

        margin = (ctx.controls.fetch(@setting_control_id, 100.0) / 100.0).clamp(0.0, 1.0)
        @relief_pressure_pa + ((1.0 - margin) * (@max_relief_pressure_pa - @relief_pressure_pa))
      end

      # Feathers open over the same proportional span the declared pair describes, so a valve wound
      # up keeps its character rather than becoming a different kind of valve.
      def full_open_pa(ctx)
        span = @full_open_pressure_pa / @relief_pressure_pa
        setting_pa(ctx) * span
      end

      # Opens on sensed pressure — but a valve has **two** kinds of lever, and they are not the
      # same part, so they do not compose the same way:
      #
      #     open = max(lift, easing) × gag
      #
      # `ease_control_id:` is the **easing lever** that lifts it by hand. It can only open the
      # valve further than the spring already has, hence `max`: blowing pressure down
      # deliberately is a real operating decision, holding a safety valve shut is not something a
      # handle should do. `control_id:` is the **gag**, and it multiplies — it can shut the valve
      # completely, which is the sort of decision that gets people killed and is therefore
      # available.
      def open_fraction(ctx) = [ lift(ctx), eased(ctx) ].max * super

      # How far the driver has pulled the easing lever, 0 with no lever fitted.
      def eased(ctx)
        return 0.0 unless @ease_control_id

        (ctx.controls.fetch(@ease_control_id, 0.0) / 100.0).clamp(0.0, 1.0)
      end

      # 0 below the setting, ramping to 1 by the full-open pressure. Reads `setting_pa` rather than
      # the declared figure, so the adjusting screw actually moves the valve.
      def lift(ctx)
        sensed = ctx.node_reading(@senses, @senses_quantity)
        setting = setting_pa(ctx)
        return 0.0 if sensed.nil? || sensed <= setting

        span = full_open_pa(ctx) - setting
        return 1.0 if span <= 0.0

        ((sensed - setting) / span).clamp(0.0, 1.0)
      end

      def lifting?(ctx) = lift(ctx).positive?

      # Simulated seconds of quiet before a second blow-off counts as a new episode.
      #
      # **A latch with no hysteresis chatters, and hysteresis on the PRESSURE is not enough.** A
      # valve sensing `compression_pressure_pa` — a per-stroke pressure reconstructed from crank
      # geometry, swinging through its whole range tick to tick — re-arms on every stroke, and a
      # 2% band around the setting produced 20 announcements in 40 ticks. That is four records a
      # second, the one thing the event system may not produce.
      #
      # A time hold does not care what the sensed quantity is doing: it reports what an observer
      # would say, that the valve was blowing off *between* two moments. Refreshed while the
      # valve is open, so a boiler sitting on its safety valve for an hour is one event.
      REARM_SECONDS = 30.0

      # **Record how far open it is, because otherwise nothing can gauge it.** A relief valve is
      # transport, so it holds no material and `Arbiter` leaves no trace of it in state — which
      # would leave the one part whose job is to act unsupervised the one part a player cannot
      # watch. `setting_pa` goes in too, so a player reads what the screw is wound to rather than
      # inferring it from a lever percentage.
      #
      # Pure: `open_fraction` reads the previous tick, so this records what the valve did rather
      # than predicting what it will do.
      def apply(state, ctx, _grant)
        state = state.merge(lift: open_fraction(ctx), setting_pa: setting_pa(ctx))

        # `lift`, not `open_fraction`, and the difference is the point: `open_fraction` also
        # counts the driver hauling on the easing lever, which is a person letting steam go
        # deliberately. Blowing off is the vessel reaching its setting on its own.
        lifted = lift(ctx).positive?
        held = state.fetch(:blow_off_hold_s, 0.0)
        state = state.merge(blow_off_hold_s: lifted ? REARM_SECONDS : [ held - ctx.dt, 0.0 ].max)
        return state unless lifted && held <= 0.0

        [ state,
          [ Event.build(type: :blew_off, node: id, label: label, severity: :notice,
                        tick: ctx.tick,
                        detail: { senses: @senses, quantity: @senses_quantity,
                                  setting_pa: setting_pa(ctx).round(1) }) ] ]
      end
    end
  end
end
