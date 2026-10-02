# frozen_string_literal: true

module ReactorSim
  module Operations
    # A single-seam, bord-and-pillar shaft colliery, in its fan-ventilated era.
    #
    # The second operation, and the first that **buys** its power rather than making it: a line
    # shaft turned from an engine house somewhere else drives the fan, the pump and the winder.
    # Everything that makes a colliery difficult is a competition for that one shaft.
    #
    # ## The five subsystems, and what each one is here
    #
    #   winning      a hewer at the face, cutting into a seam that depletes
    #   haulage      face -> pit bottom, a road with a rate limit
    #   hoisting     pit bottom -> bank, the winder, off the line shaft
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

      CHASSIS = {
        # The post-Hartley pit: two shafts, so the ventilation circuit is a circuit and there is
        # a second way out. The only frame offered for now; a single-shaft variant is a
        # deliberately worse machine and belongs with the hazards that make it worse.
        two_shaft: {
          parts: {
            cutting: :hand_picks,
            lighting: :tallow_candles,
            winder: :steam_whim,
            fan: :waddle_fan,
            pump: :sinking_set,
            quarters: :lamp_cabin,
            rest: :refuge_hole
          }.freeze,
          advance: ADVANCE_SHIFT
        }.freeze
      }.freeze

      # `ground:` pins how gassy and how wet this pit is instead of drawing it. **Not in
      # `options:`**, and it does not need to be: it changes `initial_state` and nothing about
      # the graph, and a restored snapshot installs its own state over the top — so the ground
      # a match was given survives a round trip whatever this was called with.
      def build(id:, seed:, chassis: :two_shaft, loadout: {}, crew: {}, ground: nil,
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
      # **The ladderway is a fixture and the cage is a fitting.** Every shaft can be climbed;
      # only a mine that has bought the gear can be ridden. That is what makes the cage a
      # purchase rather than a setting, and it is why nobody is ever *completely* stranded —
      # when the winder stops the ladders are still there, and still awful.
      def passages
        [
          Passage.new(a: :bank, b: :pit_bottom, metres: SHAFT_DEPTH_M, speed_m_s: 0.6,
                      label: "Ladderway"),
          Passage.new(a: :pit_bottom, b: :district, metres: 200.0, speed_m_s: 1.2,
                      label: "Main Road")
        ]
      end

      # The same shaft, ridden instead of climbed — by rod or by cage. Either way it stops the
      # moment the line shaft does, and the ladders are what is left.
      def cage_passage(speed_m_s:, rated_omega:, label: "Cage")
        Passage.new(a: :bank, b: :pit_bottom, metres: SHAFT_DEPTH_M, speed_m_s: speed_m_s,
                    control_id: :man_winding, driven_by: :cage_drive,
                    rated_omega: rated_omega, label: label)
      end

      # **What winding men costs, and it is the men-or-coal choice made physical.** The cage
      # hangs off the same line shaft as everything else, so calling it loads the shaft, and a
      # loaded shaft turns slower — which means the winder raises less coal, the pump lifts less
      # water and the fan moves less air, all at once.
      #
      # `:constant` because a hoist is: the load on the drum is the weight on the rope and does
      # not care how fast it is going. `Nodes::Load`'s own comment names hoists as the case that
      # curve exists for.
      def cage_drive(max_torque:, rated_omega:)
        Nodes::Load.new(
          id: :cage_drive, label: "Cage Drive", moment_of_inertia: 120.0,
          max_torque: max_torque, rated_omega: rated_omega, curve: :constant,
          control_id: :man_winding, friction: 1.0
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
          ports: [
            Port.new(id: :air_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 40.0),
            Port.new(id: :air_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 40.0),
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
          # **The igniter names the OPEN-FLAME lever, and a safe lighting tier does not declare
          # it.** `run_heater` reads `ctx.controls.fetch(id, 0.0)`, so with gauze lanterns or
          # electric lamps fitted this resolves to zero and the district has no ignition source
          # at all — which is what "safe lighting" has to mean in a pit that makes firedamp.
          heater_control_id: :naked_flame, heater_watts: 1.2e3,
          igniter_kg_per_s: 4.0e-4,
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
      def upcast(head_pa:, rated_omega:)
        Nodes::Conduit.new(
          id: :upcast, label: "Upcast Fan", accepts: [ :gas ],
          max_kg_per_s: 40.0, conductance: 1.2, heat_capacity: 5.0e4,
          control_id: :ventilation, head_pa: head_pa,
          driven_by: :line_shaft, efficiency: 0.55, rated_omega: rated_omega
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
      # **`control_id` differs by tier and that is the mechanism, not an accident.** The
      # district's igniter names `:naked_flame`; a tier that is an open flame in a gassy room
      # declares its lever under that id and therefore lights the gas, and a safe tier declares
      # `:safe_light` instead. `Vessel#run_heater` reads `ctx.controls.fetch(id, 0.0)`, so a
      # lever nobody declared is simply zero and the district has no ignition source at all.
      # Both are labelled "Sconces", because to the player it is one lever either way — and
      # neither may be called `:sconces`, which is the NODE: one flat id namespace.
      class Lighting < Nodes::Load
        attr_reader :illumination

        def initialize(illumination:, **opts)
          @illumination = illumination.to_f
          super(**opts)
        end

        # What somebody standing in this room gets for free. Read off N−1 state and the
        # actuated levers, so it cannot depend on phase order.
        def ambient_tags(state, levers) = { darkvision: lit(state, levers) }

        # Turned down is dimmer; a powered tier whose shaft has stopped is dark. Both are
        # fractions of what this fitting manages at full.
        def lit(state, levers)
          fraction = @control_id ? (levers.fetch(@control_id, 0.0) / 100.0).clamp(0.0, 1.0) : 1.0
          fraction *= (omega(state).abs / @rated_omega).clamp(0.0, 1.0) if @rated_omega.positive?

          @illumination * fraction
        end

        # Recorded so the panel can read it as an ordinary field, the way `carried_kg` is.
        def apply(state, ctx, grant)
          super.merge(lit: lit(state, ctx.controls))
        end
      end

      def sconces(illumination:, control_id:, max_torque: 0.0, rated_omega: 0.0)
        Lighting.new(
          id: :sconces, label: "Sconces", illumination: illumination, control_id: control_id,
          max_torque: max_torque, rated_omega: rated_omega, curve: :viscous,
          moment_of_inertia: 12.0
        )
      end

      # **The hewer's lever, and an effort station**: what comes of it depends on who is swinging
      # the pick. Shaped exactly like the stoker's line on the steam engine.
      # **The node is a noun and the lever is a gerund**, as `:stoker`/`:stoking` is on the
      # engine — node, control point, gauge and minion ids share one flat namespace, so a
      # conduit and its own lever cannot both be called `:hewing`.
      def pick_line(max_kg_per_s:)
        Nodes::Conduit.new(
          id: :pick_line, label: "Hewing", accepts: [ :solid ],
          max_kg_per_s: max_kg_per_s, heat_capacity: 2.0e3,
          control_id: :hewing
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
        def initialize(advanced_by:, supported_by:, endangers: {}, **opts)
          @advanced_by = advanced_by.to_sym
          @supported_by = supported_by.to_sym
          @failure_hazards = endangers.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          super(**opts)
        end

        attr_reader :failure_hazards

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
        def failure_modes = { roof_fall: { derates: { throughput: 0.12 } } }

        def failure_mode(_state, _ctx, _cause) = :roof_fall

        def failure_detail(state, ctx)
          { unsupported: (ctx.controls.fetch(@advanced_by, 0.0) -
                          ctx.controls.fetch(@supported_by, 0.0)).clamp(0.0, 100.0).round(1),
            carried_kg: state.fetch(:carried_kg, 0.0).round(3) }
        end
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
          }
        )
      end

      # The winder. **Driven off the line shaft**, so raising coal costs bought power, and the
      # work it does leaves the operation on the ledger rather than heating anything.
      def winder(max_kg_per_s:, lift_m:, rated_omega:)
        Nodes::Conduit.new(
          id: :winder, label: "Winding Engine", accepts: [ :solid ],
          max_kg_per_s: max_kg_per_s, heat_capacity: 8.0e3,
          control_id: :winding,
          driven_by: :line_shaft, lift_m: lift_m, efficiency: 0.62,
          rated_omega: rated_omega, delivers_to: :work, displacement: true
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
        Nodes::Conduit.new(
          id: :pump, label: "Sump Pump", accepts: [ :liquid ],
          max_kg_per_s: max_kg_per_s, heat_capacity: 1.0e4,
          control_id: :pumping,
          driven_by: :line_shaft, lift_m: lift_m, efficiency: efficiency,
          rated_omega: rated_omega, delivers_to: :work, displacement: true
        )
      end

      def drainage
        Nodes::Delivery.new(id: :drainage, label: "Drainage", accepts: [ :liquid ])
      end

      # --- the supply -----------------------------------------------------------

      # What the engine house turns. Everything that costs power hangs off this one shaft, which
      # is what makes a brownout a whole-mine event rather than one machine stopping.
      def line_shaft(rated_torque_nm:, rated_omega:)
        Nodes::Import.new(
          id: :line_shaft, label: "Line Shaft",
          rated_torque_nm: rated_torque_nm, rated_omega: rated_omega,
          moment_of_inertia: 900.0, friction: 4.0, control_id: :clutch
        )
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
                     stats: sheet.fetch(:stats), tags: sheet.fetch(:tags))
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
