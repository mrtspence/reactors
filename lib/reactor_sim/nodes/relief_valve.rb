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
      attr_reader :senses, :relief_pressure_pa, :full_open_pressure_pa

      def initialize(id:, senses:, relief_pressure_pa:, full_open_pressure_pa: nil, **options)
        super(id: id, **options)
        @senses = senses.to_sym
        @relief_pressure_pa = relief_pressure_pa.to_f
        # Fully open a quarter above the setting unless told otherwise.
        @full_open_pressure_pa = (full_open_pressure_pa || (@relief_pressure_pa * 1.25)).to_f
      end

      # Opens on sensed pressure rather than on a lever. A control point can still be fitted
      # to gag it shut, which is exactly the sort of decision that gets people killed.
      def plan(state, ctx)
        return Intent.none if broken?(state)

        opening = lift(ctx)
        return Intent.none if opening <= 0.0

        held = contents_kg(state)
        Intent.new(
          draws: { inlet: [ (port(:outlet).capacity_kg(ctx.dt) * opening) - held, 0.0 ].max },
          pushes: { outlet: held }
        )
      end

      # 0 below the setting, ramping to 1 by the full-open pressure.
      def lift(ctx)
        sensed = ctx.node_pressure(@senses)
        return 0.0 if sensed.nil? || sensed <= @relief_pressure_pa

        span = @full_open_pressure_pa - @relief_pressure_pa
        return 1.0 if span <= 0.0

        ((sensed - @relief_pressure_pa) / span).clamp(0.0, 1.0)
      end

      def lifting?(ctx) = lift(ctx).positive?
    end
  end
end
