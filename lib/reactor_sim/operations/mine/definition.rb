# frozen_string_literal: true

module ReactorSim
  module Operations
    # A single-seam, bord-and-pillar shaft colliery, in its fan-ventilated era.
    #
    # The second operation, and the first that **buys** its power rather than making it: a line
    # shaft turned from an engine house somewhere else drives the fan, the pump and the hoist.
    # Everything that makes a colliery difficult is a competition for that one shaft.
    #
    # ## The five subsystems, and what each one is here
    #
    #   winning      a hewer at the face, cutting into a seam that depletes
    #   haulage      face -> pit bottom, a road with a rate limit
    #   hoisting     pit bottom -> bank on the deck of the hoist, men and coal alike
    #   drainage     water runs downhill to the sump and is pumped out, off the line shaft
    #   ventilation  air down the downcast, round the workings, out through the fan
    #
    # ## Geometry is the point
    #
    # This is the first operation with `passages:`, so a shift starts at bank and has to be *sent*
    # underground — down the shaft, along the main road, into the district. The walk is minutes,
    # and it is the reason a cage is worth buying.
    #
    # See `docs/design_sketches/mine.md`.
    module Mine
      extend self

      TYPE = :mine

      # A mine runs faster than an engine because what it does takes hours rather than seconds —
      # but a COUPLED mine has to share its supplier's clock, so this is the figure a mine runs
      # at when it is bought from an engine at 1.0. See `Match#validate_couplings!`.
      DEFAULT_TIME_SCALE = 1.0

      # The yard round the shaft collar that drains into it, m². A storm's rain on it reaches the
      # sump at a few kilograms a second — a load on the pump, not a flood.
      YARD_M2 = 2_000.0

      # **The shifts already down when the whistle goes** are fitted, not given: a face shift and a
      # pit bottom shift to start with, bigger ones as upgrades (`Mine::SHIFTS`). Bank to the face is
      # minutes, and a player who has to spend all of them before anything can happen is a player
      # watching a loading bar.
      STARTING_PARTS = {
        cutting: :hand_picks,
        haulage: :hand_putting,
        lighting: :tallow_candles,
        winder: :steam_whim,
        rope: :hemp_rope,
        headframe: :timber_headframe,
        fan: :waddle_fan,
        pump: :sinking_set,
        quarters: :lamp_cabin,
        rest: :refuge_hole,
        pit_bottom_rest: :pit_bottom_refuge,
        face_shift: :advance_shift,
        pit_bottom_shift: :pit_bottom_shift
      }.freeze

      # **The starting pit has one shaft.** It carries the ways up and down and both halves of the
      # air, divided by a brattice — so what chokes the shaft traps the shift *and* short-circuits
      # the ventilation, which is Hartley's shape. Two shafts is the upgrade: the second is a
      # second way out, and a circuit with no brattice in it.
      #
      # The first frame is the one a pit starts on.
      CHASSIS = {
        single_shaft: {
          parts: STARTING_PARTS.merge(brattice: :canvas_brattice).freeze,
          single_shaft: true
        }.freeze,
        two_shaft: {
          parts: STARTING_PARTS
        }.freeze
      }.freeze

      # `ground:` pins how gassy and how wet this pit is instead of drawing it. **Not in
      # `options:`**, and it does not need to be: it changes `initial_state` and nothing about
      # the graph, and a restored snapshot installs its own state over the top — so the ground
      # a match was given survives a round trip whatever this was called with.
      # `conditions:` is the match's sky — `{ season:, climate:, start_hour:, severity: }` from setup
      # — and nil is the standard sky a spec measures the pit under.
      def build(id:, seed:, chassis: CHASSIS.keys.first, loadout: {}, crew: {}, ground: nil,
                conditions: nil, time_scale: DEFAULT_TIME_SCALE, state: nil, rngs: nil, content: nil)
        chassis = chassis.to_sym
        assembly = assembly_for(chassis, loadout, ground: ground, conditions: conditions)
        fragment = assembly.build!
        roster = Crew.normalise(crew, capacity: assembly.crew_capacity)

        Operation.new(
          id: id, type: TYPE, seed: seed, time_scale: time_scale,
          state: state, rngs: rngs, content: content,
          options: { chassis: chassis, loadout: assembly.loadout, crew: roster, conditions: conditions }.compact,
          nodes: fragment.nodes, links: fragment.links,
          thermal_links: fragment.thermal_links, drive_links: fragment.drive_links,
          # From the fragment, so a fitted cage contributes its own way through the shaft — the
          # ladderway arrives the same way, as a fixture.
          passages: fragment.passages,
          places: fragment.places,
          control_points: fragment.control_points,
          diagnostics: assembly.diagnostics,
          minions: crew_for(roster, content || Content.default,
                            station: assembly.crew_origin, place: :bank,
                            advance: assembly.advance_shifts)
        )
      end

      def assembly_for(chassis, loadout = {}, ground: nil, conditions: nil)
        spec = CHASSIS.fetch(chassis.to_sym) { raise Error, "unknown mine chassis #{chassis.inspect}" }
        spec = spec.merge(ground: ground) if ground
        spec = spec.merge(conditions: conditions) if conditions

        Assembly.new(
          slots: slots(spec), loadout: loadout, spec: spec,
          fixtures: fixtures(spec), instruments: catalogue, order: PANEL_ORDER,
          routes: ROUTES, advisories: ADVISORIES
        )
      end

      # **The walk, and the whole reason a mine is not an engine.** Bank to the face is a shaft
      # and the best part of half a kilometre of roadway; at a competent pace that is minutes,
      # every shift, in both directions.
      #
      # TODO: balance — these are a guess, and the sketch says balance is a sweep rather than a
      # guess. A competent hand on the ladders reaches the face in about five minutes of
      # simulated time; a day-labourer takes three times that. Historically right (Levant's men
      # spent a third of a shift on ladders, which is exactly why the man engine was worth its
      # cost) and probably still too long for an opening five minutes of play.
      #
      # **The ladderway is a fixture and the hoist is a fitting.** Every shaft can be climbed;
      # the hoist that winds the coal can be ridden too, a kibble badly and a cage well. Nobody is
      # ever *completely* stranded — when the hoist stops the ladders are still there, and still
      # awful.
      def passages(spec = {})
        [
          Passage.new(a: :bank, b: :pit_bottom, metres: SHAFT_DEPTH_M, speed_m_s: 0.6,
                      through: THROUGH_SHAFT, label: "Ladderway"),
          Passage.new(a: :pit_bottom, b: :district, metres: 200.0, speed_m_s: 1.2,
                      through: :pit_bottom, label: "Main Road"),
          *([ escape ] unless spec[:single_shaft])
        ]
      end

      # **The second way out**, which is what the second shaft is for: up the return and the far
      # shaft's ladders, straight to bank. Longer than the main way, so it is taken only when that
      # is closed — and slow, because it is a return airway.
      def escape
        Passage.new(a: :district, b: :bank, metres: 200.0 + SHAFT_DEPTH_M + 40.0, speed_m_s: 0.45,
                    label: "Upcast Ladders")
      end

      # **The shaft itself**, which nothing in the air or the coal passes through as a node but
      # every way up and down runs `through:`. Choked, it closes all of them at once.
      #
      # **Something can lodge in it.** A tub let into the shaft at bank falls until it wedges in
      # the guides at `LODGE_M` — or, with the cage below that, lands on the cage instead. A jam
      # closes every way through the shaft and is a ledge a descending cage hangs on (see
      # `Nodes::Hoist`). Its `hold` is spent by the shaft working it loose and, much faster, by
      # the weight of a cage resting on it; spent, it falls to the sump.
      #
      #   state: durability, failure, jam_m, hold
      class Shaft < ReactorSim::Node
        include Concerns::Wearing

        LODGE_M = 25.0

        # Newton-seconds a lodged tub holds against. What works it loose with nothing on it, N.
        HOLD_NS = 6.0e5
        SETTLING_N = 1_000.0

        def initialize(hoist: nil, **opts)
          @hoist = hoist&.to_sym
          super(**opts)
          freeze
        end

        attr_reader :hoist

        def base_initial_state(rng, content) = super.merge(jam_m: nil, hold: 0.0)

        def failure_modes = { choked: {} }

        def jam_m(state) = state[:jam_m]

        def blocks_passage?(state, _content = nil) = broken?(state) || !jam_m(state).nil?

        def suffers?(kind) = kind == :obstruction || super

        # TODO: a tub that lands on the cage is a falling-object hazard to its riders — first
        # caller is a hazard a mishap can raise; until then it falls on the cage and stops.
        def suffer(state, mishap, ctx)
          return super unless mishap.fetch(:kind) == :obstruction
          return [ state, [] ] unless jam_m(state).nil?

          return [ state, [] ] if cage_below?(ctx)

          [ state.merge(jam_m: LODGE_M, hold: HOLD_NS * mishap.fetch(:share, 1.0)), [] ]
        end

        def cage_below?(ctx)
          drum = @hoist && ctx.nodes[@hoist]
          drum.respond_to?(:cage_m) && drum.cage_m(ctx.node_state(@hoist)) > LODGE_M
        end

        def apply(state, ctx, _grant)
          return state if jam_m(state).nil?

          bearing = @hoist ? ctx.node_state(@hoist)&.fetch(:resting_n, 0.0).to_f : 0.0
          hold = state.fetch(:hold) - ((SETTLING_N + bearing) * ctx.dt)
          hold.positive? ? state.merge(hold: hold) : state.merge(jam_m: nil, hold: 0.0)
        end
      end

      def shaft = Shaft.new(id: :shaft, label: "Shaft", hoist: :cage_drive)

      # **The headframe over the downcast**, and the air the fan draws past it on its way down the
      # shaft — a share of the intake, through `headframe_draught` and on into the pit bottom
      # through `headframe_smoke`. Iron or timber, the air is the same; only timber burns.
      #
      # **A timber frame is lit by the sheave it carries** (`hot_spot: :sheave`): the bearers the
      # plummer blocks sit on reach the bearing's temperature, and past timber's ignition point the
      # frame catches with nothing alight near it. Burning, its smoke goes down the shaft and through
      # every working. **It comes down when a share of its timber has gone**, taking the sheave and
      # part of the shaft with it.
      class Headframe < Nodes::Vessel
        # The share of its timber burnt away when it falls.
        BURNT_THROUGH = 0.3

        def initialize(timber_kg:, **opts)
          @timber_kg = timber_kg.to_f
          super(**opts)
        end

        attr_reader :timber_kg

        def timber_left_kg(state)
          state.fetch(:parcels).sum { |p| p.fetch(:resource) == :wood ? p.fetch(:kg) : 0.0 }
        end

        def overload?(state, _ctx, _integrity)
          @timber_kg.positive? && timber_left_kg(state) < @timber_kg * (1.0 - BURNT_THROUGH)
        end

        def failure_modes = { collapsed: {} }

        def failure_mode(_state, _ctx, _cause) = :collapsed

        def failure_detail(state, _ctx) = { timber_left_kg: timber_left_kg(state).round(1) }
      end

      # Who the frame falls on, and what it brings down with it.
      HEADFRAME_FALL = { tags: %i[impact burn], places: { bank: 1.4 }, riders: { cage_drive: 1.2 } }.freeze

      def headframe(timber_kg:)
        Headframe.new(
          id: :headframe, label: "Headframe", timber_kg: timber_kg, volume_m3: 300.0,
          heat_capacity: 2.0e4, ambient_conductance: 300.0,
          initial_contents: [ { resource: :air, kg: 360.0 },
                              *([ { resource: :wood, kg: timber_kg } ] if timber_kg.positive?) ],
          reactions: (timber_kg.positive? ? %i[wood_combustion] : []), hot_spot: :sheave,
          # A finite rating, so a fire in it is reported as an incident rather than as telemetry.
          max_temperature_k: 1_400.0,
          endangers: { collapsed: HEADFRAME_FALL }, damages: { collapsed: { sheave: 1.0, shaft: 0.6 } },
          ports: [ Port.new(id: :air_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
                   Port.new(id: :smoke_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0) ]
        )
      end

      # The share of the intake drawn past the headframe: each of these two in series with the other
      # is a ninth of the downcast's conductance.
      def headframe_draught
        Nodes::Conduit.new(id: :headframe_draught, label: "Headframe Draught", accepts: [ :gas ],
                           max_kg_per_s: 40.0, conductance: 0.2, heat_capacity: 2.0e3)
      end

      def headframe_smoke
        Nodes::Conduit.new(id: :headframe_smoke, label: "Headframe Smoke", accepts: [ :gas ],
                           max_kg_per_s: 40.0, conductance: 0.2, heat_capacity: 2.0e3)
      end

      # **The signal bell at the pit bottom**, rung as the cage is sent away from it. An open
      # electric bell sparks at its contacts every time it rings, which is an ignition source in the
      # room it hangs in; a flameproof one declares no `spark:` and offers nothing.
      #
      #   state: ringing
      class SignalBell < ReactorSim::Node
        # How close to the landing the cage still is while the bell is ringing it away.
        RINGS_WITHIN_M = 2.0

        def initialize(hoist:, landing_m:, spark: nil, **opts)
          @hoist = hoist.to_sym
          @landing_m = landing_m.to_f
          @spark = spark&.freeze
          super(**opts)
          freeze
        end

        attr_reader :hoist, :landing_m, :spark

        def base_initial_state(rng, content) = super.merge(ringing: false)

        def ignition(state, _levers)
          return nil unless @spark && state.fetch(:ringing, false)

          { kg_per_s: @spark.fetch(:igniter_kg_per_s), watts: @spark.fetch(:watts),
            cause: :signal_bell }
        end

        # Ringing while the cage is moving off this landing, as of last tick.
        def apply(state, ctx, _grant)
          drum = ctx.nodes[@hoist]
          drum_state = ctx.node_state(@hoist)
          return state.merge(ringing: false) unless drum.respond_to?(:cage_m) && drum_state

          near = (drum.cage_m(drum_state) - @landing_m).abs < RINGS_WITHIN_M
          state.merge(ringing: near && drum.cage_speed_m_s(drum_state).abs >= Nodes::Hoist::STOPPED_M_S)
        end
      end

      # A spark at the contacts: a spark's seed for a mixture that will carry it, and almost no heat.
      BELL_SPARK = { igniter_kg_per_s: 1.0e-7, watts: 50.0 }.freeze

      def signal_bell(spark:, label:)
        SignalBell.new(id: :signal_bell, label: label, hoist: :cage_drive, landing_m: SHAFT_DEPTH_M,
                       spark: spark)
      end

      # **The foot of the upcast**: where the return air arrives on its way to the fan. In a single
      # shaft it is the upcast compartment's, on the far side of the brattice, and whatever leaks
      # through the brattice joins it here. A furnace's flue warms it, and a warm foot is what draws
      # the whole upcast column (`stack_height_m:` on the fan's conduit).
      def upcast_foot
        Nodes::Vessel.new(
          id: :upcast_foot, label: "Upcast Foot", volume_m3: 300.0,
          heat_capacity: 4.0e4, ambient_conductance: 80.0,
          initial_contents: [ { resource: :air, kg: 360.0 } ],
          ports: [
            Port.new(id: :air_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            Port.new(id: :leak_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            Port.new(id: :flue_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            Port.new(id: :air_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0)
          ]
        )
      end

      # **A ventilating furnace at the upcast foot**: a coal fire whose flue warms the foot, and a
      # warm foot draws the whole upcast (`upcast`'s stack). It needs no power, only stoking, and its
      # draught follows its fire. **Its air is the return's**, gas and all, unless a dumb drift feeds
      # it from the intake instead (`furnace_fed_from:`, informed by the dumb drift's slot). Return
      # firedamp in its range fires here: lit by the furnaceman's work, or by the furnace's own heat
      # past the gas's ignition point.
      def furnace(volume_m3:, heat_capacity:)
        Nodes::Vessel.new(
          id: :furnace, label: "Furnace", volume_m3: volume_m3, heat_capacity: heat_capacity,
          ambient_conductance: 100.0, initial_contents: [ { resource: :air, kg: volume_m3 * 1.2 } ],
          reactions: %i[coal_combustion firedamp_combustion],
          # His shovel keeps it alight: whoever is stoking it is a light at the grate.
          heater_control_id: :furnace_stoking, igniter_kg_per_s: 0.002,
          # No temperature rating: its coal fire is the furnace working. Its gas going off is the
          # blast in the furnace drift, at the shaft bottom.
          endangers: { explosion: { tags: %i[blast burn], scales_with: :joules, reference: 1.0e8,
                                    places: { pit_bottom: 1.6 } } },
          ports: [ Port.new(id: :fuel_in, direction: :inlet, accepts: [ :fuel ], max_kg_per_s: 1.0),
                   Port.new(id: :air_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
                   Port.new(id: :flue_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0) ]
        )
      end

      def furnace_bunker(kg:)
        Nodes::Vessel.new(
          id: :furnace_bunker, label: "Furnace Coal", volume_m3: kg / COAL_BULK_KG_M3, ambient_conductance: 0.0,
          initial_contents: [ { resource: :coal, kg: kg } ],
          ports: [ Port.new(id: :out, direction: :outlet, accepts: [ :fuel ], max_kg_per_s: 1.0) ]
        )
      end

      # The furnaceman's shovel, an effort station like the engine's stoker.
      # `max_kg_per_s` is one furnaceman's.
      def furnace_stoke(max_kg_per_s:, crew:)
        Nodes::Conduit.new(id: :furnace_stoke, label: "Stoking the Furnace", accepts: [ :fuel ],
                           max_kg_per_s: max_kg_per_s, heat_capacity: 1.0e3, control_id: :furnace_stoking,
                           worked: true, crew: crew)
      end

      # Through the furnace's grate and arch, which is what a bigger furnace widens.
      def furnace_draught(conductance:)
        Nodes::Conduit.new(id: :furnace_draught, label: "Furnace Drift", accepts: [ :gas ],
                           max_kg_per_s: 40.0, conductance: conductance, heat_capacity: 2.0e3)
      end

      def furnace_flue
        Nodes::Conduit.new(id: :furnace_flue, label: "Furnace Flue", accepts: [ :gas ],
                           max_kg_per_s: 40.0, conductance: 1.2, heat_capacity: 2.0e3)
      end

      # **A leak from the intake straight to the return**: whatever it passes is air that never
      # reaches the face. Shut, it passes `leak_fraction` of its bore; `opening` is how far it
      # stands open beyond that; failed, it is a hole and passes everything.
      class Leak < Nodes::Conduit
        def initialize(leak_fraction:, **opts)
          @leak_fraction = leak_fraction.to_f
          super(**opts)
        end

        attr_reader :leak_fraction

        def opening(_state) = 0.0

        def gas_conductance(state, ctx)
          base = super or return nil
          return base if broken?(state)

          base * (@leak_fraction + ((1.0 - @leak_fraction) * opening(state)))
        end
      end

      # **The partition between the downcast and the upcast**: nearly shut while sound, a torrent
      # once breached — the fan then pulls the air down one side and straight back up the other,
      # and the district starves. How much it leaks sound is the tier.
      class Brattice < Leak
        def failure_modes = { breached: {} }

        def failure_mode(_state, _ctx, _cause) = :breached
      end

      # **The door where the haulage crosses from intake to return.** Every set of tubs pushes it
      # open (`traffic:`, the road's activity as of last tick); a trapper shuts it after them, and a
      # self-closing door shuts itself. With nobody trapping a plain door stays as the last tub left
      # it — it does not know nobody is there. An air lock is two doors, so the way through is open
      # only as often as both are at once. An explosion blows it out for good.
      #
      #   state: open, durability, failure
      class Door < Leak
        # Open, per second, under full traffic; shut, per second, under a trapper fully at it.
        OPENED_PER_S = 0.5
        SHUT_PER_S = 1.2

        def initialize(traffic:, trapper: nil, self_closing_per_s: 0.0, doors: 1, **opts)
          @traffic = traffic.to_sym
          @trapper = trapper&.to_sym
          @self_closing_per_s = self_closing_per_s.to_f
          @doors = Integer(doors)
          super(**opts)
        end

        attr_reader :traffic, :trapper, :self_closing_per_s, :doors

        def base_initial_state(rng, content) = super.merge(open: 0.0)

        def opening(state) = state.fetch(:open, 0.0)**@doors

        def apply(state, ctx, _grant)
          road = ctx.nodes[@traffic]
          tubs = road&.activity(ctx.node_state(@traffic), :tubs, ctx.dt).to_f
          trapping = @trapper ? [ ctx.controls.fetch(@trapper, 0.0) / 100.0, 0.0 ].max : 0.0
          shutting = (SHUT_PER_S * trapping) + @self_closing_per_s
          open = state.fetch(:open, 0.0) + (((OPENED_PER_S * tubs) - shutting) * ctx.dt)

          state.merge(open: open.clamp(0.0, 1.0))
        end

        def failure_modes = { blown_out: {} }

        def failure_mode(_state, _ctx, _cause) = :blown_out
      end

      def door(label:, self_closing_per_s: 0.0, doors: 1, trapper: :trapping)
        Door.new(id: :door, label: label, accepts: [ :gas ], leak_fraction: 0.02, max_kg_per_s: 40.0,
                 conductance: 1.0, heat_capacity: 1.0e3, traffic: :tub_road, trapper: trapper,
                 self_closing_per_s: self_closing_per_s, doors: doors)
      end

      def brattice(leak_fraction:)
        Brattice.new(id: :brattice, label: "Brattice", accepts: [ :gas ], leak_fraction: leak_fraction,
                     max_kg_per_s: 40.0, conductance: 1.0, heat_capacity: 1.0e3)
      end

      # The same shaft, ridden on the man engine's rod instead of climbed. It stops the moment the
      # line shaft does, and the ladders are what is left. A cage or kibble is a hoist and rides
      # differently — see `hoist_fragment`.
      def rod_passage(speed_m_s:, rated_omega:, label: "Man Engine")
        Passage.new(a: :bank, b: :pit_bottom, metres: SHAFT_DEPTH_M, speed_m_s: speed_m_s,
                    control_id: :rods, driven_by: :man_engine,
                    rated_omega: rated_omega, through: THROUGH_SHAFT, label: label)
      end

      # **The man engine: a rod down the shaft on a bob at the top.** It hangs off the same line
      # shaft as everything else, so running it loads the shaft, and a loaded shaft turns slower —
      # the hoist raises less coal, the pump lifts less water and the fan moves less air, all at
      # once.
      #
      # **Every stroke is a step on or off.** How busy the rods are is `strokes`, the square of
      # its speed against rated: a missed step is a peril that scales with it, so an engine house
      # opening its throttle shortens the step window under every man on the rods.
      #
      # **The strap joining bob to rod wears per stroke and per man on it**, and parts on a hard
      # overspeed. How it parted decides what the catches do: worn through (`parted`) leaves them
      # in line and they hold; torn out (`torn_out`) knocks them out of line with it. Parted, the
      # rod is gone from the line shaft — a load rejection upstream.
      #
      #   state: angular_momentum, durability, failure
      class ManEngine < Nodes::Load
        include Concerns::Wearing

        # Durability per second at rated speed with nobody on the rods.
        STRAP_PER_S = 0.05

        # Riders' weight that doubles the strap's wear.
        STRAP_RIDERS_KG = 400.0

        # How far past rated speed a sound strap stands before it is torn out. A worn one less.
        OVERSPEED_MARGIN = 0.6

        def initialize(endangers: {}, damages: {}, perils: [], **opts)
          @failure_hazards = endangers.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          @failure_damages = damages.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          @perils = perils.freeze
          super(**opts)
        end

        attr_reader :failure_hazards, :failure_damages, :perils

        def speed_ratio(state) = @rated_omega.positive? ? omega(state).abs / @rated_omega : 0.0

        def activity(state, quantity, _dt) = quantity == :strokes ? speed_ratio(state)**2 : nil

        def stress_per_second(state, ctx)
          riders = ctx.respond_to?(:cargo_kg) ? ctx.cargo_kg(id) : 0.0
          STRAP_PER_S * (speed_ratio(state)**2) * (1.0 + (riders / STRAP_RIDERS_KG))
        end

        def overload?(state, _ctx, integrity) = speed_ratio(state) > 1.0 + (OVERSPEED_MARGIN * integrity)

        def failure_modes = { parted: {}, torn_out: {} }

        def failure_mode(_state, _ctx, cause) = cause == :overload ? :torn_out : :parted

        def failure_detail(state, _ctx) = { speed_ratio: speed_ratio(state).round(2) }
      end

      def man_engine(max_torque:, rated_omega:, endangers:, damages:)
        ManEngine.new(
          id: :man_engine, label: "Man Engine", moment_of_inertia: 120.0,
          max_torque: max_torque, rated_omega: rated_omega, curve: :constant,
          control_id: :rods, friction: 1.0, endangers: endangers, damages: damages,
          # A missed step, every stroke a chance of it. Mostly a fall onto the next sollar.
          perils: [ Peril.new(id: :misstep, tags: %i[fall crush], severity: 1.6, rate: 0.6,
                              scales_with: :strokes, riders: %i[man_engine]) ]
        )
      end

      # --- the air circuit ------------------------------------------------------

      # Open air at the pit bank. The source and the sink of the whole ventilation circuit, and
      # the pressure reference the fan works against.
      def atmosphere = Nodes::Atmosphere.new

      def downcast
        Nodes::Conduit.new(
          id: :downcast, label: "Downcast Shaft", accepts: [ :gas ],
          max_kg_per_s: 40.0, conductance: 0.9, heat_capacity: 4.0e4
        )
      end

      # The pit bottom: a real volume of air, somewhere to stand, and the place water collects.
      # **The shaft bottom, and the low corner of the whole mine.**
      #
      # Water runs downhill and this is downhill, so what the pumps do not lift stands here.
      # `flooding` is what a float on a chain actually tells you: not a weight, but how far up
      # it has come against the point where it is over the rails and backing up the road.
      #
      # **Past the roof mark it is drowned.** There is no air left to stand in, so nobody here can
      # breathe, and every way that runs through the pit bottom — the shaft's and the main road —
      # is closed. The district, higher up, is then an air pocket.
      class Sump < Nodes::Vessel
        # Where the pit bottom stops being wet and starts being flooded — water over the
        # landing, the onsetter's feet and the bottom of the cage. It is the mark the gauge is
        # read against, and the number a player is actually racing.
        FLOOD_KG = 2_400.0

        # Water to the roof of the roadways.
        ROOF_KG = 6 * FLOOD_KG

        def standing_kg(state, content)
          Parcel.total_kg(Parcel.matching(state.fetch(:parcels), [ :liquid ], content))
        end

        def flooding(state, content) = (standing_kg(state, content) / FLOOD_KG).clamp(0.0, 1.0)

        def submerged?(state, content) = standing_kg(state, content) >= ROOF_KG

        def blocks_passage?(state, content = nil) = !content.nil? && submerged?(state, content)
      end

      def pit_bottom
        Sump.new(
          id: :pit_bottom, label: "Pit Bottom", volume_m3: 900.0,
          # Its gear; the rock is `:pit_bottom_rock`.
          heat_capacity: 2.0e4,
          initial_contents: [ { resource: :air, kg: 1_100.0 } ],
          # **Gas that reaches the shaft can burn there.** It is on the intake and is clear while
          # the air runs; stop the fan or breach the brattice and the district's gas backs out to
          # where the signal bell rings — or to where a district explosion's flame arrives.
          reactions: %i[firedamp_combustion],
          ports: [
            Port.new(id: :air_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            Port.new(id: :air_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            # The share of the intake drawn down past the headframe — smoke, when it is burning.
            Port.new(id: :smoke_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            # The trickle that leaks off the intake into the waste behind the face.
            Port.new(id: :waste_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 5.0),
            # Through the brattice into the upcast compartment, in a single-shaft pit.
            Port.new(id: :brattice_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            # Through the haulage door into the return.
            Port.new(id: :door_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            # Its own inlet, not the downcast's: a port filters on tags and cannot tell two
            # gases apart, so a seep sharing the intake would be a seep the ventilation drives.
            Port.new(id: :damp_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 2.0),
            # Wide enough for a rope haulage's sets or a belt, as well as the putters' tubs.
            Port.new(id: :coal_in, direction: :inlet, accepts: [ :solid ], max_kg_per_s: 40.0),
            Port.new(id: :coal_out, direction: :outlet, accepts: [ :solid ], max_kg_per_s: 12.0),
            # The sump is the pit bottom's own low corner rather than a node of its own: water
            # collects where the shaft does, and a second vessel would add a tick of lag between
            # the two for no behaviour.
            Port.new(id: :water_in, direction: :inlet, accepts: [ :liquid ], max_kg_per_s: 30.0),
            Port.new(id: :water_out, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: 30.0)
          ]
        )
      end

      def main_road
        Nodes::Conduit.new(
          id: :main_road, label: "Main Road", accepts: [ :gas ],
          max_kg_per_s: 40.0, conductance: 0.8, heat_capacity: 6.0e4
        )
      end

      # The working district. Air, men and coal all meet here, which is what makes one volume
      # the right model for it rather than three.
      # The working district. Air, men, coal and gas all meet here, which is what makes one
      # volume the right model for it rather than four.
      #
      # **It hosts the firedamp reaction, and the igniter is whatever the district is lit by.**
      # Working by naked flame is a real decision with a real payoff — you can see what you are
      # doing, and hewing is gated on seeing — and the whole of its cost is that the district
      # then contains a light. Everything else follows from the gas being there or not. See
      # `Lighting` for how a tier decides whether it is an ignition source.
      # **What stone dust does, and why it is a throttle rather than a cap.**
      #
      # Limestone spread along the roadways does not stop coal dust burning — it means what gets
      # raised is mostly inert, so the mixture cannot carry a flame from one length of roadway to
      # the next. The fuel and the air are both still there; they are no longer meeting. That is
      # exactly the sentence `Vessel#reaction_throttle` was written for, one hazard along from
      # ash smothering a grate.
      #
      # It damps the **gas** as well, and that is right: inert dust absorbs the heat a flame
      # front needs to carry, whatever is carrying it. Historically stone dusting is what stopped
      # ignitions becoming disasters rather than what stopped them happening.
      class District < Nodes::Vessel
        # Below this share of the airborne dust being inert, the roadways will carry a flame.
        # The real figure is a legal minimum somewhere upward of 50% incombustible; this is the
        # same idea with one number.
        INERTED = 0.65

        # **Dusting saves you from the dust, not from the gas**, and that is why this reads the
        # reaction id. Historically the two are separate: stone dusting is why ignitions stopped
        # becoming *disasters*, not why they stopped happening — men still died of firedamp in
        # dusted pits. Throttling both alike left a dusted district sitting at ambient through a
        # naked light in 12% gas, which quietly cancelled the whole of the gas hazard.
        def reaction_throttle(state, content, reaction_id = nil)
          base = super(state, content, reaction_id)
          return base unless reaction_id == :coal_dust_combustion

          coal = contents_of(state, :coal_dust)
          stone = contents_of(state, :stone_dust)
          total = coal + stone
          return base if total <= 0.0

          inert = [ stone / total, INERTED ].min

          base * (1.0 - (inert / INERTED))
        end

        def contents_of(state, resource)
          state.fetch(:parcels, []).find { |p| p.fetch(:resource) == resource }&.fetch(:kg) || 0.0
        end
      end

      # **The strata round a working**, of `:coal_measures`. The roads' gas loses its heat to the
      # rock face and the rock passes it on into the ground, which is why a blast's heat lasts
      # seconds and the face it scorched stays warm for minutes (`Nodes::Wall`).
      #
      # Two centimetres: about how far heat gets into rock over the minutes a working cares about.
      ROCK_SKIN_M = 0.02

      # Fire gases against the rough rock of a mine drift, where measured coefficients run 25–50.
      ROCK_FILM_W_PER_M2_K = 30.0

      # Hot CO₂ and steam carrying the dust and soot a blast raises — a luminous cloud, where clean
      # products a few metres deep sit near 0.2. Radiation is most of what a blast's gas loses to
      # the walls. TODO: derived from what is in the gas — first caller is a furnace, where a
      # luminous flame is the lever; fixed until then, and untested beyond it.
      FLAME_GAS_EMISSIVITY = 0.4

      # **Rough rock has about twice the face of a smooth bore** of the same size, and the roughness
      # stirs the gas against it.
      ROCK_ROUGHNESS = 2.0

      def rock(id, area_m2:)
        Nodes::Wall.new(id: id, label: "Strata", material: :coal_measures,
                        area_m2: area_m2 * ROCK_ROUGHNESS, skin_m: ROCK_SKIN_M, content: Content.default)
      end

      def rock_face(room, rock, area_m2:)
        face = area_m2 * ROCK_ROUGHNESS
        ThermalLink.new(a: room, b: rock, conductance: ROCK_FILM_W_PER_M2_K * face,
                        emissivity: FLAME_GAS_EMISSIVITY, radiating_area_m2: face)
      end

      # 200 m of roadway at about ten metres round, and the pit bottom's landing and its roads — as a
      # smooth bore; `ROCK_ROUGHNESS` makes it rock.
      DISTRICT_FACE_M2 = 2_100.0
      PIT_BOTTOM_FACE_M2 = 1_350.0

      def district
        District.new(
          id: :district, label: "District", volume_m3: 1_400.0,
          # Its props, tubs and gear. The rock is `:district_rock`.
          heat_capacity: 2.0e4,
          initial_contents: [ { resource: :air, kg: 1_700.0 } ],
          # And a fired charge, which reacts the tick it lands and leaves its fumes here.
          reactions: %i[firedamp_combustion coal_dust_combustion black_powder_firing permitted_firing],
          # The waste behind the face and the rock round it: either hot enough fires the district's
          # gas with no flame — a gob fire, or strata a fire has left past firedamp's ignition point.
          hot_spot: %i[gob district_rock],
          # **No igniter of its own.** Whatever is alight in the district — an open-flame light —
          # offers itself to this air through `Tick#ignition_sources`, so with a safe tier fitted
          # the district has no ignition source at all, which is what "safe lighting" has to mean
          # in a pit that makes firedamp.
          # **What a roadway stands, which is not much.** Timber, and men. Past this the district
          # is on fire, and `stress_rate` is high because there is no slow version of this
          # failure — a gas explosion crosses a district faster than anybody in it can move.
          max_temperature_k: 480.0, stress_rate: 2.4,
          # And what it does to the people in it. **The blast reaches the pit bottom too**: an
          # explosion travels the roadways, and afterdamp travels further still and kills more
          # than the blast did.
          #
          # By PLACE, because that is why it reaches them. Everybody in the district is in the
          # district when it goes up — the deputy walking through, the man who has just been
          # stood down from his post — and the weight falls off with distance rather than with
          # what anybody was doing.
          #
          # **The explosion is the blast, the instant it happens**, by the energy it released — a
          # walled district has shed its heat long before it could wear through. A rupture is the
          # roadway itself giving way to a fire that went on burning.
          endangers: {
            explosion: { tags: %i[blast burn], scales_with: :joules, reference: 3.0e9,
                         places: { district: 3.2, pit_bottom: 1.1 } },
            rupture: { tags: %i[blast burn afterdamp], scales_with: :temperature_k,
                       reference: 1_400.0,
                       places: { district: 3.2, pit_bottom: 1.1 } }
          },
          # The blast goes down the roads and blows the haulage door out of its frame, so the air
          # that might have cleared the afterdamp takes the short way back to the fan instead. **It
          # wrecks the roadway too**, by force rather than heat — timbering blown out, the roof let
          # down — so a sound district stands one explosion and one already worn does not.
          damages: { explosion: { door: 1.0, district: 0.5 }, rupture: { door: 1.0 } },
          ports: [
            Port.new(id: :air_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            Port.new(id: :air_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            Port.new(id: :gas_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 2.0),
            # What comes out of the coal ahead: an outburst's gas and dust, or the borer's draw.
            Port.new(id: :burst_in, direction: :inlet, accepts: [], max_kg_per_s: 60.0),
            # What a shot brings: its charge, the coal it brings down and the dust it raises.
            Port.new(id: :shot_in, direction: :inlet, accepts: [], max_kg_per_s: 120.0),
            # What has leaked through the waste behind the face — and its smoke, if it is heating.
            Port.new(id: :waste_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 5.0),
            # The share of the intake that has passed a belt road — its smoke, when it is burning.
            Port.new(id: :smoke_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            # The cutter's spray water, and the road it runs back down to the sump.
            Port.new(id: :spray_in, direction: :inlet, accepts: [ :liquid ], max_kg_per_s: 2.0),
            Port.new(id: :water_out, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: 2.0),
            # **Inlets only.** Dust that has settled in a district has no way out of it: no
            # conduit here accepts `:dust`, so it neither rides out on the tubs nor blows away
            # up the return. It goes when it burns or when it is covered over.
            Port.new(id: :dust_in, direction: :inlet, accepts: [ :dust ], max_kg_per_s: 2.0),
            Port.new(id: :stone_in, direction: :inlet, accepts: [ :dust ], max_kg_per_s: 2.0),
            Port.new(id: :coal_in, direction: :inlet, accepts: [ :solid ], max_kg_per_s: 12.0),
            # Wide enough for a rope haulage's sets and a belt's loading point.
            Port.new(id: :coal_out, direction: :outlet, accepts: [ :solid ], max_kg_per_s: 40.0)
          ]
        )
      end

      def return_road
        Nodes::Conduit.new(
          id: :return_road, label: "Return Airway", accepts: [ :gas ],
          max_kg_per_s: 40.0, conductance: 0.8, heat_capacity: 6.0e4
        )
      end

      # The fan, on the upcast, **exhausting**: a colliery fan pulls the whole circuit rather
      # than blowing into it, which is why the shaft it sits on is the upcast and why stopping
      # it stops everything rather than merely reducing it.
      #
      # `delivers_to:` is deliberately left at its default — itself. The air a fan moves stays in
      # the operation and the pressure it put there dissipates into the stream, unlike the pump,
      # whose water genuinely leaves.
      # A rotor flying apart in the fan house throws iron across the bank.
      #
      # **Its conduit is the upcast column too**, the shaft's depth of it, so a foot warmer than the
      # air outside draws by buoyancy whether the fan turns or not.
      def upcast(head_pa:, rated_omega:, reversible: false)
        Fan.new(
          id: :upcast, label: "Upcast Fan", accepts: [ :gas ],
          max_kg_per_s: 40.0, conductance: 1.2, heat_capacity: 5.0e4, stack_height_m: SHAFT_DEPTH_M,
          control_id: :ventilation, head_pa: head_pa,
          reverse_control_id: (:fan_reversed if reversible),
          driven_by: :line_shaft, efficiency: 0.55, rated_omega: rated_omega,
          burst_ratio: 1.5, endangers: { burst: { tags: %i[impact], places: { bank: 1.6 } } }
        )
      end

      # --- winning and haulage --------------------------------------------------

      # The seam, as a body of coal that runs out.
      #
      # A block of coal in a vessel rather than a bespoke "face" node, which means winning needs
      # no new machinery at all: the hewer's lever is a `Conduit` drawing out of it, exactly as
      # the stoker's lever draws out of the bunker. It also makes a district that has been
      # worked out a real thing rather than a rule.
      # The seam holds the gas as well as the coal, because that is where it is: firedamp is in
      # the coal and comes out when the coal is broken. Carrying it as ordinary contents means
      # emission needs no injection and no new machinery — it is a conduit out of a vessel, like
      # everything else — and mass conserves from the start.
      # **The dust is not in here**, and that is not tidiness. Coal dust is tagged `gas` so the
      # ventilation will carry it, which means a seam holding both would let the *blower* carry
      # it too — dust would arrive in the district whether anybody was cutting or not, and it
      # did: 22 kg with the hewing lever hard at zero. A port filters on tags and cannot tell
      # two gases apart, so the two sources have to be two nodes.
      def seam(kg:, firedamp_kg:)
        Nodes::Vessel.new(
          id: :seam, label: "Coal Face", volume_m3: 4_000.0, ambient_conductance: 0.0,
          initial_contents: [ { resource: :coal, kg: kg },
                              { resource: :firedamp, kg: firedamp_kg } ],
          ports: [
            Port.new(id: :out, direction: :outlet, accepts: [ :solid ], max_kg_per_s: 12.0),
            Port.new(id: :gas_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 2.0),
            # What a shot brings down, faster than any pick.
            Port.new(id: :fall_out, direction: :outlet, accepts: [ :solid ], max_kg_per_s: 60.0)
          ]
        )
      end

      # What the pick makes. A separate body from the seam so that only the hewing lever can
      # reach it — see `seam`.
      def dust_source(kg:)
        Nodes::Vessel.new(
          id: :dust_source, label: "Face Dust", volume_m3: 2_000.0, ambient_conductance: 0.0,
          initial_contents: [ { resource: :coal_dust, kg: kg } ],
          ports: [ Port.new(id: :out, direction: :outlet, accepts: [ :dust ], max_kg_per_s: 2.0),
                   # What a shot raises.
                   Port.new(id: :raised_out, direction: :outlet, accepts: [ :dust ], max_kg_per_s: 5.0) ]
        )
      end

      # **Dust comes off the pick, not out of the ground.** A blower vents whether anybody is
      # there or not; dust is made by cutting, so this one is on the hewing lever — which makes
      # driving a face hard the thing that fills the district with it. Rate-driven, because what
      # limits it is how hard the coal is being worked rather than any gradient.
      #
      # **Sprays lay most of it** where it is made, by how wet they have the face (`SprayLine`).
      class DustLine < Nodes::Conduit
        LAID_WET = 0.7

        def initialize(sprayed_by: :spray_line, **opts)
          @sprayed_by = sprayed_by.to_sym
          super(**opts)
        end

        def throughput_kg(state, ctx) = super * (1.0 - (LAID_WET * SprayLine.wetting(ctx, @sprayed_by)))
      end

      # `max_kg_per_s` is what each hewer raises.
      def dust_line(max_kg_per_s:)
        DustLine.new(
          id: :dust_line, label: "Dust", accepts: [ :dust ],
          max_kg_per_s: max_kg_per_s, heat_capacity: 1.0e3,
          control_id: :hewing, worked: true
        )
      end

      # The limestone, in a heap at bank. It runs out, which is the cost of dusting.
      def dust_store(kg:)
        Nodes::Vessel.new(
          id: :dust_store, label: "Stone Dust", volume_m3: 400.0, ambient_conductance: 0.0,
          initial_contents: [ { resource: :stone_dust, kg: kg } ],
          ports: [ Port.new(id: :out, direction: :outlet, accepts: [ :dust ],
                            max_kg_per_s: 2.0) ]
        )
      end

      # **A lever at bank rather than a body underground**, deliberately. There are already
      # three jobs at the face against four hands, and a fourth would make this a staffing
      # problem when it is meant to be a *spending* one: dusting costs stores and attention, not
      # a person you could have put on the pick.
      def dusting_line(max_kg_per_s:)
        Nodes::Conduit.new(
          id: :dusting_line, label: "Dusting", accepts: [ :dust ],
          max_kg_per_s: max_kg_per_s, heat_capacity: 1.0e3,
          control_id: :stone_dusting
        )
      end

      # **A blower**: a fissure venting firedamp, continuously, whether anybody is watching or
      # not. No lever, because that is the point — the mine gives off gas and the only question
      # is whether enough air is going past to take it away.
      #
      # **`conductance:` is the live restriction here and `max_kg_per_s` is a ceiling**, which is
      # the one thing about this fitting that is easy to get backwards. A cap next to a
      # conductance is a dead number: declaring a conductance puts the path in the
      # pressure-driven regime, where the gas solve sets the rate and the cap is never
      # consulted. Written with a plausible-looking `0.05 kg/s` and a conductance of `0.02`, the
      # blower passed **4.2 kg a tick against a 0.0125 kg rating** and filled the district to 65%
      # gas in three minutes, with the fan making no difference whatever.
      #
      # Pressure-driven is also the better model, and it gives one behaviour for free that a
      # fixed rate cannot: **emission falls as the district fills**, because the gradient it is
      # venting against is what drives it. A gassy working vents harder once it is cleared.
      # **Ground varies, and a pit whose numbers are identical every match is a pit you learn
      # once.** How fiery a panel is, how sour the old workings are and how wet the strata runs
      # are properties of the *ground*, not of mining — a colliery two miles away is a different
      # proposition, and knowing which one you have been given is most of an overseer's job.
      #
      # Drawn in `initial_state`, one of the three places entropy is permitted, and held in
      # state so it snapshots and replays exactly. **Each seep has its own RNG stream**, because
      # ids key the stream table — so a fiery pit is not also a wet one, and a player cannot
      # learn one number and infer the rest.
      module Ground
        # Wide on purpose, and it reaches genuinely low. 0.2 is a panel that barely makes gas at
        # all; 2.4 is one that has to be fought all shift — **and the starting fan does not hold
        # the top of it**, which is deliberate: a range the base machine always copes with is a
        # range that changes nothing. Anything narrower and the counter-measure is the same
        # every match, which is the rote this exists to break.
        RANGE = (0.2..2.4)

        # **1.0 is the ground a spec measures a MACHINE on**, and the argument is
        # `ReferenceCrew`'s exactly: a spec that runs a mine and does not say what ground it was
        # given measures the luck rather than the pit. `Mine.build(ground: 1.0)` pins every seep
        # at ordinary; left nil, each draws its own.
        ORDINARY = 1.0

        def initialize(ground: nil, **opts)
          @ground = ground&.to_f
          super(**opts)
        end

        def initial_state(rng, content = nil)
          super.merge(ground: @ground || rng.between(RANGE.begin, RANGE.end))
        end

        # 1.0 for a state written before this existed, so a restored snapshot is merely average
        # rather than inert.
        def ground(state) = state.fetch(:ground, 1.0)
      end

      # A fissure venting gas under pressure, at whatever rate this particular ground does it.
      class Seep < Nodes::Conduit
        include Ground

        def gas_conductance(state, ctx)
          base = super or return nil

          base * ground(state)
        end
      end

      def blower(conductance:, ground: nil)
        Seep.new(
          id: :blower, label: "Blower", accepts: [ :gas ], ground: ground,
          max_kg_per_s: 0.5, conductance: conductance, heat_capacity: 1.0e3
        )
      end

      # **The worked-out ground behind the face, and what is quietly happening in it.** Coal left
      # in the goaf oxidises slowly, using up the oxygen and leaving blackdamp — so a pit makes
      # more of this the longer it has been worked, from ground nobody goes into any more.
      #
      # Placeless, like the seam: it is collapsed rock, not a room.
      # **How sour the waste is running, which is the one damp a pit can make without a fire.**
      #
      # Coal left behind oxidises, and where it oxidises hot it goes to carbon monoxide instead
      # of stopping at carbon dioxide. Some panels do this and some never do, so the share is
      # drawn per match beside everything else about the ground.
      #
      # It matters out of all proportion to its size: whitedamp poisons at a concentration that
      # displaces nothing, so a pit whose goaf has gone sour is one where the canary is the only
      # warning there will be — and the flame lamp reads perfectly clear the whole time.
      #
      # **The roof over it hangs until it falls.** Every metre the face advances leaves a metre of
      # unsupported roof behind it, less what has been packed with stone; when what hangs passes the
      # next **span** the goaf falls — flushing its gas out through the seep and driving a windblast
      # down the roads ahead of it — and the roof starts hanging again. The spans are drawn per match,
      # varied, and the first is the largest (the first weighting), so nobody knows when.
      #
      #   state: parcels, spans (metres, next first), fallen_at_m, packed_m, hanging_m, weighting,
      #          flushing_s, durability, failure
      class OldWorkings < Nodes::Vessel
        SOUR = (0.0..0.09)

        # Pinned by `ground:` the way the seeps are, so a spec about a machine is not also a
        # spec about which waste it was given. Sweet, because sour is the exception.
        ORDINARY_SOUR = 0.0

        # **Spans, log-normal**: the first weighting, then the periodic falls after it, in metres of
        # unsupported advance.
        FIRST_SPAN_M = 6.0
        SPAN_M = 3.0
        SPAN_SIGMA = 0.4
        SPANS_DRAWN = 12

        # How long a fall drives the goaf's gas out, and how hard.
        FLUSH_S = 20.0
        FLUSH_FACTOR = 150.0

        # A packer at full effort fills this much of the void a second, in metres of advance — about
        # half what a hewer wins.
        PACK_M_PER_S = 8.0e-5

        def initialize(sour: nil, spans: nil, seam: nil, seam_kg: 0.0, packing: nil, **opts)
          @sour = sour&.to_f
          @spans = spans&.map(&:to_f)&.freeze
          @seam = seam&.to_sym
          @seam_kg = seam_kg.to_f
          @packing = packing&.to_sym
          super(**opts)
        end

        def initial_state(rng, content = nil)
          state = super
          spans = @spans || Array.new(SPANS_DRAWN) { |n| span(rng, n.zero? ? FIRST_SPAN_M : SPAN_M) }
          state.merge(spans: spans, fallen_at_m: 0.0, packed_m: 0.0, hanging_m: 0.0, weighting: 0.0,
                      flushing_s: 0.0)
        end

        def span(rng, median_m) = median_m * Math.exp(SPAN_SIGMA * GasPocket.standard_normal(rng).clamp(-2.5, 2.5))

        def advance_m(ctx) = @seam ? Ahead.advance_m(ctx, seam: @seam, seam_kg: @seam_kg) : 0.0

        def flushing?(state) = state.fetch(:flushing_s, 0.0).positive?

        def overload?(state, _ctx, _integrity)
          span = state.fetch(:spans, []).first
          !span.nil? && state.fetch(:hanging_m, 0.0) >= span
        end

        def failure_modes = { fell: {} }

        def failure_mode(_state, _ctx, _cause) = :fell

        def failure_detail(state, _ctx) = { hanging_m: state.fetch(:hanging_m, 0.0).round(2) }

        # What hangs, what has been packed, and the fall: on the tick after it, the roof starts hanging
        # afresh and the gas is driven out for `FLUSH_S`; once that is spent the goaf is quiet again.
        def apply(state, ctx, grant)
          state, events = super
          advance = advance_m(ctx)
          state = fall(state, advance) if broken?(state) && !flushing?(state) && state.fetch(:hanging_m).positive?
          state = settle(state, ctx) if flushing?(state)

          packed = [ state.fetch(:packed_m) + (PACK_M_PER_S * packing(ctx) * ctx.dt),
                     advance - state.fetch(:fallen_at_m) ].min
          hanging = [ advance - state.fetch(:fallen_at_m) - packed, 0.0 ].max
          span = state.fetch(:spans).first
          [ state.merge(packed_m: packed, hanging_m: hanging, weighting: span ? hanging / span : 0.0), events ]
        end

        private

        def packing(ctx) = @packing ? [ ctx.controls.fetch(@packing, 0.0) / 100.0, 0.0 ].max : 0.0

        def fall(state, advance)
          state.merge(fallen_at_m: advance, packed_m: 0.0, hanging_m: 0.0, flushing_s: FLUSH_S,
                      spans: state.fetch(:spans).drop(1))
        end

        def settle(state, ctx)
          left = state.fetch(:flushing_s) - ctx.dt
          return state.merge(flushing_s: left) if left.positive?

          state.merge(flushing_s: 0.0, failure: nil, durability: state.fetch(:initial_durability))
        end

        public

        def holds_initial_state(rng, content)
          state = super
          share = @sour || rng.between(SOUR.begin, SOUR.end)
          { parcels: Parcel.normalise(state.fetch(:parcels).flat_map { |parcel|
              sour(parcel, share, content)
            }) }
        end

        private

        # Only the blackdamp turns; anything else declared stays as it was.
        def sour(parcel, share, content)
          return [ parcel ] unless parcel.fetch(:resource) == :blackdamp

          taken, left = Parcel.split(parcel, parcel.fetch(:kg) * share)
          [ left, Parcel.build(resource: :whitedamp, kg: taken.fetch(:kg),
                               temperature_k: Parcel.temperature_k(taken, content),
                               content: content) ]
        end
      end

      # A fall drives the air out ahead of it, down the roads, at whoever is in them — by how much
      # came down.
      WINDBLAST = { tags: %i[impact], scales_with: :hanging_m, reference: OldWorkings::FIRST_SPAN_M,
                    places: { district: 1.8, pit_bottom: 0.6 } }.freeze

      # A pinned `ground:` draws no spans, so a spec measuring the machine has no falls.
      def goaf(kg:, seam_kg:, sour: nil, ground: nil)
        OldWorkings.new(
          id: :goaf, label: "Old Workings", volume_m3: 3_000.0, ambient_conductance: 0.0,
          sour: sour, spans: ([] if ground), seam: :seam, seam_kg: seam_kg, packing: :packing,
          initial_contents: [ { resource: :blackdamp, kg: kg } ],
          endangers: { fell: WINDBLAST },
          ports: [ Port.new(id: :out, direction: :outlet, accepts: [ :gas ],
                            max_kg_per_s: 2.0) ]
        )
      end

      # **The waste the last workings left behind this district's face, and how far it has got.** A
      # match inherits it: in some pits nothing heating at all, and otherwise a zone of broken coal of
      # drawn size **already part-way to firing** — so the danger runs from none to a fire ready in
      # fifteen minutes, weighted to one between three quarters of an hour and an hour and a half.
      #
      # From there it is physics. Air trickles through it from the intake at the pit bottom to the face,
      # driven by the fan; the coal takes up its oxygen (`coal_oxidation`) and warms, and where the heat
      # cannot get away it climbs until the coal lights of itself — a gob fire. Short of air it
      # smoulders and makes carbon monoxide, which comes out at the face; hot enough it breaks out
      # there; hotter still it fires the district's gas. **Sealing** builds stoppings across the leak,
      # which starves it; the stoppings stay built.
      #
      #   state: parcels, joules, ignition, ground, sealed (0..1)
      class Gob < Nodes::Vessel
        include Ground

        # A pit whose last workings left nothing heating.
        NONE_SHARE = 0.25

        # The heating zone's coal, log-normal.
        ZONE_COAL_KG = 3_000.0
        ZONE_SIGMA = 0.6

        # **When it is due to fire**, as the draw intends it — log-normal, so most between three quarters
        # of an hour and an hour and a half, clamped to a quarter of an hour at the soonest.
        FIRES_IN_S = 65.0 * 60.0
        FIRES_SIGMA = 0.4
        SOONEST_S = 15.0 * 60.0

        # The heat a waste makes on the leak's ordinary trickle — what the start temperature is solved
        # against, measured off running pits rather than assumed. The real trickle sets the real rate.
        DESIGN_HEAT_W = 50_000.0

        # Broken coal has a great deal of surface: how much faster than lump coal it takes up oxygen.
        REACTIVITY = 10.0

        # Stoppings built per second at full effort: a couple of hours to seal it.
        SEAL_PER_S = 1.4e-4

        # `waste:` pins `{ coal_kg:, temperature_k: }` instead of drawing it; a pinned `ground:` pins
        # none.
        def initialize(sealing: nil, waste: nil, **opts)
          @sealing = sealing&.to_sym
          @waste = waste&.transform_keys(&:to_sym)&.freeze
          super(**opts)
        end

        # **A waste that has been heating for days has used its air.** It holds what the trickle keeps
        # in it against the coal taking it up — the rest long since gone to blackdamp — so it does
        # not start with a lungful of fresh oxygen to burn through in its first minutes. **And it has
        # breathed out as it warmed**, so it starts at the pressure of the roads, holding less gas the
        # hotter it is.
        HEATING_AIR_KG = 18.0

        def initial_state(rng, content = nil)
          state = super
          waste = @waste || left_behind(rng, content)
          kelvin = waste.fetch(:temperature_k, ambient_k)
          parcels = waste.fetch(:coal_kg).positive? ? heating(state, waste, kelvin, content) : state.fetch(:parcels)
          state.merge(parcels: Parcel.normalise(parcels), joules: heat_capacity * kelvin, sealed: 0.0)
        end

        def heating(state, waste, kelvin, content)
          held = Parcel.total_kg(state.fetch(:parcels)) * ambient_k / kelvin
          [ Parcel.build(resource: :coal, kg: waste.fetch(:coal_kg), temperature_k: kelvin, content: content),
            Parcel.build(resource: :air, kg: HEATING_AIR_KG, temperature_k: kelvin, content: content),
            Parcel.build(resource: :blackdamp, kg: held - HEATING_AIR_KG, temperature_k: kelvin, content: content) ]
        end

        # **What the last shift left**: nothing, or a zone of drawn size at the temperature that brings
        # it to coal's ignition point in a drawn time. Solved against Newton's law of cooling with the
        # design heat: `T(t) = Tₐ + P/G + (T₀ − Tₐ − P/G)·e^(−Gt/C)`, inverted for `T₀`.
        def left_behind(rng, content)
          return { coal_kg: 0.0 } if rng.float < NONE_SHARE

          coal_kg = ZONE_COAL_KG * Math.exp(ZONE_SIGMA * GasPocket.standard_normal(rng).clamp(-2.5, 2.5))
          fires_in = [ FIRES_IN_S * Math.exp(FIRES_SIGMA * GasPocket.standard_normal(rng).clamp(-3.0, 3.0)), SOONEST_S ].max
          capacity = heat_capacity + (coal_kg * content.resource(:coal).fetch(:specific_heat_j_per_kg_k))
          { coal_kg: coal_kg, temperature_k: start_k(fires_in, capacity, content) }
        end

        def start_k(fires_in, capacity, content)
          fire_k = content.reaction(:coal_combustion).dig(:ignition, :autoignition_k).to_f
          settles = ambient_k + (DESIGN_HEAT_W / ambient_conductance)
          start = settles + ((fire_k - settles) * Math.exp(ambient_conductance * fires_in / capacity))
          start.clamp(ambient_k, fire_k - 1.0)
        end

        def reaction_throttle(state, content, reaction_id = nil)
          reaction_id == :coal_oxidation ? REACTIVITY : super
        end

        # **Breaking out**: past its rating its fire is through to the face, at once.
        def overload?(state, ctx, _integrity) = temperature_k(state, ctx.content) >= rated_temperature_k(ctx.content)

        def sealed(state) = state.fetch(:sealed, 0.0)

        def apply(state, ctx, grant)
          state, events = super
          worked = @sealing ? [ ctx.controls.fetch(@sealing, 0.0) / 100.0, 0.0 ].max : 0.0
          [ state.merge(sealed: [ sealed(state) + (SEAL_PER_S * worked * ctx.dt), 1.0 ].min), events ]
        end
      end

      # Breaking out: the waste's fire reaching the face.
      GOB_BREAKOUT = { tags: %i[burn afterdamp], places: { district: 1.6 } }.freeze

      # A pinned `ground:` inherits no heating waste.
      def gob(ground: nil)
        Gob.new(
          id: :gob, label: "The Waste", volume_m3: 300.0, sealing: :sealing, ground: ground,
          waste: ({ coal_kg: 0.0 } if ground),
          # The rock round the heating zone, warmed with it; and the little it loses to the strata,
          # which is the whole of the hazard.
          heat_capacity: 5.0e5, ambient_conductance: 40.0,
          initial_contents: [ { resource: :air, kg: 360.0 } ],
          reactions: %i[coal_oxidation coal_combustion],
          # Past this its fire is through to the face.
          max_temperature_k: 1_000.0, endangers: { rupture: GOB_BREAKOUT },
          ports: [ Port.new(id: :air_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 5.0),
                   Port.new(id: :air_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 5.0) ]
        )
      end

      # A leak through the waste, closed off by the stoppings as they are built. **Never to exactly
      # zero**: a zero conductance drops the path out of the pressure-driven regime, and it then
      # passes its port's whole rating — a sealed waste breathing harder than an open one.
      class GobLeak < Nodes::Conduit
        # What a fully sealed waste still leaks, as a share of the open figure.
        SEALED_LEAK = 1.0e-6

        def initialize(gob:, **opts)
          @gob = gob.to_sym
          super(**opts)
        end

        def gas_conductance(state, ctx)
          base = super or return nil
          base * [ 1.0 - ctx.node_state(@gob)&.fetch(:sealed, 0.0).to_f, SEALED_LEAK ].max
        end
      end

      def gob_leak(id)
        GobLeak.new(id: id, label: "Leakage Through the Waste", accepts: [ :gas ], gob: :gob,
                    max_kg_per_s: 5.0, conductance: GOB_LEAK_CONDUCTANCE, heat_capacity: 1.0e3)
      end

      # Each side of the waste. A trickle beside the main road's 0.8 — a few hundredths of a kilogram
      # a second, and the reason it can heat at all.
      GOB_LEAK_CONDUCTANCE = 0.004

      # **The goaf's gas, driven out when it falls**: while the goaf is flushing, the seep passes
      # `FLUSH_FACTOR` times its ordinary make.
      class GoafSeep < Seep
        def initialize(goaf:, **opts)
          @goaf = goaf.to_sym
          super(**opts)
        end

        def gas_conductance(state, ctx)
          base = super or return nil
          flushing = ctx.node_state(@goaf)&.fetch(:flushing_s, 0.0).to_f.positive?
          flushing ? base * OldWorkings::FLUSH_FACTOR : base
        end
      end

      # **Into the pit bottom, because blackdamp is heavy and runs downhill.** Firedamp collects
      # in the roof at the face; blackdamp lies in the dips, and the deepest dip in the mine is
      # the shaft bottom where the sump is. Buoyancy is not modelled, so the geometry says this
      # by where the seep is wired rather than by letting the parcel sink.
      #
      # Pressure-driven for the same reason the blower is — a rate cap between two passive
      # holders moves nothing or everything — and it gives the same behaviour for free: it vents
      # harder into a pit bottom that has been cleared than into one already full of it.
      def goaf_seep(conductance:, ground: nil)
        GoafSeep.new(
          id: :goaf_seep, label: "Blackdamp", accepts: [ :gas ], ground: ground, goaf: :goaf,
          max_kg_per_s: 0.5, conductance: conductance, heat_capacity: 1.0e3
        )
      end

      # **Light on the roadway, as opposed to light in your hand.**
      #
      # Hewing is `gated_by: %i[mining_effectiveness darkvision]` and a gate is a *zero* when it
      # is missing, so light is not a bonus — it is the difference between a shift that wins
      # coal and one that does not. A lamp on your belt is the minion's own tag; this is the
      # other way of getting it, and `Minion#gate` takes the better of the two rather than the
      # sum, because two lamps do not let you see twice.
      #
      # **A `Load`, always**, even for the tiers that burn nothing: the unpowered ones simply
      # declare no torque and hang off no shaft, so their `omega` stays zero and is never
      # consulted. That keeps one class, one node id and one slot across a tech tree whose top
      # end is wired to the engine house and whose bottom end is a candle on a nail.
      #
      # **An open-flame tier is an ignition source in the room it lights**, and a safe tier is
      # not: it declares no flame and offers nothing to `Tick#ignition_sources`. The lever's id
      # differs too — `:naked_flame` against `:safe_light` — because a fire names what lit it, and
      # "naked flame" tells the player what to stop doing. Both are labelled "Sconces", because
      # to the player it is one lever either way — and neither may be called `:sconces`, which is
      # the NODE: one flat id namespace.
      #
      # **A gauze is safe only in still enough air.** Past `gauze_passes_m_s` of draught through the
      # district — measured off the intake road as of last tick — the flame is blown through the
      # mesh and the lamp is a naked light after all, named `:gauze` so a fire says so. A stronger
      # fan is what gets it there.
      #
      # **Lamps on a dynamo over-run.** Driven past `BLOWS_AT` of rated speed — less once worn — the
      # filaments go, and the district is dark with the shift still in it. A flame on a bracket has
      # no dynamo and cannot.
      class Lighting < Nodes::Load
        include Concerns::Wearing

        attr_reader :illumination, :gauze_passes_m_s

        # The intake road's cross-section the draught is read across, m².
        ROADWAY_M2 = 4.0

        BLOWS_AT = 1.4

        def overload?(state, _ctx, integrity)
          return false unless @rated_omega.positive?

          omega(state).abs / @rated_omega > 1.0 + ((BLOWS_AT - 1.0) * integrity)
        end

        def failure_modes = { blown: { derates: { illumination: 0.0 } } }

        def initialize(illumination:, igniter_kg_per_s: 0.0, flame_watts: 0.0,
                       gauze_passes_m_s: nil, draught_from: :main_road, **opts)
          @illumination = illumination.to_f
          @igniter_kg_per_s = igniter_kg_per_s.to_f
          @flame_watts = flame_watts.to_f
          @gauze_passes_m_s = gauze_passes_m_s&.to_f
          @draught_from = draught_from.to_sym
          super(**opts)
        end

        # What somebody standing in this room gets for free. Read off N−1 state and the
        # actuated levers, so it cannot depend on phase order.
        def ambient_tags(state, levers) = { darkvision: lit(state, levers) }

        # **The flame goes with the lever, not with the light.** A candle turned down is fewer
        # candles, each as hot as ever, so a powered tier's shaft speed has no say here.
        def ignition(state, levers)
          fraction = (levers.fetch(@control_id, 0.0) / 100.0).clamp(0.0, 1.0)
          return through_the_gauze(state, fraction) if @gauze_passes_m_s
          return nil unless @igniter_kg_per_s.positive?

          { kg_per_s: @igniter_kg_per_s * fraction, watts: @flame_watts * fraction,
            cause: @control_id }
        end

        def through_the_gauze(state, fraction)
          return nil unless state.fetch(:draught_m_s, 0.0) > @gauze_passes_m_s

          { kg_per_s: OPEN_FLAME.fetch(:igniter_kg_per_s) * fraction,
            watts: OPEN_FLAME.fetch(:flame_watts) * fraction, cause: :gauze }
        end

        def draught_m_s(ctx)
          kg = ctx.node_state(@draught_from)&.fetch(:carried_kg, 0.0).to_f
          kg / Units::AIR_DENSITY_KG_PER_M3 / ROADWAY_M2 / ctx.dt
        end

        # Turned down is dimmer; a powered tier whose shaft has stopped is dark. Both are
        # fractions of what this fitting manages at full.
        def lit(state, levers)
          fraction = @control_id ? (levers.fetch(@control_id, 0.0) / 100.0).clamp(0.0, 1.0) : 1.0
          fraction *= (omega(state).abs / @rated_omega).clamp(0.0, 1.0) if @rated_omega.positive?

          @illumination * fraction * derating(state, :illumination)
        end

        # Recorded so the panel can read it as an ordinary field, the way `carried_kg` is.
        def apply(state, ctx, grant)
          super.merge(lit: lit(state, ctx.controls), draught_m_s: draught_m_s(ctx))
        end
      end

      # What the open flames down the roadway offer the district: enough seed to light a mixture
      # that will carry it, and a little heat. In gas too lean to carry it the seed is what they
      # burn — a flame cap apiece, about a kilowatt of firedamp for the row.
      OPEN_FLAME = { igniter_kg_per_s: 2.0e-5, flame_watts: 1.2e3 }.freeze

      def sconces(illumination:, control_id:, max_torque: 0.0, rated_omega: 0.0, flame: {})
        Lighting.new(
          id: :sconces, label: "Sconces", illumination: illumination, control_id: control_id,
          max_torque: max_torque, rated_omega: rated_omega, curve: :viscous,
          moment_of_inertia: 12.0, **flame
        )
      end

      # **The hewer's lever, and an effort station**: what comes of it depends on who is swinging
      # the pick. Shaped exactly like the stoker's line on the steam engine.
      # **The node is a noun and the lever is a gerund**, as `:stoker`/`:stoking` is on the
      # engine — node, control point, gauge and minion ids share one flat namespace, so a
      # conduit and its own lever cannot both be called `:hewing`.
      # **A cutter's picks strike sparks** off the pyrite and sandstone in the seam, in the room they
      # are cutting in, for as long as they are cutting — read off what it cut last tick. A hand
      # pick declares no `sparks:` and strikes none.
      #
      # **Wet, they strike none that can light anything.** Water sprayed on the picks quenches the hot
      # streak behind each one below what fires methane, so while the sprays (`SprayLine`) are
      # wetting the face fully the cutter offers no spark. A spray running short is no protection: a
      # spark quenched part way is still a spark.
      class PickLine < Nodes::Conduit
        def initialize(sparks: nil, sprayed_by: :spray_line, **opts)
          @sparks = sparks&.freeze
          @sprayed_by = sprayed_by.to_sym
          super(**opts)
        end

        attr_reader :sparks, :sprayed_by

        def ignition(state, _levers)
          cutting = state.fetch(:cutting, 0.0)
          return nil unless @sparks && cutting.positive? && !state.fetch(:quenched, false)

          { kg_per_s: @sparks.fetch(:kg_per_s) * cutting, watts: @sparks.fetch(:watts) * cutting,
            cause: :cutter_sparks }
        end

        # How hard it was cutting this tick, against a full face, and whether the sprays had it wet.
        def apply(state, ctx, grant)
          cut = state.fetch(:carried_kg, 0.0) / (full_crew_kg_per_s * ctx.dt)
          super.merge(cutting: cut.clamp(0.0, 1.0), quenched: SprayLine.wetting(ctx, @sprayed_by) >= 1.0)
        end
      end

      # A frictional spark: a spark's seed, enough to fire a mixture in the band, almost no heat.
      CUTTER_SPARKS = { kg_per_s: 1.0e-7, watts: 30.0 }.freeze

      def pick_line(max_kg_per_s:, crew:, sparks: nil)
        PickLine.new(
          id: :pick_line, label: "Hewing", accepts: [ :solid ],
          max_kg_per_s: max_kg_per_s, heat_capacity: 2.0e3,
          control_id: :hewing, sparks: sparks, worked: true, crew: crew
        )
      end

      # **Water sprays on the cutter**, from the sump: a small pump off the line shaft lifts it to the
      # face, where it wets the picks and lays the dust they make, and runs back down the road to the
      # sump. So it runs while the sump has water and the shaft turns, and a sump pumped bare stops
      # it. **How wet the face is** is what it passed last tick against what it is rated for: at half
      # its rating and above, fully.
      class SprayLine < Nodes::Conduit
        FULL_AT = 0.5

        def initialize(**opts)
          @rated_kg_per_s = opts.fetch(:max_kg_per_s).to_f
          super
        end

        def wetting(state, dt)
          share = state.fetch(:carried_kg, 0.0) / (@rated_kg_per_s * dt)
          (share / FULL_AT).clamp(0.0, 1.0)
        end

        # Zero where no sprays are fitted.
        def self.wetting(ctx, id)
          node = ctx.nodes&.[](id)
          state = ctx.node_state(id)
          node.respond_to?(:wetting) && state ? node.wetting(state, ctx.dt) : 0.0
        end
      end

      # About 24 litres a minute through the cutter's jets, at three bar.
      SPRAY_KG_PER_S = 0.4
      SPRAY_HEAD_PA = 3.0e5

      def spray_line
        SprayLine.new(id: :spray_line, label: "Cutter Sprays", accepts: [ :liquid ],
                      max_kg_per_s: SPRAY_KG_PER_S, heat_capacity: 500.0, control_id: :spraying,
                      driven_by: :line_shaft, displacement: true, rated_omega: WORKING_OMEGA,
                      head_pa: SPRAY_HEAD_PA, lift_m: ROAD_RISE_M, efficiency: 0.5)
      end

      # The spray water running back down the road to the sump.
      def face_drain
        Nodes::Conduit.new(id: :face_drain, label: "Face Drain", accepts: [ :liquid ],
                           max_kg_per_s: 2.0, heat_capacity: 500.0)
      end

      # **The shot hole: drilled, charged and fired by the shotfirer**, a tonne and a half of coal at
      # a time (`design_sketches/mine-accidents-unit4.md` §3). The conduit is the charge line from
      # the magazine: it passes one charge on the tick after the hole is ready, and the charge reacts
      # in the district's air the tick it lands, leaving its fumes. The coal and dust it brings down
      # follow through `ShotYield`, off the running total in `brought_down_kg`.
      #
      # **Its accidents are mishaps of the shotfirer's post**, so a poor hand has more of them: a
      # shot that blows out of its hole is, for a tick, a flame in the room; a charge that misfires
      # stays in the hole. **What then happens to a misfire is the shotfirer's judgement**:
      #
      # - recognised, it is a known misfire he digs out, **all or nothing** — its hazard is at full
      #   weight while any of it remains, and the clearing completes in one tick;
      # - taken for a spent shot, it is a **live charge left in the face** nobody knows of, which a
      #   hewer working the face can strike and set off on himself.
      #
      # Either going off is a blast to whoever set it off and a flame in the room for a tick.
      class ShotHole < Nodes::Conduit
        # Seconds of a sound shotfirer's work to drill, charge and fire one hole.
        SHOT_S = 900.0

        # And to dig out a charge that did not go off. Slower than drilling a fresh hole, because
        # it is done with a wooden scraper and nobody hurries it.
        CLEAR_S = 1_200.0

        # What one shot brings down, kg; a blown-out shot brings down this share of it.
        SHOT_COAL_KG = 1_500.0
        BLOWN_OUT_YIELD = 0.25

        # How long a shot reads as just fired, s.
        FIRED_S = 30.0

        STATUSES = %i[idle charging fired misfire clearing].freeze

        attr_reader :charge_kg, :blowout, :perils

        # `blowout:` is the flame a blown-out shot offers the room for its one tick.
        def initialize(charge_kg:, blowout:, perils:, **opts)
          @charge_kg = charge_kg.to_f
          @blowout = blowout.freeze
          @perils = perils.freeze
          super(**opts)
        end

        def base_initial_state(rng, content)
          super.merge(progress: 0.0, firing: false, misfires: 0, live: 0, clearing: 0.0,
                      brought_down_kg: 0.0, blew_out: false, blowout_pending: false,
                      misfire_pending: false, misjudged_pending: false, work: 0.0, hewing: 0.0,
                      since_fired_s: FIRED_S, status: 0)
        end

        # One charge, on the tick the hole is ready; nothing otherwise.
        def throughput_kg(state, _ctx) = state.fetch(:firing) ? @charge_kg : 0.0

        def ignition(state, _levers) = state.fetch(:blew_out) ? @blowout : nil

        # `:misfired` is a known misfire, at full weight until it is dug out; `:live` a charge left in
        # the face, struck by working it — so it scales with the hewing as well.
        def activity(state, quantity, _dt)
          case quantity
          when :firing then state.fetch(:work).clamp(0.0, 1.0)
          when :misfired then state.fetch(:misfires).positive? ? 1.0 : 0.0
          when :live then state.fetch(:live).positive? ? state.fetch(:hewing).clamp(0.0, 1.0) : 0.0
          end
        end

        MISHAPS = %i[blowout misfire misjudged set_off struck].freeze

        def suffers?(kind) = MISHAPS.include?(kind) || super

        # `misfire` and `misjudged` mark the charge being made; `set_off` and `struck` fire a known
        # misfire and a live charge, which is a flame in the room for a tick and a little coal.
        def suffer(state, mishap, ctx)
          case mishap.fetch(:kind)
          when :blowout then [ state.merge(blowout_pending: true), [] ]
          when :misfire then [ state.merge(misfire_pending: true), [] ]
          when :misjudged then [ state.merge(misjudged_pending: true), [] ]
          when :set_off then [ went_off(state, :misfires), [] ]
          when :struck then [ went_off(state, :live), [] ]
          else super
          end
        end

        # `hewing` is the face's busy-ness against a full crew, which is what a live charge in it
        # scales with: every hewer on it is somebody who might strike it.
        def apply(state, ctx, grant)
          work = [ ctx.controls.fetch(:shotfiring, 0.0) / 100.0, 0.0 ].max
          face_crew = ctx.nodes[:pick_line]&.crew || 1
          hewing = [ ctx.controls.fetch(:hewing, 0.0) / 100.0 / face_crew, 0.0 ].max
          shot = fired(super, ctx).merge(work: work, hewing: hewing)
          shot = shot.fetch(:misfires).positive? ? dig_out(shot, work, ctx) : charge(shot, work, ctx)
          shot.merge(status: STATUSES.index(status(shot)))
        end

        private

        # What last tick's firing did, now the charge line has passed what the magazine had.
        def fired(state, ctx)
          since = state.fetch(:since_fired_s) + ctx.dt
          return state.merge(blew_out: false, since_fired_s: since) unless state.fetch(:firing)

          share = (state.fetch(:carried_kg, 0.0) / @charge_kg).clamp(0.0, 1.0)
          blew = state.fetch(:blowout_pending) && share.positive?
          coal = SHOT_COAL_KG * share * (blew ? BLOWN_OUT_YIELD : 1.0)
          state.merge(firing: false, blew_out: blew, blowout_pending: false, since_fired_s: 0.0,
                      brought_down_kg: state.fetch(:brought_down_kg) + coal)
        end

        # A charge that misfires stays where it is: known, it waits to be dug out; misjudged, it is
        # left live in the face and the shotfirer goes on to the next hole.
        def charge(state, work, ctx)
          progress = state.fetch(:progress) + (work * ctx.dt / SHOT_S)
          return state.merge(progress: progress) if progress < 1.0

          done = state.merge(progress: 0.0, misfire_pending: false, misjudged_pending: false)
          return done.merge(live: state.fetch(:live) + 1) if state.fetch(:misjudged_pending)
          return done.merge(misfires: state.fetch(:misfires) + 1) if state.fetch(:misfire_pending)

          done.merge(firing: true)
        end

        def went_off(state, which)
          return state unless state.fetch(which).positive?

          state.merge(which => state.fetch(which) - 1, blew_out: true, clearing: which == :misfires ? 0.0 : state.fetch(:clearing),
                      brought_down_kg: state.fetch(:brought_down_kg) + (SHOT_COAL_KG * BLOWN_OUT_YIELD))
        end

        def dig_out(state, work, ctx)
          clearing = state.fetch(:clearing) + (work * ctx.dt / CLEAR_S)
          return state.merge(clearing: clearing) if clearing < 1.0

          state.merge(clearing: 0.0, misfires: state.fetch(:misfires) - 1)
        end

        def status(state)
          if state.fetch(:misfires).positive?
            state.fetch(:work).positive? ? :clearing : :misfire
          elsif state.fetch(:since_fired_s) < FIRED_S
            :fired
          else
            state.fetch(:work).positive? ? :charging : :idle
          end
        end
      end

      # **What a shot brings down, coming down**: coal off the seam, or the dust it raises, at
      # `share` of what the shot hole's shots have brought down in all, as fast as it can fall.
      # Passes what is still owed against what it has passed already, so a shot's yield arrives
      # whatever ticks it lands on.
      class ShotYield < Nodes::Conduit
        def initialize(shot_hole:, share:, **opts)
          @shot_hole = shot_hole.to_sym
          @share = share.to_f
          super(**opts)
        end

        def base_initial_state(rng, content) = super.merge(owed_kg: 0.0, passed_kg: 0.0)

        def throughput_kg(state, ctx) = [ state.fetch(:owed_kg), super ].min

        def apply(state, ctx, grant)
          passed = state.fetch(:passed_kg) + state.fetch(:carried_kg, 0.0)
          down = ctx.node_state(@shot_hole)&.fetch(:brought_down_kg, 0.0).to_f * @share
          super.merge(passed_kg: passed, owed_kg: [ down - passed, 0.0 ].max)
        end
      end

      # **The shot's flame for the tick it blows out**: a seed and real heat, black powder's long
      # and hot, a permitted explosive's short and cool — the difference is in the peril's rate, and
      # the flame itself is what a blown-out shot is.
      BLOWN_OUT_SHOT = { kg_per_s: 0.4, watts: 4.0e6, cause: :blown_out_shot }.freeze

      # **The magazine**, at bank: the charges a pit has, which run down as it fires.
      def magazine(resource:, kg:)
        Nodes::Vessel.new(
          id: :magazine, label: "Magazine", volume_m3: 2.0, ambient_conductance: 0.0,
          initial_contents: [ { resource: resource, kg: kg } ],
          ports: [ Port.new(id: :out, direction: :outlet, accepts: [ :explosive ], max_kg_per_s: 40.0) ]
        )
      end

      def shot_hole(charge_kg:, perils:)
        ShotHole.new(
          id: :shot_hole, label: "Shot Holes", accepts: [ :explosive ], max_kg_per_s: 40.0,
          heat_capacity: 1.0e3, charge_kg: charge_kg, blowout: BLOWN_OUT_SHOT, perils: perils
        )
      end

      def shot_fall
        ShotYield.new(id: :shot_fall, label: "Shot Coal", accepts: [ :solid ], max_kg_per_s: 60.0,
                      heat_capacity: 1.0e3, shot_hole: :shot_hole, share: 1.0)
      end

      # A hundredth of the coal a shot brings down goes up as dust it raises.
      def shot_dust
        ShotYield.new(id: :shot_dust, label: "Shot Dust", accepts: [ :dust ], max_kg_per_s: 5.0,
                      heat_capacity: 1.0e3, shot_hole: :shot_hole, share: 0.01)
      end

      # **A roadway that can come in on top of you.**
      #
      # Specific to a mine rather than generic, so it lives here: what wears a haulage road out
      # is not heat, it is **ground being opened faster than it is being supported**. Hewing
      # advances the face and exposes fresh roof; timbering sets props behind it. Run the one
      # without the other and the roof takes up the difference.
      #
      # Roof falls were the steady, unspectacular majority of deaths in every coalfield — far
      # more than every explosion put together — and they are undramatic in exactly this way:
      # nothing goes wrong suddenly, somebody simply did not set enough timber.
      class Roadway < Nodes::Conduit
        # Durability per second for each kg/s of coal cut beyond what the timbering keeps up with.
        #
        # **Against `Wearing::DEFAULT_DURABILITY_RANGE`, which is 850–1150, not 0–1.** A rate is
        # meaningless without the scale it is against; check the pool before picking the rate.
        #
        # A full hand face of five hewers with a decent kit cuts about 0.3 kg/s, and wholly
        # unsupported brings the road in at about ten minutes: long enough to see it coming and
        # send somebody, short enough to happen inside a match.
        UNSUPPORTED_RATE = 5.2

        # How much cutting one competent timberer keeps propped: three hand hewers' worth. A
        # tuning figure until a source turns up; a cutter's face wants more timbermen, because it
        # opens ground faster.
        TIMBERED_KG_PER_S = 0.36

        # `endangers:` lives here rather than on `Conduit`, because a pipe that hurts the people
        # beside it is a general idea nothing else has needed yet and a roadway coming in is
        # not. `Tick#hazards_from` only asks whether a node responds to `failure_hazards`, so a
        # subclass answering is enough.
        # `rope:` names the haulage rope a road's sets are drawn on, if it has one: parted, the road
        # carries nothing until it is spliced. `advanced_by:` is the node that cuts the face, and
        # what it cut last tick is the ground opened; `supported_by:` is the timbering post.
        def initialize(advanced_by:, supported_by:, endangers: {}, perils: [], rope: nil, **opts)
          @rope = rope&.to_sym
          @advanced_by = advanced_by.to_sym
          @supported_by = supported_by.to_sym
          @failure_hazards = endangers.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          @perils = perils.freeze
          super(**opts)
        end

        attr_reader :failure_hazards, :perils

        def throughput_kg(state, ctx)
          return 0.0 if @rope && ctx.node_state(@rope)&.fetch(:failure, nil)

          super
        end

        # **The difference, floored at zero, never the ratio.** A ratio makes a face nobody is
        # working still consume timber to stand still, and a district standing idle does not
        # fall in — it is cutting that opens ground.
        def stress_per_second(state, ctx)
          (unsupported_kg_per_s(ctx) * UNSUPPORTED_RATE) + super
        end

        # Coal cut beyond what the timbering keeps up with, kg/s. Cutting is what opens ground, so
        # this reads what the face actually cut rather than how hard it was asked to.
        def unsupported_kg_per_s(ctx)
          return 0.0 unless ctx.dt.positive?

          cut = ctx.node_state(@advanced_by)&.fetch(:carried_kg, 0.0).to_f / ctx.dt
          propped = ctx.controls.fetch(@supported_by, 0.0) / 100.0 * TIMBERED_KG_PER_S
          [ cut - propped, 0.0 ].max
        end

        # A fall does not seal a roadway, it chokes it — a few tubs a shift get past over the
        # debris until it is cleared. Never 0.0: a road that passes nothing is a better seal
        # than a sound one, which is the trap `nodes/CLAUDE.md` records for ruptures.
        # **How busy the road is, 0..1.** What a peril on a haulage road scales with is the
        # traffic, not the clock — the tub going past is the danger, so a road being worked
        # flat out is a road that hurts people and an idle one is a corridor.
        def activity(state, quantity, dt)
          return nil unless quantity == self.class::TRAFFIC

          (state.fetch(:carried_kg, 0.0) / (full_crew_kg_per_s * dt)).clamp(0.0, 1.0)
        end

        # What its perils scale with: the tubs going past.
        TRAFFIC = :tubs

        def failure_modes = { roof_fall: { derates: { throughput: 0.12 } } }

        def failure_mode(_state, _ctx, _cause) = :roof_fall

        def failure_detail(state, ctx)
          { unsupported: unsupported_kg_per_s(ctx).round(3),
            carried_kg: state.fetch(:carried_kg, 0.0).round(3) }
        end
      end

      # **A pure safety fitting**: manholes cut in a roadway side, gates across the shaft at bank.
      # It wins no coal, spends money, and does nothing whatever visible until the day it is used.
      #
      # It holds no material and has no ports, which is correct — it is not in the way of
      # anything. What it contributes is the place it guards.
      class Guard < ReactorSim::Node
        def initialize(effectiveness:, places:, **opts)
          @safety_equipment = places.to_h { |place| [ place.to_sym, effectiveness.to_f ] }.freeze
          super(**opts)
        end

        attr_reader :safety_equipment
      end

      def manholes(effectiveness:, label:)
        # Both ends of the haulage road, because the road runs between them and the tubs go
        # the whole way: a refuge at one end is no use at the other.
        Guard.new(id: :manholes, label: label, effectiveness: effectiveness,
                  places: %i[pit_bottom district])
      end

      # Shut, a tub cannot run past the banksman into the shaft; but somebody has to shut them.
      def shaft_gates(effectiveness:, label:)
        Guard.new(id: :shaft_gates, label: label, effectiveness: effectiveness, places: %i[bank])
      end

      # **The haulage road rises from the pit bottom to the district**, the sump being the lowest
      # point in the pit: full sets come down to the shaft and empties go back up. Gentle enough
      # that putting is unchanged on it; steep enough that a set loose on it runs.
      ROAD_RISE_M = 12.0
      ROAD_M = 200.0

      # **The rope a haulage engine draws its sets on**, and what happens when it lets go. Its
      # tension is a set down the incline — `m·g·(sin θ + rolling)` — and it wears with the
      # traffic it hauls. Sound, it never parts under a set's weight; what parts a worn one is the
      # **snatch** as a set is started, several times the standing tension. Parted, the set runs
      # back down to the shaft (`RUNAWAY`) and the haulage stops until the hauling hands splice it.
      #
      # A set breaking away is the other way: a hooker-on coupling a set without its backstay, a
      # mishap of the haulage post (`:breakaway`).
      class HaulageRope < Node
        include Concerns::Wearing

        # Ten tubs: two tonnes of coal and their own iron.
        SET_KG = 2_600.0
        ROLLING = 0.02

        # A set started hard: what a worn rope parts under.
        SNATCH = 8.0

        # Durability per second at full traffic: about six hours' hauling from new.
        WEAR_PER_S = 0.046

        # Seconds of a hauling hand's work to splice a parted rope.
        SPLICE_S = 600.0

        attr_reader :road, :breaking_kn, :splice_control, :perils, :failure_hazards, :failure_damages

        def initialize(id:, road:, breaking_kn:, splice_control:, perils: [], endangers: {}, damages: {},
                       label: nil)
          super(id: id, label: label)
          @road = road.to_sym
          @breaking_kn = breaking_kn.to_f
          @splice_control = splice_control.to_sym
          @perils = perils.freeze
          @failure_hazards = endangers.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          @failure_damages = damages.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          freeze
        end

        def base_initial_state(rng, content) = super.merge(traffic: 0.0, splicing: 0.0)

        def self.tension_n = SET_KG * Units::GRAVITY_M_PER_S2 * ((ROAD_RISE_M / ROAD_M) + ROLLING)

        def hauling?(state) = state.fetch(:traffic).positive?

        def stress_per_second(state, _ctx) = WEAR_PER_S * state.fetch(:traffic)

        def overload?(state, _ctx, integrity)
          hauling?(state) && SNATCH * HaulageRope.tension_n > @breaking_kn * 1_000.0 * integrity
        end

        def failure_modes = { parted: {} }

        def failure_detail(_state, _ctx) = { set_kg: SET_KG }

        def activity(state, quantity, _dt) = quantity == :hauling ? state.fetch(:traffic) : nil

        def suffers?(kind) = kind == :breakaway || super

        def suffer(state, mishap, ctx)
          return super unless mishap.fetch(:kind) == :breakaway

          broken?(state) ? [ state, [] ] : break_part(state, ctx, :mishap)
        end

        # How busy the road is, as of last tick, and — parted — the splice coming on.
        def apply(state, ctx, _grant)
          road = ctx.node_state(@road) || {}
          rated = ctx.nodes&.[](@road)&.full_crew_kg_per_s.to_f * ctx.dt
          traffic = rated.positive? ? (road.fetch(:carried_kg, 0.0) / rated).clamp(0.0, 1.0) : 0.0
          state = state.merge(traffic: traffic)
          return state unless broken?(state)

          splice(state, ctx)
        end

        private

        def splice(state, ctx)
          work = [ ctx.controls.fetch(@splice_control, 0.0) / 100.0, 0.0 ].max
          progress = state.fetch(:splicing) + (work * ctx.dt / SPLICE_S)
          return state.merge(splicing: progress) if progress < 1.0

          state.merge(failure: nil, durability: state.fetch(:initial_durability), splicing: 0.0)
        end
      end

      # **A set loose on the incline**: it runs back down to the shaft, gathering speed, and what
      # it does to somebody is where on the road they are (`Tick#along`). The district end meets it
      # as it breaks away; the trapper at the doors near the foot, near its fastest; and at the pit
      # bottom it is off its rails and amongst everybody there — the onsetter, whoever is waiting to
      # ride. The hands working the road are somewhere along it, may reach a manhole, and, well down
      # it, may be pinned against the side or between it and a standing tub.
      RUNAWAY = {
        tags: %i[impact], scales_with: :set_kg, reference: HaulageRope::SET_KG,
        along: { from: :district, to: :pit_bottom, weight: 3.0, top_share: 0.1,
                 positions: { trapping: 0.9 }, roaming: %i[haulage],
                 crushed: { chance: 0.5, factor: 2.0, tags: %i[crush], cause: :crushed_by_runaway } }
      }.freeze

      # **A hooker-on coupling a set without its backstay**, by how hard the road is worked.
      SET_BREAKS_AWAY = Peril.new(id: :set_broke_away, rate: 0.08, scales_with: :hauling,
                                  stations: %i[haulage], mishap: { node: :haulage_rope, kind: :breakaway })

      # `catch:` is a fitted runaway catch (`{ at:, holds: }`): the run stops most sets at it, and
      # what it stops never reaches the door.
      def haulage_rope(breaking_kn:, catch: nil)
        runaway = catch ? RUNAWAY.merge(along: RUNAWAY.fetch(:along).merge(catch: catch.freeze).freeze).freeze : RUNAWAY
        door = 1.0 - (catch ? catch.fetch(:holds) : 0.0)
        HaulageRope.new(id: :haulage_rope, label: "Haulage Rope", road: :tub_road, breaking_kn: breaking_kn,
                        splice_control: :haulage, perils: [ SET_BREAKS_AWAY ],
                        endangers: { parted: runaway }, damages: { parted: { door: door } })
      end

      # What the haulage engine pays per kilogram of coal, as a lift: the empties drawn back up the
      # rise and both ways' rolling, less nothing for the full sets it lets down under the brake.
      HAULED_LIFT_M = 10.0

      # `driven:` makes it a rope haulage: a haulage engine off the line shaft drawing sets on
      # `rope:`, moving coal only while the shaft turns and paying the shaft for the empties it
      # draws back up. Without it the road is put by hand.
      # `max_kg_per_s` is one putter's, or one hauling hand's, and `crew:` how many the road takes.
      def tub_road(max_kg_per_s:, crew:, driven: false, rope: nil)
        Roadway.new(
          rope: rope,
          **(driven ? { driven_by: :line_shaft, displacement: true, rated_omega: WORKING_OMEGA,
                        lift_m: HAULED_LIFT_M, efficiency: 0.6 } : {}),
          advanced_by: :pick_line, supported_by: :timbering,
          id: :tub_road, label: "Haulage Road", accepts: [ :solid ],
          max_kg_per_s: max_kg_per_s, heat_capacity: 4.0e3,
          control_id: :haulage, worked: true, crew: crew,
          # Who is under it when it comes in. **The road runs between two rooms and the fall
          # reaches both** — the putter's end worst, because he is on it, and the face less.
          # Keyed by place rather than by post, so the timberman standing at the face is caught
          # too, which he plainly should be and was not while a hazard reached people through
          # the job they were doing.
          endangers: {
            # `reference:` is in kg/s of unsupported cutting, the unit `unsupported` is reported
            # in: a full hand face wholly unsupported reads about 0.3 with a decent kit.
            roof_fall: { tags: %i[rockfall crush], scales_with: :unsupported,
                         reference: 0.2,
                         places: { pit_bottom: 2.6, district: 1.6 } }
          },
          # **What the road does to people with nothing broken at all**, which is the majority
          # of what a haulage road ever did to anybody. Both scale with the traffic, so the
          # haulage lever is the production dial and the danger dial at once.
          #
          # The two are **mutually exclusive by build**, which is the point of tag-selected
          # perils: a big minion gets wedged against the side where a small one would have
          # room, and a small one is missed by a driver where a big one would have been seen.
          # Neither is simply better in the road — they are exposed to different accidents.
          perils: [
            Peril.new(id: :caught_in_haulage, tags: %i[crush], severity: 2.2,
                      scales_with: :tubs, places: %i[pit_bottom district]),
            Peril.new(id: :wedged, tags: %i[crush], severity: 2.6, scales_with: :tubs,
                      when_tagged: :hulking, places: %i[pit_bottom district]),
            Peril.new(id: :struck_by_tub, tags: %i[impact], severity: 1.4, scales_with: :tubs,
                      unless_tagged: :hulking, places: %i[pit_bottom district])
          ]
        )
      end

      # **A belt conveyor on the road**, off the line shaft, carrying with no hand on it. The drive
      # drum pulls the belt by friction, `grip_kg_per_s` of coal's worth; a loading point pushing more
      # onto it than that **stalls** it, and a slipping belt does not recover, because a belt sliding
      # on its drum grips less than one standing on it. Stalled, it carries nothing and the drum turns
      # on under it, its friction the drive's heat (`bearing_load_n`, the drum's `loaded_by:`). Water
      # on the pit bottom wets the drum and takes grip away.
      class Conveyor < Roadway
        TRAFFIC = :belt

        # The pull at which the belt slips, and slipping it drags at about that: a 4.4 kN slack side
        # round 210° of drum at rubber-on-steel μ 0.35 holds 11.5 kN by the capstan law, which is a
        # five-ply 30-inch cotton belt at its working tension.
        SLIP_FORCE_N = 11_500.0
        BELT_MU = 0.35

        # Wet rubber on steel grips at about 0.2, which takes most of the capstan's margin.
        WET_GRIP_LOSS = 0.6

        def initialize(grip_kg_per_s:, fed_from:, wetted_by:, **opts)
          @grip_kg_per_s = grip_kg_per_s.to_f
          @fed_from = fed_from.to_sym
          @wetted_by = wetted_by.to_sym
          super(**opts)
        end

        attr_reader :grip_kg_per_s, :fed_from, :wetted_by

        def throughput_kg(state, ctx) = stalled?(ctx) ? 0.0 : super

        # **What the loading point pushes on, against what the drum can pull.** Both at the belt's
        # speed, since a slower belt carries its load deeper for the same pull.
        def stalled?(ctx)
          share = displacement_fraction(ctx)
          return false unless share.positive?

          pushed = full_crew_kg_per_s * ctx.dt * open_fraction(ctx) * share
          [ pushed, waiting_kg(ctx) ].min > grip_kg_per_s_now(ctx) * share * ctx.dt
        end

        def grip_kg_per_s_now(ctx) = @grip_kg_per_s * (1.0 - (WET_GRIP_LOSS * wetness(ctx)))

        # Slipping at `BELT_MU`, the drum drags at `SLIP_FORCE_N`; gripping, it does not rub at all.
        def bearing_load_n(ctx) = stalled?(ctx) ? SLIP_FORCE_N / BELT_MU : 0.0

        private

        def waiting_kg(ctx)
          parcels = ctx.node_state(@fed_from)&.fetch(:parcels, nil) || []
          Parcel.total_kg(Parcel.matching(parcels, port(:inlet).accepts, ctx.content))
        end

        def wetness(ctx)
          node = ctx.nodes&.[](@wetted_by)
          state = ctx.node_state(@wetted_by)
          node.respond_to?(:flooding) && state ? node.flooding(state, ctx.content) : 0.0
        end
      end

      # The belt's speed at the line shaft's working speed.
      BELT_M_PER_S = 2.0

      # What the belt drive pays per kilogram of coal, as a lift: its idlers' drag both ways, the
      # coal's descent being taken by the drive's brake rather than given back.
      BELT_LIFT_M = 6.0

      def conveyor(max_kg_per_s:, grip_kg_per_s:)
        Conveyor.new(
          grip_kg_per_s: grip_kg_per_s, fed_from: :district, wetted_by: :pit_bottom,
          driven_by: :line_shaft, displacement: true, rated_omega: WORKING_OMEGA,
          lift_m: BELT_LIFT_M, efficiency: 0.7,
          advanced_by: :pick_line, supported_by: :timbering,
          id: :tub_road, label: "Belt Road", accepts: [ :solid ],
          max_kg_per_s: max_kg_per_s, heat_capacity: 4.0e3, control_id: :haulage,
          endangers: { roof_fall: { tags: %i[rockfall crush], scales_with: :unsupported, reference: 30.0,
                                    places: { pit_bottom: 2.6, district: 1.6 } } },
          # Caught in the belt where it runs onto the drum: the attendant, clearing spillage at
          # the drive head.
          perils: [ Peril.new(id: :caught_in_the_belt, tags: %i[crush], severity: 2.4, scales_with: :belt,
                              stations: %i[belt_attending]) ]
        )
      end

      # **The drive drum**, rubbing only while the belt is stalled on it (`Conveyor#bearing_load_n`):
      # dry, at the belt's friction, its heat the drive's 23 kW at working speed. A gate-end drum,
      # 16 inches across and 0.7 m wide in an 8 mm steel shell, is about 55 kg. It sheds heat so
      # that under a belt stalled for good it settles about 773 K, the most stalled drums are
      # measured at — and lower as the drag slows the shaft.
      DRUM_HEAT_CAPACITY_J_PER_K = 2.7e4

      def belt_drive
        Nodes::Bearing.new(
          id: :belt_drive, label: "Belt Drive", supports: :line_shaft, duty: :journal, material: :steel,
          heat_capacity: DRUM_HEAT_CAPACITY_J_PER_K, ambient_conductance: 46.0,
          loaded_by: :tub_road, static_load_n: 0.0, journal_radius_m: BELT_M_PER_S / WORKING_OMEGA,
          mu_film: Conveyor::BELT_MU, mu_boundary: Conveyor::BELT_MU, oil_charge_kg: 0.0, viscous_c: 0.0
        )
      end

      # **Coal spilt off the belt where it runs over the drive head**: a share of what it carries, a
      # tick behind. A conduit holds nothing, so it carries the share of the belt's last tick.
      class Spillage < Nodes::Conduit
        def initialize(belt:, share:, **opts)
          @belt = belt.to_sym
          @share = share.to_f
          super(**opts)
        end

        def throughput_kg(state, ctx)
          [ ctx.node_state(@belt)&.fetch(:carried_kg, 0.0).to_f * @share, super ].min
        end
      end

      SPILT_SHARE = 0.002

      def belt_spillage
        Spillage.new(id: :belt_spillage, label: "Spillage", accepts: [ :solid ], max_kg_per_s: 1.0,
                     heat_capacity: 1.0e3, belt: :tub_road, share: SPILT_SHARE)
      end

      # **What lies packed round the drive head**: spillage and the grease off its bearings, against
      # the drum (`hot_spot:`). It lights at a layer's ignition point, far below the belt's, and
      # burning it is the belt's hot spot. On the belt road's air, so it breathes and its smoke goes
      # inbye. The belt attendant shovels it back onto the coal (`belt_clearing`).
      def drive_head
        Nodes::Vessel.new(
          # Its heat capacity is the drive frame's half-tonne of steel, which the deposit burns against.
          id: :drive_head, label: "Drive Head", volume_m3: 20.0, heat_capacity: 2.5e5,
          initial_contents: [ { resource: :air, kg: 24.5 } ],
          reactions: %i[coal_layer_combustion], hot_spot: :belt_drive,
          # A finite rating, so a fire in it is reported as an incident rather than as telemetry.
          max_temperature_k: 1_400.0,
          ports: [ Port.new(id: :air_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
                   Port.new(id: :smoke_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0),
                   Port.new(id: :spill_in, direction: :inlet, accepts: [ :solid ], max_kg_per_s: 1.0),
                   Port.new(id: :spill_out, direction: :outlet, accepts: [ :solid ], max_kg_per_s: 1.0) ]
        )
      end

      # The attendant's shovel: the spillage back onto the pit bottom's coal, as hard as he works.
      def belt_clearing
        Nodes::Conduit.new(id: :belt_clearing, label: "Clearing the Drive Head", accepts: [ :solid ],
                           max_kg_per_s: 0.3, heat_capacity: 1.0e3, control_id: :belt_attending,
                           worked: true, crew: 2)
      end

      # 400 m of belt, both runs, at ten kilograms a metre.
      BELT_KG = 4_000.0

      # **The belt, lying along the road on the intake**, and the share of the intake that passes it:
      # drawn off the pit bottom past the drive head and on into the district. It lights from what it
      # lies on (`hot_spot:`) — a burning deposit at the drive head, or its stalled drum — and
      # burning, its smoke and its carbon monoxide go inbye to the face. Its rock is
      # `:belt_road_rock`: 200 m of road, as the district's.
      BELT_ROAD_FACE_M2 = 2_000.0

      def belt_road(belting:, reaction:)
        Nodes::Vessel.new(
          id: :belt_road, label: "Belt Road", volume_m3: 200.0, heat_capacity: 5.0e3,
          initial_contents: [ { resource: :air, kg: 245.0 }, { resource: belting, kg: BELT_KG } ],
          reactions: [ reaction ], hot_spot: %i[belt_drive drive_head],
          # A finite rating, so a fire in it is reported as an incident rather than as telemetry.
          max_temperature_k: 1_400.0,
          ports: [ Port.new(id: :air_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
                   Port.new(id: :smoke_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0) ]
        )
      end

      # **The belt road is an intake of its own** beside the main road, which is how a conveyor was
      # laid: in series, these three are half the main road's conductance.
      BELT_ROAD_CONDUCTANCE = 1.2

      def belt_draught = belt_airway(:belt_draught, "Belt Road Draught")

      def drive_head_draught = belt_airway(:drive_head_draught, "Past the Drive Head")

      def belt_smoke = belt_airway(:belt_smoke, "Belt Road Smoke")

      def belt_airway(id, label)
        Nodes::Conduit.new(id: id, label: label, accepts: [ :gas ], max_kg_per_s: 40.0,
                           conductance: BELT_ROAD_CONDUCTANCE, heat_capacity: 2.0e3)
      end

      # **Coal rides the cage**, on a deck that is the hoist's load like anybody in it — so lifting
      # coal is work the line shaft does through the drum, booked as the drum's gravity source does
      # it, and everything that can happen to a cage can happen with a deck of coal on it.
      def cage_deck(capacity_kg:)
        Nodes::Vessel.new(
          id: :cage_deck, label: "Cage Deck", volume_m3: capacity_kg / COAL_BULK_KG_M3,
          heat_capacity: 2.0e3, ambient_conductance: 20.0,
          ports: [
            Port.new(id: :coal_in, direction: :inlet, accepts: [ :solid ], max_kg_per_s: 40.0),
            Port.new(id: :coal_out, direction: :outlet, accepts: [ :solid ], max_kg_per_s: 40.0)
          ]
        )
      end

      COAL_BULK_KG_M3 = 800.0

      # **A landing: tubs run on or off the deck, but only with the cage standing there.** Whoever
      # works it is the lever (`control_id:`, an effort station), so with nobody at the landing no
      # coal moves however long the cage stands.
      #
      # **The bank's tubs are the banksman's**, so its traffic is what his peril scales with: the
      # busier the bank, the likelier a tub runs past him into the shaft.
      class Landing < Nodes::Conduit
        def initialize(hoist:, landing_m:, perils: [], **opts)
          @hoist = hoist.to_sym
          @landing_m = landing_m.to_f
          @perils = perils.freeze
          super(**opts)
        end

        attr_reader :hoist, :landing_m, :perils

        def throughput_kg(state, ctx)
          drum = ctx.nodes[@hoist]
          drum_state = ctx.node_state(@hoist)
          return 0.0 unless drum_state && drum.cage_stopped_at?(drum_state, @landing_m)

          super
        end

        def activity(state, quantity, dt)
          return nil unless quantity == :tubs

          (state.fetch(:carried_kg, 0.0) / (full_crew_kg_per_s * dt)).clamp(0.0, 1.0)
        end
      end

      # The onsetter running full tubs onto the deck at the pit bottom. `max_kg_per_s` is one
      # onsetter's.
      def deck_loading(max_kg_per_s:, crew: LANDING_CREW)
        Landing.new(id: :deck_loading, label: "Onsetting", accepts: [ :solid ],
                    hoist: :cage_drive, landing_m: SHAFT_DEPTH_M, max_kg_per_s: max_kg_per_s,
                    heat_capacity: 2.0e3, control_id: :onsetting, worked: true, crew: crew)
      end

      # Two to a landing: one running the tubs on or off and one at the gate.
      LANDING_CREW = 2

      # What the weather on the deck at bank does to running tubs off it: twice as bad wet, nine
      # times on ice.
      BANK_FOOTING = { wet: 1.0, icy: 8.0 }.freeze

      # The banksman running them off at bank.
      def deck_unloading(max_kg_per_s:, crew: LANDING_CREW)
        Landing.new(
          id: :deck_unloading, label: "Banking", accepts: [ :solid ],
          hoist: :cage_drive, landing_m: 0.0, max_kg_per_s: max_kg_per_s,
          heat_capacity: 2.0e3, control_id: :banking, worked: true, crew: crew,
          # Rare beside the haulage road's, because it is one tub in many hundreds — and it hurts
          # nobody at bank; it is the shaft that suffers it. **Both are the deck's footing**: a wet
          # one is worse, an icy one far worse, and an icy deck is how a banksman ends up in the
          # shaft after his tub.
          perils: [ Peril.new(id: :tub_into_shaft, rate: 0.3, scales_with: :tubs,
                              mishap: { node: :shaft, kind: :obstruction, share: 1.0 },
                              stations: %i[banking], underfoot: BANK_FOOTING),
                    Peril.new(id: :slipped_on_the_deck, tags: %i[fall impact], severity: 1.2, rate: 0.1,
                              scales_with: :tubs, stations: %i[banking], underfoot: BANK_FOOTING) ]
        )
      end

      def screens
        Nodes::Delivery.new(id: :screens, label: "Screens", accepts: [ :solid ])
      end

      # --- drainage -------------------------------------------------------------

      # Where the water comes from. An effectively bottomless body feeding the workings at a
      # fixed trickle — a mine does not run out of water, which is the entire problem.
      def strata(kg:)
        Nodes::Vessel.new(
          id: :strata, label: "Strata", volume_m3: 1.0e6, ambient_conductance: 0.0,
          initial_contents: [ { resource: :water, kg: kg } ],
          ports: [ Port.new(id: :out, direction: :outlet, accepts: [ :liquid ],
                            max_kg_per_s: 30.0) ]
        )
      end

      # Seepage. No lever on it: water arrives whether anybody is watching or not.
      #
      # **It can also let go**, and that is inundation. A roadway driven toward old workings is
      # driven toward whatever is standing in them, and the wall between is only as thick as the
      # last survey said — break through and the water arrives faster than anybody in a dipping
      # road can walk out of it.
      #
      # **Sized for the inrush, not for the trickle**, and the fitting throttles itself down to
      # the trickle while it is sound. A `derates: { throughput: }` above 1.0 cannot do this:
      # the path is also capped by the narrowest *port* along it, so a conduit rated at the
      # seepage rate stays at the seepage rate however far its throughput is derated upward.
      # One restriction, one number — and here the number belongs to the node.
      #
      # A pinned `ground:` is a spec measuring the machine, and draws no water ahead.
      def seepage(inrush_kg_per_s:, seam_kg:, ground: nil)
        Inrush.new(
          id: :seepage, label: "Seepage", accepts: [ :liquid ], ground: ground,
          seam: :seam, seam_kg: seam_kg, waters: ([] if ground),
          max_kg_per_s: inrush_kg_per_s, heat_capacity: 1.0e3
        )
      end

      # **What lies ahead of the face**, drawn with the ground and told to nobody: old workings full
      # of water, pockets of gas. Each match has none, one or two, at a depth into the face that is
      # never in the first couple of metres — not knowing whether there is one, or whether there is
      # another, is the tension.
      #
      # **The face advances by coal won** from the seam, at a heading's worth of coal a metre, so the
      # depths are real metres: a pit raising a few kilograms a second makes a couple of metres an
      # hour, and the 90 t district is about nineteen metres deep.
      module Ahead
        # How many: 0, 1 or 2, by these odds.
        COUNT_ODDS = [ 0.5, 0.45, 0.05 ].freeze

        # Where, in metres of advance.
        DEPTHS_M = (2.0..12.0)

        # A heading 3 m wide in a 1.2 m seam of coal at 1300 kg/m³.
        FACE_KG_PER_M = 4_700.0

        module_function

        def count(rng)
          roll = rng.float
          COUNT_ODDS.each_with_index do |odds, n|
            return n if roll < odds

            roll -= odds
          end
          COUNT_ODDS.length - 1
        end

        # Depths into the face, nearest first.
        def depths(rng) = Array.new(count(rng)) { rng.between(DEPTHS_M.begin, DEPTHS_M.end) }.sort

        # How far the face has come, from the coal the seam has given up as of last tick.
        def advance_m(ctx, seam:, seam_kg:)
          state = ctx.node_state(seam) or return 0.0
          left = state.fetch(:parcels).sum { |p| p.fetch(:resource) == :coal ? p.fetch(:kg) : 0.0 }
          [ (seam_kg - left) / FACE_KG_PER_M, 0.0 ].max
        end
      end

      # **Gas held in the coal ahead of the face**, under pressure: the pockets `Ahead` draws for a
      # match, each a mass of firedamp and coal dust, all held here from the start so the books
      # need nothing new — gassier ground, bigger pockets. The pocket is the ledger of what is
      # ahead: as the face comes on it records how far the next pocket is (`ahead_m`) and what is
      # left in it (`next_kg`), spending a pocket's tonnes as the outburst or the borer takes them,
      # read off their own carried mass as of last tick.
      #
      #   state: parcels, ground, pockets ([{ at_m:, kg: }], nearest first), ahead_m, next_kg
      class GasPocket < Nodes::Vessel
        include Ground

        # **How big an outburst is, and it is heavy-tailed**: most throw a few tonnes to a few tens
        # of tonnes of coal, and the rare one hundreds. Log-normal on the coal thrown — median
        # `COAL_MEDIAN_T`, `COAL_SIGMA` in log space, clamped at `COAL_TAIL` standard deviations.
        COAL_MEDIAN_T = 20.0
        COAL_SIGMA = 1.0
        COAL_TAIL = 2.5

        # Firedamp the thrown coal held, m³ a tonne on ordinary ground, at 0.668 kg/m³.
        GAS_M3_PER_T = 10.0
        FIREDAMP_KG_PER_M3 = 0.668

        # The airborne fines among the coal thrown — a first guess.
        DUST_SHARE_OF_COAL = 0.01

        # Below this a pocket is spent.
        SPENT_KG = 1.0

        # Reported with nothing ahead.
        NOTHING_M = 1_000.0

        def initialize(seam:, seam_kg:, outburst:, bore:, pockets: nil, **opts)
          @seam = seam.to_sym
          @seam_kg = seam_kg.to_f
          @outburst = outburst.to_sym
          @bore = bore.to_sym
          @pockets = pockets&.map { |p| p.transform_keys(&:to_sym).freeze }&.freeze
          super(**opts)
        end

        def initial_state(rng, content = nil)
          state = super
          gassy = ground(state)
          pockets = @pockets || Ahead.depths(rng).map { |at| pocket(rng, at, gassy) }
          state.merge(parcels: held(pockets, content), pockets: pockets, ahead_m: NOTHING_M, next_kg: 0.0,
                      next_coal_t: 0.0)
        end

        # A pocket at `at_m`: the coal it throws, the firedamp that coal held, and its fines.
        def self.drawn(rng, at_m, gassy)
          coal_t = COAL_MEDIAN_T * Math.exp(COAL_SIGMA * standard_normal(rng).clamp(-COAL_TAIL, COAL_TAIL))
          firedamp = coal_t * GAS_M3_PER_T * FIREDAMP_KG_PER_M3 * gassy
          dust = coal_t * 1_000.0 * DUST_SHARE_OF_COAL
          { at_m: at_m, coal_t: coal_t, firedamp_kg: firedamp, dust_kg: dust, kg: firedamp + dust }
        end

        # Box–Muller, from the stream's own uniform draws.
        def self.standard_normal(rng)
          u = [ rng.float, 1.0e-12 ].max
          Math.sqrt(-2.0 * Math.log(u)) * Math.cos(2.0 * Math::PI * rng.float)
        end

        def pockets(state) = state.fetch(:pockets, [])

        def apply(state, ctx, grant)
          taken = [ @outburst, @bore ].sum { |id| ctx.node_state(id)&.fetch(:carried_kg, 0.0).to_f }
          pockets = spend(pockets(state), taken)
          nearest = pockets.first
          ahead = nearest ? nearest.fetch(:at_m) - Ahead.advance_m(ctx, seam: @seam, seam_kg: @seam_kg) : NOTHING_M

          applied, events = super
          [ applied.merge(pockets: pockets, ahead_m: ahead, next_kg: nearest ? nearest.fetch(:kg) : 0.0,
                          next_coal_t: nearest ? nearest.fetch(:coal_t, 0.0) : 0.0), events ]
        end

        private

        def spend(pockets, taken)
          return pockets if pockets.empty? || taken <= 0.0

          left = pockets.first.fetch(:kg) - taken
          left > SPENT_KG ? [ pockets.first.merge(kg: left), *pockets.drop(1) ] : pockets.drop(1)
        end

        def pocket(rng, at_m, gassy) = self.class.drawn(rng, at_m, gassy)

        def held(pockets, content)
          return [] if pockets.empty?

          Parcel.normalise(%i[firedamp coal_dust].zip(%i[firedamp_kg dust_kg]).map do |resource, key|
            Parcel.build(resource: resource, kg: pockets.sum { |p| p.fetch(key) }, temperature_k: ambient_k,
                         content: content)
          end)
        end
      end

      # **The outburst**: the face reaching a pocket with gas still in it, and the pocket emptying
      # into the district in seconds — firedamp, and dust for the next flame. It lets go as a failure
      # (`outburst`) so it hurts whoever is at the face, and once that pocket is spent it is shut
      # again, so a second pocket further in is a second outburst.
      class Outburst < Nodes::Conduit
        def initialize(pocket:, endangers: {}, **opts)
          @pocket = pocket.to_sym
          @failure_hazards = endangers.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          super(**opts)
        end

        attr_reader :failure_hazards

        def pocket_state(ctx) = ctx.node_state(@pocket) || {}

        def overload?(_state, ctx, _integrity)
          ahead = pocket_state(ctx)
          ahead.fetch(:ahead_m, GasPocket::NOTHING_M) <= 0.0 && ahead.fetch(:next_kg, 0.0) > GasPocket::SPENT_KG
        end

        def throughput_kg(state, ctx) = broken?(state) ? super : 0.0

        # Spent, it shuts; the next pocket, if any, is what lies ahead.
        def apply(state, ctx, _grant)
          return state unless broken?(state) && !overload?(state, ctx, 1.0)

          state.merge(failure: nil, durability: state.fetch(:initial_durability))
        end

        def failure_modes = { outburst: {} }

        def failure_mode(_state, _ctx, _cause) = :outburst

        def failure_detail(_state, ctx)
          ahead = pocket_state(ctx)
          { coal_t: ahead.fetch(:next_coal_t, 0.0).round(1), gas_kg: ahead.fetch(:next_kg, 0.0).round }
        end
      end

      # **Boring ahead**: an auger driven into the face, which draws the next pocket off slowly once it
      # is within reach — into the district's air, so the fan has to carry it — and is how anybody
      # learns a pocket is there.
      class BoreLine < Nodes::Conduit
        # How far ahead an auger reaches.
        REACH_M = 4.0

        def initialize(pocket:, **opts)
          @pocket = pocket.to_sym
          super(**opts)
        end

        def in_reach?(ctx)
          ahead = ctx.node_state(@pocket) || {}
          ahead.fetch(:ahead_m, GasPocket::NOTHING_M) <= REACH_M && ahead.fetch(:next_kg, 0.0) > GasPocket::SPENT_KG
        end

        def throughput_kg(state, ctx) = in_reach?(ctx) ? super : 0.0

        # What the holes are giving: the gas in the pocket within reach, or nothing.
        def apply(state, ctx, _grant)
          state.merge(found_kg: in_reach?(ctx) ? ctx.node_state(@pocket).fetch(:next_kg) : 0.0)
        end
      end

      # A pinned `ground:` draws no pockets.
      def gas_pocket(seam_kg:, ground: nil)
        GasPocket.new(
          id: :gas_pocket, label: "Gas Pocket", volume_m3: 6.0, ambient_conductance: 0.0,
          seam: :seam, seam_kg: seam_kg, outburst: :outburst, bore: :bore_line,
          ground: ground, pockets: ([] if ground),
          ports: [ Port.new(id: :out, direction: :outlet, accepts: [], max_kg_per_s: 60.0) ]
        )
      end

      # Coal thrown into the face, and how hard it hits goes with how much: a median outburst at the
      # reference, the rare large one far worse.
      OUTBURST_HARM = { tags: %i[crush impact], scales_with: :coal_t, reference: GasPocket::COAL_MEDIAN_T,
                        places: { district: 2.4 } }.freeze

      def outburst
        Outburst.new(id: :outburst, label: "Outburst", accepts: [], pocket: :gas_pocket,
                     max_kg_per_s: 60.0, heat_capacity: 1.0e3, endangers: { outburst: OUTBURST_HARM })
      end

      def bore_line
        BoreLine.new(id: :bore_line, label: "Bore Holes", accepts: [], pocket: :gas_pocket,
                     max_kg_per_s: 0.25, heat_capacity: 1.0e3, control_id: :boring, worked: true)
      end

      # **The fissure between the face and whatever water lies ahead of it.**
      #
      # It seeps the ordinary make of water a pit lives with, by its `ground`. **Where the ground
      # holds a body of water** — drawn per match (`Ahead`) — the coal weeps harder as the face comes
      # within `WEEPS_WITHIN_M` of it, and when the face reaches it the fissure lets go: an inrush at
      # the full rate until that body's tonnes are through, and then back to the seep. A second body
      # further in is a second inrush. Driving the face is the cause, because it is the only thing
      # that advances it.
      #
      #   state: durability, failure, ground, waters ([{ at_m:, kg: }], nearest first), drained_kg,
      #          barrier_m
      class Inrush < Nodes::Conduit
        include Ground

        # What gets through a fissure that has not given way yet, as a fraction of what gets
        # through one that has.
        SEEP_FRACTION = 0.06

        # Within this the coal weeps, up to this many times the ordinary seep at the barrier.
        WEEPS_WITHIN_M = 3.0
        WEEPS_UP_TO = 4.0

        # What a body of old workings holds.
        WATER_KG = (20_000.0..80_000.0)

        # The barrier reported with no water ahead — the plans' "forty yards of solid coal".
        NO_WATER_M = 1_000.0

        # `waters:` pins the bodies instead of drawing them; a pinned `ground:` pins none.
        def initialize(seam:, seam_kg:, waters: nil, **opts)
          @seam = seam.to_sym
          @seam_kg = seam_kg.to_f
          @waters = waters&.map { |w| w.transform_keys(&:to_sym).freeze }&.freeze
          super(**opts)
        end

        def initial_state(rng, content = nil)
          state = super
          waters = @waters || Ahead.depths(rng).map { |at| { at_m: at, kg: rng.between(WATER_KG.begin, WATER_KG.end) } }
          state.merge(waters: waters, drained_kg: 0.0, barrier_m: NO_WATER_M)
        end

        def waters(state) = state.fetch(:waters, [])

        def barrier_m(state, ctx)
          ahead = waters(state).first or return NO_WATER_M
          ahead.fetch(:at_m) - Ahead.advance_m(ctx, seam: @seam, seam_kg: @seam_kg)
        end

        # Weeping: the seep rises as the barrier thins.
        def weeping(barrier)
          closeness = (1.0 - (barrier / WEEPS_WITHIN_M)).clamp(0.0, 1.0)
          1.0 + ((WEEPS_UP_TO - 1.0) * closeness)
        end

        # **`ground` varies the ordinary make and never the inrush**, because they are two
        # different facts: how wet the strata runs is the ground, and what is standing behind the
        # fissure is not.
        def throughput_kg(state, ctx)
          return super if broken?(state)

          super * SEEP_FRACTION * ground(state) * weeping(state.fetch(:barrier_m, NO_WATER_M))
        end

        # The face has reached the water.
        def overload?(state, ctx, _integrity) = !waters(state).empty? && barrier_m(state, ctx) <= 0.0

        # Breached, the body drains through it; once its tonnes are through, the fissure is a seep
        # again and the next body, if any, is what lies ahead.
        def apply(state, ctx, _grant)
          return state.merge(barrier_m: barrier_m(state, ctx)) unless broken?(state)

          drained = state.fetch(:drained_kg) + state.fetch(:carried_kg, 0.0)
          body = waters(state).first
          return state.merge(drained_kg: drained, barrier_m: 0.0) if body && drained < body.fetch(:kg)

          healed = state.merge(failure: nil, durability: state.fetch(:initial_durability), drained_kg: 0.0,
                               waters: waters(state).drop(1))
          healed.merge(barrier_m: barrier_m(healed, ctx))
        end

        def failure_modes = { inrush: {} }

        def failure_mode(_state, _ctx, _cause) = :inrush

        def failure_detail(state, ctx)
          { depth_m: Ahead.advance_m(ctx, seam: @seam, seam_kg: @seam_kg).round(2),
            water_kg: waters(state).first&.fetch(:kg)&.round }
        end
      end

      def pump(max_kg_per_s:, lift_m:, efficiency:, rated_omega:, driven_by: :line_shaft)
        Pump.new(
          id: :pump, label: "Sump Pump", accepts: [ :liquid ],
          max_kg_per_s: max_kg_per_s, heat_capacity: 1.0e4,
          control_id: :pumping,
          driven_by: driven_by, lift_m: lift_m, efficiency: efficiency,
          rated_omega: rated_omega, delivers_to: :work, displacement: true, burst_ratio: 1.4
        )
      end

      def drainage
        Nodes::Delivery.new(id: :drainage, label: "Drainage", accepts: [ :liquid ])
      end

      # **The Cornish set's beam**: the bob at the shaft top that works the pump rods. A power sink
      # on the line shaft like everything else, so whatever turns that shaft works the pump through
      # it — and a broken beam stops the pumping by itself, because nothing turns the pump.
      #
      # It fatigues with every stroke under the column, faster the more water it is lifting, and a
      # surge breaks it outright. **Broken, it falls into the shaft** and chokes it; in a single
      # shaft it tears the brattice out on the way. Hartley.
      #
      #   state: angular_momentum, durability, failure
      class PumpBeam < ReactorSim::Node
        include Concerns::Rotating
        include Concerns::Wearing

        # Durability per second at rated speed with the pump lifting its full rating.
        STROKE_PER_S = 0.04

        # The share of that the bob costs with nothing in the column.
        UNLADEN = 0.3

        # How far past rated speed a sound beam stands before it breaks. A worn one less.
        OVERSPEED_MARGIN = 0.5

        def initialize(id:, pump:, pump_kg_per_s:, rated_omega:, label: nil, endangers: {},
                       damages: {})
          @pump = pump.to_sym
          @pump_kg_per_s = pump_kg_per_s.to_f
          @rated_omega = rated_omega.to_f
          @failure_hazards = endangers.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          @failure_damages = damages.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          super(id: id, label: label)
          freeze
        end

        attr_reader :failure_hazards, :failure_damages

        def moment_of_inertia = 400.0
        def friction = 2.0

        def speed_ratio(state) = omega(state).abs / @rated_omega

        # How much of its rating the pump lifted last tick.
        def lifting(ctx)
          carried = ctx.node_state(@pump)&.fetch(:carried_kg, 0.0).to_f
          (carried / (@pump_kg_per_s * ctx.dt)).clamp(0.0, 1.0)
        end

        def stress_per_second(state, ctx)
          STROKE_PER_S * (speed_ratio(state)**2) * (UNLADEN + ((1.0 - UNLADEN) * lifting(ctx)))
        end

        def overload?(state, _ctx, integrity) = speed_ratio(state) > 1.0 + (OVERSPEED_MARGIN * integrity)

        def failure_modes = { broken: {} }

        def failure_mode(_state, _ctx, _cause) = :broken

        def failure_detail(state, _ctx) = { speed_ratio: speed_ratio(state).round(2) }
      end

      def pump_beam(pump_kg_per_s:, rated_omega:, endangers:, damages:)
        PumpBeam.new(id: :pump_beam, label: "Pump Beam", pump: :pump, pump_kg_per_s: pump_kg_per_s,
                     rated_omega: rated_omega, endangers: endangers, damages: damages)
      end

      # --- the supply -----------------------------------------------------------

      # What the engine house turns. Everything that costs power hangs off this one shaft, which
      # is what makes a brownout a whole-mine event rather than one machine stopping.
      # `trip:` names the overspeed trip if one is fitted; with none, the line shaft never trips.
      def line_shaft(rated_torque_nm:, rated_omega:)
        Nodes::Import.new(
          id: :line_shaft, label: "Line Shaft",
          rated_torque_nm: rated_torque_nm, rated_omega: rated_omega,
          moment_of_inertia: 900.0, friction: 4.0, control_id: :clutch, trip: :overspeed_trip
        )
      end

      # **A centrifugal trip on the line shaft**: past `trip_ratio` of rated speed it throws the
      # clutch out. Holds nothing and moves nothing; the line shaft reads its setting.
      class OverspeedTrip < ReactorSim::Node
        def initialize(trip_ratio:, **opts)
          @trip_ratio = trip_ratio.to_f
          super(**opts)
          freeze
        end

        attr_reader :trip_ratio
      end

      # **Overspeed, felt at the fan and the pump.** A surge from the engine house arrives as the
      # line shaft running past rated, and both fittings hang off it: past `burst_ratio` of rated —
      # less on a worn part — the fan's rotor bursts and the pump's rising main bursts. Burst, a fan
      # makes no head and a pump lifts nothing.
      module Overspeed
        def speed_ratio(ctx) = ctx.node_omega(@driven_by).to_f.abs / @rated_omega

        def overload?(_state, ctx, integrity) = speed_ratio(ctx) > 1.0 + ((@burst_ratio - 1.0) * integrity)

        def failure_detail(_state, ctx) = { speed_ratio: speed_ratio(ctx).round(2) }
      end

      # **Reversed, it blows down the upcast instead of drawing up it** (`reverse_control_id:`, on a
      # reversible tier only): the whole circuit runs backwards, smoke on the intake goes back up the
      # downcast — and the district's gas comes out past whatever is alight at the pit bottom. It
      # costs the same to turn either way.
      class Fan < Nodes::Conduit
        include Overspeed

        def initialize(burst_ratio:, endangers: {}, reverse_control_id: nil, **opts)
          @burst_ratio = burst_ratio.to_f
          @reverse_control_id = reverse_control_id&.to_sym
          @failure_hazards = endangers.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          super(**opts)
        end

        attr_reader :failure_hazards

        def head_pa(ctx)
          return 0.0 if ctx.node_state(id)&.fetch(:failure, nil)

          reversed?(ctx) ? -super : super
        end

        def reversed?(ctx) = !@reverse_control_id.nil? && ctx.controls.fetch(@reverse_control_id, 0.0) >= 50.0

        # The bill is the head it makes times the air it moves, whichever way it is blowing.
        def hydraulic_w(state, ctx)
          return 0.0 unless ctx.dt.positive?

          head_pa(ctx).abs * state.fetch(:carried_m3, 0.0) / ctx.dt
        end

        def failure_modes = { burst: {} }
      end

      class Pump < Nodes::Conduit
        include Overspeed

        def initialize(burst_ratio:, **opts)
          @burst_ratio = burst_ratio.to_f
          super(**opts)
        end

        def failure_modes = { main_burst: { derates: { throughput: 0.0 } } }
      end

      def crew_for(roster, content, station:, place:, advance: [])
        below = advance_seats(roster, advance)

        roster.map do |seat, posting|
          sheet = Crew.resolve(posting, content: content)
          # **Already down, and posted to nothing.** Standing there is the head start; which post
          # they take is still the player's first decision, and giving them a station as well
          # would put a gang on one lever before anybody had asked for it.
          underground = below[seat]

          Minion.new(id: seat, station: underground ? nil : station,
                     place: underground || place,
                     name: sheet.fetch(:name),
                     minion: sheet.fetch(:minion), archetype: sheet.fetch(:archetype),
                     stats: sheet.fetch(:stats), tags: sheet.fetch(:tags),
                     mass_kg: sheet.fetch(:mass_kg), worn_kg: sheet.fetch(:worn_kg))
        end
      end

      # `{ seat => place }`, **dealt from the end of the roster, the first shift first** — so seat
      # one is still somebody at bank and a roster filled from the top has its named hands there.
      # Never more than the roster holds: a small quarters seats the face before the pit bottom,
      # and bank keeps whoever is left.
      def advance_seats(roster, advance)
        free = roster.keys.reverse
        Array(advance).each_with_object({}) do |shift, dealt|
          free.shift(shift.fetch(:seats)).each { |seat| dealt[seat] = shift.fetch(:place) }
        end.freeze
      end
    end
  end
end
