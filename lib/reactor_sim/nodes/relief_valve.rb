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
                  :ease_control_id

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
                     senses_quantity: :pressure_pa, ease_control_id: nil, **options)
        super(id: id, one_way: true, **options)
        @senses = senses.to_sym
        @senses_quantity = senses_quantity.to_sym
        @relief_pressure_pa = relief_pressure_pa.to_f
        # Fully open a quarter above the setting unless told otherwise.
        @full_open_pressure_pa = (full_open_pressure_pa || (@relief_pressure_pa * 1.25)).to_f
        # The easing lever. See `open_fraction`.
        @ease_control_id = ease_control_id&.to_sym
        freeze
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

      # 0 below the setting, ramping to 1 by the full-open pressure.
      def lift(ctx)
        sensed = ctx.node_reading(@senses, @senses_quantity)
        return 0.0 if sensed.nil? || sensed <= @relief_pressure_pa

        span = @full_open_pressure_pa - @relief_pressure_pa
        return 1.0 if span <= 0.0

        ((sensed - @relief_pressure_pa) / span).clamp(0.0, 1.0)
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
      def apply(state, ctx, _grant)
        state.merge(lift: open_fraction(ctx))
      end
    end
  end
end
