# frozen_string_literal: true

module ReactorSim
  # A quantity of one substance, carrying its own energy.
  #
  # ## Why a module over plain hashes rather than a Parcel class
  #
  # Deliberate, and measured. Parcels are `{resource:, kg:, joules:}` hashes because:
  #
  #   * **They are the hot path.** Every link, every tick, every phase-solve iteration
  #     touches them. Allocation here already dominated the tick once — the saturation
  #     solve was 64% of a hundred-node step until its inner loop stopped building objects.
  #     A wrapper object per parcel per operation would put that cost back.
  #   * **They snapshot as they are.** A class would need `to_h`/`from_h` on every save and
  #     restore, which is exactly the sort of hand-maintained conversion that drifts.
  #
  # What a class would have bought — a place to hang behaviour — this module provides
  # instead, and it is all pure: every method returns new parcels and mutates nothing.
  #
  # Energy is enthalpy relative to a 0 K reference:
  #
  #     joules = kg * (specific_heat * T + formation_enthalpy)
  #
  # The formation term is what makes phase change exact. Water and steam at the same
  # temperature hold very different energy per kg, and the difference is precisely the
  # latent heat — so condensing a parcel releases exactly what boiling it cost.
  module Parcel
    EPSILON = 1e-12

    module_function

    def build(resource:, kg:, temperature_k:, content:)
      { resource: resource.to_sym,
        kg: kg.to_f,
        joules: kg.to_f * ((content.specific_heat(resource) * temperature_k.to_f) +
                           content.formation_enthalpy(resource)) }
    end

    def temperature_k(parcel, content)
      kg = parcel.fetch(:kg)
      return Units::STANDARD_TEMPERATURE_K if kg <= EPSILON

      resource = parcel.fetch(:resource)
      sensible = parcel.fetch(:joules) - (kg * content.formation_enthalpy(resource))
      sensible / (kg * content.specific_heat(resource))
    end

    # J/K — how much energy this parcel absorbs per degree. Summed across a node's
    # contents to get its total thermal inertia.
    def heat_capacity(parcel, content)
      parcel.fetch(:kg) * content.specific_heat(parcel.fetch(:resource))
    end

    def volume_m3(parcel, content)
      parcel.fetch(:kg) / content.density(parcel.fetch(:resource))
    end

    # Split off `kg`, returning [taken, remaining]. Energy follows mass proportionally,
    # which is correct because a parcel is at a single temperature throughout.
    def split(parcel, kg)
      available = parcel.fetch(:kg)
      taken_kg = [ kg, available ].min

      return [ zero(parcel), parcel ] if taken_kg <= EPSILON
      return [ parcel, zero(parcel) ] if taken_kg >= available - EPSILON

      fraction = taken_kg / available
      [ { resource: parcel.fetch(:resource), kg: taken_kg,
          joules: parcel.fetch(:joules) * fraction },
        { resource: parcel.fetch(:resource), kg: available - taken_kg,
          joules: parcel.fetch(:joules) * (1.0 - fraction) } ]
    end

    def zero(parcel) = { resource: parcel.fetch(:resource), kg: 0.0, joules: 0.0 }

    def empty?(parcel) = parcel.fetch(:kg) <= EPSILON

    # --- collection helpers -------------------------------------------------

    # Same-resource parcels are merged; a node never holds two parcels of one substance.
    # Sorted by resource id so the collection is canonical and snapshot digests are stable
    # regardless of the order things arrived in.
    def normalise(parcels)
      parcels
        .reject { |p| empty?(p) }
        .group_by { |p| p.fetch(:resource).to_sym }
        .map { |resource, group|
          { resource: resource,
            kg: group.sum { |p| p.fetch(:kg) },
            joules: group.sum { |p| p.fetch(:joules) } }
        }
        .sort_by { |p| p.fetch(:resource) }
        .freeze
    end

    # Remove exactly `taken` from `held`, per resource. Used when settlement has decided
    # what leaves a node: the parcels were extracted proportionally, so subtracting them
    # conserves both mass and energy to the bit.
    def subtract(held, taken)
      return normalise(held) if taken.empty?

      removed = taken.each_with_object(Hash.new { |h, k| h[k] = [ 0.0, 0.0 ] }) do |p, acc|
        acc[p.fetch(:resource)][0] += p.fetch(:kg)
        acc[p.fetch(:resource)][1] += p.fetch(:joules)
      end

      normalise(held.map do |parcel|
        kg, joules = removed[parcel.fetch(:resource)]
        next parcel if kg.nil?

        { resource: parcel.fetch(:resource),
          kg: [ parcel.fetch(:kg) - kg, 0.0 ].max,
          joules: [ parcel.fetch(:joules) - joules, 0.0 ].max }
      end)
    end

    def total_kg(parcels)     = parcels.sum { |p| p.fetch(:kg) }
    def total_joules(parcels) = parcels.sum { |p| p.fetch(:joules) }

    def total_heat_capacity(parcels, content)
      parcels.sum { |p| heat_capacity(p, content) }
    end

    def total_volume(parcels, content)
      parcels.sum { |p| volume_m3(p, content) }
    end

    def total_formation(parcels, content)
      parcels.sum { |p| p.fetch(:kg) * content.formation_enthalpy(p.fetch(:resource)) }
    end

    def matching(parcels, tags, content)
      return parcels if tags.nil? || tags.empty?

      parcels.select { |p| (content.tags(p.fetch(:resource)) & tags).any? }
    end

    # Draw `kg` from a set of parcels, taken proportionally so the mixture that leaves has
    # the same composition as the mixture that stays. Returns [taken, remaining].
    def draw(parcels, kg, _content)
      available = total_kg(parcels)
      return [ [], parcels ] if kg <= EPSILON || available <= EPSILON

      fraction = [ kg / available, 1.0 ].min
      taken = []
      remaining = []

      parcels.each do |parcel|
        t, r = split(parcel, parcel.fetch(:kg) * fraction)
        taken << t unless empty?(t)
        remaining << r unless empty?(r)
      end

      [ normalise(taken), normalise(remaining) ]
    end

    # Set every parcel to a common temperature, preserving total energy. Used after any
    # energy change so a node's contents and its own thermal mass stay in equilibrium —
    # which is what makes advection correct, since a parcel then leaves carrying exactly
    # the energy its temperature implies.
    def at_temperature(parcels, temperature_k, content)
      parcels.map do |p|
        resource = p.fetch(:resource)
        { resource: resource,
          kg: p.fetch(:kg),
          joules: p.fetch(:kg) * ((content.specific_heat(resource) * temperature_k) +
                                  content.formation_enthalpy(resource)) }
      end.freeze
    end
  end
end
