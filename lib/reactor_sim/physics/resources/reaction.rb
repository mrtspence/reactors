# frozen_string_literal: true

module ReactorSim
  module Resources
    # Chemistry, unlike phase change, has a rate.
    #
    # An instantaneous reaction has no transient, and the transient is the game — a vat
    # that reacts the moment its reagents meet gives the overseer nothing to steer. The
    # model is crude on purpose: a first-order approach to completion, with an optional
    # ignition temperature. Catalysis, inhibitors and competing pathways are the upgrade
    # path and need no structural change to reach.
    module Reaction
      module_function

      # Returns [new_parcels, joules_released].
      def advance(spec, parcels, temperature_k:, dt:, content:)
        return [ parcels, 0.0 ] if temperature_k < spec.fetch(:min_temperature_k, 0.0).to_f

        consumes = spec.fetch(:consumes)
        held = parcels.to_h { |p| [ p.fetch(:resource), p ] }

        # How far the reaction could possibly go, set by whichever reagent runs out first.
        limit = consumes.map { |resource, ratio|
          (held[resource]&.fetch(:kg) || 0.0) / ratio.to_f
        }.min
        return [ parcels, 0.0 ] if limit.nil? || limit <= Parcel::EPSILON

        # Closed-form first order: unconditionally stable and never overshoots, at any dt.
        # Same trick as the thermal model, and for the same reason — time_scale is a dial
        # the designer turns, so nothing may depend on dt being small.
        extent = limit * (1.0 - Math.exp(-spec.fetch(:rate_per_s).to_f * dt))
        return [ parcels, 0.0 ] if extent <= Parcel::EPSILON

        # Per unit of reaction EXTENT, not per kilogram — one unit consumes the whole
        # `consumes` set. Negative enthalpy is exothermic, so releasing energy is a sign flip.
        [ apply_stoichiometry(spec, parcels, extent, temperature_k, content),
          -spec.fetch(:enthalpy_j_per_unit, 0.0).to_f * extent ]
      end

      # Products carry the ENTHALPY the reactants had, not their temperature.
      #
      # Building products at the reactants' temperature looks harmless and is not: eleven
      # kilograms of air at 1005 J/kg·K becoming twelve kilograms of flue gas at 1100 J/kg·K
      # is a different amount of energy for the same temperature, so the stoichiometry
      # quietly minted about 780 kJ every time it fired. Conserving enthalpy across the
      # swap and letting the caller add the reaction's own energy separately keeps the two
      # effects distinct and the books exact.
      #
      # The node is rebalanced to a single temperature afterwards, so nothing ends up with
      # a physically odd temperature of its own.
      def apply_stoichiometry(spec, parcels, extent, _temperature_k, _content)
        consumed_joules = 0.0

        remaining = parcels.map do |parcel|
          ratio = spec.fetch(:consumes)[parcel.fetch(:resource)]
          next parcel unless ratio

          taken, left = Parcel.split(parcel, extent * ratio.to_f)
          consumed_joules += taken.fetch(:joules)
          left
        end

        # Split the reactants' enthalpy across the products by mass, and nothing else. In
        # particular NOT the products' formation enthalpy: `enthalpy_j_per_unit` is defined
        # to already include any formation difference between the two sides, so adding it
        # here as well would count it twice.
        produced_mass = spec.fetch(:produces).values.sum(&:to_f)
        produced = spec.fetch(:produces).map do |resource, ratio|
          share = produced_mass.positive? ? ratio.to_f / produced_mass : 0.0
          { resource: resource.to_sym, kg: extent * ratio.to_f, joules: consumed_joules * share }
        end

        Parcel.normalise(remaining + produced)
      end
    end
  end
end
