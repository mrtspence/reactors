# frozen_string_literal: true

module ReactorSim
  module Concerns
    # A node whose contents exert pressure.
    #
    # **Derived only — there is no pressure in state, ever.** A stored pressure drifts away from
    # the contents and temperature that cause it and nothing tells you.
    #
    # Deliberately simple: ideal gas over whatever volume the liquids are not occupying. No pump
    # head, no hydrostatic term, no flow-induced drop — each of which is an additive change here
    # rather than a rework.
    module Pressurized
      # Below this the node is effectively liquid-full and the ideal gas law would run away
      # to infinity. Clamping is a lie, but a bounded and monotonic one: pressure still
      # rises steeply as the last of the free volume disappears, which is the behaviour
      # that matters.
      MINIMUM_FREE_VOLUME_FRACTION = 0.001

      # How much more of a gas this node could take before reaching `target_pa`.
      #
      # **Volume alone cannot limit a gas** — it expands to fill whatever it is in — so without
      # this a small vessel accepts far more gas in one tick than the thing feeding it could
      # push, and ends up at a *higher* pressure than its own supply: eighteen kilograms into a
      # fifth of a cubic metre, at eight times the supply pressure.
      #
      # Infinity means unlimited, which is the right answer for the open air.
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
      # **In MOLES rather than kilograms.** Pressure is a function of moles (Dalton's law), so a
      # molar capacity is exact for any mixture, where the kg form `V_free·M/(R·T)` needs a mean
      # molar mass and is wrong by the spread of the composition — about 0.8% on a firebox
      # holding air, flue gas and CO₂ together. `Arbiter.settle_gas` converts the mole transfer
      # back to kg using the source's own composition, exact for the same reason.
      def mole_capacity_per_pa(state, content)
        temperature = temperature_k(state, content)
        return 0.0 if temperature <= 0.0

        free_volume(state, content) / (Units::GAS_CONSTANT * temperature)
      end

      # **An empty vessel is a VACUUM, not a vessel full of air.** Reporting one atmosphere for an
      # empty node breaks two things at once: a source below atmospheric can never fill a
      # receiver that claims 101 kPa while holding nothing, and nothing can present a vacuum,
      # which some machinery works against directly. If a node should contain air, give it air.
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

      # **What the shell can stand, derived from the shell.** Hoop stress in a thin cylindrical
      # shell is `σ = p·r / t`, so the pressure that tears it open is `σ_plate · t / r`. Every
      # term is a property of the part or of the metal: **a vessel's strength is not a number
      # somebody picks, it is what it is built from and how thick it is.** Same shape as
      # `Flywheel#burst_speed_m_s`.
      #
      # > **Never derive it from the safety valve's setting.** What a boiler survives depends on
      # > the plate, not on where somebody set a valve — and coupling them means raising the
      # > setting drags the damage threshold up in lockstep, so the gap between blowing off and
      # > bursting can never be deliberately widened or narrowed.
      #
      # `safety_factor` is the part's own, not the metal's, for the same reason it is on the
      # flywheel: how far below the ideal figure a real vessel fails depends on its seams. A
      # riveted wrought-iron boiler is the worst case — joint efficiency around 70%, and grooving
      # and corrosion along the seam worse still — so a quarter of the plate figure is realistic
      # rather than pessimistic.
      #
      # An explicit `max_pressure_pa:` wins, so a part can be special or simply not model this.
      # Infinity when there is no geometry to work from.
      def rated_pressure_pa(content)
        declared = max_pressure_pa
        return declared if declared.finite?
        return Float::INFINITY if material.nil? || shell_radius_m.nil? || wall_thickness_m.nil?
        return Float::INFINITY unless shell_radius_m.positive?

        content.tensile_strength_pa(material) * wall_thickness_m / shell_radius_m * safety_factor
      end

      # Overridden by any node that accepts these directly. Declaring none leaves the node
      # unbreakable by pressure, which is the right default for a tank nobody pressurises.
      def max_pressure_pa = Float::INFINITY
      def material = nil
      def shell_radius_m = nil
      def wall_thickness_m = nil
      def safety_factor = 1.0

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
