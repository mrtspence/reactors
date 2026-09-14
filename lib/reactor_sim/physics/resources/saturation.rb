# frozen_string_literal: true

module ReactorSim
  module Resources
    # Phase change snaps to equilibrium. Evaporation and condensation are fast relative to
    # any sane time_scale, so rate-limiting them would add a knob without adding a decision
    # (docs/simulation_architecture.md §13).
    module Saturation
      module_function

      # Boiling point at a given pressure, via Clausius–Clapeyron against the substance's
      # reference point. This is what makes a void coefficient expressible: drop the
      # pressure and the same water boils at a lower temperature, all on its own.
      def saturation_temperature_k(spec, pressure_pa)
        phase = spec.fetch(:phase)
        t_ref = phase.fetch(:reference_temperature_k).to_f
        p_ref = phase.fetch(:reference_pressure_pa).to_f
        latent = phase.fetch(:latent_heat_j_per_kg).to_f
        molar = spec.fetch(:molar_mass_g_per_mol).to_f / 1000.0

        r_specific = Units::GAS_CONSTANT / molar
        inverse = (1.0 / t_ref) - ((r_specific / latent) * Math.log(pressure_pa / p_ref))
        return Float::INFINITY if inverse <= 0.0

        1.0 / inverse
      end

      # Pressure and phase split are COUPLED, and solving them in sequence oscillates.
      #
      # Boiling at last tick's pressure produces vapour, which raises the pressure, which
      # raises the saturation temperature, which condenses it all again — a vessel flipping
      # between 0 kg and 51 kg of steam on alternate ticks, with pressure swinging between
      # 101 kPa and 2.5 MPa. The two quantities have to be solved together.
      #
      # Bisection on pressure does it: the implied pressure of the vapour produced by
      # equilibrating at P is monotonically decreasing in P, so there is exactly one fixed
      # point and halving the bracket converges on it. Deterministic and stable at any
      # timestep.
      #
      # The inner loop runs on LOCALS ONLY — no hashes, no allocation, no method dispatch
      # into Content. That matters more than it looks: this runs 40 times per node per
      # tick, and the first version, which fetched from a context hash each iteration, cost
      # ~64% of the entire tick at 100 nodes. The arithmetic was never the problem; forty
      # thousand hash lookups were.
      #
      # Returns [parcels, pressure_pa].
      def solve(liquid_id, vapour_id, parcels, volume_m3:, content:)
        involved = parcels.select { |p| [ liquid_id, vapour_id ].include?(p.fetch(:resource)) }
        mass = Parcel.total_kg(involved)
        return [ parcels, nil ] if involved.empty? || mass <= Parcel::EPSILON

        implied = implied_pressure_fn(liquid_id, vapour_id, parcels, involved, mass,
                                      volume_m3, content)

        # If even at the floor nothing boils, the mixture is subcooled and its pressure is
        # set by whatever else is in the vessel, not by this pair.
        return [ equilibrate(liquid_id, vapour_id, parcels, pressure_pa: MIN_PRESSURE_PA, content:), nil ] if
          implied.call(MIN_PRESSURE_PA) <= MIN_PRESSURE_PA

        # Bisect in LOG space. Pressure here spans five orders of magnitude — a few kPa of
        # vapour above tepid water, tens of MPa in a vessel about to let go — so halving
        # the logarithm converges on *relative* precision and reaches it in far fewer
        # steps than halving the raw interval.
        low  = LOG_MIN_PRESSURE
        high = LOG_MAX_PRESSURE
        ITERATIONS.times do
          mid = 0.5 * (low + high)
          pressure = Math.exp(mid)
          implied.call(pressure) > pressure ? low = mid : high = mid
        end

        pressure = Math.exp(0.5 * (low + high))
        [ equilibrate(liquid_id, vapour_id, parcels, pressure_pa: pressure, content:), pressure ]
      end

      # Builds the function whose fixed point is the answer: "what pressure would the
      # vapour exert, if the pair were equilibrated at this pressure?" Everything constant
      # for the tick is captured once, so each call is pure arithmetic on captured locals.
      def implied_pressure_fn(liquid_id, vapour_id, parcels, involved, mass, volume_m3, content)
        spec = content.resource(liquid_id)
        phase = spec.fetch(:phase)
        inv_t_ref = 1.0 / phase.fetch(:reference_temperature_k).to_f
        p_ref = phase.fetch(:reference_pressure_pa).to_f
        clausius = (Units::GAS_CONSTANT / (spec.fetch(:molar_mass_g_per_mol).to_f / 1000.0)) /
                   phase.fetch(:latent_heat_j_per_kg).to_f

        cp_l = content.specific_heat(liquid_id)
        f_l  = content.formation_enthalpy(liquid_id)
        cp_v = content.specific_heat(vapour_id)
        f_v  = content.formation_enthalpy(vapour_id)
        density_l = content.density(liquid_id)
        molar_v = content.resource(vapour_id).fetch(:molar_mass_g_per_mol).to_f / 1000.0
        h_per_kg = Parcel.total_joules(involved) / mass
        min_free = volume_m3 * Concerns::Pressurized::MINIMUM_FREE_VOLUME_FRACTION

        # Anything else in the vessel displaces volume this vapour cannot use.
        other_volume = parcels.reject { |p| involved.include?(p) }
                              .reject { |p| content.tags(p.fetch(:resource)).include?(:gas) }
                              .sum { |p| Parcel.volume_m3(p, content) }

        lambda do |pressure_pa|
          inverse = inv_t_ref - (clausius * Math.log(pressure_pa / p_ref))
          next 0.0 if inverse <= 0.0

          t_sat = 1.0 / inverse
          h_l = (cp_l * t_sat) + f_l
          next 0.0 if h_per_kg <= h_l # subcooled — no vapour at all

          h_v = (cp_v * t_sat) + f_v
          if h_per_kg >= h_v          # superheated — all of it is vapour
            vapour_kg = mass
            temperature = (h_per_kg - f_v) / cp_v
          else
            vapour_kg = mass * ((h_per_kg - h_l) / (h_v - h_l))
            temperature = t_sat
          end
          next 0.0 if vapour_kg <= Parcel::EPSILON

          free = volume_m3 - (((mass - vapour_kg) / density_l) + other_volume)
          free = min_free if free < min_free

          (vapour_kg / molar_v) * Units::GAS_CONSTANT * temperature / free
        end
      end

      MIN_PRESSURE_PA = 1_000.0        # below this, treat the mixture as subcooled
      MAX_PRESSURE_PA = 60_000_000.0   # far past any vessel that survives
      LOG_MIN_PRESSURE = Math.log(MIN_PRESSURE_PA)
      LOG_MAX_PRESSURE = Math.log(MAX_PRESSURE_PA)
      # Halvings of the log bracket. The range spans ~11 nats, so 20 steps pin the answer
      # to about 1e-5 relative — a hundredth of a pascal at atmospheric, far finer than
      # anything downstream can notice, and deterministic to the bit.
      #
      # This is the tick's single biggest cost (see docs/simulation_architecture.md §9), so
      # it is the first dial to turn if a large operation ever needs to be cheaper. Halving
      # it costs precision nothing cares about; the reason not to go lower is that the
      # bracket has to survive a vessel going from tepid to 60 MPa.
      ITERATIONS = 20

      # Split a liquid/vapour pair at the given pressure, conserving mass and energy
      # exactly. Returns the replacement parcels.
      #
      # Three regimes, decided by total enthalpy rather than by temperature — which is what
      # makes the two-phase region work at all. Inside it, adding energy boils more water
      # without the temperature moving at all, and that plateau is the interesting part.
      def equilibrate(liquid_id, vapour_id, parcels, pressure_pa:, content:)
        involved = parcels.select { |p| [ liquid_id, vapour_id ].include?(p.fetch(:resource)) }
        return parcels if involved.empty?

        mass = Parcel.total_kg(involved)
        return parcels.reject { |p| involved.include?(p) } if mass <= Parcel::EPSILON

        enthalpy = Parcel.total_joules(involved)
        t_sat = saturation_temperature_k(content.resource(liquid_id), pressure_pa)

        h_liquid = specific_enthalpy(liquid_id, t_sat, content)
        h_vapour = specific_enthalpy(vapour_id, t_sat, content)
        others = parcels.reject { |p| involved.include?(p) }

        replacement =
          if enthalpy <= mass * h_liquid
            [ { resource: liquid_id, kg: mass, joules: enthalpy } ]           # subcooled
          elsif enthalpy >= mass * h_vapour
            [ { resource: vapour_id, kg: mass, joules: enthalpy } ]           # superheated
          else
            quality = ((enthalpy / mass) - h_liquid) / (h_vapour - h_liquid)    # two-phase
            vapour_kg = mass * quality
            liquid_kg = mass - vapour_kg
            [ { resource: liquid_id, kg: liquid_kg, joules: liquid_kg * h_liquid },
              { resource: vapour_id, kg: vapour_kg, joules: vapour_kg * h_vapour } ]
          end

        Parcel.normalise(others + replacement)
      end

      def specific_enthalpy(resource, temperature_k, content)
        (content.specific_heat(resource) * temperature_k) + content.formation_enthalpy(resource)
      end
    end
  end
end
