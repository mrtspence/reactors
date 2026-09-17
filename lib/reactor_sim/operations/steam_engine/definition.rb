# frozen_string_literal: true

module ReactorSim
  module Operations
    # A stationary steam engine, in two historical flavours built from the same parts.
    #
    #   | | boiler relief | cylinder exhausts to | condenser |
    #   |---|---|---|---|
    #   | **Watt atmospheric** (1776)         | ~1.4 atm | the condenser  | yes |
    #   | **Trevithick high-pressure** (1802) | ~6 atm   | the atmosphere | no  |
    #
    # Watt's engine makes a vacuum and lets the sky push the piston, so the boiler barely needs
    # to be above atmospheric and the condenser is the whole point. Trevithick pushes with boiler
    # pressure instead — lighter, far more powerful, and apt to explode.
    #
    # ## The chain
    #
    #   bunker ─stoker─➤ firebox ◄─damper─ atmosphere        (fuel meets air)
    #   firebox ─tubes─➤ flue ─➤ atmosphere                  (the gas leaves, via the water)
    #                    firebox ═radiant═➤ boiler           (the fire glows at the water legs)
    #               boiler_tubes ═convective═➤ boiler        (the gas scrubs through the tubes)
    #   supply ─feed──➤ injector ─➤ boiler ─throttle─➤ chest ─➤ cylinder   (water → steam → work)
    #                  boiler ─➤ injector                    (live steam does the pumping)
    #                            cylinder ═torque═➤ flywheel ═drive═➤ load
    #
    # Everything after the firebox is the same in both engines; only the exhaust path moves.
    #
    # The **injector** is pumped by live steam that condenses into the feedwater, so filling the
    # boiler and pulling hard draw on the same supply — which is what makes the feed lever a
    # decision. See `docs/design_sketches/injector.md`.
    #
    # The **steam chest** is where the two laws meet: a gradient decides what gets into it,
    # geometry decides what is taken out, and its pressure is the negotiation. Without it a
    # regulator rations mass without setting a pressure, and cannot affect torque.
    #
    # **Two heat paths, not one.** A single conduction link pins the firebox at `T_boiler + Q/k`,
    # making a realistic fire and a well-fed boiler mutually exclusive. The flue gas gets a route
    # past the water — which is what boiler tubes are.
    module SteamEngine
      TYPE = :steam_engine

      # A steam engine is a fast machine, so it wants little or no time compression. At
      # `time_scale` 8 one tick applies two seconds of full torque — enough to take a flywheel
      # from rest past its burst speed before anything can respond.
      DEFAULT_TIME_SCALE = 1.0

      module_function

      # The chassis decides the frame — where the exhaust goes, which slots exist — and the
      # loadout decides what is fitted in them. An empty `loadout:` is the stock engine.
      # See `parts.rb` and `docs/design_sketches/modular_components.md`.
      def build(id:, seed:, chassis: :high_pressure, loadout: {}, crew: {},
                time_scale: DEFAULT_TIME_SCALE, state: nil, rngs: nil, content: nil)
        # A restored snapshot brings these back from JSON as strings.
        chassis = chassis.to_sym
        assembly = assembly_for(chassis, loadout)
        fragment = assembly.build!
        roster = Crew.normalise(crew, roles: crew_roles)

        Operation.new(
          id: id, type: TYPE, seed: seed, time_scale: time_scale,
          state: state, rngs: rngs, content: content,
          # The RESOLVED loadout, naming every slot including the empty ones: a partial loadout
          # is re-defaulted on restore, so a deliberately-empty slot would grow its part back.
          # The roster is here for the same reason — a crew is a loadout by another name.
          options: { chassis: chassis, loadout: assembly.loadout, crew: roster },
          nodes: fragment.nodes, links: fragment.links,
          thermal_links: fragment.thermal_links, drive_links: fragment.drive_links,
          control_points: fragment.control_points,
          diagnostics: assembly.diagnostics,
          minions: crew_for(roster, content || Content.default)
        )
      end

      # The one way to ask what a loadout would build, and all an outfitting screen needs: slots,
      # alternatives and verdict, without building an operation. `build` goes through here too,
      # so the machine a player is shown and the machine they get cannot differ.
      def assembly_for(chassis, loadout = {})
        spec = CHASSIS.fetch(chassis.to_sym) { raise Error, "unknown engine chassis #{chassis.inspect}" }

        Assembly.new(
          slots: slots(spec), loadout: loadout, spec: spec,
          fixtures: fixtures(spec), instruments: catalogue, order: PANEL_ORDER,
          routes: ROUTES, advisories: ADVISORIES
        )
      end

      # A chassis is the frame: fixed topology, and which part fills each slot that differs
      # between the two machines. Numbers belong to the parts that own them, in `parts.rb`.
      CHASSIS = {
        # Low boiler pressure, exhaust into a vacuum. The condenser does the work.
        atmospheric: {
          exhausts_to: :condenser,
          condenser: true,
          # Anything not named here is the same on both machines and keeps its `slots` default.
          # Read with `fetch`, so a varying slot left unnamed raises rather than fitting the
          # wrong part.
          parts: {
            boiler: :beam_boiler,
            boiler_gauge: :low_pressure_gauge,
            # The older frame reads its water with taps rather than a glass.
            water_glass: :try_cocks,
            chimney: :plain_chimney,
            damper: :narrow_damper,
            safety_valve: :low_pressure_safety_valve,
            cylinder: :atmospheric_cylinder,
            cylinder_relief: :low_pressure_cylinder_relief,
            flywheel: :beam_flywheel,
            load: :slow_mill_drive
          }.freeze
        }.freeze,
        # High boiler pressure, exhaust straight to the sky. No condenser at all.
        high_pressure: {
          exhausts_to: :atmosphere,
          condenser: false,
          parts: {
            boiler: :locomotive_boiler,
            boiler_gauge: :bourdon_pressure_gauge,
            water_glass: :gauge_glass,
            # With no condenser the exhaust goes up the chimney and draws the fire. Blastpipe and
            # stack are one part: they are proportioned together and meaningless apart.
            chimney: :blastpipe_chimney,
            damper: :wide_damper,
            safety_valve: :ramsbottom_safety_valve,
            cylinder: :high_pressure_cylinder,
            cylinder_relief: :high_pressure_cylinder_relief,
            flywheel: :light_flywheel,
            load: :mill_drive
          }.freeze
        }.freeze
      }.freeze

      # Gas conductances (damper, flue, safety valve) are set so the firebox sits within about a
      # kilopascal of ambient, the regime a real furnace runs in. Measured as a multiple of the
      # shipped values at 60/60/80 after 3600 ticks:
      #
      #     ×10    firebox +35 kPa   10.8 MW    saturated — the flue empties the box every tick
      #     ×3     firebox +1.1 kPa   6.0 MW
      #     ×1     firebox +0.5 kPa   2.9 MW    <- here
      #     ×0.5   firebox   ~0 Pa    0.1 MW    fire will not sustain
      #
      # Above ×1.5 the boiler simply pins on its safety valve, so opening the gas path further
      # buys nothing. **Re-measure if the stack height, blastpipe rating or firebox volume
      # changes** — all three move the head this is solved against.
      #
      # Each builder below makes one node. Wiring, levers and gauges live in `parts.rb`.

      def fuel_bunker
        Nodes::Vessel.new(
          id: :bunker, label: "Fuel Bunker", volume_m3: 40.0,
          initial_contents: [ { resource: :coal, kg: 12_000.0 } ],
          ports: [ Port.new(id: :out, direction: :outlet, accepts: [ :fuel ], max_kg_per_s: 2.0) ]
        )
      end

      # An effort station, not a valve: `stoking` is somebody's exertion, and what reaches the
      # grate is that times their capability.
      #
      # **0.25 kg/s is what a competent human manages**, not a mechanical limit. The fire needs
      # ~0.12 kg/s to establish and can usefully burn ~0.12-0.15 kg/s, so this puts the optimum
      # near lever 50 with a rising limb below and a real falloff above. Surplus coal banks up as
      # cold thermal mass the fire then has to heat. Measured kW at damper 60 / 70:
      #
      #     lever      30     40      50      60      70      80     100
      #     damper 60   0    27.2   116.4   110.8   105.1    99.4    88.7
      #     damper 70   0    35.7   279.6   265.3   250.9   237.3   212.5
      #
      # The light/over-fuelled window is narrow (~0.12 → 0.15 kg/s), and above damper ~80 the
      # boiler sits on its safety valve, so the falloff hides in power while the fire cools.
      def stoker
        Nodes::Conduit.new(
          id: :stoker, label: "Stoking Line", accepts: [ :fuel ],
          max_kg_per_s: 0.25, heat_capacity: 2.0e3,
          control_id: :stoking
        )
      end

      def damper(conductance:)
        Nodes::Conduit.new(
          # `conductance:` is the only air control; `max_kg_per_s` is a structural port bound and
          # does not apply to a conduit that declares one (`docs/reference/nodes.md`). The
          # atmospheric engine runs a smaller fire because its conductance is 0.1 against 0.35.
          id: :damper, label: "Damper", accepts: [ :gas ],
          max_kg_per_s: 12.0, heat_capacity: 2.0e3,
          conductance: conductance,
          control_id: :damper_open
        )
      end

      # Forced draught. A cold chimney does not draw — buoyancy needs a hot stack and a hot stack
      # needs a fire — so a naturally-drawn firebox cannot light itself. Hold the blower on to
      # establish the fire, then shut it and let the stack take over.
      #
      # **`conductance:` must be a number, and `Float::INFINITY` is the right one.** A path
      # settles by pressure only if *every* conduit on it declares a conductance
      # (`Arbiter.gas_coupling` returns nil otherwise), and one nil turns the whole air path
      # rate-driven, which leaves it with no head at all. Series conductances combine
      # reciprocally, so `1/∞ = 0` contributes nothing and the damper's rating comes through
      # untouched. Here infinity states "not the restriction"; the restriction is next door.
      #
      # `:blower_fan` rather than `:blower`, which is already the lever — ids are one flat
      # namespace across nodes, levers, gauges and crew.
      #
      # TODO: the blower is free and should not be. Intended cost is crew time first, a
      # consumable second. **Assume a black start** — a player may be the only one generating
      # power, so nothing may depend on an electrical supply. `heat_capacity` is a placeholder.
      def blower_fan
        Nodes::Conduit.new(
          id: :blower_fan, label: "Blower", accepts: [ :gas ],
          max_kg_per_s: 12.0, conductance: Float::INFINITY,
          heat_capacity: 2.0e3, ambient_conductance: 0.0,
          head_pa: 600.0, head_control_id: :blower
        )
      end

      # Where fuel and air meet. The igniter is a small, deliberate heat input — coal will
      # not catch below 700 K, so an engine has to be lit before it can be run.
      def firebox
        Nodes::Vessel.new(
          id: :firebox, label: "Firebox", volume_m3: 6.0,
          heat_capacity: 3.0e4, ambient_conductance: 60.0,
          reactions: %i[coal_combustion wood_combustion oil_combustion],
          # Ash measured against the **void** — the fire's own waste filling the gaps the air
          # comes through, which is what banking a grate with ash does. 12% of the box is space
          # between the fuel. `:waste` rather than `:solid` deliberately: coal is tagged
          # `[solid, fuel]`, so `:solid` would also make the fuel bed choke itself, which is a
          # separate mechanism with its own measurements.
          obstruction_tags: [ :waste ], void_fraction: 0.12,
          # A match, not a furnace: it sets a little fuel alight and the fire's own combustion
          # does the rest, or it does not catch. Sized so leaving it on is not a way to keep a
          # fire alive.
          heater_control_id: :igniter, heater_watts: 1.2e5, igniter_kg_per_s: 0.02,
          ports: [
            Port.new(id: :fuel_in, direction: :inlet, accepts: [ :fuel ], max_kg_per_s: 2.0),
            Port.new(id: :air_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 4.0),
            # Its own inlet: `air_in` is gas-only and a blown plug throws water. `accepts:` is
            # checked at every port on a path, so the liquid half would be dropped silently.
            Port.new(id: :plug_in, direction: :inlet, accepts: [ :gas, :liquid ],
                     max_kg_per_s: 2.0),
            # Any gas, not just combustion products — draught that was drawn in but not burnt
            # has to be able to leave, or it piles up and swallows the fire's heat.
            Port.new(id: :flue_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 12.0),
            Port.new(id: :ash_out, direction: :outlet, accepts: [ :waste ], max_kg_per_s: 0.5)
          ]
        )
      end

      # Where most of the fuel's energy reaches the water: the fire's gas is dragged through a
      # bundle of tubes surrounded by water, giving up its heat on the way to the chimney. This
      # is the second heat path, and it carries the trade-off that makes firing a skill — more
      # draught is a hotter fire but a shorter time in the tubes.
      #
      # **The tubes can burn out.** `ambient_conductance: 0.0` leaves them nowhere to shed heat
      # except into the boiler, so their metal temperature is set by the balance between the gas
      # scrubbing through and the water carrying it away. Starve the water side or over-draught
      # the fire and the metal climbs unchecked. This is *not* the low-water hazard: a lumped
      # drum at 5% water is not hot, and low water is the crown sheet's job (`Nodes::Boiler`).
      #
      # `material: :wrought_iron` takes the 750 K rating from `content/resources/materials.yml`
      # — the lowest of the structural metals. `stress_rate` is per-part: how fast a given bundle
      # fails once over is a property of the bundle.
      def boiler_tubes
        Nodes::Conduit.new(
          id: :boiler_tubes, label: "Boiler Tubes", accepts: [ :gas ],
          max_kg_per_s: 12.0, conductance: 4.0,
          # The tube bundle's own metal. Large against the gas crossing it, so the stream
          # leaves at close to the tube temperature rather than dragging it about.
          heat_capacity: 5.0e4, ambient_conductance: 0.0,
          material: :wrought_iron, stress_rate: 12.0
        )
      end

      def flue(blastpipe:)
        Nodes::Conduit.new(
          # **Wet, not dry.** `Arbiter` requires every port on a path to accept a resource, and
          # this is the high-pressure engine's only liquid outlet — gas-only floods the cylinder.
          # Real exhaust is wet steam and a blastpipe throws water.
          #
          # TODO: `Parcel.draw` splits proportionally by mass, sweeping out preferentially what
          # is a thousand times denser than the carrier. That is backwards and makes hydraulic
          # lock nearly unreachable; see `design_sketches/transport_model.md` §5.
          id: :flue, label: "Chimney", accepts: [ :gas, :liquid ],
          # Stack height is what turns a hot fire into draught (`Arbiter.path_head`) — a taller
          # chimney is a better-breathing engine.
          max_kg_per_s: 12.0, heat_capacity: 5.0e3, conductance: 0.4, stack_height_m: 10.0,
          # Buoyancy is weakest when the stack is cold, which is when a cold engine needs draught
          # most. Exhausting up the chimney ties draught to how hard the engine is working.
          blast_from: (:cylinder if blastpipe),
          blast_pa_per_kg_per_s: 600.0,
          ambient_conductance: 200.0
        )
      end

      def water_supply
        Nodes::Vessel.new(
          id: :supply, label: "Water Supply", volume_m3: 12.0,
          initial_contents: [ { resource: :water, kg: 6_000.0 } ],
          ambient_conductance: 50.0,
          ports: [
            Port.new(id: :out, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: 4.0),
            Port.new(id: :in, direction: :inlet, accepts: [ :liquid ], max_kg_per_s: 4.0)
          ]
        )
      end

      # The pump must outrun evaporation or the glass has no upward authority, but too much
      # authority puts the usable band in the bottom third of the lever and makes the rest
      # deliberate flooding. 2.0 against roughly 1 kg/s of steaming leaves a workable middle.
      # The other half of that ratio is the fire — see `damper`.
      def feed_pump
        Nodes::Conduit.new(
          id: :feed_pump, label: "Feed Pump", accepts: [ :liquid ],
          max_kg_per_s: 2.0, heat_capacity: 2.0e3,
          control_id: :feed
        )
      end

      # **The injector costs steam rather than heat.** It is thermally almost perfect — every
      # joule the live steam carries goes into the feedwater and back into the drum it came from.
      # What it costs is steam that could have driven the cylinder, so filling the boiler and
      # pulling hard compete for the same supply.
      #
      # A holder needs no new node class: steam condenses because a small vessel full of cold
      # water sits below its saturation pressure, and `h = c·T + h_f` lands the latent heat in
      # the water exactly. See `docs/design_sketches/injector.md`.
      def injector
        Nodes::Vessel.new(
          id: :injector, label: "Injector", volume_m3: 0.3,
          heat_capacity: 4.0e3, ambient_conductance: 20.0,
          ports: [
            Port.new(id: :steam_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 1.0),
            Port.new(id: :water_in, direction: :inlet, accepts: [ :liquid ], max_kg_per_s: 2.5),
            # Delivers liquid only. Any steam that failed to condense stays here rather than
            # being blown into the drum, which is what a real injector does when it "knocks off".
            Port.new(id: :out, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: 3.0)
          ]
        )
      end

      # The steam pipe to the injector, on the same lever as the water.
      #
      # **Rate-driven, not pressure-driven**: an injector is a fixed-geometry nozzle passing a
      # fixed ratio of steam to water, and a conductance as well would be two numbers for one
      # restriction. The design figure is 1 kg of steam to 10 of water, landing delivery near
      # 360 K. **Re-derive if `feed_pump` moves** — the two are one part.
      def injector_steam
        Nodes::Conduit.new(
          id: :injector_steam, label: "Injector Steam", accepts: [ :gas ],
          max_kg_per_s: 0.20, heat_capacity: 1.0e3, ambient_conductance: 10.0,
          control_id: :feed
        )
      end

      # The dangerous part. Relief pressure is where it starts hurting itself; burst
      # pressure is where it stops being a boiler.
      def boiler(shell_radius_m:, wall_thickness_m:, working_pressure_pa:)
        Nodes::Boiler.new(
          id: :boiler, label: "Boiler", volume_m3: 5.0,
          # The mark at which this drum has a full head of steam, and it is neither the shell's
          # rating nor the safety valve's setting. The shell is ~2.4x too high to mean anything
          # operationally; the valve lives in a **different slot**, so a drum cannot read it and
          # should not — swapping the valve must not change what "ready to work" means about the
          # boiler. Set just under the stock valve so the announcement lands before the blow-off
          # rather than with it.
          working_pressure_pa: working_pressure_pa,
          heat_capacity: 6.0e5, ambient_conductance: 90.0,
          initial_contents: [ { resource: :water, kg: 2_000.0 } ],
          # **The shell says what it can take; the valve setting is a decision against it.** What
          # a boiler survives must not depend on where somebody set its safety valve, so this is
          # derived from the plate: hoop stress `σ = p·r/t` gives `p = σ·t/r·safety_factor`. See
          # `Concerns::Pressurized#rated_pressure_pa`.
          #
          # `safety_factor: 0.25` is the seams, not the metal — a riveted wrought-iron boiler
          # loses about 30% to joint efficiency before any allowance for grooving and corrosion
          # along a seam. It is what makes an old boiler a different object from a new one once
          # `integrity` starts falling. Per chassis, because the plate really differs.
          shell_radius_m: shell_radius_m,
          wall_thickness_m: wall_thickness_m,
          safety_factor: 0.25, stress_rate: 90.0,
          # What the shell takes with it. Configured here rather than on `Nodes::Boiler` because
          # which parts are near enough to be wrecked is a fact about this machine. See
          # `Concerns::Wearing#failure_damages`.
          damages: { explosion: { cylinder: 0.6, flywheel: 0.5 } },
          # And what it does to the people. The fireman stands at the firebox door directly under
          # the barrel; the yardhand is at the damper, further round. Naming stations separately
          # is the point — who gets hurt depends on where they were standing.
          #
          # **Scaled by the flash expansion that caused it.** A barrel with 600 kg of water
          # behind the plate is a different event from one nearly empty. 22.0 is the figure at a
          # real rupture (`crown_sheet_spec`), so these weights mean their face value there.
          endangers: {
            explosion: { tags: %i[blast scald], scales_with: :flash_expansion, reference: 22.0,
                         stations: { stoking: 3.0, damper_open: 1.4 } },
            seam_split: { tags: %i[scald heat], scales_with: :flash_expansion, reference: 22.0,
                          stations: { stoking: 0.9, damper_open: 0.3 } }
          },
          # **The crown sheet is what makes a low glass dangerous.** `material:` takes the rating
          # from content — wrought iron at 750 K — and `fired_by:` is the node on the other side
          # of the plate.
          #
          # 0.25 is where the plate starts to come out of the water, against a drum running at
          # 0.47–0.58 in ordinary work. That gap is deliberate: baring the crown sheet takes
          # sustained neglect, not a moment's inattention. What shortens it is **swell** — the
          # glass shows the bubbles and the plate is cooled by water, so pulling hard reads
          # comfortable while the level falls past the plate. See `Nodes::Boiler`.
          material: :wrought_iron, crown_fill: 0.25, fired_by: :firebox,
          # **Priming.** Overfill and water comes over with the steam, past the throttle and on
          # to the cylinder, which is the road to hydraulic lock. Below 55% full the boiler is
          # 99.5% dry and this is invisible.
          #
          # **Swell** makes priming an event rather than a level: scaled by how fast the drum is
          # losing pressure, so steady running of any intensity costs nothing and only a sharp
          # demand change lifts the water. Slamming the regulator from 60 to 100 drops the drum
          # at about 8.8 kPa/s, so 8 kPa/s is a hard pull.
          #
          # `max_swell` 0.20 reads 1.25× true level at saturation — enough to fool a driver who
          # is not watching the fire, not enough to be noise. The safety comes from the **glass**,
          # not the swell: a full glass alone and a sharp opening alone are both survivable.
          steam_port: :steam_out, wetness: 0.005, foaming_wetness: 0.30, onset_fill: 0.55,
          priming_wetness: 0.97, swell_pa_per_s: 8_000.0, max_swell: 0.20,
          # Real drums take tens of seconds to settle after a demand change, and it has to be
          # long enough for water to actually go somewhere — at 8 s the slug was over before the
          # chest had filled.
          swell_settle_s: 12.0,
          ports: [
            Port.new(id: :feed_in, direction: :inlet, accepts: [ :liquid ], max_kg_per_s: 2.5),
            # **Wet, because the whole steam line has to be.** `accepts:` is a structural gate
            # that runs before any affinity, so a gas-only outlet makes carryover impossible
            # whatever the drum is doing. The tag says water *may* cross; `carryover` decides how
            # much. Rated for the **water**, not the steam: on a pressure-driven path conductance
            # rates the gas and this bounds only the liquid riding with it (`Arbiter.entrained`),
            # so it is the bore of the main steam pipe — tens of kg/s for a 150 mm offtake.
            Port.new(id: :steam_out, direction: :outlet, accepts: [ :gas, :liquid ],
                     max_kg_per_s: 25.0),
            Port.new(id: :relief_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 3.0),
            # Where the shell lets go. Wet, because what comes out of a burst drum is steam and
            # the water flashing behind it, and rated far above anything the working machine
            # uses so that the **breach** is the restriction rather than this port — see
            # `SteamEngine.boiler_breach`. Nothing flows through it while the drum is sound.
            Port.new(id: :breach_out, direction: :outlet, accepts: [ :gas, :liquid ],
                     max_kg_per_s: 100.0),
            # A second hole, for the regulator's failure. It sits in the dome on the boiler side
            # of its own valve, so a split body empties the drum and no lever on the footplate
            # stops it. A conduit holds nothing, so its rupture drains a holder. See
            # `Nodes::Breach`.
            Port.new(id: :steam_pipe_out, direction: :outlet, accepts: [ :gas, :liquid ],
                     max_kg_per_s: 40.0),
            # Through the crown sheet and down onto the fire. Wet, because what comes out of a
            # blown plug is whatever is at the top of the water.
            Port.new(id: :plug_out, direction: :outlet, accepts: [ :gas, :liquid ],
                     max_kg_per_s: 2.0),
            # Its own pipe from the steam space, deliberately not `steam_out`: carryover affinity
            # is keyed to `steam_port`, so this is fed dry steam rather than priming water, which
            # keeps the injector working precisely when the boiler is misbehaving.
            Port.new(id: :injector_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 1.0)
          ]
        )
      end

      # **The hole the drum opens when it fails.** Mode fractions scale conductance and rate
      # together, because `Conduit#open_fraction` feeds both — one number is the size of the hole.
      #
      # Sized against the **regulator wide open** (`conductance: 1.5e-3`), which is the hole this
      # engine's whole output goes through. Swept on a worked engine (175 rpm, 608 kPa, 2034 kg
      # in the drum), rpm at +600 ticks:
      #
      #     conductance   2e-5    1e-4    4e-4    2e-3     2.0
      #     rpm           175     151      80      18       2
      #     spilled kg     26     111     230     294    2150
      #
      # `seam_split` at 1e-4 is the limp-home case: the engine loses speed slowly and a driver who
      # damps the fire and runs for the shed has a decision worth making. That is 5e-5 of the
      # shell — about 8 cm², a hole three centimetres across, which is what a weeping seam is.
      # `explosion` opens the whole bore and empties the drum inside a hundred ticks.
      #
      # **Run-ending is not declared anywhere.** The engine stops because there is no pressure,
      # because there is a hole. See `docs/design_sketches/failure_model.md` §6.
      def boiler_breach
        Nodes::Breach.new(
          id: :boiler_breach, label: "Boiler Breach", senses: :boiler,
          opens_by: { seam_split: 5.0e-5, explosion: 1.0 },
          accepts: [ :gas, :liquid ], max_kg_per_s: 60.0, conductance: 2.0,
          # Effectively no wall. A hole is not a fitting: it has no thermal mass of its own to
          # rob the escaping stream of heat on the way out, and giving it one would make a burst
          # drum quietly cheaper than it should be.
          heat_capacity: 1.0, ambient_conductance: 0.0
        )
      end

      # The hole a blown head leaves. Much smaller than the boiler's: a cylinder holds a couple
      # of kilograms of steam, so what escapes is the charge and whatever the chest keeps feeding
      # it. `scored_bore` is deliberately absent — worn rings leak *past the piston*, which is a
      # derating rather than a hole in the casing, and a mode a breach does not name opens
      # nothing.
      def cylinder_breach
        Nodes::Breach.new(
          id: :cylinder_breach, label: "Cylinder Breach", senses: :cylinder,
          opens_by: { blown_head: 1.0 },
          accepts: [ :gas, :liquid ], max_kg_per_s: 25.0, conductance: 0.3,
          heat_capacity: 1.0, ambient_conductance: 0.0
        )
      end

      # A split chest casting. `Nodes::Vessel`'s one mode is `:rupture`, so that is what this
      # names. Sized between the cylinder's and the boiler's: the chest holds little but sits on
      # the main steam line, so what escapes is mostly what the boiler keeps feeding it — a
      # starvation failure rather than a bang.
      def steam_chest_breach
        Nodes::Breach.new(
          id: :steam_chest_breach, label: "Steam Chest Breach", senses: :steam_chest,
          opens_by: { rupture: 1.0 },
          accepts: [ :gas, :liquid ], max_kg_per_s: 40.0, conductance: 0.6,
          heat_capacity: 1.0, ambient_conductance: 0.0
        )
      end

      # A conduit rupture, and why `senses:` is separate from what a breach drains. It watches
      # the **throttle** and empties the **boiler**: a locomotive regulator sits in the dome on
      # the boiler side of its own valve, so shutting it does not stop the leak. **The one
      # control that would normally save you is on the wrong side of the hole.**
      #
      # Smaller than the drum's own breach — a slit along a seam, not the shell opening. Sized to
      # bleed the boiler faster than the fire can replace it while leaving time to drop the fire
      # and save the crown sheet.
      def steam_pipe_breach
        Nodes::Breach.new(
          id: :steam_pipe_breach, label: "Steam Pipe Breach", senses: :throttle,
          opens_by: { rupture: 1.0 },
          accepts: [ :gas, :liquid ], max_kg_per_s: 40.0, conductance: 0.02,
          heat_capacity: 1.0, ambient_conductance: 0.0
        )
      end

      # Sized to pass rather more steam than the fire can raise, but not without limit — a badly
      # stoked boiler can still outrun it.
      #
      # **The easing lever** lifts the valve by hand, to prove it is not stuck to its seat or to
      # blow pressure down before it reaches the setting. It can only open the valve further than
      # the spring already has (`ReliefValve#open_fraction`), so it spends steam and can never
      # hold the boiler shut.
      #
      # **The adjusting screw is the engine's risk/reward lever.** `relief_pa` is the *safe* end
      # of a range: the lever reads as margin, defaults to 100, and winding it down raises the
      # valve toward `max_relief_pa`. What a player buys is admission pressure and power; what
      # they pay is a crown sheet that fails sooner on the same overheating
      # (`Boiler#crown_allowable_pressure_pa`), less headroom under the shell's rating, and a
      # flywheel asked for work it may not survive. Measured at cut-off 40:
      #
      #     margin   100     90     80     70     60     40     20
      #     kW     364.1  406.8  451.9  499.9  552.6  653.2  burst
      #     wheel   0.27   0.30   0.34   0.38   0.41   0.49   1.00
      #
      # `max_relief_pa` sits well below what the shell could stand, because the **wheel** is the
      # interesting limit and a stronger one is what unlocks the top of this lever.
      #
      # **The two levers interact.** At full gear the safe band is far narrower — 100/90/80 give
      # 517.8 / 571.0 / 631.3 kW and margin 70 bursts the wheel — so a driver can have high
      # pressure *or* full gear, not both. At margin 100 the drum sits on its valve at 608 kPa;
      # at 90 or below it runs under the setting and is limited by the fire instead.
      def relief_valve(relief_pa:, max_relief_pa:)
        Nodes::ReliefValve.new(
          id: :relief, label: "Safety Valve", senses: :boiler,
          relief_pressure_pa: relief_pa, ease_control_id: :ease_safety,
          setting_control_id: :valve_setting,
          max_relief_pressure_pa: max_relief_pa,
          accepts: [ :gas ], max_kg_per_s: 3.0, conductance: 0.05,
          heat_capacity: 1.0e3, ambient_conductance: 50.0
        )
      end

      # A soft-metal bung through the crown sheet, rated to go at 620 K against the plate's own
      # 750 K. While water covers the plate the plug is cooled with it; uncover it and this melts
      # first, dumping steam and water onto the fire.
      #
      # **A warning, not a save**: it puts the fire out and leaves the engine out of service
      # until somebody fits a new one — a ruined day against a ruined boiler.
      #
      # Not a `ReliefValve`, because one re-seats, and a boiler that healed itself once the water
      # came back would be exactly the consequence-free behaviour this hazard exists to prevent.
      # It senses the **crown sheet** rather than the drum: a lumped drum at 5% water is not hot,
      # merely empty, so a plug pointed at `temperature_k` would look like protection and be none.
      def fusible_plug
        Nodes::FusiblePlug.new(
          id: :fusible_plug, label: "Fusible Plug",
          senses: :boiler, senses_key: :crown_temperature_k,
          melts_above: 620.0,
          accepts: [ :gas, :liquid ], max_kg_per_s: 2.0,
          heat_capacity: 2.0e2, ambient_conductance: 0.0
        )
      end

      # **A restriction, not a ration.** Flow through a conductance costs a pressure drop that
      # grows with the flow, so the steam chest behind it sits below the boiler by an amount the
      # driver controls. That is wire-drawing, and it is what a regulator physically is. A rate
      # cap instead would decide how much steam arrives but nothing about the pressure it arrives
      # at, leaving the regulator no effect on torque at all.
      def throttle
        Nodes::Conduit.new(
          # Wet, like the rest of the steam line. `accepts:` is checked at **every** port on a
          # path, so one dry tag between the drum and the cylinder repeals priming silently.
          id: :throttle, label: "Throttle Valve", accepts: [ :gas, :liquid ],
          # Two numbers for one restriction, deliberately: `conductance` rates the steam and
          # `max_kg_per_s` the water it carries (`Arbiter.entrained` bounds liquid by the bore).
          max_kg_per_s: 25.0, conductance: 1.5e-3, heat_capacity: 3.0e3,
          # **Equal-percentage trim**, because a linear regulator is not a linear control here:
          # wide open, `k·dt·ΣC⁻¹` is 1.76, so the chest equalises with the drum inside a tick and
          # the valve stops being the restriction. On linear trim the chest reaches 85% of boiler
          # pressure by lever 30 and the top 70% of travel buys 21% of the power.
          #
          # 8 comes from a sweep. The engine needs about 4.5% of full conductance to beat the
          # load, and a steeper curve (50) does not reach that until lever 30, moving the dead
          # zone to the bottom of the travel instead of the top. Power per notch in the upper
          # half, linear against 8: +17/+11/+7/+6 becomes +35/+25/+19/+15. See
          # `Conduit#open_fraction`.
          rangeability: 8.0,
          control_id: :throttle_open
        )
      end

      # An engine admits steam from a chest between the regulator and the valve gear, and the
      # pressure in **that** — not the boiler's — is what the indicator diagram starts from.
      #
      # The loop then closes on its own and needs no bound: if the cylinder swallows faster than
      # the throttle can pass, the chest depletes, its pressure falls, and both the demand
      # (through admission density) and the MEP (through P₁) fall with it next tick. That is the
      # engine physically unable to work steam it did not receive.
      #
      # 1 m³ is the chest *and* the main steam pipe behind it. It has to hold several ticks of
      # admission or the cylinder's positive-displacement draw empties it inside one and the
      # pressure rings; at full gear the cylinder takes about 0.25 kg a tick.
      #
      # The outlet is permissive: wet steam reaching the valve is real, and it is the road by
      # which priming becomes hydraulic lock.
      def steam_chest
        Nodes::Vessel.new(
          id: :steam_chest, label: "Steam Chest", volume_m3: 1.0,
          heat_capacity: 2.0e4, ambient_conductance: 40.0,
          ports: [
            Port.new(id: :in, direction: :inlet, accepts: [ :gas, :liquid ], max_kg_per_s: 25.0),
            Port.new(id: :out, direction: :outlet, max_kg_per_s: 25.0),
            # Where a split chest casting lets go. Inert while it is sound.
            Port.new(id: :breach_out, direction: :outlet, accepts: [ :gas, :liquid ],
                     max_kg_per_s: 40.0)
          ]
        )
      end

      # Raking out the ashpan: the remedy that makes a choked grate a mechanic rather than a slow
      # dead end. Ash is produced by both combustion reactions and consumed by nothing, so
      # without a way out the fire strangles itself and no lever helps.
      #
      # An effort station like the stoker, not a valve.
      def ash_pan
        Nodes::Conduit.new(
          id: :ash_pan, label: "Ashpan", accepts: [ :waste ],
          max_kg_per_s: 0.5, heat_capacity: 1.0e3, ambient_conductance: 40.0,
          control_id: :ash_raking
        )
      end

      # **A decision, not a safety net.** A cold or standing cylinder fills with its own
      # condensate. While the engine turns, the exhaust stroke sweeps that water out; while it
      # stands, `exhaust_demand_kg` scales with revolutions and the exhaust carries nothing, so
      # the water collects.
      #
      # Permissive on purpose: real cocks blow steam as well as water, so leaving them open is a
      # choice rather than a free win. Open, the cylinder cannot hold a charge and the engine
      # will not pull; shut, it is efficient and accumulating. Measured over a full startup:
      #
      #     shut throughout          peak 0.859  knocking badly, relief lifting, 329.1 kW
      #     open throughout          peak 0.002  dry, 313.3 kW — blowing steam away
      #     open, then shut when hot peak 0.006  dry, 326.7 kW
      #
      # The third row is the procedure, and the only one that gets both. See `cylinder`.
      def drain_cocks
        Nodes::Conduit.new(
          id: :drain_cocks, label: "Cylinder Cocks",
          max_kg_per_s: 0.25, heat_capacity: 5.0e2, ambient_conductance: 20.0,
          control_id: :cylinder_cocks
        )
      end

      # **The last chance before a cylinder end goes**, and it works because it senses the right
      # quantity. The charge spread over the whole cylinder barely moves as the clearance fills,
      # so `pressure_pa` would give no warning at all; `compression_pressure_pa` is what the
      # charge reaches at top dead centre — 2.2× the dry figure on half a clearance of water and
      # 13.6× on nine tenths. Set above the highest compression of normal work, so it costs
      # nothing until something is wrong.
      #
      # **Its setting rarely matters; its presence matters on every cold start.** A startup with
      # no relief valve fitted ends in `cylinder_failure`: warming through fills a cold cylinder
      # with condensate, and this is what lifts and vents the charge. In ordinary running it
      # never lifts. It matters while the cylinder is **wet**, where lifting costs real power
      # exactly when a driver is already in trouble — so a higher setting keeps the engine
      # pulling through a damp patch, at the price of telling the last safeguard to wait longer.
      #
      # The range to 20 atm is generous against a 9 atm base on purpose: the barrel's derived
      # hoop rating is far above both, so a better cylinder should find room here. Going past
      # what the barrel takes fatigues it — see `Cylinder#stress_per_second`.
      def cylinder_relief(relief_pa:, max_relief_pa:)
        Nodes::ReliefValve.new(
          id: :cylinder_relief, label: "Cylinder Relief Valve",
          senses: :cylinder, senses_quantity: :compression_pressure_pa,
          relief_pressure_pa: relief_pa,
          setting_control_id: :cylinder_valve_setting,
          max_relief_pressure_pa: max_relief_pa,
          max_kg_per_s: 2.0, conductance: 0.02,
          heat_capacity: 5.0e2, ambient_conductance: 20.0
        )
      end

      def cylinder(spec, bore_m:, stroke_m:, heat_capacity:)
        Nodes::Cylinder.new(
          id: :cylinder, label: "Cylinder",
          bore_m: bore_m, stroke_m: stroke_m,
          # **`supplied_by:` is the steam chest, not the boiler**, which is what makes the
          # regulator a real control: it is where the diagram takes its admission pressure and
          # whose density sizes the intake.
          drives: :flywheel, exhausts_to: spec.fetch(:exhausts_to), supplied_by: :steam_chest,
          cutoff_control_id: :cutoff, efficiency: 0.82,
          # **What makes the cocks cost something.** An open cock bleeds the working space to
          # atmosphere while the piston pushes against it — a pressure divider on the admission
          # pressure. See `Cylinder#admission_pressure_pa`.
          #
          # The loss compounds: algebra predicts ~27% for this authority and it measures **43%**,
          # because less power is a slower engine, less blastpipe draught, a weaker fire and a
          # lower chest pressure. Measured cost of leaving them wide open:
          #
          #                 throttle 20   throttle 60   throttle 100
          #     0.15            19.6%         21.4%         21.6%
          #     0.20            26.1%         28.5%         29.3%
          #     0.30            39.2%         42.3%         43.4%   <- here
          #
          # The penalty is **larger the harder the engine is pulling** (78 kW against 159 kW in
          # absolute terms), which is right: dumping your most energetic steam should cost most.
          # It is a gradient rather than a switch — cocks 0/25/50/75/100 at full throttle give
          # 365.7 / 328.1 / 284.0 / 243.5 / 206.8 kW — and shut, the engine is bit-identical to
          # having no cocks at all.
          drain_control_id: :cylinder_cocks, drain_authority: 0.30,
          # The barrel's own strength, so over-pressure has a graded cost through
          # `Cylinder#stress_per_second` rather than only the all-at-once `overload?`. Radius
          # comes from the bore, so only thickness and metal are stated: 25 mm of cast iron over
          # a 0.225 m radius rates well above the relief setting, which is right — a barrel is a
          # thick casting and its danger is the *compression spike*, not working pressure.
          # `safety_factor: 0.3` is the casting: cast iron is brittle and a cylinder end is full
          # of stress raisers where the cover bolts through.
          material: :cast_iron, wall_thickness_m: 0.025, safety_factor: 0.3, stress_rate: 45.0,
          # **The cold-cylinder mechanic lives in this number.** A cold cylinder condenses much of
          # what it is admitted, which is why the procedure is *cocks open, crack the regulator,
          # warm through, shut the cocks* — and that needs a warming window long enough to act in.
          #
          # Taken from the geometry: 0.45 m bore, 1.1 m stroke, ~25 mm wall gives ≈ 0.057 m³ of
          # cast iron, 410 kg, 189 kJ/K for the bare barrel. 4.0e5 is roughly twice that, the
          # allowance for piston, rod, cover bolting and valve faces. Peak cylinder occupancy
          # over a normal startup with the cocks left shut:
          #
          #     hc    6.0e4   2.0e5   4.0e5   6.0e5   8.0e5
          #     occ   0.188   0.579   0.859   0.924   0.947
          #
          # At 4.0e5 the engine reads "knocking badly", lifts the cylinder relief valve, takes no
          # damage, and clears once it is turning — a scare that teaches the procedure rather than
          # a death sentence. Opening the cocks holds it at 0.002 for about 5% of the power.
          heat_capacity: heat_capacity,
          # Rated for the port, not the stroke: `admission_kg` sizes the charge and this only
          # stops the valve passing more than the pipe can. It must admit water at the rate the
          # steam line delivers it, or a slug cannot reach the piston and hydraulic lock stays a
          # standing-engine curiosity.
          inlet_kg_per_s: 25.0, exhaust_kg_per_s: 6.0
        )
      end

      def flywheel(mass_kg:, radius_m:, friction:, safety_factor:)
        # A beam engine's wheel is a different object from a high-pressure engine's: vastly
        # heavier, larger, and turning far more slowly. It has to be, because a 1.3 m piston
        # working against a vacuum develops something like 160 kN·m.
        Nodes::Flywheel.new(
          id: :flywheel, label: "Flywheel",
          # Cast iron is strong in compression and weak in tension, the wrong way round for a
          # flywheel. Strength and density come from content; the safety factor is this part's
          # own, because how far below the ideal a real casting fails is a property of the
          # casting.
          #
          # **0.45 on the high-pressure engine is what keeps the boiler the danger.** Swept
          # against a starved boiler, reporting which part fails first and the wheel's peak
          # stress:
          #
          #     wheel                margin 100   margin 70   margin 40   margin 0 (9 atm)
          #     iron sf 0.35         crown 0.27   crown 0.38  crown 0.50  **WHEEL** t1511
          #     iron sf 0.45  ×1.65  crown 0.16   crown 0.23  crown 0.30  crown 0.41
          #     iron sf 0.55  ×2.47  crown 0.11   crown 0.15  crown 0.20  crown 0.27
          #     steel sf 0.35 ×3.06  crown 0.09   crown 0.12  crown 0.16  crown 0.22
          #
          # 0.45 is the **minimum** that works, and the minimum is the point: it makes the crown
          # reachable at every pressure while leaving the wheel at 0.41 wound right down, a real
          # gradient on the Wheel Stress gauge. At 0.55 and above the wheel stops being a hazard,
          # which is why steel is an upgrade rather than the default. Below it the wheel bursts
          # in the acceleration transient and the low-water hazard is unreachable.
          #
          # Watt's wheel keeps 0.35: period-apt for 1776 foundry practice, and irrelevant in
          # normal running, where that wheel sits at 0.007 of its burst stress. The figure only
          # decides how far it overspeeds when the load comes off.
          material: :cast_iron, safety_factor: safety_factor,
          friction: friction,
          fatigue_rate: 25.0,
          mass_kg: mass_kg,
          radius_m: radius_m
        )
      end

      # A mill on a line shaft: paddles, stones and belts all dragging, so what it absorbs
      # climbs with the square of the speed. `load_torque` is what it takes at
      # `load_rated_omega`, not a ceiling.
      #
      # **This is what makes shedding the load dangerous rather than raising it.** Under a fan
      # law the mill holds the engine at its duty point, so taking the load away is what lets
      # everything the boiler pours in go into acceleration, with only the wheel's tensile limit
      # in the way. A constant-torque brake has no stable intersection with the cylinder's torque
      # curve, which makes full demand the *safe* setting.
      def load(moment_of_inertia:, max_torque:, rated_omega:)
        Nodes::Load.new(
          id: :load, label: "Mill Drive", moment_of_inertia: moment_of_inertia,
          max_torque: max_torque, rated_omega: rated_omega,
          curve: :fan, control_id: :load_demand, friction: 3.0
        )
      end

      # Only on the atmospheric engine. Sitting in cold water, it drops the pressure below
      # atmospheric — and that vacuum is what actually drives a Watt engine.
      def condenser
        Nodes::Vessel.new(
          id: :condenser, label: "Condenser", volume_m3: 3.0,
          heat_capacity: 2.0e5, ambient_conductance: 600_000.0,
          ports: [
            Port.new(id: :in, direction: :inlet, max_kg_per_s: 14.0),
            Port.new(id: :drain, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: 4.0)
          ]
        )
      end

      # Condensate back to the supply, closing the water loop.
      def condensate_return
        Nodes::Conduit.new(
          id: :hotwell, label: "Hotwell Return", accepts: [ :liquid ],
          max_kg_per_s: 4.0, heat_capacity: 2.0e3,
          ambient_conductance: 400.0
        )
      end

      # --- wiring --------------------------------------------------------------
      #
      # Links ship with the fitting they belong to, in `parts.rb`, which is what makes a part
      # removable: an unfitted part contributes no fragment, so its links leave with it. The one
      # link that is no fitting's — where the cylinder exhausts to — is the chassis's own, in
      # `SteamEngine.fixtures`.
      #
      # Two paths carry fire to water: **radiant**, the firebox glowing at the water legs, and
      # **convective**, flue gas scrubbing through the tube bundle. The split matters more than
      # either number — with only the radiant path the firebox is pinned at `T_boiler + Q/k`, so
      # a hot fire and a well-fed boiler are mutually exclusive. Measured at 60/60/80, heat
      # reaching the water and shaft power out:
      #
      #     radiant only, k=9000    firebox  676 K   2300 kW   41.0 kW
      #     radiant 2000 + tubes    firebox 1036 K   2191 kW   24.2 kW
      #     radiant 3500 + tubes    firebox  895 K   2332 kW   47.3 kW   <- here
      #
      # A boiler fitted without its tubes is the first row.

      # --- controls ------------------------------------------------------------
      #
      # **Levers arrive with the part they belong to**, in `parts.rb`. Panel order is slot
      # declaration order, ordered by the cab rather than by the graph.
      #
      # Every lever keeps the default `stiffness: Float::INFINITY`, so `actual` snaps to
      # `target` — these are valves, and a valve goes where you put it. The crew bites through
      # `effort:` instead: `:stoking` and `:ash_raking` declare a weighted stat blend, the lever
      # is the player's intent, and what the node reads is `lever × capability`
      # (`Tick#control_values`). Day-labourers reach 56 kPa and never turn the wheel where a
      # competent hand reaches 608 kPa and 174.6 rpm. See `design_sketches/minions.md` §9.
      #
      # Two of them are worth reading where they are declared, because their defaults are
      # deliberate and surprising:
      #
      #   :cylinder_cocks    **defaults shut, and that is not the safe setting.** A standing
      #                      engine should have its cocks open; this defaults closed because that
      #                      is the state the balance was measured in, and a lever whose default
      #                      silently changes every other number is worse than one to learn.
      #   :valve_setting     **the adjusting screw, read as margin rather than as pressure**,
      #                      defaulting to 100 — the full safety margin — so an untouched
      #                      engine is the safe engine and spending margin is a decision.
      #                      `:cylinder_valve_setting` follows the same convention.

      # --- crew ----------------------------------------------------------------

      # **What the machine asks for, not who turns up.** A fireman is a job; who is doing it this
      # match comes from the roster, in `options:`.
      #
      # The two posts cover the two effort stations. The other five levers are valves and need
      # nobody — but an *effort* station with nobody on it delivers nothing, so a machine whose
      # roster leaves these empty is worked by the labour exchange and barely runs.
      #
      # NOTE the ids. The obvious name for the person shovelling coal is `stoker`, and `:stoker`
      # is already the conduit carrying fuel to the firebox. Ids are shared across nodes, levers,
      # instruments and crew because they key one rng table, so that collision would hand two
      # components the same stream. `validate_graph!` refuses it outright.
      def crew_roles
        [ Crew::Role.new(id: :fireman, label: "Fireman", station: :stoking),
          Crew::Role.new(id: :yardhand, label: "Yardhand", station: :damper_open) ]
      end

      # **The roster, resolved.** An unfilled role gets the standin, which is what makes an empty
      # slot and a minion on the injury list the same thing to the engine: somebody turned up,
      # and they are not who you wanted.
      def crew_for(roster, content)
        crew_roles.map do |role|
          sheet = Crew.resolve(roster[role.id], content: content)

          Minion.new(id: role.id, station: role.station, name: sheet.fetch(:name),
                     minion: sheet.fetch(:minion), archetype: sheet.fetch(:archetype),
                     stats: sheet.fetch(:stats), tags: sheet.fetch(:tags))
        end
      end
    end
  end
end
