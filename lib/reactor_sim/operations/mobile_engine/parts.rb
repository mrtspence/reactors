# frozen_string_literal: true

module ReactorSim
  module Operations
    module MobileEngine
      ATM = Units::STANDARD_PRESSURE_PA

      # **A vertical boiler and a single small cylinder**, the engine of a period railroad shovel:
      # about 80 kW at work, an eighth of the stationary engine's 500–650 kW. A 2¼-yd³ shovel went through 12,000–
      # 15,000 gallons of water a day (Marsh), about 0.6 kg/s of steam at work, so 40–100 kW.
      #
      # Every figure is the stationary engine's scaled to it — the fire and the air to a sixth, the
      # barrel to a twelfth of the swept volume at a little more pressure — and the sweep on the rig,
      # not this table, is what sets them.
      VERTICAL = {
        firebox: { volume_m3: 1.2, heat_capacity: 6.0e3, ambient_conductance: 15.0 },
        stoker: { max_kg_per_s: 0.25 },
        # The fireman's lever, held: a shovelful at a time, about a tenth of what he could shift.
        firing: 12.0,
        damper: 0.35,
        damper_open: 70.0,
        # The grate shaken through as she runs, rather than raked out by somebody bent double.
        shaking: 20.0,
        tubes: { conductance: 4.0, heat_capacity: 1.0e4, conductance_to_water: 4_000.0 },
        chimney: { conductance: 0.4, stack_height_m: 6.0 },
        # 12 mm over a 0.5 m radius rates about 15 atm from the plate, so a 7 atm drum works at half
        # its shell, as the stationary one does.
        boiler: { shell_radius_m: 0.5, wall_thickness_m: 0.012, working_pressure_pa: 7.0 * ATM,
                  volume_m3: 1.2, water_kg: 500.0, heat_capacity: 1.2e5, ambient_conductance: 30.0,
                  radiant: { conductance: 220.0, radiating_area_m2: 5.0 } },
        feedwater: { pump_kg_per_s: 0.4, steam_kg_per_s: 0.04 },
        throttle: 1.5e-4,
        steam_chest: { volume_m3: 0.15, heat_capacity: 3.0e3 },
        cylinder: { bore_m: 0.25, stroke_m: 0.3, heat_capacity: 4.0e4, wall_thickness_m: 0.015,
                    # A lubricator's charge: at work the rings drink about a kilogram an hour, and
                    # nobody comes round with a can.
                    rings: { mass_kg: 10.0, static_load_n: 400.0, oil_charge_kg: 3.0, oil_loss_kg_per_m: 8.0e-5 } },
        cutoff: 60.0,
        # Heavy for its power: the drum and the gearing turn with it, and the work comes and goes with
        # every swing.
        flywheel: { mass_kg: 1_200.0, radius_m: 0.7, friction: 1.5, safety_factor: 0.45 }
      }.freeze

      # Governed at the speed she was observed working at, which is also what a locomotive's
      # gearing is cut for.
      GOVERNED_OMEGA = 37.0

      Parts.register(:vertical_engine, kind: :mobile_engine, label: "Vertical-Boiler Engine",
                     description: "An upright boiler and one small cylinder on a bedplate. Goes where the work is.",
                     provides: %i[firebox stoker damper ash_pan boiler_tubes flue boiler boiler_breach feed_pump
                                  injector injector_steam throttle steam_pipe_breach steam_chest steam_chest_breach
                                  cylinder piston_rings cylinder_breach drain_cocks flywheel],
                     stats: { working_pressure_pa: VERTICAL.dig(:boiler, :working_pressure_pa), governed_omega: GOVERNED_OMEGA,
                              bore_m: 0.25, stroke_m: 0.3, material: :wrought_iron }) do |spec|
        MobileEngine.engine_fragment(spec.fetch(:names), VERTICAL)
      end

      # --- the bunker and the tank ----------------------------------------------------------

      Parts.register(:small_bunker, kind: :mobile_bunker, label: "Small Bunker",
                     description: "A few hours' coal on the footplate.",
                     provides: %i[bunker], stats: { coal_kg: 300.0 }) do |spec|
        SteamEngine.bunker_fragment(names: spec.fetch(:names), volume_m3: 0.5, coal_kg: 300.0)
      end

      Parts.register(:large_bunker, kind: :mobile_bunker, label: "Large Bunker",
                     description: "A shift's coal and then some.",
                     provides: %i[bunker], stats: { coal_kg: 800.0 }) do |spec|
        SteamEngine.bunker_fragment(names: spec.fetch(:names), volume_m3: 1.2, coal_kg: 800.0)
      end

      Parts.register(:small_tank, kind: :mobile_tank, label: "Small Tank",
                     description: "An hour or two of water, then she wants the standpipe.",
                     provides: %i[supply], stats: { water_kg: 1_500.0 }) do |spec|
        SteamEngine.water_supply_fragment(names: spec.fetch(:names), volume_m3: 1.8, water_kg: 1_500.0, label: "Tank")
      end

      Parts.register(:large_tank, kind: :mobile_tank, label: "Large Tank",
                     description: "Enough water to see out most of a shift.",
                     provides: %i[supply], stats: { water_kg: 4_000.0 }) do |spec|
        SteamEngine.water_supply_fragment(names: spec.fetch(:names), volume_m3: 4.5, water_kg: 4_000.0, label: "Tank")
      end

      # --- the safety tier ------------------------------------------------------------------

      # **A weight on a lever, and the bottom of the ladder.** One setting, nobody can ease it, and
      # it lifts wide over a quarter of its setting, so it holds the drum loosely.
      Parts.register(:dead_weight_valve, kind: :mobile_safety_valve, label: "Dead-Weight Valve",
                     description: "A weight on a lever. One setting, and it lifts slowly.",
                     provides: %i[relief], stats: { setting: "8 atm" }) do |spec|
        SteamEngine.safety_valve_fragment(names: spec.fetch(:names), relief_pa: 8.0 * ATM, max_relief_pa: 8.0 * ATM,
                                          adjustable: false, conductance: 0.012, label: "Dead-Weight Valve")
      end

      # Sprung, so it opens fully just past its setting and holds the drum in a closer band.
      Parts.register(:spring_safety_valve, kind: :mobile_safety_valve, label: "Spring Safety Valve",
                     description: "Sprung, and quick to lift: it holds her close to her setting.",
                     provides: %i[relief], stats: { setting: "8 atm" }) do |spec|
        SteamEngine.safety_valve_fragment(names: spec.fetch(:names), relief_pa: 8.0 * ATM, max_relief_pa: 8.0 * ATM,
                                          adjustable: false, conductance: 0.012, full_open_pa: 8.3 * ATM,
                                          label: "Spring Safety Valve")
      end

      Parts.register(:mobile_fusible_plug, kind: :mobile_fusible_plug, label: "Fusible Plug",
                     description: "Puts the fire out before the crown sheet goes.",
                     provides: %i[fusible_plug]) do |spec|
        SteamEngine.fusible_plug_fragment(names: spec.fetch(:names))
      end

      # --- the shovel -----------------------------------------------------------------------

      # **A yard dipper**, a smaller railroad shovel's, sized to the vertical engine: about 1.4 t of
      # broken overburden a dipperful, round in about a minute at work — some 23 kg/s. The cut is
      # most of the power, about 1.5 kJ a kilogram against a few hundred joules of lift.
      YARD = {
        capacity_kg: 1_400.0, fill_kg_per_s: 90.0, swing_s: 12.0, lift_m: 6.0, work_j_per_kg: 1_500.0,
        swing_w: 8_000.0, rated_omega: 37.0,
        # A set-up's worth within the boom's reach, kept there by five pitmen at 8 kg/s each.
        reach_m3: 3.0, moving_up_kg_per_s: 8.0, pitmen: 5
      }.freeze

      Parts.register(:yard_dipper, kind: :shovel_dipper, label: "Yard Dipper",
                     description: "A one-yard dipper on a railroad shovel: dig, swing, dump, swing back.",
                     provides: %i[dipper reach moving_up hose],
                     stats: YARD.slice(:capacity_kg, :swing_s, :pitmen)) do |spec|
        MobileEngine.shovel_fragment(spec.fetch(:names), spec.fetch(:host), YARD)
      end

      # **What the chain brings down when it parts**: the dipper, on whoever is under the boom.
      CHAIN_PARTED = ->(names) { { wounds: { crush: 1.0 }, places: { names.place => 3.0 } } }
      # **And the boom**: the whole jib and its dipper across the shovel's ground.
      BOOM_DOWN = ->(names) { { wounds: { crush: 0.6, impact: 0.4 }, places: { names.place => 8.0 } } }

      module_function

      def chain_fragment(names, breaking_kn:, wear_per_s:, shows_wear:)
        Fragment.new(nodes: [
          Chain.new(id: names.(:chain), dipper: names.(:dipper), breaking_kn: breaking_kn, wear_per_s: wear_per_s,
                    shows_wear: shows_wear, splice_control: names.(:pitmen),
                    endangers: { parted: CHAIN_PARTED.(names) })
        ])
      end

      def boom_fragment(names, rated_n:, fatigue_per_s:, label:)
        Fragment.new(nodes: [
          Boom.new(id: names.(:boom), dipper: names.(:dipper), rated_n: rated_n, fatigue_per_s: fatigue_per_s,
                   label: label, endangers: { down: BOOM_DOWN.(names) })
        ])
      end

      # **Iron, the bottom**: weaker, and it shows its wear — the period's choice because it warned.
      Parts.register(:iron_chain, kind: :shovel_chain, label: "Iron Chain",
                     description: "Weaker, and you can see it going.",
                     provides: %i[chain], stats: { breaking_kn: 500.0 }) do |spec|
        MobileEngine.chain_fragment(spec.fetch(:names), breaking_kn: 500.0, wear_per_s: 1.0, shows_wear: true)
      end

      # **Steel**: stronger, and it wears faster under the snatch and parts with no warning.
      Parts.register(:steel_chain, kind: :shovel_chain, label: "Steel Chain",
                     description: "Stronger. It goes without telling you.",
                     provides: %i[chain], stats: { breaking_kn: 800.0 }) do |spec|
        MobileEngine.chain_fragment(spec.fetch(:names), breaking_kn: 800.0, wear_per_s: 3.3, shows_wear: false)
      end

      Parts.register(:timber_boom, kind: :shovel_boom, label: "Timber Boom",
                     description: "Oak, trussed with iron rods. Force her through hard ground and it tires.",
                     provides: %i[boom], stats: { rated_kn: 200.0 }) do |spec|
        MobileEngine.boom_fragment(spec.fetch(:names), rated_n: 200_000.0, fatigue_per_s: 2.0, label: "Timber Boom")
      end

      Parts.register(:steel_boom, kind: :shovel_boom, label: "Steel Boom",
                     description: "A riveted steel jib that takes a hard cut in its stride.",
                     provides: %i[boom], stats: { rated_kn: 350.0 }) do |spec|
        MobileEngine.boom_fragment(spec.fetch(:names), rated_n: 350_000.0, fatigue_per_s: 2.0, label: "Steel Boom")
      end

      # --- the locomotive ------------------------------------------------------------------

      # **A dinkey**: a 10-t contractor's engine on 0.4 m wheels, geared to make 3.5 m/s — about
      # 8 mph, a pit's running speed — at the engine's governed speed. Its cars are tiered with it,
      # because a train is weighed and braked as one.
      DINKEY = { engine_kg: 10_000.0, radius_m: 0.4, rated_m_s: 3.5, clutch_stiffness: 3.0e4 }.freeze

      # A side-dump car of 3 yd³ holds about 2.3 m³ — some 4 t of overburden.
      SIDE_DUMP_M3 = 2.3

      def self.train_figures(cars:, car_tare_kg:)
        volume = cars * SIDE_DUMP_M3
        DINKEY.merge(cars: cars, cars_m3: volume, tare_kg: DINKEY.fetch(:engine_kg) + (cars * car_tare_kg),
                     load_kg: volume * 1_800.0)
      end

      WOODEN_TRAIN = train_figures(cars: 4, car_tare_kg: 1_500.0).freeze
      STEEL_TRAIN = train_figures(cars: 6, car_tare_kg: 1_800.0).freeze

      Parts.register(:dinkey_train, kind: :locomotive_train, label: "Dinkey and Wooden Side-Dumps",
                     description: "A little geared engine and four wooden side-dump cars.",
                     provides: %i[train cars loading tipping],
                     stats: WOODEN_TRAIN.slice(:cars, :tare_kg, :load_kg, :radius_m, :rated_m_s)) do |spec|
        MobileEngine.train_fragment(spec.fetch(:names), spec.fetch(:host), WOODEN_TRAIN)
      end

      Parts.register(:dinkey_steel_train, kind: :locomotive_train, label: "Dinkey and Steel Side-Dumps",
                     description: "Six steel side-dump cars: half as much again each trip, and heavier to stop.",
                     provides: %i[train cars loading tipping],
                     stats: STEEL_TRAIN.slice(:cars, :tare_kg, :load_kg, :radius_m, :rated_m_s)) do |spec|
        MobileEngine.train_fragment(spec.fetch(:names), spec.fetch(:host), STEEL_TRAIN)
      end

      def self.brake_fragment(names, capacity_nm:, heat_capacity:, label:)
        Fragment.new(
          nodes: [ Nodes::Brake.new(id: names.(:brake), label: label, supports: names.(:train), capacity_nm: capacity_nm,
                                    heat_capacity: heat_capacity, control_id: names.(:brake_release)) ],
          control_points: [ ControlPoint.new(id: names.(:brake_release), label: label, node: names.(:brake),
                                             place: names.place, default: 0.0, internal: true) ]
        )
      end

      # **A screw hand brake on the engine**, the bottom: about twice what holds a loaded train on the
      # bank, small enough to heat on a long run down.
      Parts.register(:hand_brake, kind: :locomotive_brake, label: "Hand Brake",
                     description: "A screw brake on the engine's wheels. Holds her; stops her slowly.",
                     provides: %i[brake], stats: { capacity_nm: 5_000.0 }) do |spec|
        MobileEngine.brake_fragment(spec.fetch(:names), capacity_nm: 5_000.0, heat_capacity: 2.5e4, label: "Hand Brake")
      end

      Parts.register(:steam_brake, kind: :locomotive_brake, label: "Steam Brake",
                     description: "A steam cylinder on the brake rigging: stops her in a third of the road.",
                     provides: %i[brake], stats: { capacity_nm: 12_000.0 }) do |spec|
        MobileEngine.brake_fragment(spec.fetch(:names), capacity_nm: 12_000.0, heat_capacity: 4.0e4, label: "Steam Brake")
      end

      # --- what the driver reads by ---------------------------------------------------------
      #
      # **Instruments for the driver, not the player**: they build nothing, and what they say is
      # how finely he reads (`Driver`).

      Parts.register(:mobile_try_cocks, kind: :mobile_water_reading, label: "Try-Cocks",
                     description: "Taps at three heights. He knows which side of each the water is.",
                     stats: { water_step: 0.2 }) { |_spec| Fragment.empty }

      Parts.register(:mobile_gauge_glass, kind: :mobile_water_reading, label: "Gauge Glass",
                     description: "He can see the water.",
                     stats: { water_step: 0.02 }) { |_spec| Fragment.empty }

      Parts.register(:mobile_pressure_gauge, kind: :mobile_pressure_reading, label: "Bourdon Gauge",
                     description: "He knows her pressure by a dial instead of by her voice.",
                     stats: { pressure_step_pa: 0.1 * ATM }) { |_spec| Fragment.empty }
    end
  end
end
