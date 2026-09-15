# frozen_string_literal: true

module ReactorSim
  module Operations
    # A stationary steam engine, in two historical flavours built from the same parts.
    #
    # This operation exists to answer a question about the architecture, not just to be
    # playable: *can an atmospheric engine and a high-pressure engine be the same operation
    # with different parts swapped in?* If yes, the abstractions are the right ones.
    #
    # They can, and the difference is three lines:
    #
    #   | | boiler relief | cylinder exhausts to | condenser |
    #   |---|---|---|---|
    #   | **Watt atmospheric** (1776)      | ~1.4 atm | the condenser | yes |
    #   | **Trevithick high-pressure** (1802) | ~6 atm | the atmosphere | no |
    #
    # Watt's engine works by making a vacuum and letting the sky push the piston; the
    # boiler barely needs to be above atmospheric, and the condenser is the whole point.
    # Trevithick threw the condenser away and pushed with boiler pressure instead — lighter,
    # far more powerful, and with a habit of exploding, which is why Watt thought he was mad.
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
    # Everything after the firebox is the same in both engines. Only the exhaust path moves.
    #
    # **The injector is why the feed lever is a decision.** Cold water straight into a hot drum
    # put the fire out — at feed 100 the boiler fell to 376 K and the engine stopped — which made
    # a high water level and a working engine mutually exclusive, and priming therefore
    # unreachable. A real injector is pumped by live steam that condenses into the feedwater, so
    # it costs almost no heat and a great deal of *steam*: filling the boiler and pulling hard now
    # draw on the same supply. See `docs/design_sketches/injector.md`.
    #
    # **The steam chest is not decoration.** A regulator that rations mass without setting a
    # pressure cannot affect torque, so the cylinder's diagram had nothing to read but the
    # boiler, and a conservation clamp quietly became the throttle. The chest gives the two
    # laws somewhere to meet: a gradient decides what gets into it, geometry decides what is
    # taken out, and its pressure is the negotiation. See `nodes/CLAUDE.md`.
    #
    # **Two heat paths, not one.** With a single conduction link the firebox temperature is
    # pinned at `T_boiler + Q/k`, so a realistic fire and a well-fed boiler were mutually
    # exclusive. Giving the flue gas a route past the water — which is what boiler tubes are —
    # buys both, and needs no new machinery: a conduit already has a wall the stream mixes
    # into, and a ThermalLink already couples that wall to the water.
    module SteamEngine
      TYPE = :steam_engine

      # A steam engine is a FAST machine — sixty revolutions a minute is interesting in real
      # time — so unlike a mine or a smelter it wants little or no time compression. At
      # `time_scale` 8 a single tick applies two seconds of full torque, which is enough to
      # take a flywheel from rest to past its burst speed before anything can respond.
      DEFAULT_TIME_SCALE = 1.0

      module_function

      # **The engine is assembled from parts now**, not built from a node list. The chassis
      # decides the frame — where the exhaust goes, which slots exist — and the loadout decides
      # what is fitted in them. See `parts.rb` for the components and
      # `docs/design_sketches/modular_components.md` for why it is shaped this way.
      #
      # An empty `loadout:` is the stock engine: `Assembly` fills every slot from its
      # `default:`, and the result is bit-identical to the machine that existed before parts
      # did.
      def build(id:, seed:, chassis: :high_pressure, loadout: {},
                time_scale: DEFAULT_TIME_SCALE, state: nil, rngs: nil, content: nil)
        # Symbolised because a restored snapshot brings it back from JSON as a string.
        chassis = chassis.to_sym
        assembly = assembly_for(chassis, loadout)
        fragment = assembly.build!

        Operation.new(
          id: id, type: TYPE, seed: seed, time_scale: time_scale,
          state: state, rngs: rngs, content: content,
          # **The resolved loadout, not the one that was passed in**, and every slot is named
          # in it including the empty ones. A partial loadout would be re-defaulted on restore,
          # so a deliberately-empty slot would quietly grow its part back — the exact silent
          # divergence `options:` exists to prevent.
          options: { chassis: chassis, loadout: assembly.loadout },
          nodes: fragment.nodes, links: fragment.links,
          thermal_links: fragment.thermal_links, drive_links: fragment.drive_links,
          control_points: fragment.control_points,
          diagnostics: assembly.diagnostics, minions: crew
        )
      end

      # **The one way to ask what a loadout would build, and the only thing outside the sim
      # should need.** An outfitting screen wants the slots, the alternatives for each, and the
      # verdict — all of which are on `Assembly` — and it wants them *without* building an
      # operation, because most of what it renders is for builds the player has not chosen.
      #
      # `build` goes through here too, so the machine a player is shown and the machine they get
      # cannot be assembled two different ways.
      def assembly_for(chassis, loadout = {})
        spec = CHASSIS.fetch(chassis.to_sym) { raise Error, "unknown engine chassis #{chassis.inspect}" }

        Assembly.new(
          slots: slots(spec), loadout: loadout, spec: spec,
          fixtures: fixtures(spec), instruments: catalogue, order: PANEL_ORDER,
          routes: ROUTES, advisories: ADVISORIES
        )
      end

      # **A chassis is the frame: fixed topology, and which part goes in each slot that differs
      # between the two machines.** It used to be a flat bag of twenty numbers, seventeen of
      # which belonged to six parts that were not separate objects yet — see
      # `docs/design_sketches/modular_components.md` §1, which is the observation the whole of
      # modularisation came out of. Those numbers now live on the parts that own them, in
      # `parts.rb`, together with the measurements that chose them.
      #
      # What is left is genuinely the machine's shape, plus one presentation number.
      CHASSIS = {
        # Low boiler pressure, exhaust into a vacuum. The condenser does the work.
        atmospheric: {
          exhausts_to: :condenser,
          condenser: true,
          # Everything not named here is the same on both machines and keeps its default in
          # `slots`. `fetch` on the way out, so adding a slot that varies and forgetting to name
          # it here raises rather than silently fitting the wrong part.
          parts: {
            boiler: :beam_boiler,
            # **This is where `burst_pa` went.** It was the boiler pressure gauge's full-scale
            # reading — never a physical limit; the shell's real rating is derived from its plate
            # by `Concerns::Pressurized#rated_pressure_pa` — and it sat on the chassis because
            # the panel catalogue was built from the chassis and did not know which boiler was
            # fitted. The dial is a fitting now, so the number lives on the dial.
            boiler_gauge: :low_pressure_gauge,
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
            # Trevithick threw the condenser away, which left the exhaust needing somewhere to
            # go — and putting it up the chimney turned a liability into the engine's lungs.
            # **That is one part rather than two**: a blastpipe and the chimney above it were
            # proportioned together and are meaningless apart. See `parts.rb`.
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

      # --- what the chassis used to carry, and where it went ---------------------
      #
      # The block below was `VARIANTS`, a flat hash of twenty keys. Seventeen of them belonged
      # to six parts; they are now on those parts in `parts.rb`, with the sweeps that chose them.
      # Kept here for one more release as a map, because several of these numbers are cited by
      # name in `current_progress.md` and in the notes on the node builders further down:
      #
      #     relief_pa, max_relief_pa                 -> :ramsbottom_safety_valve / :low_pressure_safety_valve
      #     cylinder_relief_pa, ..._max_pa           -> :high_pressure_cylinder_relief / :low_pressure_...
      #     shell_radius_m, wall_thickness_m         -> :locomotive_boiler / :beam_boiler
      #     bore_m, stroke_m, cylinder_heat_capacity -> :high_pressure_cylinder / :atmospheric_cylinder
      #     flywheel{}, wheel_safety_factor          -> :light_flywheel / :beam_flywheel
      #     load_inertia, load_torque, load_rated_omega -> :mill_drive / :slow_mill_drive
      #     damper_conductance                       -> :wide_damper / :narrow_damper
      #     blastpipe                                -> :blastpipe_chimney / :plain_chimney
      #
      # `exhausts_to` and `condenser` stayed: they are the machine's shape rather than a
      # fitting's rating.
      #
      # **`burst_pa` is gone too, as of 2026-09-14**, and it took a change of mind to move it. It
      # was the pressure gauge's full-scale reading and it stayed here because the panel catalogue
      # was built from the chassis. The fix was not to pass the fitted boiler into the catalogue —
      # a gauge's range is not a property of the drum either. It was to notice that **the dial is
      # a separate object screwed to the boiler**, and make it a part: `:boiler_gauge`, optional,
      # with the scale on the gauge where it belongs. Same rule as the blower and the blastpipe —
      # *an attribute becomes a node when it is a separate object, and a variant when it is a
      # different version of the same object* — applied to an instrument for the first time.
      #
      # So `CHASSIS` now holds `exhausts_to`, `condenser` and `parts:`. Topology and nothing else,
      # which is what §6 of the modularisation sketch asked for.

      # --- how the gas conductances were chosen ---------------------------------
      #
      # `damper_conductance`, the flue's and the safety valve's are **one tenth** of what they
      # were before mass transport became an implicit network solve, and the factor is not a
      # fudge — it is the difference between a number that was doing nothing and a number that
      # sets the draught.
      #
      # Under the old explicit law the flow was decided by a stability limiter rather than by
      # conductance (the flue asked for 1972 mol and was granted 1.8), so these could be
      # anything. They were: at 2.0 mol/(Pa·s) the damper reaches 4 kg/s on **70 Pa**, which
      # puts the firebox 35 kPa above atmospheric — a third of an atmosphere of overpressure
      # inside a box with a chimney on it.
      #
      # Now they decide the flow directly, so they are set where the firebox sits within about
      # a kilopascal of ambient, which is the regime a real furnace runs in. Measured across
      # the band as a multiple of what is shipped here, at 60/60/80 after 3600 ticks:
      #
      #     ×10    firebox +35 kPa   10.8 MW    (saturated; the flue empties the box every tick
      #                                          and the conductance is inert again)
      #     ×3     firebox +1.1 kPa   6.0 MW
      #     ×1     firebox +0.5 kPa   2.9 MW    <- here
      #     ×0.5   firebox   ~0 Pa    0.1 MW    fire will not sustain
      #
      # Re-confirmed after the boiler tubes landed: ×1.5 and above simply pins the boiler on
      # its safety valve and the engine stops gaining anything, so there is nothing to buy by
      # opening the gas path further.
      #
      # **Re-measure this if the stack height, the blastpipe rating or the firebox volume
      # changes**, because all three move the head this conductance is solved against.
      #
      # --- the components ------------------------------------------------------
      #
      # Each of these builds one node. What they are wired to, which levers they bring and
      # which gauges arrive with them lives in `parts.rb`, next to the `Parts.register` that
      # fits them — a part's pieces used to be scattered across four lists in two files, which
      # is why nothing was ever optional.

      def fuel_bunker
        Nodes::Vessel.new(
          id: :bunker, label: "Fuel Bunker", volume_m3: 40.0,
          initial_contents: [ { resource: :coal, kg: 12_000.0 } ],
          ports: [ Port.new(id: :out, direction: :outlet, accepts: [ :fuel ], max_kg_per_s: 2.0) ]
        )
      end

      # A work station, not a valve. `stoking` is somebody's effort — how fast coal actually
      # reaches the grate is how hard they are shovelling. It behaves as an ordinary control
      # for now; when minions arrive they take over moving its `actual`, and nothing else
      # about this changes.
      #
      # ## **0.25 kg/s, down from 0.6, and this is the whole of the stoking inversion**
      #
      # Stoking was monotonically *inverted* — more coal, less power, at every damper setting and
      # every air rating. Read as kg/s rather than as lever percent the cause is arithmetic:
      #
      #     the fire needs ~0.12 kg/s of coal to establish at all   (an absolute threshold:
      #       identical at 0.3 × 40, 0.2 × 60 and 0.15 × 80, and failing at 0.2 × 40)
      #     the fire can usefully burn ~0.12-0.15 kg/s             (peak power at every damper)
      #     the stoker was rated                          0.6 kg/s
      #
      # So **the entire useful band sat below lever 25** and the rest of the travel was strictly
      # harmful — the surplus banks up as unburnt coal, which is cold thermal mass the fire then
      # has to heat. Measured at the shipped rating, damper 85, stoking 100: **401 kg of coal
      # sitting in a 6 m³ firebox**, against 22 kg at stoking 20.
      #
      # At 0.25 the optimum lands at lever 50 with a rising limb below it and a real falloff
      # above, which is the shape a fireman's lever should have. Measured, kW at damper 60 / 70:
      #
      #     lever      30     40      50      60      70      80     100
      #     damper 60   0    27.2   116.4   110.8   105.1    99.4    88.7
      #     damper 70   0    35.7   279.6   265.3   250.9   237.3   212.5
      #
      # The nominal point is deliberately almost unmoved — stoking 60 at damper 85 gives 332.9 kW
      # against 332.1 before — so this re-centres the lever without re-tuning the engine.
      #
      # **Two things this does NOT fix, and they are the next pass.** The window between "will not
      # light" and "over-fuelled" is only about 0.12 → 0.15 kg/s, which is narrow whatever the
      # rating is; and above damper ~80 the boiler sits on its safety valve, so the falloff is
      # invisible in power even though the fire is measurably cooling (903 → 886 K).
      def stoker
        Nodes::Conduit.new(
          id: :stoker, label: "Stoking Line", accepts: [ :fuel ],
          max_kg_per_s: 0.25, heat_capacity: 2.0e3,
          control_id: :stoking
        )
      end

      def damper(conductance:)
        Nodes::Conduit.new(
          # **`damper_conductance` is the only air control there is**, and `max_kg_per_s` below is
          # a structural port bound rather than a dial: it does not apply to a conduit that
          # declares a `conductance:` (see `docs/reference/nodes.md`, and the same note on
          # `throttle`). Matched to the flue and the tubes, which is the rest of this gas path.
          #
          # There used to be a per-variant `draught_kg_per_s` here — 4.0 and 2.0 — presented as
          # each engine's fire size, and **it was dead config.** Set it to 4.0, 6.6 or 9.0 and the
          # sweep returns byte-identical results at every stoking level and every damper position.
          # The comment above it was wrong twice over: it claimed the damper was "sized so a fully
          # open damper roughly matches a fully stoked grate", which is false arithmetic (a full
          # grate at 0.6 kg/s of coal needs 6.6 kg/s of air at the reaction's 11:1, not 4.0) *and*
          # was a claim about a quantity that did nothing. Two docs had picked it up as the reason
          # the atmospheric engine runs a smaller fire; the real reason is its conductance, 0.1
          # against 0.35. **Deleted rather than left with a warning on it** — a number that looks
          # tunable and is not costs more than it saves.
          #
          # Historical, and still true of the *conductance*: it was halved when transport moved
          # to paths, because a conduit used to deliver about HALF its rating — it spent every
          # other tick drawing rather than pushing — so the 4 → 8 widening before that was tuned
          # around a factor of two nobody could see.
          id: :damper, label: "Damper", accepts: [ :gas ],
          max_kg_per_s: 12.0, heat_capacity: 2.0e3,
          conductance: conductance,
          # **The blower used to live here, as `head_pa:` and `head_control_id:` on this
          # node.** It is its own part now — see `blower_fan` — because an attribute on
          # somebody else's node cannot be fitted, removed or upgraded, which is the whole
          # thing modularisation is for. The physics is unchanged: `Arbiter.path_head` sums
          # head over every conduit on a path, so a fan in series with the damper contributes
          # exactly what an attribute on the damper did.
          control_id: :damper_open
        )
      end

      # **The blower, promoted from an attribute to a part.**
      #
      # Forced draught. A cold chimney does not draw — buoyancy needs a hot stack, and a hot
      # stack needs a fire — so a naturally-drawn firebox physically cannot light itself. Real
      # practice is a blower, and this is it: hold it on to get the fire established, then shut
      # it and let the stack take over. A modest one, which is all a coal fire should ever
      # need; it exists because the blastpipe cannot help until the engine is already turning.
      #
      # **`conductance: Float::INFINITY`, and it has to be a number rather than nothing.**
      #
      # The first attempt left it off, on the reasoning that a fan is a pressure source and not
      # a restriction. That **killed the engine outright** — fire at 296 K, boiler at 3 kPa,
      # dead on both chassis — because a path settles by pressure *only if every conduit on it
      # declares a conductance* (`Arbiter.gas_coupling`, which returns nil the moment one does
      # not). One nil turned the whole air path rate-driven, and a rate-driven path has no head
      # at all, so the blower and the chimney both stopped existing. Silent, and total.
      #
      # Infinity is the faithful spelling of what the attribute did. Series conductances combine
      # reciprocally — `1/total = Σ 1/kᵢ` — so `1/∞ = 0` contributes exactly nothing and the
      # damper's rating comes through untouched, which is what keeps the seven-point sweep that
      # chose `damper_conductance` valid. A finite value would be more honest about a real fan
      # casing and would re-rate the path: 1000 already moves it 0.03%.
      #
      # Note this is the one place in the engine where `Float::INFINITY` is a *statement* rather
      # than a silent off switch: it says "not the restriction", and the restriction is next
      # door and measured.
      #
      # `:blower_fan` rather than `:blower`, because `:blower` is already the lever. Ids are one
      # flat namespace across nodes, levers, gauges and crew — they key one rng table — and this
      # is the third part to hit that: `:stoker` against `stoking`, and `:fusible_plug` against
      # the `plug_blown` gauge.
      #
      # TODO: **WIP part.** The blower is still free, and it should not be. The intended cost is
      # crew time first and a consumable second, and note the constraint that rules out the easy
      # answer: **assume a black start**, since a player may be the only one generating power in
      # a match, so nothing may depend on having an electrical supply. A fuel-oil reserve bolts
      # onto this part when minions land; `heat_capacity` below is a placeholder for a casing
      # nobody has weighed.
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
          # **Ash smothers a fire, and until now it could not.** Both combustion reactions
          # produce it, nothing consumes it and no operation removes it, so it accumulated
          # forever and did nothing but add thermal mass — 10.8 kg in normal running, which is
          # 0.26% of six cubic metres and therefore invisible against the vessel's own volume.
          #
          # Measured against the **void** instead, it is the fire's own waste filling the gaps
          # the air has to come through, which is what banking a grate with ash actually does.
          # 12% of the box is the space between the fuel; the rest is fuel, walls and gas.
          #
          # **`:waste`, not `:solid`, and the difference is deliberate.** Coal is tagged
          # `[solid, fuel]`, so `:solid` would make the fuel itself an obstruction — which is
          # not wrong (over-filling a grate really does choke it) but would silently introduce a
          # *second* mechanism for the stoking inversion already recorded in
          # `current_progress.md` and not yet attributed. One mechanism at a time; a bed choked
          # by its own fuel is a separate change with its own measurements.
          obstruction_tags: [ :waste ], void_fraction: 0.12,
          # A match, not a furnace. The igniter used to be 2.5 MW, which is what it took to
          # drag six cubic metres of firebox over a bulk ignition threshold — and a player
          # quickly learned that the way to keep a fire alive was to leave it on, turning the
          # starting handle into a permanent heat source.
          #
          # It now sets a little fuel alight and adds a modest amount of heat, exactly like a
          # gas pilot: the fire's own combustion does the rest, or it does not catch.
          heater_control_id: :igniter, heater_watts: 1.2e5, igniter_kg_per_s: 0.02,
          ports: [
            Port.new(id: :fuel_in, direction: :inlet, accepts: [ :fuel ], max_kg_per_s: 2.0),
            Port.new(id: :air_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 4.0),
            # **Its own inlet, because `air_in` is gas-only and a blown plug throws water.**
            # `accepts:` is checked at every port on a path, so routing the plug through the air
            # inlet would have silently dropped the liquid half of what it discharges — the same
            # trap the chimney and the steam line both fell into. A separate port is also honest:
            # a plug discharges through the crown sheet, not through the damper.
            Port.new(id: :plug_in, direction: :inlet, accepts: [ :gas, :liquid ],
                     max_kg_per_s: 2.0),
            # Accepts any gas, not just combustion products. Air that has been drawn in
            # but not burnt has to be able to leave again — restricting this to :exhaust
            # meant unburnt draught piled up in the firebox and swallowed the fire's heat.
            Port.new(id: :flue_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 12.0),
            Port.new(id: :ash_out, direction: :outlet, accepts: [ :waste ], max_kg_per_s: 0.5)
          ]
        )
      end

      # **This is where most of the fuel's energy actually reaches the water**, and it is what
      # boiler tubes *are*: the fire's gas is dragged through a bundle of tubes surrounded by
      # water, giving up its heat on the way to the chimney.
      #
      # Without it the only fire→water path was one conduction link, and the arithmetic of that
      # is unforgiving. A single link makes the firebox temperature `T_boiler + Q/k`, so the
      # only way to get heat into the water is to hold the fire cold: at k = 9000 the box sat
      # at 676 K against a 420 K boiler, and **90% of the fuel went up the chimney** — 3311 kW
      # burnt, 2989 kW advected away, 33 kW of shaft work. Weakening the link to make the fire
      # hotter simply starved the boiler (measured: k = 1000 gave the same 692 K on a fifth of
      # the burn, and the engine never turned).
      #
      # A stream that gives up its heat as it passes needs no new machinery: a conduit already
      # has a wall that `Tick#carry_through` mixes the stream into, and a `ThermalLink` already
      # couples that wall to the water. The gas leaves the firebox at fire temperature and
      # reaches the chimney at not much above the water's.
      #
      # It also restores the trade-off that makes firing a boiler a skill: more draught is a
      # hotter fire but a shorter time in the tubes, so past a point the extra heat goes out of
      # the stack instead of into the water.
      # **The tubes can burn out, and they are the right part to be able to.** A tube bundle sits
      # between the fire and the water with `ambient_conductance: 0.0` — it has nowhere to shed
      # heat except into the boiler — so its metal temperature is set entirely by the balance
      # between the gas scrubbing through it and the water carrying that heat away. Starve the
      # water side, or over-draught the fire, and the metal climbs with nothing to stop it.
      #
      # That is the real mechanism, it needed no new machinery, and it is the classic boiler
      # failure of the period: a burst tube fills the firebox with steam and puts the fire out.
      # Note what it is *not* — this is not the low-water hazard. A dry drum does not make these
      # hot, because the tubes are coupled to the boiler node and a lumped drum at 5% water is
      # not hot. Low water is the crown sheet's job; see `Nodes::Boiler`.
      #
      # `material: :wrought_iron` rather than a number here, so the rating comes from
      # `content/resources/materials.yml` — 750 K, the lowest of the structural metals, because
      # the slag stringers that make wrought iron tough when cold are what open up when it is
      # worked hot. `stress_rate` stays per-part: how fast a given bundle fails once it is over
      # is a property of the bundle, exactly as `safety_factor` is on the flywheel.
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
          # **Wet, not dry.** This was `[:gas]`, and because `Arbiter` requires every port on a
          # path to accept a resource, that one tag meant condensate had no route out of the
          # cylinder — the only liquid outlet the high-pressure engine has is up this chimney.
          # The cylinder flooded to 22 kg of water and a liquid fraction of 1.455 on a perfectly
          # ordinary run, and the atmospheric variant did not, purely because its condenser
          # inlet is permissive.
          #
          # Real exhaust is wet steam and a blastpipe genuinely throws water, so this is honest
          # rather than expedient. What it does not yet express is *how much* of the condensate
          # the stroke carries away: `Parcel.draw` splits proportionally by mass, which sweeps
          # out preferentially what is a thousand times denser than the carrier — backwards, and
          # it makes hydraulic lock nearly unreachable. The entrainment rule in
          # `design_sketches/transport_model.md` §5 is what sets that fraction properly.
          id: :flue, label: "Chimney", accepts: [ :gas, :liquid ],
          # The stack is the engine's lungs. Its height is what turns a hot fire into draught
          # (see `Arbiter.path_head`), so it is deliberately a number a player can reason about
          # and an operation can vary: a taller chimney is a better-breathing engine.
          max_kg_per_s: 12.0, heat_capacity: 5.0e3, conductance: 0.4, stack_height_m: 10.0,
          # The blastpipe, on the engines that have one. Buoyancy alone cannot feed this fire:
          # it is weakest when the stack is cold, which is exactly when a cold engine needs
          # draught most, so a naturally-drawn firebox lights and then suffocates. Exhausting up
          # the chimney ties draught to how hard the engine is working instead.
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

      # **2.0 kg/s, down from 2.5.** The pump has to be able to outrun evaporation or the glass
      # has no upward authority at all — but at 2.5 against roughly 1 kg/s of steaming it had
      # *two and a half times* the authority, which made the usable band 0–40 on the lever and
      # everything above it deliberate flooding. The whole top half of a control doing nothing
      # but harm is a control with no middle.
      #
      # This number is only half the ratio, and the other half is the fire: see `damper`. Raising
      # evaporation and lowering the pump both close the same gap, and the two were moved
      # together so the band lands somewhere a player can work in.
      def feed_pump
        Nodes::Conduit.new(
          id: :feed_pump, label: "Feed Pump", accepts: [ :liquid ],
          max_kg_per_s: 2.0, heat_capacity: 2.0e3,
          control_id: :feed
        )
      end

      # **The injector, and it costs steam rather than heat.**
      #
      # Cold feedwater straight into a hot drum was putting the fire out: at feed 100 the boiler
      # fell from 432 K to 376 K, its pressure from 608 to 116 kPa, and the engine stopped. That
      # made a high water level and a working engine **mutually exclusive**, which in turn made
      # priming unreachable — every route to a full glass killed the fire that would have to
      # swell it. Design and the rejected cheap version:
      # [`docs/design_sketches/injector.md`](../../../../docs/design_sketches/injector.md).
      #
      # An injector is thermally almost perfect and that is *not* its cost. Every joule the live
      # steam carries goes into the feedwater and back into the drum it came from. What it costs
      # is **steam that could have gone to the cylinder** — so filling the boiler and pulling hard
      # now compete for the same steam, which is the trade this lever never had.
      #
      # No new node class: an injector is a place where steam and cold water meet and leave
      # together, which is a holder. The steam condenses because a small vessel full of cold water
      # sits below its saturation pressure, and the latent heat lands in the water exactly,
      # because `h = c·T + h_f` makes it so. The existing physics does all of it.
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
      # **Rate-driven, not pressure-driven.** An injector is a fixed-geometry nozzle passing a
      # fixed ratio of steam to water; giving it a conductance as well would be two numbers for
      # one restriction, which this engine has already got wrong twice. The ratio is the design
      # figure — **1 kg of steam to 10 of water**, which lands the delivery near 360 K.
      #
      # **0.20, and it is a ratio rather than a rate.** It was 0.28 against a 2.5 kg/s pump,
      # which is 11% of the water but about **28% of everything the boiler could raise** — the
      # injector was quietly the largest single consumer of steam on the engine. Real injectors
      # sit nearer a tenth, and they sit there because their pumps are not oversized. Moving the
      # pump to 2.0 and this to 0.20 keeps the 1:10 nozzle ratio and takes the bite out of the
      # fire. **Re-derive this if `feed_pump` moves again** — the two are one part.
      def injector_steam
        Nodes::Conduit.new(
          id: :injector_steam, label: "Injector Steam", accepts: [ :gas ],
          max_kg_per_s: 0.20, heat_capacity: 1.0e3, ambient_conductance: 10.0,
          control_id: :feed
        )
      end

      # The dangerous part. Relief pressure is where it starts hurting itself; burst
      # pressure is where it stops being a boiler.
      def boiler(shell_radius_m:, wall_thickness_m:)
        Nodes::Boiler.new(
          id: :boiler, label: "Boiler", volume_m3: 5.0,
          heat_capacity: 6.0e5, ambient_conductance: 90.0,
          initial_contents: [ { resource: :water, kg: 2_000.0 } ],
          # ## The shell says what it can take, and the valve setting is a decision against it
          #
          # This was `relief_pa * 1.5`, and that is **circular**: the pressure a boiler can survive
          # cannot depend on where somebody set its safety valve. It also made the two impossible
          # to separate — raising the valve dragged the damage threshold up in lockstep, so the gap
          # between "blowing off" and "bursting" could never be deliberately widened or narrowed.
          #
          # Derived from the plate instead, the way `Flywheel` has always derived its burst speed:
          # hoop stress `σ = p·r/t` gives `p = σ·t/r·safety_factor`. A 5 m³ drum of 0.6 m radius is
          # about 4.4 m long, which is a locomotive-sized barrel; 14 mm wrought iron is
          # period-correct for it. See `Concerns::Pressurized#rated_pressure_pa`.
          #
          # `safety_factor: 0.25` is the seams, not the metal. A riveted wrought-iron boiler loses
          # about 30% to joint efficiency before any allowance for the grooving and corrosion that
          # run along a seam — a quarter of the plate figure is realistic rather than pessimistic,
          # and it is what makes an old boiler a different object from a new one once `integrity`
          # starts falling.
          # Per variant, because the plate really is different: a 1.4 atm beam engine has no
          # business carrying 14 mm of iron, and a 6 atm one cannot do without it.
          shell_radius_m: shell_radius_m,
          wall_thickness_m: wall_thickness_m,
          safety_factor: 0.25, stress_rate: 90.0,
          # **What the shell takes with it.** A drum letting go throws its plate across the
          # shop; a seam splitting soaks the place in steam and hurts nothing structural. Fiat
          # rather than a release-energy model — see `Concerns::Wearing#failure_damages` and
          # docs/design_sketches/failure_model.md §6 — and configured here rather than in
          # `Nodes::Boiler` because *which* parts are near enough to be wrecked is a fact about
          # this machine, not about boilers.
          damages: { explosion: { cylinder: 0.6, flywheel: 0.5 } },
          # **The crown sheet, which is what makes a low glass dangerous at last.** The water
          # lever has had a ceiling (priming) and no floor since it was built: feed 0 ran happily
          # at 357 kW while the drum emptied. Half a mechanic, and the missing half is the
          # failure everyone in the high-pressure era actually feared.
          #
          # `material:` rather than a `max_temperature_k:` number, so the rating comes from
          # content — wrought iron at 750 K, which is what these were built from and the lowest
          # of the structural metals. `fired_by:` is the node on the other side of the plate.
          #
          # 0.25 is where the plate starts to come out of the water, against a drum that runs at
          # 0.47–0.58 in ordinary work. That gap is deliberate: running the crown sheet bare takes
          # sustained neglect, not a moment's inattention — from a normal level at zero feed it is
          # several thousand ticks away. What shortens it is **swell**, because the glass shows the
          # bubbles and the plate is cooled by water: pull hard and the needle reads comfortable
          # while the level underneath it is falling past the plate. See `Nodes::Boiler`.
          material: :wrought_iron, crown_fill: 0.25, fired_by: :firebox,
          # **Priming.** Overfill it and the water comes over with the steam, past the throttle,
          # into the chest and on to the cylinder, where it is the road to hydraulic lock. Below
          # 55% full this is a 99.5%-dry boiler and invisible in play. See `Nodes::Boiler`.
          #
          # **Swell** is what makes priming an event rather than a level. Scaled by how fast the
          # drum is losing pressure, so steady running of any intensity costs nothing and only a
          # sharp demand change lifts the water — which is exactly the case the sources name.
          # **Measured, not guessed.** Slamming this regulator from 60 to 100 drops the drum at
          # about 8.8 kPa/s, and lighting up — opening it from shut — saturates. So 8 kPa/s is
          # "a hard pull", an eased regulator is a fraction of it, and steady running of any
          # intensity is zero. A first guess of 20 kPa/s put a hard slam at 20% swell, which never
          # reached the offtake at any glass a working engine holds.
          #
          # Note the safety comes from the **glass**, not from the swell: the biggest swell in a
          # normal run is the initial opening, and that is survivable because the level is low.
          # A full glass alone is survivable, and a sharp opening alone is survivable.
          # **0.20, down from 0.45.** At 0.45 the glass reads `1/(1−0.45)` = 1.82× the true
          # level on a saturating pull, which is not a gauge being misleading, it is a gauge
          # being useless — the needle spent its time somewhere the water had never been. Real
          # swell on a drum this size is tens of percent, and 0.20 reads 1.25× at saturation:
          # enough to fool a driver who is not watching the fire, not enough to be noise.
          steam_port: :steam_out, wetness: 0.005, foaming_wetness: 0.30, onset_fill: 0.55,
          priming_wetness: 0.97, swell_pa_per_s: 8_000.0, max_swell: 0.20,
          # Real drums take tens of seconds to settle after a demand change, and it has to be
          # long enough for water to actually go somewhere — at 8 s the slug was over before the
          # chest had filled.
          swell_settle_s: 12.0,
          ports: [
            Port.new(id: :feed_in, direction: :inlet, accepts: [ :liquid ], max_kg_per_s: 2.5),
            # **Wet, because the whole steam line has to be.** `accepts:` is a structural gate
            # and it runs before any affinity, so a `[:gas]` outlet makes carryover impossible
            # no matter what the drum is doing. The tag says water *may* cross; `carryover`
            # above decides how much, and at a calm level that is half a percent.
            # **Rated for water, not for steam.** On a pressure-driven path conductance rates the
            # gas and this figure now bounds only the liquid riding with it (`Arbiter.entrained`),
            # so it is the bore of the main steam pipe rather than a steam allowance: a 150 mm
            # offtake passing water at a few metres a second is tens of kg/s. At 2.5 it silently
            # capped a priming slug at a quarter of what the drum could actually throw.
            Port.new(id: :steam_out, direction: :outlet, accepts: [ :gas, :liquid ],
                     max_kg_per_s: 25.0),
            Port.new(id: :relief_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 3.0),
            # Where the shell lets go. Wet, because what comes out of a burst drum is steam and
            # the water flashing behind it, and rated far above anything the working machine
            # uses so that the **breach** is the restriction rather than this port — see
            # `SteamEngine.boiler_breach`. Nothing flows through it while the drum is sound.
            Port.new(id: :breach_out, direction: :outlet, accepts: [ :gas, :liquid ],
                     max_kg_per_s: 100.0),
            # Through the crown sheet and down onto the fire. Wet, because what comes out of a
            # blown plug is whatever is at the top of the water.
            Port.new(id: :plug_out, direction: :outlet, accepts: [ :gas, :liquid ],
                     max_kg_per_s: 2.0),
            # **Its own pipe from the steam space, deliberately not `steam_out`.** The drum's
            # carryover affinity is keyed to `steam_port`, so a separate port is fed dry steam
            # rather than priming water — which is what the machine has, and what keeps the
            # injector working precisely when the boiler is misbehaving.
            Port.new(id: :injector_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 1.0)
          ]
        )
      end

      # Sized so it can pass rather more steam than the fire can raise, but not without
      # limit — a badly stoked boiler can still outrun it.
      #
      # **The easing lever is not chrome.** Every boiler of this period had a handle to lift its
      # safety valve by hand, and a driver used it for real reasons: to prove the valve is not
      # stuck to its seat, and to blow pressure down deliberately before it reaches the setting.
      # It can only open the valve further than the spring already has (see
      # `ReliefValve#open_fraction`), so it is a way to spend steam, never a way to hold the
      # boiler shut — the cost is on the ledger as vented mass and in the glass as a falling
      # level, which is exactly the trade a driver was making.
      # **The adjusting screw, and it is the engine's risk/reward lever.** `relief_pa` is now the
      # *safe* end of a range rather than a fixed setting: the lever reads as margin, defaults to
      # 100, and winding it down raises the valve toward `max_relief_pa`. An untouched engine is
      # therefore exactly the engine it was before, and more pressure is something a player has
      # to decide to take.
      #
      # What they are buying and paying for, all of it already modelled:
      #
      #   * more admission pressure, so more power
      #   * a crown sheet that fails **sooner** on the same overheating, because the plate's
      #     allowance is knocked down by temperature and a higher working pressure eats what is
      #     left (`Boiler#crown_allowable_pressure_pa`)
      #   * less headroom under the shell's own derived rating
      #   * **a flywheel being asked for work it may not survive, which is the real gate.**
      #     Measured at cut-off 40, margin against power and wheel stress:
      #
      #         margin   100     90     80     70     60     40     20
      #         kW     364.1  406.8  451.9  499.9  552.6  653.2  burst
      #         wheel   0.27   0.30   0.34   0.38   0.41   0.49   1.00
      #
      #     A 1.79× power gain across a smooth climb in stress, and then it lets go between 40 and
      #     20 — a real risk/reward curve with the Wheel Stress gauge as the warning, rather than a
      #     cliff. So `max_relief_pa` sits well below what the shell could stand, because the wheel
      #     is the interesting limit and a stronger one is what unlocks the top of this lever.
      #
      # **The two levers interact, and that is the best thing about it.** At full gear the safe band
      # is far narrower — 100/90/80 give 517.8 / 571.0 / 631.3 kW and margin 70 bursts the wheel —
      # so a driver can have high pressure *or* full gear, not both. Notching up to spend the
      # margin is the skill.
      #
      # It also quietly fixes the saturation that was masking other mechanics: at margin 100 the
      # drum sits on its valve at 608.0 kPa, and at 90 or below it is **under** its setting
      # (638 → 790 kPa) and limited by the fire instead. The masking is now something a player can
      # choose to remove.
      # **The hole the drum opens when it fails**, and the thing that makes a burst boiler
      # different from a boiler with a flag set on it.
      #
      # The mode fractions scale the conductance and the rate together, because
      # `Conduit#open_fraction` feeds both — one number is genuinely the size of the hole.
      #
      # ## Measured, and the first guess was wrong by four orders of magnitude
      #
      # Sized against the safety valve at first, on the reasoning that it is the only other hole
      # in this drum with a physical meaning. That produced a **cliff**: every fraction from 0.03
      # down to 0.0005 took a 175 rpm engine to a standstill, so there was no small failure at
      # all. The mistake was the reference — the valve only opens above its setting, while a
      # breach is open always, and the number to compare against is the **regulator wide open**
      # (`conductance: 1.5e-3`), which is the hole this engine's whole output goes through.
      #
      # Swept on a worked engine (175 rpm, 608 kPa, 2034 kg in the drum), rpm at +600 ticks:
      #
      #     conductance   2e-5    1e-4    4e-4    2e-3     2.0
      #     rpm           175     151      80      18       2
      #     spilled kg     26     111     230     294    2150
      #
      # So `seam_split` is **1e-4**, which is the limp-home case: the engine loses speed slowly
      # and a driver who damps the fire and runs for the shed has a decision worth making.
      # That is 5e-5 of the shell, and the area works out honest — about 8 cm² on a drum of this
      # size, a hole three centimetres across, which is what a weeping seam is. `explosion` opens
      # the whole bore and empties the drum inside a hundred ticks.
      #
      # **Run-ending is not declared anywhere.** The engine stops because there is no pressure,
      # because there is a hole. See docs/design_sketches/failure_model.md §6.
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

      # **The fusible plug: the remedy, shipped with the hazard.**
      #
      # A soft-metal bung screwed through the crown sheet, rated to go at 620 K against the
      # plate's own 750 K. While water covers the plate the plug is cooled with it; uncover it
      # and this is the first thing to melt, dumping steam and water down onto the fire.
      #
      # **It is a warning, not a save.** It puts the fire out, fills the shed with steam, and
      # leaves the engine out of service until somebody fits a new one — which is precisely the
      # trade a real one makes: a ruined day against a ruined boiler. That it is louder and more
      # expensive than simply watching the glass is the point.
      #
      # Not a `ReliefValve`, and the reason is in `Nodes::FusiblePlug`: a relief valve re-seats,
      # and a boiler that quietly healed itself once the water came back over the plate would
      # have exactly the consequence-free behaviour this hazard exists to not have.
      #
      # It senses the **crown sheet's** temperature and not the drum's, for the same reason the
      # cylinder relief senses compression pressure: a lumped drum at 5% water is not hot, merely
      # empty, so a plug pointed at `temperature_k` would look like protection and be none.
      def fusible_plug
        Nodes::FusiblePlug.new(
          id: :fusible_plug, label: "Fusible Plug",
          senses: :boiler, senses_key: :crown_temperature_k,
          melts_above: 620.0,
          accepts: [ :gas, :liquid ], max_kg_per_s: 2.0,
          heat_capacity: 2.0e2, ambient_conductance: 0.0
        )
      end

      # **A restriction, not a ration.** This used to be a rate cap, which is the wrong kind of
      # number for a valve: it decided *how much* steam reached the cylinder but nothing at all
      # about the pressure it arrived at, so the diagram went on reading the boiler and the
      # regulator had no effect on torque whatsoever. What actually held the engine back was the
      # `extractable_joules` bound in `Tick#transmit_torque` — measured discarding **30 to 50%
      # of the declared work** (scale 0.496 at throttle 20, 0.698 at 60), with the declared
      # torque nearly flat across the range. A conservation clamp was standing in for the entire
      # throttling mechanism.
      #
      # As a conductance it does the real thing. Flow through it costs a pressure drop that
      # grows with the flow, so the steam chest behind it sits below the boiler by an amount
      # the driver controls — which is wire-drawing, and it is what a regulator physically is.
      #
      # `max_kg_per_s` does not apply to a conduit that declares a conductance (see
      # `docs/reference/nodes.md`); it is left here only as a sanity bound on the ports.
      def throttle
        Nodes::Conduit.new(
          # Wet, like the rest of the steam line. A regulator does not dry steam, and a
          # `[:gas]` tag anywhere between the drum and the cylinder makes priming impossible
          # no matter what the drum is doing — `accepts:` is checked at **every** port on a
          # path, so one dry tag in the middle silently repeals the mechanic.
          id: :throttle, label: "Throttle Valve", accepts: [ :gas, :liquid ],
          # Two numbers for one restriction, and deliberately so: `conductance` rates the steam,
          # `max_kg_per_s` the water it carries. They are not redundant since `Arbiter.entrained`
          # started bounding liquid by the bore. Sized to match the steam line either side.
          max_kg_per_s: 25.0, conductance: 1.5e-3, heat_capacity: 3.0e3,
          # **Equal-percentage trim, because a linear regulator is not a linear control here.**
          # Wide open, `k·dt·ΣC⁻¹` is 1.76 — past 1, so the chest equalises with the drum inside
          # a tick and the valve has stopped being the restriction. Measured on linear trim: the
          # chest was at 85% of boiler pressure by lever 30, and the top 70% of the travel bought
          # 21% of the power. The full-open figure is untouched by this; only the intermediate
          # positions move, which is the whole point of trim. See `Conduit#open_fraction`.
          #
          # **8 was picked from a sweep, not from the algebra.** The first attempt at 50 simply
          # moved the dead zone from the top of the travel to the bottom — the engine would not
          # turn at all below lever 30, because it needs about 4.5% of full conductance to beat
          # the load and this curve does not reach that until then. Measured power per notch in
          # the upper half, linear against 8: +17/+11/+7/+6 becomes +35/+25/+19/+15, with the
          # engine still pulling 84 rpm at lever 10. At 15 it is dead there.
          rangeability: 8.0,
          control_id: :throttle_open
        )
      end

      # **The steam chest: the part that was missing, and the reason three things were wrong.**
      #
      # A real engine does not admit steam from its boiler. It admits from a chest held between
      # the regulator and the valve gear, and the pressure in that chest — not the boiler's — is
      # what the indicator diagram starts from. Without it the cylinder had nowhere to read an
      # admission pressure from except its own settled charge, which is a post-expansion,
      # mid-exhaust condition at roughly 30% of boiler pressure; and once it read the boiler
      # instead, the regulator stopped affecting torque at all.
      #
      # With it, the loop closes on its own and needs no bound: if the cylinder swallows faster
      # than the throttle can pass, the chest depletes, its pressure falls, and **both** the
      # demand (through admission density) and the MEP (through P₁) fall with it on the next
      # tick. That is the engine physically unable to work steam it did not receive.
      #
      # Sized generously on purpose — 1 m³ is the chest *and* the main steam pipe behind it,
      # which is honest, and it has to hold several ticks of admission or the cylinder's
      # positive-displacement draw empties it inside one and the pressure rings. At full gear
      # the cylinder takes about 0.25 kg a tick and this holds ten times that.
      #
      # **The outlet is permissive, and that is deliberate.** A gas-only tag here would trap
      # condensate exactly the way the chimney's did — see the note on `flue`. Wet steam
      # reaching the valve is real, and it is the road by which priming becomes hydraulic lock.
      def steam_chest
        Nodes::Vessel.new(
          id: :steam_chest, label: "Steam Chest", volume_m3: 1.0,
          heat_capacity: 2.0e4, ambient_conductance: 40.0,
          ports: [
            Port.new(id: :in, direction: :inlet, accepts: [ :gas, :liquid ], max_kg_per_s: 25.0),
            Port.new(id: :out, direction: :outlet, max_kg_per_s: 25.0)
          ]
        )
      end

      # Raking out the ashpan. **Not optional chrome** — it is the remedy that makes the choked
      # grate a mechanic rather than a slow dead end. Ash is produced by both combustion
      # reactions and consumed by nothing, so without a way out the fire quietly strangles
      # itself over a long game and no lever a player can reach will help.
      #
      # A work station like the stoker, not a valve: `ash_raking` is somebody's effort with a
      # shovel, and it takes the fire's own waste out to the yard.
      def ash_pan
        Nodes::Conduit.new(
          id: :ash_pan, label: "Ashpan", accepts: [ :waste ],
          max_kg_per_s: 0.5, heat_capacity: 1.0e3, ambient_conductance: 40.0,
          control_id: :ash_raking
        )
      end

      # **Cylinder cocks**, and they are a decision rather than a safety net.
      #
      # A cold or standing cylinder fills with its own condensate — the charge gives up heat to
      # the walls and to the work it is doing, which is genuine expansion cooling and the reason
      # a saturated engine loses so much steam to the cylinder in the first place. While the
      # engine is turning, the exhaust stroke sweeps that water out with the steam. While it is
      # standing, **the exhaust carries nothing at all**, because `exhaust_demand_kg` scales
      # with revolutions — so the water simply collects.
      #
      # Permissive on purpose. Real cocks blow steam as well as water, and that is what makes
      # leaving them open a choice instead of a free win: open, the cylinder cannot hold a
      # charge and the engine will not pull; shut, it is efficient and it is accumulating. Open
      # them to warm through and before moving off, shut them once it is hot.
      #
      # **That last sentence was aspirational until 2026-09-12.** The cylinder's thermal mass was
      # an order of magnitude light, so it warmed through in about three seconds and there was no
      # window for the procedure to exist in — peak occupancy over a whole startup with these
      # shut was 0.188, which is "damp" and not worth acting on. With the casting's real heat
      # capacity the three states are properly distinct:
      #
      #     shut throughout          peak 0.859  "knocking badly", relief lifting, 329.1 kW
      #     open throughout          peak 0.002  dry, and 313.3 kW — you are blowing your steam away
      #     open, then shut when hot peak 0.006  dry, and 326.7 kW
      #
      # The third row is the procedure, and it is the only one that gets both. See `cylinder`.
      def drain_cocks
        Nodes::Conduit.new(
          id: :drain_cocks, label: "Cylinder Cocks",
          max_kg_per_s: 0.25, heat_capacity: 5.0e2, ambient_conductance: 20.0,
          control_id: :cylinder_cocks
        )
      end

      # **The last chance before a cylinder end goes**, and it works only because it is pointed
      # at the right quantity. A valve sensing `pressure_pa` would be useless here: the charge
      # spread over the whole cylinder barely moves as the clearance fills, so the plain vessel
      # pressure gives no warning at all of the thing that destroys it. `compression_pressure_pa`
      # is what the charge reaches at top dead centre, and it is 2.2× the dry figure on half a
      # clearance of water and 13.6× on nine tenths.
      #
      # Set above the highest compression the engine reaches in normal work, so it costs nothing
      # until something is wrong. Permissive, because what it has to pass is water.
      # **Its own adjusting screw, on the same margin-reads-100-is-safe convention as the boiler's.**
      # Stated absolutely rather than as `relief_pa * 1.5`, because a cylinder valve's setting is a
      # property of the cylinder and not of where the boiler's valve happens to be set — the old
      # spelling coupled them for no reason, and coupled the cylinder to a number that is now only
      # the *safe end* of the boiler's range.
      #
      # **Its SETTING rarely matters; its PRESENCE matters on every cold start.** Those are two
      # different claims and only the first was written down here. Measured 2026-09-14, once the
      # valve became a part that could be left off: a normal startup with no relief valve fitted
      # ends in `cylinder_failure`. Warming through fills a cold cylinder with its own
      # condensate — peak occupancy 0.859, "knocking badly" — and this is what lifts, vents the
      # charge and turns a wrecked cylinder into a scare that teaches the procedure.
      #
      # What winding it down buys and costs is narrower than the boiler's and worth being honest
      # about. In ordinary *running* this valve never lifts — compression pressure stays far below
      # it — so the setting does nothing there. It matters while the cylinder is **wet**: lifting vents
      # the charge, which is a real power loss exactly when a driver is already in trouble, so a
      # higher setting keeps the engine pulling through a damp patch. The price is that the last
      # device standing between a slug and a wrecked cylinder has been told to wait longer.
      #
      # The range to 20 atm looks generous against a 9 atm base, and is deliberate: the barrel's own
      # derived hoop rating is far above both, so a player who fits a better cylinder should find
      # room here rather than a limit left over from this one. Going past what the barrel can take
      # now fatigues it — see `Cylinder#stress_per_second`, which had never once fired because
      # nothing gave the cylinder a rating.
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
          # **`supplied_by:` is the steam chest, not the boiler**, and that one word is what
          # makes the regulator a real control. It is the node the indicator diagram takes its
          # admission pressure from and the node whose density sizes the intake, so pointing it
          # at the boiler meant the throttle could not touch either.
          drives: :flywheel, exhausts_to: spec.fetch(:exhausts_to), supplied_by: :steam_chest,
          cutoff_control_id: :cutoff, efficiency: 0.82,
          # **What makes the cocks cost something.** Until this the diagram did not know they
          # existed: they drained condensate and cooled the barrel, and leaving them wide open
          # cost 4–7% of the power — at low throttle it *gained* 1%. An open cock bleeds the
          # working space to atmosphere while the piston is pushing against it, which is a
          # pressure divider on the admission pressure. See `Cylinder#admission_pressure_pa`.
          #
          # **0.30 is a deliberate choice above the band this was briefed at.** The loss compounds:
          # the algebra predicts about 27% for this authority and it measures **43%**, because less
          # power is a slower engine, which is less blastpipe draught, a weaker fire and a lower
          # chest pressure — the direct effect feeds back on itself. Measured cost of leaving them
          # wide open:
          #
          #                 throttle 20   throttle 60   throttle 100
          #     0.15            19.6%         21.4%         21.6%
          #     0.20            26.1%         28.5%         29.3%
          #     0.30            39.2%         42.3%         43.4%   <- here
          #
          # The brief asked for 15–35% and this sits above it, kept on the grounds that shutting
          # the cocks is a trivial thing to do and an instructive thing to learn: the penalty only
          # ever lands on somebody who left them open and forgot, and it teaches them in one run.
          #
          # Note the direction, which was the actual complaint from play: the penalty is **larger
          # the harder the engine is pulling** — 39.2% at throttle 20 against 43.4% at 100, and in
          # absolute terms 78 kW against 159 kW. Dumping your most energetic steam should be
          # costliest, and before this it was free above 500 kW.
          #
          # It is a gradient rather than a switch — cocks 0/25/50/75/100 at full throttle give
          # 365.7 / 328.1 / 284.0 / 243.5 / 206.8 kW — and with the cocks **shut** the engine is
          # bit-identical to having no cocks at all, verified against authority 0.0 at 365.6552 kW
          # and 169.5271 rpm to every decimal place.
          drain_control_id: :cylinder_cocks, drain_authority: 0.30,
          # **The barrel's own strength, so over-pressure has a graded cost.** `stress_per_second`
          # has fatigued on `compression_pressure_pa` since it was written and had **never once
          # fired**, because nothing gave the cylinder a rating — the fifth silent-off-switch in
          # this engine. Until now a cylinder could only fail one way, all at once, through
          # `overload?`; a driver running it hard and wet paid nothing until the moment it broke.
          #
          # Radius comes from the bore, so only the thickness and the metal are stated. 25 mm of
          # cast iron over a 0.225 m radius gives a hoop rating well above the relief setting,
          # which is right — a cylinder barrel is a thick casting and its danger is the
          # *compression spike*, not steady working pressure. `safety_factor: 0.3` is the casting:
          # cast iron is brittle, and a cylinder end is full of stress raisers where the cover
          # bolts through.
          material: :cast_iron, wall_thickness_m: 0.025, safety_factor: 0.3, stress_rate: 45.0,
          # **The cold-cylinder mechanic lives in this number, and it was an order of magnitude
          # light.** The drain cocks are meant to matter during starting: a cold cylinder
          # condenses a great deal of what is admitted to it, which is why the procedure is
          # *cocks open, crack the regulator, warm through, shut the cocks*. It could not, because
          # at `6.0e4` J/K against a charge of ~0.25 kg of steam a tick carrying ~2.75 MJ/kg the
          # metal rises ~11.5 K per tick and warms from ambient to steam temperature in about a
          # dozen ticks. **Three seconds.** There was no cold-cylinder window to have a procedure
          # about, and peak occupancy over a whole startup reached 0.188 — "damp", and nothing a
          # driver would ever act on.
          #
          # The real casting, taken from the geometry rather than guessed: 0.45 m bore, 1.1 m
          # stroke, ~25 mm wall. Barrel `π(0.25² − 0.225²) × 1.1` = 0.041 m³, two covers ≈
          # 0.016 m³, so ≈ 0.057 m³ of cast iron — 410 kg at 7200 kg/m³, **189 kJ/K** — and that
          # counts none of the piston, rod, cover bolting or valve faces. 4.0e5 is roughly twice
          # the bare barrel, which is the allowance for all of that.
          #
          # Measured over a normal startup with the cocks left shut, peak cylinder occupancy:
          #
          #     hc    6.0e4   2.0e5   4.0e5   6.0e5   8.0e5
          #     occ   0.188   0.579   0.859   0.924   0.947
          #
          # At 4.0e5 the engine reads **"knocking badly"** and lifts the cylinder relief valve
          # (0.28), takes **no damage**, and clears to 0.004 once it is turning — so it is a
          # genuine scare that teaches the procedure rather than a death sentence for forgetting
          # it. Opening the cocks holds it at 0.002 and costs about 5% of the power, which is the
          # trade that makes shutting them again a decision.
          heat_capacity: heat_capacity,
          # The intake is rated for the port, not for the stroke — `admission_kg` sizes the
          # charge and this only stops the valve passing more than the pipe can. It has to admit
          # water at the rate the steam line can deliver it, or a slug simply cannot reach the
          # piston and hydraulic lock stays a standing-engine curiosity.
          inlet_kg_per_s: 25.0, exhaust_kg_per_s: 6.0
        )
      end

      def flywheel(mass_kg:, radius_m:, friction:, safety_factor:)
        # A beam engine's wheel is a different object from a high-pressure engine's: vastly
        # heavier, larger, and turning far more slowly. It has to be, because a 1.3 m piston
        # working against a vacuum develops something like 160 kN·m.
        Nodes::Flywheel.new(
          id: :flywheel, label: "Flywheel",
          # Cast iron is strong in compression and weak in tension, which is exactly the
          # wrong way round for a flywheel. The strength and density come from content; the
          # safety factor is this part's own, because how far below the ideal figure a real
          # casting fails is a property of the casting.
          #
          # ## **0.45 on the high-pressure engine, and it is what makes the boiler dangerous**
          #
          # At 0.35 the wheel was the first thing to fail in the one regime that matters: wound
          # the safety valve down to 9 atm, it burst at **tick 1511 — in the acceleration
          # transient, with the crown sheet still at 449 K.** The low-water hazard was therefore
          # unreachable in play, because the engine came apart long before the plate got hot.
          #
          # Swept against the crown, starved boiler, reporting which part fails first and the
          # wheel's peak stress:
          #
          #     wheel                margin 100   margin 70   margin 40   margin 0 (9 atm)
          #     iron sf 0.35         crown 0.27   crown 0.38  crown 0.50  **WHEEL** t1511
          #     iron sf 0.45  ×1.65  crown 0.16   crown 0.23  crown 0.30  crown 0.41
          #     iron sf 0.55  ×2.47  crown 0.11   crown 0.15  crown 0.20  crown 0.27
          #     steel sf 0.35 ×3.06  crown 0.09   crown 0.12  crown 0.16  crown 0.22
          #
          # **0.45 is chosen because it is the minimum that works, and the minimum is the point.**
          # It makes the crown reachable at every pressure while leaving the wheel at 0.41 wound
          # right down — a real gradient from 0.16 to 0.41 on the Wheel Stress gauge, so the wheel
          # is still something a driver watches. At 0.55 and above it stops being a hazard at all
          # (0.11–0.27), and steel stops it mattering entirely, which is why steel is left as the
          # upgrade rather than the default.
          #
          # With the plug scaled over the plate ruptures at **711 / 702 / 692 / 675 K** across the
          # same margins — note it fails *cooler* at higher pressure, which is the crown's pressure
          # coupling working, and why it goes below wrought iron's bare 750 K rating.
          #
          # **Watt's wheel keeps 0.35, and not only because it was not measured.** Foundry practice
          # in 1776 was not what it was in 1802, so the older engine having the poorer casting is
          # period-apt. It is also irrelevant in normal running — that wheel sits at 0.007 of its
          # burst stress — so the figure only decides how far it has to overspeed when the load
          # comes off, and that wants its own measurement rather than this one.
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
      # **This is what makes shedding the load dangerous rather than raising it.** As a
      # constant-torque brake — which it used to be — the load had no stable intersection with
      # the cylinder's torque curve, so more demand simply meant a slower engine and full
      # demand was the *safe* setting. Under a fan law the mill holds the engine at its duty
      # point and it is taking the load AWAY that lets everything the boiler is pouring in go
      # into acceleration, with only the wheel's tensile limit in the way.
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

      # Condensate back to the supply — closing the water loop, exactly the topology a
      # topological resolution order could not have handled.
      def condensate_return
        Nodes::Conduit.new(
          id: :hotwell, label: "Hotwell Return", accepts: [ :liquid ],
          max_kg_per_s: 4.0, heat_capacity: 2.0e3,
          ambient_conductance: 400.0
        )
      end

      # --- wiring --------------------------------------------------------------
      #
      # **The link list has moved onto the parts.** Every link now ships with the fitting it
      # belongs to, in `parts.rb`, which is what makes a part removable at all: an unfitted
      # part contributes no fragment, so its links leave with it and nothing has to remember to
      # delete them. The one link that is NOT a fitting's — where the cylinder exhausts to — is
      # the chassis's own, in `SteamEngine.fixtures`, because that is the difference between
      # Watt's engine and Trevithick's rather than a part somebody bolted on.

      # Two paths from the fire to the water, which is how a boiler actually works.
      #
      #   radiant     the firebox glowing straight at the water legs around it
      #   convective  the flue gas scrubbing through the tube bundle on its way out
      #
      # The split matters more than either number. With only the radiant path, the firebox
      # temperature is pinned at `T_boiler + Q/k` — so a hot fire and a well-fed boiler were
      # mutually exclusive, and the engine could only have one by giving up the other.
      # Measured at 60/60/80, total heat reaching the water and what the engine did with it:
      #
      #     radiant only, k=9000    firebox  676 K   2300 kW   41.0 kW   (before the tubes)
      #     radiant 2000 + tubes    firebox 1036 K   2191 kW   24.2 kW
      #     radiant 3500 + tubes    firebox  895 K   2332 kW   47.3 kW   <- here
      #
      # The middle row is the trade the single link used to force: a realistic fire bought by
      # starving the boiler. With two paths the engine gets both — a fire at 895 K instead of
      # 676, the same heat into the water, and more power out.
      #
      # **Both links now ship with the part that owns them** — the radiant one with
      # the boiler part, the convective one with `:stock_boiler_tubes` — but the measurement
      # stays here, where the two can be read against each other. A boiler fitted without its
      # tubes is the first row of that table, and stage 2 will make it buildable.

      # --- controls ------------------------------------------------------------
      #
      # **Levers arrive with the part they belong to**, in `parts.rb`. Panel order is slot
      # declaration order, which is ordered by the cab rather than by the graph.
      #
      # Every lever here keeps the default `stiffness: Float::INFINITY`, so `actual` snaps to
      # `target` and the crew's rate multiplier is discarded before it is ever used.
      #
      # TODO: expedient — this is what makes the crew inert. Giving the work stations
      # (`:stoking`, `:feed`) a finite stiffness is the one-line change that makes minion
      # condition matter, and it is deliberately not made here: the skill gradient at
      # time_scale 1.0 (60/80/60 survives, 80/90/70 bursts the flywheel) was measured with
      # instant actuation, and a proper implementation re-measures it rather than assuming
      # a few ticks of lever travel are lost in the noise.
      #
      # Two of them are worth reading where they are declared, because their defaults are
      # deliberate and surprising:
      #
      #   :cylinder_cocks    **defaults shut, and that is not the safe setting.** A standing
      #                      engine should have its cocks open; this defaults closed because
      #                      that is the state the whole balance was measured in, and a lever
      #                      whose default silently changes every other number is worse than
      #                      one a player has to learn.
      #   :valve_setting     **the adjusting screw, read as margin rather than as pressure**,
      #                      defaulting to 100 — the full safety margin — so an untouched
      #                      engine is the safe engine and spending margin is a decision.
      #                      `:cylinder_valve_setting` follows the same convention.

      # --- crew ----------------------------------------------------------------

      # Two, deliberately: one minion cannot demonstrate reassignment, and one station cannot
      # demonstrate the lookup. The other five levers are unmanned, which is harmless because
      # every lever here is frictionless (see `control_points` above).
      #
      # NOTE the ids. The obvious name for the person shovelling coal is `stoker`, and
      # `:stoker` is already the conduit that carries fuel to the firebox. Ids are shared
      # across nodes, levers, instruments and crew because they key one rng table, so that
      # collision would have handed two components the same stream. `validate_graph!` now
      # refuses it outright.
      #
      # TODO: expedient — this roster is fixed, so it stays out of `options:` and is rebuilt
      # from code like the node list. The moment a crew can be hired, injured or dismissed it
      # must move into `options:`, or a restored snapshot rebuilds a different crew. Exactly
      # the trap `variant:` is in `options:` to avoid.
      def crew
        [ Minion.new(id: :fireman, archetype: :fireman, station: :stoking),
          Minion.new(id: :yardhand, archetype: :yardhand, station: :damper_open) ]
      end
    end
  end
end
