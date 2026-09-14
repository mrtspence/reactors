# frozen_string_literal: true

module ReactorSim
  module Concerns
    # A node whose mechanism can be obstructed by what collects inside it.
    #
    # ## The gap this fills
    #
    # Volume occupancy had exactly two consequences in this engine, and they are both about
    # *room*: `Holds#room_m3` stops a node accepting more condensed matter than it has space
    # for, and `Pressurized#free_volume` raises the pressure of the gas that is left. Neither
    # says anything about the deposit getting in the **way** of something.
    #
    # That third consequence is what water in a cylinder, ash on a grate, tar in a line and
    # scale in a tube all are, and without it each needs its own bespoke rule. Two laws for one
    # idea is how `max_kg_per_s` and `conductance` happened.
    #
    # ## Occupancy is measured against a CHARACTERISTIC volume, not the node's
    #
    # This is the whole of the concern and the only thing that is subtle about it. A cylinder
    # holding 14 kg of water is destroyed, and 14 kg is **7%** of its total volume — because
    # what matters is the clearance space the piston has to fit into at the top of its stroke,
    # not the cylinder. Measured against the wrong denominator the hazard is invisible.
    #
    #   config: obstruction_volume_m3, obstruction_tags
    #
    # Needs `Holds`, because only a holder can accumulate anything. **A conduit cannot foul in
    # this engine** — it holds nothing by design (see `Path`), so a fouling pipe has to be a
    # holder with a restriction beside it, or the deposit has nowhere to live.
    #
    # ## What occupancy MEANS is the node's business, not this concern's
    #
    # Deliberately, because it genuinely differs and a shared answer would be wrong for
    # everything:
    #
    #   swept-volume machine   clearance volume    compression pressure rises, then it locks
    #   reacting bed           void space          air cannot reach fuel; the reaction chokes
    #   vessel                 its own volume      free volume falls, pressure rises
    #
    # So this provides the fraction and nothing else.
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
