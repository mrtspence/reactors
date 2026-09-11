# frozen_string_literal: true

module ReactorSim
  module Concerns
    # A node whose contents exert pressure.
    #
    # Derived only — there is no pressure in state, ever. A stored pressure drifts away
    # from the contents and temperature that cause it and nothing tells you; a derived one
    # cannot.
    #
    # The model is deliberately simple (docs/simulation_architecture.md §13): ideal gas
    # over whatever volume the liquids are not occupying. No pump head, no hydrostatic
    # term, no flow-induced drop. Because it is encapsulated here, each of those is an
    # additive change rather than a rework.
    module Pressurized
      # Below this the node is effectively liquid-full and the ideal gas law would run away
      # to infinity. Clamping is a lie, but a bounded and monotonic one: pressure still
      # rises steeply as the last of the free volume disappears, which is the behaviour
      # that matters.
      MINIMUM_FREE_VOLUME_FRACTION = 0.001

      # How much more of a gas this node could take before reaching `target_pa`.
      #
      # Volume alone cannot limit a gas — it expands to fill whatever it is in — so without
      # this a small vessel will happily accept far more gas in one tick than the thing
      # feeding it could ever push, and end up at a HIGHER pressure than its own supply.
      # One node did exactly that: it drew eighteen kilograms of gas into a fifth of a cubic
      # metre and reached eight times the pressure of the thing supplying it.
      #
      # Infinity means "unlimited" and is the right answer for the open air.
      def gas_headroom_kg(state, target_pa, content, resource)
        return Float::INFINITY unless content.tags(resource).include?(:gas)

        held = parcels(state)
        free = free_volume(state, content)

        temperature = temperature_k(state, content)
        return Float::INFINITY if temperature <= 0.0

        molar = molar_mass_kg(resource, content)
        capacity_kg = (target_pa * free / (Units::GAS_CONSTANT * temperature)) * molar
        present_kg = held.select { |p| content.tags(p.fetch(:resource)).include?(:gas) }
                         .sum { |p| p.fetch(:kg) }

        [ capacity_kg - present_kg, 0.0 ].max
      end

      # How many moles this node takes on per pascal of pressure rise, at fixed volume and
      # temperature. This is the **capacity** term for mass transport, exactly as heat capacity
      # is for heat: `P = nRT/V_free`, so `dn/dP = V_free/(R·T)`.
      #
      # Deliberately in MOLES rather than kilograms. Pressure is a function of moles — Dalton's
      # law — so a molar capacity is exact for any mixture, where the kg form `V_free·M/(R·T)`
      # needs a mean molar mass and is wrong by the spread of the composition. Measured at about
      # 0.8% on a firebox holding air, flue gas and CO₂ together, which is small but is an error
      # with no reason to exist.
      #
      # `Arbiter.settle_gas` converts the resulting mole transfer back to kg using the source's
      # own composition, which is exact for the same reason.
      def mole_capacity_per_pa(state, content)
        temperature = temperature_k(state, content)
        return 0.0 if temperature <= 0.0

        free_volume(state, content) / (Units::GAS_CONSTANT * temperature)
      end

      # An empty vessel is a VACUUM, not a vessel full of air.
      #
      # Reporting one atmosphere for an empty node quietly broke two things at once: a
      # source below atmospheric could never fill a receiver, because the receiver claimed
      # to be at 101 kPa while holding nothing at all; and nothing could present a vacuum,
      # which some machinery works against directly.
      #
      # If a node should contain air, it should be given air.
      def pressure_pa(state, content)
        held = parcels(state)
        return 0.0 if held.empty?

        gases = held.select { |p| content.tags(p.fetch(:resource)).include?(:gas) }
        return 0.0 if gases.empty?

        free = free_volume(state, content)

        moles = gases.sum do |p|
          p.fetch(:kg) / molar_mass_kg(p.fetch(:resource), content)
        end

        moles * Units::GAS_CONSTANT * temperature_k(state, content) / free
      end

      private

      # Whatever room the condensed phases are not occupying, floored so the ideal gas law
      # cannot run away to infinity as the last of it disappears.
      def free_volume(state, content)
        liquid = parcels(state).reject { |p| content.tags(p.fetch(:resource)).include?(:gas) }
                               .sum { |p| Parcel.volume_m3(p, content) }

        [ volume_m3 - liquid, volume_m3 * MINIMUM_FREE_VOLUME_FRACTION ].max
      end

      def molar_mass_kg(resource, content)
        grams = content.resource(resource).fetch(:molar_mass_g_per_mol) do
          raise Error, "resource #{resource} is tagged :gas but has no molar_mass_g_per_mol"
        end
        grams.to_f / 1000.0
      end
    end
  end
end
