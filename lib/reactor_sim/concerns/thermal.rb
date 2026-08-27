# frozen_string_literal: true

module ReactorSim
  module Concerns
    # A node that has a temperature.
    #
    # The node's own structure (the metal) and whatever it currently holds are treated as
    # ONE lumped body at a single temperature. That is a deliberate approximation and it
    # buys a lot: advection becomes exactly correct, because a parcel leaving carries
    # precisely the energy its temperature implies, with no separate wall-to-fluid link to
    # get wrong. Things that genuinely need distinct temperatures are distinct nodes
    # (docs/simulation_architecture.md §13).
    #
    #   config: heat_capacity (J/K) — the structure alone
    #           ambient_conductance (W/K) — leak to the environment; 0 for a perfect flask
    #   state:  joules — the structure's energy alone; parcels carry their own
    module Thermal
      def thermal_initial_state(_rng, _content)
        { joules: heat_capacity * initial_temperature_k }
      end

      # Total thermal inertia: structure plus contents.
      def total_heat_capacity(state, content)
        heat_capacity + Parcel.total_heat_capacity(parcels(state), content)
      end

      def total_joules(state)
        state.fetch(:joules) + Parcel.total_joules(parcels(state))
      end

      def temperature_k(state, content)
        capacity = total_heat_capacity(state, content)
        return initial_temperature_k if capacity <= Parcel::EPSILON

        (total_joules(state) - Parcel.total_formation(parcels(state), content)) / capacity
      end

      # Add (or remove) energy and re-settle structure and contents to one temperature.
      # Energy in == energy out, exactly; this only redistributes.
      def add_joules(state, joules, content)
        rebalance(state.merge(joules: state.fetch(:joules) + joules), content)
      end

      # Restore the single-temperature invariant after anything has changed the mix —
      # mass arriving, mass leaving, a phase split, a reaction.
      def rebalance(state, content)
        held = parcels(state)
        capacity = total_heat_capacity(state, content)
        return state if capacity <= Parcel::EPSILON

        t = (total_joules(state) - Parcel.total_formation(held, content)) / capacity

        state.merge(
          joules: heat_capacity * t,
          **(held.empty? ? {} : { parcels: Parcel.at_temperature(held, t, content) })
        )
      end

      # Overridden by Holds; a node can be thermal without holding anything.
      def parcels(state) = state.fetch(:parcels, [])

      def initial_temperature_k = Units::STANDARD_TEMPERATURE_K
    end
  end
end
