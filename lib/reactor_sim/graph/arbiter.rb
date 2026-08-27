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

    # One link's granted movement.
    Flow = Struct.new(:link, :parcels, :requested_kg, keyword_init: true) do
      def granted_kg = parcels.sum { |p| p.fetch(:kg) }
      def rejected_kg = [ requested_kg - granted_kg, 0.0 ].max
    end

    module_function

    def settle(nodes:, states:, links:, thermal_links:, drive_links: [], intents:, content:, dt:)
      Settlement.new(
        flows: settle_mass(nodes:, states:, links:, intents:, content:, dt:),
        heat: settle_heat(nodes:, states:, thermal_links:, content:, dt:),
        ambient: settle_ambient(nodes:, states:, content:, dt:),
        drive: settle_drive(nodes:, states:, drive_links:, dt:)
      ).freeze
    end

    # --- mass ---------------------------------------------------------------

    def settle_mass(nodes:, states:, links:, intents:, content:, dt:)
      # 1. What each link would move, capped by the throughput of both its ports, then
      #    broken down per resource so composition is preserved as flow is scaled.
      claims = links.map do |link|
        source = nodes.fetch(link.from_node)
        sink   = nodes.fetch(link.to_node)
        out_port = source.port(link.from_port)
        in_port  = sink.port(link.to_port)

        # Either end may drive flow — a pump upstream pushing, or one downstream pulling —
        # but an ACTIVE SINK IS AUTHORITATIVE ABOUT ITS OWN INTAKE. If the receiving node
        # declared a draw, that is how much it is willing to take, and no amount of pushing
        # changes it.
        #
        # Taking the larger of the two made a sink unable to refuse: a valve shoving its
        # whole contents at a cylinder overrode the cylinder's own careful limit and packed
        # it to eight times its supply pressure. A passive tank declares nothing and still
        # accepts whatever arrives, which is what makes a pump-into-tank work.
        sink_intent = intents.fetch(link.to_node, Intent.none)
        desired =
          if sink_intent.draws.key?(link.to_port)
            sink_intent.draw(link.to_port)
          else
            intents.fetch(link.from_node, Intent.none).push(link.from_port)
          end
        desired = [ desired, out_port.capacity_kg(dt), in_port.capacity_kg(dt) ].min

        eligible = eligible_parcels(states.fetch(link.from_node), out_port, in_port, content)
        { link:, desired:, per_resource: apportion(desired, eligible) }
      end

      claims = scale_by_source_availability(claims, states, content)
      claims = cap_gas_by_pressure(claims, nodes, states, content)
      claims = scale_by_sink_room(claims, nodes, states, content)

      claims.map do |claim|
        Flow.new(
          link: claim.fetch(:link),
          parcels: extract(states.fetch(claim.fetch(:link).from_node), claim.fetch(:per_resource)),
          requested_kg: claim.fetch(:desired)
        ).freeze
      end.freeze
    end

    # Material must satisfy BOTH ports' tag filters — a gas outlet feeding a liquid inlet
    # moves nothing, which is a wiring mistake the operation should be able to make.
    def eligible_parcels(state, out_port, in_port, content)
      state.fetch(:parcels, []).select do |p|
        resource = p.fetch(:resource)
        out_port.accepts?(resource, content) && in_port.accepts?(resource, content)
      end
    end

    # Split a desired mass across the resources actually present, proportional to what is
    # there, so a drawn mixture has the same composition as the mixture it left behind.
    def apportion(desired, parcels)
      total = parcels.sum { |p| p.fetch(:kg) }
      return {} if desired <= Parcel::EPSILON || total <= Parcel::EPSILON

      parcels.to_h { |p| [ p.fetch(:resource), desired * (p.fetch(:kg) / total) ] }
    end

    # Several links drawing on one node compete for its contents, per resource.
    def scale_by_source_availability(claims, states, _content)
      demand = Hash.new(0.0)
      claims.each do |claim|
        node_id = claim.fetch(:link).from_node
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
        node_id = claim.fetch(:link).from_node
        claim.merge(per_resource: claim.fetch(:per_resource).to_h do |r, kg|
          [ r, kg * scales.fetch([ node_id, r ], 1.0) ]
        end)
      end
    end

    # Several links pushing into one node compete for its room. Volume is the currency
    # here, because that is what a vessel actually runs out of.
    def scale_by_sink_room(claims, nodes, states, content)
      incoming = Hash.new(0.0)
      claims.each do |claim|
        node_id = claim.fetch(:link).to_node
        incoming[node_id] += volume_of(claim.fetch(:per_resource), content)
      end

      scales = incoming.to_h do |node_id, wanted|
        node = nodes.fetch(node_id)
        room = node.respond_to?(:room_m3) ? node.room_m3(states.fetch(node_id), content) : Float::INFINITY
        [ node_id, wanted > room ? room / wanted : 1.0 ]
      end

      claims.map do |claim|
        scale = scales.fetch(claim.fetch(:link).to_node, 1.0)
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
    def cap_gas_by_pressure(claims, nodes, states, content)
      claims.map do |claim|
        link = claim.fetch(:link)
        sink = nodes.fetch(link.to_node)
        source = nodes.fetch(link.from_node)
        next claim unless sink.respond_to?(:gas_headroom_kg) && source.respond_to?(:pressure_pa)

        supply = source.pressure_pa(states.fetch(link.from_node), content)

        claim.merge(per_resource: claim.fetch(:per_resource).to_h { |resource, kg|
          next [ resource, kg ] unless content.tags(resource).include?(:gas)

          headroom = sink.gas_headroom_kg(states.fetch(link.to_node), supply, content, resource)
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

    # Heat is one instance of a general shape: two bodies joined by a coupling drift toward
    # a shared value. Rotation is the other. See Relaxation for the mathematics and for why
    # the per-node bound is not optional.
    def settle_heat(nodes:, states:, thermal_links:, content:, dt:)
      return {} if thermal_links.empty?

      temperatures = {}
      capacities = {}
      thermal_links.flat_map { |l| [ l.a, l.b ] }.uniq.each do |id|
        node = nodes.fetch(id)
        temperatures[id] = node.temperature_k(states.fetch(id), content)
        capacities[id] = node.total_heat_capacity(states.fetch(id), content)
      end

      Relaxation.settle(thermal_links, capacities, temperatures, dt)
    end

    # --- rotation -----------------------------------------------------------

    # Angular momentum crossing a shaft, belt or gear train. Identical mathematics to heat
    # with moment of inertia standing in for heat capacity and angular velocity for
    # temperature — which is exactly why it shares an implementation.
    #
    # Momentum is conserved to the bit. Kinetic energy is NOT, and should not be: what a
    # slipping coupling loses becomes friction heat, and the Operation puts that difference
    # on the ledger rather than letting it vanish.
    def settle_drive(nodes:, states:, drive_links:, dt:)
      return {} if drive_links.empty?

      velocities = {}
      inertias = {}
      drive_links.flat_map { |l| [ l.a, l.b ] }.uniq.each do |id|
        node = nodes.fetch(id)
        velocities[id] = node.omega(states.fetch(id))
        inertias[id] = node.moment_of_inertia
      end

      Relaxation.settle(drive_links, inertias, velocities, dt)
    end

    # --- ambient ------------------------------------------------------------

    # Waste heat: every thermal node leaks to the environment. Not arbitrated, because a
    # fixed-temperature sink cannot be overshot — the closed form converges on it.
    #
    # This is what stops a long chain being a perfect heat accumulator, and it is also what
    # makes exact energy conservation cheap: the environment is an explicit sink with a
    # ledger, not a silent hole (docs/simulation_architecture.md §8).
    def settle_ambient(nodes:, states:, content:, dt:)
      nodes.each_value.filter_map do |node|
        next unless node.respond_to?(:ambient_conductance)
        next if node.ambient_conductance <= 0.0

        state = states.fetch(node.id)
        q = Relaxation.to_reservoir(
          node.total_heat_capacity(state, content),
          node.temperature_k(state, content),
          node.ambient_k, node.ambient_conductance, dt
        )
        next if q.abs <= Parcel::EPSILON

        [ node.id, q ] # positive = node sheds to the environment
      end.to_h.freeze
    end
  end
end
