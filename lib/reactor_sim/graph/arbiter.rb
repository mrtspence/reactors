# frozen_string_literal: true

module ReactorSim
  # Settlement: one pure function over every claim in the operation at once.
  #
  # This is the piece that lets nodes be evaluated in any order while still conserving mass
  # and energy exactly. Nodes declare what they want against the previous tick; the arbiter
  # sees the whole set together and decides what actually moves. Nothing here reads a
  # clock, draws entropy, or depends on hash order.
  #
  # Mass and heat go through the same machinery because they are the same problem: claims
  # against a shared limit, settled once, with the remainder staying put. For mass the
  # limit is port throughput and destination room; for heat it is the point past which a
  # node would overshoot its neighbours. Ungranted mass stays as contents; ungranted heat
  # stays as sender enthalpy. Neither is ever destroyed.
  #
  # Oversubscription splits proportionally to request (docs/simulation_architecture.md
  # §13). Declared priority is deliberately not built; changing the rule is a change to one
  # function here.
  module Arbiter
    Settlement = Struct.new(:flows, :heat, :ambient, :drive, keyword_init: true)

    # One path's granted movement.
    #
    # A path has a nominal direction, but gas may run the other way down it — so the ends are
    # asked for by role (source, sink) rather than by name (from, to), and `reversed` is the
    # only place the distinction lives. Everything downstream reads the roles, which is what
    # keeps backflow from needing a second code path through advection and the grants.
    Flow = Struct.new(:path, :parcels, :requested_kg, :reversed, keyword_init: true) do
      def granted_kg = parcels.sum { |p| p.fetch(:kg) }
      def rejected_kg = [ requested_kg - granted_kg, 0.0 ].max

      def source_node = reversed ? path.to_node : path.from_node
      def source_port = reversed ? path.to_port : path.from_port
      def sink_node   = reversed ? path.from_node : path.to_node
      def sink_port   = reversed ? path.from_port : path.to_port

      # The walls the stream touches, in the order it touches them.
      def conduits = reversed ? path.conduits.reverse : path.conduits
    end

    module_function

    def settle(nodes:, states:, paths:, thermal_links:, drive_links: [], intents:, content:, dt:, ctx:)
      Settlement.new(
        flows: settle_mass(nodes:, states:, paths:, intents:, content:, dt:, ctx:),
        heat: settle_heat(nodes:, states:, thermal_links:, content:, dt:),
        ambient: settle_ambient(nodes:, states:, content:, dt:),
        drive: settle_drive(nodes:, states:, drive_links:, dt:, ctx:)
      ).freeze
    end

    # --- mass ---------------------------------------------------------------

    def settle_mass(nodes:, states:, paths:, intents:, content:, dt:, ctx:)
      # Gas moves down a pressure gradient, settled by the same Relaxation that heat and
      # rotation use. Everything else is rate-driven. A path opts into the pressure regime by
      # having conduits that declare a `conductance` and holders that declare no intent.
      gas_kg = settle_gas(nodes:, states:, paths:, intents:, content:, dt:, ctx:)

      # 1. What each path would move, then broken down per resource so composition is
      #    preserved as flow is scaled.
      #
      #    A settled gas flow may be NEGATIVE, meaning the gradient beat the path's nominal
      #    direction. The path is then walked backwards for the tick: source and sink swap,
      #    and every stage below reads `claim[:source]` rather than `path.from_node`.
      claims = paths.map do |path|
        ports = path_ports(path, nodes)
        settled = gas_kg[path.id]
        reversed = settled ? settled.negative? : false
        source = reversed ? path.to_node : path.from_node
        eligible = eligible_parcels(states.fetch(source), ports, content)
        # What the parts on this path think about the mix. Computed once per path, from the
        # frozen previous tick like everything else a node reads — so a separator whose
        # efficiency depends on how hard it is being driven is answering about last tick's
        # flow, which is the same one-tick staleness every cross-node read already carries.
        weights = transport_weights(path, nodes, states, ctx, eligible, content)

        if settled
          gas, bulk = eligible.partition { |p| content.tags(p.fetch(:resource)).include?(:gas) }
          desired = settled.abs
          # A reversed path carries gas and nothing else: the rate term is declared for the
          # nominal direction and means nothing running the other way. In practice every
          # pressure-driven path is gas-tagged end to end, so `bulk` is empty either way.
          rate = reversed ? 0.0 : rate_desired(path, nodes, states, intents, ports, dt, ctx)
          per_resource = entrained(desired, gas, bulk, rate, weights, content)
        else
          desired = rate_desired(path, nodes, states, intents, ports, dt, ctx)
          per_resource = apportion(desired, eligible, weights)
        end

        { path:, reversed:, source:, sink: (reversed ? path.from_node : path.to_node),
          desired:, per_resource: }
      end

      claims = scale_by_source_availability(claims, states, content)
      claims = cap_gas_by_pressure(claims, nodes, states, content, gas_kg, intents)
      claims = scale_by_sink_room(claims, nodes, states, content)

      claims.map do |claim|
        Flow.new(
          path: claim.fetch(:path),
          reversed: claim.fetch(:reversed),
          parcels: extract(states.fetch(claim.fetch(:source)), claim.fetch(:per_resource)),
          requested_kg: claim.fetch(:desired)
        ).freeze
      end.freeze
    end

    # Every port material crosses on this path — the two holders' and every conduit's.
    # Throughput and tag filters apply at each one, so a gas-only valve halfway along a line
    # restricts it exactly as an endpoint would.
    def path_ports(path, nodes)
      path.links.flat_map do |link|
        [ nodes.fetch(link.from_node).port(link.from_port),
          nodes.fetch(link.to_node).port(link.to_port) ]
      end
    end

    # The narrowest conduit on the route, with its lever and its failure taken into account.
    # A path with no conduits is unrestricted and leans on its ports alone.
    def path_capacity(path, nodes, states, ctx)
      return Float::INFINITY if path.direct?

      path.conduits.map { |id| nodes.fetch(id).throughput_kg(states.fetch(id), ctx) }.min
    end

    # Rate-driven flow: how much this path would move if nothing but its limits stopped it.
    #
    # Either end may drive it — a pump upstream pushing, or a machine downstream pulling — but
    # an ACTIVE SINK IS AUTHORITATIVE ABOUT ITS OWN INTAKE. Taking the larger of the two made a
    # sink unable to refuse: a valve shoving its whole contents at a cylinder overrode the
    # cylinder's own careful limit and packed it to eight times its supply pressure.
    #
    # With nothing declared at either end the PATH drives the flow. That is what replaced the
    # conduit's `pushes: held` — holders are passive, so if the route itself did not drive
    # flow, nothing in the graph would move at all.
    def rate_desired(path, nodes, states, intents, ports, dt, ctx)
      sink_intent = intents.fetch(path.to_node, Intent.none)
      source_intent = intents.fetch(path.from_node, Intent.none)

      desired =
        if sink_intent.draws.key?(path.to_port)
          sink_intent.draw(path.to_port)
        elsif source_intent.pushes.key?(path.from_port)
          source_intent.push(path.from_port)
        else
          Float::INFINITY
        end

      [ desired, ports.map { |port| port.capacity_kg(dt) }.min,
        path_capacity(path, nodes, states, ctx) ].min
    end

    # --- gas: pressure-driven ------------------------------------------------

    # A coupling for `Relaxation`, which needs only these four.
    Coupling = Struct.new(:id, :a, :b, :conductance, keyword_init: true)

    # Gas settled the same way heat and rotation are: bodies joined by couplings drift toward
    # a shared potential. Capacity is `dn/dP = V_free/(R·T)`, potential is pressure.
    #
    # Returns `{ path.id => kg }` for the paths that took part; a path missing from the hash is
    # rate-driven and settles as it always did. **A negative figure means the gradient beat the
    # path's nominal direction and the gas is flowing backwards** — backdraught down a chimney,
    # blowback through an open valve. `settle_mass` swaps the ends of the path when it sees one.
    #
    # **Settled in MOLES, converted to kg afterwards.** Pressure is a function of moles, so a
    # molar capacity is exact for a mixture where a mass one would need a mean molar mass.
    # The conversion back uses whichever end is actually the source, for the same reason.
    def settle_gas(nodes:, states:, paths:, intents:, content:, dt:, ctx:)
      by_id = paths.to_h { |path| [ path.id, path ] }
      couplings = paths.filter_map { |path| gas_coupling(path, nodes, states, intents, ctx) }
      return {} if couplings.empty?

      ids = couplings.flat_map { |c| [ c.a, c.b ] }.uniq
      capacities = ids.to_h { |id| [ id, nodes.fetch(id).mole_capacity_per_pa(states.fetch(id), content) ] }
      potentials = ids.to_h { |id| [ id, nodes.fetch(id).pressure_pa(states.fetch(id), content) ] }
      # Indexed rather than searched. `path_head` used to scan the whole path list per
      # coupling, which is an O(n²) sweep on the hottest function in settlement.
      heads = couplings.to_h { |c| [ c.id, path_head(by_id.fetch(c.id), nodes, states, content, ctx) ] }
      limits = couplings.to_h { |c| [ c.id, mole_limits(by_id.fetch(c.id), nodes) ] }.compact

      moles = Relaxation.settle(couplings, capacities, potentials, dt, heads,
                                limits.empty? ? nil : limits)

      couplings.to_h do |coupling|
        n = moles.fetch(coupling.id, 0.0)
        source = n.negative? ? coupling.b : coupling.a
        [ coupling.id, moles_to_kg(n, states.fetch(source), content) ]
      end
    end

    # The bounds this path's flow must respect, in moles over the step.
    #
    # **Conductance is the whole restriction on a pressure-driven path**, so the only bound here
    # is direction: a check valve may not run backwards. `Port#max_kg_per_s` governs rate-driven
    # paths and nothing else.
    #
    # Applying both is not harmless. A rating and a conductance describe restrictions that
    # rarely agree, so the throat ends up choked at essentially every pressure the graph
    # reaches — and a permanently choked coupling carries a *fixed* flow, leaving the pressure
    # at either end with no feedback at all. A real orifice does choke, but on a pressure ratio
    # near 2:1, which furnace draught never approaches; a choke needs a physical trigger, not a
    # kg/s borrowed from a rate-driven part.
    def mole_limits(path, nodes)
      one_way?(path, nodes) ? [ 0.0, Float::INFINITY ] : nil
    end

    # Mean kg per mole of a node's gases, or nil if it holds none.
    def mean_molar_mass(state, content)
      gases = state.fetch(:parcels, []).select { |p| content.tags(p.fetch(:resource)).include?(:gas) }
      moles = Parcel.total_moles(gases, content)
      return nil if moles <= Parcel::EPSILON

      Parcel.total_kg(gases) / moles
    end

    # A path settles by pressure only if every conduit on it declares a conductance and neither
    # end has declared an intent for it. A node that asks for a specific amount — a cylinder
    # filling its charge — is making a positive-displacement claim, not riding a gradient.
    def gas_coupling(path, nodes, states, intents, ctx)
      return nil if path.direct?
      return nil if intents.fetch(path.to_node, Intent.none).draws.key?(path.to_port)
      return nil if intents.fetch(path.from_node, Intent.none).pushes.key?(path.from_port)
      return nil unless [ path.from_node, path.to_node ].all? { |id|
        nodes.fetch(id).respond_to?(:mole_capacity_per_pa)
      }

      conductances = path.conduits.map { |id| nodes.fetch(id).gas_conductance(states.fetch(id), ctx) }
      return nil if conductances.any?(&:nil?)
      return nil if conductances.any? { |k| k <= 0.0 }

      # Resistances in series add.
      total = 1.0 / conductances.sum { |k| 1.0 / k }
      Coupling.new(id: path.id, a: path.from_node, b: path.to_node, conductance: total)
    end

    # A path admits backflow only if every conduit on it does. One check valve anywhere in a
    # line stops the whole line reversing, which is exactly what fitting one is for.
    def one_way?(path, nodes) = path.conduits.any? { |id| nodes.fetch(id).one_way? }

    # The pressure a path supplies of its own, on top of the gradient between its ends.
    #
    # **Buoyancy is what makes a chimney work**, and why gas transport needs a head term rather
    # than only a gradient: a firebox venting to the same atmosphere it draws from has no
    # gradient to breathe on, so it fills to ambient and suffocates. A stack of hot gas weighs
    # less than the same column of cold air, and the difference is the draught.
    #
    #     head = (ρ_ambient − ρ_stream) · g · height
    #
    # So a hotter fire pulls harder, which feeds the fire — a loop a player can learn.
    #
    # Densities come from the ideal gas law at ambient pressure using the SOURCE's own mean
    # molar mass, so flue gas and air are compared on the same footing.
    def path_head(path, nodes, states, content, ctx)
      fixed = path.conduits.sum { |id| nodes.fetch(id).head_pa(ctx) }
      height = path.conduits.sum { |id| nodes.fetch(id).stack_height_m }
      return fixed if height <= 0.0

      source = nodes.fetch(path.from_node)
      state = states.fetch(path.from_node)
      gases = state.fetch(:parcels, []).select { |p| content.tags(p.fetch(:resource)).include?(:gas) }
      moles = Parcel.total_moles(gases, content)
      return fixed if moles <= Parcel::EPSILON

      molar = Parcel.total_kg(gases) / moles
      hot = source.temperature_k(state, content)
      ambient = source.respond_to?(:ambient_k) ? source.ambient_k : Units::STANDARD_TEMPERATURE_K
      return fixed if hot <= 0.0 || ambient <= 0.0

      density = ->(t) { Units::STANDARD_PRESSURE_PA * molar / (Units::GAS_CONSTANT * t) }
      fixed + ((density.call(ambient) - density.call(hot)) * Units::GRAVITY_M_PER_S2 * height)
    end

    # Mean molar mass of the source's gases turns a mole transfer into a mass one. Apportioning
    # that mass across the species afterwards gives exactly `n · xᵢ · Mᵢ` per species.
    #
    # The sign is carried through: `source_state` is whichever end the caller found to be
    # upstream this tick, so a backflow converts against the composition that is actually
    # moving. Discarding negatives here is what used to make `one_way` unreachable dead code —
    # a reversed transfer was thrown away before anything could act on it, so a single
    # overshoot latched permanently and no `one_way: false` had any effect at all.
    def moles_to_kg(moles, source_state, content)
      return 0.0 if moles.abs <= Parcel::EPSILON

      molar = mean_molar_mass(source_state, content)
      return 0.0 if molar.nil?

      moles * molar
    end

    # Material must satisfy EVERY port's tag filter along the path — a gas outlet feeding a
    # liquid inlet moves nothing, which is a wiring mistake the operation should be able to
    # make.
    def eligible_parcels(state, ports, content)
      state.fetch(:parcels, []).select do |p|
        resource = p.fetch(:resource)
        ports.all? { |port| port.accepts?(resource, content) }
      end
    end

    # Split a desired mass across the resources actually present, proportional to what is
    # there, so a drawn mixture has the same composition as the mixture it left behind —
    # **unless a part on the path has an opinion about it.**
    #
    # This is the one place composition is decided. Everything after it only scales the vector,
    # which is why an override belongs here and nowhere else.
    #
    # `weights` is empty for almost every path, and the unweighted branch is kept rather than
    # folded in so that a graph where nothing overrides anything is **bit-identical** to one
    # without the feature at all.
    def apportion(desired, parcels, weights = nil)
      return {} if desired <= Parcel::EPSILON

      if weights.nil? || weights.empty?
        total = parcels.sum { |p| p.fetch(:kg) }
        return {} if total <= Parcel::EPSILON

        return parcels.to_h { |p| [ p.fetch(:resource), desired * (p.fetch(:kg) / total) ] }
      end

      weighted = parcels.map { |p|
        resource = p.fetch(:resource)
        [ resource, p.fetch(:kg) * weights.fetch(resource, 1.0) ]
      }
      total = weighted.sum { |(_, kg)| kg }
      return {} if total <= Parcel::EPSILON

      weighted.to_h { |(resource, kg)| [ resource, desired * (kg / total) ] }
    end

    # What a pressure-driven path carries: the gas the solve settled, plus whatever condensed
    # matter the parts on the path say rides **with** it.
    #
    # **A pressure solve rates the gas, not the total, so entrainment is additive here where it
    # is not on a rate-driven path.** A rate limit is a mass throughput and an affinity may only
    # redistribute it; moles of gas crossing a conductance are unaffected by a droplet hitching a
    # lift, so the liquid rides on top and the gas figure is preserved exactly. Solids still take
    # the rate term — a stoker really is rated in mass, and coal does not ride on steam.
    #
    # **Liquid is rated by the bore, gas by the conductance.** The entrainment term is capped by
    # `rate`, and uncapped it is unbounded: `scale = desired / gas_share` grows without limit as
    # the stream approaches pure liquid, so a drum on the point of priming claims its entire
    # inventory in one tick. The only backstop, `scale_by_sink_room`, scales a claim *uniformly*
    # and so would trim the gas below what the solve settled — breaking the invariant this method
    # exists to protect. The cap is also the physical rule: conductance rates moles down a
    # pressure gradient and says nothing about how fast water moves through a pipe, which is set
    # by the bore.
    #
    # **A line with no declared opinion still passes liquid**, falling to the same proportional
    # rate term solids take. Dropping it instead silently applies to every conductance-bearing
    # path whose ends declare no intent — which is why a cylinder relief valve would pass water
    # in exactly zero states: lifted, the path is pressure-driven with no affinity declared;
    # shut, its throughput is zero. A flooded line flows as a liquid, not as steam's passenger.
    def entrained(desired, gas, bulk, rate, weights, content)
      moved = apportion(desired, gas, weights)
      # Nothing declared: every condensed phase shares the line's rating as **one** budget rather
      # than one each, or a stream carrying both water and sludge would be given twice the bore.
      return moved.merge(apportion(rate, bulk, weights)) if weights.empty? || bulk.empty?

      liquid, solid = bulk.partition { |p| content.tags(p.fetch(:resource)).include?(:liquid) }
      carried = apportion(rate, solid, weights)
      dry = moved.merge(carried)
      return dry if liquid.empty?

      # Weight gas and liquid together, then scale so the GAS mass is exactly what the pressure
      # solve asked for. Whatever liquid the weights imply comes along beside it.
      shares = apportion(1.0, gas + liquid, weights)
      gas_share = gas.sum { |p| shares.fetch(p.fetch(:resource), 0.0) }
      return dry if gas_share <= Parcel::EPSILON

      scale = desired / gas_share
      wet = shares.transform_values { |v| v * scale }
      wet = trim_liquid(wet, liquid, rate)
      wet.merge(carried)
    end

    # Hold the liquid the mix implies down to what the line can actually pass, leaving the gas
    # figure untouched. Scaled rather than clipped per resource so a mixed condensate keeps its
    # composition.
    def trim_liquid(shares, liquid, rate)
      wet_kg = liquid.sum { |p| shares.fetch(p.fetch(:resource), 0.0) }
      return shares if wet_kg <= rate || wet_kg <= Parcel::EPSILON

      trim = rate / wet_kg
      keys = liquid.map { |p| p.fetch(:resource) }
      shares.to_h { |resource, kg| [ resource, keys.include?(resource) ? kg * trim : kg ] }
    end

    # An affinity of zero is a gate in the wrong place — hard exclusion belongs in a port's
    # `accepts:`, where it is structural and visible in the operation definition. Clamped so a
    # separator always misplaces something, which is what a real one does: the area between the
    # ideal and the actual partition curve is where all the interesting behaviour lives.
    #
    # **The band has to be this wide**, and the first attempt at ±10³ was not. Affinity works
    # against the mass ratio actually held, and a boiler drum holds 2620 kg of water against
    # 6.2 kg of steam — 424 to 1. Delivering the 99.5%-dry steam a real drum delivers therefore
    # needs a liquid weight near **1.2 × 10⁻⁵**, which a 10⁻³ floor silently rounds up into
    # violent priming. A phase separator is not an extreme case; it is the ordinary one.
    MIN_AFFINITY = 1.0e-6
    MAX_AFFINITY = 1.0e6

    # The composition bias every part on a path applies, as `{resource => multiplier}`.
    #
    # **Product across ports, max within a port**, which mirrors the tag gate exactly —
    # `accepts?` is OR within a port and `ports.all?` is AND across them. Keeping the two the
    # same shape is what stops the boolean gate and the weighted rule drifting apart.
    #
    # Returns `{}` when nothing on the path has an opinion, so the common case costs one hash
    # allocation and takes the untouched path through `apportion`.
    def transport_weights(path, nodes, states, ctx, parcels, content)
      return {} if parcels.empty?

      opinions = path.links.flat_map { |link|
        [ [ link.from_node, link.from_port ], [ link.to_node, link.to_port ] ]
      }.filter_map { |node_id, port_id|
        affinity = nodes.fetch(node_id).transport_affinity(port_id, states.fetch(node_id), ctx)
        affinity unless affinity.nil? || affinity.empty?
      }
      return {} if opinions.empty?

      parcels.to_h { |p|
        resource = p.fetch(:resource)
        weight = opinions.reduce(1.0) { |acc, o| acc * port_affinity(o, resource, content) }
        [ resource, weight.clamp(MIN_AFFINITY, MAX_AFFINITY) ]
      }
    end

    # An exact resource key beats any tag key, so a rule about one substance is always reachable
    # without inventing a tag for it.
    def port_affinity(affinity, resource, content)
      exact = affinity[resource]
      return exact.to_f.clamp(MIN_AFFINITY, MAX_AFFINITY) if exact

      matched = content.tags(resource).filter_map { |tag| affinity[tag] }
      return 1.0 if matched.empty?

      matched.max.to_f.clamp(MIN_AFFINITY, MAX_AFFINITY)
    end

    # Several paths drawing on one node compete for its contents, per resource.
    def scale_by_source_availability(claims, states, _content)
      demand = Hash.new(0.0)
      claims.each do |claim|
        node_id = claim.fetch(:source)
        claim.fetch(:per_resource).each { |r, kg| demand[[ node_id, r ]] += kg }
      end

      # Indexed once rather than scanning a node's parcels per claim per resource.
      held = {}
      scales = demand.to_h do |(node_id, resource), wanted|
        by_resource = held[node_id] ||= states.fetch(node_id).fetch(:parcels, [])
                                             .to_h { |p| [ p.fetch(:resource), p.fetch(:kg) ] }
        available = by_resource.fetch(resource, 0.0)
        [ [ node_id, resource ], wanted > available ? available / wanted : 1.0 ]
      end

      claims.map do |claim|
        node_id = claim.fetch(:source)
        claim.merge(per_resource: claim.fetch(:per_resource).to_h do |r, kg|
          [ r, kg * scales.fetch([ node_id, r ], 1.0) ]
        end)
      end
    end

    # Several paths pushing into one node compete for its room. Volume is the currency
    # here, because that is what a vessel actually runs out of.
    def scale_by_sink_room(claims, nodes, states, content)
      incoming = Hash.new(0.0)
      claims.each do |claim|
        node_id = claim.fetch(:sink)
        incoming[node_id] += volume_of(claim.fetch(:per_resource), content)
      end

      scales = incoming.to_h do |node_id, wanted|
        node = nodes.fetch(node_id)
        room = node.respond_to?(:room_m3) ? node.room_m3(states.fetch(node_id), content) : Float::INFINITY
        [ node_id, wanted > room ? room / wanted : 1.0 ]
      end

      claims.map do |claim|
        scale = scales.fetch(claim.fetch(:sink), 1.0)
        next claim if scale >= 1.0

        claim.merge(per_resource: claim.fetch(:per_resource).transform_values { |kg| kg * scale })
      end
    end

    # Only condensed phases are charged for volume, matching `Holds#room_m3`. A gas expands
    # to fill whatever it is given and pushes the pressure up instead of running out of
    # space, so charging an incoming gas for room would throttle every duct in the game to
    # its own volume times air's density — about a kilogram of air per cubic metre, which
    # is nowhere near enough to feed a fire.
    #
    # These two rules have to agree. Fixing one without the other is what made the damper
    # deliver 1.2 kg of air a tick when the grate wanted seven.
    def volume_of(per_resource, content)
      per_resource.sum do |resource, kg|
        content.tags(resource).include?(:gas) ? 0.0 : kg / content.density(resource)
      end
    end

    # A gas cannot be limited by volume, so it is limited by pressure instead: no link may
    # deliver more gas in one tick than would bring the destination up to the pressure of
    # its own source. Without this a small vessel over-packs and ends up at a higher
    # pressure than the thing feeding it, which is not a thing pipes do.
    #
    # Nodes that do not model pressure — the open air, a coal bunker — report unlimited
    # headroom and are unaffected. Deliberately only a CAP: it never blocks flow outright,
    # so a chimney cannot deadlock waiting for a pressure difference to appear.
    def cap_gas_by_pressure(claims, nodes, states, content, gas_kg, intents)
      claims.map do |claim|
        path = claim.fetch(:path)
        # A pressure-driven path has already been settled against the gradient, by a closed
        # form that converges on the equilibrium rather than jumping to it. Capping it again
        # here would be the instantaneous equaliser this stage exists to be, applied on top of
        # the rate that replaced it.
        next claim if gas_kg.key?(path.id)
        # **A positive-displacement claim is not riding a gradient**, so this rule does not
        # describe it — `gas_coupling` refuses to pressure-settle such a path on the same
        # grounds. A piston really does draw its cylinder below chest pressure (that is what
        # wire-drawing at the port is), and the claim is self-bounding anyway, since a swept
        # volume filled at supply density cannot exceed the supply's density.
        #
        # Capping it here derates the cylinder's intake by a factor set by the temperature
        # difference between chest and cylinder rather than anything physical — and only at some
        # cut-offs, so the engine changes shape across the lever for no stated reason.
        next claim if intents.fetch(claim.fetch(:sink), Intent.none).draws.key?(path.to_port)

        sink = nodes.fetch(claim.fetch(:sink))
        source = nodes.fetch(claim.fetch(:source))
        next claim unless sink.respond_to?(:gas_headroom_kg) && source.respond_to?(:pressure_pa)

        supply = source.pressure_pa(states.fetch(claim.fetch(:source)), content)

        claim.merge(per_resource: claim.fetch(:per_resource).to_h { |resource, kg|
          next [ resource, kg ] unless content.tags(resource).include?(:gas)

          headroom = sink.gas_headroom_kg(states.fetch(claim.fetch(:sink)), supply, content, resource)
          [ resource, [ kg, headroom ].min ]
        })
      end
    end

    # Take the granted mass out of the source's parcels. Energy follows mass
    # proportionally, which is exact because a node's contents are all at one temperature.
    def extract(state, per_resource)
      held = state.fetch(:parcels, [])

      per_resource.filter_map do |resource, kg|
        next if kg <= Parcel::EPSILON

        parcel = held.find { |p| p.fetch(:resource) == resource }
        next if parcel.nil? || parcel.fetch(:kg) <= Parcel::EPSILON

        taken = [ kg, parcel.fetch(:kg) ].min
        { resource: resource,
          kg: taken,
          joules: parcel.fetch(:joules) * (taken / parcel.fetch(:kg)) }
      end.freeze
    end

    # --- heat ---------------------------------------------------------------

    # Heat is one instance of a general shape: bodies joined by couplings drift toward a
    # shared potential. Rotation and mass are the others, and all three go through the same
    # implicit network solve. See Relaxation for the mathematics and for what the pairwise
    # closed form it replaced could not express.
    def settle_heat(nodes:, states:, thermal_links:, content:, dt:)
      return {} if thermal_links.empty?

      temperatures = {}
      capacities = {}
      thermal_links.flat_map { |l| [ l.a, l.b ] }.uniq.each do |id|
        node = nodes.fetch(id)
        temperatures[id] = node.temperature_k(states.fetch(id), content)
        capacities[id] = node.total_heat_capacity(states.fetch(id), content)
      end

      Relaxation.settle(heat_couplings(thermal_links, temperatures), capacities, temperatures, dt)
    end

    # **A radiant link's conductance is recomputed every tick**, because it depends on both end
    # temperatures. `Coupling` is the same vehicle the gas solve uses for exactly this, so
    # `Relaxation` needs to know nothing about radiation — it is handed a conductance either way.
    #
    # A link with no radiant surface is passed through untouched, which is what keeps the digest
    # bit-identical for everything that has not opted in.
    def heat_couplings(thermal_links, temperatures)
      return thermal_links if thermal_links.none?(&:radiative?)

      thermal_links.map do |link|
        next link unless link.radiative?

        radiant = link.radiative_conductance(temperatures.fetch(link.a),
                                             temperatures.fetch(link.b))
        Coupling.new(id: link.id, a: link.a, b: link.b,
                     conductance: link.conductance + radiant)
      end
    end

    # --- rotation -----------------------------------------------------------

    # Angular momentum crossing a shaft, belt or gear train. Identical mathematics to heat
    # with moment of inertia standing in for heat capacity and angular velocity for
    # temperature — which is exactly why it shares an implementation.
    #
    # Momentum is conserved to the bit. Kinetic energy is NOT, and should not be: what a
    # slipping coupling loses becomes friction heat, and the Operation puts that difference
    # on the ledger rather than letting it vanish.
    # Drag rides in the same solve, keyed `node=ground`, because a brake and a coupling pulling
    # on one shaft at once is a network rather than two steps — see `Relaxation.settle`.
    def settle_drive(nodes:, states:, drive_links:, dt:, ctx: nil)
      # A coupling to a part that has let go transmits nothing. Without this a burst flywheel
      # stayed on the drivetrain and kept accelerating — measured at 2365 rpm and 3.97 MW, on
      # a wheel whose own burst limit is 322 rpm.
      live = drive_links.reject do |link|
        states.fetch(link.a)[:failure] || states.fetch(link.b)[:failure]
      end
      drags = drive_drags(nodes, states, ctx)
      return {} if live.empty? && drags.empty?

      velocities = {}
      inertias = {}
      (live.flat_map { |l| [ l.a, l.b ] } + drags.keys).uniq.each do |id|
        node = nodes.fetch(id)
        velocities[id] = node.omega(states.fetch(id))
        inertias[id] = node.moment_of_inertia
      end

      Relaxation.settle(live, inertias, velocities, dt, nil, nil, drags)
    end

    # Total conductance toward rest per **shaft**, which is not always the node that declared it:
    # a bearing drags on what it carries. **A shaft that has let go is not dragged** — it has left
    # the drivetrain, and `Tick#stress` has already taken its momentum.
    #
    # **Whether a broken declarer still drags is the declarer's to answer**, not this method's. A
    # burst flywheel stops dragging on itself; a seized bearing drags harder than it ever did, and
    # that is the only mechanism by which a seizure stops anything.
    def drive_drags(nodes, states, ctx)
      return {} if ctx.nil?

      nodes.each_with_object(Hash.new(0.0)) do |(id, node), acc|
        next unless node.respond_to?(:drag_conductances)

        shaft = node.drag_shaft
        next if states.fetch(shaft, {})[:failure]

        total = node.drag_conductances(states.fetch(id), ctx).values.sum
        acc[shaft] += total if total.positive?
      end.select { |_, total| total.positive? }
    end

    # --- ambient ------------------------------------------------------------

    # Waste heat: every thermal node leaks to the environment. Not arbitrated, because a
    # fixed-temperature sink cannot be overshot — the closed form converges on it.
    #
    # This is what stops a long chain being a perfect heat accumulator, and it is also what
    # makes exact energy conservation cheap: the environment is an explicit sink with a
    # ledger, not a silent hole (docs/simulation_architecture.md §8).
    # **Two mechanisms, summed as one conductance.** Conduction and convection to the air are
    # linear; radiation goes as T⁴ and is linearised exactly by factoring (`Thermal`), so both
    # are W/K and the closed form takes their sum. A part is entitled to differ in each — a
    # lagged drum does neither, a bare hot pipe does both.
    #
    # **The guard is on the total, not on conduction.** Skipping a node whose
    # `ambient_conductance` is zero would skip everything that radiates and barely conducts,
    # which is most hot things in a machine.
    def settle_ambient(nodes:, states:, content:, dt:)
      nodes.each_value.filter_map do |node|
        next unless node.respond_to?(:ambient_conductance)

        state = states.fetch(node.id)
        temperature = node.temperature_k(state, content)
        conductance = node.ambient_conductance +
                      node.radiative_conductance(temperature, node.ambient_k)
        next if conductance <= 0.0

        q = Relaxation.to_reservoir(node.total_heat_capacity(state, content),
                                    temperature, node.ambient_k, conductance, dt)
        next if q.abs <= Parcel::EPSILON

        [ node.id, q ] # positive = node sheds to the environment
      end.to_h.freeze
    end
  end
end
