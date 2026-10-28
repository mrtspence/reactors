# frozen_string_literal: true

module ReactorSim
  module Operations
    # **A steam engine that goes where the work is** — the shovel's, the locomotive's — built from
    # the stationary engine's own pieces at a tenth the size, as an engine of its own rather than a
    # load on anybody's line shaft. Its coal and water are its own.
    #
    # **Full fidelity inside, little to watch outside.** An operation may carry several, so most of
    # the engine's levers are internal and held where its blueprint sets them; two people work it —
    # the fireman, an effort post stoking at the blueprint's rate, and the driver, a governor post
    # working the throttle to what he is asked and the feed to the water (`Driver`). The gauges fitted
    # are the driver's, not the player's.
    #
    # An engine is a set of slots named for it (`slots`), fitted like any other part, with a host —
    # the pit, a rig — supplying the air, the place it stands in and what it drives. See
    # `docs/design_sketches/mobile-engines.md`.
    module MobileEngine
      # What he makes of the water with nothing to read it by, and of the pressure with no gauge:
      # full or empty, and by the sound of her.
      BLIND_WATER_STEP = 0.5
      BY_EAR_PA = Units::STANDARD_PRESSURE_PA

      module_function

      def names(engine, place:) = Names.new(engine, place: place)

      # **The slots of one engine**, named for it, so two shovels are two sets. The machine itself is
      # one part; what is tiered around it — the safety valve, what reads the water and the pressure,
      # a fusible plug, the bunker and the tank — are slots of their own. `host:` is what the
      # operation it stands in gives it, by id: a shovel's `bench:`, `car:` and `standpipe:`.
      # `needs:` is the slot the engine belongs to, where the machine is an upgrade: every engine
      # slot is then built only while that one is fitted (`Slot#needs`), and the machine's slots
      # are a group of their own on the outfitting screen, named for it.
      def slots(engine, place:, needs: nil, **host)
        spec = { names: names(engine, place: place), host: host.freeze }
        group = needs ? engine.to_sym : :engine
        slot = ->(role, **opts) { Slot.new(id: spec.fetch(:names).(role), spec: spec, group: group, needs: needs, **opts) }

        [
          slot.(:engine, accepts: :mobile_engine, label: "Engine", required: true, default: :vertical_engine),
          slot.(:bunker, accepts: :mobile_bunker, label: "Bunker", required: true, default: :small_bunker),
          slot.(:tank, accepts: :mobile_tank, label: "Tank", required: true, default: :small_tank),
          slot.(:safety_valve, accepts: :mobile_safety_valve, label: "Safety Valve", default: :dead_weight_valve),
          slot.(:water_reading, accepts: :mobile_water_reading, label: "Water Reading", default: :mobile_try_cocks),
          slot.(:pressure_reading, accepts: :mobile_pressure_reading, label: "Pressure Gauge"),
          slot.(:fusible_plug, accepts: :mobile_fusible_plug, label: "Fusible Plug")
        ]
      end

      # **A shovel**: an engine's slots, and the dipper, its chain and its boom. It digs from the
      # host's `bench:` into its `car:`, and its tank fills by hose from its `standpipe:`.
      # `dumps_into:` is the `[node, port]` the dipper dumps into, where that is not the car's own
      # inlet — a train's loading landing.
      #
      # `cast_to:` is the `[node, port]` it casts onto while no train stands at `cars:` — the
      # train's `{ carrier:, mark_m: }` — if the player lets it (`names.(:casting)`). `upgrade:`
      # makes the whole shovel optional: its dipper slot, labelled so, empty to start, and every
      # other slot `needs:` it.
      def shovel_slots(shovel, place:, bench:, car:, standpipe:, dumps_into: nil, cast_to: nil, cars: nil, upgrade: nil)
        host = { bench: bench, car: car, standpipe: standpipe, dumps_into: dumps_into, cast_to: cast_to, cars: cars }.compact
        principal = names(shovel, place: place).(:dipper)
        engine = slots(shovel, place: place, needs: upgrade && principal, **host)
        spec = engine.first.spec
        slot = ->(role, **opts) { Slot.new(id: spec.fetch(:names).(role), spec: spec, group: engine.first.group, **opts) }
        needs = upgrade && principal

        engine + [
          upgrade ? slot.(:dipper, accepts: :shovel_dipper, label: upgrade, default: nil)
                  : slot.(:dipper, accepts: :shovel_dipper, label: "Dipper", required: true, default: :yard_dipper),
          slot.(:chain, accepts: :shovel_chain, label: "Hoisting Chain", required: true, default: :iron_chain, needs: needs),
          slot.(:boom, accepts: :shovel_boom, label: "Boom", required: true, default: :timber_boom, needs: needs)
        ]
      end

      # **The shovel's board**: what the crew would shout, the first that holds (`Dipper::SIGNALS`).
      # True, with no lag and nobody it is read through, as the cage's is — somebody in the cab knows.
      def board(shovel, place:)
        n = names(shovel, place: place)
        Diagnostic.new(id: n.(:board), label: "Shovel", source: Sources::Field.new(n.(:dipper), :signal),
                       display: Displays::Prose.new(Dipper::SIGNALS.values))
      end

      # The dig reaches the car whatever it goes through on the way.
      # A shovel that is an `upgrade:` is checked only while it is fitted.
      def shovel_routes(shovel, place:, bench:, car:, standpipe:, upgrade: nil, **)
        n = names(shovel, place: place)
        needs = upgrade && n.(:dipper)
        routes(shovel, place: place, needs: needs) +
          [ { from: bench, to: car, carrying: :solid, as: "#{shovel}: nothing carries the dig from the bench to the car" },
            { from: standpipe, to: n.(:supply), carrying: :liquid, as: "#{shovel}: no hose from the standpipe" } ]
            .map { |route| needs ? route.merge(needs: needs) : route }
      end

      # What "this engine can run at all" means, as `SteamEngine::ROUTES` does for the stationary one.
      def routes(engine, place:, needs: nil)
        n = names(engine, place: place)
        [ { from: n.(:bunker), to: n.(:firebox), carrying: :fuel, as: "#{engine}: no route for coal to the grate" },
          { from: :atmosphere, to: n.(:firebox), carrying: :gas, as: "#{engine}: no route for air to the fire" },
          { from: n.(:firebox), to: :atmosphere, carrying: :gas, as: "#{engine}: the fire cannot breathe out" },
          { from: n.(:supply), to: n.(:boiler), carrying: :liquid, as: "#{engine}: no route for water to the boiler" },
          { from: n.(:boiler), to: n.(:cylinder), carrying: :gas, as: "#{engine}: no route for steam to the cylinder" } ]
          .map { |route| needs ? route.merge(needs: needs) : route }
      end

      # **The driver's post**, built once the engine is fitted, because what he reads the water and
      # the pressure by is whatever the loadout put in those slots. His own lever is what the engine
      # is asked for.
      def driver(assembly, engine, place:)
        n = names(engine, place: place)
        driving_post(n, engine_driver(assembly, n))
      end

      # Live steam, a fire and somebody else's life on the footplate: the hot-work ticket's.
      def driving_post(names, governor)
        ControlPoint.new(id: names.(:driving), label: "Driver", node: names.(:throttle), default: 0.0,
                         place: names.place, complexity: 0.8, requires: :licensed, governor: governor)
      end

      def engine_driver(assembly, names)
        water = assembly.part(names.(:water_reading))&.stats&.fetch(:water_step) || BLIND_WATER_STEP
        pressure = assembly.part(names.(:pressure_reading))&.stats&.fetch(:pressure_step_pa) || BY_EAR_PA
        engine = assembly.part(names.(:engine)).stats
        hose = assembly.fragment.nodes.any? { |node| node.id == names.(:hose) }
        Driver.new(boiler: names.(:boiler), throttle: names.(:throttle_open), feed: names.(:feed),
                   working_pa: engine.fetch(:working_pressure_pa), water_step: water, pressure_step_pa: pressure,
                   shaft: names.(:flywheel), governed_omega: engine.fetch(:governed_omega),
                   **(hose ? { hose: names.(:hose_open), tank: names.(:supply),
                               tank_kg: assembly.part(names.(:tank)).stats.fetch(:water_kg) } : {}))
      end

      # --- the locomotive ------------------------------------------------------------------

      # **A locomotive**: an engine's slots, its train — the running gear and the cars, tiered
      # together because a train is weighed and braked as one — and its brake. It runs the host's
      # `track:` (a `Track`), is loaded by the shovel it `serves:` at the loading mark, and is tipped
      # into the host's `dump:` at the dump mark. `place:` is its footplate.
      #
      # `serves:` is optional: a train at a hand face has no shovel to wreck. `loaded_from:` is the
      # muck its hand loaders fill it from, and `beside:` who works where it is loaded, at peril of
      # it. `upgrade:` makes the whole dinky optional, as a shovel's is.
      def locomotive_slots(loco, place:, track:, dump:, serves: nil, loaded_from: nil, beside: [], upgrade: nil)
        host = { track: track, serves: serves&.to_sym, dump: dump.to_sym, loaded_from: loaded_from&.to_sym,
                 beside: Array(beside).map(&:to_sym) }.compact
        principal = names(loco, place: place).(:train)
        needs = upgrade && principal
        engine = slots(loco, place: place, needs: needs, **host)
        spec = engine.first.spec
        slot = ->(role, **opts) { Slot.new(id: spec.fetch(:names).(role), spec: spec, group: engine.first.group, **opts) }

        engine + [
          upgrade ? slot.(:train, accepts: :locomotive_train, label: upgrade, default: nil)
                  : slot.(:train, accepts: :locomotive_train, label: "Train", required: true, default: :dinkey_train),
          slot.(:brake, accepts: :locomotive_brake, label: "Brake", required: true, default: :hand_brake, needs: needs)
        ]
      end

      def locomotive_routes(loco, place:, dump:, upgrade: nil, **)
        n = names(loco, place: place)
        needs = upgrade && n.(:train)
        (routes(loco, place: place, needs: needs) +
          [ { from: n.(:cars), to: dump, carrying: :solid, as: "#{loco}: nothing tips the cars" } ])
          .map { |route| needs ? route.merge(needs: needs) : route }
      end

      # **The train's board** (`Train::SIGNALS`), as the shovel's is the dipper's.
      def train_board(loco, place:)
        n = names(loco, place: place)
        Diagnostic.new(id: n.(:board), label: "Train", source: Sources::Field.new(n.(:train), :signal),
                       display: Displays::Prose.new(Train::SIGNALS.values))
      end

      # **The driver's post on a locomotive**: the engine driver, and the round (`Round`). He calls
      # the cars full a little short of brim-full, and believes his brake does what it does on the
      # steepest bank with the train empty — which is true of a sound brake.
      def locomotive_driver(assembly, loco, place:, track:)
        n = names(loco, place: place)
        train = assembly.part(n.(:train)).stats
        brake = assembly.part(n.(:brake)).stats
        bank = track.sections.map { |s| s.fetch(:grade).abs }.max
        inertia_kg = train.fetch(:tare_kg) + (train.fetch(:load_kg) / 2.0)
        stopping_n = (brake.fetch(:capacity_nm) / train.fetch(:radius_m)) - (train.fetch(:tare_kg) * Units::GRAVITY_M_PER_S2 * bank)
        governor = Round.new(driver: engine_driver(assembly, n), train: n.(:train), forward: n.(:forward_gear),
                             reverse: n.(:reverse_gear), brake_release: n.(:brake_release),
                             full_kg: train.fetch(:load_kg) * FULL_SHARE,
                             believed_decel: [ stopping_n / inertia_kg, LEAST_BELIEVED_DECEL ].max)
        driving_post(n, governor)
      end

      # Cars this full are full: a dipperful more would spill.
      FULL_SHARE = 0.9
      LEAST_BELIEVED_DECEL = 0.05

      # **A train's working parts**: the train on its track and its cars, geared to the engine
      # through a forward and a reverse clutch; the landing that takes the shovel's dump at the
      # loading mark and the one the dumpmen tip at the dump mark; the footplate it carries.
      def train_fragment(names, host, figures)
        track = host.fetch(:track)
        loading_place = track.place_at(track.mark(:loading))
        dump_place = track.place_at(track.mark(:dump))
        gear = figures.fetch(:rated_m_s) / (figures.fetch(:radius_m) * GOVERNED_OMEGA)
        clutch = ->(id, ratio) {
          DriveLink.new(id: names.(id), a: names.(:flywheel), b: names.(:train), stiffness: figures.fetch(:clutch_stiffness),
                        ratio: ratio, control_id: names.(id))
        }
        lever = ->(id, label, node, place) { ControlPoint.new(id: names.(id), label: label, node: node, place: place, internal: true) }
        Fragment.new(
          nodes: [ train(names, host, figures, loading_place, dump_place), cars(names, figures),
                   Nodes::Landing.new(id: names.(:loading), label: "Loading", accepts: [ :solid ], carrier: names.(:train),
                                      mark_m: track.mark(:loading), max_kg_per_s: 2_000.0, heat_capacity: 1.0e3),
                   Nodes::Landing.new(id: names.(:tipping), label: "Tipping", accepts: [ :solid ], carrier: names.(:train),
                                      mark_m: track.mark(:dump), max_kg_per_s: TIPPING_KG_PER_S, heat_capacity: 1.0e3,
                                      control_id: names.(:dumpmen), worked: true, crew: DUMPMEN,
                                      traffic: :tipping, perils: [ caught_tipping(names) ]) ],
          links: [
            Link.new(from: [ names.(:loading), :outlet ], to: [ names.(:cars), :in ]),
            Link.new(from: [ names.(:cars), :out ], to: [ names.(:tipping), :inlet ]),
            Link.new(from: [ names.(:tipping), :outlet ], to: [ host.fetch(:dump), :in ])
          ],
          drive_links: [ clutch.(:forward_gear, gear), clutch.(:reverse_gear, -gear) ],
          control_points: [
            lever.(:forward_gear, "Forward Gear", names.(:train), names.place),
            lever.(:reverse_gear, "Reverse Gear", names.(:train), names.place),
            # Tipping the cars and digging out what sticks.
            ControlPoint.new(id: names.(:dumpmen), label: "Dumpmen", node: names.(:tipping), place: dump_place,
                             capacity: DUMPMEN, effort: { force: 0.6, swing: 0.4 }, gated_by: %i[darkvision],
                             exertion: 5.0e-4, default: 100.0, internal: true)
          ],
          places: [ Place.new(id: names.place, label: "Footplate", carried_by: names.(:train), shares: FOOTPLATE_SHARES,
                              open_air: true, nodes: [ names.(:train), names.(:cars) ]),
                    Place.new(id: loading_place, nodes: [ names.(:loading) ]),
                    Place.new(id: dump_place, nodes: [ names.(:tipping) ]) ]
        ).merge(host[:loaded_from] ? hand_loading(names, host.fetch(:loaded_from), track, loading_place) : Fragment.empty)
      end

      # Two at the dump, tipping a train in about two minutes.
      DUMPMEN = 2
      TIPPING_KG_PER_S = 70.0

      # **Loaders shovelling the muck at the face into a standing train**, four to a train, each
      # about a navvy's loose-earth rate brought into play — far slower than a shovel, far quicker
      # than barrows up a ramp.
      LOADERS = 4
      LOADING_KG_PER_S = 1.2

      def hand_loading(names, muck, track, loading_place)
        Fragment.new(
          nodes: [ Nodes::Landing.new(id: names.(:hand_loading), label: "Hand Loading", accepts: [ :solid ],
                                      carrier: names.(:train), mark_m: track.mark(:loading), max_kg_per_s: LOADING_KG_PER_S,
                                      heat_capacity: 1.0e3, control_id: names.(:loaders), worked: true, crew: LOADERS) ],
          links: [ Link.new(from: [ muck, :out ], to: [ names.(:hand_loading), :inlet ]),
                   Link.new(from: [ names.(:hand_loading), :outlet ], to: [ names.(:cars), :in ]) ],
          places: [ Place.new(id: loading_place, nodes: [ names.(:hand_loading) ]) ],
          control_points: [
            ControlPoint.new(id: names.(:loaders), label: "Loaders", node: names.(:hand_loading), place: loading_place,
                             capacity: LOADERS, effort: { force: 0.6, swing: 0.4 }, gated_by: %i[darkvision],
                             exertion: 8.0e-4, default: 100.0)
          ]
        )
      end

      # An open footplate: half of what happens on it reaches where it stands, and back.
      FOOTPLATE_SHARES = 0.5

      # Who is at peril of it where it is loaded: the shovel's pitmen if it serves one, whoever the
      # host says works there, and its own loaders. A crash wrecks the shovel it serves.
      def train(names, host, figures, loading_place, dump_place)
        shovel = host[:serves] && MobileEngine.names(host.fetch(:serves), place: loading_place)
        beside = (shovel ? [ shovel.(:pitmen) ] : []) + host.fetch(:beside, []) +
                 (host[:loaded_from] ? [ names.(:loaders) ] : [])
        Train.new(
          id: names.(:train), label: "Train", track: host.fetch(:track), cars: names.(:cars), brake: names.(:brake),
          loader: names.(:loading), tipper: names.(:tipping), demand_control: names.(:driving),
          engine: { boiler: names.(:boiler), supply: names.(:supply), firebox: names.(:firebox), relief: names.(:relief),
                    working_pa: VERTICAL.dig(:boiler, :working_pressure_pa) },
          perils: [ struck_by_train(loading_place, beside, loading_place),
                    struck_by_train(dump_place, [ names.(:dumpmen) ], dump_place) ],
          endangers: runaways(names, loading_place, dump_place),
          damages: shovel ? { crashed: { shovel.(:boom) => 1.0, shovel.(:dipper) => 1.0 } } : {},
          **figures.slice(:tare_kg, :load_kg, :radius_m, :rated_m_s)
        )
      end

      def cars(names, figures)
        Nodes::Vessel.new(
          id: names.(:cars), label: "Cars", volume_m3: figures.fetch(:cars_m3), heat_capacity: 2.0e3 * figures.fetch(:cars),
          ambient_conductance: 20.0,
          ports: [ Port.new(id: :in, direction: :inlet, accepts: [ :solid ], max_kg_per_s: 2_000.0),
                   Port.new(id: :out, direction: :outlet, accepts: [ :solid ], max_kg_per_s: 2_000.0) ]
        )
      end

      # **Struck by the train moving through where somebody works**, and a man can be pushed in
      # front of it.
      def struck_by_train(where, stations, place)
        Peril.new(id: :"struck_by_train_at_#{where}", wounds: { impact: 0.6, crush: 0.4 }, severity: 2.5, rate: 0.2,
                  scales_with: place, stations: stations, opportunity: true)
      end

      def caught_tipping(names)
        Peril.new(id: :caught_tipping, wounds: { crush: 0.5, impact: 0.5 }, severity: 1.5, rate: 0.15,
                  scales_with: :tipping, stations: [ names.(:dumpmen) ])
      end

      # **What a train does when it leaves the road**: into the shovel and its pitmen at the loading
      # end, over the edge with whoever is on her at the tip, and off the rails anywhere — shared to
      # wherever that is through the footplate. By how fast she was going.
      def runaways(names, loading_place, dump_place)
        hit = { wounds: { crush: 0.6, impact: 0.4 }, scales_with: :speed_m_s }
        { crashed: hit.merge(reference: 4.0, places: { loading_place => 4.0, names.place => 8.0 }),
          over_the_tip: hit.merge(reference: 3.0, places: { dump_place => 2.0, names.place => 10.0 }),
          derailed: hit.merge(reference: 6.0, places: { names.place => 6.0 }) }
      end

      # **The fixed pieces of a vertical-boiler engine**, at the figures `parts.rb` gives them: the
      # stationary engine's own fragments under this engine's names, with every lever but the
      # fireman's held by the blueprint.
      def engine_fragment(names, figures)
        held = ->(default) { { default: default, internal: true } }
        [
          SteamEngine.firebox_fragment(names: names, igniter: false, **figures.fetch(:firebox)),
          SteamEngine.stoker_fragment(names: names, lever: held.(figures.fetch(:firing)), **figures.fetch(:stoker)),
          SteamEngine.damper_fragment(names: names, conductance: figures.fetch(:damper), **held.(figures.fetch(:damper_open))),
          Fragment.new(links: [ Link.new(from: [ :atmosphere, :intake ], to: [ names.(:damper), :inlet ]) ]),
          SteamEngine.ash_pan_fragment(names: names, worked: false, default: figures.fetch(:shaking)),
          SteamEngine.boiler_tubes_fragment(names: names, **figures.fetch(:tubes)),
          # Exhausting up the stack, so she draws as hard as she works — a short stack over a small
          # fire hardly draws at all on buoyancy.
          SteamEngine.chimney_fragment(blastpipe: true, names: names, **figures.fetch(:chimney)),
          SteamEngine.boiler_fragment(names: names, endangers: footplate(names), **figures.fetch(:boiler)),
          SteamEngine.feedwater_fragment(names: names, feed: held.(0.0), **figures.fetch(:feedwater)),
          SteamEngine.regulator_fragment(names: names, throttle: held.(0.0), conductance: figures.fetch(:throttle)),
          SteamEngine.steam_chest_fragment(names: names, **figures.fetch(:steam_chest)),
          SteamEngine.cylinder_fragment({ exhausts_to: names.(:flue) }, names: names,
                                        cutoff: held.(figures.fetch(:cutoff)), **figures.fetch(:cylinder)),
          Fragment.new(links: [ Link.new(from: [ names.(:cylinder), :exhaust ], to: [ names.(:flue), :inlet ]) ]),
          SteamEngine.drain_cocks_fragment(names: names, cocks: held.(0.0)),
          SteamEngine.flywheel_fragment(names: names, belted: false, **figures.fetch(:flywheel))
        ].reduce(Fragment.empty) { |acc, piece| acc.merge(piece) }
      end

      # **A shovel's working parts** at a dipper's figures: the reach the pitmen keep and the dipper
      # the craneman fills, the hose the driver works, and the posts that work them. Every lever is
      # held: the pitmen and the craneman work flat out at whatever they can manage.
      def shovel_fragment(names, host, figures)
        held = ->(default) { { default: default, internal: true } }
        reach = Nodes::Vessel.new(
          id: names.(:reach), label: "Face in Reach", volume_m3: figures.fetch(:reach_m3),
          heat_capacity: 1.0e3, ambient_conductance: 0.0,
          ports: [ Port.new(id: :in, direction: :inlet, accepts: [ :solid ], max_kg_per_s: 200.0),
                   Port.new(id: :out, direction: :outlet, accepts: [ :solid ], max_kg_per_s: 200.0) ]
        )
        moving_up = MovingUp.new(id: names.(:moving_up), label: "Moving Up", accepts: [ :solid ], face: host.fetch(:bench),
                                 max_kg_per_s: figures.fetch(:moving_up_kg_per_s), heat_capacity: 1.0e3,
                                 control_id: names.(:pitmen), worked: true, crew: figures.fetch(:pitmen))
        hose = Nodes::Conduit.new(id: names.(:hose), label: "Hose", accepts: [ :liquid ], max_kg_per_s: 2.0,
                                  heat_capacity: 2.0e2, ambient_conductance: 0.0, control_id: names.(:hose_open))
        Fragment.new(
          nodes: [ reach, moving_up, dipper(names, host, figures), hose ],
          links: [
            Link.new(from: [ host.fetch(:bench), :out ], to: [ names.(:moving_up), :inlet ]),
            Link.new(from: [ names.(:moving_up), :outlet ], to: [ names.(:reach), :in ]),
            Link.new(from: [ names.(:reach), :out ], to: [ names.(:dipper), :in ]),
            Link.new(from: [ names.(:dipper), :out ], to: host.fetch(:dumps_into) { [ host.fetch(:car), :in ] }),
            *([ Link.new(from: [ names.(:dipper), :cast ], to: host.fetch(:cast_to)) ] if host[:cast_to]),
            Link.new(from: [ host.fetch(:standpipe), :out ], to: [ names.(:hose), :inlet ]),
            Link.new(from: [ names.(:hose), :outlet ], to: [ names.(:supply), :in ])
          ],
          control_points: [
            # Bringing the face to the dipper: shifting the track, blocking the jacks, clearing spill —
            # and splicing a parted chain. Work out of doors, so by the light there is.
            ControlPoint.new(id: names.(:pitmen), label: "Pitmen", node: names.(:moving_up), place: names.place,
                             capacity: figures.fetch(:pitmen), effort: { force: 0.6, swing: 0.4 }, gated_by: %i[darkvision],
                             exertion: 6.0e-4, **held.(100.0)),
            # Setting the depth of cut and tripping the door over the car.
            ControlPoint.new(id: names.(:craneman), label: "Craneman", node: names.(:dipper), place: names.place,
                             effort: { dexterity: 0.6, intelligence: 0.4 }, gated_by: %i[darkvision], exertion: 3.0e-4,
                             **held.(100.0)),
            ControlPoint.new(id: names.(:hose_open), label: "Hose", node: names.(:hose), place: names.place,
                             **held.(0.0)),
            # **How much the shovel is left to itself**: with no train standing, cast what it digs
            # onto the muck, or wait for one. The player's.
            *([ ControlPoint.new(id: names.(:casting), label: "Cast While No Train", node: names.(:dipper),
                                 place: names.place, default: 100.0) ] if host[:cast_to])
          ]
        )
      end

      def dipper(names, host, figures)
        Dipper.new(
          id: names.(:dipper), label: "Dipper", driven_by: names.(:flywheel), crane_control: names.(:craneman),
          demand_control: names.(:driving), chain: names.(:chain), boom: names.(:boom),
          reach: names.(:reach), face: host.fetch(:bench),
          cast: host[:cast_to] && host.fetch(:cars).merge(control: names.(:casting)),
          engine: { boiler: names.(:boiler), supply: names.(:supply), firebox: names.(:firebox), relief: names.(:relief),
                    working_pa: VERTICAL.dig(:boiler, :working_pressure_pa) },
          perils: [ struck_by_dipper(names) ],
          **figures.slice(:capacity_kg, :fill_kg_per_s, :swing_s, :lift_m, :work_j_per_kg, :swing_w, :rated_omega)
        )
      end

      # **Struck by the dipper as it swings**: anybody working beside it, only while it swings, and a
      # pitman can be pushed into it.
      def struck_by_dipper(names)
        Peril.new(id: :struck_by_dipper, wounds: { impact: 1.0 }, severity: 2.0, rate: 0.25, scales_with: :swinging,
                  stations: [ names.(:pitmen), names.(:craneman) ], opportunity: true)
      end

      # **Whoever is on the footplate when she goes**: the place she stands in, near enough that a
      # drum letting go reaches all of it.
      def footplate(names)
        { explosion: { wounds: { blast: 0.6, burn: 0.4 }, scales_with: :flash_expansion, reference: 22.0,
                       places: { names.place => 12.0 } },
          seam_split: { wounds: { burn: 1.0 }, scales_with: :flash_expansion, reference: 22.0,
                        places: { names.place => 0.9 } } }
      end
    end
  end
end
