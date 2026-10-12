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

      # **The shift that is already down when the whistle goes.**
      #
      # Bank to the face is minutes, and a player who has to spend all of them before anything
      # can happen is a player watching a loading bar. A few hands already in the district are
      # the mine's opening move: coal can be cut on tick one while the rest of the shift walks.
      #
      # **The last seats, not the first**, so seat one is still somebody at bank and a roster
      # that fills only the top of the list gets a shift that has to be sent down.
      #
      # TODO: first caller of a *fitted* version is the blueprint tree — this belongs on a part
      # (a night shift, a lodging house, an underground stable) so a player buys the head start
      # rather than being given it, and so a frame can offer more than one arrangement. Declared
      # on the chassis today because nothing yet sells it.
      ADVANCE_SHIFT = { seats: 3, place: :district }.freeze

      STARTING_PARTS = {
        cutting: :hand_picks,
        lighting: :tallow_candles,
        winder: :steam_whim,
        fan: :waddle_fan,
        pump: :sinking_set,
        quarters: :lamp_cabin,
        rest: :refuge_hole
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
          single_shaft: true,
          advance: ADVANCE_SHIFT
        }.freeze,
        two_shaft: {
          parts: STARTING_PARTS,
          advance: ADVANCE_SHIFT
        }.freeze
      }.freeze

      # `ground:` pins how gassy and how wet this pit is instead of drawing it. **Not in
      # `options:`**, and it does not need to be: it changes `initial_state` and nothing about
      # the graph, and a restored snapshot installs its own state over the top — so the ground
      # a match was given survives a round trip whatever this was called with.
      def build(id:, seed:, chassis: CHASSIS.keys.first, loadout: {}, crew: {}, ground: nil,
                time_scale: DEFAULT_TIME_SCALE, state: nil, rngs: nil, content: nil)
        chassis = chassis.to_sym
        assembly = assembly_for(chassis, loadout, ground: ground)
        fragment = assembly.build!
        roster = Crew.normalise(crew, capacity: assembly.crew_capacity)

        Operation.new(
          id: id, type: TYPE, seed: seed, time_scale: time_scale,
          state: state, rngs: rngs, content: content,
          options: { chassis: chassis, loadout: assembly.loadout, crew: roster },
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
                            advance: CHASSIS.fetch(chassis)[:advance])
        )
      end

      def assembly_for(chassis, loadout = {}, ground: nil)
        spec = CHASSIS.fetch(chassis.to_sym) { raise Error, "unknown mine chassis #{chassis.inspect}" }
        spec = spec.merge(ground: ground) if ground

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
                      through: :shaft, label: "Ladderway"),
          Passage.new(a: :pit_bottom, b: :district, metres: 200.0, speed_m_s: 1.2,
                      label: "Main Road"),
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

        def blocks_passage?(state) = broken?(state) || !jam_m(state).nil?

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

      # A spark at the contacts: a little seed for a mixture that will carry it, and almost no heat.
      BELL_SPARK = { igniter_kg_per_s: 2.0e-4, watts: 50.0 }.freeze

      def signal_bell(spark:, label:)
        SignalBell.new(id: :signal_bell, label: label, hoist: :cage_drive, landing_m: SHAFT_DEPTH_M,
                       spark: spark)
      end

      # **The foot of the upcast compartment**, on the far side of the brattice: where the return
      # air arrives, and where whatever leaks through the brattice joins it on the way to the fan.
      # Only a single-shaft pit has one — two shafts have no brattice between them.
      def upcast_foot
        Nodes::Vessel.new(
          id: :upcast_foot, label: "Upcast Foot", volume_m3: 300.0,
          heat_capacity: 4.0e4, ambient_conductance: 80.0,
          initial_contents: [ { resource: :air, kg: 360.0 } ],
          ports: [
            Port.new(id: :air_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            Port.new(id: :leak_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            Port.new(id: :air_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0)
          ]
        )
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
          trapping = @trapper ? (ctx.controls.fetch(@trapper, 0.0) / 100.0).clamp(0.0, 1.5) : 0.0
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
                    rated_omega: rated_omega, through: :shaft, label: label)
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
      class Sump < Nodes::Vessel
        # Where the pit bottom stops being wet and starts being flooded — water over the
        # landing, the onsetter's feet and the bottom of the cage. Nothing enforces it; it is
        # the mark the gauge is read against, and the number a player is actually racing.
        FLOOD_KG = 2_400.0

        def flooding(state, content)
          standing = Parcel.total_kg(
            Parcel.matching(state.fetch(:parcels), [ :liquid ], content)
          )

          (standing / FLOOD_KG).clamp(0.0, 1.0)
        end
      end

      def pit_bottom
        Sump.new(
          id: :pit_bottom, label: "Pit Bottom", volume_m3: 900.0,
          heat_capacity: 2.0e5, ambient_conductance: 220.0,
          initial_contents: [ { resource: :air, kg: 1_100.0 } ],
          # **Gas that reaches the shaft can burn there.** It is on the intake and is clear while
          # the air runs; stop the fan or breach the brattice and the district's gas backs out to
          # where the signal bell rings — or to where a district explosion's flame arrives.
          reactions: %i[firedamp_combustion],
          ports: [
            Port.new(id: :air_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            Port.new(id: :air_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            # Through the brattice into the upcast compartment, in a single-shaft pit.
            Port.new(id: :brattice_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            # Through the haulage door into the return.
            Port.new(id: :door_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            # Its own inlet, not the downcast's: a port filters on tags and cannot tell two
            # gases apart, so a seep sharing the intake would be a seep the ventilation drives.
            Port.new(id: :damp_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 2.0),
            Port.new(id: :coal_in, direction: :inlet, accepts: [ :solid ], max_kg_per_s: 12.0),
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

      def district
        District.new(
          id: :district, label: "District", volume_m3: 1_400.0,
          heat_capacity: 3.0e5, ambient_conductance: 300.0,
          initial_contents: [ { resource: :air, kg: 1_700.0 } ],
          reactions: %i[firedamp_combustion coal_dust_combustion],
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
          endangers: {
            rupture: { tags: %i[blast burn afterdamp], scales_with: :temperature_k,
                       reference: 1_400.0,
                       places: { district: 3.2, pit_bottom: 1.1 } }
          },
          # The blast goes down the roads and blows the haulage door out of its frame, so the air
          # that might have cleared the afterdamp takes the short way back to the fan instead.
          damages: { rupture: { door: 1.0 } },
          ports: [
            Port.new(id: :air_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            Port.new(id: :air_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            Port.new(id: :gas_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 2.0),
            # **Inlets only.** Dust that has settled in a district has no way out of it: no
            # conduit here accepts `:dust`, so it neither rides out on the tubs nor blows away
            # up the return. It goes when it burns or when it is covered over.
            Port.new(id: :dust_in, direction: :inlet, accepts: [ :dust ], max_kg_per_s: 2.0),
            Port.new(id: :stone_in, direction: :inlet, accepts: [ :dust ], max_kg_per_s: 2.0),
            Port.new(id: :coal_in, direction: :inlet, accepts: [ :solid ], max_kg_per_s: 12.0),
            Port.new(id: :coal_out, direction: :outlet, accepts: [ :solid ], max_kg_per_s: 12.0)
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
      def upcast(head_pa:, rated_omega:)
        Fan.new(
          id: :upcast, label: "Upcast Fan", accepts: [ :gas ],
          max_kg_per_s: 40.0, conductance: 1.2, heat_capacity: 5.0e4,
          control_id: :ventilation, head_pa: head_pa,
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
            Port.new(id: :gas_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 2.0)
          ]
        )
      end

      # What the pick makes. A separate body from the seam so that only the hewing lever can
      # reach it — see `seam`.
      def dust_source(kg:)
        Nodes::Vessel.new(
          id: :dust_source, label: "Face Dust", volume_m3: 2_000.0, ambient_conductance: 0.0,
          initial_contents: [ { resource: :coal_dust, kg: kg } ],
          ports: [ Port.new(id: :out, direction: :outlet, accepts: [ :dust ],
                            max_kg_per_s: 2.0) ]
        )
      end

      # **Dust comes off the pick, not out of the ground.** A blower vents whether anybody is
      # there or not; dust is made by cutting, so this one is on the hewing lever — which makes
      # driving a face hard the thing that fills the district with it. Rate-driven, because what
      # limits it is how hard the coal is being worked rather than any gradient.
      def dust_line(max_kg_per_s:)
        Nodes::Conduit.new(
          id: :dust_line, label: "Dust", accepts: [ :dust ],
          max_kg_per_s: max_kg_per_s, heat_capacity: 1.0e3,
          control_id: :hewing
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
      class OldWorkings < Nodes::Vessel
        SOUR = (0.0..0.09)

        # Pinned by `ground:` the way the seeps are, so a spec about a machine is not also a
        # spec about which waste it was given. Sweet, because sour is the exception.
        ORDINARY_SOUR = 0.0

        def initialize(sour: nil, **opts)
          @sour = sour&.to_f
          super(**opts)
        end

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

      def goaf(kg:, sour: nil)
        OldWorkings.new(
          id: :goaf, label: "Old Workings", volume_m3: 3_000.0, ambient_conductance: 0.0,
          sour: sour,
          initial_contents: [ { resource: :blackdamp, kg: kg } ],
          ports: [ Port.new(id: :out, direction: :outlet, accepts: [ :gas ],
                            max_kg_per_s: 2.0) ]
        )
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
        Seep.new(
          id: :goaf_seep, label: "Blackdamp", accepts: [ :gas ], ground: ground,
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

      # What an open flame on the roadway offers the district: enough seed to light a mixture
      # that will carry it, and a little heat.
      OPEN_FLAME = { igniter_kg_per_s: 4.0e-4, flame_watts: 1.2e3 }.freeze

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
      class PickLine < Nodes::Conduit
        def initialize(sparks: nil, **opts)
          @sparks = sparks&.freeze
          @rated_kg_per_s = opts.fetch(:max_kg_per_s).to_f
          super(**opts)
        end

        attr_reader :sparks

        def ignition(state, _levers)
          cutting = state.fetch(:cutting, 0.0)
          return nil unless @sparks && cutting.positive?

          { kg_per_s: @sparks.fetch(:kg_per_s) * cutting, watts: @sparks.fetch(:watts) * cutting,
            cause: :cutter_sparks }
        end

        # How hard it was cutting this tick, against its rating.
        def apply(state, ctx, grant)
          cut = state.fetch(:carried_kg, 0.0) / (@rated_kg_per_s * ctx.dt)
          super.merge(cutting: cut.clamp(0.0, 1.0))
        end
      end

      # A frictional spark: enough seed to fire a mixture in the band, almost no heat.
      CUTTER_SPARKS = { kg_per_s: 1.0e-4, watts: 30.0 }.freeze

      def pick_line(max_kg_per_s:, sparks: nil)
        PickLine.new(
          id: :pick_line, label: "Hewing", accepts: [ :solid ],
          max_kg_per_s: max_kg_per_s, heat_capacity: 2.0e3,
          control_id: :hewing, sparks: sparks
        )
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
        # Durability per second at a fully advanced, wholly unsupported face.
        #
        # **Against `Wearing::DEFAULT_DURABILITY_RANGE`, which is 850–1150, not 0–1.** Written as
        # `9.0e-3` — a plausible-looking figure for a fraction-per-second — it took 2% off a
        # roadway in 1500 s and the roof could not have come in inside a day's play. A rate is
        # meaningless without the scale it is against; check the pool before picking the rate.
        #
        # At 7.3 a wholly unsupported face brings the road in at about 450 simulated seconds,
        # which is minutes rather than seconds on purpose: the player has to be able to see it
        # coming and send somebody.
        #
        # **It was 2.2 before hewing became gated rather than aided.** The controls this reads
        # carry the *worked* value, so a change to how capability is computed moves this figure
        # even though nothing here was touched: a decent kit went from ×1.6 aided to ×0.48
        # gated, a factor of 3.3, and the rate had to follow it.
        UNSUPPORTED_RATE = 7.3

        # `endangers:` lives here rather than on `Conduit`, because a pipe that hurts the people
        # beside it is a general idea nothing else has needed yet and a roadway coming in is
        # not. `Tick#hazards_from` only asks whether a node responds to `failure_hazards`, so a
        # subclass answering is enough.
        def initialize(advanced_by:, supported_by:, endangers: {}, perils: [], **opts)
          @advanced_by = advanced_by.to_sym
          @supported_by = supported_by.to_sym
          @failure_hazards = endangers.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          @perils = perils.freeze
          # Kept because `activity` divides by it: the road's own rating is the scale its
          # traffic means anything against.
          @rated_kg_per_s = opts.fetch(:max_kg_per_s).to_f
          super(**opts)
        end

        attr_reader :failure_hazards, :perils

        # **The difference, floored at zero, never the ratio.** A ratio makes a face nobody is
        # working still consume timber to stand still, and a district standing idle does not
        # fall in — it is cutting that opens ground.
        def stress_per_second(state, ctx)
          exposed = ctx.controls.fetch(@advanced_by, 0.0) / 100.0
          supported = ctx.controls.fetch(@supported_by, 0.0) / 100.0
          unsupported = [ exposed - supported, 0.0 ].max

          (unsupported * UNSUPPORTED_RATE) + super
        end

        # A fall does not seal a roadway, it chokes it — a few tubs a shift get past over the
        # debris until it is cleared. Never 0.0: a road that passes nothing is a better seal
        # than a sound one, which is the trap `nodes/CLAUDE.md` records for ruptures.
        # **How busy the road is, 0..1.** What a peril on a haulage road scales with is the
        # traffic, not the clock — the tub going past is the danger, so a road being worked
        # flat out is a road that hurts people and an idle one is a corridor.
        def activity(state, quantity, dt)
          return nil unless quantity == :tubs

          (state.fetch(:carried_kg, 0.0) / (@rated_kg_per_s * dt)).clamp(0.0, 1.0)
        end

        def failure_modes = { roof_fall: { derates: { throughput: 0.12 } } }

        def failure_mode(_state, _ctx, _cause) = :roof_fall

        def failure_detail(state, ctx)
          { unsupported: (ctx.controls.fetch(@advanced_by, 0.0) -
                          ctx.controls.fetch(@supported_by, 0.0)).clamp(0.0, 100.0).round(1),
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

      def tub_road(max_kg_per_s:)
        Roadway.new(
          advanced_by: :hewing, supported_by: :timbering,
          id: :tub_road, label: "Haulage Road", accepts: [ :solid ],
          max_kg_per_s: max_kg_per_s, heat_capacity: 4.0e3,
          control_id: :haulage,
          # Who is under it when it comes in. **The road runs between two rooms and the fall
          # reaches both** — the putter's end worst, because he is on it, and the face less.
          # Keyed by place rather than by post, so the timberman standing at the face is caught
          # too, which he plainly should be and was not while a hazard reached people through
          # the job they were doing.
          endangers: {
            # `reference:` is in the same **worked** units `unsupported` is reported in, so it
            # moved when hewing became gated: a fully unsupported face reads about 48 with a
            # decent kit, not 100, and a reference of 60 put every fall in one severity band.
            roof_fall: { tags: %i[rockfall crush], scales_with: :unsupported,
                         reference: 30.0,
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
          @rated_kg_per_s = opts.fetch(:max_kg_per_s).to_f
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

          (state.fetch(:carried_kg, 0.0) / (@rated_kg_per_s * dt)).clamp(0.0, 1.0)
        end
      end

      # The onsetter running full tubs onto the deck at the pit bottom.
      def deck_loading(max_kg_per_s:)
        Landing.new(id: :deck_loading, label: "Onsetting", accepts: [ :solid ],
                    hoist: :cage_drive, landing_m: SHAFT_DEPTH_M, max_kg_per_s: max_kg_per_s,
                    heat_capacity: 2.0e3, control_id: :onsetting)
      end

      # The banksman running them off at bank.
      def deck_unloading(max_kg_per_s:)
        Landing.new(
          id: :deck_unloading, label: "Banking", accepts: [ :solid ],
          hoist: :cage_drive, landing_m: 0.0, max_kg_per_s: max_kg_per_s,
          heat_capacity: 2.0e3, control_id: :banking,
          # Rare beside the haulage road's, because it is one tub in many hundreds — and it hurts
          # nobody at bank; it is the shaft that suffers it.
          perils: [ Peril.new(id: :tub_into_shaft, rate: 0.3, scales_with: :tubs,
                              mishap: { node: :shaft, kind: :obstruction, share: 1.0 },
                              stations: %i[banking]) ]
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
      # road can walk out of it. The mechanism is the same one a burst pipe uses: the fissure
      # `derates: { throughput: }` **upward**, so what was a trickle becomes a torrent through
      # the same conduit.
      # **Sized for the inrush, not for the trickle**, and the fitting throttles itself down to
      # the trickle while it is sound. A `derates: { throughput: }` above 1.0 cannot do this:
      # the path is also capped by the narrowest *port* along it, so a conduit rated at the
      # seepage rate stays at the seepage rate however far its throughput is derated upward.
      # One restriction, one number — and here the number belongs to the node.
      def seepage(inrush_kg_per_s:, ground: nil)
        Inrush.new(
          id: :seepage, label: "Seepage", accepts: [ :liquid ], ground: ground,
          max_kg_per_s: inrush_kg_per_s, heat_capacity: 1.0e3
        )
      end

      # A fissure that can give way.
      #
      # `stress_per_second` is driven by **how hard the face is being driven**: cutting is what
      # advances the workings toward whatever is behind them, so a district nobody is working
      # never breaks into anything. The same term as `Roadway`'s, and deliberately — they are
      # two consequences of one decision, which is how hard to push a face you cannot see the
      # far side of.
      class Inrush < Nodes::Conduit
        include Ground

        # Slower than a roof fall by a good margin: breaking through is rarer than being
        # careless with timber, and it is meant to catch a player who has got comfortable
        # rather than one who is being reckless today.
        #
        # **Against the WORKED value of the lever, not its position.** `ctx.controls` carries
        # what the station actually achieved — `Tick#worked` scales an effort lever by whoever
        # is standing at it — so a rate sized against 0–100 is out by whatever the hewer's
        # capability happens to be, and quietly never fires.
        DRIVEN_RATE = 1.2

        def stress_per_second(state, ctx)
          ((ctx.controls.fetch(:hewing, 0.0) / 100.0) * DRIVEN_RATE) + super
        end

        # What gets through a fissure that has not given way yet, as a fraction of what gets
        # through one that has. The ordinary make of water a pit lives with.
        SEEP_FRACTION = 0.06

        # The hole is the conduit, and while the ground holds it is nearly shut. Nothing is
        # derated: the node governs its own throughput, so there is one restriction and one
        # number for it.
        #
        # **`ground` varies the ordinary make and never the inrush**, because they are two
        # different facts: how wet the strata runs is the ground, and what is standing behind
        # the fissure is not. Scaling the breach as well would make a dry pit's inundation
        # something the starting set could simply pump away, which is the one moment the pump
        # tier is supposed to decide.
        def throughput_kg(state, ctx)
          return super if broken?(state)

          super * SEEP_FRACTION * ground(state)
        end

        def failure_modes = { inrush: {} }

        def failure_mode(_state, _ctx, _cause) = :inrush

        def failure_detail(state, ctx)
          { driven: ctx.controls.fetch(:hewing, 0.0).round(1),
            carried_kg: state.fetch(:carried_kg, 0.0).round(3) }
        end
      end

      def pump(max_kg_per_s:, lift_m:, efficiency:, rated_omega:)
        Pump.new(
          id: :pump, label: "Sump Pump", accepts: [ :liquid ],
          max_kg_per_s: max_kg_per_s, heat_capacity: 1.0e4,
          control_id: :pumping,
          driven_by: :line_shaft, lift_m: lift_m, efficiency: efficiency,
          rated_omega: rated_omega, delivers_to: :work, displacement: true, burst_ratio: 1.4
        )
      end

      def drainage
        Nodes::Delivery.new(id: :drainage, label: "Drainage", accepts: [ :liquid ])
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

      class Fan < Nodes::Conduit
        include Overspeed

        def initialize(burst_ratio:, endangers: {}, **opts)
          @burst_ratio = burst_ratio.to_f
          @failure_hazards = endangers.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          super(**opts)
        end

        attr_reader :failure_hazards

        def head_pa(ctx) = ctx.node_state(id)&.fetch(:failure, nil) ? 0.0 : super

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

      def crew_for(roster, content, station:, place:, advance: nil)
        below = advance_seats(roster, advance)

        roster.map do |seat, posting|
          sheet = Crew.resolve(posting, content: content)
          # **Already down, and posted to nothing.** Standing in the district is the head start;
          # which face they work is still the player's first decision, and giving them a station
          # as well would put a gang on one lever before anybody had asked for it.
          underground = below.include?(seat)

          Minion.new(id: seat, station: underground ? nil : station,
                     place: underground ? advance.fetch(:place) : place,
                     name: sheet.fetch(:name),
                     minion: sheet.fetch(:minion), archetype: sheet.fetch(:archetype),
                     stats: sheet.fetch(:stats), tags: sheet.fetch(:tags),
                     mass_kg: sheet.fetch(:mass_kg), worn_kg: sheet.fetch(:worn_kg))
        end
      end

      # Never more than the roster holds, so a small quarters is a shift that is entirely at
      # bank rather than one with nobody left to send.
      def advance_seats(roster, advance)
        return [] if advance.nil? || !advance.fetch(:seats, 0).positive?

        roster.keys.last(advance.fetch(:seats)).freeze
      end
    end
  end
end
