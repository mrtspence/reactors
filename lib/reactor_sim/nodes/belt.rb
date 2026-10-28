# frozen_string_literal: true

module ReactorSim
  module Nodes
    # **A belt conveyor's grip on its drive drum**, for any conduit that is a belt. The drum pulls
    # the belt by friction, `grip_kg_per_s` of load's worth; a loading point pushing more onto it
    # than that **stalls** it, and a slipping belt does not recover, because a belt sliding on its
    # drum grips less than one standing on it. Stalled, it carries nothing and the drum turns on
    # under it, its friction the drive's heat (`bearing_load_n`, the drum's `loaded_by:`).
    # `wetted_by:` names a holder answering `flooding`, whose water on the drum takes grip away.
    #
    # A module, because a belt may also be something else — a road that can fall in, say.
    module Belting
      # The pull at which the belt slips, and slipping it drags at about that: a 4.4 kN slack side
      # round 210° of drum at rubber-on-steel μ 0.35 holds 11.5 kN by the capstan law, which is a
      # five-ply 30-inch cotton belt at its working tension.
      SLIP_FORCE_N = 11_500.0
      BELT_MU = 0.35

      # Wet rubber on steel grips at about 0.2, which takes most of the capstan's margin.
      WET_GRIP_LOSS = 0.6

      def initialize(grip_kg_per_s:, fed_from:, wetted_by: nil, **opts)
        @grip_kg_per_s = grip_kg_per_s.to_f
        @fed_from = fed_from.to_sym
        @wetted_by = wetted_by&.to_sym
        super(**opts)
      end

      attr_reader :grip_kg_per_s, :fed_from, :wetted_by

      def throughput_kg(state, ctx) = stalled?(ctx) ? 0.0 : super

      # **What the loading point pushes on, against what the drum can pull.** Both at the belt's
      # speed, since a slower belt carries its load deeper for the same pull.
      def stalled?(ctx)
        share = displacement_fraction(ctx)
        return false unless share.positive?

        pushed = full_crew_kg_per_s * ctx.dt * open_fraction(ctx) * share
        [ pushed, waiting_kg(ctx) ].min > grip_kg_per_s_now(ctx) * share * ctx.dt
      end

      def grip_kg_per_s_now(ctx) = @grip_kg_per_s * (1.0 - (WET_GRIP_LOSS * wetness(ctx)))

      # Slipping at `BELT_MU`, the drum drags at `SLIP_FORCE_N`; gripping, it does not rub at all.
      def bearing_load_n(ctx) = stalled?(ctx) ? SLIP_FORCE_N / BELT_MU : 0.0

      private

      def waiting_kg(ctx)
        parcels = ctx.node_state(@fed_from)&.fetch(:parcels, nil) || []
        Parcel.total_kg(Parcel.matching(parcels, port(:inlet).accepts, ctx.content))
      end

      def wetness(ctx)
        return 0.0 unless @wetted_by

        node = ctx.nodes&.[](@wetted_by)
        state = ctx.node_state(@wetted_by)
        node.respond_to?(:flooding) && state ? node.flooding(state, ctx.content) : 0.0
      end
    end

    # **A belt conveyor on its own**: a driven, displacement conduit that grips (`Belting`). Its
    # feed is its lever, and nobody need be on it. It writes a board (`signal`) and how busy it is
    # (`:belt`) for a peril of whoever is beside it.
    class Belt < Conduit
      include Belting

      SIGNALS = { standing: "standing", stalled: "stalled", empty: "running empty", carrying: "carrying" }.freeze

      def apply(state, ctx, grant)
        applied = super
        applied.merge(signal: SIGNALS.keys.index(signal(applied, ctx)))
      end

      def activity(state, quantity, dt)
        return nil unless quantity == :belt && dt.positive?

        (state.fetch(:carried_kg, 0.0) / (full_crew_kg_per_s * dt)).clamp(0.0, 1.0)
      end

      private

      def signal(state, ctx)
        return :standing unless displacement_fraction(ctx).positive?
        return :stalled if stalled?(ctx)

        state.fetch(:carried_kg, 0.0) > Parcel::EPSILON ? :carrying : :empty
      end
    end
  end
end
