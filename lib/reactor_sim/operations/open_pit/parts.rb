# frozen_string_literal: true

module ReactorSim
  module Operations
    module OpenPit
      # **The places, all open to the sky.** The bank holds the air; everywhere else breathes it.
      # A fitting places what it installs, so the truth is the assembled layout:
      #
      #     ruby -Ilib -e 'require "reactor_sim"
      #       op = ReactorSim::Operations::OpenPit.build(id: "p", seed: 1)
      #       op.layout.places.each { |p| puts "#{p}: #{op.nodes.keys.select { |n| op.layout.place_of_node(n) == p }}" }'
      PLACES = [
        Place.new(id: :bank, label: "Bank", exposure: 1.0, air: :atmosphere,
                  nodes: %i[atmosphere outdoors ore_bin line_shaft head_tank washed_ore]),
        # **The mud dam and the reservoir**, on the ground above the pit: whatever lets go here runs
        # down into the sump.
        Place.new(id: :dams, label: "The Dams", exposure: 1.0, open_air: true),
        Place.new(id: :stripping_bench, label: "Stripping Bench", exposure: 1.0, open_air: true,
                  nodes: %i[stripping_bench stripping_muck]),
        # The bottom of the pit, where its water stands.
        Place.new(id: :ore_bench, label: "Ore Bench", exposure: 1.0, open_air: true, water: :sump,
                  nodes: %i[ore_bench ore_muck sump bailing]),
        Place.new(id: :spoil_dump, label: "Spoil Dump", exposure: 1.0, open_air: true,
                  nodes: %i[tip_head spreading spoil_dump]),
        # Where the dinkies run between the faces and their dumps.
        Place.new(id: :haul_road, label: "Haul Road", exposure: 1.0, open_air: true)
      ].freeze

      # A muck pile at the face: what has been got and not yet carried out. About two tonnes and a
      # half; the face's board calls it full a little short of that.
      MUCK_M3 = 1.5
      MUCK_FULL = 0.9

      # The tip head the barrows run out onto, and what the dumpmen spread it from. Unspread, it
      # fills in about twenty minutes of stripping and the barrows have nowhere to tip.
      TIP_HEAD_M3 = 2.0

      # The carry at the top of the ramp: to the tip head, and across the bank to the bin.
      CARRY_M = { stripping: 25.0, ore: 30.0 }.freeze

      # --- getting and carrying out -----------------------------------------------------------
      #
      # Each face has a getting slot and a carrying slot, told which face they are by their slot's
      # names, so one part serves both faces.

      # **Picks and shovels**: four getters a face, each winning about 0.6 kg/s of loose ground — a
      # navvy's twenty tonnes a day of earth, brought into an hour's play. `swing`, a tool at the end
      # of an arm, and gated on a pick as hewing is.
      #
      # **Every job in the pit is gated on light**, and the pit has none of its own: the sky lights
      # it by day, and at night only somebody who sees in the dark works. TODO: lighting for night
      # work, as blueprints — the pit's first caller of a lighting slot.
      Parts.register(:pick_and_shovel, kind: :pit_getting, label: "Picks and Shovels",
                     description: "A gang with picks and shovels. Slow, and slower in bad ground.",
                     provides: %i[getting], stats: { max_kg_per_s: 0.6, crew: 4 }) do |spec|
        OpenPit.getting_fragment(spec.fetch(:names), max_kg_per_s: 0.6, crew: 4)
      end

      # **Barrows up a plank ramp**: four barrowmen a face, a 90 kg barrowful a trip. `force` — a
      # loaded barrow up a ramp is friction and lift.
      Parts.register(:barrows, kind: :pit_carrying, label: "Barrows",
                     description: "Barrows and a plank ramp. Every tonne walked up out of the pit.",
                     provides: %i[carrying], stats: { barrow_kg: 90.0, crew: 4 }) do |spec|
        OpenPit.barrows_fragment(spec.fetch(:names), spec.fetch(:tips_into), barrow_kg: 90.0, crew: 4)
      end

      module_function

      def getting_fragment(names, max_kg_per_s:, crew:)
        Fragment.new(
          nodes: [ Getting.new(id: names.(:getting), label: "Getting", accepts: [ :solid ], bench: names.(:bench),
                               max_kg_per_s: max_kg_per_s, heat_capacity: 2.0e3, control_id: names.(:getters),
                               worked: true, crew: crew, perils: [ fall_from_the_face(names) ]) ],
          links: [ Link.new(from: [ names.(:bench), :out ], to: [ names.(:getting), :inlet ]),
                   Link.new(from: [ names.(:getting), :outlet ], to: [ names.(:muck), :in ]) ],
          places: [ Place.new(id: names.place, nodes: [ names.(:getting) ]) ],
          control_points: [
            ControlPoint.new(id: names.(:getters), label: "#{face_label(names)} Getters", node: names.(:getting),
                             default: 100.0, place: names.place, capacity: crew,
                             effort: { swing: 0.7, force: 0.3 }, gated_by: %i[mining_effectiveness darkvision],
                             exertion: 1.0e-3)
          ]
        )
      end

      def barrows_fragment(names, tips_into, barrow_kg:, crew:)
        level_kg_per_s = barrow_kg / Barrowing.trip_s(0.0, CARRY_M.fetch(names.prefix))
        Fragment.new(
          nodes: [ Barrowing.new(id: names.(:carrying), label: "Barrows", accepts: [ :solid ], bench: names.(:bench),
                                 carry_m: CARRY_M.fetch(names.prefix), max_kg_per_s: level_kg_per_s,
                                 heat_capacity: 2.0e3, control_id: names.(:barrowmen), worked: true, crew: crew,
                                 perils: [ fall_on_the_barrow_way(names) ]) ],
          links: [ Link.new(from: [ names.(:muck), :out ], to: [ names.(:carrying), :inlet ]),
                   Link.new(from: [ names.(:carrying), :outlet ], to: [ tips_into, :in ]) ],
          places: [ Place.new(id: names.place, nodes: [ names.(:carrying) ]) ],
          control_points: [
            ControlPoint.new(id: names.(:barrowmen), label: "#{face_label(names)} Barrows", node: names.(:carrying),
                             default: 100.0, place: names.place, capacity: crew,
                             effort: { force: 0.8, toughness: 0.2 }, gated_by: %i[darkvision], exertion: 9.0e-4)
          ]
        )
      end

      def face_label(names) = names.prefix.to_s.capitalize

      # **A fall of ground from the face onto whoever is getting it**, likelier the harder it is
      # worked and the harder the ground. Somebody can be put under it.
      def fall_from_the_face(names)
        Peril.new(id: :"fall_from_the_#{names.prefix}_face", wounds: { impact: 0.6, crush: 0.4 }, severity: 2.0,
                  rate: 0.15, scales_with: :getting, stations: [ names.(:getters) ], opportunity: true)
      end

      # **Off the plank with a loaded barrow**, by the barrows going past, and far worse wet or icy.
      def fall_on_the_barrow_way(names)
        Peril.new(id: :"fell_off_the_#{names.prefix}_ramp", wounds: { impact: 1.0 }, causes: %i[fall], severity: 1.4,
                  rate: 0.1, scales_with: :barrows, stations: [ names.(:barrowmen) ],
                  underfoot: { wet: 1.0, icy: 8.0 }, opportunity: true)
      end

      # --- washing ----------------------------------------------------------------------------

      # The speed the line shaft is worked at, which every driven fitting is rated against.
      WORKING_OMEGA = 22.0

      # Several tonnes of water a tonne of wash ore (modern log washers; the period figure is not in
      # the sources read).
      WATER_PER_KG = 3.0

      # **The log washers**, a bay each. The single-shaft washer was nearly everywhere replaced by
      # the two-shaft Thomas washer by 1875 (Prime); it washes less and loses more of the ore to the
      # dam. About 15 t and 25 t of washed ore a day, brought into an hour's play. The double Thomas
      # washer is the last of the log washers, twice the Thomas; the series washer — a trommel, a
      # log washer and an attrition cell in line — washes as much, at half as much power again, and
      # keeps nearly all the ore. Work and water are per kilogram, so a washer washing twice as much
      # draws twice as much of both.
      WASHERS = {
        single_log_washer: { label: "Single Log Washer", rated_kg_per_s: 1.7, efficiency: 0.8, work_j_per_kg: 6_000.0,
                             hands: 2,
                             description: "One toothed log in a trough. It loses a fifth of the ore to the dam." },
        thomas_washer: { label: "Thomas Washer", rated_kg_per_s: 2.8, efficiency: 0.9, work_j_per_kg: 5_000.0, hands: 2,
                         description: "Two logs, geared together. Washes more, and loses less." },
        double_thomas_washer: { label: "Double Thomas Washer", rated_kg_per_s: 5.6, efficiency: 0.9,
                                work_j_per_kg: 5_000.0, hands: 3,
                                description: "Longer logs and a deeper trough: twice the Thomas, and twice its " \
                                             "power and water. Wasted on lumps the hands must break." },
        series_washer: { label: "Series Washer", rated_kg_per_s: 5.6, efficiency: 0.97, work_j_per_kg: 7_500.0,
                         hands: 3,
                         description: "A trommel, a log washer and an attrition cell in line. Keeps nearly all " \
                                      "the ore, for half as much power again." }
      }.freeze

      WASHERS.each do |id, washer|
        Parts.register(id, kind: :log_washer, label: washer.fetch(:label), description: washer.fetch(:description),
                           provides: %i[washer feed],
                           stats: washer.slice(:rated_kg_per_s, :efficiency, :hands)) do |spec|
          OpenPit.washer_fragment(washer, spec.fetch(:names), feeds_from: spec.fetch(:feeds_from),
                                                              crushed: spec.fetch(:crushed))
        end
      end

      # **A washer's hands** rake the wash ore in and clear the clay balls. From the bin, uncrushed,
      # they break the lumps with a sledge first, and a kilogram a second each is all they rake;
      # crushed ore comes down a chute from the hopper, three times as fast.
      RAKE_KG_PER_S = { uncrushed: 1.0, crushed: 3.0 }.freeze

      def washer_fragment(washer, names, feeds_from:, crushed:)
        hands = washer.fetch(:hands)
        Fragment.new(
          nodes: [
            LogWasher.new(id: names.(:washer), label: "#{washer.fetch(:label)} (#{bay_label(names)})",
                          driven_by: :line_shaft, rated_omega: WORKING_OMEGA, water_per_kg: WATER_PER_KG,
                          fed_by: names.(:feed), bin: feeds_from, crushed: crushed, volume_m3: 2.5,
                          perils: [ caught_in_the_logs(names) ], endangers: { logs_broken: logs_breaking(names) },
                          **washer.slice(:rated_kg_per_s, :efficiency, :work_j_per_kg)),
            Nodes::Conduit.new(id: names.(:feed), label: "Raking In", accepts: [ :solid ],
                               max_kg_per_s: RAKE_KG_PER_S.fetch(crushed ? :crushed : :uncrushed), heat_capacity: 2.0e3,
                               control_id: names.(:hands), worked: true, crew: hands)
          ],
          links: [ Link.new(from: [ feeds_from, :out ], to: [ names.(:feed), :inlet ]),
                   Link.new(from: [ names.(:feed), :outlet ], to: [ names.(:washer), :ore_in ]),
                   Link.new(from: [ :head_tank, :out ], to: [ names.(:washer), :water_in ]),
                   Link.new(from: [ names.(:washer), :washed ], to: [ :washed_ore, :in ]),
                   Link.new(from: [ names.(:washer), :slurry ], to: [ :mud_dam, :in ]) ],
          places: [ Place.new(id: :bank, nodes: [ names.(:washer), names.(:feed) ]) ],
          control_points: [
            ControlPoint.new(id: names.(:hands), label: "#{bay_label(names)} Hands", node: names.(:feed), default: 100.0,
                             place: :bank, capacity: hands, effort: { force: 0.6, dexterity: 0.4 },
                             gated_by: %i[darkvision], exertion: 7.0e-4)
          ],
          diagnostics: [ washer_board(names) ]
        )
      end

      def bay_label(names) = names.prefix.to_s.tr("_", " ").capitalize

      # **Caught in the logs**, reaching in to clear a ball while they turn.
      def caught_in_the_logs(names)
        Peril.new(id: :caught_in_the_logs, wounds: { crush: 0.7, cut: 0.3 }, severity: 2.4, rate: 0.12,
                  scales_with: :turning, stations: [ names.(:hands) ], opportunity: true)
      end

      # **A log letting go**: teeth and splinters across the trough, at whoever is raking.
      def logs_breaking(names) = { wounds: { impact: 0.6, cut: 0.4 }, stations: { names.(:hands) => 2.0 } }

      # --- the washhouse ------------------------------------------------------------------------

      # **The washhouse**: how many bays it has room for, each a washer of its own. The bays past
      # the third are built only when the washhouse has room for them (`needs_at_least:`).
      WASHHOUSES = {
        washhouse: { label: "Washhouse", bays: 3,
                     description: "A shed on trestles over the dam, with room for three washers." },
        extended_washhouse: { label: "Extended Washhouse", bays: 4, description: "Room for a fourth washer." },
        long_washhouse: { label: "Long Washhouse", bays: 5, description: "Room for five washers." },
        double_washhouse: { label: "Double Washhouse", bays: 6,
                            description: "Two rows of three, over one dam. Room for six washers." }
      }.freeze

      WASHHOUSES.each do |id, house|
        Parts.register(id, kind: :washhouse, label: house.fetch(:label), description: house.fetch(:description),
                           stats: house.slice(:bays)) { |_spec| Fragment.empty }
      end

      BAYS = 6

      def bay(number) = Names.new(:"bay_#{number}", place: :bank)

      # **The water pump**, lifting the reservoir to the head tank every washer draws on: one pump for
      # the floor, so the washers compete for its water.
      PUMPS = {
        single_pump: { label: "Single Pump", max_kg_per_s: 8.0, description: "Enough for one log washer." },
        duplex_pump: { label: "Duplex Pump", max_kg_per_s: 30.0, description: "Enough for a floor of Thomas washers." },
        compound_pump: { label: "Compound Pump", max_kg_per_s: 100.0,
                         description: "Enough for six washers of the top tier." }
      }.freeze

      PUMPS.each do |id, pump|
        Parts.register(id, kind: :pit_pump, label: pump.fetch(:label), description: pump.fetch(:description),
                           provides: %i[water_pump], stats: pump.slice(:max_kg_per_s)) do |_spec|
          OpenPit.pump_fragment(pump.fetch(:max_kg_per_s))
        end
      end

      def pump_fragment(max_kg_per_s)
        Fragment.new(
          # Lifting the reservoir to the head tank, off the line shaft: nothing with the shaft
          # stopped, and the lift charged to it.
          nodes: [ Nodes::Conduit.new(id: :water_pump, label: "Water Pump", accepts: [ :liquid ], max_kg_per_s: max_kg_per_s,
                                      heat_capacity: 1.0e4, control_id: :pumping, driven_by: :line_shaft, lift_m: 12.0,
                                      efficiency: 0.5, rated_omega: WORKING_OMEGA, delivers_to: :work,
                                      displacement: true) ],
          links: [ Link.new(from: [ :reservoir, :out ], to: [ :water_pump, :inlet ]),
                   Link.new(from: [ :water_pump, :outlet ], to: [ :head_tank, :in ]) ],
          places: [ Place.new(id: :bank, nodes: %i[water_pump]) ],
          control_points: [ ControlPoint.new(id: :pumping, label: "Water Pump", node: :water_pump, default: 100.0,
                                             place: :bank) ]
        )
      end

      # --- the dams -----------------------------------------------------------------------------

      # **The mud dam**, where the slurry settles: a starting floor never troubles it, a full floor
      # of the top washers fills it within a match without a decant. A taller wall holds more and
      # weeps sooner; settling ponds are two walls, stronger for it.
      MUD_DAMS = {
        mud_dam: { label: "Mud Dam", capacity_m3: 3_000.0, wear_per_s: 0.4,
                   description: "A clay wall on trestles below the washhouse, and a pond behind it." },
        raised_dam: { label: "Raised Dam", capacity_m3: 6_000.0, wear_per_s: 0.5,
                      description: "The wall built up on its own settled clay. Twice the pond, and weeps sooner." },
        settling_ponds: { label: "Settling Ponds", capacity_m3: 12_000.0, wear_per_s: 0.25,
                          description: "Two ponds, one draining into the next. Four times the room, and a wall " \
                                       "that stands." }
      }.freeze

      # The share of its pond a dam's wall stands without weeping; a reservoir's bank stands more.
      DAM_SAFE_FILL = 0.6
      RESERVOIR_SAFE_FILL = 0.8

      DAM_HANDS = 3

      # **A wall letting go sweeps whoever is on it off it**, and the pond runs down into the pit.
      DAM_BREACH = { wounds: { impact: 1.0 }, causes: %i[fall], places: { dams: 2.0 } }.freeze

      MUD_DAMS.each do |id, dam|
        Parts.register(id, kind: :mud_dam, label: dam.fetch(:label), description: dam.fetch(:description),
                           provides: %i[mud_dam mud_dam_breach decant], stats: dam.slice(:capacity_m3)) do |spec|
          OpenPit.mud_dam_fragment(dam, ground: spec[:ground])
        end
      end

      def mud_dam_fragment(dam, ground:)
        Fragment.new(
          nodes: [
            MudDam.new(id: :mud_dam, label: dam.fetch(:label), capacity_m3: dam.fetch(:capacity_m3),
                       safe_fill: DAM_SAFE_FILL, wear_per_s: dam.fetch(:wear_per_s), puddled_by: :dam_hands,
                       ground: ground, heat_capacity: 1.0e4, ambient_conductance: 0.0,
                       endangers: { breached: DAM_BREACH },
                       ports: [ Port.new(id: :in, direction: :inlet, accepts: %i[solid liquid], max_kg_per_s: 2_000.0),
                                Port.new(id: :decant, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: 300.0),
                                Port.new(id: :breach, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: 300.0) ]),
            Decant.new(id: :decant, label: "Decant", accepts: [ :liquid ], max_kg_per_s: 120.0, heat_capacity: 1.0e3,
                       control_id: :decanting, from: :mud_dam),
            breach(:mud_dam)
          ],
          links: [ Link.new(from: [ :mud_dam, :decant ], to: [ :decant, :inlet ]),
                   Link.new(from: [ :decant, :outlet ], to: [ :reservoir, :in ]),
                   Link.new(from: [ :mud_dam, :breach ], to: [ :mud_dam_breach, :inlet ]),
                   Link.new(from: [ :mud_dam_breach, :outlet ], to: [ :sump, :in ]) ],
          places: [ Place.new(id: :dams, nodes: %i[mud_dam decant mud_dam_breach]) ],
          control_points: [
            # **The decant gate**: the free water off the top of the pond, back to the reservoir.
            ControlPoint.new(id: :decanting, label: "Decant Gate", node: :decant, default: 50.0, place: :dams)
          ]
        )
      end

      # **The hole a wall leaves**, into the pit below: the pond's water, never its settled clay.
      def breach(embankment)
        Nodes::Breach.new(id: :"#{embankment}_breach", label: "Breach", senses: embankment, opens_by: { breached: 1.0 },
                          accepts: [ :liquid ], max_kg_per_s: 300.0, heat_capacity: 1.0e3)
      end

      # **The reservoir**, its bank an embankment held at its crest by the spillway. The starting one's
      # bank is so strong no match sees it wear; a larger one's wears held full, and comes with the
      # bankmen to puddle it and a scour valve to draw it down.
      RESERVOIRS = {
        reservoir: { label: "Reservoir", capacity_kg: 6.0e5, wear_per_s: 0.002, area_m2: 300.0, bank: false,
                     description: "A pond behind a low bank. A day's washing for one washer." },
        large_reservoir: { label: "Large Reservoir", capacity_kg: 2.0e6, wear_per_s: 0.2, area_m2: 800.0, bank: true,
                           description: "A higher bank, three times the water. Held full, it weeps." },
        great_reservoir: { label: "Great Reservoir", capacity_kg: 6.0e6, wear_per_s: 0.35, area_m2: 2_000.0, bank: true,
                           description: "Ten times the water behind a great bank. If it goes, the pit goes under." }
      }.freeze

      RESERVOIR_BANKMEN = 3

      RESERVOIRS.each do |id, pond|
        Parts.register(id, kind: :reservoir, label: pond.fetch(:label), description: pond.fetch(:description),
                           provides: %i[reservoir reservoir_breach spillway reservoir_catchment],
                           instruments: pond.fetch(:bank) ? %i[reservoir_bank] : [],
                           stats: pond.slice(:capacity_kg)) do |spec|
          OpenPit.reservoir_fragment(pond, ground: spec[:ground])
        end
      end

      def reservoir_fragment(pond, ground:)
        bank = pond.fetch(:bank)
        capacity = pond.fetch(:capacity_kg)
        Fragment.new(
          nodes: [
            # A tenth over its crest, so what is over it can stand until the spillway takes it.
            Reservoir.new(id: :reservoir, label: pond.fetch(:label), capacity_kg: capacity, freeboard: 0.1,
                          safe_fill: RESERVOIR_SAFE_FILL, wear_per_s: pond.fetch(:wear_per_s),
                          puddled_by: (:bankmen if bank), ground: ground, heat_capacity: 1.0e5,
                          endangers: { breached: DAM_BREACH },
                          ports: [ Port.new(id: :in, direction: :inlet, accepts: [ :liquid ], max_kg_per_s: 300.0),
                                   Port.new(id: :out, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: 200.0),
                                   Port.new(id: :spill, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: 300.0),
                                   Port.new(id: :breach, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: 300.0),
                                   *([ Port.new(id: :scour, direction: :outlet, accepts: [ :liquid ],
                                                max_kg_per_s: 300.0) ] if bank) ]),
            Nodes::Catchment.new(id: :reservoir_catchment, label: "Rain on the Reservoir", area_m2: pond.fetch(:area_m2)),
            Spillway.new(id: :spillway, label: "Spillway", accepts: [ :liquid ], max_kg_per_s: 300.0, heat_capacity: 1.0e3,
                         over: :reservoir, crest_kg: capacity),
            breach(:reservoir),
            *([ scour_valve ] if bank)
          ],
          links: [ Link.new(from: [ :reservoir_catchment, :out ], to: [ :reservoir, :in ]),
                   Link.new(from: [ :reservoir, :spill ], to: [ :spillway, :inlet ]),
                   Link.new(from: [ :spillway, :outlet ], to: [ :drainage, :in ]),
                   Link.new(from: [ :reservoir, :breach ], to: [ :reservoir_breach, :inlet ]),
                   Link.new(from: [ :reservoir_breach, :outlet ], to: [ :sump, :in ]),
                   *([ Link.new(from: [ :reservoir, :scour ], to: [ :scour, :inlet ]),
                       Link.new(from: [ :scour, :outlet ], to: [ :drainage, :in ]) ] if bank) ],
          places: [ Place.new(id: :dams, nodes: [ :reservoir, :spillway, :reservoir_breach, *([ :scour ] if bank) ]) ],
          control_points: bank ? reservoir_bank_posts : []
        )
      end

      # **The scour valve**: water let off to drainage to spare the bank.
      def scour_valve
        Nodes::Conduit.new(id: :scour, label: "Scour Valve", accepts: [ :liquid ], max_kg_per_s: 200.0,
                           heat_capacity: 1.0e3, control_id: :scour_valve)
      end

      def reservoir_bank_posts
        [ ControlPoint.new(id: :scour_valve, label: "Scour Valve", node: :scour, default: 0.0, place: :dams),
          ControlPoint.new(id: :bankmen, label: "Reservoir Bankmen", node: :reservoir, default: 100.0, place: :dams,
                           capacity: RESERVOIR_BANKMEN, effort: { force: 0.6, swing: 0.4 }, gated_by: %i[darkvision],
                           exertion: 8.0e-4) ]
      end

      # --- crushing -----------------------------------------------------------------------------

      # **The rock crusher**, between the bin and a hopper over the washhouse. A log washer cannot
      # take the lumps run-of-pit ore carries, so ahead of the jaws a washer's hands break them by
      # hand (`RAKE_KG_PER_S`) and its logs wear faster (`LogWasher::UNCRUSHED_WEAR`). Blake's jaw
      # crusher is 1858, the gyratory 1881; the rates and the work are general figures.
      CRUSHERS = {
        blake_jaw_crusher: { label: "Blake Jaw Crusher", rated_kg_per_s: 6.0, work_j_per_kg: 4_000.0,
                             description: "A pair of iron jaws, one swinging. Enough for two washers." },
        large_jaw_crusher: { label: "Large Jaw Crusher", rated_kg_per_s: 15.0, work_j_per_kg: 4_000.0,
                             description: "Wider jaws on a heavier frame. Enough for a floor of Thomas washers." },
        gyratory_crusher: { label: "Gyratory Crusher", rated_kg_per_s: 40.0, work_j_per_kg: 3_500.0,
                            description: "A cone gyrating in a bowl, crushing all the way round. More than a " \
                                         "shovel digs." }
      }.freeze

      CRUSHERS.each do |id, crusher|
        Parts.register(id, kind: :pit_crusher, label: crusher.fetch(:label), description: crusher.fetch(:description),
                           provides: %i[crusher crushed_ore], instruments: %i[crusher_board],
                           stats: crusher.slice(:rated_kg_per_s)) do |spec|
          OpenPit.crusher_fragment(crusher, belted: spec.fetch(:belted))
        end
      end

      # **The crusher feeders**, shovelling from the bin into the jaws when no belt does.
      FEEDERS = 6
      FEEDER_KG_PER_S = 1.5

      # About thirty tonnes of crushed ore over the washhouse.
      HOPPER_M3 = 15.0

      def crusher_fragment(crusher, belted:)
        feeders = belted ? [] : [ :crusher_feeders ]
        Fragment.new(
          nodes: [
            Crusher.new(id: :crusher, label: crusher.fetch(:label), accepts: [ :solid ], heat_capacity: 2.0e4,
                        max_kg_per_s: crusher.fetch(:rated_kg_per_s), work_j_per_kg: crusher.fetch(:work_j_per_kg),
                        driven_by: :line_shaft, rated_omega: WORKING_OMEGA, displacement: true, delivers_to: :work,
                        bin: :ore_bin, hopper: :crushed_ore, feeders: feeders.first,
                        perils: feeders.map { |station| caught_in_the_jaws(station) }),
            heap(:crushed_ore, "Crushed Ore", HOPPER_M3),
            *(belted ? [] : [ crusher_feed ])
          ],
          links: [ Link.new(from: [ :crusher, :outlet ], to: [ :crushed_ore, :in ]),
                   *(belted ? [] : [ Link.new(from: [ :ore_bin, :out ], to: [ :crusher_feed, :inlet ]),
                                     Link.new(from: [ :crusher_feed, :outlet ], to: [ :crusher, :inlet ]) ]) ],
          places: [ Place.new(id: :bank, nodes: [ :crusher, :crushed_ore, *(belted ? [] : [ :crusher_feed ]) ]) ],
          control_points: belted ? [] : [
            ControlPoint.new(id: :crusher_feeders, label: "Crusher Feeders", node: :crusher_feed, default: 100.0,
                             place: :bank, capacity: FEEDERS, effort: { force: 0.7, swing: 0.3 }, gated_by: %i[darkvision],
                             exertion: 8.0e-4)
          ]
        )
      end

      def crusher_feed
        Nodes::Conduit.new(id: :crusher_feed, label: "Feeding the Jaws", accepts: [ :solid ], max_kg_per_s: FEEDER_KG_PER_S,
                           heat_capacity: 2.0e3, control_id: :crusher_feeders, worked: true, crew: FEEDERS)
      end

      # **Caught in the jaws**, a shovel or an arm too far in while they work.
      def caught_in_the_jaws(station)
        Peril.new(id: :caught_in_the_jaws, wounds: { crush: 1.0 }, severity: 2.6, rate: 0.1, scales_with: :jaws,
                  stations: [ station ], opportunity: true)
      end

      # **A belt from the bin up to the jaws**, off the line shaft: the feeders' places, and their
      # limit. It needs the crusher, because a belt into a log washer would be the same lumps. Its feed
      # is a lever and nobody is on it; fed past what its drum grips, it stalls, and the drum turns on
      # under it and heats. Rain on it is 5e's.
      FEED_BELT = { grip_kg_per_s: 40.0, feed_kg_per_s: 50.0, lift_m: 8.0 }.freeze

      Parts.register(:pit_feed_belt, kind: :pit_belt, label: "Feed Belt",
                     description: "A rubber belt from the bin up to the jaws. No feeders, and it stalls if overfed.",
                     provides: %i[feed_belt feed_belt_drive], instruments: %i[belt_board],
                     stats: FEED_BELT.slice(:grip_kg_per_s)) do |_spec|
        OpenPit.feed_belt_fragment
      end

      # The belt's speed at the shaft's working speed, and its drive drum: the colliery's.
      BELT_M_PER_S = 2.0
      DRUM_HEAT_CAPACITY_J_PER_K = 2.7e4

      def feed_belt_fragment
        Fragment.new(
          nodes: [
            Nodes::Belt.new(id: :feed_belt, label: "Feed Belt", accepts: [ :solid ], max_kg_per_s: FEED_BELT.fetch(:feed_kg_per_s),
                            grip_kg_per_s: FEED_BELT.fetch(:grip_kg_per_s), fed_from: :ore_bin, heat_capacity: 4.0e3,
                            driven_by: :line_shaft, displacement: true, rated_omega: WORKING_OMEGA,
                            lift_m: FEED_BELT.fetch(:lift_m), efficiency: 0.7, control_id: :belt_feed),
            Nodes::Bearing.new(id: :feed_belt_drive, label: "Feed Belt Drive", supports: :line_shaft, duty: :journal,
                               material: :steel, heat_capacity: DRUM_HEAT_CAPACITY_J_PER_K, ambient_conductance: 46.0,
                               loaded_by: :feed_belt, static_load_n: 0.0, journal_radius_m: BELT_M_PER_S / WORKING_OMEGA,
                               mu_film: Nodes::Belting::BELT_MU, mu_boundary: Nodes::Belting::BELT_MU,
                               oil_charge_kg: 0.0, viscous_c: 0.0)
          ],
          links: [ Link.new(from: [ :ore_bin, :out ], to: [ :feed_belt, :inlet ]),
                   Link.new(from: [ :feed_belt, :outlet ], to: [ :crusher, :inlet ]) ],
          places: [ Place.new(id: :bank, nodes: %i[feed_belt feed_belt_drive]) ],
          control_points: [
            # A lever, not a post. Past what the drum grips, it stalls.
            ControlPoint.new(id: :belt_feed, label: "Belt Feed", node: :feed_belt, default: 50.0, place: :bank)
          ]
        )
      end

      # --- the crew ---------------------------------------------------------------------------

      # **The site hut at bank** is where the shift starts and where the far walk to rest leads.
      Parts.register(:site_hut, kind: :crew_quarters, label: "Site Hut",
                     description: "A timber hut on the bank: tallies, tools, a stove. One shift.",
                     stats: { crew_capacity: 14, recovery_rate: 2.0 }) do |_spec|
        OpenPit.quarters_fragment("Site Hut", 2.0)
      end

      Parts.register(:changing_house, kind: :crew_quarters, label: "Changing House",
                     description: "Lockers, a drying room and a hot meal. Somewhere worth coming up to.",
                     stats: { crew_capacity: 20, recovery_rate: 3.0 }) do |_spec|
        OpenPit.quarters_fragment("Changing House", 3.0)
      end

      # **Barracks** for a pit worked by a crowd: bunks two to a bed across the shifts, as the Bilbao
      # barracks were. Room for a full washing floor, and nobody rests as well as in a changing house.
      Parts.register(:barracks, kind: :crew_quarters, label: "Barracks",
                     description: "Bunks for forty, two to a bed across the shifts. Crowded, and nobody rests well.",
                     stats: { crew_capacity: 40, recovery_rate: 1.8 }) do |_spec|
        OpenPit.quarters_fragment("Barracks", 1.8)
      end

      def quarters_fragment(label, recovery_rate)
        Fragment.new(control_points: [ ControlPoint.new(id: :quarters, label: label, place: :bank,
                                                        recovery: Fatigue::BASE_RECOVERY * recovery_rate) ])
      end

      # **Outbuildings: somewhere to rest without climbing out, and somewhere part of the shift
      # starts.** A hut fitted at a bench or the dump seats `advance_seats` there when the match
      # begins, posted to nothing, and rests `rest_capacity` at a time. Which bench is its slot's.
      OUTBUILDINGS = {
        bench_hut: { kind: :pit_hut, label: "Bench Hut", seats: 3, rest: 2, recovery: 1.6,
                     description: "A lean-to on the bench. Three start there; two can sit down." },
        bench_cabin: { kind: :pit_hut, label: "Bench Cabin", seats: 5, rest: 4, recovery: 2.4,
                       description: "A proper cabin with a brazier. Five start there; four can rest." },
        dump_shelter: { kind: :dump_hut, label: "Dump Shelter", seats: 2, rest: 1, recovery: 1.4,
                        description: "Boards against the wind at the tip. Two start there; one can rest." },
        dump_cabin: { kind: :dump_hut, label: "Dump Cabin", seats: 3, rest: 2, recovery: 2.0,
                      description: "A cabin at the tip. Three start there; two can rest." }
      }.freeze

      OUTBUILDINGS.each do |id, hut|
        Parts.register(id, kind: hut.fetch(:kind), label: hut.fetch(:label), description: hut.fetch(:description),
                           stats: { advance_seats: hut.fetch(:seats), rest_capacity: hut.fetch(:rest),
                                    recovery_rate: hut.fetch(:recovery) }) do |spec|
          names = spec.fetch(:names)
          Fragment.new(control_points: [
            ControlPoint.new(id: names.(:hut), label: hut.fetch(:label), place: names.place, capacity: hut.fetch(:rest),
                             recovery: Fatigue::BASE_RECOVERY * hut.fetch(:recovery))
          ])
        end
      end

      # **The pit boss**, walking the benches and the dump and keeping the peace on all three, as the
      # colliery's overman does underground.
      Parts.register(:pit_boss, kind: :pit_supervision, label: "Pit Boss",
                     description: "Walks the benches and the dump, and keeps the peace on all three.",
                     stats: { oversees: 3 }) do |_spec|
        Fragment.new(control_points: [
          ControlPoint.new(id: :overseeing, label: "Pit Boss", place: :stripping_bench, capacity: 1, default: 100.0,
                           effort: { charisma: 0.5, intelligence: 0.5 }, exertion: 2.0e-4,
                           oversees: %i[stripping_bench ore_bench spoil_dump])
        ])
      end

      # --- slots and fixtures --------------------------------------------------------------------

      DUMP = Names.new(:dump, place: :spoil_dump)

      # Declaration order is the panel's lever order: the stripping face and its machines, the ore
      # face and its machines, the washing floor in the order the ore goes through it, the crew.
      # `machines` and `feed` are what `OpenPit.fitted_machines` and `OpenPit.feed_for` read off the
      # loadout, which the faces and the bays are wired for.
      def slots(spec, machines = {}, feed = UNCRUSHED)
        fitted = spec.fetch(:parts)
        stripping = { names: face(:stripping), tips_into: :tip_head }
        ore = { names: face(:ore), tips_into: :ore_bin }
        [
          Slot.new(id: :stripping_getting, accepts: :pit_getting, label: "Stripping", group: :stripping,
                   required: true, default: fitted.fetch(:stripping_getting), spec: stripping),
          Slot.new(id: :stripping_carrying, accepts: :pit_carrying, label: "Carrying the Stripping", group: :stripping,
                   required: true, default: fitted.fetch(:stripping_carrying), spec: stripping),
          *machine_slots(:stripping, machines),
          Slot.new(id: :ore_getting, accepts: :pit_getting, label: "Getting Ore", group: :ore,
                   required: true, default: fitted.fetch(:ore_getting), spec: ore),
          Slot.new(id: :ore_carrying, accepts: :pit_carrying, label: "Carrying the Ore", group: :ore,
                   required: true, default: fitted.fetch(:ore_carrying), spec: ore),
          *machine_slots(:ore, machines),
          # Empty to start: the bailers are the pit's drainage until a pump is bought.
          Slot.new(id: :sump_pump, accepts: :sump_pump, label: "Sump Pump", group: :drainage, default: fitted[:sump_pump]),
          # Empty to start: the pit is worked by pick until powder is bought, and so is its ticket.
          Slot.new(id: :blasting, accepts: :pit_blasting, label: "Blasting", group: :blasting,
                   default: fitted[:blasting], informs: %i[explosive], spec: { machines: machines }),
          Slot.new(id: :magazine, accepts: :pit_magazine, label: "Magazine", group: :blasting, needs: :blasting,
                   default: fitted.fetch(:magazine)),
          *washing_slots(fitted, feed),
          Slot.new(id: :quarters, accepts: :crew_quarters, label: "Quarters", group: :crew,
                   required: true, default: fitted.fetch(:quarters)),
          # Who starts out in the pit, the stripping bench first.
          Slot.new(id: :stripping_hut, accepts: :pit_hut, label: "Stripping Bench Hut", group: :crew,
                   default: fitted[:stripping_hut], spec: { names: face(:stripping) }),
          Slot.new(id: :ore_hut, accepts: :pit_hut, label: "Ore Bench Hut", group: :crew,
                   default: fitted[:ore_hut], spec: { names: face(:ore) }),
          Slot.new(id: :dump_shelter, accepts: :dump_hut, label: "Dump Shelter", group: :crew,
                   default: fitted[:dump_shelter], spec: { names: DUMP }),
          # Empty to start: a pit with nobody keeping the peace, until the first brawl.
          Slot.new(id: :supervision, accepts: :pit_supervision, label: "Supervision", group: :crew,
                   default: fitted[:supervision]),
          WeatherGauges.slot
        ]
      end

      # **What feeds the bays**: the bin while no crusher is fitted, the crusher's hopper while one
      # is, and whether a belt feeds the crusher.
      UNCRUSHED = { from: :ore_bin, crushed: false, belted: false }.freeze

      # The crusher and its belt, the washhouse and its bays, the pump. Bay 1 is required; bays 2
      # and 3 always have room; the rest only in a washhouse that has room for them.
      def washing_slots(fitted, feed)
        bays = (1..BAYS).map do |number|
          names = bay(number)
          gate = number > WASHHOUSES.dig(:washhouse, :bays) ? { needs: :washhouse, needs_at_least: { bays: number } } : {}
          Slot.new(id: names.prefix, accepts: :log_washer, label: bay_label(names), group: :washing,
                   required: number == 1, default: fitted[names.prefix],
                   spec: { names: names, feeds_from: feed.fetch(:from), crushed: feed.fetch(:crushed) }, **gate)
        end
        [ Slot.new(id: :crusher, accepts: :pit_crusher, label: "Crusher", group: :washing, default: fitted[:crusher],
                   spec: { belted: feed.fetch(:belted) }),
          Slot.new(id: :feed_belt, accepts: :pit_belt, label: "Feed Belt", group: :washing, needs: :crusher,
                   default: fitted[:feed_belt]),
          Slot.new(id: :washhouse, accepts: :washhouse, label: "Washhouse", group: :washing, required: true,
                   default: fitted.fetch(:washhouse)),
          *bays,
          Slot.new(id: :pump, accepts: :pit_pump, label: "Water Pump", group: :washing, required: true,
                   default: fitted.fetch(:pump)),
          Slot.new(id: :mud_dam, accepts: :mud_dam, label: "Mud Dam", group: :washing, required: true,
                   default: fitted.fetch(:mud_dam)),
          Slot.new(id: :reservoir, accepts: :reservoir, label: "Reservoir", group: :washing, required: true,
                   default: fitted.fetch(:reservoir)) ]
      end

      # Each fitted bay's reach: fed, emptied, watered.
      def washing_routes
        (1..BAYS).flat_map do |number|
          names = bay(number)
          label = bay_label(names).downcase
          [ { from: :ore_bin, to: names.(:washer), carrying: :solid, needs: names.prefix, as: "nothing feeds #{label}" },
            { from: names.(:washer), to: :washed_ore, carrying: :ore, needs: names.prefix,
              as: "nothing takes #{label}'s washed ore away" },
            { from: :reservoir, to: names.(:washer), carrying: :liquid, needs: names.prefix,
              as: "no water reaches #{label}" } ]
        end
      end

      # --- the machines ---------------------------------------------------------------------------
      #
      # **A steam shovel and a dinky at each face, both upgrades** (`upgrade:`): a principal slot
      # each, empty to start, and every other slot of the machine built only while it is fitted.

      NO_MACHINES = { shovel: false, train: false }.freeze

      def machine_slots(face_id, machines)
        fitted = machines.fetch(face_id, NO_MACHINES)
        label = face_label(face(face_id))
        MobileEngine.shovel_slots(shovel(face_id).prefix, place: face(face_id).place, upgrade: "#{label} Shovel",
                                  **shovel_host(face_id, fitted)) +
          MobileEngine.locomotive_slots(train(face_id).prefix, place: footplate(face_id), upgrade: "#{label} Dinky",
                                        **train_host(face_id, fitted))
      end

      def machine_routes(machines)
        FACES.flat_map do |face_id|
          fitted = machines.fetch(face_id, NO_MACHINES)
          MobileEngine.shovel_routes(shovel(face_id).prefix, place: face(face_id).place, upgrade: true,
                                     **shovel_host(face_id, fitted)) +
            MobileEngine.locomotive_routes(train(face_id).prefix, place: footplate(face_id), upgrade: true,
                                           **train_host(face_id, fitted))
        end
      end

      # **What a shovel digs into**: with a dinky at the face, the train's cars while one stands
      # there and the muck while none does; without one, the muck. Its hose draws on the reservoir.
      def shovel_host(face_id, fitted)
        names = face(face_id)
        host = { bench: names.(:bench), standpipe: :reservoir }
        return host.merge(car: names.(:muck)) unless fitted.fetch(:train)

        cars = train(face_id)
        host.merge(car: cars.(:cars), dumps_into: [ cars.(:loading), :inlet ], cast_to: [ names.(:muck), :in ],
                   cars: { carrier: cars.(:train), mark_m: TRACKS.fetch(face_id).mark(:loading) })
      end

      # **Where a dinky runs, and who is at peril of it**: its face's track, tipping where the face's
      # barrows tip; loaded by hand from the muck, and by the shovel if there is one.
      def train_host(face_id, fitted)
        names = face(face_id)
        { track: TRACKS.fetch(face_id), dump: TRAIN_DUMPS.fetch(face_id),
          serves: fitted.fetch(:shovel) ? shovel(face_id).prefix : nil, loaded_from: names.(:muck),
          beside: [ names.(:getters), names.(:barrowmen) ] }
      end

      # **Each face's track out of the pit**, built from the median depths at 2%: the stripping a
      # bench down to the spoil dump, the ore two benches down to the bin at bank.
      def self.track(depth_m, loading_place, dump_place)
        road_m = depth_m / HAUL_GRADE
        MobileEngine::Track.new(
          sections: [ { to_m: TRACK_END_M * 2, place: loading_place },
                      { to_m: (TRACK_END_M * 2) + road_m, place: :haul_road, grade: HAUL_GRADE },
                      { to_m: (TRACK_END_M * 4) + road_m, place: dump_place } ],
          marks: { loading: TRACK_END_M, dump: (TRACK_END_M * 3) + road_m }
        )
      end

      HAUL_GRADE = 0.02
      # A mark this far from either end, so a buffer is behind it.
      TRACK_END_M = 20.0

      TRACKS = {
        stripping: track(4.0, :stripping_bench, :spoil_dump),
        ore: track(7.0, :ore_bench, :bank)
      }.freeze

      TRAIN_DUMPS = { stripping: :spoil_dump, ore: :ore_bin }.freeze

      # **What no slot owns**: the ground itself, the muck piles, the dump and its spreading, the
      # bin. `spec[:ground]` pins the ground instead of drawing it; `machines` is what the faces are
      # wired for, since a slide wrecks a shovel's boom and its pile drains into the shovel's reach.
      def fixtures(spec, machines = {})
        ground = spec[:ground]
        Fragment.new(
          diagnostics: catalogue.values_at(:stripping_face, :ore_face, :uncovered_ore, :the_sump, :the_tip, :the_edge,
                                           :ore_at_bank, :spoil_tipped, :washed_tons, :water_supply, :the_dam,
                                           :dam_wall, :shaft_speed) +
                       WeatherGauges.guesses(observer: :dumpmen).values,
          passages: passages, places: PLACES,
          nodes: [
            Nodes::Outdoors.new(setup: spec[:conditions]), Nodes::Atmosphere.new,
            bench(:stripping, machines, mix: { overburden: 1.0 }, bulk_kg_m3: OVERBURDEN_KG_M3, median_thickness_m: 4.0,
                                        start_m: STRIPPING_LEAD_M, hard_ground: true, ground: ground),
            bench(:ore, machines, mix: WASH_ORE, bulk_kg_m3: WASH_ORE_KG_M3, median_thickness_m: 3.0,
                                  beneath: :stripping_bench, berm_m: BERM_M, ground: ground, wetted_by: :sump),
            *pit_water(ground),
            muck(:stripping), muck(:ore),
            TipHead.new(id: :tip_head, label: "Tip Head", volume_m3: TIP_HEAD_M3, heat_capacity: 1.0e4,
                        ambient_conductance: 0.0, wetness_from: :seepage, ground: ground,
                        endangers: { broke_back: BREAKBACK },
                        ports: [ Port.new(id: :in, direction: :inlet, accepts: [ :solid ], max_kg_per_s: 2_000.0),
                                 Port.new(id: :out, direction: :outlet, accepts: [ :solid ], max_kg_per_s: 2_000.0),
                                 Port.new(id: :slump, direction: :outlet, accepts: [ :solid ], max_kg_per_s: 1.0e5) ]),
            Slip.new(id: :slumping, label: "Breaking Back", accepts: [ :solid ], max_kg_per_s: 1.0e5, heat_capacity: 1.0e3,
                     from: :tip_head),
            heap(:spoil_dump, "Spoil Dump", 5_000.0),
            heap(:ore_bin, "Ore Bin", 400.0),
            Nodes::Conduit.new(id: :spreading, label: "Spreading", accepts: [ :solid ], max_kg_per_s: 1.5,
                               heat_capacity: 2.0e3, control_id: :dumpmen, worked: true, crew: 2),
            # The one shaft the pit draws its power from; where that comes from is the match's.
            Nodes::Import.new(id: :line_shaft, label: "Line Shaft", rated_torque_nm: LINE_SHAFT_NM,
                              rated_omega: WORKING_OMEGA, moment_of_inertia: 400.0, friction: 2.0, control_id: :clutch),
            Nodes::Delivery.new(id: :drainage, label: "Drainage", accepts: [ :liquid ]),
            # The tank over the washhouse the pump fills and every washer's gutter draws on.
            heap(:head_tank, "Head Tank", HEAD_TANK_M3, accepts: %i[liquid]),
            heap(:washed_ore, "Washed Ore", 400.0, accepts: %i[ore])
          ],
          links: [ Link.new(from: [ :tip_head, :out ], to: [ :spreading, :inlet ]),
                   Link.new(from: [ :spreading, :outlet ], to: [ :spoil_dump, :in ]),
                   Link.new(from: [ :tip_head, :slump ], to: [ :slumping, :inlet ]),
                   Link.new(from: [ :slumping, :outlet ], to: [ :spoil_dump, :in ]),
                   Link.new(from: [ :strata, :out ], to: [ :seepage, :inlet ]),
                   Link.new(from: [ :seepage, :outlet ], to: [ :sump, :in ]),
                   Link.new(from: [ :pit_catchment, :out ], to: [ :sump, :in ]),
                   Link.new(from: [ :sump, :out ], to: [ :bailing, :inlet ]),
                   Link.new(from: [ :bailing, :outlet ], to: [ :reservoir, :in ]) ],
          control_points: [
            ControlPoint.new(id: :clutch, label: "Clutch", node: :line_shaft, default: 100.0, place: :bank),
            # **The dam hands**, puddling the mud dam's wall with clay, and rebuilding it breached.
            ControlPoint.new(id: :dam_hands, label: "Dam Hands", node: :mud_dam, default: 100.0, place: :dams,
                             capacity: DAM_HANDS, effort: { force: 0.6, swing: 0.4 }, gated_by: %i[darkvision],
                             exertion: 8.0e-4),
            # **The bailers** at the sump, buckets and a windlass, lifting the pit's water up to the
            # reservoir. A full gang holds an ordinary pit on a dry day.
            ControlPoint.new(id: :bailers, label: "Bailers", node: :bailing, default: 100.0, place: :ore_bench,
                             capacity: BAILERS, effort: { force: 0.7, swing: 0.3 }, gated_by: %i[darkvision],
                             exertion: 9.0e-4),
            # **Spreading the tip**: barrowed spoil run back from the edge so the next barrows can
            # tip. With nobody at it the tip head fills and the stripping stops behind it.
            ControlPoint.new(id: :dumpmen, label: "Dumpmen", node: :spreading, default: 100.0,
                             place: :spoil_dump, capacity: 2, effort: { force: 0.6, swing: 0.4 }, gated_by: %i[darkvision],
                             exertion: 6.0e-4)
          ]
        ).merge(FACES.map { |face_id| slopes(face_id, machines) }.reduce(:merge))
      end

      def bench(face_id, machines, mix:, bulk_kg_m3:, median_thickness_m:, ground:, start_m: 0.0, beneath: nil,
                berm_m: 0.0, hard_ground: false, wetted_by: nil)
        names = face(face_id)
        shovel = machines.dig(face_id, :shovel)
        Bench.new(id: names.(:bench), label: "#{face_label(names)} Bench", mix: mix, bulk_kg_m3: bulk_kg_m3,
                  width_m: CUT_WIDTH_M, length_m: CUT_LENGTH_M, median_thickness_m: median_thickness_m,
                  getting: names.(:getting), getters: names.(:getters), muck: names.(:muck),
                  muck_full_kg: MUCK_M3 * bulk_kg_m3 * MUCK_FULL, beneath: beneath, berm_m: berm_m, start_m: start_m,
                  hard_ground: hard_ground, ground: ground, wetted_by: wetted_by, slip: names.(:slip),
                  shot_hole: names.(:shot_hole),
                  endangers: { slid: SLIDE.(names) },
                  damages: shovel ? { slid: { shovel(face_id).(:boom) => SLIDE_BOOM_SHARE } } : {})
      end

      # --- slides ---------------------------------------------------------------------------------

      # **A slide buries whoever is at the face**, by the overhang that came down, through a helmet
      # (`rockfall`); a train standing there takes its share through its footplate.
      SLIDE = lambda { |names|
        { wounds: { crush: 0.6, impact: 0.4 }, causes: %i[rockfall], scales_with: :overhang_kg,
          reference: Bench::HANGING_KG, places: { names.place => 1.6 } }
      }

      # And takes this much of a shovel's boom with it.
      SLIDE_BOOM_SHARE = 0.3

      # **A breakback takes the edge and whoever is on it** down the face of the dump.
      BREAKBACK = { wounds: { crush: 0.5, impact: 0.5 }, causes: %i[fall], scales_with: :edge_load_kg,
                    reference: TipHead::EDGE_KG, places: { spoil_dump: 1.6 } }.freeze

      # The slip pile a slide leaves on the face: room for the largest a face holds.
      SLIP_M3 = 6.0

      BARMEN = 2
      BARMAN_KG_PER_S = 1.2

      # **A face's slip pile and its barmen.** The pile drains into the muck, and into a fitted
      # shovel's reach as well, so the dipper digs it out; the barmen bar the hanging face down into
      # the muck.
      def slopes(face_id, machines)
        names = face(face_id)
        reach = machines.dig(face_id, :shovel) && shovel(face_id).(:reach)
        Fragment.new(
          nodes: [
            Slip.new(id: names.(:sliding), label: "Sliding", accepts: [ :solid ], max_kg_per_s: 1.0e5, heat_capacity: 1.0e3,
                     from: names.(:bench)),
            heap(names.(:slip), "#{face_label(names)} Slip", SLIP_M3),
            Barring.new(id: names.(:barring), label: "Barring Down", accepts: [ :solid ], bench: names.(:bench),
                        max_kg_per_s: BARMAN_KG_PER_S, heat_capacity: 2.0e3, control_id: names.(:barmen), worked: true,
                        crew: BARMEN, perils: [ struck_barring(names) ])
          ],
          links: [ Link.new(from: [ names.(:bench), :slide ], to: [ names.(:sliding), :inlet ]),
                   Link.new(from: [ names.(:sliding), :outlet ], to: [ names.(:slip), :in ]),
                   Link.new(from: [ names.(:slip), :out ], to: [ names.(:muck), :in ]),
                   *([ Link.new(from: [ names.(:slip), :out ], to: [ reach, :in ]) ] if reach),
                   Link.new(from: [ names.(:bench), :barred ], to: [ names.(:barring), :inlet ]),
                   Link.new(from: [ names.(:barring), :outlet ], to: [ names.(:muck), :in ]) ],
          places: [ Place.new(id: names.place, nodes: [ names.(:sliding), names.(:slip), names.(:barring) ]) ],
          control_points: [
            ControlPoint.new(id: names.(:barmen), label: "#{face_label(names)} Barmen", node: names.(:barring),
                             default: 100.0, place: names.place, capacity: BARMEN, effort: { force: 0.5, swing: 0.5 },
                             gated_by: %i[darkvision], exertion: 9.0e-4)
          ]
        )
      end

      # --- blasting -------------------------------------------------------------------------------

      # **Powder in the face**, a shot hole at each face worked by its powder gang (`Nodes::ShotHole`):
      # a shot breaks the ground ahead of the face (`Bench#broken_kg`) rather than bringing it down,
      # so the face digs it loose. What separates the tiers is how much a hole breaks and how long it
      # takes, and what it is charged with; dynamite freezes.
      BLASTING = {
        jumper_holes: { label: "Jumper Holes", explosive: :black_powder, charge_kg: 1.0, yield_kg: 2_000.0,
                        shot_s: 300.0, throw: 0.6, gopher: false,
                        description: "Holes driven with a jumper bar and charged with powder. A little at a time." },
        gopher_holes: { label: "Gopher Holes", explosive: :black_powder, charge_kg: 4.0, yield_kg: 8_000.0,
                        shot_s: 750.0, throw: 1.0, gopher: true,
                        description: "A man-sized hole dug into the toe and packed with kegs. It falls in on " \
                                     "the man digging it." },
        dynamite_shots: { label: "Dynamite Shots", explosive: :dynamite, charge_kg: 2.0, yield_kg: 8_000.0,
                          shot_s: 360.0, throw: 1.0, gopher: false,
                          description: "Dynamite in drilled holes: strong and quick, and it freezes in the cold." }
      }.freeze

      # Digging a misfire out with a wooden scraper; a shot that blows out of its hole breaks this
      # share of what it would.
      SHOT_CLEAR_S = 600.0
      SHOT_BLOWN_OUT_YIELD = 0.25

      # Dynamite is frozen below this.
      DYNAMITE_FREEZES_K = 281.15

      POWDER_GANG = 2

      BLASTING.each do |id, tier|
        Parts.register(id, kind: :pit_blasting, label: tier.fetch(:label), description: tier.fetch(:description),
                           informs: { explosive: tier.fetch(:explosive) }, instruments: %i[stripping_shots ore_shots],
                           stats: tier.slice(:yield_kg, :shot_s)) do |spec|
          FACES.map { |face_id| OpenPit.shot_fragment(face_id, tier, spec.fetch(:machines, {})) }.reduce(:merge)
        end
      end

      def shot_fragment(face_id, tier, machines)
        names = face(face_id)
        struck = { names.(:getters) => names.(:getting) }
        struck[shovel(face_id).(:pitmen)] = shovel(face_id).(:moving_up) if machines.dig(face_id, :shovel)
        Fragment.new(
          nodes: [
            Nodes::ShotHole.new(
              id: names.(:shot_hole), label: "#{face_label(names)} Shot Holes", accepts: [ :explosive ], max_kg_per_s: 40.0,
              heat_capacity: 1.0e3, charge_kg: tier.fetch(:charge_kg), perils: shot_perils(names, tier, struck.keys),
              fired_by: names.(:powder_gang), struck_by: struck, shot_s: tier.fetch(:shot_s), clear_s: SHOT_CLEAR_S,
              yield_kg: tier.fetch(:yield_kg), blown_out_yield: SHOT_BLOWN_OUT_YIELD, fire_control: names.(:fire),
              charge_from: :magazine, freezes_below_k: (DYNAMITE_FREEZES_K if tier.fetch(:explosive) == :dynamite)
            ),
            # Where the charge goes off, and its fumes away into the open air.
            Nodes::Vessel.new(id: names.(:shot), label: "#{face_label(names)} Shot", volume_m3: 5.0, heat_capacity: 1.0e3,
                              ambient_conductance: 5.0, reactions: %i[black_powder_firing dynamite_firing],
                              ports: [ Port.new(id: :in, direction: :inlet, accepts: [ :explosive ], max_kg_per_s: 40.0),
                                       Port.new(id: :fumes, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0) ]),
            Nodes::Conduit.new(id: names.(:fumes), label: "Fumes", accepts: [ :gas ], max_kg_per_s: 40.0, conductance: 0.5,
                               heat_capacity: 1.0e2)
          ],
          links: [ Link.new(from: [ :magazine, :out ], to: [ names.(:shot_hole), :inlet ]),
                   Link.new(from: [ names.(:shot_hole), :outlet ], to: [ names.(:shot), :in ]),
                   Link.new(from: [ names.(:shot), :fumes ], to: [ names.(:fumes), :inlet ]),
                   Link.new(from: [ names.(:fumes), :outlet ], to: [ :atmosphere, :exhaust ]) ],
          places: [ Place.new(id: names.place, nodes: [ names.(:shot_hole), names.(:shot), names.(:fumes) ]) ],
          control_points: [
            # **The post that takes the Shotfirer's Ticket**, the colliery's: worked without it, it is
            # worked with far more going wrong.
            ControlPoint.new(id: names.(:powder_gang), label: "#{face_label(names)} Powder Gang", node: names.(:shot_hole),
                             default: 100.0, place: names.place, capacity: POWDER_GANG,
                             effort: { precision: 0.6, intelligence: 0.4 }, gated_by: %i[darkvision], exertion: 6.0e-4,
                             complexity: 1.0, requires: :shotfirer, openings: [ left_live(names, struck.keys) ]),
            # **The word to fire**: a lever, so the range can be cleared first. Left at fire, every hole
            # goes as soon as it is charged.
            ControlPoint.new(id: names.(:fire), label: "#{face_label(names)} Fire", node: names.(:shot_hole), default: 100.0,
                             place: names.place)
          ]
        )
      end

      # How often a charge misfires, split between the two ways it can be read; frozen, far oftener.
      SHOT_MISFIRE_RATE = 0.4
      FROZEN_MISFIRE_RATE = 1.6

      # **Every accident a shot has is a peril of the powder gang's post**, so a poor hand has more of
      # them; **an unticketed gang has more again** (`unless_tagged: :shotfirer`). A misjudged misfire is
      # struck by whoever digs the face. **Flyrock** comes down for a couple of seconds after every shot
      # (`:flying`), hardest at the face it was fired at and least at the bank — the range the player
      # clears — scaled by how much a tier throws.
      def shot_perils(names, tier, struck)
        gang = [ names.(:powder_gang) ]
        hole = names.(:shot_hole)
        mishap = ->(kind) { { node: hole, kind: kind } }
        throw = tier.fetch(:throw)
        [
          Peril.new(id: :blown_out_shot, rate: 0.4, scales_with: :firing, stations: gang, mishap: mishap.(:blowout)),
          Peril.new(id: :misfired_shot, rate: SHOT_MISFIRE_RATE, judged: :rightly, scales_with: :firing, stations: gang,
                    mishap: mishap.(:misfire)),
          Peril.new(id: :misjudged_misfire, rate: SHOT_MISFIRE_RATE, judged: :wrongly, scales_with: :firing,
                    stations: gang, mishap: mishap.(:misjudged)),
          Peril.new(id: :frozen_misfire, rate: FROZEN_MISFIRE_RATE, judged: :rightly, scales_with: :frozen,
                    stations: gang, mishap: mishap.(:misfire)),
          Peril.new(id: :frozen_misjudged, rate: FROZEN_MISFIRE_RATE, judged: :wrongly, scales_with: :frozen,
                    stations: gang, mishap: mishap.(:misjudged)),
          Peril.new(id: :premature_shot, wounds: { blast: 0.7, burn: 0.3 }, severity: 9.6, rate: 0.06,
                    scales_with: :firing, stations: gang),
          Peril.new(id: :unticketed_premature, wounds: { blast: 0.7, burn: 0.3 }, severity: 9.6, rate: 0.3,
                    scales_with: :firing, stations: gang, unless_tagged: :shotfirer),
          Peril.new(id: :unticketed_misjudged, rate: 1.2, judged: :wrongly, scales_with: :firing, stations: gang,
                    unless_tagged: :shotfirer, mishap: mishap.(:misjudged)),
          Peril.new(id: :set_off_misfire, wounds: { blast: 1.0 }, severity: 12.0, rate: 0.6, scales_with: :misfired,
                    stations: gang, mishap: mishap.(:set_off)),
          Peril.new(id: :struck_live_charge, wounds: { blast: 1.0 }, severity: 14.4, rate: 1.2, scales_with: :live,
                    stations: struck, mishap: mishap.(:struck)),
          *(tier.fetch(:gopher) ? [ gopher_fall(gang) ] : []),
          *flyrock(names, throw)
        ]
      end

      # **The gopher hole falling in** on the man digging it.
      def gopher_fall(gang)
        Peril.new(id: :gopher_hole_fell_in, wounds: { crush: 1.0 }, causes: %i[rockfall], severity: 3.0, rate: 0.3,
                  scales_with: :firing, stations: gang, opportunity: true)
      end

      # The rest of the pit from a face, nearest first.
      ACROSS = { stripping: %i[ore_bench haul_road], ore: %i[stripping_bench haul_road] }.freeze
      FAR = %i[bank spoil_dump dams].freeze

      # **A shot is seconds under falling rock**, so its rates are in the hundreds: a full margin is
      # spent standing at the face it was fired at, and a fraction of one across the pit.
      def flyrock(names, throw)
        thrown = ->(id, places, severity, rate) {
          Peril.new(id: id, wounds: { impact: 1.0 }, causes: %i[rockfall], severity: severity * throw, rate: rate,
                    scales_with: :flying, places: places)
        }
        [ thrown.(:flyrock_at_the_face, [ names.place ], 3.0, 600.0),
          thrown.(:flyrock_across_the_pit, ACROSS.fetch(names.prefix), 2.0, 60.0),
          thrown.(:flyrock_at_the_bank, FAR, 1.2, 15.0) ]
      end

      # **A charge left live in the face on purpose**, for the man he hates to strike.
      def left_live(names, struck)
        Animosity::Opening.new(id: :left_live, stations: struck, harm: 3.6,
                               mishap: { node: names.(:shot_hole), kind: :misjudged })
      end

      # **The magazine**, at the bank, its charges at its own temperature: a powder house in the
      # weather, or a thawing house, heated — too cold and dynamite freezes, too hot and its
      # nitroglycerin sweats out and the house can go up.
      MAGAZINE_KG = 60.0

      Parts.register(:powder_house, kind: :pit_magazine, label: "Powder House",
                     description: "A stone hut at the bank. In the cold, dynamite in it freezes.",
                     provides: %i[magazine]) do |spec|
        OpenPit.magazine_fragment(spec.fetch(:explosive))
      end

      Parts.register(:thawing_house, kind: :pit_magazine, label: "Thawing House",
                     description: "A heated magazine. Too cold, the dynamite freezes; too hot, it sweats and " \
                                  "can go up.",
                     provides: %i[magazine], instruments: %i[the_magazine]) do |spec|
        OpenPit.magazine_fragment(spec.fetch(:explosive), heated: true)
      end

      # Past this the nitroglycerin exudes, and the house wears toward going up.
      EXUDES_K = 318.15

      # **The thawing house going up**, across the bank, by how much was in it.
      MAGAZINE_BLAST = { wounds: { blast: 0.8, burn: 0.2 }, scales_with: :charge_kg, reference: MAGAZINE_KG,
                         places: { bank: 6.0 } }.freeze

      def magazine_fragment(explosive, heated: false)
        heat = heated ? { heater_control_id: :thawing_heat, heater_watts: 1_500.0, max_temperature_k: EXUDES_K,
                          stress_rate: 60.0, endangers: { rupture: MAGAZINE_BLAST } } : {}
        ports = [ Port.new(id: :out, direction: :outlet, accepts: [ :explosive ], max_kg_per_s: 40.0),
                  *([ Port.new(id: :blast, direction: :outlet, accepts: [ :explosive ], max_kg_per_s: 1.0e4) ] if heated) ]
        magazine = Magazine.new(id: :magazine, label: heated ? "Thawing House" : "Powder House", volume_m3: 2.0,
                                heat_capacity: 2.0e4, ambient_conductance: 20.0,
                                initial_contents: [ { resource: explosive, kg: MAGAZINE_KG } ], ports: ports, **heat)
        fragment = Fragment.new(
          nodes: [ magazine ],
          places: [ Place.new(id: :bank, nodes: %i[magazine]) ],
          control_points: heated ? [ ControlPoint.new(id: :thawing_heat, label: "Thawing House Stove", node: :magazine,
                                                      default: 30.0, place: :bank) ] : []
        )
        heated ? fragment.merge(going_up) : fragment
      end

      # **What goes up with it**: every charge in the house, through the hole its going leaves, into
      # where it fires, its fumes away into the open air.
      def going_up
        Fragment.new(
          nodes: [
            Nodes::Breach.new(id: :magazine_breach, label: "Going Up", senses: :magazine, opens_by: { rupture: 1.0 },
                              accepts: [ :explosive ], max_kg_per_s: 1.0e4, heat_capacity: 1.0e3),
            Nodes::Vessel.new(id: :magazine_blast, label: "Blast", volume_m3: 20.0, heat_capacity: 1.0e3,
                              ambient_conductance: 5.0, reactions: %i[black_powder_firing dynamite_firing],
                              ports: [ Port.new(id: :in, direction: :inlet, accepts: [ :explosive ], max_kg_per_s: 1.0e4),
                                       Port.new(id: :fumes, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 200.0) ]),
            Nodes::Conduit.new(id: :magazine_fumes, label: "Fumes", accepts: [ :gas ], max_kg_per_s: 200.0, conductance: 2.0,
                               heat_capacity: 1.0e2)
          ],
          links: [ Link.new(from: [ :magazine, :blast ], to: [ :magazine_breach, :inlet ]),
                   Link.new(from: [ :magazine_breach, :outlet ], to: [ :magazine_blast, :in ]),
                   Link.new(from: [ :magazine_blast, :fumes ], to: [ :magazine_fumes, :inlet ]),
                   Link.new(from: [ :magazine_fumes, :outlet ], to: [ :atmosphere, :exhaust ]) ],
          places: [ Place.new(id: :bank, nodes: %i[magazine_breach magazine_blast magazine_fumes]) ]
        )
      end

      # **Struck by what they bring down**, the harder they bar the likelier.
      def struck_barring(names)
        Peril.new(id: :"struck_barring_the_#{names.prefix}_face", wounds: { impact: 0.7, crush: 0.3 },
                  causes: %i[rockfall], severity: 1.6, rate: 0.12, scales_with: :barring,
                  stations: [ names.(:barmen) ], opportunity: true)
      end

      # --- the pit's water ----------------------------------------------------------------------

      # **Where the pit's water comes from, and where it stands**: seepage from the strata, more the
      # deeper the pit and the wetter the ground, and the springs the ore face meets; rain on the
      # pit; all into the sump at the bottom of the ore bench, which the bailers lift.
      def pit_water(ground)
        [ Nodes::Vessel.new(id: :strata, label: "Strata", volume_m3: STRATA_KG / 1_000.0, ambient_conductance: 0.0,
                            initial_contents: [ { resource: :water, kg: STRATA_KG } ],
                            ports: [ Port.new(id: :out, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: 60.0) ]),
          Seepage.new(id: :seepage, label: "Seepage", accepts: [ :liquid ], max_kg_per_s: 60.0, heat_capacity: 1.0e3,
                      bench: :ore_bench, kg_per_s_per_m: SEEPAGE_KG_PER_S_PER_M, ground: ground),
          Nodes::Catchment.new(id: :pit_catchment, label: "Rain on the Pit", area_m2: PIT_M2),
          # Room for the hole, and for the water up the whole of the ore bench.
          Sump.new(id: :sump, label: "Sump", volume_m3: (SUMP_HOLE_KG + (FLOOR_KG_PER_M * 3.0)) / 1_000.0,
                   heat_capacity: 1.0e4, ambient_conductance: 0.0, hole_kg: SUMP_HOLE_KG, flood_kg: SUMP_FLOOD_KG,
                   deep_kg: SUMP_DEEP_KG, perils: [ going_in ],
                   ports: [ Port.new(id: :in, direction: :inlet, accepts: [ :liquid ], max_kg_per_s: 300.0),
                            Port.new(id: :out, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: 300.0) ]),
          Nodes::Conduit.new(id: :bailing, label: "Bailing", accepts: [ :liquid ], max_kg_per_s: BAILER_KG_PER_S,
                             heat_capacity: 1.0e3, control_id: :bailers, worked: true, crew: BAILERS) ]
      end

      # **Off the bench edge into the water over the flood mark**, onto what lies under it — or pushed.
      # The drowning is the water's own (`Place#water:`), once they are spent treading it.
      def going_in
        Peril.new(id: :into_the_water, wounds: { impact: 1.0 }, causes: %i[fall], severity: 1.2, rate: 0.1,
                  scales_with: :over_the_mark, places: %i[ore_bench], opportunity: true)
      end

      # About 3 kg/s at the median depth; the ground's wetness spreads it from under 1 to about 7.
      SEEPAGE_KG_PER_S_PER_M = 0.43
      STRATA_KG = 5.0e5

      # The pit's footprint and the ground that drains into it.
      PIT_M2 = 1_500.0

      # The hole below the ore floor; knee-deep across the cut is the flood mark; over a man's
      # head, out of his depth.
      SUMP_HOLE_KG = 15_000.0
      FLOOD_MARK_M = 0.3
      OUT_OF_DEPTH_M = 1.4
      # Water a metre deep over the ore bench's floor.
      FLOOR_KG_PER_M = CUT_WIDTH_M * CUT_LENGTH_M * 1_000.0
      SUMP_FLOOD_KG = SUMP_HOLE_KG + (FLOOR_KG_PER_M * FLOOD_MARK_M)
      SUMP_DEEP_KG = SUMP_HOLE_KG + (FLOOR_KG_PER_M * OUT_OF_DEPTH_M)

      BAILERS = 4
      BAILER_KG_PER_S = 0.8

      # From the sump up to the reservoir: the ore bench's median depth and the climb to the bank.
      SUMP_LIFT_M = 10.0

      # **The sump pumps**, every one an upgrade on the line shaft: lifting from the sump to the
      # reservoir, nothing with the shaft stopped.
      SUMP_PUMPS = {
        lift_pump: { label: "Lift Pump", max_kg_per_s: 6.0,
                     description: "A bucket pump at the sump, off the line shaft. An ordinary pit, but not a storm." },
        plunger_pump: { label: "Plunger Pump", max_kg_per_s: 15.0, description: "Holds a wet pit through a storm." },
        centrifugal_pump: { label: "Centrifugal Pump", max_kg_per_s: 40.0,
                            description: "Holds a wet pit that has broken into its springs." }
      }.freeze

      SUMP_PUMPS.each do |id, pump|
        Parts.register(id, kind: :sump_pump, label: pump.fetch(:label), description: pump.fetch(:description),
                           provides: %i[sump_pump], stats: pump.slice(:max_kg_per_s)) do |_spec|
          OpenPit.sump_pump_fragment(pump.fetch(:max_kg_per_s))
        end
      end

      def sump_pump_fragment(max_kg_per_s)
        Fragment.new(
          nodes: [ Nodes::Conduit.new(id: :sump_pump, label: "Sump Pump", accepts: [ :liquid ], max_kg_per_s: max_kg_per_s,
                                      heat_capacity: 1.0e4, control_id: :sump_pumping, driven_by: :line_shaft,
                                      lift_m: SUMP_LIFT_M, efficiency: 0.5, rated_omega: WORKING_OMEGA,
                                      delivers_to: :work, displacement: true) ],
          links: [ Link.new(from: [ :sump, :out ], to: [ :sump_pump, :inlet ]),
                   Link.new(from: [ :sump_pump, :outlet ], to: [ :reservoir, :in ]) ],
          places: [ Place.new(id: :ore_bench, nodes: %i[sump_pump]) ],
          control_points: [ ControlPoint.new(id: :sump_pumping, label: "Sump Pump", node: :sump_pump, default: 100.0,
                                             place: :ore_bench) ]
        )
      end

      def muck(face_id)
        names = face(face_id)
        heap(names.(:muck), "#{face_label(names)} Muck", MUCK_M3)
      end

      # Ports wide enough for a dipperful dumped at once, or a train tipped.
      def heap(id, label, volume_m3, accepts: [ :solid ])
        Nodes::Vessel.new(id: id, label: label, volume_m3: volume_m3, heat_capacity: 1.0e4, ambient_conductance: 0.0,
                          ports: [ Port.new(id: :in, direction: :inlet, accepts: accepts, max_kg_per_s: 2_000.0),
                                   Port.new(id: :out, direction: :outlet, accepts: accepts, max_kg_per_s: 2_000.0) ])
      end

      # What the shaft is rated to take: a full floor of the top washers and a gyratory crusher, so
      # the limit is the supply and not the shaft.
      LINE_SHAFT_NM = 20_000.0

      # The starting reservoir: about a day's washing for the starting washer, full; under two hours
      # for a full floor without a decant.
      RESERVOIR_KG = RESERVOIRS.dig(:reservoir, :capacity_kg)

      # A few seconds of a full floor's water.
      HEAD_TANK_M3 = 2.0

      ROUTES = ([
        { from: :stripping_bench, to: :spoil_dump, carrying: :solid, as: "nothing takes the stripping to the dump" },
        { from: :ore_bench, to: :ore_bin, carrying: :solid, as: "nothing brings the ore to the bin" },
        { from: :sump, to: :reservoir, carrying: :liquid, as: "nothing lifts the pit's water out — the ore bench will flood" }
      ] + washing_routes).freeze
    end
  end
end
