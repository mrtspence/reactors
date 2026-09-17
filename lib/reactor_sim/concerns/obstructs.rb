# frozen_string_literal: true

module ReactorSim
  module Concerns
    # A node whose mechanism can be obstructed by what collects inside it.
    #
    # `Holds#room_m3` and `Pressurized#free_volume` already charge condensed phases for *room*.
    # Neither says the deposit is getting in the **way** of something, which is the third
    # consequence that water in a cylinder, ash on a grate and scale in a tube all are.
    #
    # **Occupancy is measured against a CHARACTERISTIC volume, not the node's**, and that is the
    # whole of the concern. A cylinder holding 14 kg of water is destroyed, and 14 kg is 7% of
    # its total volume — what matters is the clearance space the piston must fit into at the top
    # of its stroke. Against the wrong denominator the hazard is invisible.
    #
    #   config: obstruction_volume_m3, obstruction_tags
    #
    # Needs `Holds`, so **a conduit cannot foul**: it holds nothing by design, and a fouling pipe
    # has to be a holder with a restriction beside it.
    #
    # **What occupancy MEANS is the node's business**, because it genuinely differs:
    #
    #   swept-volume machine   clearance volume    compression pressure rises, then it locks
    #   reacting bed           void space          air cannot reach fuel; the reaction chokes
    #   vessel                 its own volume      free volume falls, pressure rises
    module Obstructs
      # 0.0 when clear, 1.0 when the characteristic volume is completely full of matter that
      # does not belong there. Values above 1.0 are meaningful and are not clamped — how far
      # past the limit something is decides how hard it fails.
      def occupancy(state, content)
        volume = obstruction_volume_m3
        return 0.0 if volume <= 0.0

        obstructing_volume_m3(state, content) / volume
      end

      def obstructing_volume_m3(state, content)
        Parcel.total_volume(obstructing_parcels(state, content), content)
      end

      # Tagged rather than "everything that is not a gas", because the filter is part of the
      # mechanism: a cylinder is wrecked by liquid and indifferent to soot, a grate is choked
      # by solid ash and drains water away.
      def obstructing_parcels(state, content)
        tags = obstruction_tags
        return [] if tags.empty?

        parcels(state).select { |p| (content.tags(p.fetch(:resource)) & tags).any? }
      end
    end
  end
end
