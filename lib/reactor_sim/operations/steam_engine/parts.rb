# frozen_string_literal: true

module ReactorSim
  module Operations
    module SteamEngine
      # The engine, as components. Each `Parts.register` wraps one of `definition.rb`'s node
      # builders and adds the wiring that comes with it, so removing a part is a matter of not
      # fitting it rather than editing four lists across two files.
      #
      # `provides:` is the id contract: the id belongs to the ROLE, not the part. Every boiler
      # names its drum `:boiler`, so the wiring around it, the gauges pointed at it and its rng
      # stream all survive a swap. See `docs/design_sketches/modular_components.md`.
      module_function

      # --- shared shapes ---------------------------------------------------------
      #
      # **Where two parts of one kind differ only in numbers, the wiring is written once.** Eight
      # kinds have a high-pressure and an atmospheric variant differing in a handful of figures,
      # never in links or levers. The numbers, and the sweeps that chose them, sit on the
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

      def boiler_fragment(shell_radius_m:, wall_thickness_m:, working_pressure_pa:)
        Fragment.new(
          # **The drum ships its own hole.** A boiler you can fit is a boiler that can burst, so
          # the breach belongs to this fragment rather than to the chassis — fit a different
          # drum and you get that drum's way of failing, fit none and there is nothing to
          # rupture. It is shut and costs nothing until the shell fails; see `Nodes::Breach`.
          nodes: [ SteamEngine.boiler(shell_radius_m: shell_radius_m,
                                      wall_thickness_m: wall_thickness_m,
                                      working_pressure_pa: working_pressure_pa),
                   SteamEngine.boiler_breach ],
          links: [
            Link.new(from: [ :boiler, :breach_out ],   to: [ :boiler_breach, :inlet ]),
            # `:spill`, not `:exhaust`. Both end in the sky; only one of them was meant to, and
            # booking them together would make every efficiency figure built on the ledger a
            # lie. See `Nodes::Atmosphere`.
            Link.new(from: [ :boiler_breach, :outlet ], to: [ :atmosphere, :spill ])
          ],
          # **The firebox glowing straight at the water legs, and it genuinely glows now.** This
          # was a flat 3500 W/K, which could not say the thing every fireman knows: a *bright*
          # fire is worth far more than a merely hot one. The radiant term goes as T⁴, so the
          # draught and the damper now change how much heat reaches the water rather than only
          # how much fuel is burnt.
          #
          # **The split is calibrated against the total, not chosen freely.** At the working
          # point — fire ~1020 K, water ~430 K — 24 m² at ε 0.9 gives about 2180 W/K of
          # radiation, and the 1100 W/K left over is convection: flue gas does touch the legs on
          # its way to the tubes, and that part is linear. The sum is ~3280 W/K, which is where
          # the flat figure sat, so the release changes the *shape* of the path rather than its
          # size. Radiation is two thirds of it, which is a firebox.
          #
          # Get that sum wrong and nothing announces it: an under-strength path makes the fire
          # run HOTTER, because the heat cannot leave it, and the reading that looks like a
          # better fire is the bottleneck.
          #
          # The other half of the fire→water path is the tube bundle, which arrives with
          # `:stock_boiler_tubes` — the split matters more than either number.
          thermal_links: [ ThermalLink.new(a: :firebox, b: :boiler, conductance: 1_100.0,
                                           emissivity: 0.9, radiating_area_m2: 24.0) ]
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

      # **The rings come with the barrel**, because their geometry *is* the barrel's — a ring's
      # rubbing speed is that cylinder's stroke and its gas load acts over that cylinder's bore.
      # A separate slot would let a player fit rings from a machine twice the size.
      #
      # Load area is the rings' back face: bore circumference × total ring height, not the
      # piston's own face, which is four times larger and would be a different mechanism.
      def ring_load_area_m2(bore_m) = Math::PI * bore_m * 0.085

      def cylinder_fragment(spec, bore_m:, stroke_m:, heat_capacity:)
        Fragment.new(
          # The barrel ships its own hole, the way the drum does: fit a cylinder and you get
          # that cylinder's way of coming apart. Shut and free until the head lets go.
          nodes: [ SteamEngine.cylinder(spec, bore_m: bore_m, stroke_m: stroke_m,
                                              heat_capacity: heat_capacity),
                   SteamEngine.piston_rings(stroke_m: stroke_m, material: :bronze,
                                            load_area_m2: ring_load_area_m2(bore_m),
                                            mass_kg: 60.0, content: Content.default,
                                            static_load_n: 2_400.0, film_speed_m_s: 2.2,
                                            viscous_c: 6.0, oil_charge_kg: 0.8,
                                            # Rings sit inside a tonne of iron casting, which is
                                            # a far better heat path than a bearing housing in
                                            # open air — so they run hot but not dangerously so.
                                            ambient_conductance: 260.0,
                                            stress_rate: 45.0,
                                            # **Rings are the consumable, and this is the number
                                            # that says so.** 76 kW of boundary rubbing at the
                                            # reference setting puts a set at roughly 5 hours of
                                            # running, 4.1 flat out — several sessions, not one.
                                            wear_rate: 7.3e-7,
                                            # Rings rub twice a revolution over a long stroke, so
                                            # they drink faster than a journal does.
                                            oil_loss_kg_per_m: 1.4e-4,
                                            # **The route to a worn bore that is not hydraulic
                                            # lock.** Rings that have wiped no longer seal, and
                                            # what they score on the way is the barrel.
                                            damages: { wiped: { cylinder: 0.35 },
                                                       seized: { cylinder: 0.6 } }),
                   SteamEngine.cylinder_breach ],
          links: [
            Link.new(from: [ :cylinder, :breach_out ],    to: [ :cylinder_breach, :inlet ]),
            Link.new(from: [ :cylinder_breach, :outlet ], to: [ :atmosphere, :spill ])
          ],
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
          # **A belt drive loses single-digit percent, and `stiffness` is what says so.** At
          # steady state a viscous coupling dissipates exactly `Δω / ω_driver` of what crosses
          # it, so the slip fraction *is* the loss fraction and the number follows from a target:
          # `k ≥ torque / (slip × ω)`. At 9 000 this ran 22% slip and burned a fifth of the
          # engine — measured only once the load stopped being slammed to a standstill every
          # tick, which was hiding it. See `docs/design_sketches/bearings.md` §1.1.
          drive_links: [ DriveLink.new(a: :flywheel, b: :load, stiffness: 150_000.0) ]
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

      # **A well-oiled journal is very efficient, and that is not a bug in the numbers.** These
      # carry well under a percent of shaft power flooded — real plain bearings run a friction
      # coefficient of 0.001–0.005 on a full film — and the engine's mechanical loss lives mostly
      # in the piston and gland instead. What makes them matter is the *other* end of the
      # Stribeck curve: starved, the same journal is forty times worse and cooks itself in
      # minutes. Measured on the reference run: 38 K above ambient wet, and past babbitt's 520 K
      # rating dry.
      #
      # 45 kg is the whole assembly's effective thermal mass, not the white metal alone — the
      # brasses, their caps and the length of shaft between them all soak the heat.
      def journal_fragment(mass_kg:, material:, **rest)
        Fragment.new(
          nodes: [ SteamEngine.main_bearings(mass_kg: mass_kg, material: material,
                                             content: Content.default, **rest) ]
        )
      end

      # **Harder, hotter, and it takes the shaft with it.** Bronze runs to a 560 K service limit
      # against babbitt's 416, so it shrugs off neglect that would wipe white metal — and it
      # declares no latent heat, so it does not melt out and give the housing back.
      #
      # That is not a free upgrade, and `failure_damages` is where the price is. **Babbitt is
      # sacrificial on purpose**: it is the soft thing that goes so the journal does not. Bronze
      # is harder than the shaft is forgiving, so when it does seize it scores the crank rather
      # than running out of the housing — the cylinder *and* the flywheel pay.
      Parts.register(:bronze_journals, kind: :bearings, label: "Bronze Journals",
                     description: "Solid bronze shells. They will take abuse white metal " \
                                  "will not, and they are less kind when they finally go.",
                     provides: %i[main_bearings],
                     instruments: %i[bearing_temp bearing_condition],
                     stats: { material: :bronze, mass_kg: 52.0 }) do |_spec|
        SteamEngine.journal_fragment(
          mass_kg: 52.0, material: :bronze, stress_rate: 120.0, wear_rate: 4.0e-7,
          oil_loss_kg_per_m: 2.0e-4,
          damages: { seized: { cylinder: 0.5, flywheel: 0.4 } },
          endangers: { seized: { tags: %i[burn crush], scales_with: :rim_speed_m_s,
                                 reference: 27.0, stations: { oiling: 1.0 } } }
        )
      end

      # **The late unlock, and it is an upgrade — which is fine.** Progression is gated and an
      # earned upgrade is allowed to be better; what it is not allowed to be is *free of
      # character*. See `docs/design_sketches/bearings.md` §4.5.
      #
      # Three things make it a different part rather than a better number:
      #
      #   * **It does not care about oil.** Flat friction across the Stribeck curve — that is what
      #     `mu_film:`/`mu_boundary:` exist for — so no oil charge, no consumption, and the oil
      #     round stops being about the journals at all.
      #   * **It barely wears.** Rolling contact, so `wear_rate` is an order down on a plain
      #     bearing's and `stress_rate` is nearly nothing.
      #   * **It gives no warning.** A plain bearing telegraphs distress for minutes and can be
      #     caught; a roller reads sound right up until a race spalls. Here that falls out rather
      #     than being asserted: durability barely moves, so `bearing_condition` says "cold and
      #     quiet" — and the failure route is `overload?` on temperature, which arrives without
      #     the gauge ever having drifted.
      Parts.register(:roller_bearings, kind: :bearings, label: "Roller Bearings",
                     description: "Sealed races, packed with grease at the works. Nothing to " \
                                  "oil, and nothing to hear before they let go.",
                     provides: %i[main_bearings],
                     instruments: %i[bearing_temp bearing_condition],
                     stats: { material: :steel, mass_kg: 38.0 }) do |_spec|
        SteamEngine.journal_fragment(
          mass_kg: 38.0, material: :steel,
          mu_film: 0.0015, mu_boundary: 0.002,
          oil_charge_kg: 0.0, oil_loss_kg_per_m: 0.0,
          viscous_c: 1.2, stress_rate: 25.0, wear_rate: 6.0e-8,
          damages: { seized: { cylinder: 0.5, flywheel: 0.5 } },
          endangers: { seized: { tags: %i[burn crush], scales_with: :rim_speed_m_s,
                                 reference: 27.0, stations: { oiling: 1.0 } } }
        )
      end

      # **Where the oil is kept, which is not the same question as how it reaches the bearings.**
      # This part is the store; the lubrication method that draws on it is what differs between a
      # man with a can, a ring oiler and a forced feed. Separating them is what lets the method be
      # upgraded without buying a new drum. See `docs/design_sketches/bearings.md` §1.5.
      Parts.register(:babbitt_journals, kind: :bearings, label: "Babbitt Journals",
                     description: "White metal poured into bronze shells. Soft, and meant to be.",
                     provides: %i[main_bearings],
                     instruments: %i[bearing_temp bearing_condition],
                     stats: { material: :babbitt, mass_kg: 45.0 }) do |_spec|
        # **Rated so that a starved journal wipes before it melts.** A bearing losing its oil
        # takes about 158 s to climb from running temperature to babbitt's 520 K, so the fatigue
        # path has to finish inside that or the warning rung never happens.
        #
        # A seizure takes the cylinder half way to its own failure: the rod keeps driving into a
        # crank that has stopped turning, and that load goes somewhere.
        SteamEngine.journal_fragment(
          mass_kg: 45.0, material: :babbitt, stress_rate: 200.0,
          # Same coefficient as the rings, and the **4 kW of boundary rubbing** a flooded journal
          # sees does the rest: 95 hours against the rings' 5. A well-oiled journal is not a
          # consumable, and it is the oil that makes that true rather than the metal.
          wear_rate: 7.3e-7,
          # **The white metal only**, against 45 kg of assembly thermal mass. This is what a
          # re-babbitting job replaces, and what runs out of the housing when one cooks.
          lining_kg: 6.0,
          oil_loss_kg_per_m: 2.0e-4,
          damages: { seized: { cylinder: 0.5 } },
          # Whoever is at the crank with a can when it goes. Tags rather than a severity, so
          # protective kit resolves through `Injury#resistance` by naming convention with no
          # engine change; `scales_with:` reads the rim speed off the failure event, because a
          # seizure at 170 rpm is not one at walking pace.
          # 27 m/s is the reference rim speed — a 1.5 m flywheel at its working 18 rad/s — so a
          # seizure at ordinary running scales to 1.0 and one on a barred-over engine to almost
          # nothing.
          endangers: { seized: { tags: %i[burn crush], scales_with: :rim_speed_m_s,
                                 reference: 27.0, stations: { oiling: 1.0 } } }
        )
      end

      Parts.register(:stock_oil_store, kind: :oil_store, label: "Oil Store",
                     description: "A drum of straight mineral oil and a filler funnel.",
                     provides: %i[oil_store], instruments: %i[oil_remaining],
                     stats: { volume_m3: 0.3, bearing_oil_kg: 180.0 }) do |_spec|
        Fragment.new(nodes: [ SteamEngine.oil_store ])
      end

      # **A man with an oil can, and the cheapest lubrication there is.** One lever, two lines:
      # an oiler walks the machine and does the journals and the gland on the same round.
      #
      # **Dexterity-led rather than strength-led**, which makes it the first station in the game
      # that is not a strength check — oiling is fiddly and attentive, not heavy. The
      # `intelligence` share is deliberate: the stat is defined and read by nothing else, and
      # knowing which bearing wants attention is exactly what it should mean.
      #
      # The mechanic needs no new engine concept. There is no discrete-action or cooldown
      # machinery in the simulation and this wants none: the fireman has to **leave the shovel**
      # to come and oil, which is an `assign_minion` command that already works, and the fire
      # dies while he is away. That is the whole decision.
      Parts.register(:hand_oiling, kind: :lubrication, label: "Hand Oiling",
                     description: "An oil can, a long spout, and somebody to walk the machine.",
                     provides: %i[oil_feed_journals oil_feed_rings],
                     stats: { max_kg_per_s: 0.06 }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.oil_line(id: :oil_feed_journals),
                   SteamEngine.oil_line(id: :oil_feed_rings) ],
          links: [
            Link.new(from: [ :oil_store, :out ],            to: [ :oil_feed_journals, :inlet ]),
            Link.new(from: [ :oil_feed_journals, :outlet ], to: [ :main_bearings, :oil_in ]),
            Link.new(from: [ :oil_store, :out ],            to: [ :oil_feed_rings, :inlet ]),
            Link.new(from: [ :oil_feed_rings, :outlet ],    to: [ :piston_rings, :oil_in ])
          ],
          control_points: [
            # Fiddly and attentive rather than heavy, so the lightest `exertion:` on the engine —
            # a quarter hour at it flat out, against the stoker's five minutes. The oil round is a
            # job you can be sent back to.
            ControlPoint.new(id: :oiling, label: "Oil Round", node: :oil_feed_journals,
                             effort: { dexterity: 0.6, intelligence: 0.4 },
                             aided_by: :oiling, exertion: 3.7e-4)
          ]
        )
      end

      # --- crew quarters --------------------------------------------------------------------
      #
      # **Where the shift begins, and the only part that is not machinery.** It answers two
      # questions no other fitting can: how many hands the operation can field, and where they
      # are standing when the match starts.
      #
      # **It builds no node, and that is right rather than a shortcut.** A mess room holds
      # nothing, conducts nothing and is driven by nothing — it is a *place*, and a place in this
      # model is a `ControlPoint` somebody can be posted to. `station_index`, `endangers:` and
      # fatigue all resolve through control points already, so a station with no `node:` needs no
      # new machinery anywhere. `ControlPoint#lever?` is what keeps it off the lever strip.
      #
      # > **Not `provides: %i[quarters]`.** `provides:` names NODE ids a part must build, and
      # > node, lever, instrument and minion ids share one flat namespace — so declaring a node
      # > and a control point both called `:quarters` is a duplicate-id build error.
      #
      # `recovery:` is the seam the fatigue release left: an ordinary valve recovers at
      # `Fatigue::BASE_RECOVERY`, and better amenities are a larger number in the same field.
      # At 2× base a spent worker is back on their feet in ~230 s against ~455 s at a valve.
      Parts.register(:mess_room, kind: :crew_quarters, label: "Mess Room",
                     description: "A bench, a kettle on the plate, and room for two off the " \
                                  "footplate.",
                     stats: { crew_capacity: 2, recovery_rate: 2.0 }) do |_spec|
        Fragment.new(
          control_points: [
            ControlPoint.new(id: :quarters, label: "Crew Quarters",
                             recovery: Fatigue::BASE_RECOVERY * 2.0)
          ]
        )
      end

      # **The upgrade that buys back a person, which is the only currency the oil round spends.**
      # A ring rides on the shaft and lifts oil out of a sump as it turns, so the machine oils
      # itself while it is running — the lever stops being an effort station and becomes a valve
      # on the sump feed.
      #
      # **That is the whole tradeoff, and it has a real edge**: a ring oiler works because the
      # shaft is turning. It delivers nothing on a barred-over or stalling engine, which is
      # exactly when a journal is most at risk, and it cannot be hurried when one is already hot.
      # A man with a can can oil a stopped engine; this cannot.
      Parts.register(:ring_oiler, kind: :lubrication, label: "Ring Oilers",
                     description: "Loose rings riding each journal, lifting oil from a sump as " \
                                  "the shaft turns. Nobody has to stand there.",
                     provides: %i[oil_feed_journals oil_feed_rings],
                     stats: { max_kg_per_s: 0.03 }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.oil_line(id: :oil_feed_journals, max_kg_per_s: 0.03),
                   SteamEngine.oil_line(id: :oil_feed_rings, max_kg_per_s: 0.03) ],
          links: [
            Link.new(from: [ :oil_store, :out ],            to: [ :oil_feed_journals, :inlet ]),
            Link.new(from: [ :oil_feed_journals, :outlet ], to: [ :main_bearings, :oil_in ]),
            Link.new(from: [ :oil_store, :out ],            to: [ :oil_feed_rings, :inlet ]),
            Link.new(from: [ :oil_feed_rings, :outlet ],    to: [ :piston_rings, :oil_in ])
          ],
          # **No `effort:`, and that is the upgrade.** The lever is now a valve on the sump feed
          # rather than somebody's exertion, so it delivers whether or not anybody is standing
          # there — and defaults open, because a ring oiler that has to be switched on is a hand
          # oiler with extra steps.
          control_points: [
            ControlPoint.new(id: :oiling, label: "Oil Feed", node: :oil_feed_journals,
                             default: 100.0)
          ]
        )
      end

      Parts.register(:stock_stoker, kind: :stoking_gear, label: "Stoking Line",
                     provides: %i[stoker], stats: { max_kg_per_s: 0.25 }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.stoker ],
          links: [
            Link.new(from: [ :bunker, :out ],    to: [ :stoker, :inlet ]),
            Link.new(from: [ :stoker, :outlet ], to: [ :firebox, :fuel_in ])
          ],
          # **Effort, not a valve**, and the lever here is an instruction rather than a setting:
          # "fire her as hard as you can" gets you whatever the person at the firehole can
          # actually shift. Mostly back, a little placement — a shovelful has to go to the right
          # part of the grate, which is why dexterity is in the blend at all.
          #
          # `SteamEngine.stoker`'s 0.25 kg/s is therefore **what a competent human manages**, not
          # a mechanical limit: a day-labourer moves a third of it and a strong fireman with a
          # shovel roughly double.
          # **The heaviest station on the engine: about five minutes flat out.** `exertion:` is
          # fatigue per second for a competent hand with the lever hard over — and the figure that
          # matters is `1/(3 × exertion)`, not `1/exertion`, because the runaway divides
          # time-to-spent by three (`Fatigue::LOAD_CEILING`). So 1.1e-3 is ~300 simulated seconds
          # at `dt` 0.25 s. At a third of the lever the same person lasts most of an hour, which
          # is what makes firing rate a decision rather than a setting.
          control_points: [ ControlPoint.new(id: :stoking, label: "Stoking Effort", node: :stoker,
                                             effort: { strength: 0.75, dexterity: 0.25 },
                                             aided_by: :shovelling, exertion: 1.1e-3) ]
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
            # Effort, like the stoker and for the same reason — its own comment on
            # `SteamEngine.ash_pan` already called it "somebody's effort with a shovel". More
            # awkward than firing, hence the heavier dexterity share: an ashpan is raked out
            # bent double under a locomotive rather than swung at from standing.
            ControlPoint.new(id: :ash_raking, label: "Rake the Ashpan", node: :ash_pan,
                             effort: { strength: 0.6, dexterity: 0.4 },
                             aided_by: :shovelling, exertion: 9.3e-4)
          ]
        )
      end

      # **0.35 sits at the knee of the draught curve.** Measured at full controls, blower OFF,
      # sweeping this number alone:
      #
      #     k     0.20   0.25   0.30   0.35   0.40   0.50   0.60
      #     kW   335.1  432.2  476.6  493.3  491.3  497.4  499.0
      #     fire   986   1000   1002   1001    999    993    988   K
      #                                  ^ here: the knee, and the hottest fire
      #
      # What the blower is worth, by conductance: **+152.7 kW at 0.2, +16.4 at 0.3, +2.9 at 0.4,
      # −2.4 at 0.5** — past the knee it over-draughts and cools the fire. **Sizing the damper
      # properly is what stops the blower being an exploit**: undersized, the blower's 600 Pa of
      # head silently makes up the difference and is worth a free 45% on demand. A blower is for
      # raising first steam on a cold stack, and should be inert once the fire draws for itself.
      #
      # 0.35 rather than 0.4+ because above the knee the engine burns more fuel for no more work
      # and starts feathering its safety valve: 0.4 burns 3.4% more coal for 0.4% *less* power.
      Parts.register(:wide_damper, kind: :damper, label: "Wide Damper",
                     description: "Sized at the knee of the draught curve.",
                     provides: %i[damper], instruments: %i[air_supply],
                     stats: { conductance: 0.35 }) do |_spec|
        SteamEngine.damper_fragment(conductance: 0.35)
      end

      # **A smaller fire than Trevithick's, and its conductance is the only thing making it
      # smaller.** Period-correct, and as much as this chassis's condenser can swallow: fed the
      # high-pressure draught it makes more steam than the condenser can lay down and the vacuum
      # collapses. Not swept — it has its own condenser balance and wants its own measurement.
      Parts.register(:narrow_damper, kind: :damper, label: "Narrow Damper",
                     description: "Restricted, to suit a condenser that cannot swallow more.",
                     provides: %i[damper], instruments: %i[air_supply],
                     stats: { conductance: 0.1 }) do |_spec|
        SteamEngine.damper_fragment(conductance: 0.1)
      end

      # `when_empty: :bypass` rather than `:omit`, because the air still has to get in: without a
      # fan the atmosphere connects straight to the damper and the fire draws on stack buoyancy
      # alone. That is a real machine and a real decision — a cold stack has no buoyancy, so an
      # engine built without a blower cannot raise its own first steam. No extra power, and you
      # notice its absence at the worst moment.
      #
      # **A minion on the handles, and the starting blower.** Measured against the engine: at
      # 120 Pa full lever it moves about 0.93 kg/s of air against natural draught's 0.30, which
      # raises steam at t=3800 where the donkey does it at t=1600. Slow is the intent — raising
      # steam by hand should be slow, and buying the donkey is the way out of it.
      #
      # **It costs a person the whole time**, which is the point: three effort stations against
      # two seats, so somebody on the bellows is somebody not on the shovel exactly when both
      # matter most. `exertion:` is heavy — the top of this lever is a sprint, priced by the
      # fatigue release, and a hand held there is spent in about four minutes.
      Parts.register(:hand_bellows, kind: :forced_draught, label: "Hand Bellows",
                     description: "Leather and ash, worked by somebody who would rather be " \
                                  "shovelling.",
                     provides: %i[blower_fan],
                     stats: { head_pa: 120.0, crew: "one, continuously" }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.blower_fan(head_pa: 120.0) ],
          links: [
            Link.new(from: [ :atmosphere, :intake ], to: [ :blower_fan, :inlet ]),
            Link.new(from: [ :blower_fan, :outlet ], to: [ :damper, :inlet ])
          ],
          control_points: [
            ControlPoint.new(id: :blower, label: "Bellows", node: :blower_fan,
                             effort: { strength: 0.8, toughness: 0.2 },
                             exertion: 1.4e-3)
          ]
        )
      end

      # **The upgrade, and deliberately today's figures exactly.** 600 Pa and the same rating, so
      # a player who has bought it gets the machine every existing balance measurement was taken
      # against — the cold-start gradient, the sweeps in `bearings.md` §6.3, all of it. The Hand
      # Bellows is a new and harder starting condition rather than a rebalancing of the old one.
      #
      # It costs fuel instead of a person: its own tank, its own two-stroke, and a fan belted to
      # it through `driven_by:`. Running out is the failure, and it is one a player can watch
      # coming on the gauge.
      Parts.register(:donkey_blower, kind: :forced_draught, label: "Donkey Blower",
                     description: "A little oil engine on its own bedplate, belted to the fan.",
                     provides: %i[blower_fan donkey donkey_tank],
                     stats: { head_pa: 600.0, fuel: "fuel oil, 60 kg" }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.blower_fan(head_pa: 600.0, driven_by: :donkey),
                   SteamEngine.donkey_engine, SteamEngine.donkey_tank,
                   SteamEngine.donkey_fuel_line, SteamEngine.donkey_air_line,
                   SteamEngine.donkey_flue ],
          links: [
            Link.new(from: [ :atmosphere, :intake ],   to: [ :blower_fan, :inlet ]),
            Link.new(from: [ :blower_fan, :outlet ],   to: [ :damper, :inlet ]),
            Link.new(from: [ :donkey_tank, :out ],     to: [ :donkey_fuel, :inlet ]),
            Link.new(from: [ :donkey_fuel, :outlet ],  to: [ :donkey, :fuel ]),
            Link.new(from: [ :atmosphere, :intake ],   to: [ :donkey_air, :inlet ]),
            Link.new(from: [ :donkey_air, :outlet ],   to: [ :donkey, :air ]),
            Link.new(from: [ :donkey, :exhaust ],      to: [ :donkey_flue, :inlet ]),
            Link.new(from: [ :donkey_flue, :outlet ],  to: [ :atmosphere, :exhaust ])
          ],
          control_points: [
            ControlPoint.new(id: :blower, label: "Donkey Throttle", node: :donkey)
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

      # **The blastpipe is part of the chimney, not a part of its own**, on two counts.
      # *Physically*, a blastpipe and the stack above it are one assembly whose proportions were
      # tuned together; a nozzle without the stack it points up is not a thing. *Mechanically*,
      # the blast head has to reach BOTH paths through the chimney — the draught path from the
      # firebox and the cylinder's exhaust — which works because the flue sits on both. A
      # separate node between the tubes and the flue would sit on the draught path only, and one
      # placed to catch both would have to own the chassis's exhaust link.
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
                     # **Neither `boiler_pressure` nor `boiler_water` here.** Both dials are
                     # their own fittings now (`:boiler_gauge`, `:water_glass`), and a boiler
                     # that still claimed one collided with the gauge that supplies it — the
                     # id-collision check earning its keep twice, once per gauge that moved out.
                     # The crown sheet stays: nobody fits a crown sheet, it *is* the drum.
                     instruments: %i[crown_sheet],
                     stats: { volume_m3: 5.0, shell_radius_m: 0.6, wall_thickness_m: 0.014,
                              material: :wrought_iron, rated_pressure: "14.39 atm",
                              working_pressure: "5 atm" }) do |_spec|
        SteamEngine.boiler_fragment(shell_radius_m: 0.6, wall_thickness_m: 0.014,
                                    working_pressure_pa: 5.0 * Units::STANDARD_PRESSURE_PA)
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
                     # Both gauges are fittings of their own — see `:locomotive_boiler` above.
                     instruments: %i[crown_sheet],
                     stats: { volume_m3: 5.0, shell_radius_m: 0.75, wall_thickness_m: 0.006,
                              material: :wrought_iron, rated_pressure: "4.93 atm",
                              working_pressure: "1.2 atm" }) do |_spec|
        SteamEngine.boiler_fragment(shell_radius_m: 0.75, wall_thickness_m: 0.006,
                                    working_pressure_pa: 1.2 * Units::STANDARD_PRESSURE_PA)
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

      # **Parts that are instruments rather than machinery.** A gauge's full-scale reading is a
      # property of the gauge — a 0–14 atm dial and a 0–4 atm dial are different objects, chosen
      # to suit the drum — so the dial is a fitting and the number lives on it. They contribute a
      # `Diagnostic` instead of nodes; the definition stays in `panel.rb` and these hold only the
      # figures.
      #
      # **Not required.** An engine with no pressure gauge assembles, runs, and is a frightening
      # way to work — the risk/reward axis the safety devices sit on, applied to information.
      Parts.register(:bourdon_pressure_gauge, kind: :boiler_gauge, label: "Bourdon Gauge",
                     description: "Reads to 14 atm. Two ticks late and ±8 kPa, which is most " \
                                  "of the argument for not running close to the valve.",
                     instruments: [],
                     stats: { full_scale: "14 atm", lag_ticks: 2, noise_kpa: 8 }) do |_spec|
        Fragment.new(diagnostics: [
          SteamEngine.boiler_pressure(full_scale_pa: 14.0 * Units::STANDARD_PRESSURE_PA)
        ])
      end

      # **Scaled for a Watt engine**, which never sees 3 atm — the same dial would spend its life
      # in the first tenth of its travel, and a needle that never moves tells you nothing.
      Parts.register(:low_pressure_gauge, kind: :boiler_gauge, label: "Low-Pressure Gauge",
                     description: "Reads to 4 atm, so the working range fills the dial.",
                     instruments: [],
                     stats: { full_scale: "4 atm", lag_ticks: 2, noise_kpa: 8 }) do |_spec|
        Fragment.new(diagnostics: [
          SteamEngine.boiler_pressure(full_scale_pa: 4.0 * Units::STANDARD_PRESSURE_PA)
        ])
      end

      # **The upgrade, and the shape every instrument upgrade has to take.** One tick of lag
      # instead of two and ±3 kPa instead of ±8 — better, and still late and still wrong.
      #
      # It does not remove either filter, and no instrument blueprint ever may: the panel's
      # imperfection is the game rather than an obstacle in front of it, and a gauge that can be
      # bought into telling the truth has sold the only thing it was protecting. See
      # `SteamEngine.boiler_pressure` for the rule and the three gauges exempt from it entirely.
      Parts.register(:compensated_pressure_gauge, kind: :boiler_gauge,
                     label: "Compensated Gauge",
                     description: "A tick quicker and a good deal steadier. Still late, still " \
                                  "wrong, just less so.",
                     instruments: [],
                     stats: { full_scale: "14 atm", lag_ticks: 1, noise_kpa: 3 }) do |_spec|
        Fragment.new(diagnostics: [
          SteamEngine.boiler_pressure(full_scale_pa: 14.0 * Units::STANDARD_PRESSURE_PA,
                                      lag: 1, noise_pa: 3_000.0)
        ])
      end

      # **The water gauges are the most consequential thing a player can buy.** The crown sheet
      # is what destroys this boiler and the glass is the only warning — a warning already
      # compromised by swell, which lifts the reading exactly when a hard pull is uncovering the
      # plate. Upgrading does not remove that trap, only the noise and delay on top of it.
      #
      # **The tier below the glass is a different instrument, not a worse glass.** Try-cocks are
      # taps at fixed heights: open one and you learn whether steam or water comes out, and
      # nothing between. That is a `Quantize` filter *added* to the usual three, which is the
      # shape a genuine downgrade takes.
      #
      # 10% steps, measured: at 25% the needle never moves across 1400 ticks of a level swinging
      # 44% to 56%, because the whole working band sits inside one step. 10% stays visibly steppy
      # and still lets a trend through — the difference between a bad instrument and none.
      Parts.register(:try_cocks, kind: :water_glass, label: "Try-Cocks",
                     description: "Taps up the backhead. You learn roughly where the water is " \
                                  "and never exactly — and you learn it a moment late.",
                     instruments: [],
                     stats: { reads: "in steps of 10%", lag_ticks: 2, noise: "±2%" }) do |_spec|
        Fragment.new(diagnostics: [
          SteamEngine.boiler_water(label: "Try-Cocks", lag: 2, noise: 0.02, step: 0.1)
        ])
      end

      # **±2.5%, up from ±1.2%, and that is a correction rather than a nerf.** The display reads
      # whole percent, so the old figure was smaller than one unit of what the player can see:
      # the glass was very nearly noise-free, which is not what it was written to be and left
      # nothing for a better glass to improve on. Measured jitter went 0.29 against the reflex
      # glass's 0.26 — a three-fold cut in noise that a player could not have noticed.
      Parts.register(:gauge_glass, kind: :water_glass, label: "Gauge Glass",
                     description: "A plain sight glass. Reads continuously, a tick late, and " \
                                  "trembles enough that you watch it for a while before " \
                                  "believing it.",
                     instruments: [],
                     stats: { reads: "continuous", lag_ticks: 1, noise: "±2.5%" }) do |_spec|
        Fragment.new(diagnostics: [ SteamEngine.boiler_water(noise: 0.025) ])
      end

      # **Less noise, not less lie.** The swell it shows is the real glass's real flaw and no
      # money removes it — see `SteamEngine.boiler_pressure` for the rule this obeys. What a
      # better glass buys is a steadier column you can actually read a trend off, which matters
      # most in the one situation where the trend is the whole story: the level walking down
      # while the needle sits still.
      Parts.register(:reflex_gauge_glass, kind: :water_glass, label: "Reflex Gauge Glass",
                     description: "Prismatic glass: water reads black, steam silver. Steadier " \
                                  "and easier to read at a glance. It still shows the swell.",
                     instruments: [],
                     stats: { reads: "continuous", lag_ticks: 1, noise: "±0.6%" }) do |_spec|
        Fragment.new(diagnostics: [
          SteamEngine.boiler_water(label: "Reflex Glass", noise: 0.006)
        ])
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
                     stats: { material: :fusible_alloy, plug_kg: 0.05 }) do |_spec|
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
          # The regulator ships its own hole, like every other part that can fail — but note
          # **the breach is fed from the BOILER, not from the throttle.** A conduit holds
          # nothing, so a burst pipe has no contents of its own to lose; it has to drain a
          # holder, and naming the drum says the split is on the boiler side of the valve.
          # `senses:` and the inlet link are deliberately different nodes. See `Nodes::Breach`.
          nodes: [ SteamEngine.throttle, SteamEngine.steam_pipe_breach ],
          links: [
            Link.new(from: [ :boiler, :steam_out ], to: [ :throttle, :inlet ]),
            Link.new(from: [ :throttle, :outlet ],  to: [ :steam_chest, :in ]),
            Link.new(from: [ :boiler, :steam_pipe_out ],   to: [ :steam_pipe_breach, :inlet ]),
            Link.new(from: [ :steam_pipe_breach, :outlet ], to: [ :atmosphere, :spill ])
          ],
          control_points: [
            ControlPoint.new(id: :throttle_open, label: "Throttle", node: :throttle)
          ]
        )
      end

      Parts.register(:stock_steam_chest, kind: :steam_chest, label: "Steam Chest",
                     provides: %i[steam_chest], stats: { volume_m3: 1.0 }) do |_spec|
        Fragment.new(
          nodes: [ SteamEngine.steam_chest, SteamEngine.steam_chest_breach ],
          links: [
            Link.new(from: [ :steam_chest, :out ], to: [ :cylinder, :inlet ]),
            Link.new(from: [ :steam_chest, :breach_out ],   to: [ :steam_chest_breach, :inlet ]),
            Link.new(from: [ :steam_chest_breach, :outlet ], to: [ :atmosphere, :spill ])
          ]
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
                     stats: { bore_m: 0.45, stroke_m: 1.1, material: :cast_iron }) do |spec|
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
                     stats: { bore_m: 1.3, stroke_m: 2.4, material: :cast_iron }) do |spec|
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

      # **Declaration order is the panel's lever order**, because fragments merge in this order
      # and `Operation#panel` maps over the control points as it receives them. A player learns a
      # panel by where things are, so this list is ordered by the cab rather than the graph:
      # fire, then water, then steam, then the engine itself. Node order falls out of it and
      # cannot reach the digest, since `canonical` sorts by key.
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
                   required: false, default: :hand_bellows, when_empty: :bypass,
                   bypass: [ [ :atmosphere, :intake ], [ :damper, :inlet ] ]),
          Slot.new(id: :bunker, accepts: :bunker, label: "Fuel Bunker", group: :fire,
                   required: true, default: :stock_bunker),
          # **The biggest single upgrade on the engine.** Without the bundle the flue gas goes
          # straight from firebox to chimney and the only fire→water path is the radiant one,
          # which is a plain shell boiler. Radiant only puts the firebox at 676 K and sends 90%
          # of the fuel up the chimney for 41 kW of shaft work, against 895 K and 47.3 kW with
          # tubes — and that comparison uses a radiant conductance tuned *for* the tubeless case.
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
          # **A gauge is a fitting, not a property of the drum.** Optional, and that is the point:
          # an engine with no pressure gauge assembles and runs perfectly well, and driving one is
          # the same bargain as running without a safety valve — applied to what you can *see*
          # rather than to what can break. `:omit`, because a dial that is not there shows nothing
          # and there is no machinery to bypass.
          Slot.new(id: :boiler_gauge, accepts: :boiler_gauge, label: "Pressure Gauge",
                   group: :water, required: false, default: fitted.fetch(:boiler_gauge),
                   when_empty: :omit),
          # Optional for the same reason, and a worse idea for a better one: this is the reading
          # the crown sheet turns on, so working without it is the sharpest information bargain
          # on the engine.
          Slot.new(id: :water_glass, accepts: :water_glass, label: "Water Gauge",
                   group: :water, required: false, default: fitted.fetch(:water_glass),
                   when_empty: :omit),
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
                   required: true, default: fitted.fetch(:load)),
          # **Required, because an engine with nowhere to keep oil is not a cheaper engine.**
          # Unlike the safety tier, going without buys nothing at all — there is no power in it
          # and no information traded away, so it would be a strictly worse build rather than a
          # decision. What is a decision is how the oil gets from here to the bearings, and that
          # is a separate fitting.
          Slot.new(id: :oil_store, accepts: :oil_store, label: "Oil Store", group: :engine,
                   required: true, default: :stock_oil_store),
          # Required for the same reason the oil store is: a crankshaft with nothing to turn in
          # is not a cheaper engine. What varies is the metal, and later whether it needs oiling
          # at all.
          Slot.new(id: :bearings, accepts: :bearings, label: "Main Bearings", group: :engine,
                   required: true, default: :babbitt_journals),
          # **How the oil gets from the drum to the brasses, which is the decision the store is
          # not.** Required, because an engine whose oil stays in the drum destroys itself — but
          # what is fitted here is the whole ladder from a man with a can to a forced feed, and
          # the cheapest of them costs a person standing at a lever instead of a shovel.
          Slot.new(id: :lubrication, accepts: :lubrication, label: "Lubrication", group: :engine,
                   required: true, default: :hand_oiling),
          # **Required, and it is the one slot that is not part of the machine.** It says how
          # many hands the operation can field and where they begin the shift — so an engine
          # without one has no crew at all, rather than a crew that starts nowhere.
          Slot.new(id: :quarters, accepts: :crew_quarters, label: "Crew Quarters", group: :crew,
                   required: true, default: :mess_room)
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
        # **The one advisory about a hazard the player cannot see rather than cannot stop.**
        # Every other part on this list protects the machine; this one protects the driver's
        # judgement, and going without it is the same bargain applied to information — you keep
        # the engine you had and lose the only honest warning it gave you.
        { slot: :boiler_gauge,
          says: "No pressure gauge. The safety valve is now the first thing that will tell " \
                "you how hard you are pushing her, and by then it is telling everyone." },
        { slot: :water_glass,
          says: "No way to read the water. The crown sheet is what kills a boiler and the " \
                "fusible plug is now your only warning — which is to say, none at all until " \
                "it has already happened." },
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
