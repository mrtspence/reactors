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
      #
      # `ignited_fuel_kg` is how much of the fuel is actually alight (Resources::Ignition).
      # When it is given, IT is the gate and `min_temperature_k` is not applied here — the
      # ignited mass already encodes the temperature history, and an ember must keep burning
      # below a threshold it has fallen under. When it is nil the reaction is not modelling
      # ignition and the old bulk-temperature gate stands, so nothing that predates ignition
      # behaves differently.
      def advance(spec, parcels, temperature_k:, dt:, content:, ignited_fuel_kg: nil)
        if ignited_fuel_kg.nil?
          return [ parcels, 0.0 ] if temperature_k < spec.fetch(:min_temperature_k, 0.0).to_f
        elsif ignited_fuel_kg <= Parcel::EPSILON
          return [ parcels, 0.0 ]
        end

        held = parcels.to_h { |p| [ p.fetch(:resource), p ] }
        unless Array(spec[:alternatives]).empty?
          return cascade(spec, parcels, held, temperature_k: temperature_k, dt: dt,
                                             content: content, ignited_fuel_kg: ignited_fuel_kg)
        end

        consumes = spec.fetch(:consumes)

        # How far the reaction could possibly go, set by whichever reagent runs out first.
        #
        # Only the LIT fuel counts. Capping the fuel term here rather than scaling the finished
        # extent matters more than it looks: `limit` is frequently set by the air, and scaling
        # an already-air-limited extent by the lit fraction charges the fire for its draught
        # twice. A grate with 46 kg of coal and 0.25 kg alight then burned half a percent of
        # what the air allowed, and produced 9 kJ a tick instead of megawatts.
        limit = consumes.map { |resource, ratio|
          available = held[resource]&.fetch(:kg) || 0.0
          available = [ available, ignited_fuel_kg ].min if ignited_fuel_kg && fuel?(resource, content)
          available / ratio.to_f
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

      def fuel?(resource, content) = content.tags(resource).include?(:fuel)

      # --- pathways -----------------------------------------------------------------------
      #
      # **What a reaction does when it cannot get enough of one reagent.** A fire with air to
      # spare burns clean; the same fire with half the air it wants burns all of its fuel
      # anyway and makes carbon monoxide doing it. That is not the reaction going slower — it
      # is a different reaction, and the supply of one named reagent decides how much of each
      # happens.
      #
      # `limited_by:` names that reagent and `alternatives:` lists the cheaper ways out,
      # ordered most-of-it-first. The top-level `consumes`/`produces` is the preferred pathway,
      # so **a reaction declaring no alternatives never reaches any of this** and computes
      # exactly as it did before pathways existed.
      #
      # See `docs/design_sketches/reaction-pathways.md`.
      def cascade(spec, parcels, held, temperature_k:, dt:, content:, ignited_fuel_kg:)
        gate = spec.fetch(:limited_by).to_sym
        wanted = demand(spec, held, gate, dt, content, ignited_fuel_kg)
        return [ parcels, 0.0 ] if wanted <= Parcel::EPSILON

        shares = allocate(pathways(spec), gate, wanted, held[gate]&.fetch(:kg) || 0.0, held)
        return [ parcels, 0.0 ] if shares.empty?

        shares.reduce([ parcels, 0.0 ]) do |(acc, released), (pathway, extent)|
          [ apply_stoichiometry(pathway, acc, extent, temperature_k, content),
            released + (-pathway.fetch(:enthalpy_j_per_unit, 0.0).to_f * extent) ]
        end
      end

      # The preferred pathway first, then the declared alternatives. Each is a whole reaction
      # in its own right — `consumes`, `produces`, `enthalpy_j_per_unit` — so `apply_stoichiometry`
      # takes one without knowing it came from a list.
      def pathways(spec)
        [ spec ] + Array(spec[:alternatives])
      end

      # **How far the reaction would go if the gated reagent were free**, which is what makes a
      # starved fire burn its fuel rather than bank it. Every reagent BUT the gate caps this,
      # the lit mass caps the fuel exactly as it does for a single-pathway reaction, and the
      # same closed form turns a ceiling into a rate.
      def demand(spec, held, gate, dt, content, ignited_fuel_kg)
        caps = spec.fetch(:consumes).filter_map do |resource, ratio|
          next if resource == gate

          available = held[resource]&.fetch(:kg) || 0.0
          available = [ available, ignited_fuel_kg ].min if ignited_fuel_kg &&
                                                            fuel?(resource, content)
          available / ratio.to_f
        end

        limit = caps.min
        return 0.0 if limit.nil? || limit <= Parcel::EPSILON

        limit * (1.0 - Math.exp(-spec.fetch(:rate_per_s).to_f * dt))
      end

      # **Spend the scarce reagent on the cleanest pathway that can still afford the rest.**
      #
      # For one boundary this is exact and needs no tuning: with `a₁` and `a₂` per unit and `A`
      # available, the split that spends `A` precisely is `x·a₁ + (E−x)·a₂ = A`, which is what
      # the `headroom` line solves. Plentiful supply puts everything on the first pathway;
      # supply below even the last pathway's appetite caps the extent, which is what a
      # single-pathway reaction has always done.
      #
      # Returns `[[pathway, extent], ...]`, skipping pathways that got nothing.
      def allocate(pathways, gate, wanted, supply, held)
        shares = []

        # `next` rather than `break`: a `break` inside `filter_map` discards everything already
        # accumulated and hands back nil, which reads as "nothing reacted" for the commonest
        # case of all — the first pathway taking the lot.
        pathways.each_with_index do |pathway, i|
          next if wanted <= Parcel::EPSILON

          cost = ratio_of(pathway, gate)
          extent = affordable(cost, cheapest(pathways, i + 1, gate), wanted, supply)
          extent = [ extent, extra_reagent_cap(pathway, pathways.first, held) ].min
          next if extent <= Parcel::EPSILON

          wanted -= extent
          supply -= extent * cost
          shares << [ pathway, extent ]
        end

        shares
      end

      # What this pathway may take, given that whatever it leaves behind still has to be paid
      # for by the cheapest pathway after it. `nil` means there is nothing after it, so it is
      # the last resort and simply takes what the supply allows.
      def affordable(cost, fallback, wanted, supply)
        return cost.positive? ? [ wanted, supply / cost ].min : wanted if fallback.nil?
        return wanted if cost <= fallback

        headroom = supply - (wanted * fallback)
        [ [ headroom / (cost - fallback), 0.0 ].max, wanted ].min
      end

      def cheapest(pathways, from, gate)
        rest = pathways[from..] or return nil
        return nil if rest.empty?

        rest.map { |pathway| ratio_of(pathway, gate) }.min
      end

      def ratio_of(pathway, resource) = pathway.fetch(:consumes)[resource].to_f

      # **A pathway may name a reagent the preferred one does not** — water gas is carbon and
      # steam rather than carbon and less air — and then its own supply caps it, so a pathway
      # whose extra reagent is absent simply cannot run and the cascade falls through.
      #
      # > **This is a seam, and it ships under-tested.** Nothing in the game declares an extra
      # > reagent yet, so the only coverage is a rig. If you are the first to build on it — a
      # > gasworks, a producer-gas plant — treat a surprise here as a gap in
      # > `docs/design_sketches/reaction-pathways.md` rather than as a bug in your content.
      def extra_reagent_cap(pathway, preferred, held)
        extras = pathway.fetch(:consumes).reject { |r, _| preferred.fetch(:consumes).key?(r) }
        return Float::INFINITY if extras.empty?

        extras.map { |r, ratio| (held[r]&.fetch(:kg) || 0.0) / ratio.to_f }.min
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
