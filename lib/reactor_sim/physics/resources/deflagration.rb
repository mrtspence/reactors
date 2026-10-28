# frozen_string_literal: true

module ReactorSim
  module Resources
    # **A flame front through a premixed mixture**: a gas or dust explosion. It crosses a room
    # faster than a tick, so it is resolved rather than integrated (see `Resources::Prompt`).
    #
    # **Anything alight in a mixture inside its range is a front**, and the front passes through the
    # whole mixture: every kilogram of fuel in it burns, its products set by the mixture's own air —
    # `Reaction.complete` — rather than by where the burn fell on the tick grid. Outside its range a
    # flame stays with `Ignition` and burns only what it lights.
    #
    # There is no build-up at room scale. A flame is self-propagating at a kernel of centimetres,
    # and a lit fraction left to grow at its rate first burns the mixture it is in, diluting it —
    # far enough, measured, to take a 9% room out of its range before it ever went off.
    module Deflagration
      module_function

      # The lit mass is as of last tick, so a flame laid this tick goes off on the next. **Or a front
      # has already passed through the node this tick**, which lights every other fuel in its range
      # — the gas flame taking the dust cloud with it.
      def triggered?(spec, ignition, parcels, content:, front: false, **)
        return false unless Ignition.carries_flame?(spec, parcels, content)
        return false if Ignition.fuel_mass(spec, parcels, content) <= Parcel::EPSILON

        front || ignition.fetch(:kg, 0.0) > Parcel::EPSILON
      end

      # `share` is how much of the mixture the front can carry through — less than all of it where
      # the node throttles the reaction, as stone dust does a dust cloud.
      # Returns [new_parcels, joules_released, fuel_kg_burnt].
      def resolve(spec, parcels, content:, share: 1.0)
        before = Ignition.fuel_mass(spec, parcels, content)
        burnt, released = Reaction.complete(spec, parcels, content: content, share: share)

        [ burnt, released, before - Ignition.fuel_mass(spec, burnt, content) ]
      end

      # A front needs a mixture to run through, and the range is what says whether it has one.
      def validate!(id, spec)
        limits = spec[:ignition]
        return if limits && (limits[:lean_fraction] || limits[:rich_fraction])

        raise Error, "reaction #{id}: a deflagration needs an ignition block with a flammable range"
      end
    end
  end
end
