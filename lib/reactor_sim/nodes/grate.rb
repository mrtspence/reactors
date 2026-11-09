# frozen_string_literal: true

module ReactorSim
  module Nodes
    # **The bars a fuel bed lies on, and the bed in the way of the air.** Its gas conductance is its
    # own `conductance:` divided by `1 + depth / choke_depth_m`, the depth read off its `bed:` (a
    # `Nodes::FuelBed`) last tick, so a thick bed chokes its own draught and its ash with it.
    class Grate < Conduit
      def initialize(bed:, choke_depth_m:, **opts)
        @bed = bed.to_sym
        @choke_depth_m = choke_depth_m.to_f
        super(**opts)
      end

      attr_reader :bed, :choke_depth_m

      def gas_conductance(state, ctx)
        base = super or return nil

        base / (1.0 + (ctx.node_reading(@bed, :depth_m).to_f / @choke_depth_m))
      end
    end
  end
end
