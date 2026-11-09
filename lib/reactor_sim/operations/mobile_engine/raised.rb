# frozen_string_literal: true

module ReactorSim
  module Operations
    module MobileEngine
      # **A vertical-boiler engine as it was observed at work**: raised, then run ten minutes with
      # its driver asked for 60 — 104 kW from a 900 kW fire, the drum at 8 atm on its dead-weight
      # valve, the shaft at 34 rad/s, the fire a 30 kg bed burning what the fireman feeds it. Read
      # off a running engine, so it is a state the engine reaches.
      #
      # **The advance shift raised her steam**, so this is how every mobile engine starts a match,
      # and how every spec seeds one: one set of figures, so the engines stay in step and a retune
      # moves them all. See `docs/design_sketches/mobile-engines.md` §3.
      AT_WORK = {
        fire_bed: { kelvin: 1_115.6, air: 0.052, ash: 0.0007, coal: 29.96, flue_gas: 0.089, alight_kg: 29.9 },
        firebox: { kelvin: 1_043.3, air: 0.094, flue_gas: 0.160 },
        boiler: { kelvin: 443.5, water: 513.5, steam: 2.71 },
        injector: { kelvin: 351.3, steam: 0.183, water: 0.105 },
        steam_chest: { kelvin: 431.1, steam: 0.449, water: 0.005 },
        cylinder: { kelvin: 291.8, steam: 0.0398, water: 0.0093 },
        walls: { boiler_tubes: 527.5, flue: 416.7, ash_pan: 341.9, injector_steam: 426.5, throttle: 443.5,
                 piston_rings: 360.8, relief: 405.8 },
        flywheel_l: 10_045.4, throttle: 60.0, feed: 95.5
      }.freeze

      # **The heavy engine at work**, observed the same way with the test load asked for all it
      # takes: 167 kW from twice the vertical engine's fire, a 60 kg bed, the drum at 8 atm.
      HEAVY_AT_WORK = {
        fire_bed: { kelvin: 1_008.6, air: 0.238, ash: 0.0015, coal: 59.49, flue_gas: 0.177, alight_kg: 59.34 },
        firebox: { kelvin: 966.0, air: 0.252, flue_gas: 0.187 },
        boiler: { kelvin: 443.6, water: 1_152.5, steam: 4.93 },
        injector: { kelvin: 354.6, steam: 0.162, water: 0.037 },
        steam_chest: { kelvin: 427.7, steam: 0.653, water: 0.0 },
        cylinder: { kelvin: 290.0, steam: 0.0678, water: 0.0129 },
        walls: { boiler_tubes: 542.5, flue: 464.7, ash_pan: 372.8, injector_steam: 420.1, throttle: 443.5,
                 piston_rings: 401.0, relief: 431.0 },
        flywheel_l: 23_565.2, throttle: 33.9, feed: 16.5
      }.freeze

      BY_ENGINE = { vertical_engine: AT_WORK, heavy_vertical_engine: HEAVY_AT_WORK }.freeze

      module_function

      # `op` with each of `engines` at work, its driver asked for `demand`, at the figures of the
      # engine its loadout fits. Only for an operation just built: a restore carries its own state,
      # and this is the state a match starts in.
      def raised(op, engines, demand: 60.0)
        snapshot = ReactorSim.deep_symbolize(op.to_h)
        engines.each do |engine|
          names = Names.new(engine, place: engine)
          at_work = BY_ENGINE.fetch(op.options.fetch(:loadout).fetch(names.(:engine)))
          raise_engine(snapshot.fetch(:state), op, names, demand, at_work)
        end
        Operation.from_h(snapshot)
      end

      def raise_engine(state, op, names, demand, at_work)
        nodes = state.fetch(:nodes)
        body = ->(role) {
          figures = at_work.fetch(role)
          id = names.(role)
          kg = figures.except(:kelvin, :alight_kg)
          nodes[id] = nodes.fetch(id).merge(joules: op.nodes.fetch(id).heat_capacity * figures.fetch(:kelvin),
                                            parcels: parcels_at(figures.fetch(:kelvin), kg, op.content))
        }
        %i[fire_bed firebox boiler injector steam_chest cylinder].each(&body)
        fire = names.(:fire_bed)
        # Each transition's latch seeded too, so an engine raised before the match does not announce
        # that its fire caught or its steam came up.
        nodes[fire] = nodes.fetch(fire).merge(
          ignition: nodes.fetch(fire).fetch(:ignition, {}).merge(coal_combustion: { kg: at_work.dig(:fire_bed, :alight_kg) }),
          alight: true
        )
        nodes[names.(:boiler)] = nodes.fetch(names.(:boiler)).merge(full_head: true)
        at_work.fetch(:walls).each do |role, kelvin|
          id = names.(role)
          nodes[id] = nodes.fetch(id).merge(joules: op.nodes.fetch(id).heat_capacity * kelvin) if nodes.key?(id)
        end
        nodes[names.(:flywheel)] = nodes.fetch(names.(:flywheel)).merge(angular_momentum: at_work.fetch(:flywheel_l))

        lever = ->(value) { { target: value, actual: value } }
        controls = state.fetch(:controls)
        { driving: demand, throttle_open: at_work.fetch(:throttle), feed: at_work.fetch(:feed) }.each do |role, value|
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
