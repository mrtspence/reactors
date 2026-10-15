# frozen_string_literal: true

module ReactorSim
  module Operations
    module Mine
      # How deep the shaft is. Every lift in the mine is measured against it, so it lives here
      # rather than being repeated in three fittings that could disagree.
      SHAFT_DEPTH_M = 90.0

      # What every way up and down the shaft runs through: the shaft, choked or jammed, and the
      # pit bottom at its foot, drowned.
      THROUGH_SHAFT = %i[shaft pit_bottom].freeze

      # The district's coal. At a heading's 4.7 t a metre (`Ahead`), about nineteen metres of face.
      SEAM_KG = 90_000.0

      # What the line shaft turns at when the supply is healthy. Driven fittings are rated
      # against it, so a fitting's declared duty means "at working speed" rather than "always".
      WORKING_OMEGA = 22.0

      # **How long a lever takes to travel, in percent of its range per second**, before whoever
      # is working it is taken into account — `Minion#rate_multiplier` scales these, so a strong
      # hand moves a shutter faster than a spent one.
      #
      # Only things somebody physically moves get a figure. `Float::INFINITY` stays right for a
      # posting, for a margin set before the shift, and for every **effort** station: there the
      # lever is intent and `capability` already supplies the rate, so a finite travel would
      # charge the same minion twice and let a kobold eventually equal an ogre.
      module Travel
        QUICK = 20.0  # a clutch, thrown in about five seconds
        STEADY = 8.0  # a winding regulator under a skilled engineman — twelve seconds hard over
        HEAVY = 2.5   # a fan shutter or a pump throttle: forty seconds, and you feel every one
        SCONCES = 2.0 # lighting a district one candle at a time, near enough a minute
      end

      # **The three rooms, and which machinery is in each.** A node's place is what decides who a
      # failure reaches: everybody in the district is in the district when it goes up, whatever
      # they were posted to and whether they were posted to anything at all.
      #
      # What is deliberately placeless is as load-bearing as what is placed. The seam is coal in
      # the ground and the strata is the water behind it — **rock is not a room**, and neither is
      # the dust still in the seam.
      #
      # **The shafts and roads are conduits *between* rooms and belong to neither**, which is the
      # rule that decides the haulage road: it runs from the face to the pit bottom, so a fall in
      # it reaches both and is in neither. Putting it in the district instead made the roof miss
      # the putter, who is the person it was most likely to kill. The day somebody should stand
      # in a roadway, it becomes a place of its own rather than joining one of these.
      #
      # A fitting places what it installs, so the truth is the assembled layout rather than this
      # list:
      #
      #     ruby -Ilib -e 'require "reactor_sim"
      #       op = ReactorSim::Operations::Mine.build(id: "m", seed: 1)
      #       puts op.nodes.keys.reject { |n| op.layout.place_of_node(n) }.inspect'
      PLACES = [
        Place.new(id: :bank, label: "Pit Bank",
                  nodes: %i[atmosphere screens line_shaft upcast drainage dust_store]),
        Place.new(id: :pit_bottom, label: "Pit Bottom", nodes: %i[pit_bottom pump]),
        Place.new(id: :district, label: "The District",
                  nodes: %i[district pick_line dust_line blower])
      ].freeze

      # ---------------------------------------------------------------- winding

      # **The hoist winds men and coal alike**: a drum and two balanced cages — or kibbles — off
      # the line shaft, coal on the deck, men in it. One engineman works it, certificated, to
      # wherever the player names or, with `coal_winding` on, shuttling coal and taking men first.
      #
      # **Four tiers.** The steam whim's kibble is a bucket on a rope: small, slow, unguided, and
      # ridden by men standing in it at their peril. The cages are guided and quick, and what each
      # buys over the last is what an overwind ends as: through the sheaves, hung in the catch
      # plate by King's detaching hook (1867), or stopped short by a trip — which is only as good as
      # the brake. Hooked and tripped cages carry safety catches for a parted rope.
      HOISTS = {
        steam_whim: { label: "Steam Whim", kibble: true, hook: false, trip: false,
                      speed_m_s: 2.0, brake_nm: 12_000.0, deck_kg: 300.0, rated_kg: 220.0,
                      cage_kg: 300.0,
                      description: "A drum, a rope and a kibble. Men ride it standing in the bucket." },
        cage_gear: { label: "Cage", kibble: false, hook: false, trip: false,
                     speed_m_s: 4.2, brake_nm: 30_000.0, deck_kg: 1_000.0, rated_kg: 420.0,
                     cage_kg: 1_500.0,
                     description: "Guided cage on a rope. Quick, and nothing to stop an overwind." },
        hooked_cage: { label: "Cage, Detaching Hook", kibble: false, hook: true, trip: false,
                       speed_m_s: 4.2, brake_nm: 30_000.0, deck_kg: 1_000.0, rated_kg: 420.0,
                       cage_kg: 1_500.0,
                       description: "King's hook: an overwind hangs the cage in the headframe." },
        tripped_cage: { label: "Cage, Hook and Trip", kibble: false, hook: true, trip: true,
                        speed_m_s: 4.2, brake_nm: 30_000.0, deck_kg: 1_000.0, rated_kg: 420.0,
                        cage_kg: 1_500.0,
                        description: "The hook, and a trip that throws the brake on past the marks." }
      }.freeze

      HOISTS.each do |id, tier|
        Parts.register(id, kind: :winder, label: tier.fetch(:label),
                           description: tier.fetch(:description),
                           provides: %i[cage_drive cage_deck],
                           instruments: %i[coal_raised cage_depth slack_rope winding_brake brake_heat
                                           sheave_heat],
                           stats: tier.except(:label, :description)) do |spec|
          Mine.hoist_fragment(tier: tier, spec: spec)
        end
      end

      # ---------------------------------------------------------------- winning

      # **Hand picks are the bottom of the tree and the thing every other tier is measured
      # against.** A hewer lying on his side with a short-handled pick, which is how nearly all
      # of it was got for nearly all of the period.
      Parts.register(:hand_picks, kind: :cutting, label: "Hand Picks",
                     description: "Short-handled picks and wedges. A hewer and his own back.",
                     provides: %i[pick_line],
                     stats: { max_kg_per_s: 1.4 }) do |_spec|
        Mine.cutting_fragment(max_kg_per_s: 1.4, exertion: 1.2e-3)
      end

      # Gillott & Copley's 1868 disc cutter and its descendants: a machine that undercuts the
      # seam so the coal comes down under its own weight. Four times the coal, and **it does not
      # tire**, which is the part that actually changes the shift — a hewer is spent in twenty
      # minutes and a cutter is not.
      Parts.register(:coal_cutter, kind: :cutting, label: "Coal Cutter",
                     description: "A rail-mounted disc that undercuts the seam. Loud, and tireless.",
                     provides: %i[pick_line],
                     stats: { max_kg_per_s: 5.6 }) do |_spec|
        # And its picks strike sparks off the seam while it cuts.
        Mine.cutting_fragment(max_kg_per_s: 5.6, exertion: 3.0e-4, sparks: Mine::CUTTER_SPARKS)
      end

      def self.cutting_fragment(max_kg_per_s:, exertion:, sparks: nil)
        Fragment.new(
          nodes: [ Mine.pick_line(max_kg_per_s: max_kg_per_s, sparks: sparks) ],
          links: [
            Link.new(from: [ :seam, :out ], to: [ :pick_line, :inlet ]),
            Link.new(from: [ :pick_line, :outlet ], to: [ :district, :coal_in ])
          ],
          control_points: [
            # Gated, not merely aided: an ogre with no pick gets no coal out of a seam however
            # strong they are, and nobody gets any in the dark.
            ControlPoint.new(id: :hewing, label: "Hewing", node: :pick_line, default: 0.0,
                             place: :district,
                             # `swing`, not `force`: a pick is a tool at the end of an arm, so
                             # bulk stops paying in proportion and an ogre is about twice a man
                             # rather than four times. A scaled-up pick is the upgrade.
                             effort: { swing: 0.7, dexterity: 0.3 },
                             gated_by: %i[mining_effectiveness darkvision],
                             exertion: exertion)
          ]
        )
      end

      # ---------------------------------------------------------------- man riding

      # **Its own slot, because a man engine winds no coal at all**, and a colliery that bought one
      # bought it precisely so that shift change would stop costing it winding time. Optional: with
      # nothing fitted there are still the hoist and the ladders.

      # A reciprocating rod down the shaft with steps on it: you ride twelve feet, step off onto
      # a sollar, wait, and step on again. Slower than a cage and far cheaper to turn — at
      # Tresavean it cut the journey from an hour to twenty-four minutes and put a fifth on the
      # shift's output.
      #
      # **Two tiers, and what the second buys is catches on the rod** — which hold a rod whose strap
      # wore through and do nothing for one torn out by an overspeed, because the same breakage
      # knocks them out of line (Levant, 1919).
      Parts.register(:man_engine, kind: :manriding, label: "Man Engine",
                     description: "Stepped rods and sollars. You ride it twelve feet at a time.",
                     provides: %i[man_engine], instruments: %i[rod_speed],
                     stats: { speed_m_s: 1.8, max_torque: 520.0, catches: false }) do |spec|
        Mine.manriding_fragment(speed_m_s: 1.8, max_torque: 520.0, label: "Man Engine",
                                catches: false, spec: spec)
      end

      Parts.register(:caught_man_engine, kind: :manriding, label: "Man Engine, Rod Catches",
                     description: "The same rods, with catches to hold them if the strap goes.",
                     provides: %i[man_engine], instruments: %i[rod_speed],
                     stats: { speed_m_s: 1.8, max_torque: 520.0, catches: true }) do |spec|
        Mine.manriding_fragment(speed_m_s: 1.8, max_torque: 520.0, label: "Man Engine",
                                catches: true, spec: spec)
      end

      # **Who a falling rod hurts.** Everybody on it falls with it — unless catches hold a rod
      # whose strap wore through, when it drops a foot and stops.
      ROD_FALL = { tags: %i[fall crush], riders: { man_engine: 3.0 } }.freeze
      ROD_CAUGHT = { tags: %i[impact], riders: { man_engine: 0.4 } }.freeze

      def self.rod_hazards(catches)
        { parted: catches ? ROD_CAUGHT : ROD_FALL, torn_out: ROD_FALL }
      end

      # **The hoist: a drum and two balanced cages, wound by an engineman.** The player names where
      # cage A goes (`man_winding`, percent of the shaft from bank), or turns `coal_winding` on and
      # lets him shuttle; he works a forward clutch, a reversing clutch and the brake to get there,
      # and with nobody at the post they hold where they were left. The drum hangs off the line
      # shaft through both clutches, so a laden cage running down drives the shaft back.
      CAGE_DRUM_RADIUS_M = 1.5

      # Where the trip throws the brake on: a little past either landing.
      TRIP_MARKS_M = [ -1.0, SHAFT_DEPTH_M + 1.0 ].freeze

      # **Who an end of the shaft hurts**, by what they are riding: hung in the catch plate is a
      # jolt, the baulks at the bottom are as bad as the speed, and through the sheaves is a fall.
      # Wreckage from the headframe goes down the shaft and reaches the bank too.
      CAGE_HAZARDS = {
        caught: { tags: %i[impact], scales_with: :speed_m_s, reference: 4.0,
                  riders: { cage_drive: 0.6 } },
        crashed: { tags: %i[impact], scales_with: :speed_m_s, reference: 4.0,
                   riders: { cage_drive: 2.6 } },
        overwound: { tags: %i[fall impact], riders: { cage_drive: 3.4 }, places: { bank: 0.3 } }
      }.freeze

      # **A parted rope drops the cage**, and what happens next is whether it has catches. Without
      # them it falls to the sump and takes the shaft's guides with it; with them it is a jolt.
      # Hooked and tripped cages carry catches, which is what the tier buys besides the hook.
      ROPE_HAZARDS = {
        parted: { tags: %i[fall impact], riders: { cage_drive: 3.4 } },
        parted_held: { tags: %i[impact], riders: { cage_drive: 0.5 } }
      }.freeze

      # **The winding rope, and what it is made of.** Flat hemp first; wrought-iron wire from the
      # 1840s; steel wire from the 1870s. A ~40 mm rope of each: hemp is light, stretchy — so a
      # snatch is softer — weak, and rots in a wet shaft; iron is four times as strong and five times
      # the weight; steel is stronger again, stiffest, and rusts least. Cheaper rope is likelier to
      # part, and the drum lifts its weight.
      ROPES = {
        hemp_rope: { label: "Hemp Rope", breaking_kn: 110.0, kg_per_m: 1.1, stiffness_n_per_m: 8.0e4,
                     corrode_per_s: 0.06, bend_per_m: 0.025,
                     description: "Flat hemp. Light and cheap, and it rots in a wet shaft." },
        iron_wire_rope: { label: "Iron Wire Rope", breaking_kn: 400.0, kg_per_m: 5.5,
                          stiffness_n_per_m: 6.5e5, corrode_per_s: 0.03, bend_per_m: 0.025,
                          description: "Wrought-iron wire, laid. Strong, heavy, and it rusts." },
        steel_wire_rope: { label: "Steel Wire Rope", breaking_kn: 1_000.0, kg_per_m: 5.8,
                           stiffness_n_per_m: 8.0e5, corrode_per_s: 0.02, bend_per_m: 0.02,
                           description: "Plough-steel wire. The strongest rope there is." }
      }.freeze

      ROPES.each do |id, tier|
        Parts.register(id, kind: :rope, label: tier.fetch(:label), description: tier.fetch(:description),
                           provides: %i[winding_rope], instruments: %i[rope_condition],
                           stats: tier.except(:label, :description)) do |_spec|
          Mine.rope_fragment(tier: tier)
        end
      end

      # The rope, and the two jobs at bank that keep it: recapping and re-roping.
      def self.rope_fragment(tier:)
        Fragment.new(
          nodes: [ Mine.winding_rope(tier: tier) ],
          places: [ Place.new(id: :bank, nodes: [ :winding_rope ]) ],
          control_points: [
            # Only with the cage stopped at bank — cutting and re-socketing the capel.
            ControlPoint.new(id: :recapping, label: "Recapping", node: :winding_rope, default: 100.0,
                             place: :bank, effort: { dexterity: 0.7, force: 0.3 },
                             exertion: 6.0e-4),
            # A long, heavy job, and only with a spare rope in store.
            ControlPoint.new(id: :reroping, label: "Re-roping", node: :winding_rope, default: 100.0,
                             place: :bank, effort: { force: 0.6, dexterity: 0.4 },
                             exertion: 9.0e-4)
          ]
        )
      end

      # **Riding the kibble**: standing in an unguided bucket that swings and catches the shaft
      # side, worse the faster it is wound. What the cage buys besides speed.
      RIDING_THE_KIBBLE = Peril.new(id: :riding_the_kibble, tags: %i[fall impact], severity: 1.8,
                                    rate: 0.5, scales_with: :swing, riders: %i[cage_drive])

      # Wound away while somebody is still getting in: caught between the deck and the shaft side.
      CAUGHT_BOARDING = { tags: %i[crush], severity: 2.0 }.freeze

      # **The marshals' posts take some knowing**: a hand out of their depth slips, and a marshal
      # slipping rings a false ready.
      MARSHAL_COMPLEXITY = 0.7

      # Without catches a parted rope takes the cage down the shaft, and the shaft's guides with it.
      def self.winding_rope(tier:)
        Nodes::Rope.new(id: :winding_rope, label: tier.fetch(:label), hoist: :cage_drive,
                        **tier.slice(:breaking_kn, :kg_per_m, :stiffness_n_per_m, :corrode_per_s,
                                     :bend_per_m),
                        sheave: :sheave, wet_by: :seepage, recap_control: :recapping,
                        renew_control: :reroping, spare: :spare_rope,
                        endangers: ROPE_HAZARDS, damages: { parted: { shaft: 0.4 } })
      end

      # The two sheave wheels' own weight on the journal.
      SHEAVE_WHEELS_KG = 1_500.0

      # Rope dragged through a seized sheave's iron groove, as a share of the √2 pull the journal
      # feels: rope on iron at μ 0.25 over a quarter-turn holds back `e^(0.25·π/2) − 1` ≈ 0.48 of
      # each side's tension (the capstan law), and 0.48 ÷ √2 ≈ 0.34.
      GROOVE_MU = 0.34

      # **The headgear pulley**, a plain journal under both ropes. Its oil is what keeps it cool,
      # and a hot sheave scores the rope running over it. **Seized, the engine winds on and the rope
      # drags through the dead wheel's groove** — a brake on the winding, heating the sheave and
      # scoring the rope, which is how a headgear catches fire.
      #
      # **Its load is what the ropes pull on it**, read off the rope (`loaded_by:`) — both cages,
      # whatever is in cage A and both ropes' own weight — on top of its own wheels. So a laden wind
      # heats it more than an empty one.
      def self.sheave
        Nodes::Bearing.new(
          id: :sheave, label: "Sheave", supports: :cage_drive, duty: :journal, material: :babbitt,
          # Up in the headframe in still air, so it holds its heat: run dry through a long spell
          # of winding it climbs past the point where it scores the rope.
          heat_capacity: 3.0e3, ambient_conductance: 4.5,
          static_load_n: SHEAVE_WHEELS_KG * Units::GRAVITY_M_PER_S2, loaded_by: :winding_rope,
          slips_when_seized: { mu: GROOVE_MU, lever_m: CAGE_DRUM_RADIUS_M },
          journal_radius_m: 0.15, film_speed_m_s: 0.1, oil_charge_kg: 0.6,
          stress_rate: 200.0, wear_rate: 1.0e-6, oil_loss_kg_per_m: 1.0e-3,
          damages: { seized: { winding_rope: 0.3 } }
        )
      end

      def self.sheave_grease
        Nodes::Vessel.new(
          id: :sheave_grease, label: "Sheave Grease", volume_m3: 0.05,
          initial_contents: [ { resource: :bearing_oil, kg: 30.0 } ], ambient_conductance: 6.0,
          ports: [ Port.new(id: :out, direction: :outlet, accepts: [ :lubricant ],
                            max_kg_per_s: 0.2) ]
        )
      end

      def self.sheave_oil_line
        Nodes::Conduit.new(id: :sheave_oil_line, label: "Sheave Oil Line", accepts: [ :lubricant ],
                           max_kg_per_s: 0.03, heat_capacity: 40.0, ambient_conductance: 0.0,
                           control_id: :greasing)
      end

      # Tubs on or off the deck, kg/s, at either landing: a couple of tubs a minute.
      LANDING_KG_PER_S = 12.0

      def self.hoist_fragment(tier:, spec:)
        speed_m_s = tier.fetch(:speed_m_s)
        hook = tier.fetch(:hook)
        kibble = tier.fetch(:kibble)
        gear = speed_m_s / (CAGE_DRUM_RADIUS_M * WORKING_OMEGA)
        winding = Winding.new(hoist: :cage_drive, forward: :cage_forward, reverse: :cage_reverse,
                              brake_release: :cage_brake_release, shuttle: :coal_winding,
                              deck: :cage_deck, deck_full_kg: tier.fetch(:deck_kg) * 0.95,
                              coal_from: :pit_bottom)
        # Iron through the headframe goes down the shaft: it chokes it, and in a single shaft it
        # takes the brattice with it.
        wreckage = { shaft: 0.6 }.merge(spec[:single_shaft] ? { brattice: 0.5 } : {})

        Fragment.new(
          nodes: [
            Nodes::Hoist.new(id: :cage_drive, label: kibble ? "Whim Drum" : "Cage Drum",
                             moment_of_inertia: 4_000.0, radius_m: CAGE_DRUM_RADIUS_M,
                             depth_m: SHAFT_DEPTH_M, friction: 20.0,
                             detaching_hook: hook, endangers: CAGE_HAZARDS,
                             damages: { overwound: wreckage }, rope: :winding_rope, shaft: :shaft,
                             deck: :cage_deck, boarding_hazard: CAUGHT_BOARDING,
                             rated_speed_m_s: speed_m_s, perils: kibble ? [ RIDING_THE_KIBBLE ] : [],
                             cage_kg: tier.fetch(:cage_kg), catches: hook),
            Nodes::Brake.new(id: :cage_brake, label: "Winding Brake", supports: :cage_drive,
                             capacity_nm: tier.fetch(:brake_nm), heat_capacity: 5.0e4,
                             control_id: :cage_brake_release,
                             trip: (TRIP_MARKS_M if tier.fetch(:trip))),
            Mine.sheave, Mine.sheave_grease, Mine.sheave_oil_line,
            Mine.cage_deck(capacity_kg: tier.fetch(:deck_kg)),
            Mine.deck_loading(max_kg_per_s: LANDING_KG_PER_S),
            Mine.deck_unloading(max_kg_per_s: LANDING_KG_PER_S)
          ],
          links: [
            Link.new(from: [ :sheave_grease, :out ], to: [ :sheave_oil_line, :inlet ]),
            Link.new(from: [ :sheave_oil_line, :outlet ], to: [ :sheave, :oil_in ]),
            Link.new(from: [ :pit_bottom, :coal_out ], to: [ :deck_loading, :inlet ]),
            Link.new(from: [ :deck_loading, :outlet ], to: [ :cage_deck, :coal_in ]),
            Link.new(from: [ :cage_deck, :coal_out ], to: [ :deck_unloading, :inlet ]),
            Link.new(from: [ :deck_unloading, :outlet ], to: [ :screens, :in ])
          ],
          # **Stiff enough to lift a full deck**: a clutch carries torque only as stiffness × slip,
          # and a tonne of coal is 14 kN·m at the drum, so at 4×10³ the slip it needed was more
          # than the drum's whole rated speed and a laden cage ran backwards into the sump.
          drive_links: [
            DriveLink.new(id: :forward_gear, a: :line_shaft, b: :cage_drive, stiffness: 3.0e4,
                          ratio: gear, control_id: :cage_forward, cut_by: :cage_brake),
            DriveLink.new(id: :reverse_gear, a: :line_shaft, b: :cage_drive, stiffness: 3.0e4,
                          ratio: -gear, control_id: :cage_reverse, cut_by: :cage_brake)
          ],
          passages: [ Passage.new(a: :bank, b: :pit_bottom, metres: SHAFT_DEPTH_M,
                                  speed_m_s: speed_m_s, hoist: :cage_drive,
                                  staffed_by: :man_winding, driven_by: :line_shaft,
                                  rated_omega: WORKING_OMEGA, through: Mine::THROUGH_SHAFT,
                                  label: kibble ? "Kibble" : "Cage",
                                  rated_kg: tier.fetch(:rated_kg),
                                  marshals: { bank: :banking, pit_bottom: :onsetting }) ],
          places: [ Place.new(id: :bank, nodes: %i[cage_drive cage_brake sheave sheave_grease
                                                   deck_unloading]),
                    Place.new(id: :pit_bottom, nodes: [ :deck_loading ]) ],
          control_points: [
            # **The post that takes knowing how**: overwinding is how you put a cage through the
            # headgear. A destination, so it moves the moment it is set — the engineman is what
            # takes time.
            ControlPoint.new(id: :man_winding, label: "Winding", node: :cage_drive,
                             default: 0.0, place: :bank, complexity: 1.1, requires: :certificated,
                             governor: winding),
            # On, and the engineman runs the shaft himself: men first, coal otherwise.
            ControlPoint.new(id: :coal_winding, label: "Wind Coal", node: :cage_drive,
                             default: 0.0, place: :bank),
            # **The banksman**, who runs the tubs off the deck at the top of the shaft and stops the
            # cage being loaded past its rating there. A clumsy one lets a tub into the shaft.
            ControlPoint.new(id: :banking, label: "Banksman", node: :deck_unloading, default: 100.0,
                             place: :bank, effort: { force: 0.5, dexterity: 0.5 },
                             exertion: 4.0e-4, complexity: MARSHAL_COMPLEXITY),
            ControlPoint.new(id: :cage_forward, label: "Lowering Clutch", node: :cage_drive,
                             place: :bank, internal: true),
            ControlPoint.new(id: :cage_reverse, label: "Raising Clutch", node: :cage_drive,
                             place: :bank, internal: true),
            ControlPoint.new(id: :cage_brake_release, label: "Winding Brake", node: :cage_brake,
                             place: :bank, internal: true),
            # **A job at the headgear that raises nothing**, and with recapping and re-roping it is
            # what the rope's life is. Posted is working: like the banksman, full effort by default.
            ControlPoint.new(id: :greasing, label: "Greasing the Sheave", node: :sheave_oil_line,
                             default: 100.0, place: :bank,
                             effort: { dexterity: 0.6, intelligence: 0.4 },
                             aided_by: :oiling, exertion: 3.7e-4),
            # **The onsetter**, the banksman's opposite number at the pit bottom: he runs the full
            # tubs on, and stops the cage being loaded past its rating there.
            ControlPoint.new(id: :onsetting, label: "Onsetter", node: :deck_loading, default: 100.0,
                             place: :pit_bottom, effort: { force: 0.5, dexterity: 0.5 },
                             exertion: 4.0e-4, complexity: MARSHAL_COMPLEXITY)
          ]
        )
      end

      # **The headframe**: pitch pine to start, and an iron one that will not burn. The timber it
      # counts is the upper frame and the sheave platform, which is what a hot sheave sets alight.
      HEADFRAMES = {
        timber_headframe: { label: "Timber Headframe", timber_kg: 4_000.0,
                            description: "Pitch-pine legs and a sheave platform. It burns." },
        iron_headframe: { label: "Iron Headframe", timber_kg: 0.0,
                          description: "Riveted wrought iron. Nothing in it to catch." }
      }.freeze

      HEADFRAMES.each do |id, tier|
        Parts.register(id, kind: :headframe, label: tier.fetch(:label),
                           description: tier.fetch(:description), provides: %i[headframe],
                           stats: tier.slice(:timber_kg)) do |_spec|
          Mine.headframe_fragment(timber_kg: tier.fetch(:timber_kg))
        end
      end

      # In parallel with the downcast, whatever it is made of, so changing the frame never changes
      # the pit's air.
      def self.headframe_fragment(timber_kg:)
        Fragment.new(
          nodes: [ Mine.headframe(timber_kg: timber_kg), Mine.headframe_draught, Mine.headframe_smoke ],
          links: [ Link.new(from: [ :atmosphere, :intake ], to: [ :headframe_draught, :inlet ]),
                   Link.new(from: [ :headframe_draught, :outlet ], to: [ :headframe, :air_in ]),
                   Link.new(from: [ :headframe, :smoke_out ], to: [ :headframe_smoke, :inlet ]),
                   Link.new(from: [ :headframe_smoke, :outlet ], to: [ :pit_bottom, :smoke_in ]) ],
          thermal_links: [ ThermalLink.new(a: :sheave, b: :headframe, conductance: 2.0) ]
        )
      end

      # **The shaft signals.** Every pit has a bell; what the upgrade buys is one that does not spark
      # in the pit bottom's air.
      Parts.register(:electric_bells, kind: :signals, label: "Electric Bells",
                     description: "Battery bells on a bare wire. They spark every time they ring.",
                     provides: %i[signal_bell], stats: { sparks: true }) do |_spec|
        Fragment.new(nodes: [ Mine.signal_bell(spark: Mine::BELL_SPARK, label: "Electric Bells") ],
                     places: [ Place.new(id: :pit_bottom, nodes: [ :signal_bell ]) ])
      end

      Parts.register(:flameproof_bells, kind: :signals, label: "Flameproof Bells",
                     description: "The same bells, the contacts sealed in a cast case.",
                     provides: %i[signal_bell], stats: { sparks: false }) do |_spec|
        Fragment.new(nodes: [ Mine.signal_bell(spark: nil, label: "Flameproof Bells") ],
                     places: [ Place.new(id: :pit_bottom, nodes: [ :signal_bell ]) ])
      end

      # **Gates across the shaft at bank.** Bought down rather than removed: a gate somebody has
      # left open stops nothing, so how much it saves depends on whoever is at the bank seeing to
      # it.
      Parts.register(:shaft_gates, kind: :shaft_gates, label: "Shaft Gates",
                     description: "Swing gates at the shaft top. They work when they are shut.",
                     provides: %i[shaft_gates], stats: { effectiveness: 0.7 }) do |_spec|
        Fragment.new(nodes: [ Mine.shaft_gates(effectiveness: 0.7, label: "Shaft Gates") ],
                     places: [ Place.new(id: :bank, nodes: [ :shaft_gates ]) ])
      end

      # **An overspeed trip on the line shaft**: past its setting it throws the clutch out, which
      # saves the fan, the pump and the lamps from a surge — and sheds the whole mine at once, a load
      # rejection that runs the engine house away harder. Both halves are the point.
      Parts.register(:overspeed_trip, kind: :overspeed_trip, label: "Overspeed Trip",
                     description: "A flyball trip on the line shaft. Saves the plant; drops the load.",
                     provides: %i[overspeed_trip], stats: { trip_ratio: 1.25 }) do |_spec|
        Fragment.new(nodes: [ Mine::OverspeedTrip.new(id: :overspeed_trip, label: "Overspeed Trip",
                                                      trip_ratio: 1.25) ],
                     places: [ Place.new(id: :bank, nodes: [ :overspeed_trip ]) ])
      end

      # **Reliability, and nothing else.** A coil of new rope in the store wins no coal and shows on
      # no gauge until the day the rope parts; then it is the difference between re-roping and a
      # shaft out of service for the rest of the match.
      Parts.register(:spare_rope, kind: :spare_rope, label: "Spare Rope",
                     description: "A new winding rope, coiled in the store against the day.",
                     provides: %i[spare_rope], stats: {}) do |_spec|
        Fragment.new(nodes: [ Nodes::SpareRope.new(id: :spare_rope, label: "Spare Rope",
                                                   rope: :winding_rope) ],
                     places: [ Place.new(id: :bank, nodes: [ :spare_rope ]) ])
      end

      def self.manriding_fragment(speed_m_s:, max_torque:, label:, catches:, spec:)
        # A rod down the shaft wrecks it whichever way it went; in a single shaft the brattice too.
        wreckage = { shaft: 0.6 }.merge(spec[:single_shaft] ? { brattice: 0.5 } : {})

        Fragment.new(
          nodes: [ Mine.man_engine(max_torque: max_torque, rated_omega: WORKING_OMEGA,
                                   endangers: rod_hazards(catches),
                                   damages: { parted: wreckage, torn_out: wreckage }) ],
          drive_links: [ DriveLink.new(a: :line_shaft, b: :man_engine, stiffness: 2.2e3) ],
          passages: [ Mine.rod_passage(speed_m_s: speed_m_s, rated_omega: WORKING_OMEGA,
                                       label: label) ],
          # The gear it brings stands at bank. A fitting names only what it installs; the room
          # is the chassis's and the two declarations are unioned.
          places: [ Place.new(id: :bank, nodes: [ :man_engine ]) ],
          control_points: [
            ControlPoint.new(id: :rods, label: "Man Engine", node: :man_engine,
                             default: 0.0, place: :bank, stiffness: Travel::STEADY)
          ]
        )
      end

      # ---------------------------------------------------------------- ventilation

      Parts.register(:waddle_fan, kind: :fan, label: "Waddle Fan",
                     description: "Open-running, no casing. Cheap, and it shows.",
                     provides: %i[upcast], instruments: %i[air_quantity],
                     stats: { head_pa: 2_200.0 }) do |spec|
        Mine.fan_fragment(head_pa: 2_200.0, spec: spec)
      end

      Parts.register(:guibal_fan, kind: :fan, label: "Guibal Fan",
                     description: "Spiral casing, shuttered discharge, evasee chimney.",
                     provides: %i[upcast], instruments: %i[air_quantity],
                     stats: { head_pa: 5_200.0 }) do |spec|
        Mine.fan_fragment(head_pa: 5_200.0, spec: spec)
      end

      # A Guibal with reversing doors in its drift: the same fan, and a lever that turns the whole
      # circuit round — the textbook answer to a fire on the intake.
      Parts.register(:reversible_fan, kind: :fan, label: "Reversible Fan",
                     description: "A Guibal with reversing doors. It can blow the pit backwards.",
                     provides: %i[upcast], instruments: %i[air_quantity],
                     stats: { head_pa: 5_200.0, reversible: true }) do |spec|
        Mine.fan_fragment(head_pa: 5_200.0, spec: spec, reversible: true)
      end

      # In a single-shaft pit the return comes up the upcast compartment, by way of its foot, where
      # the brattice leaks into it; with two shafts it goes straight to the fan.
      def self.fan_fragment(head_pa:, spec:, reversible: false)
        return_side = if spec[:single_shaft]
          [ Link.new(from: [ :return_road, :outlet ], to: [ :upcast_foot, :air_in ]),
            Link.new(from: [ :upcast_foot, :air_out ], to: [ :upcast, :inlet ]) ]
        else
          [ Link.new(from: [ :return_road, :outlet ], to: [ :upcast, :inlet ]) ]
        end

        Fragment.new(
          nodes: [ Mine.upcast(head_pa: head_pa, rated_omega: WORKING_OMEGA, reversible: reversible) ],
          links: [
            Link.new(from: [ :district, :air_out ], to: [ :return_road, :inlet ]),
            *return_side,
            Link.new(from: [ :upcast, :outlet ], to: [ :atmosphere, :exhaust ])
          ],
          control_points: [
            ControlPoint.new(id: :ventilation, label: "Fan", node: :upcast, default: 100.0,
                             place: :bank, stiffness: Travel::HEAVY),
            # Swinging the reversing doors over: past half-way it blows the other way.
            *([ ControlPoint.new(id: :fan_reversed, label: "Reverse the Fan", node: :upcast,
                                 default: 0.0, place: :bank, stiffness: Travel::HEAVY) ] if reversible)
          ]
        )
      end

      # ---------------------------------------------------------------- the haulage door

      # **The door every pit has, and what the tier buys is who shuts it.** A plain door needs a
      # trapper or it stands open behind the last tub. A self-closing door shuts itself on its
      # weight. An air lock is two of them, so the way is open only when both are at once.
      DOORS = {
        plain_door: { label: "Trap Door", self_closing_per_s: 0.0, doors: 1,
                      description: "A canvas-faced door across the road. Somebody has to shut it." },
        self_closing_door: { label: "Self-Closing Door", self_closing_per_s: 0.6, doors: 1,
                             description: "Hung on a slant, so it swings shut on its own weight." },
        air_lock: { label: "Air Lock", self_closing_per_s: 0.6, doors: 2,
                    description: "Two self-closing doors a tub's length apart." }
      }.freeze

      DOORS.each do |id, tier|
        Parts.register(id, kind: :door, label: tier.fetch(:label), description: tier.fetch(:description),
                           provides: %i[door], stats: tier.slice(:self_closing_per_s, :doors)) do |_spec|
          Mine.door_fragment(**tier.slice(:label, :self_closing_per_s, :doors))
        end
      end

      def self.door_fragment(label:, self_closing_per_s:, doors:)
        Fragment.new(
          nodes: [ Mine.door(label: label, self_closing_per_s: self_closing_per_s, doors: doors) ],
          links: [ Link.new(from: [ :pit_bottom, :door_out ], to: [ :door, :inlet ]),
                   Link.new(from: [ :door, :outlet ], to: [ :return_road, :inlet ]) ],
          places: [ Place.new(id: :pit_bottom, nodes: [ :door ]) ],
          control_points: [
            # **The trapper**, and the job nobody needs to be strong for: light, sitting work by the
            # door in the dark. Small hands are better at it (`diminutive`), which is how a pit came
            # to give it to its children — the incentive is the node's, not an archetype's.
            ControlPoint.new(id: :trapping, label: "Trapper", node: :door, default: 100.0,
                             place: :pit_bottom, effort: { dexterity: 0.6, intelligence: 0.4 },
                             aided_by: :diminutive, exertion: 2.0e-4)
          ]
        )
      end

      # ---------------------------------------------------------------- the brattice

      # **How much a sound brattice leaks is the tier**, and nothing else differs in this pass.
      # What each does when it comes down — canvas barely obstructs, concrete is devastating — and
      # in a fire — creosote is a fire load — is deferred to the last pass of the mine accidents.
      # TODO: brattice hazards — first callers are the shaft's obstructions and fire on the intake.
      BRATTICES = {
        canvas_brattice: { label: "Canvas Brattice", leak: 0.12,
                           description: "Sheeting on battens. Cheap, temporary, and it lets the air by." },
        creosoted_brattice: { label: "Creosoted Brattice", leak: 0.07,
                              description: "Tarred canvas. Tighter than plain, and it will burn." },
        timber_brattice: { label: "Timber Brattice", leak: 0.045,
                           description: "Plank partition the depth of the shaft. Leaks a fair bit." },
        concrete_brattice: { label: "Concrete Walling", leak: 0.006,
                             description: "A wall down the shaft. Barely leaks, and is a great weight." }
      }.freeze

      BRATTICES.each do |id, spec|
        Parts.register(id, kind: :brattice, label: spec.fetch(:label),
                           description: spec.fetch(:description), provides: %i[brattice],
                           stats: { leak: spec.fetch(:leak) }) do |_spec|
          Fragment.new(
            nodes: [ Mine.brattice(leak_fraction: spec.fetch(:leak)) ],
            links: [ Link.new(from: [ :pit_bottom, :brattice_out ], to: [ :brattice, :inlet ]),
                     Link.new(from: [ :brattice, :outlet ], to: [ :upcast_foot, :leak_in ]) ]
          )
        end
      end

      # ---------------------------------------------------------------- drainage

      Parts.register(:sinking_set, kind: :pump, label: "Sinking Set",
                     description: "A small set on the sump. Keeps pace with an ordinary make of water.",
                     provides: %i[pump], instruments: %i[sump_level],
                     stats: { max_kg_per_s: 14.0 }) do |_spec|
        Mine.pump_fragment(max_kg_per_s: 14.0, efficiency: 0.5)
      end

      # **The better pump brings the worse accident.** Rods down the shaft off a beam at the top,
      # and the beam is what fails: broken, it falls into the shaft. The sinking set has none.
      Parts.register(:cornish_set, kind: :pump, label: "Cornish Set",
                     description: "Beam and rods down the shaft. It holds the water down — " \
                                  "and the beam hangs over the only way out.",
                     provides: %i[pump pump_beam], instruments: %i[sump_level beam_condition],
                     stats: { max_kg_per_s: 26.0 }) do |spec|
        Mine.pump_fragment(max_kg_per_s: 26.0, efficiency: 0.68, driven_by: :pump_beam)
            .merge(Mine.beam_fragment(pump_kg_per_s: 26.0, spec: spec))
      end

      def self.pump_fragment(max_kg_per_s:, efficiency:, driven_by: :line_shaft)
        Fragment.new(
          nodes: [ Mine.pump(max_kg_per_s: max_kg_per_s, lift_m: SHAFT_DEPTH_M,
                             efficiency: efficiency, rated_omega: WORKING_OMEGA,
                             driven_by: driven_by) ],
          links: [
            Link.new(from: [ :pit_bottom, :water_out ], to: [ :pump, :inlet ]),
            Link.new(from: [ :pump, :outlet ], to: [ :drainage, :in ])
          ],
          control_points: [
            ControlPoint.new(id: :pumping, label: "Pumping", node: :pump, default: 100.0,
                             place: :bank, stiffness: Travel::HEAVY)
          ]
        )
      end

      # Whoever is under it when it comes down: at bank, in the cage, at the bottom. Every pit has
      # a cage or a kibble; a man engine is optional, so its riders are not named here.
      # TODO: riders of the man engine — needs a hazard that can name a carrier only when fitted.
      BEAM_FALL = { tags: %i[impact crush],
                    places: { bank: 1.2, pit_bottom: 1.6 },
                    riders: { cage_drive: 2.6 } }.freeze

      def self.beam_fragment(pump_kg_per_s:, spec:)
        wreckage = { shaft: 1.0 }.merge(spec[:single_shaft] ? { brattice: 1.0 } : {})

        Fragment.new(
          nodes: [ Mine.pump_beam(pump_kg_per_s: pump_kg_per_s, rated_omega: WORKING_OMEGA,
                                  endangers: { broken: BEAM_FALL }, damages: { broken: wreckage }) ],
          drive_links: [ DriveLink.new(a: :line_shaft, b: :pump_beam, stiffness: 2.0e4) ],
          places: [ Place.new(id: :bank, nodes: [ :pump_beam ]) ]
        )
      end

      # ---------------------------------------------------------------- the crew

      # **The lamp cabin is at bank**, which is where a shift starts and where the walk starts
      # from. Found by what the slot accepts, so the mine gets `crew_capacity` and an origin
      # without reimplementing either.
      Parts.register(:lamp_cabin, kind: :crew_quarters, label: "Lamp Cabin",
                     description: "Where lamps are issued and tallies are taken. Two shifts.",
                     stats: { crew_capacity: 10, recovery_rate: 2.0 }) do |_spec|
        Fragment.new(
          control_points: [
            ControlPoint.new(id: :quarters, label: "Lamp Cabin", place: :bank,
                             recovery: Fatigue::BASE_RECOVERY * 2.0)
          ]
        )
      end

      Parts.register(:pit_head_baths, kind: :crew_quarters, label: "Pit Head Baths",
                     description: "Lamps, lockers and hot water. Somewhere worth resting.",
                     stats: { crew_capacity: 14, recovery_rate: 3.0 }) do |_spec|
        Fragment.new(
          control_points: [
            ControlPoint.new(id: :quarters, label: "Pit Head Baths", place: :bank,
                             recovery: Fatigue::BASE_RECOVERY * 3.0)
          ]
        )
      end

      # ---------------------------------------------------------------- lighting

      # **What the district is lit by, and it is a purchase rather than a standing order.**
      #
      # Hewing is gated on `darkvision`, and a gate is a zero when it is missing — so light is
      # the difference between a shift that wins coal and one that stands in the dark being
      # paid. The tree is the real one, and every step is a genuine trade:
      #
      #   tallow candles   dim, free to run, and an open flame in a gassy room
      #   oil flares       twice the light, the same open flame
      #   gauze lanterns   Davy gauze on the roadway: safe, and you can see less by it
      #   electric lamps   the best light there is, and it hangs off the same shaft as the fan
      #
      # A pit starts with candles, which is why the first upgrade a player reaches for is
      # usually the one that makes the district brighter *and* keeps it lethal.
      Parts.register(:tallow_candles, kind: :lighting, label: "Tallow Candles",
                     description: "Candles on nails down the roadway. An open flame, in a pit.",
                     provides: %i[sconces], instruments: %i[district_light],
                     stats: { illumination: 0.35 }) do |_spec|
        Mine.lighting_fragment(illumination: 0.35, control_id: :naked_flame,
                               flame: Mine::OPEN_FLAME)
      end

      Parts.register(:oil_flares, kind: :lighting, label: "Oil Flares",
                     description: "Open oil flares on brackets. You can see; so can the gas.",
                     provides: %i[sconces], instruments: %i[district_light],
                     stats: { illumination: 0.75 }) do |_spec|
        Mine.lighting_fragment(illumination: 0.75, control_id: :naked_flame,
                               flame: Mine::OPEN_FLAME)
      end

      # **The first tier that is not an ignition source in still air.** Dimmer than the flares it
      # replaces, which is the trade — and a gauze passes its flame in a fast enough draught, so a
      # stronger fan can make it a naked light again. Measured past the sconces on a worked pit with
      # its haulage door shut, the waddle fan makes 1.84 m/s in a single shaft and 2.02 in two, the
      # Guibal 2.54 and 3.03, and natural draught alone about 1.9 — so the Guibal is what defeats the
      # gauze, and electric lamps are what answer it. (Historically an unbonneted Davy lamp passed
      # flame at about six feet a second; this is a little above, so the starting fan stays safe.)
      GAUZE_PASSES_M_S = 2.3

      Parts.register(:gauze_lanterns, kind: :lighting, label: "Gauze Lanterns",
                     description: "Davy gauze on the roadway side. Safe, until the air is too quick for it.",
                     provides: %i[sconces], instruments: %i[district_light],
                     stats: { illumination: 0.5, gauze_passes_m_s: GAUZE_PASSES_M_S }) do |_spec|
        Mine.lighting_fragment(illumination: 0.5, control_id: :safe_light,
                               flame: { gauze_passes_m_s: GAUZE_PASSES_M_S })
      end

      # Hung off the same line shaft as the fan, the pump and the winder — so the best light in
      # the mine is also one more thing competing for the supply, and a brownout puts the
      # district dark with the shift still in it.
      Parts.register(:electric_lamps, kind: :lighting, label: "Electric Lamps",
                     description: "A dynamo off the line shaft. The best light there is, while the shaft turns.",
                     provides: %i[sconces], instruments: %i[district_light],
                     stats: { illumination: 1.0, max_torque: 210.0 }) do |_spec|
        Mine.lighting_fragment(illumination: 1.0, control_id: :safe_light,
                               max_torque: 210.0, rated_omega: WORKING_OMEGA)
      end

      def self.lighting_fragment(illumination:, control_id:, max_torque: 0.0, rated_omega: 0.0,
                                 flame: {})
        Fragment.new(
          nodes: [ Mine.sconces(illumination: illumination, control_id: control_id,
                                max_torque: max_torque, rated_omega: rated_omega, flame: flame) ],
          # Only a powered tier hangs off the shaft. The rest are a flame on a bracket.
          drive_links: rated_omega.positive? ?
            [ DriveLink.new(a: :line_shaft, b: :sconces, stiffness: 1.4e3) ] : [],
          places: [ Place.new(id: :district, nodes: [ :sconces ]) ],
          control_points: [
            # **At bank**, because it is a standing order to the shift rather than something
            # anybody walks over to turn up. Labelled the same in every tier: to the player it
            # is one lever, and which id it carries is what decides whether it fires the gas.
            ControlPoint.new(id: control_id, label: "Sconces", node: :sconces,
                             default: 0.0, place: :bank, stiffness: Travel::SCONCES)
          ]
        )
      end

      # **Somewhere to sit down without walking out**, which is the whole of it.
      #
      # The lamp cabin is at bank, and bank is a shaft and four hundred metres of roadway away
      # from the face — so resting a spent hewer cost the round trip and the player simply never
      # did it. A cut-out in the roadway side is the historical answer and the cheap one.
      #
      # **`capacity:` is the mechanic and the upgrade path.** A manhole takes one man; whether a
      # second may be sent is `Operation#assign_minion`'s refusal, not a rule here.
      Parts.register(:refuge_hole, kind: :rest_station, label: "Refuge Hole",
                     description: "A manhole cut in the roadway side. Room for one, and no more.",
                     stats: { rest_capacity: 1, recovery_rate: 1.4 }) do |_spec|
        Mine.rest_fragment(capacity: 1, recovery_rate: 1.4, label: "Refuge Hole")
      end

      Parts.register(:snap_cabin, kind: :rest_station, label: "Snap Cabin",
                     description: "A proper cut-out with a bench and a water can. Three at a time.",
                     stats: { rest_capacity: 3, recovery_rate: 2.4 }) do |_spec|
        Mine.rest_fragment(capacity: 3, recovery_rate: 2.4, label: "Snap Cabin")
      end

      # --- manholes -------------------------------------------------------------------------
      #
      # **The least interesting purchase in the pit, and the one that saves most lives.** The
      # haulage road hurts people with nothing broken — a set of tubs goes past and sooner or
      # later catches somebody — and cutting refuges into its side is the whole answer. It
      # wins no coal and shows nothing on a gauge.
      #
      # **Empty is legal and is where every pit starts**, exactly as the ladderway is: this is
      # something a player notices they need, usually by reading an event about somebody who
      # did not have one.
      Parts.register(:sparse_manholes, kind: :haulage_refuge, label: "Manholes",
                     description: "Refuges cut every forty yards. Something, if you are quick.",
                     stats: { refuge_reach: 0.5 }) do |_spec|
        Fragment.new(nodes: [ Mine.manholes(effectiveness: 0.5, label: "Manholes") ])
      end

      Parts.register(:whitewashed_manholes, kind: :haulage_refuge, label: "Whitewashed Manholes",
                     description: "Refuges every twenty yards, limed so they show in a lamp.",
                     stats: { refuge_reach: 0.85 }) do |_spec|
        Fragment.new(nodes: [ Mine.manholes(effectiveness: 0.85, label: "Whitewashed Manholes") ])
      end

      # **In the district, which is the entire point**, and a control point with no `node:` —
      # somewhere to stand, not something to set.
      def self.rest_fragment(capacity:, recovery_rate:, label:)
        Fragment.new(
          control_points: [
            ControlPoint.new(id: :rest, label: label, place: :district, capacity: capacity,
                             recovery: Fatigue::BASE_RECOVERY * recovery_rate)
          ]
        )
      end

      # ---------------------------------------------------------------- slots

      # Declaration order is the panel's lever order. Ordered by where the work is — bank first,
      # then underground — rather than by the order the graph happens to resolve in.
      def self.slots(spec)
        fitted = spec.fetch(:parts)

        [
          Slot.new(id: :cutting, accepts: :cutting, label: "Cutting", group: :face,
                   required: true, default: fitted.fetch(:cutting)),
          Slot.new(id: :winder, accepts: :winder, label: "Winder", group: :shaft,
                   required: true, default: fitted.fetch(:winder)),
          # **Empty is where every mine starts**, and there are still the ladders. Nothing has
          # to be bypassed, because nothing downstream depends on it: a man-riding fitting only
          # ever *adds* a faster way through a shaft that could always be climbed.
          Slot.new(id: :manriding, accepts: :manriding, label: "Man Riding", group: :shaft,
                   required: false, default: nil, when_empty: :omit),
          Slot.new(id: :rope, accepts: :rope, label: "Winding Rope", group: :shaft,
                   required: true, default: fitted.fetch(:rope)),
          Slot.new(id: :headframe, accepts: :headframe, label: "Headframe", group: :shaft,
                   required: true, default: fitted.fetch(:headframe)),
          Slot.new(id: :spare_rope, accepts: :spare_rope, label: "Spare Rope", group: :shaft,
                   required: false, default: nil, when_empty: :omit),
          Slot.new(id: :shaft_gates, accepts: :shaft_gates, label: "Shaft Gates", group: :shaft,
                   required: false, default: nil, when_empty: :omit),
          Slot.new(id: :signals, accepts: :signals, label: "Signals", group: :shaft,
                   required: false, default: :electric_bells, when_empty: :omit),
          Slot.new(id: :overspeed_trip, accepts: :overspeed_trip, label: "Overspeed Trip",
                   group: :shaft, required: false, default: nil, when_empty: :omit),
          # Every pit has a door where the haulage crosses the return; what is bought is who shuts it.
          Slot.new(id: :door, accepts: :door, label: "Haulage Door", group: :air,
                   required: true, default: :plain_door),
          Slot.new(id: :lighting, accepts: :lighting, label: "Lighting", group: :face,
                   required: true, default: fitted.fetch(:lighting)),
          Slot.new(id: :fan, accepts: :fan, label: "Fan", group: :air,
                   required: true, default: fitted.fetch(:fan)),
          Slot.new(id: :pump, accepts: :pump, label: "Pump", group: :water,
                   required: true, default: fitted.fetch(:pump)),
          Slot.new(id: :quarters, accepts: :crew_quarters, label: "Lamp Cabin", group: :crew,
                   required: true, default: fitted.fetch(:quarters)),
          # **Not `:crew_quarters`, and it matters.** `Assembly#crew_capacity` finds the
          # quarters by what a slot ACCEPTS and takes the first — a second one would make a
          # rest station decide how many hands the pit can field.
          Slot.new(id: :rest, accepts: :rest_station, label: "Rest Station", group: :crew,
                   required: true, default: fitted.fetch(:rest)),
          # Not required, and defaulted to nothing. A pit that has bought no refuges is the
          # starting pit, and the first a player hears of it is a man caught in the haulage.
          Slot.new(id: :manholes, accepts: :haulage_refuge, label: "Manholes", group: :crew,
                   required: false, default: fitted[:manholes]),
          # Only a single shaft has one: two shafts have nothing between them to partition.
          *(if spec[:single_shaft]
              [ Slot.new(id: :brattice, accepts: :brattice, label: "Brattice", group: :air,
                         required: true, default: fitted.fetch(:brattice)) ]
            end)
        ]
      end

      # What no slot owns: the hole in the ground itself, the air in it, the coal in the seam and
      # the water behind it. A mine without a fan is a legal thing to build; a mine without a
      # shaft is not a mine.
      #
      # **Its gauges are supplied rather than named**, for the same reason its nodes are: they
      # read fixtures, so no part can take them away. Pulled from the catalogue rather than
      # rebuilt here, so a gauge has one definition wherever it arrives from.
      # `spec[:ground]` pins every seep at one multiplier instead of drawing one. Nil — a real
      # match — draws, which is the point of the whole mechanism; a spec measuring the machine
      # passes `Ground::ORDINARY`.
      def self.fixtures(spec)
        ground = spec[:ground]
        Fragment.new(
          diagnostics: Mine.catalogue.values_at(:flame_cap, :lamp_flame, :canary, :shaft_speed,
                                                :shaft_supply, :district_air, :seam_remaining,
                                                # The road, what moves on it and what the ground
                                                # is making are the hole itself rather than a
                                                # fitting, so no part can take these away.
                                                :roof_timber, :putting, :water_make, :survey,
                                                :bore_holes, :goaf_weight, :fire_stink,
                                                # Whether the district is on fire. The one
                                                # reading no fitting may remove, because a pit
                                                # with nothing bought can still go up.
                                                :district_fire),
          # Every shaft can be climbed. Only one that has bought the gear can be ridden.
          passages: Mine.passages(spec),
          places: PLACES,
          nodes: [
            Mine.shaft, *([ Mine.upcast_foot ] if spec[:single_shaft]),
            Mine.atmosphere, Mine.line_shaft(rated_torque_nm: 5.4e3, rated_omega: WORKING_OMEGA),
            Mine.downcast, Mine.pit_bottom, Mine.main_road, Mine.district, Mine.return_road,
            Mine.seam(kg: SEAM_KG, firedamp_kg: 4_000.0),
            Mine.dust_source(kg: 3_000.0),
            # Deep enough that it never runs dry: a pit does not stop making blackdamp.
            Mine.goaf(kg: 20_000.0, seam_kg: SEAM_KG, sour: (Mine::OldWorkings::ORDINARY_SOUR if ground),
                      ground: ground),
            Mine.goaf_seep(conductance: 1.8e-5, ground: ground),
            Mine.blower(conductance: 2.5e-4, ground: ground),
            Mine.dust_line(max_kg_per_s: 0.30),
            Mine.dust_store(kg: 6_000.0), Mine.dusting_line(max_kg_per_s: 0.55),
            Mine.tub_road(max_kg_per_s: 6.0), Mine.screens,
            # 18 kg/s through a broken fissure, against a sinking set's 14 and a Cornish set's
            # 26 — so the starting pump is overwhelmed by an inrush and the upgrade is what
            # holds it. That gap is the reason to buy the better set.
            Mine.strata(kg: 5.0e5), Mine.seepage(inrush_kg_per_s: 18.0, seam_kg: SEAM_KG, ground: ground),
            Mine.drainage,
            # Gas held in the coal ahead, the outburst that releases it, and the auger that finds it.
            Mine.gas_pocket(seam_kg: SEAM_KG, ground: ground), Mine.outburst, Mine.bore_line,
            # The waste behind the face, and the air that leaks through it.
            Mine.gob(ground: ground), Mine.gob_leak(:waste_in), Mine.gob_leak(:waste_out)
          ],
          links: [
            # Air: down the downcast, round the workings. The return side comes with the fan.
            Link.new(from: [ :atmosphere, :intake ], to: [ :downcast, :inlet ]),
            Link.new(from: [ :downcast, :outlet ], to: [ :pit_bottom, :air_in ]),
            Link.new(from: [ :pit_bottom, :air_out ], to: [ :main_road, :inlet ]),
            Link.new(from: [ :main_road, :outlet ], to: [ :district, :air_in ]),
            # Coal: out of the seam, into the district, along the road. The shaft comes with the
            # winder.
            # Gas out of the seam and into the workings, continuously. Nothing controls it.
            Link.new(from: [ :seam, :gas_out ], to: [ :blower, :inlet ]),
            Link.new(from: [ :blower, :outlet ], to: [ :district, :gas_in ]),
            # Blackdamp out of the old workings and into the lowest point in the mine.
            Link.new(from: [ :goaf, :out ], to: [ :goaf_seep, :inlet ]),
            Link.new(from: [ :goaf_seep, :outlet ], to: [ :pit_bottom, :damp_in ]),
            # Dust off the pick, and the limestone that answers it.
            Link.new(from: [ :dust_source, :out ], to: [ :dust_line, :inlet ]),
            Link.new(from: [ :dust_line, :outlet ], to: [ :district, :dust_in ]),
            Link.new(from: [ :dust_store, :out ], to: [ :dusting_line, :inlet ]),
            Link.new(from: [ :dusting_line, :outlet ], to: [ :district, :stone_in ]),
            # Coal out of the seam comes with the cutting fitting, whichever one is fitted.
            Link.new(from: [ :district, :coal_out ], to: [ :tub_road, :inlet ]),
            Link.new(from: [ :tub_road, :outlet ], to: [ :pit_bottom, :coal_in ]),
            # Water: in through the strata, downhill to the pit bottom. The lift comes with the
            # pump.
            Link.new(from: [ :strata, :out ], to: [ :seepage, :inlet ]),
            Link.new(from: [ :seepage, :outlet ], to: [ :pit_bottom, :water_in ]),
            Link.new(from: [ :gas_pocket, :out ], to: [ :outburst, :inlet ]),
            Link.new(from: [ :outburst, :outlet ], to: [ :district, :burst_in ]),
            Link.new(from: [ :gas_pocket, :out ], to: [ :bore_line, :inlet ]),
            Link.new(from: [ :bore_line, :outlet ], to: [ :district, :burst_in ]),
            Link.new(from: [ :pit_bottom, :waste_out ], to: [ :waste_in, :inlet ]),
            Link.new(from: [ :waste_in, :outlet ], to: [ :gob, :air_in ]),
            Link.new(from: [ :gob, :air_out ], to: [ :waste_out, :inlet ]),
            Link.new(from: [ :waste_out, :outlet ], to: [ :district, :waste_in ])
          ],
          control_points: [
            ControlPoint.new(id: :clutch, label: "Clutch", node: :line_shaft, default: 100.0,
                             place: :bank, stiffness: Travel::QUICK),
            # **The most boring lever in the game, and the one that decides whether an ignition
            # is an incident or a disaster.** It wins no coal, spends stores that run out, and
            # does nothing whatever until the day the gas goes up.
            ControlPoint.new(id: :stone_dusting, label: "Stone Dusting", node: :dusting_line,
                             default: 0.0, place: :bank, stiffness: Travel::HEAVY),
            # **The two effort stations, and they are underground.** Somebody has to be sent
            # there, which is the whole point of the geometry.
            # **Gated, not merely aided.** An ogre with no pick gets no coal out of a seam
            # however strong they are, and nobody gets any in the dark — so these two multiply
            # and a missing one is a zero. It is the single biggest reason to spend anything on
            # equipment, and the reason a kobold's innate darkvision is worth something.
            # **Not `endurance`**, however much putting is an endurance job — it is a divisor in
            # `Fatigue.accrual` and enters no capability blend, which is what lets the reference
            # crew set it to 1e6. See the traps list.
            ControlPoint.new(id: :haulage, label: "Putting", node: :tub_road, default: 0.0,
                             place: :pit_bottom,
                             # **`force`, because a loaded tub is friction and leverage** — this
                             # is the job where sheer mass pays most, and where an outrageously
                             # muscular pixie still shifts nothing.
                             effort: { force: 0.8, toughness: 0.2 },
                             aided_by: :shovelling, exertion: 9.0e-4),
            # **The third effort station, and the one that produces nothing.** Setting timber
            # wins no coal and raises no water; all it does is stop the roof taking up the slack
            # behind a face that is being cut. Against a crew of four and four other jobs, that
            # is the triage: the post whose whole output is *nothing going wrong* is the one
            # nobody can spare somebody for.
            #
            # `node: :tub_road` because that is what it supports — the lever is read by the
            # roadway's own wear, not by anything that moves material.
            # **Gated exactly as hewing is, and that is not a detail.** `Roadway` wears on
            # `hewing − timbering`, and a difference between two levers only means anything if
            # both are measured the same way. Gating one multiplicatively (×0.48 for a decent
            # kit) while the other was merely aided (×1.6) put them on scales three times
            # apart, so any timbering at all covered any amount of cutting and the roof could
            # not come in. Same gates, same scale, real difference.
            ControlPoint.new(id: :timbering, label: "Timbering", node: :tub_road, default: 0.0,
                             place: :district,
                             # `force`: props and bars are heavy things lifted into place, and
                             # the dexterity half is setting them true once they are up there.
                             effort: { force: 0.6, dexterity: 0.4 },
                             gated_by: %i[mining_effectiveness darkvision],
                             exertion: 1.0e-3),
            # **Boring ahead**: an auger driven into the face, which finds what lies in the coal and
            # draws a gas pocket off before the face reaches it. It wins no coal and costs a hand at
            # a face that has fewer hands than jobs, which is the trade. Posted is working.
            ControlPoint.new(id: :boring, label: "Boring Ahead", node: :bore_line, default: 100.0,
                             place: :district, effort: { swing: 0.6, dexterity: 0.4 },
                             gated_by: %i[darkvision], exertion: 9.0e-4),
            # **Packing**: stone built into the void behind the face so the roof settles on it rather
            # than hanging until it falls. Heavy, and it wins no coal. Posted is working.
            ControlPoint.new(id: :packing, label: "Packing", node: :goaf, default: 100.0,
                             place: :district, effort: { force: 0.7, toughness: 0.3 },
                             gated_by: %i[darkvision], exertion: 1.1e-3),
            # **Sealing the waste**: stoppings built across the leakage, which starve a heating gob of
            # air. What is built stays built. Posted is working.
            ControlPoint.new(id: :sealing, label: "Sealing the Waste", node: :gob, default: 100.0,
                             place: :district, effort: { force: 0.5, dexterity: 0.5 },
                             gated_by: %i[darkvision], exertion: 8.0e-4)
          ]
        )
      end

      # Reachability, checked against the real resolved paths.
      ROUTES = [
        { from: :atmosphere, to: :district, carrying: :gas,
          as: "no route for fresh air to reach the workings" },
        { from: :district, to: :atmosphere, carrying: :gas,
          as: "the workings have no return — nothing carries the foul air away" },
        { from: :seam, to: :screens, carrying: :solid,
          as: "no route for coal to reach the surface" },
        { from: :strata, to: :drainage, carrying: :liquid,
          as: "no route for water out of the sump — the mine will drown" }
      ].freeze

      ADVISORIES = [].freeze
    end
  end
end
