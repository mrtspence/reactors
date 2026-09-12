# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A valve that opens itself when the pressure behind it gets too high.
    #
    # Papin fitted one to a steam digester in 1679, and the reasoning has not changed: what
    # fills a vessel rarely knows how fast it is being emptied. Left alone, anything with a
    # source at one end and a closed outlet at the other will keep pressurising until
    # something gives.
    #
    # Modelled as a conduit that senses a node's pressure and opens progressively above its
    # setting, so it feathers rather than slams. It is not meant to be relied on: whatever
    # blows off is product going to waste, and the vent has a finite throat. Overwhelm it
    # and the vessel still bursts.
    #
    # Deliberately a NODE rather than a property of the vessel. That means it can be sized
    # wrongly, wired to the wrong place, and — once linkages can fail — jam shut.
    class ReliefValve < Conduit
      attr_reader :senses, :senses_quantity, :relief_pressure_pa, :full_open_pressure_pa,
                  :ease_control_id, :setting_control_id, :max_relief_pressure_pa

      # Always a check valve. A safety valve lets a vessel breathe out and must never let it
      # breathe in — a boiler that could suck the atmosphere back through its own relief line
      # is not a boiler anyone would stand next to.
      #
      # `senses_quantity:` because **the pressure that destroys a thing is not always the
      # pressure it reports.** A boiler is threatened by its plain vessel pressure; a cylinder
      # is destroyed by the pressure its charge reaches at top dead centre, which is a
      # derivation and which no lumped body ever experiences directly. A relief valve pointed
      # at the wrong quantity is worse than none, because it looks like protection.
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

      # ## The adjusting screw: the margin is the player's to spend
      #
      # A third lever, and a third distinct thing — the other two open a valve that is already
      # set, this one decides **where it is set at all**. Real safety valves are adjustable and
      # winding them up to get more out of an engine is exactly the decision that blew boilers up
      # through the whole high-pressure era.
      #
      # The lever reads as **margin, not pressure**: 100 is the full safety margin and the setting
      # the part was designed around, 0 is the screw wound right down to
      # `max_relief_pressure_pa`. It defaults to the safe end so an untouched engine is the safe
      # engine, and spending margin is something a player has to choose to do.
      #
      # That framing matters for what it buys. More pressure is more power, and it is also:
      # a crown sheet that fails sooner on the same overheating (the plate's allowance is knocked
      # down by temperature, so a higher working pressure eats the margin — see
      # `crown_allowable_pressure_pa`), less headroom before the shell itself is over, and a
      # driveline being asked for work it may not survive. **On this engine the flywheel gives way
      # long before the boiler does**, which makes a stronger wheel the thing that actually unlocks
      # the upper half of this lever rather than the boiler being the gate.
      #
      # With no lever fitted this is just the declared setting, so every other valve is unchanged.
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

      # Opens on sensed pressure rather than on a lever — but a valve has **two** kinds of lever
      # and they are not the same part, so they do not compose the same way.
      #
      #     open = max(lift, easing) × gag
      #
      # `ease_control_id:` is the **easing lever**, the handle on the side of a Ramsbottom valve
      # that lifts it by hand. It can only ever open the valve further than the spring already
      # has, which is why it is a `max`: blowing pressure down deliberately is a real operating
      # decision, and holding a safety valve shut is not something a handle should be able to do.
      #
      # `control_id:` is the **gag**, and it multiplies — it can shut the valve completely, which
      # is exactly the sort of decision that gets people killed and is therefore available.
      #
      # This used to be a `plan` declaring draws and pushes. It is a valve opening now, because
      # a conduit is no longer an endpoint for material — the sensed pressure modulates how far
      # the path is open, which is what a relief valve physically does.
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

      # **Record how far open it is, because otherwise nothing can gauge it.** A relief valve is
      # transport, so it holds no material and `Arbiter` leaves no trace of it in state — which
      # meant the one part whose whole job is to act unsupervised was the one part a player had
      # no way to watch. A boiler blowing off is the loudest thing in the building and the panel
      # could not say so.
      #
      # Pure: `open_fraction` reads the previous tick through `ctx` exactly as it does during
      # transport, so this records what the valve did rather than predicting what it will do.
      # `setting_pa` goes in too, so a player can read what they have wound the screw to rather
      # than inferring it from a lever percentage.
      def apply(state, ctx, _grant)
        state.merge(lift: open_fraction(ctx), setting_pa: setting_pa(ctx))
      end
    end
  end
end
