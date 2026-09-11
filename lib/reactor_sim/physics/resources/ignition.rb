# frozen_string_literal: true

module ReactorSim
  module Resources
    # How much of the fuel is actually alight.
    #
    # Combustion used to be gated on the node's BULK temperature, which is a lie a
    # lumped-temperature node cannot avoid telling: a match does not raise a coal bunker to
    # 700 K, it raises a few grams, and those grams raise their neighbours. Modelled as a bulk
    # threshold the fire became all-or-nothing — above the line the whole grate burned, below
    # it nothing did and nothing ever could again, because there was no ember left to grow
    # from. The only winning move was to leave the igniter on permanently, which turned a
    # match into a throttle (docs/design_sketches/ignition.md).
    #
    # So the state is the ignited MASS, in kg, and the fraction is derived from it. That is the
    # same choice made everywhere else in the physics — store the extensive quantity, derive
    # the intensive one — and it pays for itself twice here:
    #
    #   * shovelling cold fuel onto a fire dilutes it for free, because the ignited mass does
    #     not change while the total does, and
    #   * fuel that burns away takes its share of the fire with it.
    #
    # This does NOT replace modelling genuinely distinct temperatures as distinct nodes. A
    # reactor's fuel pin really is hundreds of kelvin above its coolant, and no ignited
    # fraction can express that — the two approaches answer different questions and are meant
    # to coexist.
    module Ignition
      module_function

      # Does this reaction model ignition at all?
      #
      # Opt-in by content: a reaction with no `ignition:` block keeps the old
      # `min_temperature_k` gate untouched. Reactions that are not combustion — and reactions
      # written before this existed — are therefore completely unaffected.
      def modelled?(spec) = spec.key?(:ignition)

      # How quickly the fire's view of the draught catches up with the draught itself.
      #
      # **This is deliberate fuel-bed inertia, and it is no longer load-bearing.** It was
      # written as a workaround: air passes THROUGH a firebox, and the standing inventory used
      # to oscillate hard — the damper delivered a slug, the flue cleared it, and one tick in
      # two the node genuinely held no air at all. Read instantaneously that said "starved"
      # every other tick, on a fire consuming barely one percent of what blew past it.
      #
      # That oscillation was a symptom of an unstable mass solver and is gone: transport is
      # settled implicitly now, and the firebox's air is steady to a coefficient of variation
      # of 0.0001 with no sign reversals. **Measured: disabling this memory entirely leaves the
      # steam engine bit-identical** — same fire temperature, same burn rate, same speed.
      #
      # It stays because the physics is defensible on its own terms rather than because
      # anything depends on it: a bed of burning coal does not go out because the draught
      # faltered for 250 ms. `ignition_spec` pins that behaviour. If it ever gets in the way,
      # delete it and the spec together — it is no longer propping anything up.
      OXIDISER_MEMORY_PER_S = 1.5

      def initial_state = { kg: 0.0, oxidiser_kg: 0.0 }

      # Returns the next ignition state: `{ kg:, oxidiser_kg: }`.
      def advance(spec, ignition, parcels, temperature_k:, dt:, content:, seed_kg: 0.0)
        oxidiser = remember_oxidiser(ignition, spec, parcels, content, dt)
        fuel_kg = fuel_mass(spec, parcels, content)

        # Nothing to burn means nothing alight. A grate that runs empty goes out, and refilling
        # it does not bring the fire back — which is exactly what a stoker has to prevent.
        return { kg: 0.0, oxidiser_kg: oxidiser } if fuel_kg <= Parcel::EPSILON

        ignited = [ ignition.fetch(:kg, 0.0) + seed_kg, fuel_kg ].min
        return { kg: 0.0, oxidiser_kg: oxidiser } if ignited <= Parcel::EPSILON

        net = net_rate(spec, ignited, oxidiser, temperature_k, dt, content)

        kg = if net.positive?
          spread(ignited, fuel_kg, net, dt)
        else
          # Dying, not dead. What is left is the ember the fire can be nursed back from, and
          # its existence is the whole difference between this model and the old threshold.
          ignited * Math.exp(net * dt)
        end

        { kg: kg.clamp(0.0, fuel_kg), oxidiser_kg: oxidiser }
      end

      # Whether the fire is gaining ground or losing it, per second. Positive spreads,
      # negative dies back.
      #
      # Spread does NOT depend on the bulk temperature, and getting that wrong first time made
      # this model fail in exactly the way the one it replaced did: gate spread on reaching
      # 500 K and a fire can never bootstrap, because it cannot reach 500 K without spreading.
      # A flame front is hot even when the room is cold — that is how anybody has ever lit a
      # fire. What a cold firebox does is draw heat OUT of the flame, so bulk temperature
      # belongs on the quench side, where `min_temperature_k` sets the scale.
      #
      # Starvation is measured against what the lit fuel would actually burn this tick, not
      # against zero. A fire with a hundred times the air it needs is not "less starved" than
      # one with ten times; both are simply breathing.
      def net_rate(spec, ignited_kg, oxidiser_kg, temperature_k, dt, content)
        min_k = spec.fetch(:min_temperature_k, 0.0).to_f
        chill = min_k.positive? ? (1.0 - (temperature_k / min_k)).clamp(0.0, 1.0) : 0.0

        demand = oxidiser_demand(spec, ignited_kg, dt, content)
        starved = demand.positive? ? (1.0 - (oxidiser_kg / demand)).clamp(0.0, 1.0) : 0.0

        # Starvation cuts both ways: a fire cannot spread into fuel it has no air to burn, so
        # spread is scaled down as well as quench scaled up. Without that, `net` bottoms out at
        # `quench_per_s - spread_per_s` and a fire shut off from air entirely still died three
        # times slower than its own quench rate says it should.
        #
        # Chill only ever adds to quench. A cold firebox draws heat out of a flame; it does not
        # stop the flame reaching the next lump.
        (rate(spec, :spread_per_s) * (1.0 - starved)) -
          (rate(spec, :quench_per_s) * [ chill, starved ].max)
      end

      # The oxidiser this tick's burn would consume if nothing held it back.
      def oxidiser_demand(spec, ignited_kg, dt, content)
        consumes = spec.fetch(:consumes)
        fuel_ratio = consumes.sum { |r, ratio| fuel?(r, content) ? ratio.to_f : 0.0 }
        other_ratio = consumes.sum { |r, ratio| fuel?(r, content) ? 0.0 : ratio.to_f }
        return 0.0 unless fuel_ratio.positive?

        burnt = ignited_kg * (1.0 - Math.exp(-spec.fetch(:rate_per_s).to_f * dt))
        burnt / fuel_ratio * other_ratio
      end

      def remember_oxidiser(ignition, spec, parcels, content, dt)
        present = spec.fetch(:consumes).keys.sum do |resource|
          next 0.0 if content.tags(resource).include?(:fuel)

          parcels.sum { |p| p.fetch(:resource) == resource ? p.fetch(:kg) : 0.0 }
        end

        # Rises instantly, falls slowly. A gust of draught counts the moment it arrives, but
        # losing it takes time to be felt — which is the asymmetry a fuel bed actually has.
        remembered = ignition.fetch(:oxidiser_kg, 0.0) * Math.exp(-OXIDISER_MEMORY_PER_S * dt)
        [ present, remembered ].max
      end

      def fraction(spec, ignition, parcels, content:)
        fuel_kg = fuel_mass(spec, parcels, content)
        return 0.0 if fuel_kg <= Parcel::EPSILON

        (ignition.fetch(:kg, 0.0) / fuel_kg).clamp(0.0, 1.0)
      end

      # The fuel is the reagent tagged `:fuel` — inferred rather than declared, so content
      # cannot get the two out of step. A reaction consuming no fuel has nothing to set alight.
      def fuel_mass(spec, parcels, content)
        fuels = spec.fetch(:consumes).keys.select { |r| content.tags(r).include?(:fuel) }
        return 0.0 if fuels.empty?

        parcels.sum { |p| fuels.include?(p.fetch(:resource)) ? p.fetch(:kg) : 0.0 }
      end

      def fuel?(resource, content) = content.tags(resource).include?(:fuel)

      # Closed-form logistic. Exact at any dt and it cannot overshoot, for the same reason the
      # thermal and reaction integrators are closed form: `time_scale` is a dial the designer
      # turns, so nothing may assume dt is small.
      #
      # Logistic rather than exponential because a fire spreads from its EDGES — growth is
      # fastest when half the grate is alight and tails off as it runs out of fresh fuel to
      # reach. It also has the property this model depends on: from exactly zero it stays at
      # zero forever. A fire needs a spark, and that is what makes the igniter a match.
      def spread(ignited, fuel_kg, rate_per_s, dt)
        f0 = ignited / fuel_kg
        return fuel_kg if f0 >= 1.0

        f = 1.0 / (1.0 + (((1.0 - f0) / f0) * Math.exp(-rate_per_s * dt)))
        f * fuel_kg
      end

      def rate(spec, key)
        spec.fetch(:ignition).fetch(key).to_f
      end
    end
  end
end
