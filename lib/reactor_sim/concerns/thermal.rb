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
    #           emissivity, radiating_area_m2 — radiant loss; 0 for something that does not glow
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

      # ## How hot this part may get before it stops being structural
      #
      # Overridden by any node that accepts a rating directly — `Vessel` and `Conduit` both do.
      # The default is infinity, and **infinity is a silent off switch**: over-temperature
      # fatigue was written, wired and complete, and never once fired in any operation, because
      # every node in the repository shipped this default and `stress_per_second` returned on its
      # first branch every time. A capability nothing exercises is indistinguishable from one
      # that does not work.
      def max_temperature_k = Float::INFINITY

      # What the structure is made of, if it was told. `nil` means not declared.
      def material = nil

      # An explicit `max_temperature_k:` on the part wins, so a part can always be special — a
      # water-cooled wall really does survive temperatures its bare metal would not, and a
      # fusible plug is *chosen* to go early. Otherwise the rating comes from the material,
      # which is where it belongs: it is a property of the metal, not of this particular
      # casting, and a hundred future operations must not each invent their own number for
      # "steel". How fast a part fails once it is over stays per-part, as `stress_rate`.
      def rated_temperature_k(content)
        declared = max_temperature_k
        return declared if declared.finite?
        return Float::INFINITY if material.nil?

        content.max_temperature_k(material)
      end

      def initial_temperature_k = Units::STANDARD_TEMPERATURE_K

      # --- radiation -----------------------------------------------------------

      # **Opt-in, both of them**, so a node that has not been given a surface behaves exactly as
      # it did before radiation existed.
      #
      # **Emissivity belongs to the part, not to its material**, the same call `safety_factor`
      # makes: a surface property is not a bulk one. Oxidised iron runs near 0.8 and polished
      # steel near 0.1, and what separates them is a wire brush rather than a different metal.
      def emissivity = 0.0
      def radiating_area_m2 = 0.0

      # **Radiation as a conductance in W/K, which is what makes it cheap and stable.**
      #
      #   T⁴ − T_amb⁴ ≡ (T² + T_amb²)(T + T_amb)·(T − T_amb)
      #
      # That is an identity, so the bracketed part *is* a conductance and radiation becomes an
      # ordinary term in the backward-Euler machinery that already exists — unconditionally
      # stable at any `dt`, converging on the sink rather than overshooting it. An explicit `T⁴`
      # term would be exactly the integrator this library forbids.
      #
      # Evaluated at the start of the tick, which is first order like everything else here and
      # errs safely: a cooling body's true coefficient falls as it cools, so this one
      # **under**-states the loss rather than overshooting past the sink.
      def radiative_conductance(temperature_k, sink_k)
        surface = emissivity * radiating_area_m2
        return 0.0 unless surface.positive? && temperature_k.positive? && sink_k.positive?

        surface * Units::STEFAN_BOLTZMANN *
          ((temperature_k**2) + (sink_k**2)) * (temperature_k + sink_k)
      end
    end
  end
end
