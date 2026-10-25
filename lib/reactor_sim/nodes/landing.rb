# frozen_string_literal: true

module ReactorSim
  module Nodes
    # **A landing: material goes on or off something that comes and goes, but only while it stands
    # there.** `carrier:` names the node it serves — a cage, a train — which answers
    # `standing_at?(state, mark_m)`; away or moving, the landing passes nothing and what was sent
    # waits upstream. Whoever works it is the lever (`control_id:`, often an effort station), so with
    # nobody at the landing nothing moves however long the carrier stands.
    #
    # `traffic:` names the quantity its perils scale with: how busy the landing is against a full
    # crew's rate.
    #
    #   config: carrier, mark_m, traffic, perils (plus Conduit's)
    class Landing < Conduit
      def initialize(carrier:, mark_m:, traffic: nil, perils: [], **opts)
        @carrier = carrier.to_sym
        @mark_m = mark_m.to_f
        @traffic = traffic&.to_sym
        @perils = perils.freeze
        super(**opts)
      end

      attr_reader :carrier, :mark_m, :traffic, :perils

      def throughput_kg(state, ctx)
        carrier_state = ctx.node_state(@carrier)
        return 0.0 unless carrier_state && ctx.nodes[@carrier].standing_at?(carrier_state, @mark_m)

        super
      end

      def activity(state, quantity, dt)
        return nil unless @traffic && quantity == @traffic

        (state.fetch(:carried_kg, 0.0) / (full_crew_kg_per_s * dt)).clamp(0.0, 1.0)
      end
    end
  end
end
