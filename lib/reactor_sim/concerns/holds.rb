# frozen_string_literal: true

module ReactorSim
  module Concerns
    # A node that contains material.
    #
    # This is one of the four jobs the old `Buffer` carried, and it is the only one that
    # was ever really storage. Transport delay is gone (it emerges from hop count),
    # throughput lives on ports, and back-pressure is the arbiter's job.
    #
    #   config: volume_m3
    #   state:  parcels
    module Holds
      def holds_initial_state(_rng, _content) = { parcels: [] }

      def parcels(state) = state.fetch(:parcels, [])

      def contents_kg(state) = Parcel.total_kg(parcels(state))

      def contents_volume(state, content) = Parcel.total_volume(parcels(state), content)

      # How much more volume this node can accept.
      #
      # **Only condensed phases count.** A gas expands to fill whatever it is put in — it does not
      # run out of room, it raises the pressure. Charging gases against a fixed volume at a fixed
      # nominal density caps a pressure vessel at about 1.2 atm whatever is feeding it, because
      # the mass limit bites long before the pressure does. A vessel filling with gas is limited
      # by what its walls can stand, which is both more accurate and considerably more dangerous.
      #
      # Never negative: an over-full node has zero room, and the overflow is the arbiter's problem
      # rather than a negative number leaking downstream.
      def room_m3(state, content)
        condensed = parcels(state).reject { |p| content.tags(p.fetch(:resource)).include?(:gas) }

        [ volume_m3 - Parcel.total_volume(condensed, content), 0.0 ].max
      end

      # Room expressed in kg of a specific resource, which is what the arbiter needs when
      # capping an incoming push.
      def room_kg(state, content, resource)
        room_m3(state, content) * content.density(resource)
      end

      def full?(state, content) = room_m3(state, content) <= Parcel::EPSILON

      # Mean density of everything held, over the node's whole volume.
      #
      # **What a positive-displacement machine downstream actually swallows.** A piston sweeps a
      # *volume* and gets whatever is in it, so the mass per stroke is this times that volume, not
      # the ideal-gas density of the working fluid. Dry, the two agree; wet, this climbs with the
      # condensate the supply is holding, which is how a priming slug reaches a piston.
      #
      # `content` is unused — the parcels carry their own mass — but stays in the signature
      # because `Tick::Context#node_reading` passes it.
      def bulk_density_kg_m3(state, _content = nil)
        return 0.0 if volume_m3 <= 0.0

        contents_kg(state) / volume_m3
      end
    end
  end
end
