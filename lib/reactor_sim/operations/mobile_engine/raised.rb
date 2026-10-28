# frozen_string_literal: true

module ReactorSim
  module Operations
    module MobileEngine
      # **A vertical-boiler engine as it was observed at work**: raised, then run ten minutes with
      # its driver asked for 60 — 81 kW from an 890 kW fire, the drum at 8 atm on its dead-weight
      # valve, the shaft at 34 rad/s, the fire burning what the fireman feeds it. Read off a running
      # engine, so it is a state the engine reaches.
      #
      # **The advance shift raised her steam**, so this is how every mobile engine starts a match,
      # and how every spec seeds one: one set of figures, so the engines stay in step and a retune
      # moves them all. See `docs/design_sketches/mobile-engines.md` §3.
      AT_WORK = {
        firebox: { kelvin: 1_033.3, air: 0.172, ash: 0.0007, coal: 0.044, flue_gas: 0.247, alight_kg: 0.0203 },
        boiler: { kelvin: 443.6, water: 493.3, steam: 2.79 },
        injector: { kelvin: 355.7, steam: 0.10, water: 0.0001 },
        steam_chest: { kelvin: 430.8, steam: 0.447, water: 0.005 },
        cylinder: { kelvin: 291.6, steam: 0.039, water: 0.0091 },
        walls: { boiler_tubes: 530.3, flue: 422.4, ash_pan: 336.8, injector_steam: 354.9, throttle: 443.5,
                 piston_rings: 359.4, relief: 423.2 },
        flywheel_l: 9_962.1, throttle: 60.0, feed: 0.0
      }.freeze

      module_function

      # `op` with each of `engines` at work, its driver asked for `demand`. Only for an operation
      # just built: a restore carries its own state, and this is the state a match starts in.
      def raised(op, engines, demand: 60.0)
        snapshot = ReactorSim.deep_symbolize(op.to_h)
        engines.each { |engine| raise_engine(snapshot.fetch(:state), op, Names.new(engine, place: engine), demand) }
        Operation.from_h(snapshot)
      end

      def raise_engine(state, op, names, demand)
        nodes = state.fetch(:nodes)
        body = ->(role) {
          figures = AT_WORK.fetch(role)
          id = names.(role)
          kg = figures.except(:kelvin, :alight_kg)
          nodes[id] = nodes.fetch(id).merge(joules: op.nodes.fetch(id).heat_capacity * figures.fetch(:kelvin),
                                            parcels: parcels_at(figures.fetch(:kelvin), kg, op.content))
        }
        %i[firebox boiler injector steam_chest cylinder].each(&body)
        firebox = names.(:firebox)
        nodes[firebox] = nodes.fetch(firebox).merge(
          ignition: nodes.fetch(firebox).fetch(:ignition, {}).merge(coal_combustion: { kg: AT_WORK.dig(:firebox, :alight_kg) })
        )
        AT_WORK.fetch(:walls).each do |role, kelvin|
          id = names.(role)
          nodes[id] = nodes.fetch(id).merge(joules: op.nodes.fetch(id).heat_capacity * kelvin) if nodes.key?(id)
        end
        nodes[names.(:flywheel)] = nodes.fetch(names.(:flywheel)).merge(angular_momentum: AT_WORK.fetch(:flywheel_l))

        lever = ->(value) { { target: value, actual: value } }
        controls = state.fetch(:controls)
        { driving: demand, throttle_open: AT_WORK.fetch(:throttle), feed: AT_WORK.fetch(:feed) }.each do |role, value|
          controls[names.(role)] = controls.fetch(names.(role)).merge(lever.(value))
        end
      end

      def parcels_at(kelvin, kg_by_resource, content)
        Parcel.normalise(kg_by_resource.reject { |_, kg| kg.zero? }.map do |resource, kg|
          Parcel.build(resource: resource, kg: kg, temperature_k: kelvin, content: content)
        end)
      end
    end
  end
end
