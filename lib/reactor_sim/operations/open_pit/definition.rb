# frozen_string_literal: true

module ReactorSim
  module Operations
    # **A sunk limonite pit, worked by hand.** Wash ore — lumps of brown iron ore in clay — lies
    # under overburden; a stripping gang takes the overburden off, and an ore gang gets the ore it
    # uncovers. Each face is got into a muck pile and carried out up the ramp road by barrow: the
    # spoil to the dump, where the dumpmen spread it, and the ore to the bin at bank, to be washed and
    # calcined into the finished ore the pit is judged by.
    #
    # **The two gangs are the game.** The ore face can be worked only behind the stripping face,
    # a berm back, so a stripping gang that falls behind stops the ore; and every face is three
    # jobs — getting, carrying out, spreading — competing for one shift. Machines (shovels,
    # dinkeys) are upgrades fitted into the same faces later. See
    # `docs/design_sketches/open-pit.md`.
    module OpenPit
      extend self

      TYPE = :open_pit
      DEFAULT_TIME_SCALE = 1.0

      # A stripping cut, narrow so its faces move in a match: a hand gang's advance is tens of
      # centimetres, a shovel's a few metres. Long enough that no match reaches the end.
      CUT_WIDTH_M = 2.0
      CUT_LENGTH_M = 40.0

      # The ore face stays this far behind the stripping face — a safety bench — and the match
      # starts with the stripping this far ahead, so some ore is uncovered from the first tick.
      BERM_M = 2.0
      STRIPPING_LEAD_M = 2.4

      # Bulk densities in the bank: overburden, and wash ore at about a quarter limonite in clay.
      OVERBURDEN_KG_M3 = 1_800.0
      WASH_ORE_KG_M3 = 2_000.0
      WASH_ORE = { limonite: 0.25, clay: 0.75 }.freeze

      STARTING_PARTS = {
        stripping_getting: :pick_and_shovel, stripping_carrying: :barrows,
        ore_getting: :pick_and_shovel, ore_carrying: :barrows, washhouse: :washhouse, bay_1: :single_log_washer,
        pump: :single_pump, mud_dam: :mud_dam, reservoir: :reservoir, magazine: :powder_house, kiln: :open_clamp,
        coal_stock: :coal_heap, quarters: :site_hut, stripping_hut: :bench_hut, ore_hut: :bench_hut,
        dump_shelter: :dump_shelter
      }.freeze

      CHASSIS = { sunk_pit: { parts: STARTING_PARTS }.freeze }.freeze

      # `ground:` pins the ground instead of drawing it — `Ground::ORDINARY` for a spec. Not in
      # `options:`: it changes `initial_state` and nothing about the graph, and a restored
      # snapshot installs its own state. `conditions:`, `grudges:` and `wounds:` are the colliery's.
      def build(id:, seed:, chassis: CHASSIS.keys.first, loadout: {}, crew: {}, ground: nil,
                conditions: nil, grudges: nil, wounds: nil, time_scale: DEFAULT_TIME_SCALE, state: nil,
                rngs: nil, content: nil)
        chassis = chassis.to_sym
        assembly = assembly_for(chassis, loadout, ground: ground, conditions: conditions)
        fragment = assembly.build!
        roster = Crew.normalise(crew, capacity: assembly.crew_capacity)
        fitted = fitted_machines(assembly)
        posts, boards = machine_posts(assembly, fitted)

        op = Operation.new(
          id: id, type: TYPE, seed: seed, time_scale: time_scale, state: state, rngs: rngs, content: content,
          options: { chassis: chassis, loadout: assembly.loadout, crew: roster, conditions: conditions,
                     grudges: Animosity.carried_over(grudges), wounds: Wounds.carried_over(wounds) }.compact,
          nodes: fragment.nodes, links: fragment.links, thermal_links: fragment.thermal_links,
          drive_links: fragment.drive_links, passages: fragment.passages, places: fragment.places,
          control_points: fragment.control_points + posts, diagnostics: assembly.diagnostics + boards,
          minions: Crew.minions(roster, content: content || Content.default, station: assembly.crew_origin,
                                place: :bank, advance: assembly.advance_shifts)
        )
        state ? op : raised(op, fitted)
      end

      # **The pit, wired for the machines its loadout fits** (§17 of the sketch): which machines
      # there are, and whether a crusher feeds the bays, is read first, off the loadout alone, and
      # the faces and the bays are wired for them.
      def assembly_for(chassis, loadout = {}, ground: nil, conditions: nil)
        spec = CHASSIS.fetch(chassis.to_sym) { raise Error, "unknown open pit chassis #{chassis.inspect}" }
        spec = spec.merge(ground: ground) if ground
        spec = spec.merge(conditions: conditions) if conditions
        unwired = Assembly.new(slots: slots(spec), loadout: loadout, spec: spec)
        fitted = fitted_machines(unwired)

        Assembly.new(slots: slots(spec, fitted, feed_for(unwired)), loadout: loadout, spec: spec,
                     fixtures: fixtures(spec, fitted),
                     instruments: catalogue, order: PANEL_ORDER, routes: ROUTES + machine_routes(fitted),
                     advisories: [])
      end

      # `{ face => { shovel:, train: } }`, whether each is fitted.
      def fitted_machines(assembly)
        FACES.to_h do |face_id|
          [ face_id, { shovel: !assembly.part(shovel(face_id).(:dipper)).nil?,
                       train: !assembly.part(train(face_id).(:train)).nil? } ]
        end
      end

      def feed_for(assembly)
        return UNCRUSHED unless assembly.part(:crusher)

        { from: :crushed_ore, crushed: true, belted: !assembly.part(:feed_belt).nil? }
      end

      # The machines' drivers and their boards, built once what reads the water and the pressure is
      # known.
      def machine_posts(assembly, fitted)
        pieces = FACES.flat_map do |face_id|
          machines = fitted.fetch(face_id)
          names = face(face_id)
          [ (if machines.fetch(:shovel)
               id = shovel(face_id).prefix
               [ MobileEngine.driver(assembly, id, place: names.place), MobileEngine.board(id, place: names.place) ]
             end),
            (if machines.fetch(:train)
               id = train(face_id).prefix
               [ MobileEngine.locomotive_driver(assembly, id, place: footplate(face_id), track: TRACKS.fetch(face_id)),
                 MobileEngine.train_board(id, place: footplate(face_id)) ]
             end) ].compact
        end
        [ pieces.map(&:first), pieces.map(&:last) ]
      end

      # The advance shift raised the machines' steam: they start at work.
      def raised(op, fitted)
        shovels = FACES.select { |f| fitted.dig(f, :shovel) }.map { |f| shovel(f).prefix }
        trains = FACES.select { |f| fitted.dig(f, :train) }.map { |f| train(f).prefix }
        op = MobileEngine.raised(op, shovels, demand: 60.0) unless shovels.empty?
        op = MobileEngine.raised(op, trains, demand: 100.0) unless trains.empty?
        op
      end

      # The names a face's pieces go by: `stripping_bench`, `ore_muck`, and the place it is in.
      def face(id) = Names.new(id, place: :"#{id}_bench")

      # And its machines': `stripping_shovel_boiler` at the bench, `ore_train_cars` on its footplate.
      def shovel(id) = Names.new(:"#{id}_shovel", place: :"#{id}_bench")
      def train(id) = Names.new(:"#{id}_train", place: footplate(id))
      def footplate(id) = :"#{id}_train_footplate"

      FACES = %i[stripping ore].freeze

      # **Down the ramp road on foot**: to the stripping bench, on down to the ore, and across to
      # the dump. Minutes, not the colliery's shaft — but every trip to rest at bank is one.
      def passages
        [ Passage.new(a: :bank, b: :stripping_bench, metres: 70.0, speed_m_s: 1.0, label: "Ramp Road"),
          Passage.new(a: :stripping_bench, b: :ore_bench, metres: 35.0, speed_m_s: 0.9, label: "Ramp Road"),
          Passage.new(a: :bank, b: :spoil_dump, metres: 80.0, speed_m_s: 1.2, label: "Dump Road"),
          Passage.new(a: :bank, b: :dams, metres: 40.0, speed_m_s: 1.2, label: "Dam Path"),
          Passage.new(a: :bank, b: :kiln_foot, metres: 20.0, speed_m_s: 1.2, label: "Kiln Road"),
          Passage.new(a: :kiln_foot, b: :kiln_top, metres: 15.0, speed_m_s: 0.6, label: "Kiln Ramp") ]
      end

      # --- the ground ----------------------------------------------------------------------

      # **The pit's ground, drawn once per match** from each bench's own stream: how thick each
      # bench is, and along the stripping cut, stretches of harder ground — boulders, cemented
      # hardpan, an old stump — a metre or a few long. Nobody is told where they are.
      #
      # **A triangular spread rather than a log-normal**: a sum of two uniform draws needs no
      # transcendental, and those are where IEEE results differ across platforms (`Rng`).
      module Ground
        # Pins a bench at its median thickness with no hard stretches.
        ORDINARY = :ordinary

        # Each thickness lies within this share of its median, most often near it.
        THICKNESS_SPREAD = 0.4

        # How many hard stretches a cut holds — none to three, by these odds — how far ahead of where
        # the face starts, how long, and how much harder than the bench's own ground. Within what a
        # match's work reaches: a hand gang meets the nearest, a shovel all of them.
        STRETCH_ODDS = [ 0.25, 0.4, 0.25, 0.1 ].freeze
        STRETCH_AHEAD_M = (0.1..3.0)
        STRETCH_LENGTH_M = (0.5..2.0)
        STRETCH_HARDNESS = (2.0..4.0)

        module_function

        def thickness(rng, median_m) = median_m * (1.0 + (THICKNESS_SPREAD * (rng.float + rng.float - 1.0)))

        # Nearest first, measured along the cut from `from_m`, where the face starts.
        def stretches(rng, from_m)
          Array.new(count(rng)) do
            { at_m: from_m + rng.between(STRETCH_AHEAD_M.begin, STRETCH_AHEAD_M.end),
              length_m: rng.between(STRETCH_LENGTH_M.begin, STRETCH_LENGTH_M.end),
              hardness: rng.between(STRETCH_HARDNESS.begin, STRETCH_HARDNESS.end) }
          end.sort_by { |s| s.fetch(:at_m) }
        end

        def count(rng, odds = STRETCH_ODDS)
          roll = rng.float
          odds.each_with_index do |chance, n|
            return n if roll < chance

            roll -= chance
          end
          odds.length - 1
        end

        # **How wet the ground is**, a multiplier on its seepage, as the colliery's seeps are drawn:
        # a dry pit and a wet one, and the spread is past what a bailing gang holds.
        WETNESS = (0.2..2.4)

        # **Springs along the ore cut**: none, one or two, met as the face reaches them — a limestone
        # cavern, the hill-clay broken into — and flowing from then on.
        SPRING_ODDS = [ 0.35, 0.45, 0.2 ].freeze
        SPRING_AHEAD_M = (0.1..2.5)
        SPRING_KG_PER_S = (2.0..8.0)

        def wetness(rng) = rng.between(WETNESS.begin, WETNESS.end)

        # **When a face or a dump's edge lets go**, a run of hidden thresholds drawn at once: each a
        # fresh draw about its median, the first the largest, so one slide says nothing about when
        # the next comes. Pinned, each is the median and the first its multiple.
        THRESHOLD_SPREAD = 0.5
        THRESHOLDS_DRAWN = 16

        def thresholds(rng, median, first:, pinned: false)
          Array.new(THRESHOLDS_DRAWN) do |n|
            drawn = pinned ? median : median * (1.0 + (THRESHOLD_SPREAD * (rng.float + rng.float - 1.0)))
            n.zero? ? drawn * first : drawn
          end
        end

        def springs(rng)
          Array.new(count(rng, SPRING_ODDS)) do
            { at_m: rng.between(SPRING_AHEAD_M.begin, SPRING_AHEAD_M.end),
              kg_per_s: rng.between(SPRING_KG_PER_S.begin, SPRING_KG_PER_S.end) }
          end.sort_by { |s| s.fetch(:at_m) }
        end
      end

      # --- a bench ---------------------------------------------------------------------------

      # **A bench of the cut, as geometry.** It holds the whole bench as a stock — its length, the
      # cut's width, its drawn thickness — and **its face advances by what is dug off it**
      # (`advanced_m`, from where it started). In a hard stretch the face reads harder
      # (`hardness`), and getting there is that much slower.
      #
      # **A bench `beneath:` another can be worked only behind that one's face, `berm_m` back**:
      # what lies between is `uncovered_kg`, and getting it stops at nothing uncovered. A thicker
      # overburden uncovers less ore for the same stripping, which is the stripping ratio — not
      # drawn, but falling out of the two thicknesses. Nil on a bench with nothing over it.
      #
      # **Water standing on its floor** (`wetted_by:`, the sump) makes its face harder — wet clay is
      # heavy, sticky work — and at the flood mark the face is under water and nothing is uncovered.
      #
      # **Digging at the toe leaves the face hanging** (`overhang_kg`, `UNDERCUT` of what is dug off
      # `:out`), and the barmen bring it down safely through `:barred`. Left hanging past a hidden
      # threshold — drawn afresh for every slide, less for a taller bench and less again wet — it
      # **slides**: the overhang goes down `:slide` onto the face's slip pile (`slip:`), the face is
      # buried until the pile is cleared, and whoever is on the bench is hurt (`endangers:`, keyed
      # `slid`, by the `overhang_kg` that came down).
      #
      # **A shot breaks the ground ahead** (`shot_hole:`, its running `brought_down_kg`): the face digs
      # that `broken_kg` first, loose, whatever stretch or frost it is in. **In freezing weather it
      # freezes** (`frost`, toward how far the air is below freezing, and back), and frozen it is
      # harder; a bench that has not yet seen the sky takes the frost its season has left in it.
      #
      # It writes **its face's board** (`signal`): what the gang would say.
      #
      #   state: parcels, thickness_m, initial_kg, stretches, advanced_m, hardness, uncovered_kg,
      #          depth_m, overhang_kg, thresholds, slipping_kg, broken_kg, shot_seen_kg, frost, signal,
      #          durability, failure
      class Bench < Nodes::Vessel
        SIGNALS = {
          flooded: "the face flooded",
          buried: "buried by a slide",
          hanging: "the face hanging",
          stripping_behind: "stripping behind — nothing uncovered",
          waiting_on_barrows: "waiting on the barrows",
          nobody_getting: "nobody getting",
          water_on_floor: "water on the floor",
          broken: "in broken ground",
          frozen: "the face frozen",
          hard_ground: "into hard ground",
          getting: "getting"
        }.freeze

        # **Broken ground digs loose**: this hardness, against ordinary ground's 1.0.
        BROKEN_HARDNESS = 0.6

        # **Frost**: the air this far below freezing freezes the face through; it comes and goes
        # over `FROST_S`; and frozen through, the face is `FROST_HARDNESS` more again.
        FREEZING_K = 273.15
        FULL_FROST_K = 10.0
        FROST_S = 1_800.0
        FROST_HARDNESS = 3.0
        FROZEN_SEEN = 0.3

        # How much harder the face is with the water at the flood mark than dry: the period's dry
        # clay against damp, 1,350 yd³ a day against 900.
        WET_HARDNESS = 0.5

        # The share of what is dug at the toe that leaves the ground above it unsupported.
        UNDERCUT = 0.25

        # The overhang a face of the median thickness holds before it slides, dry; a fresh face holds
        # this much more the first time. Rain takes `WET_WEAKENS` of it away, and the ore bench's toe
        # at the flood mark `TOE_WEAKENS` more. The gang see it hanging past `HANGING_SEEN` of it.
        HANGING_KG = 1_200.0
        FIRST_HANGING = 1.5
        WET_WEAKENS = 0.4
        TOE_WEAKENS = 0.5
        HANGING_SEEN = 0.6

        attr_reader :mix, :bulk_kg_m3, :width_m, :length_m, :median_thickness_m, :beneath, :berm_m, :start_m,
                    :getting, :getters, :muck, :muck_full_kg, :wetted_by, :slip, :shot_hole

        # `mix` is what it is made of, as shares of its mass; `getting:` the conduit that wins it and
        # `getters:` their post; `muck:` the pile it is got into, full at `muck_full_kg`.
        # `hard_ground:` draws hard stretches along it; `stretches:` pins them instead.
        def initialize(id:, label:, mix:, bulk_kg_m3:, width_m:, length_m:, median_thickness_m:, getting:, getters:,
                       muck:, muck_full_kg:, slip:, shot_hole:, beneath: nil, berm_m: 0.0, start_m: 0.0,
                       hard_ground: false, ground: nil, stretches: nil, wetted_by: nil, endangers: {}, damages: {})
          @slip = slip.to_sym
          @shot_hole = shot_hole.to_sym
          @wetted_by = wetted_by&.to_sym
          @mix = mix.freeze
          @bulk_kg_m3 = bulk_kg_m3.to_f
          @width_m = width_m.to_f
          @length_m = length_m.to_f
          @median_thickness_m = median_thickness_m.to_f
          @beneath = beneath&.to_sym
          @berm_m = berm_m.to_f
          @start_m = start_m.to_f
          @hard_ground = hard_ground
          @ground = ground
          @stretches = stretches&.map(&:freeze)&.freeze
          @getting = getting.to_sym
          @getters = getters.to_sym
          @muck = muck.to_sym
          @muck_full_kg = muck_full_kg.to_f
          super(id: id, label: label, heat_capacity: 1.0e5, ambient_conductance: 0.0,
                volume_m3: @length_m * @width_m * @median_thickness_m * 3.0, endangers: endangers, damages: damages,
                ports: [ Port.new(id: :out, direction: :outlet, accepts: [ :solid ], max_kg_per_s: 200.0),
                         Port.new(id: :barred, direction: :outlet, accepts: [ :solid ], max_kg_per_s: 200.0),
                         # A slide comes down in seconds.
                         Port.new(id: :slide, direction: :outlet, accepts: [ :solid ], max_kg_per_s: 1.0e5) ])
        end

        def initial_state(rng, content = nil)
          state = super
          thickness = @ground ? @median_thickness_m : Ground.thickness(rng, @median_thickness_m)
          stretches = @stretches || (@hard_ground && !@ground ? Ground.stretches(rng, @start_m) : [])
          thresholds = Ground.thresholds(rng, HANGING_KG, first: FIRST_HANGING, pinned: !@ground.nil?)
          kg = @length_m * @width_m * thickness * @bulk_kg_m3
          parcels = @mix.map do |resource, share|
            Parcel.build(resource: resource, kg: kg * share, temperature_k: initial_temperature_k, content: content)
          end
          state.merge(parcels: Parcel.normalise(parcels), thickness_m: thickness, initial_kg: kg, stretches: stretches,
                      advanced_m: @start_m, hardness: hardness_at(stretches, @start_m), uncovered_kg: nil,
                      depth_m: thickness, overhang_kg: 0.0, thresholds: thresholds, slipping_kg: 0.0,
                      broken_kg: 0.0, shot_seen_kg: 0.0, frost: nil, signal: SIGNALS.keys.index(:getting))
        end

        # **What the face will hold before it slides, now**: the next drawn threshold, less for a
        # taller bench, less in the rain, less with its toe in water. Nil once none are left.
        def holds_kg(state, ctx)
          drawn = state.fetch(:thresholds, []).first or return nil
          drawn * @median_thickness_m / state.fetch(:thickness_m) *
            (1.0 - (WET_WEAKENS * ctx.sky.fetch(:wet, 0.0))) * (1.0 - (TOE_WEAKENS * flooding(ctx)))
        end

        def overload?(state, ctx, _integrity)
          holds = holds_kg(state, ctx)
          !holds.nil? && state.fetch(:overhang_kg, 0.0) >= holds
        end

        def failure_modes = { slid: {} }

        def failure_mode(_state, _ctx, _cause) = :slid

        def failure_detail(state, _ctx) = { overhang_kg: state.fetch(:overhang_kg, 0.0).round(1) }

        def kg_per_m(state) = @width_m * state.fetch(:thickness_m) * @bulk_kg_m3

        def advanced_m(state) = @start_m + ((state.fetch(:initial_kg) - contents_kg(state)) / kg_per_m(state))

        def stretches(state) = state.fetch(:stretches, [])

        # How much harder than ordinary the face is where it stands.
        def hardness_at(stretches, at_m)
          stretch = stretches.find { |s| at_m >= s.fetch(:at_m) && at_m < s.fetch(:at_m) + s.fetch(:length_m) }
          stretch ? stretch.fetch(:hardness) : 1.0
        end

        def apply(state, ctx, grant)
          applied, events = super
          applied = freeze_with(blast(hang(applied, grant), grant, ctx), ctx)
          applied = slide(applied) if broken?(applied)
          advanced = advanced_m(applied)
          above = @beneath && ctx.node_state(@beneath)
          wet = flooding(ctx)
          buried = buried?(applied, ctx)
          uncovered = above && [ (above.fetch(:advanced_m) - @berm_m - advanced) * kg_per_m(applied), 0.0 ].max
          uncovered = 0.0 if buried || (uncovered && wet >= 1.0)
          settled = applied.merge(advanced_m: advanced, uncovered_kg: uncovered,
                                  hardness: face_hardness(applied, advanced) * (1.0 + (WET_HARDNESS * wet)),
                                  depth_m: applied.fetch(:thickness_m) + (above ? above.fetch(:thickness_m) : 0.0))
          [ settled.merge(signal: SIGNALS.keys.index(signal(settled, ctx, wet, buried))), events ]
        end

        # Under a slide until its pile is cleared, or while it is still coming down.
        def buried?(state, ctx)
          state.fetch(:slipping_kg, 0.0).positive? ||
            Parcel.total_kg((ctx.node_state(@slip) || {}).fetch(:parcels, [])) > Parcel::EPSILON
        end

        # How deep the water on its floor is, against the flood mark: 0 dry, 1 at the mark.
        def flooding(ctx)
          sump = @wetted_by && ctx.nodes&.[](@wetted_by)
          state = sump && ctx.node_state(@wetted_by)
          state ? sump.flooding(state, ctx.content) : 0.0
        end

        # The frost a face goes toward in this air, from where it was over `dt`; nil was never seen.
        def frosted(was, air_k, dt)
          toward = ((FREEZING_K - air_k) / FULL_FROST_K).clamp(0.0, 1.0)
          was.nil? ? toward : was + ((toward - was) * dt / FROST_S)
        end

        # Loose where a shot has broken it; otherwise the stretch it is in, frozen or not.
        def face_hardness(state, at_m)
          return BROKEN_HARDNESS if state.fetch(:broken_kg, 0.0).positive?

          hardness_at(stretches(state), at_m) * (1.0 + (FROST_HARDNESS * state.fetch(:frost, 0.0).to_f))
        end

        private

        # What the shots have broken since last seen is ground ahead, and what was dug since takes it.
        def blast(state, grant, ctx)
          down = (ctx.node_state(@shot_hole) || {}).fetch(:brought_down_kg, state.fetch(:shot_seen_kg, 0.0))
          broken = state.fetch(:broken_kg, 0.0) + down - state.fetch(:shot_seen_kg, 0.0) - grant.sent_kg(:out)
          state.merge(broken_kg: [ broken, 0.0 ].max, shot_seen_kg: down)
        end

        # Toward the frost the air would leave in it, and the first time, straight there.
        def freeze_with(state, ctx)
          air = ctx.sky.fetch(:outdoor_k, nil) or return state.merge(frost: state.fetch(:frost) || 0.0)

          state.merge(frost: frosted(state.fetch(:frost), air, ctx.dt))
        end

        # What was dug undercuts the face, and what was barred down takes the overhang off it; what
        # went down the slide is off what is still to come down.
        def hang(state, grant)
          overhang = state.fetch(:overhang_kg, 0.0) + (UNDERCUT * grant.sent_kg(:out)) - grant.sent_kg(:barred)
          state.merge(overhang_kg: [ overhang, 0.0 ].max,
                      slipping_kg: [ state.fetch(:slipping_kg, 0.0) - grant.sent_kg(:slide), 0.0 ].max)
        end

        # **The slide**: the overhang comes down, the next threshold is a fresh one, and the face starts
        # hanging again.
        def slide(state)
          state.merge(slipping_kg: state.fetch(:slipping_kg) + state.fetch(:overhang_kg), overhang_kg: 0.0,
                      thresholds: state.fetch(:thresholds).drop(1), failure: nil,
                      durability: state.fetch(:initial_durability))
        end

        def signal(state, ctx, wet, buried)
          return :flooded if wet >= 1.0
          return :buried if buried

          holds = holds_kg(state, ctx)
          return :hanging if holds && state.fetch(:overhang_kg) >= HANGING_SEEN * holds
          return :stripping_behind if state[:uncovered_kg] && state[:uncovered_kg] <= Parcel::EPSILON

          muck = Parcel.total_kg((ctx.node_state(@muck) || {}).fetch(:parcels, []))
          return :waiting_on_barrows if muck >= @muck_full_kg
          return :nobody_getting unless ctx.controls.fetch(@getters, 0.0).positive?
          return :water_on_floor if wet.positive?
          return :broken if state.fetch(:broken_kg).positive?
          return :frozen if state.fetch(:frost, 0.0).to_f >= FROZEN_SEEN
          return :hard_ground if state.fetch(:hardness) > 1.0

          :getting
        end
      end

      # **Getting a bench by hand**: picks and shovels winning the face into the muck pile, a gang
      # rated per getter. **Harder ground wins that much less** for the same effort, and a bench
      # beneath another gives up no more than is uncovered. Worked harder, and in harder ground,
      # it is more dangerous to stand at (`:getting`).
      class Getting < Nodes::Conduit
        def initialize(bench:, perils: [], **opts)
          @bench = bench.to_sym
          @perils = perils.freeze
          super(**opts)
        end

        attr_reader :bench, :perils

        def throughput_kg(state, ctx)
          bench = ctx.node_state(@bench) or return 0.0
          got = super / bench.fetch(:hardness, 1.0)
          uncovered = bench[:uncovered_kg]
          uncovered ? [ got, uncovered ].min : got
        end

        # How hard the face was worked, against a full gang, and how hard it was.
        def apply(state, ctx, grant)
          hardness = (ctx.node_state(@bench) || {}).fetch(:hardness, 1.0)
          working = ctx.dt.positive? ? state.fetch(:carried_kg, 0.0) * hardness / (full_crew_kg_per_s * ctx.dt) : 0.0
          super.merge(working: working, hardness: hardness)
        end

        def activity(state, quantity, _dt)
          return nil unless quantity == :getting

          state.fetch(:working, 0.0) * state.fetch(:hardness, 1.0)
        end
      end

      # **Barrows up the ramp road**, a gang rated per barrowman. A barrowful a round trip, and the
      # trip is the ramp — the bench's depth over `RAMP_GRADE` — and the carry at the top: so the
      # deeper ore is the longer carry, and a pit that is getting deeper is getting slower to clear.
      # Its perils scale with the barrows going past (`:barrows`).
      class Barrowing < Nodes::Conduit
        # A plank ramp, one in eight; loaded up it, empty down, and the filling and tipping.
        RAMP_GRADE = 1.0 / 8.0
        UP_M_S = 0.7
        DOWN_M_S = 1.1
        HANDLING_S = 30.0

        # `max_kg_per_s` is one barrowman's on the level, `carry_m` the carry at the top, `bench:`
        # the bench whose depth the ramp climbs.
        def initialize(bench:, carry_m:, perils: [], **opts)
          @bench = bench.to_sym
          @carry_m = carry_m.to_f
          @perils = perils.freeze
          super(**opts)
        end

        attr_reader :bench, :carry_m, :perils

        def self.trip_s(depth_m, carry_m)
          metres = (depth_m / RAMP_GRADE) + carry_m
          (metres / UP_M_S) + (metres / DOWN_M_S) + HANDLING_S
        end

        # What a barrowman manages at this depth against what he would on the level.
        def pace(ctx)
          depth = (ctx.node_state(@bench) || {}).fetch(:depth_m, 0.0)
          self.class.trip_s(0.0, @carry_m) / self.class.trip_s(depth, @carry_m)
        end

        def throughput_kg(state, ctx) = super * pace(ctx)

        def apply(state, ctx, grant)
          full = full_crew_kg_per_s * pace(ctx) * ctx.dt
          super.merge(traffic: full.positive? ? (state.fetch(:carried_kg, 0.0) / full).clamp(0.0, 1.0) : 0.0)
        end

        def activity(state, quantity, _dt) = quantity == :barrows ? state.fetch(:traffic, 0.0) : nil
      end

      # **A log washer**: toothed logs turning in a trough of wash ore and water, off the line
      # shaft. It washes as fast as the logs turn — the shaft's speed against its rated speed — and
      # as its water allows, and **parts what it washes by tag**: the limonite out of `:washed`
      # (accepting `ore`), the clay and the water off `:slurry` to the mud dam. Short of water it
      # washes less; the work of the logs is charged off the shaft.
      #
      # **Its efficiency is one number**: the share of the limonite it washes that comes out clean.
      # The rest goes to the dam with the clay, and the slurry outlet's `transport_affinity` is what
      # sends exactly those shares, of exactly what it holds, out of each port.
      #
      # It draws only the water it needs, so a pump working harder than the washer cannot fill the
      # trough with water and lock the ore out. It writes **its board** (`signal`).
      #
      # **Its logs wear with what it washes**, and four times as fast on run-of-pit ore as on crushed
      # (`crushed:`): the lumps are what break the teeth. Worn, they knock, and the hands hear it;
      # broken, they wash nothing, and the log letting go is a hazard to whoever is raking.
      #
      #   state: parcels, joules, washing_kg, turning, short, signal, durability, failure
      class LogWasher < Node
        include Concerns::Thermal
        include Concerns::Holds
        include Concerns::Wearing

        SIGNALS = {
          logs_broken: "logs broken",
          logs_stopped: "logs stopped",
          short_of_water: "short of water",
          waiting_on_hand: "waiting on the washer hands",
          nothing_to_wash: "nothing to wash",
          logs_knocking: "washing — the logs knocking",
          washing: "washing"
        }.freeze

        # Under this share of its rated speed the logs are stopped, and it draws this many ticks'
        # worth of water ahead of what it is washing.
        STOPPED_SHARE = 0.1
        WATER_TICKS = 2.0

        # The tags it parts what it holds by.
        KINDS = %i[ore gangue liquid].freeze

        # Durability a second, washing flat out on crushed ore: about twelve hours of it, against
        # `Wearing::DEFAULT_DURABILITY_RANGE`. Uncrushed, about three.
        WEAR_PER_S = 0.023
        UNCRUSHED_WEAR = 4.0

        # Integrity under which the hands hear the logs knocking.
        WORN = 0.25

        attr_reader :heat_capacity, :ambient_conductance, :initial_temperature_k, :ambient_k, :volume_m3,
                    :rated_kg_per_s, :efficiency, :water_per_kg, :work_j_per_kg, :driven_by, :rated_omega,
                    :fed_by, :bin, :crushed, :perils, :failure_hazards

        # `rated_kg_per_s` is the wash ore it washes at rated speed; `water_per_kg` the water a
        # kilogram of it needs; `fed_by:` the conduit raking it in and `bin:` the bin or hopper that
        # comes from; `crushed:` whether that has been through a crusher.
        def initialize(id:, label:, rated_kg_per_s:, efficiency:, water_per_kg:, work_j_per_kg:, driven_by:,
                       rated_omega:, fed_by:, bin:, volume_m3:, crushed: false, perils: [], endangers: {},
                       heat_capacity: 2.0e5)
          super(id: id, label: label, ports: [
            Port.new(id: :ore_in, direction: :inlet, accepts: [ :solid ], max_kg_per_s: 50.0),
            Port.new(id: :water_in, direction: :inlet, accepts: [ :liquid ], max_kg_per_s: 50.0),
            Port.new(id: :washed, direction: :outlet, accepts: [ :ore ], max_kg_per_s: 50.0),
            Port.new(id: :slurry, direction: :outlet, accepts: %i[gangue liquid ore], max_kg_per_s: 200.0)
          ])
          @rated_kg_per_s = rated_kg_per_s.to_f
          @efficiency = efficiency.to_f
          @water_per_kg = water_per_kg.to_f
          @work_j_per_kg = work_j_per_kg.to_f
          @driven_by = driven_by.to_sym
          @rated_omega = rated_omega.to_f
          @fed_by = fed_by.to_sym
          @bin = bin.to_sym
          @crushed = crushed
          @volume_m3 = volume_m3.to_f
          @perils = perils.freeze
          @failure_hazards = endangers.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          @heat_capacity = heat_capacity.to_f
          @ambient_conductance = 20.0
          @initial_temperature_k = Units::STANDARD_TEMPERATURE_K
          @ambient_k = Units::STANDARD_TEMPERATURE_K
          freeze
        end

        def base_initial_state(rng, content)
          super.merge(washing_kg: 0.0, turning: 0.0, short: false, signal: SIGNALS.keys.index(:nothing_to_wash))
        end

        def speed(ctx) = (ctx.node_omega(@driven_by).to_f / @rated_omega).clamp(0.0, 1.0)

        # **What it washes this tick, and where each part goes**, from what it held last tick:
        # `washing` (wash ore), `washed` (clean limonite out of `:washed`), `out` (by resource, off
        # `:slurry`: the lost limonite, the clay, the water that went with it), `water_share`,
        # `turning`, and `held` by resource.
        def round(state, ctx)
          held = held_by(state, ctx.content)
          ore, gangue, liquid = held.values_at(:ore, :gangue, :liquid)
          solids = ore.values.sum + gangue.values.sum
          water = liquid.values.sum
          turning = speed(ctx) * derating(state, :washing)
          wanted = [ @rated_kg_per_s * turning * ctx.dt, solids ].min
          water_share = wanted.positive? ? (water / (@water_per_kg * wanted)).clamp(0.0, 1.0) : 1.0
          washing = wanted * water_share
          share = solids.positive? ? washing / solids : 0.0
          water_out = [ water, @water_per_kg * washing ].min
          out = ore.transform_values { |kg| kg * share * (1.0 - @efficiency) }
                   .merge(gangue.transform_values { |kg| kg * share })
                   .merge(liquid.transform_values { |kg| water_out * kg / water })
          { washing: washing, washed: ore.values.sum * share * @efficiency, out: out, water: water,
            water_out: water_out, water_share: water_share, turning: turning, held: ore.merge(gangue).merge(liquid) }
        end

        # The ore inlet is the washer hand's to drive; the water it asks for itself, enough to have
        # `WATER_TICKS` in hand once this tick's has gone with the slurry.
        def plan(state, ctx)
          r = round(state, ctx)
          need = @water_per_kg * @rated_kg_per_s * r.fetch(:turning) * ctx.dt * WATER_TICKS
          Intent.new(draws: { water_in: [ need - (r.fetch(:water) - r.fetch(:water_out)), 0.0 ].max },
                     pushes: { washed: r.fetch(:washed), slurry: r.fetch(:out).values.sum })
        end

        # Each resource leaves the slurry outlet by what it is sending against what it holds, so the
        # mix that goes is the mix it washed.
        def transport_affinity(port_id, state, ctx)
          return {} unless port_id == :slurry

          r = round(state, ctx)
          weights = r.fetch(:out).to_h { |resource, kg| [ resource, kg / r.fetch(:held).fetch(resource) ] }
          top = weights.values.max.to_f
          top.positive? ? weights.transform_values { |w| w / top } : {}
        end

        # What it planned, from last tick, scaled by what it actually got rid of.
        def apply(state, ctx, grant)
          r = round(ctx.node_state(id), ctx)
          planned = r.fetch(:washed) + r.fetch(:out).values.sum
          sent = grant.sent_kg(:washed) + grant.sent_kg(:slurry)
          washed = planned.positive? ? r.fetch(:washing) * (sent / planned).clamp(0.0, 1.0) : 0.0
          state = state.merge(washing_kg: washed, turning: r.fetch(:turning), short: r.fetch(:water_share) < 1.0)
          state.merge(signal: SIGNALS.keys.index(signal(state, r, ctx)))
        end

        # The logs' work through the clay, from what it washed last tick, as a drag on the shaft.
        def drag_shaft = @driven_by

        def drag_conductances(state, ctx)
          omega = ctx.node_omega(@driven_by).to_f
          return {} unless omega.positive? && ctx.dt.positive?

          watts = state.fetch(:washing_kg, 0.0) / ctx.dt * @work_j_per_kg
          watts.positive? ? { friction: watts / (omega**2) } : {}
        end

        # How hard the logs are turning, for a peril of whoever is beside them.
        def activity(state, quantity, _dt) = quantity == :turning ? state.fetch(:turning, 0.0) : nil

        def stress_per_second(state, ctx)
          return 0.0 unless ctx.dt.positive?

          washed = state.fetch(:washing_kg, 0.0) / ctx.dt / @rated_kg_per_s
          washed * WEAR_PER_S * (@crushed ? 1.0 : UNCRUSHED_WEAR)
        end

        def failure_modes = { logs_broken: { derates: { washing: 0.0 } } }

        def failure_detail(state, _ctx) = { crushed: @crushed, washing_kg: state.fetch(:washing_kg, 0.0).round(3) }

        private

        # What it holds, `{ ore: { resource => kg }, gangue: {...}, liquid: {...} }`, by tag.
        def held_by(state, content)
          held = KINDS.to_h { |kind| [ kind, {} ] }
          state.fetch(:parcels, []).each do |p|
            resource = p.fetch(:resource)
            kind = KINDS.find { |tag| content.tags(resource).include?(tag) } or next
            held[kind][resource] = held[kind].fetch(resource, 0.0) + p.fetch(:kg)
          end
          held
        end

        def signal(state, planned, ctx)
          return :logs_broken if state[:failure]
          return :logs_stopped if planned.fetch(:turning) < STOPPED_SHARE
          return :short_of_water if state.fetch(:short)
          return (integrity(state) < WORN ? :logs_knocking : :washing) if planned.fetch(:washing) > Parcel::EPSILON

          bin = Parcel.total_kg((ctx.node_state(@bin) || {}).fetch(:parcels, []))
          bin > Parcel::EPSILON ? :waiting_on_hand : :nothing_to_wash
        end
      end

      # **A rock crusher on the line shaft**: a conduit from the bin to the hopper over the washhouse,
      # crushing as fast as its jaws turn — the shaft's speed against its rated speed — and charging
      # the shaft `work_j_per_kg` for every kilogram crushed. It writes **its board** (`signal`), and
      # how hard its jaws are working (`:jaws`) for a peril of whoever feeds them.
      #
      #   state: carried_kg, signal
      class Crusher < Nodes::Conduit
        SIGNALS = {
          stopped: "stopped",
          choked: "choked — the hopper is full",
          waiting_on_feed: "waiting on its feed",
          nothing_to_crush: "nothing to crush",
          crushing: "crushing"
        }.freeze

        # `bin:` what it is fed from, `hopper:` what it crushes into, `feeders:` the post feeding it
        # by hand, if any.
        def initialize(work_j_per_kg:, bin:, hopper:, feeders: nil, perils: [], **opts)
          @work_j_per_kg = work_j_per_kg.to_f
          @bin = bin.to_sym
          @hopper = hopper.to_sym
          @feeders = feeders&.to_sym
          @perils = perils.freeze
          super(**opts)
        end

        attr_reader :work_j_per_kg, :perils

        # What it crushed last tick, priced per kilogram.
        def hydraulic_w(state, ctx)
          ctx.dt.positive? ? state.fetch(:carried_kg, 0.0) / ctx.dt * @work_j_per_kg : 0.0
        end

        def apply(state, ctx, grant)
          applied = super
          applied.merge(signal: SIGNALS.keys.index(signal(applied, ctx)))
        end

        def activity(state, quantity, dt)
          return nil unless quantity == :jaws && dt.positive?

          (state.fetch(:carried_kg, 0.0) / (full_crew_kg_per_s * dt)).clamp(0.0, 1.0)
        end

        private

        def signal(state, ctx)
          return :stopped if displacement_fraction(ctx) < LogWasher::STOPPED_SHARE
          return :crushing if state.fetch(:carried_kg, 0.0) > Parcel::EPSILON

          hopper = ctx.nodes&.[](@hopper)
          return :choked if hopper && hopper.room_m3(ctx.node_state(@hopper), ctx.content) <= 0.0

          bin = Parcel.total_kg((ctx.node_state(@bin) || {}).fetch(:parcels, []))
          bin > Parcel::EPSILON ? :waiting_on_feed : :nothing_to_crush
        end
      end

      # **A pond behind a wall that can fail** — the mud dam, the reservoir. The wall wears by how far
      # the pond stands above its `safe_fill` of what it is built to hold (`capacity_m3`), squared,
      # from the usual hidden strength; whoever is posted to `puddled_by:` puts it back, and rebuilds
      # it breached, which shuts its breach again. **Coming over the top it breaches at once**
      # (`overload?`): a full freeboard is something everybody can see. It writes the wall's
      # **board** (`signal`) — weeping, then slumping, before it goes.
      #
      #   state: parcels, signal, durability, initial_durability, failure
      class Embankment < Nodes::Vessel
        SIGNALS = { sound: "sound", weeping: "weeping at the toe", slumping: "slumping", breached: "breached" }.freeze

        # Integrity under which the toe weeps, and under which the wall slumps.
        WEEPING = 0.5
        SLUMPING = 0.2

        # Past this share of its volume it is coming over the top.
        OVERTOPS = 0.995

        # Durability a man puddling puts back a second.
        HEAL_PER_S = 0.15

        attr_reader :capacity_m3, :safe_fill, :wear_per_s, :puddled_by

        # `freeboard:` is room over `capacity_m3` before it comes over the top, for a reservoir whose
        # spillway holds it at what it is built to hold.
        def initialize(capacity_m3:, safe_fill:, wear_per_s:, puddled_by: nil, freeboard: 0.0, **opts)
          @capacity_m3 = capacity_m3.to_f
          @safe_fill = safe_fill.to_f
          @wear_per_s = wear_per_s.to_f
          @puddled_by = puddled_by&.to_sym
          super(volume_m3: @capacity_m3 * (1.0 + freeboard), **opts)
        end

        def fill(state, content) = contents_volume(state, content) / @capacity_m3

        def stress_per_second(state, ctx)
          over = (fill(state, ctx.content) - @safe_fill) / (1.0 - @safe_fill)
          over.positive? ? (@wear_per_s * (over**2)) + super : super
        end

        def overload?(state, ctx, _integrity) = contents_volume(state, ctx.content) >= OVERTOPS * volume_m3

        def failure_modes = { breached: {} }

        def failure_mode(_state, _ctx, _cause) = :breached

        def failure_detail(state, ctx) = { fill: fill(state, ctx.content).round(3) }

        def apply(state, ctx, grant)
          applied, events = super
          applied = puddle(applied, ctx)
          [ applied.merge(signal: SIGNALS.keys.index(signal(applied))), events ]
        end

        private

        # The wall put back by whoever is puddling it, and whole again, the breach is shut.
        def puddle(state, ctx)
          men = @puddled_by ? [ ctx.controls.fetch(@puddled_by, 0.0) / 100.0, 0.0 ].max : 0.0
          return state unless men.positive?

          whole = state.fetch(:initial_durability)
          made = [ state.fetch(:durability) + (HEAL_PER_S * men * ctx.dt), whole ].min
          state = state.merge(durability: made)
          state[:failure] && made >= whole ? state.merge(failure: nil) : state
        end

        def signal(state)
          return :breached if state[:failure]
          return :slumping if integrity(state) < SLUMPING
          return :weeping if integrity(state) < WEEPING

          :sound
        end
      end

      # **The mud dam**: the washers' slurry settling behind its wall — the clay, the limonite lost with
      # it, and water. The water rises clear above the settled clay, less what the clay keeps in its
      # pores (`PORE_WATER`), and that free water is what a decant can draw off. **It starts part
      # full**, the clay of the seasons before with a little water on it, drawn per match; `ground:`
      # pins it at the median.
      class MudDam < Embankment
        PORE_WATER = 0.6
        STARTING_FILL = (0.2..0.4)
        STARTING_FREE = 0.05

        def initialize(ground: nil, **opts)
          @ground = ground
          super(**opts)
        end

        def free_water_kg(state, content)
          parcels = state.fetch(:parcels, [])
          water = Parcel.total_kg(Parcel.matching(parcels, [ :liquid ], content))
          solids = Parcel.total_kg(Parcel.matching(parcels, [ :solid ], content))
          [ water - (PORE_WATER * solids), 0.0 ].max
        end

        def initial_state(rng, content = nil)
          state = super
          share = @ground ? (STARTING_FILL.begin + STARTING_FILL.end) / 2.0 : rng.between(STARTING_FILL.begin, STARTING_FILL.end)
          clay_m3 = (share - STARTING_FREE) * capacity_m3
          clay = clay_m3 / ((1.0 / content.resource(:clay).fetch(:density_kg_per_m3)) + (PORE_WATER / 1_000.0))
          water = (PORE_WATER * clay) + (STARTING_FREE * capacity_m3 * 1_000.0)
          state.merge(parcels: Parcel.normalise([
            Parcel.build(resource: :clay, kg: clay, temperature_k: initial_temperature_k, content: content),
            Parcel.build(resource: :water, kg: water, temperature_k: initial_temperature_k, content: content)
          ]))
        end
      end

      # **The decant**: a gate on a conduit drawing the mud dam's free water off the top (`from:`)
      # back into the reservoir, and none of the clay or the water it keeps.
      class Decant < Nodes::Conduit
        def initialize(from:, **opts)
          @from = from.to_sym
          super(**opts)
        end

        def throughput_kg(state, ctx)
          dam = ctx.nodes&.[](@from)
          held = ctx.node_state(@from)
          free = dam && held ? dam.free_water_kg(held, ctx.content) : 0.0
          [ super, free ].min
        end
      end

      # **The reservoir the washer and the pumps draw on**, full or nearly so in almost every
      # match. **Exceedingly rarely it is nearly dry** — a dry season — and a pit washing hard runs
      # it out. Drawn once at `initial_state`; `ground:` pins it full. Rain tops it up (5e). Its bank
      # is an `Embankment`'s, held at its crest by the spillway: the small one's so strong no match
      # sees it wear, the larger ones' not.
      class Reservoir < Embankment
        DRY_ODDS = 0.02
        DRY_FILL = (0.02..0.12)
        ORDINARY_FILL = (0.6..1.0)

        def initialize(capacity_kg:, ground: nil, **opts)
          @capacity_kg = capacity_kg.to_f
          @ground = ground
          super(capacity_m3: @capacity_kg / 1_000.0, **opts)
        end

        attr_reader :capacity_kg

        def initial_state(rng, content = nil)
          state = super
          water = Parcel.build(resource: :water, kg: @capacity_kg * starting_fill(rng), temperature_k: initial_temperature_k,
                               content: content)
          state.merge(parcels: [ water ])
        end

        private

        def starting_fill(rng)
          return 1.0 if @ground

          band = rng.float < DRY_ODDS ? DRY_FILL : ORDINARY_FILL
          rng.between(band.begin, band.end)
        end
      end

      # **Over the crest, off to drainage**: a conduit that passes only what its holder (`over:`)
      # holds past `crest_kg`. A reservoir full in most matches would otherwise refuse what is
      # pumped into it, and the pit would flood behind it.
      #
      # TODO: the larger reservoirs' rupture starts here — an overtopped bank. Untested until then.
      class Spillway < Nodes::Conduit
        def initialize(over:, crest_kg:, **opts)
          @over = over.to_sym
          @crest_kg = crest_kg.to_f
          super(**opts)
        end

        attr_reader :over, :crest_kg

        def throughput_kg(state, ctx)
          held = Parcel.total_kg((ctx.node_state(@over) || {}).fetch(:parcels, []))
          [ super, [ held - @crest_kg, 0.0 ].max ].min
        end
      end

      # **The magazine**, whose going up is as big as what was in it (`charge_kg`, for its hazard).
      class Magazine < Nodes::Vessel
        def failure_detail(state, ctx) = super.merge(charge_kg: contents_kg(state).round(3))
      end

      # **Ground coming down**: a conduit that passes what its holder (`from:`) has slipping — a slide
      # off a bench onto its pile, a dump's broken edge into the dump. It comes down in seconds.
      class Slip < Nodes::Conduit
        def initialize(from:, **opts)
          @from = from.to_sym
          super(**opts)
        end

        attr_reader :from

        def throughput_kg(state, ctx) = [ super, (ctx.node_state(@from) || {}).fetch(:slipping_kg, 0.0) ].min
      end

      # **Barring down**: the barmen prising the hanging face off with bars into the muck, a gang rated
      # per man, never more than is hanging (`bench:`'s `overhang_kg`). Its peril scales with how hard
      # they are at it (`:barring`).
      class Barring < Nodes::Conduit
        def initialize(bench:, perils: [], **opts)
          @bench = bench.to_sym
          @perils = perils.freeze
          super(**opts)
        end

        attr_reader :bench, :perils

        def throughput_kg(state, ctx) = [ super, (ctx.node_state(@bench) || {}).fetch(:overhang_kg, 0.0) ].min

        def activity(state, quantity, dt)
          return nil unless quantity == :barring && dt.positive?

          (state.fetch(:carried_kg, 0.0) / (full_crew_kg_per_s * dt)).clamp(0.0, 1.0)
        end
      end

      # **The tip head, and the dump's edge under it.** Every kilogram tipped onto it loads the edge
      # (`edge_load_kg`), more in the rain and on wetter ground (`wetness_from:`, the seepage's drawn
      # `wetness`), and the load settles away with time (`SETTLE_S`). Past a hidden threshold — drawn
      # afresh for every breakback — **the edge breaks back**: whatever is on the tip head goes down
      # `:slump` into the dump, and whoever is on the dump is hurt (`endangers:`, keyed `broke_back`).
      # The dumpmen see the cracks first.
      #
      #   state: parcels, edge_load_kg, thresholds, slipping_kg, signal, durability, failure
      class TipHead < Nodes::Vessel
        SIGNALS = { sound: "sound", cracking: "cracks behind the edge", broken_back: "broken back" }.freeze

        # The edge load a dump holds before it breaks back, the first time more; rain loads each
        # kilogram tipped `WET_LOADS` more; it settles with this time constant; the dumpmen see the
        # cracks past `CRACKS_SEEN` of it.
        EDGE_KG = 60_000.0
        FIRST_EDGE = 1.4
        WET_LOADS = 1.0
        SETTLE_S = 1_800.0
        CRACKS_SEEN = 0.6

        def initialize(wetness_from:, ground: nil, **opts)
          @wetness_from = wetness_from.to_sym
          @ground = ground
          super(**opts)
        end

        attr_reader :wetness_from

        def initial_state(rng, content = nil)
          super.merge(edge_load_kg: 0.0, slipping_kg: 0.0, signal: 0,
                      thresholds: Ground.thresholds(rng, EDGE_KG, first: FIRST_EDGE, pinned: !@ground.nil?))
        end

        def overload?(state, _ctx, _integrity)
          holds = state.fetch(:thresholds, []).first
          !holds.nil? && state.fetch(:edge_load_kg, 0.0) >= holds
        end

        def failure_modes = { broke_back: {} }

        def failure_mode(_state, _ctx, _cause) = :broke_back

        def failure_detail(state, _ctx) = { edge_load_kg: state.fetch(:edge_load_kg, 0.0).round(1) }

        def apply(state, ctx, grant)
          applied, events = super
          tipped = grant.received_kg(:in) * (1.0 + (WET_LOADS * ctx.sky.fetch(:wet, 0.0))) * ground_wetness(ctx)
          load = applied.fetch(:edge_load_kg, 0.0) + tipped - (applied.fetch(:edge_load_kg, 0.0) * ctx.dt / SETTLE_S)
          applied = applied.merge(edge_load_kg: [ load, 0.0 ].max,
                                  slipping_kg: [ applied.fetch(:slipping_kg, 0.0) - grant.sent_kg(:slump), 0.0 ].max)
          applied = break_back(applied) if broken?(applied)
          [ applied.merge(signal: SIGNALS.keys.index(signal(applied))), events ]
        end

        private

        def ground_wetness(ctx) = (ctx.node_state(@wetness_from) || {}).fetch(:wetness, 1.0)

        # Everything on it goes down into the dump, the next threshold is a fresh one, and the edge
        # starts loading again.
        def break_back(state)
          state.merge(slipping_kg: contents_kg(state), edge_load_kg: 0.0, thresholds: state.fetch(:thresholds).drop(1),
                      failure: nil, durability: state.fetch(:initial_durability))
        end

        def signal(state)
          return :broken_back if state.fetch(:slipping_kg).positive?

          holds = state.fetch(:thresholds, []).first
          holds && state.fetch(:edge_load_kg) >= CRACKS_SEEN * holds ? :cracking : :sound
        end
      end

      # **The bottom of the pit, where its water stands.** A hole dug below the ore floor
      # (`hole_kg`); past it the water stands on the ore bench's floor, and `flooding` is how deep
      # against the flood mark (`flood_kg`), knee-deep across the cut. Over `deep_kg` it is over a
      # man's head (`deep?`): anybody there treads water, and spent, goes under.
      #
      # Its peril is stepping off into it over the flood mark (`:over_the_mark`).
      #
      #   state: parcels, standing_kg, over_the_mark
      class Sump < Nodes::Vessel
        def initialize(hole_kg:, flood_kg:, deep_kg:, perils: [], **opts)
          @hole_kg = hole_kg.to_f
          @flood_kg = flood_kg.to_f
          @deep_kg = deep_kg.to_f
          @perils = perils.freeze
          super(**opts)
        end

        attr_reader :hole_kg, :flood_kg, :deep_kg, :perils

        def standing_kg(state, content) = Parcel.total_kg(Parcel.matching(state.fetch(:parcels), [ :liquid ], content))

        def flooding(state, content) = ((standing_kg(state, content) - @hole_kg) / (@flood_kg - @hole_kg)).clamp(0.0, 1.0)

        def deep?(state, content) = standing_kg(state, content) >= @deep_kg

        def apply(state, ctx, grant)
          applied, events = super
          standing = standing_kg(applied, ctx.content)
          over = ((standing - @flood_kg) / (@deep_kg - @flood_kg)).clamp(0.0, 1.0)
          [ applied.merge(standing_kg: standing, over_the_mark: over), events ]
        end

        def activity(state, quantity, _dt) = quantity == :over_the_mark ? state.fetch(:over_the_mark, 0.0) : nil
      end

      # **Seepage from the strata into the sump**: a rate a metre of the ore bench's depth, so a pit
      # getting deeper is getting wetter, by the ground's `wetness` — and every spring the ore face
      # has reached, flowing from then on. Both drawn at `initial_state`; `ground:` pins the median
      # and no springs. Nobody is told.
      #
      #   state: wetness, springs, springs_met
      class Seepage < Nodes::Conduit
        # `bench:` the ore bench, whose depth and face it reads; `from_m:` where its face starts.
        def initialize(bench:, kg_per_s_per_m:, from_m: 0.0, ground: nil, **opts)
          @bench = bench.to_sym
          @kg_per_s_per_m = kg_per_s_per_m.to_f
          @from_m = from_m.to_f
          @ground = ground
          super(**opts)
        end

        attr_reader :bench, :kg_per_s_per_m

        def initial_state(rng, content = nil)
          super.merge(drawn(rng)).merge(springs_met: 0)
        end

        def throughput_kg(state, ctx) = [ super, kg_per_s(state, ctx) * ctx.dt ].min

        def kg_per_s(state, ctx)
          bench = ctx.node_state(@bench) or return 0.0
          met(state, bench).sum { |s| s.fetch(:kg_per_s) } +
            (bench.fetch(:depth_m, 0.0) * @kg_per_s_per_m * state.fetch(:wetness, 1.0))
        end

        def apply(state, ctx, grant)
          bench = ctx.node_state(@bench)
          super.merge(springs_met: bench ? met(state, bench).length : 0)
        end

        private

        def met(state, bench) = state.fetch(:springs, []).select { |s| bench.fetch(:advanced_m, 0.0) >= s.fetch(:at_m) }

        def drawn(rng)
          return { wetness: 1.0, springs: [] } if @ground

          { wetness: Ground.wetness(rng), springs: Ground.springs(rng).map { |s| s.merge(at_m: @from_m + s.fetch(:at_m)) } }
        end
      end

      # **A kiln: washed ore and small coal burnt together**, a vessel hosting `coal_combustion` and
      # `limonite_calcining`, so how much of its ore is finished is decided by nothing but its heat.
      # Its air comes in at the eyes and its gas goes up its throat, drawn by its own heat; short of
      # air its coal burns to monoxide, and it runs cooler for it. What is drawn from it is whatever
      # lies at the bottom, calcined or not.
      #
      # **It starts at work** (`working:`, kilograms of each resource and `kelvin`): charged, at its
      # working heat, its coal alight, and the air in it at the outside pressure.
      #
      # It writes **its board** (`signal`), in the burners' words.
      #
      #   state: parcels, joules, ignition, signal
      class Kiln < Nodes::Vessel
        SIGNALS = {
          empty: "empty — waiting on the chargers",
          cold: "cold — the fire out",
          short_of_air: "burning short of air",
          too_cool: "too cool to burn the ore",
          no_coal: "no coal in the charge",
          burning: "burning well"
        }.freeze

        CALCINING = :limonite_calcining

        # Over this share of its gas by volume as monoxide, the burners call it short of air.
        SHORT_OF_AIR = 0.01

        def initialize(working:, **opts)
          @working = working.freeze
          super(**opts)
        end

        def initial_state(rng, content = nil)
          state = super
          kelvin = @working.fetch(:kelvin)
          air_kg = Units::STANDARD_PRESSURE_PA * volume_m3 * content.resource(:air).fetch(:molar_mass_g_per_mol) /
                   1_000.0 / (Units::GAS_CONSTANT * kelvin)
          held = @working.except(:kelvin).merge(air: air_kg).map do |resource, kg|
            Parcel.build(resource: resource, kg: kg, temperature_k: kelvin, content: content)
          end
          state.merge(parcels: Parcel.normalise(held), joules: heat_capacity * kelvin,
                      ignition: state.fetch(:ignition).merge(coal_combustion: { kg: @working.fetch(:coal, 0.0),
                                                                                oxidiser_kg: 0.0 }),
                      signal: SIGNALS.keys.index(:burning))
        end

        def calcines_k(content) = content.reaction(CALCINING).fetch(:min_temperature_k).to_f

        def apply(state, ctx, grant)
          applied, events = super
          [ applied.merge(signal: SIGNALS.keys.index(signal(applied, ctx.content, grant))), events ]
        end

        private

        def signal(state, content, grant)
          parcels = state.fetch(:parcels, [])
          return :empty if Parcel.total_kg(Parcel.matching(parcels, [ :ore ], content)) <= Parcel::EPSILON

          hot = temperature_k(state, content) >= calcines_k(content)
          alight = state.dig(:ignition, :coal_combustion, :kg).to_f > Parcel::EPSILON
          return :cold unless alight || hot
          return :short_of_air if monoxide_share(parcels, content) > SHORT_OF_AIR
          return :too_cool unless hot
          return :no_coal if grant.received_kg(:ore_in) > Parcel::EPSILON && grant.received_kg(:coal_in) <= Parcel::EPSILON

          :burning
        end

        def monoxide_share(parcels, content)
          gases = Parcel.matching(parcels, [ :gas ], content)
          total = Parcel.total_volume(gases, content)
          return 0.0 unless total.positive?

          Parcel.total_volume(gases.select { |p| p.fetch(:resource) == :whitedamp }, content) / total
        end
      end

      # **Charging a kiln by hand**, a gang rated per man. Its perils scale with how hard it is at it
      # (`:charging`).
      class Charging < Nodes::Conduit
        def initialize(perils: [], **opts)
          @perils = perils.freeze
          super(**opts)
        end

        attr_reader :perils

        def activity(state, quantity, dt)
          return nil unless quantity == :charging && dt.positive?

          (state.fetch(:carried_kg, 0.0) / (full_crew_kg_per_s * dt)).clamp(0.0, 1.0)
        end
      end

      # **The coal laid in with the ore**: as much as the burners' lever says, up to `most_per_kg` a
      # kilogram of what the chargers put in last tick (`with:`). No ore charged, no coal.
      class CoalCharge < Nodes::Conduit
        def initialize(with:, most_per_kg:, **opts)
          @with = with.to_sym
          @most_per_kg = most_per_kg.to_f
          super(**opts)
        end

        attr_reader :with, :most_per_kg

        def throughput_kg(state, ctx)
          ore = (ctx.node_state(@with) || {}).fetch(:carried_kg, 0.0)
          [ super, ore * @most_per_kg * open_fraction(ctx) ].min
        end
      end

      # **Drawing a kiln**: a gang rated per man raking out what lies at the bottom, calcined or not,
      # and the ash with it. Its perils scale with how hard it is at it (`:drawing`), and with how
      # hot what it draws is as well (`:drawing_hot`, `HOT_K` over the outside air at full).
      class Drawing < Nodes::Conduit
        HOT_K = 600.0

        def initialize(kiln:, perils: [], **opts)
          @kiln = kiln.to_sym
          @perils = perils.freeze
          super(**opts)
        end

        attr_reader :kiln, :perils

        def apply(state, ctx, grant)
          node = ctx.nodes&.[](@kiln)
          held = ctx.node_state(@kiln)
          over = node && held ? node.temperature_k(held, ctx.content) - ambient_k : 0.0
          busy = ctx.dt.positive? ? state.fetch(:carried_kg, 0.0) / (full_crew_kg_per_s * ctx.dt) : 0.0
          super.merge(working: busy.clamp(0.0, 1.0), hot: (over / HOT_K).clamp(0.0, 1.0))
        end

        def activity(state, quantity, _dt)
          case quantity
          when :drawing then state.fetch(:working, 0.0)
          when :drawing_hot then state.fetch(:working, 0.0) * state.fetch(:hot, 0.0)
          end
        end
      end

      # **The open air over a kiln's top**, coming across it: a conduit from the outside with a head
      # of its own (`head_pa`, never quite still), and more in a wind, as the wind's pressure on it.
      class Breeze < Nodes::Conduit
        # ½ρv² on air.
        WIND_PA_PER_M2_S2 = 0.6

        def head_pa(ctx) = super + (WIND_PA_PER_M2_S2 * (ctx.sky.fetch(:wind_m_s, 0.0)**2))
      end
    end
  end
end
