# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"

# **Mobile engines in a yard**, with nothing else there: the engine's slots (`MobileEngine.slots`),
# a fan-law load on each engine's shaft, a fireman and a driver for each. A harness, never a
# machine — so `Operations.catalogued` leaves it out.
#
# **What it owns is the yard, the load and the crew**; the engines are whatever the loadout fits.
module MobileRig
  extend Constructed

  TYPE = :mobile_engine_rig
  PLACE = :yard
  ATM = ReactorSim::Units::STANDARD_PRESSURE_PA

  # Rated near the engine's working speed, sized so the engine at work is not on its valve.
  LOAD = { moment_of_inertia: 20.0, max_torque: 4_000.0, rated_omega: 25.0 }.freeze

  PLAIN = ReactorSim::Sheet::STATS.to_h { |stat| [ stat, 1.0 ] }.freeze

  module_function

  # A shovel's own ground, in tonnes of overburden: plenty for any example, and a car that takes
  # about twenty minutes' digging.
  BENCH_KG = 300_000.0
  CAR_M3 = 20.0
  STANDPIPE_KG = 50_000.0

  # **A pit's worth of track**, for trains: the pit floor at the shovel, a haul road climbing 2% for
  # 580 m, and the dump, with buffers 20 m past the loading and dump marks.
  TRACK = ReactorSim::Operations::MobileEngine::Track.new(
    sections: [ { to_m: 60.0, place: :pit }, { to_m: 640.0, place: :haul_road, grade: 0.02 }, { to_m: 700.0, place: :dump } ],
    marks: { loading: 20.0, dump: 680.0 }
  )
  # The spoil dump the trains tip into, at the dump.
  DUMP = :spoil_dump

  # `trains:` is `{ locomotive => shovel it serves }`. With trains the shovels stand in the pit and
  # load them, and the places are the track's; without, everything is in the one yard.
  def build(id:, seed:, engines: [ :engine ], shovels: [], trains: {}, loadout: {}, time_scale: 1.0, state: nil,
            rngs: nil, content: nil)
    me = ReactorSim::Operations::MobileEngine
    engines = engines.map(&:to_sym)
    shovels = shovels.map(&:to_sym)
    trains = trains.to_h { |loco, shovel| [ loco.to_sym, shovel.to_sym ] }
    where = trains.empty? ? PLACE : TRACK.place_at(TRACK.mark(:loading))
    assembly = assembly_for(engines, shovels, trains, loadout, where)
    fragment = assembly.build!
    drivers = (engines + shovels).map { |engine| me.driver(assembly, engine, place: where) } +
              trains.keys.map { |loco| me.locomotive_driver(assembly, loco, place: footplate(loco), track: TRACK) }

    ReactorSim::Operation.new(
      id: id, type: TYPE, seed: seed, time_scale: time_scale, state: state, rngs: rngs, content: content,
      options: { engines: engines, shovels: shovels, trains: trains, loadout: assembly.loadout },
      nodes: fragment.nodes, links: fragment.links, thermal_links: fragment.thermal_links,
      drive_links: fragment.drive_links, control_points: fragment.control_points + drivers,
      diagnostics: shovels.map { |shovel| me.board(shovel, place: where) } +
                   trains.keys.map { |loco| me.train_board(loco, place: footplate(loco)) },
      places: trains.empty? ? [ ReactorSim::Place.new(id: PLACE, air: :atmosphere, exposure: 1.0, nodes: fragment.nodes.map(&:id)) ] : track_places(fragment, trains),
      minions: engines.flat_map { |engine| crew(engine, where) } +
               shovels.flat_map { |shovel| crew(shovel, where) + gang(shovel, where) } +
               trains.keys.flat_map { |loco| crew(loco, footplate(loco)) + dumpmen(loco) }
    )
  end

  def footplate(loco) = :"#{loco}_footplate"

  # **The track's places**: each train's own pieces on its footplate, the dump's tip at the dump,
  # and everything else — the shovel, its bench, the air — in the pit. What a part placed itself
  # stays where it put it.
  def track_places(fragment, trains)
    placed = fragment.places.flat_map(&:nodes)
    free = fragment.nodes.map(&:id) - placed - [ DUMP ]
    aboard = trains.keys.to_h { |loco| [ loco, free.select { |id| id.start_with?("#{loco}_") } ] }
    pit = free - aboard.values.flatten
    fragment.places +
      aboard.map { |loco, ids| ReactorSim::Place.new(id: footplate(loco), nodes: ids) } +
      [ ReactorSim::Place.new(id: :pit, label: "Pit", air: :atmosphere, exposure: 1.0, nodes: pit),
        ReactorSim::Place.new(id: :haul_road, label: "Haul Road", open_air: true, exposure: 1.0),
        ReactorSim::Place.new(id: :dump, label: "Dump", open_air: true, exposure: 1.0, nodes: [ DUMP ]) ]
  end

  def assembly_for(engines, shovels, trains, loadout, where)
    me = ReactorSim::Operations::MobileEngine
    fixtures = ReactorSim::Fragment.new(nodes: [ ReactorSim::Nodes::Atmosphere.new ])
    fixtures = engines.reduce(fixtures) { |acc, engine| acc.merge(test_load(engine)) }
    fixtures = shovels.reduce(fixtures) { |acc, shovel| acc.merge(ground(shovel, train: trains.key(shovel))) }
    fixtures = fixtures.merge(ReactorSim::Fragment.new(nodes: [ ReactorSim::Nodes::Delivery.new(id: DUMP, label: "Spoil Dump") ])) unless trains.empty?
    serving = ->(s) { host(s, train: trains.key(s)) }
    loco = ->(l) { { place: footplate(l), track: TRACK, serves: trains.fetch(l), dump: DUMP } }
    slots = engines.flat_map { |e| me.slots(e, place: where) } +
            shovels.flat_map { |s| me.shovel_slots(s, place: where, **serving.(s)) } +
            trains.keys.flat_map { |l| me.locomotive_slots(l, **loco.(l)) }
    routes = engines.flat_map { |e| me.routes(e, place: where) } +
             shovels.flat_map { |s| me.shovel_routes(s, place: where, **serving.(s)) } +
             trains.keys.flat_map { |l| me.locomotive_routes(l, **loco.(l)) }
    ReactorSim::Assembly.new(slots: slots, loadout: loadout, fixtures: fixtures, routes: routes)
  end

  def test_load(engine)
    names = names(engine)
    ReactorSim::Operations::SteamEngine.load_fragment(names: names, label: "Test Load", lever_label: "Load", **LOAD)
      .merge(ReactorSim::Fragment.new(drive_links: [
               ReactorSim::DriveLink.new(a: names.(:flywheel), b: names.(:load), stiffness: 15_000.0)
             ]))
  end

  # A shovel loading a train dumps into the train's loading landing, and the train's cars are its car.
  def host(shovel, train: nil)
    ground = { bench: :"#{shovel}_bench", standpipe: :"#{shovel}_standpipe" }
    return ground.merge(car: :"#{shovel}_car") unless train

    ground.merge(car: :"#{train}_cars", dumps_into: [ :"#{train}_loading", :inlet ])
  end

  # **What a shovel stands on**: a bench of overburden, a standpipe, and — with no train to load — a
  # car on the track beside it, emptied by a lever.
  def ground(shovel, train: nil)
    ids = host(shovel)
    solid = ->(port, direction) { ReactorSim::Port.new(id: port, direction: direction, accepts: [ :solid ], max_kg_per_s: 2_000.0) }
    standing = ReactorSim::Fragment.new(nodes: [
      ReactorSim::Nodes::Vessel.new(id: ids.fetch(:bench), label: "Bench", volume_m3: 400.0, heat_capacity: 1.0e5,
                                    initial_contents: [ { resource: :overburden, kg: BENCH_KG } ],
                                    ports: [ solid.(:out, :outlet) ]),
      ReactorSim::Nodes::Vessel.new(id: ids.fetch(:standpipe), label: "Standpipe", volume_m3: 60.0, heat_capacity: 1.0e4,
                                    initial_contents: [ { resource: :water, kg: STANDPIPE_KG } ],
                                    ports: [ ReactorSim::Port.new(id: :out, direction: :outlet, accepts: [ :liquid ],
                                                                  max_kg_per_s: 5.0) ])
    ])
    return standing if train

    standing.merge(ReactorSim::Fragment.new(
      nodes: [
        ReactorSim::Nodes::Vessel.new(id: ids.fetch(:car), label: "Car", volume_m3: CAR_M3, heat_capacity: 1.0e4,
                                      ports: [ solid.(:in, :inlet), solid.(:out, :outlet) ]),
        ReactorSim::Nodes::Conduit.new(id: :"#{shovel}_unloading", label: "Unloading", accepts: [ :solid ],
                                       max_kg_per_s: 2_000.0, heat_capacity: 1.0e3, control_id: :"#{shovel}_unload"),
        ReactorSim::Nodes::Delivery.new(id: :"#{shovel}_tip", label: "Tip")
      ],
      links: [ ReactorSim::Link.new(from: [ ids.fetch(:car), :out ], to: [ :"#{shovel}_unloading", :inlet ]),
               ReactorSim::Link.new(from: [ :"#{shovel}_unloading", :outlet ], to: [ :"#{shovel}_tip", :in ]) ],
      control_points: [ ReactorSim::ControlPoint.new(id: :"#{shovel}_unload", label: "Unload the Car",
                                                     node: :"#{shovel}_unloading", place: PLACE, default: 0.0) ]
    ))
  end

  # A fireman on the engine and a driver with his ticket, both ordinary hands.
  def crew(engine, place = PLACE)
    names = ReactorSim::Operations::MobileEngine.names(engine, place: place)
    [ ReactorSim::Minion.new(id: names.(:fireman), name: "Fireman", station: names.(:stoking), place: place,
                             stats: PLAIN, mass_kg: 70.0),
      ReactorSim::Minion.new(id: names.(:driver), name: "Driver", station: names.(:driving), place: place,
                             stats: PLAIN, tags: { licensed: true }, mass_kg: 70.0) ]
  end

  def hand(id, station, place) = ReactorSim::Minion.new(id: id, name: id.to_s, station: station, place: place, stats: PLAIN, mass_kg: 70.0)

  # The craneman and a full gang of pitmen.
  def gang(shovel, place = PLACE, pitmen: ReactorSim::Operations::MobileEngine::YARD.fetch(:pitmen))
    names = names(shovel)
    [ hand(names.(:crane_hand), names.(:craneman), place) ] +
      Array.new(pitmen) { |i| hand(names.(:"pitman_#{i + 1}"), names.(:pitmen), place) }
  end

  # Two at the dump to tip a train.
  def dumpmen(loco)
    post = names(loco).(:dumpmen)
    Array.new(ReactorSim::Operations::MobileEngine::DUMPMEN) { |i| hand(:"#{loco}_dumpman_#{i + 1}", post, :dump) }
  end

  ReactorSim::Operations.register(TYPE, harness: true) do |id:, seed:, engines: [ :engine ], shovels: [], trains: {},
                                                            loadout: {}, time_scale: 1.0, state: nil, rngs: nil, content: nil|
    build(id: id, seed: seed, engines: engines, shovels: shovels, trains: trains, loadout: loadout,
          time_scale: time_scale, state: state, rngs: rngs, content: content)
  end

  # --- at work ---------------------------------------------------------------------------

  # The test load as it was observed beside an engine at work (`MobileEngine::AT_WORK`).
  LOAD_AT_WORK_L = 620.8

  # `op` with `engine` at work, asked for `demand` — the library's own start
  # (`MobileEngine.raised`), and the rig's test load turning with it where there is one.
  def at_work(op, engine = :engine, demand: 60.0)
    op = ReactorSim::Operations::MobileEngine.raised(op, [ engine ], demand: demand)
    n = names(engine)
    return op unless op.nodes.key?(n.(:load))

    seed(op, nodes: { n.(:load) => { angular_momentum: LOAD_AT_WORK_L } },
             controls: { n.(:load_demand) => { target: 60.0, actual: 60.0 } })
  end

  # --- readings -------------------------------------------------------------------------

  def node(op, id) = op.nodes.fetch(id)
  def state(op, id) = op.state.dig(:nodes, id)
  def names(engine) = ReactorSim::Operations::MobileEngine.names(engine, place: PLACE)

  def pressure_atm(op, engine = :engine)
    id = names(engine).(:boiler)
    node(op, id).pressure_pa(state(op, id), op.content) / ATM
  end

  def fill(op, engine = :engine)
    id = names(engine).(:boiler)
    node(op, id).effective_fill(state(op, id), op.content)
  end

  def omega(op, engine = :engine)
    id = names(engine).(:flywheel)
    node(op, id).omega(state(op, id))
  end

  def lever(op, id) = op.state.dig(:controls, id, :actual)
  def held_kg(op, id) = ReactorSim::Parcel.total_kg(state(op, id).fetch(:parcels, []))
end
