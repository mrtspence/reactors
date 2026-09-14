# frozen_string_literal: true

module ReactorSim
  module Operations
    module SteamEngine
      # The engine, as components.
      #
      # Each `Parts.register` here wraps one of `definition.rb`'s node builders and adds the
      # wiring that comes with it. The node configuration itself — and the measurements that
      # chose every number in it — stays where it was; only the links moved, out of one central
      # list and onto the parts they belong to.
      #
      # **That move is the point of the whole exercise.** Deleting the safety valve used to
      # mean editing `nodes`, `links`, `control_points` and `diagnostics` across two files and
      # hoping you found all four; now it means not fitting a part.
      #
      # `provides:` is the id contract: the id belongs to the ROLE, not to the part. Every
      # boiler ever fitted names its drum `:boiler`, so the wiring around it, the gauges
      # pointed at it and its rng stream all survive a swap untouched.
      #
      # See `docs/design_sketches/modular_components.md`.
      module_function

      # --- shared shapes ---------------------------------------------------------
      #
      # **Where two parts of one kind differ only in numbers, the wiring is written once.**
      # Eight kinds have a high-pressure and an atmospheric variant, and the thing that varies
      # between them is a handful of figures, never the links or the levers — so duplicating the
      # fragment would be sixteen chances for the two to drift apart on something that is not
      # supposed to vary at all.
      #
      # These are the shapes. The numbers, and the sweeps that chose them, sit on the
      # registrations below.

      def damper_fragment(conductance:)
        Fragment.new(
          nodes: [ SteamEngine.damper(conductance: conductance) ],
          links: [ Link.new(from: [ :damper, :outlet ], to: [ :firebox, :air_in ]) ],
          control_points: [
            ControlPoint.new(id: :damper_open, label: "Damper", node: :damper, default: 50.0)
          ]
        )
      end

      def chimney_fragment(blastpipe:)
        Fragment.new(
          nodes: [ SteamEngine.flue(blastpipe: blastpipe) ],
          links: [ Link.new(from: [ :flue, :outlet ], to: [ :atmosphere, :exhaust ]) ]
        )
      end

      def boiler_fragment(shell_radius_m:, wall_thickness_m:)
        Fragment.new(
          nodes: [ SteamEngine.boiler(shell_radius_m: shell_radius_m,
                                      wall_thickness_m: wall_thickness_m) ],
          # The firebox glowing straight at the water legs around it. The other half of the
          # fire→water path is the tube bundle, which arrives with `:stock_boiler_tubes` — the
          # split matters more than either number. See `SteamEngine.boiler_tubes`.
          thermal_links: [ ThermalLink.new(a: :firebox, b: :boiler, conductance: 3_500.0) ]
        )
      end

      def safety_valve_fragment(relief_pa:, max_relief_pa:)
        Fragment.new(
          nodes: [ SteamEngine.relief_valve(relief_pa: relief_pa, max_relief_pa: max_relief_pa) ],
          links: [
            Link.new(from: [ :boiler, :relief_out ], to: [ :relief, :inlet ]),
            Link.new(from: [ :relief, :outlet ],     to: [ :atmosphere, :exhaust ])
          ],
          control_points: [
            ControlPoint.new(id: :ease_safety, label: "Ease the Safety Valve", node: :relief),
            ControlPoint.new(id: :valve_setting, label: "Safety Valve Margin", node: :relief,
                             default: 100.0)
          ]
        )
      end

      def cylinder_fragment(spec, bore_m:, stroke_m:, heat_capacity:)
        Fragment.new(
          nodes: [ SteamEngine.cylinder(spec, bore_m: bore_m, stroke_m: stroke_m,
                                              heat_capacity: heat_capacity) ],
          control_points: [
            ControlPoint.new(id: :cutoff, label: "Cut-off", node: :cylinder, default: 100.0)
          ]
        )
      end

      def cylinder_relief_fragment(relief_pa:, max_relief_pa:)
        Fragment.new(
          nodes: [ SteamEngine.cylinder_relief(relief_pa: relief_pa,
                                               max_relief_pa: max_relief_pa) ],
          links: [
            Link.new(from: [ :cylinder, :relief ],        to: [ :cylinder_relief, :inlet ]),
            Link.new(from: [ :cylinder_relief, :outlet ], to: [ :atmosphere, :exhaust ])
          ],
          control_points: [
            ControlPoint.new(id: :cylinder_valve_setting, label: "Cylinder Relief Margin",
                             node: :cylinder_relief, default: 100.0)
          ]
        )
      end

      def flywheel_fragment(mass_kg:, radius_m:, friction:, safety_factor:)
        Fragment.new(
          nodes: [ SteamEngine.flywheel(mass_kg: mass_kg, radius_m: radius_m,
                                        friction: friction, safety_factor: safety_factor) ],
          drive_links: [ DriveLink.new(a: :flywheel, b: :load, stiffness: 9_000.0) ]
        )
      end

      def load_fragment(moment_of_inertia:, max_torque:, rated_omega:)
        Fragment.new(
          nodes: [ SteamEngine.load(moment_of_inertia: moment_of_inertia,
                                    max_torque: max_torque, rated_omega: rated_omega) ],
          control_points: [
            ControlPoint.new(id: :load_demand, label: "Mill Load", node: :load, default: 60.0)
          ]
        )
      end

      # --- fire ----------------------------------------------------------------

      Parts.register(:stock_firebox, kind: :firebox, label: "Firebox",
                     provides: %i[firebox], instruments: %i[firebox_temp fire_state],
                     stats: { volume_m3: 6.0, igniter_kw: 120 }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.firebox ],
          control_points: [ ControlPoint.new(id: :igniter, label: "Igniter", node: :firebox) ]
        )
      end

      Parts.register(:stock_bunker, kind: :bunker, label: "Fuel Bunker",
                     provides: %i[bunker], instruments: %i[coal_remaining],
                     stats: { volume_m3: 40.0, coal_kg: 12_000.0 }) do |_spec|
        Fragment.new(nodes: [ SteamEngine.fuel_bunker ])
      end

      Parts.register(:stock_stoker, kind: :stoking_gear, label: "Stoking Line",
                     provides: %i[stoker], stats: { max_kg_per_s: 0.25 }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.stoker ],
          links: [
            Link.new(from: [ :bunker, :out ],    to: [ :stoker, :inlet ]),
            Link.new(from: [ :stoker, :outlet ], to: [ :firebox, :fuel_in ])
          ],
          control_points: [ ControlPoint.new(id: :stoking, label: "Stoking Effort", node: :stoker) ]
        )
      end

      # Raking out the ashpan. **Not optional chrome** — it is the remedy that makes the choked
      # grate a mechanic rather than a slow dead end. Ash is produced by both combustion
      # reactions and consumed by nothing, so without a way out the fire quietly strangles
      # itself over a long game and no lever a player can reach will help.
      Parts.register(:stock_ash_pan, kind: :ash_handling, label: "Ashpan",
                     provides: %i[ash_pan], stats: { max_kg_per_s: 0.5 }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.ash_pan ],
          links: [
            Link.new(from: [ :firebox, :ash_out ], to: [ :ash_pan, :inlet ]),
            Link.new(from: [ :ash_pan, :outlet ], to: [ :atmosphere, :exhaust ])
          ],
          control_points: [
            ControlPoint.new(id: :ash_raking, label: "Rake the Ashpan", node: :ash_pan)
          ]
        )
      end

      # **`conductance` is the only air control there is, and 0.35 is what the blower was
      # secretly paying for.** Reported from play: the blower was worth about +60 kW on demand,
      # for free, and the engine sagged whenever it was shut off. It was not a blower problem —
      # the damper conductance was undersized by roughly a factor of two, and the blower's 600 Pa
      # of head, against a 10 m stack worth ~69 Pa and a blastpipe worth ~361 Pa, was making up
      # the difference.
      #
      # Measured at full controls, blower OFF, sweeping this number alone:
      #
      #     k     0.20   0.25   0.30   0.35   0.40   0.50   0.60
      #     kW   335.1  432.2  476.6  493.3  491.3  497.4  499.0
      #     fire   986   1000   1002   1001    999    993    988   K
      #                                  ^ here: the knee, and the hottest fire
      #
      # And what the blower is still worth, by conductance: **+152.7 kW at 0.2, +16.4 at 0.3,
      # +2.9 at 0.4, and −2.4 at 0.5** — past the knee it over-draughts and cools the fire
      # (993 → 931 K). So opening the damper does not merely replace the blower, it **removes the
      # exploit**: there is no longer a free 45% sitting behind a lever, because the engine is
      # already getting the air. That is what a blower is for — raising the first steam on a cold
      # stack — and it is inert once the fire is drawing for itself.
      #
      # 0.35 rather than 0.4+ because above the knee the engine burns more fuel for no more work
      # and then starts feathering its safety valve: 0.4 burns 3.4% more coal for 0.4% *less*
      # power.
      #
      # **The old note claiming "×1.5 and above simply pins the boiler on its safety valve and
      # the engine stops gaining anything" was wrong** — ×1.5 is 0.3, which measures at 599.5 kPa,
      # off the valve, and +142 kW. It was measured before the steam chest, the regulator trim and
      # the stoker rating all moved. A stale measurement is worse than none; it had been cited as
      # a reason not to touch this.
      Parts.register(:wide_damper, kind: :damper, label: "Wide Damper",
                     description: "Sized at the knee of the draught curve.",
                     provides: %i[damper], instruments: %i[air_supply],
                     stats: { conductance: 0.35 }) do |_spec|
        SteamEngine.damper_fragment(conductance: 0.35)
      end

      # **A smaller fire than Trevithick's, and its conductance is the only thing that makes it
      # smaller.** Period-correct — Watt's engines were low-pressure machines — and also as much
      # as this one's condenser can swallow: fed the high-pressure draught it makes more steam
      # than the condenser can lay down, and the vacuum it exists to pull collapses.
      #
      # **Deliberately not raised alongside the wide damper.** That one was measured across seven
      # points; this one has its own condenser balance and wants its own sweep, which nobody has
      # run. A `draught_kg_per_s` used to sit beside it claiming to be the fire size and was
      # inert — see `SteamEngine.damper`.
      Parts.register(:narrow_damper, kind: :damper, label: "Narrow Damper",
                     description: "Restricted, to suit a condenser that cannot swallow more.",
                     provides: %i[damper], instruments: %i[air_supply],
                     stats: { conductance: 0.1 }) do |_spec|
        SteamEngine.damper_fragment(conductance: 0.1)
      end

      # **The blower, and it is the first part on this engine that is genuinely optional.**
      #
      # `when_empty: :bypass` and not `:omit`, because the air still has to get in: without a
      # fan the atmosphere connects straight to the damper and the fire draws on stack buoyancy
      # alone. That is a real machine — every naturally-drawn boiler is one — and it is a real
      # decision, because a cold stack has no buoyancy, so an engine built without a blower
      # cannot raise its own first steam. Exactly the shape the progression wants: no extra
      # power, and you notice its absence at the worst moment.
      #
      # **WIP.** It is still free, and it should not be. See the TODO on
      # `SteamEngine.blower_fan` for what it owes and the black-start constraint that rules out
      # the easy answer.
      Parts.register(:stock_blower, kind: :forced_draught, label: "Blower", wip: true,
                     description: "Forced draught for lighting up. Costs nothing yet — it will.",
                     provides: %i[blower_fan],
                     stats: { head_pa: 600.0, cost: "none yet (WIP)" }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.blower_fan ],
          links: [
            Link.new(from: [ :atmosphere, :intake ], to: [ :blower_fan, :inlet ]),
            Link.new(from: [ :blower_fan, :outlet ], to: [ :damper, :inlet ])
          ],
          control_points: [
            ControlPoint.new(id: :blower, label: "Blower", node: :blower_fan)
          ]
        )
      end

      # Through the tubes on the way to the chimney, which is where the water gets most of its
      # heat. The blastpipe still joins at the chimney, downstream of the tubes, which is where
      # a locomotive puts it.
      Parts.register(:stock_boiler_tubes, kind: :boiler_tubes, label: "Boiler Tubes",
                     provides: %i[boiler_tubes],
                     stats: { conductance: 4.0, material: :wrought_iron }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.boiler_tubes ],
          links: [
            Link.new(from: [ :firebox, :flue_out ],    to: [ :boiler_tubes, :inlet ]),
            Link.new(from: [ :boiler_tubes, :outlet ], to: [ :flue, :inlet ])
          ],
          # Strong, so the tube metal sits near the water rather than near the fire. What
          # limits the transfer is the enthalpy the gas is carrying, not this number.
          thermal_links: [ ThermalLink.new(a: :boiler_tubes, b: :boiler, conductance: 20_000.0) ]
        )
      end

      # **The blastpipe is part of the chimney, not a part of its own, and the sketch was wrong
      # about this.** §5 listed it alongside the blower and the stack as an attribute that had to
      # become its own node to become a part. The blower genuinely did — it is a fan bolted to
      # the ashpan, and it is now `:blower_fan`. The blastpipe is different on two counts.
      #
      # *Physically*, a blastpipe and the chimney above it are one assembly: their proportions
      # were tuned together, and getting that ratio right was the central art of locomotive
      # draughting. A nozzle without the stack it points up is not a thing.
      #
      # *Mechanically*, splitting them would have been worse than useless. The blast head has to
      # reach BOTH paths through the chimney — the draught path from the firebox and the
      # cylinder's own exhaust — and today it does, because the flue sits on both. A separate
      # blastpipe node between the tubes and the flue would sit on the draught path only, and
      # one placed to catch both would have to own the chassis's exhaust link, which belongs to
      # the chassis. So: one part, two variants.
      #
      # `stack_height_m` is a chimney property and stays here too, which makes a taller chimney a
      # straightforward future variant rather than a promotion.
      Parts.register(:blastpipe_chimney, kind: :chimney, label: "Chimney and Blastpipe",
                     description: "Exhausts up the stack, so the engine draws harder the " \
                                  "harder it works.",
                     provides: %i[flue],
                     stats: { stack_height_m: 10.0, blast_pa_per_kg_per_s: 600.0 }) do |_spec|
        SteamEngine.chimney_fragment(blastpipe: true)
      end

      # Watt's engine sends its exhaust to the condenser — that vacuum IS the engine — so there
      # is nothing left to throw up the chimney. It draws on stack height alone, which is why a
      # beam engine was built with a tall one and lit with a blower.
      Parts.register(:plain_chimney, kind: :chimney, label: "Chimney",
                     description: "Draws on stack buoyancy alone.",
                     provides: %i[flue], stats: { stack_height_m: 10.0 }) do |_spec|
        SteamEngine.chimney_fragment(blastpipe: false)
      end

      # --- water ---------------------------------------------------------------

      Parts.register(:stock_water_supply, kind: :water_supply, label: "Water Supply",
                     provides: %i[supply], instruments: %i[water_remaining],
                     stats: { volume_m3: 12.0, water_kg: 6_000.0 }) do |_spec|
        Fragment.new(nodes: [ SteamEngine.water_supply ])
      end

      # **The feed pump, the injector and its steam pipe are ONE part**, because they are one
      # fitting and because they share one lever. `:feed` drives both the water side and the
      # steam side — that is what an injector is, a fixed-geometry nozzle passing a fixed ratio
      # of steam to water — so splitting them into separate slots would let a player fit half
      # an injector and leave the lever pointing at nothing.
      #
      # Water and steam meet in the injector; hot water goes on to the drum. Boiler → injector
      # → boiler is a closed loop, which needs no special handling: paths are resolved holder
      # to holder and nothing here depends on a topological order.
      Parts.register(:stock_injector, kind: :feedwater, label: "Injector and Feed Pump",
                     provides: %i[feed_pump injector injector_steam],
                     stats: { pump_kg_per_s: 2.0, steam_kg_per_s: 0.20 }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.feed_pump, SteamEngine.injector, SteamEngine.injector_steam ],
          links: [
            Link.new(from: [ :supply, :out ],            to: [ :feed_pump, :inlet ]),
            Link.new(from: [ :feed_pump, :outlet ],      to: [ :injector, :water_in ]),
            Link.new(from: [ :boiler, :injector_out ],   to: [ :injector_steam, :inlet ]),
            Link.new(from: [ :injector_steam, :outlet ], to: [ :injector, :steam_in ]),
            Link.new(from: [ :injector, :out ],          to: [ :boiler, :feed_in ])
          ],
          control_points: [ ControlPoint.new(id: :feed, label: "Feed Pump", node: :feed_pump) ]
        )
      end

      # A 5 m³ drum at 0.6 m radius is about 4.4 m long — a locomotive-sized barrel — and 14 mm
      # wrought iron is period-correct for 6 atm. Derived rating **14.39 atm**, arrived at from
      # the plate rather than from a gauge scale. See `SteamEngine.boiler` for why that
      # derivation replaced a circular `relief_pa * 1.5`.
      Parts.register(:locomotive_boiler, kind: :boiler, label: "Locomotive Boiler",
                     description: "A long riveted barrel, thick enough for real pressure.",
                     provides: %i[boiler],
                     instruments: %i[boiler_pressure boiler_water crown_sheet],
                     stats: { volume_m3: 5.0, shell_radius_m: 0.6, wall_thickness_m: 0.014,
                              material: :wrought_iron, rated_pressure: "14.39 atm" }) do |_spec|
        SteamEngine.boiler_fragment(shell_radius_m: 0.6, wall_thickness_m: 0.014)
      end

      # A wide, thin drum: a beam engine's boiler is a big low-pressure thing, and 6 mm of
      # wrought iron over a 0.75 m radius is plenty for 1.4 atm. Derived rating **4.93 atm**.
      #
      # Note the two are not interchangeable in practice even though the slot accepts both: put
      # this one on a high-pressure chassis and its safety valve is set above what the shell can
      # take. **The validator does not catch that** — it is a `burst_pa`-versus-`relief_pa`
      # comparison nothing currently makes, and it is the obvious next advisory.
      Parts.register(:beam_boiler, kind: :boiler, label: "Beam Engine Boiler",
                     description: "Wide, thin, and low-pressure — a big kettle.",
                     provides: %i[boiler],
                     instruments: %i[boiler_pressure boiler_water crown_sheet],
                     stats: { volume_m3: 5.0, shell_radius_m: 0.75, wall_thickness_m: 0.006,
                              material: :wrought_iron, rated_pressure: "4.93 atm" }) do |_spec|
        SteamEngine.boiler_fragment(shell_radius_m: 0.75, wall_thickness_m: 0.006)
      end

      # --- steam ---------------------------------------------------------------

      # 6 atm with the screw at full margin; 9 atm wound right down. **9 is 63% of the shell's
      # derived 14.39, deliberately** — the shell should never be the binding constraint, because
      # the flywheel and the crown sheet are the interesting limits and they both bite first. The
      # measured risk/reward curve across the screw's travel is on `SteamEngine.relief_valve`.
      Parts.register(:ramsbottom_safety_valve, kind: :safety_valve, label: "Ramsbottom Valve",
                     description: "Adjustable from 6 to 9 atm. Spend the margin and the " \
                                  "flywheel pays for it.",
                     provides: %i[relief], instruments: %i[safety_valve valve_setting_pa],
                     stats: { safe_setting: "6 atm", full_risk: "9 atm",
                              easing_lever: true }) do |_spec|
        SteamEngine.safety_valve_fragment(relief_pa: 6.0 * Units::STANDARD_PRESSURE_PA,
                                          max_relief_pa: 9.0 * Units::STANDARD_PRESSURE_PA)
      end

      # **A far narrower band, because a Watt engine has nothing to gain from pressure** — it
      # works by making a vacuum. Winding this up buys almost nothing and risks a 4.93 atm shell.
      Parts.register(:low_pressure_safety_valve, kind: :safety_valve,
                     label: "Low-Pressure Safety Valve",
                     description: "1.4 to 2.2 atm. There is little to gain by winding it up.",
                     provides: %i[relief], instruments: %i[safety_valve valve_setting_pa],
                     stats: { safe_setting: "1.4 atm", full_risk: "2.2 atm",
                              easing_lever: true }) do |_spec|
        SteamEngine.safety_valve_fragment(relief_pa: 1.4 * Units::STANDARD_PRESSURE_PA,
                                          max_relief_pa: 2.2 * Units::STANDARD_PRESSURE_PA)
      end

      # **Into the firebox, not to the sky**, and that is the whole point of the part. A plug
      # that vented outside would be a leak; venting onto the grate is what kills the fire and
      # forces the driver to stop, which is the safety function.
      Parts.register(:stock_fusible_plug, kind: :fusible_plug, label: "Fusible Plug",
                     provides: %i[fusible_plug], instruments: %i[plug_blown],
                     stats: { melts_above_k: 620.0 }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.fusible_plug ],
          links: [
            Link.new(from: [ :boiler, :plug_out ],     to: [ :fusible_plug, :inlet ]),
            Link.new(from: [ :fusible_plug, :outlet ], to: [ :firebox, :plug_in ])
          ]
        )
      end

      # Boiler → regulator → chest is **pressure-driven**, because the throttle declares a
      # conductance and a passive vessel sits at each end. Chest → cylinder is **rate-driven**,
      # because the cylinder declares a positive-displacement draw. Two laws either side of one
      # node, which is exactly what the chest is for: the gradient decides what can get in, the
      # geometry decides what is taken out, and the pressure between them is where the two
      # negotiate.
      Parts.register(:stock_regulator, kind: :regulator, label: "Throttle Valve",
                     provides: %i[throttle],
                     stats: { conductance: 1.5e-3, rangeability: 8.0 }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.throttle ],
          links: [
            Link.new(from: [ :boiler, :steam_out ], to: [ :throttle, :inlet ]),
            Link.new(from: [ :throttle, :outlet ],  to: [ :steam_chest, :in ])
          ],
          control_points: [
            ControlPoint.new(id: :throttle_open, label: "Throttle", node: :throttle)
          ]
        )
      end

      Parts.register(:stock_steam_chest, kind: :steam_chest, label: "Steam Chest",
                     provides: %i[steam_chest], stats: { volume_m3: 1.0 }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.steam_chest ],
          links: [ Link.new(from: [ :steam_chest, :out ], to: [ :cylinder, :inlet ]) ]
        )
      end

      # --- engine --------------------------------------------------------------

      # `heat_capacity` is the metal a cold cylinder has to warm through, and it is the number
      # the whole drain-cocks procedure lives in — see `SteamEngine.cylinder` for the arithmetic
      # and for why an order-of-magnitude-light value made the cocks decoration.
      #
      # These two take `spec` because `exhausts_to` is genuinely the chassis's: where the exhaust
      # goes is the machine's shape, not the barrel's rating.
      Parts.register(:high_pressure_cylinder, kind: :cylinder, label: "High-Pressure Cylinder",
                     description: "Small bore, short stroke, and it pushes with boiler pressure.",
                     provides: %i[cylinder],
                     instruments: %i[engine_power cylinder_pressure cylinder_water],
                     stats: { bore_m: 0.45, stroke_m: 1.1, material: :cast_iron,
                              efficiency: 0.82 }) do |spec|
        SteamEngine.cylinder_fragment(spec, bore_m: 0.45, stroke_m: 1.1, heat_capacity: 4.0e5)
      end

      # A far bigger casting, but a **thinner-walled** one: shell thickness goes as `p·r`, and
      # 1.4 atm across a 0.65 m radius is a gentler duty than 6 atm across 0.225 m. So ~17 mm
      # here against ~25 mm on Trevithick's, which is why the thermal mass is 5× the
      # high-pressure figure rather than the 9× the raw volumes suggest.
      Parts.register(:atmospheric_cylinder, kind: :cylinder, label: "Atmospheric Cylinder",
                     description: "Vast bore, long stroke, and the sky does the pushing.",
                     provides: %i[cylinder],
                     instruments: %i[engine_power cylinder_pressure cylinder_water],
                     stats: { bore_m: 1.3, stroke_m: 2.4, material: :cast_iron,
                              efficiency: 0.82 }) do |spec|
        SteamEngine.cylinder_fragment(spec, bore_m: 1.3, stroke_m: 2.4, heat_capacity: 2.0e6)
      end

      # Straight to the ground, which is where cylinder cocks blow. What leaves this way is
      # gone — it reaches `Atmosphere` and lands on the ledger as `mass_vented`, not back in
      # the water supply.
      #
      # **Defaults shut, and that is not the safe setting.** A standing engine should have its
      # cocks open; this defaults closed because that is the state the engine's whole balance
      # was measured in, and a lever whose default silently changes every other number is worse
      # than one a player has to learn. Opening them is part of the starting procedure, not a
      # correction to it.
      Parts.register(:stock_drain_cocks, kind: :drain_cocks, label: "Cylinder Cocks",
                     provides: %i[drain_cocks], stats: { max_kg_per_s: 0.25 }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.drain_cocks ],
          links: [
            Link.new(from: [ :cylinder, :drain ],     to: [ :drain_cocks, :inlet ]),
            Link.new(from: [ :drain_cocks, :outlet ], to: [ :atmosphere, :exhaust ])
          ],
          control_points: [
            ControlPoint.new(id: :cylinder_cocks, label: "Cylinder Cocks", node: :drain_cocks)
          ]
        )
      end

      # Its base is where it has always sat — 1.5× the boiler valve's safe setting — but stated
      # absolutely, because a cylinder valve's setting is a property of the cylinder and not of
      # where the boiler's valve happens to be. The top of the range is deliberately generous:
      # the barrel's derived hoop rating is far above either figure, so a player who fits a
      # better cylinder finds room here rather than a limit left over from this one.
      Parts.register(:high_pressure_cylinder_relief, kind: :cylinder_relief,
                     label: "Cylinder Relief Valve",
                     description: "9 to 20 atm. It never lifts in steady running — and it is " \
                                  "what saves the cylinder every time you warm one through.",
                     provides: %i[cylinder_relief], instruments: %i[cylinder_relief_valve],
                     stats: { safe_setting: "9 atm", full_risk: "20 atm" }) do |_spec|
        SteamEngine.cylinder_relief_fragment(
          relief_pa: 9.0 * Units::STANDARD_PRESSURE_PA,
          max_relief_pa: 20.0 * Units::STANDARD_PRESSURE_PA
        )
      end

      Parts.register(:low_pressure_cylinder_relief, kind: :cylinder_relief,
                     label: "Low-Pressure Cylinder Relief Valve",
                     description: "2.1 to 5 atm, to suit a cylinder the sky pushes.",
                     provides: %i[cylinder_relief], instruments: %i[cylinder_relief_valve],
                     stats: { safe_setting: "2.1 atm", full_risk: "5 atm" }) do |_spec|
        SteamEngine.cylinder_relief_fragment(
          relief_pa: 2.1 * Units::STANDARD_PRESSURE_PA,
          max_relief_pa: 5.0 * Units::STANDARD_PRESSURE_PA
        )
      end

      # **`safety_factor: 0.45`, up from 0.35, and it is what makes the boiler dangerous.** At
      # 0.35 the wheel burst before the crown sheet could develop in the one regime that matters.
      # 0.45 is the minimum that works and the minimum is the point — it makes the crown
      # reachable at every pressure while leaving the wheel at 0.41 of its burst stress wound
      # right down, so the Wheel Stress gauge still spans a real gradient. The full sweep,
      # including why 0.55 and steel were rejected *because* they work too well, is on
      # `SteamEngine.flywheel`.
      Parts.register(:light_flywheel, kind: :flywheel, label: "Cast-Iron Flywheel",
                     description: "Light enough to be a hazard when the load comes off.",
                     provides: %i[flywheel],
                     instruments: %i[engine_speed flywheel_stress flywheel_condition],
                     stats: { mass_kg: 3_200.0, radius_m: 1.5, material: :cast_iron,
                              safety_factor: 0.45 }) do |_spec|
        SteamEngine.flywheel_fragment(mass_kg: 3_200.0, radius_m: 1.5, friction: 8.0,
                                      safety_factor: 0.45)
      end

      # A beam engine's wheel is a different object: vastly heavier, larger, and turning far more
      # slowly. It has to be, because a 1.3 m piston working against a vacuum develops something
      # like 160 kN·m.
      #
      # **Keeps `safety_factor: 0.35`, and not only because it was never measured.** Foundry
      # practice in 1776 was not what it was in 1802, so the older engine having the poorer
      # casting is period-apt. It is also irrelevant in normal running — this wheel sits at 0.007
      # of its burst stress — so the figure only decides how far it has to overspeed when the
      # load comes off, and that wants its own measurement rather than the light wheel's.
      Parts.register(:beam_flywheel, kind: :flywheel, label: "Beam Engine Flywheel",
                     description: "Twenty-four tonnes of 1776 casting, turning slowly.",
                     provides: %i[flywheel],
                     instruments: %i[engine_speed flywheel_stress flywheel_condition],
                     stats: { mass_kg: 24_000.0, radius_m: 2.8, material: :cast_iron,
                              safety_factor: 0.35 }) do |_spec|
        SteamEngine.flywheel_fragment(mass_kg: 24_000.0, radius_m: 2.8, friction: 40.0,
                                      safety_factor: 0.35)
      end

      # **Rated for the engine, and the engine got its pressure back.** `max_torque` was 5500
      # when the cylinder's diagram ran on its own held charge — a release-condition pressure at
      # roughly 30% of the boiler's — so the mill was sized against a prime mover throwing away
      # two thirds of its admission pressure. With the diagram reading the supply, full gear at
      # an open regulator burst the flywheel on every run.
      Parts.register(:mill_drive, kind: :load, label: "Mill Drive",
                     description: "A line shaft under fan-law load, rated at 10 rad/s.",
                     provides: %i[load],
                     stats: { curve: :fan, rated_omega: 10.0, max_torque: 14_000.0 }) do |_spec|
        SteamEngine.load_fragment(moment_of_inertia: 400.0, max_torque: 14_000.0,
                                  rated_omega: 10.0)
      end

      # A beam engine turns over slowly — Watt's ran at twenty-odd rpm — so its mill is rated at
      # 2.5 rad/s where Trevithick's is rated at 10.
      Parts.register(:slow_mill_drive, kind: :load, label: "Slow Mill Drive",
                     description: "Geared for a beam engine: huge torque, twenty-odd rpm.",
                     provides: %i[load],
                     stats: { curve: :fan, rated_omega: 2.5, max_torque: 90_000.0 }) do |_spec|
        SteamEngine.load_fragment(moment_of_inertia: 3_000.0, max_torque: 90_000.0,
                                  rated_omega: 2.5)
      end

      # Condensate back to the supply — closing the water loop, exactly the topology a
      # topological resolution order could not have handled. The link that brings the
      # cylinder's exhaust INTO the condenser is the chassis's, not this part's: which way the
      # exhaust goes is the difference between Watt's engine and Trevithick's, and that is a
      # frame decision rather than a fitting. See `SteamEngine::CHASSIS`.
      Parts.register(:stock_condenser, kind: :condenser, label: "Jet Condenser",
                     provides: %i[condenser hotwell], instruments: %i[condenser_vacuum],
                     stats: { volume_m3: 3.0 }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.condenser, SteamEngine.condensate_return ],
          links: [
            Link.new(from: [ :condenser, :drain ], to: [ :hotwell, :inlet ]),
            Link.new(from: [ :hotwell, :outlet ],  to: [ :supply, :in ])
          ]
        )
      end

      # --- slots ---------------------------------------------------------------

      # **Declaration order is the panel's lever order**, because fragments merge in this
      # order and `Operation#panel` maps over the control points as it receives them. A player
      # learns a panel by where things are, so this list is ordered by the cab rather than by
      # the graph: fire, then water, then steam, then the engine itself. Node order falls out
      # of it and is nobody's business — `canonical` sorts by key, so it cannot reach the
      # digest.
      #
      # Everything is `required: true` at this stage. Nothing has been made optional yet, and
      # doing both at once would mean a stage whose acceptance test could not be "the engine is
      # bit-identical". The slots that become optional are marked below.
      def slots(spec)
        # The eight kinds that differ between the two machines. `fetch` throughout, so adding a
        # slot that varies and forgetting to name it on the chassis raises at build rather than
        # silently fitting the wrong part.
        fitted = spec.fetch(:parts)

        base = [
          Slot.new(id: :firebox, accepts: :firebox, label: "Firebox", group: :fire,
                   required: true, default: :stock_firebox),
          Slot.new(id: :stoker, accepts: :stoking_gear, label: "Stoking Line", group: :fire,
                   required: true, default: :stock_stoker),
          # **Optional, and the slowest of the hazards.** Ash is produced by both combustion
          # reactions and consumed by nothing, so a grate with no way to clear its own waste
          # strangles itself over a long game and no lever a player can reach will help.
          # `:omit` rather than `:bypass`: there is no run to preserve, the waste simply stays.
          Slot.new(id: :ash_pan, accepts: :ash_handling, label: "Ashpan", group: :fire,
                   required: false, default: :stock_ash_pan, when_empty: :omit),
          Slot.new(id: :damper, accepts: :damper, label: "Damper", group: :fire,
                   required: true, default: fitted.fetch(:damper)),
          # Immediately after the damper, because slot order is the panel's lever order and
          # `blower` has always sat next to `damper_open` in the cab.
          #
          # The first `:bypass` slot on this engine: with no fan fitted the atmosphere joins
          # straight to the damper and the fire draws on the stack alone.
          Slot.new(id: :blower, accepts: :forced_draught, label: "Blower", group: :fire,
                   required: false, default: :stock_blower, when_empty: :bypass,
                   bypass: [ [ :atmosphere, :intake ], [ :damper, :inlet ] ]),
          Slot.new(id: :bunker, accepts: :bunker, label: "Fuel Bunker", group: :fire,
                   required: true, default: :stock_bunker),
          # **Optional, `:bypass`, and it is the biggest single upgrade on the engine.** Without
          # the bundle the flue gas goes straight from the firebox to the chimney and the only
          # fire→water path left is the radiant one — which is a plain shell boiler, a perfectly
          # real machine and the thing tubes were invented to replace.
          #
          # The cost is already measured and it is enormous. From the table on
          # `SteamEngine.boiler_tubes`: radiant only puts the firebox at 676 K and sends **90% of
          # the fuel up the chimney** for 41 kW of shaft work, against 895 K and 47.3 kW with
          # tubes fitted — and that comparison was made at a radiant conductance tuned *for*
          # the tubeless case. This is the part that makes a boiler worth the name.
          #
          # The thermal link to the drum leaves with it, because it is in the part's fragment.
          Slot.new(id: :boiler_tubes, accepts: :boiler_tubes, label: "Boiler Tubes", group: :water,
                   required: false, default: :stock_boiler_tubes, when_empty: :bypass,
                   bypass: [ [ :firebox, :flue_out ], [ :flue, :inlet ] ]),
          Slot.new(id: :chimney, accepts: :chimney, label: "Chimney", group: :fire,
                   required: true, default: fitted.fetch(:chimney)),
          Slot.new(id: :water_supply, accepts: :water_supply, label: "Water Supply", group: :water,
                   required: true, default: :stock_water_supply),
          Slot.new(id: :feedwater, accepts: :feedwater, label: "Feedwater", group: :water,
                   required: true, default: :stock_injector),
          Slot.new(id: :boiler, accepts: :boiler, label: "Boiler", group: :water,
                   required: true, default: fitted.fetch(:boiler)),
          Slot.new(id: :regulator, accepts: :regulator, label: "Regulator", group: :steam,
                   required: true, default: :stock_regulator),
          Slot.new(id: :steam_chest, accepts: :steam_chest, label: "Steam Chest", group: :steam,
                   required: true, default: :stock_steam_chest),
          Slot.new(id: :cylinder, accepts: :cylinder, label: "Cylinder", group: :engine,
                   required: true, default: fitted.fetch(:cylinder)),
          # **The safety tier, and the whole risk/reward axis of the progression.** None of
          # these adds power and two of them cost some, so going without is a real choice rather
          # than a strictly-worse one — and the hazard each stands in front of is already built
          # and already measured, which is what makes the choice mean anything.
          #
          # All `:omit`: a fitting that is not there passes nothing, and the boss it screws into
          # is simply blanked off. There is no run to preserve in any of them.
          Slot.new(id: :drain_cocks, accepts: :drain_cocks, label: "Cylinder Cocks", group: :engine,
                   required: false, default: :stock_drain_cocks, when_empty: :omit),
          Slot.new(id: :safety_valve, accepts: :safety_valve, label: "Safety Valve", group: :water,
                   required: false, default: fitted.fetch(:safety_valve), when_empty: :omit),
          Slot.new(id: :fusible_plug, accepts: :fusible_plug, label: "Fusible Plug", group: :water,
                   required: false, default: :stock_fusible_plug, when_empty: :omit),
          Slot.new(id: :cylinder_relief, accepts: :cylinder_relief,
                   label: "Cylinder Relief Valve", group: :engine,
                   required: false, default: fitted.fetch(:cylinder_relief), when_empty: :omit),
          Slot.new(id: :flywheel, accepts: :flywheel, label: "Flywheel", group: :engine,
                   required: true, default: fitted.fetch(:flywheel)),
          Slot.new(id: :load, accepts: :load, label: "Mill Drive", group: :engine,
                   required: true, default: fitted.fetch(:load))
        ]

        return base unless spec.fetch(:condenser)

        # Required on this chassis and absent from the other, which is the honest way to say
        # it: a Watt engine without its condenser is not a Watt engine with a part missing, it
        # is an engine whose exhaust has nowhere to go.
        base + [ Slot.new(id: :condenser, accepts: :condenser, label: "Condenser", group: :engine,
                          required: true, default: :stock_condenser) ]
      end

      # --- the chassis's own contribution ---------------------------------------

      # The world, and the one link that decides which engine this is.
      #
      # `cylinder.exhaust` going up the chimney rather than into a condenser is not a fitting —
      # it is the frame. Watt's engine works by making a vacuum and letting the sky push the
      # piston; Trevithick threw the condenser away and pushed with boiler pressure instead.
      # A slot cannot express "absent means rerouted" without becoming a chassis, so this stays
      # here. See `docs/design_sketches/modular_components.md` §6.
      def fixtures(spec)
        exhaust =
          if spec.fetch(:condenser)
            Link.new(from: [ :cylinder, :exhaust ], to: [ :condenser, :in ])
          else
            # Up the chimney, not out to the sky. This is the one link that makes the engine
            # self-draughting — see the blastpipe note on `flue`.
            Link.new(from: [ :cylinder, :exhaust ], to: [ :flue, :inlet ])
          end

        Fragment.new(nodes: [ Nodes::Atmosphere.new ], links: [ exhaust ])
      end

      # --- what makes a build functional ----------------------------------------

      # Four routes, and between them they are what "this engine can run at all" means. Checked
      # against the REAL router — the resolved `Path` list — rather than a second model of the
      # graph, so they cannot drift from how material actually moves.
      #
      # Note these are about *reachability*, not about wisdom. A build with no safety valve
      # satisfies every one of them and is a perfectly legal thing to take out onto a shift.
      ROUTES = [
        { from: :bunker, to: :firebox, carrying: :fuel,
          as: "no route for coal to reach the grate" },
        { from: :atmosphere, to: :firebox, carrying: :gas,
          as: "no route for air to reach the fire" },
        { from: :firebox, to: :atmosphere, carrying: :gas,
          as: "the fire has no way to breathe out — nothing carries the flue gas away" },
        { from: :supply, to: :boiler, carrying: :liquid,
          as: "no route for feedwater to reach the boiler" },
        { from: :boiler, to: :cylinder, carrying: :gas,
          as: "no route for steam to reach the cylinder" }
      ].freeze

      # Legal, assembles, passes every route — and probably lethal. These never block a build.
      # The copy is game design rather than error handling: it is the only warning a player
      # gets before finding out the hard way, so it says what will happen, not what is missing.
      ADVISORIES = [
        { slot: :safety_valve,
          says: "No safety valve. Nothing bleeds this boiler off — the shell holds until it " \
                "doesn't, and you will have no warning but the gauge." },
        { slot: :fusible_plug,
          says: "No fusible plug. Run the water down past the crown sheet and there is " \
                "nothing between you and the plate letting go." },
        { slot: :cylinder_relief,
          says: "No cylinder relief valve. A slug of water reaching the piston has nowhere " \
                "to go, and the cylinder end will be what gives." },
        { slot: :ash_pan,
          says: "No ashpan. The fire's own waste will bank up under the grate and choke it, " \
                "and no lever you can reach will help." },
        { slot: :drain_cocks,
          says: "No cylinder cocks. A cold cylinder fills with its own condensate and a " \
                "standing one has no way to sweep it out — warming this engine through is " \
                "going to be a nervous business." },
        # The two that are not safety devices. Both are about work you will not be able to do
        # rather than damage you will take, and the blower's is the only advisory here about
        # something you find out before you get going rather than after.
        { slot: :blower,
          says: "No blower. A cold stack has no draught, so this fire has to be coaxed " \
                "alight on buoyancy alone — and it may not go at all." },
        { slot: :boiler_tubes,
          says: "No boiler tubes. The fire heats the water through the shell alone and most " \
                "of your coal goes up the chimney — this is a plain shell boiler, and it " \
                "will feel like one." }
      ].freeze
    end
  end
end
