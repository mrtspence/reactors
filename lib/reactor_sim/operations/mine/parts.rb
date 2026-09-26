# frozen_string_literal: true

module ReactorSim
  module Operations
    module Mine
      # How deep the shaft is. Every lift in the mine is measured against it, so it lives here
      # rather than being repeated in three fittings that could disagree.
      SHAFT_DEPTH_M = 90.0

      # What the line shaft turns at when the supply is healthy. Driven fittings are rated
      # against it, so a fitting's declared duty means "at working speed" rather than "always".
      WORKING_OMEGA = 22.0

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
                  nodes: %i[atmosphere screens winder line_shaft upcast drainage dust_store]),
        Place.new(id: :pit_bottom, label: "Pit Bottom", nodes: %i[pit_bottom pump]),
        Place.new(id: :district, label: "The District",
                  nodes: %i[district pick_line dust_line blower])
      ].freeze

      # ---------------------------------------------------------------- winding

      Parts.register(:steam_whim, kind: :winder, label: "Steam Whim",
                     description: "A drum, a rope, and a kibble. One load at a time.",
                     provides: %i[winder], instruments: %i[coal_raised],
                     stats: { max_kg_per_s: 2.2 }) do |_spec|
        Mine.winding_fragment(max_kg_per_s: 2.2)
      end

      Parts.register(:cage_winder, kind: :winder, label: "Cage Winder",
                     description: "Guided cage on wire rope. Takes tubs by the deck.",
                     provides: %i[winder], instruments: %i[coal_raised],
                     stats: { max_kg_per_s: 7.0 }) do |_spec|
        Mine.winding_fragment(max_kg_per_s: 7.0)
      end

      def self.winding_fragment(max_kg_per_s:)
        Fragment.new(
          nodes: [ Mine.winder(max_kg_per_s: max_kg_per_s, lift_m: SHAFT_DEPTH_M,
                               rated_omega: WORKING_OMEGA) ],
          links: [
            Link.new(from: [ :pit_bottom, :coal_out ], to: [ :winder, :inlet ]),
            Link.new(from: [ :winder, :outlet ], to: [ :screens, :in ])
          ],
          control_points: [
            ControlPoint.new(id: :winding, label: "Winding", node: :winder, default: 0.0,
                             place: :bank)
          ]
        )
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
        Mine.cutting_fragment(max_kg_per_s: 5.6, exertion: 3.0e-4)
      end

      def self.cutting_fragment(max_kg_per_s:, exertion:)
        Fragment.new(
          nodes: [ Mine.pick_line(max_kg_per_s: max_kg_per_s) ],
          links: [
            Link.new(from: [ :seam, :out ], to: [ :pick_line, :inlet ]),
            Link.new(from: [ :pick_line, :outlet ], to: [ :district, :coal_in ])
          ],
          control_points: [
            # Gated, not merely aided: an ogre with no pick gets no coal out of a seam however
            # strong they are, and nobody gets any in the dark.
            ControlPoint.new(id: :hewing, label: "Hewing", node: :pick_line, default: 0.0,
                             place: :district,
                             effort: { strength: 0.7, dexterity: 0.3 },
                             gated_by: %i[mining_effectiveness darkvision],
                             exertion: exertion)
          ]
        )
      end

      # ---------------------------------------------------------------- man riding

      # **Its own slot, because raising coal and raising men are different machines.** A man
      # engine winds no coal at all, and a colliery that bought one bought it precisely so that
      # shift change would stop costing it winding time. Optional: with nothing fitted there are
      # still the ladders, which is where every mine starts.

      # A reciprocating rod down the shaft with steps on it: you ride twelve feet, step off onto
      # a sollar, wait, and step on again. Slower than a cage and far cheaper to turn — at
      # Tresavean it cut the journey from an hour to twenty-four minutes and put a fifth on the
      # shift's output.
      Parts.register(:man_engine, kind: :manriding, label: "Man Engine",
                     description: "Stepped rods and sollars. You ride it twelve feet at a time.",
                     provides: %i[cage_drive],
                     stats: { speed_m_s: 1.8, max_torque: 520.0 }) do |_spec|
        Mine.manriding_fragment(speed_m_s: 1.8, max_torque: 520.0, label: "Man Engine")
      end

      # Quick, and it costs the whole mine while it runs.
      Parts.register(:cage_gear, kind: :manriding, label: "Cage",
                     description: "Guided cage and safety catches. Quick, and heavy on the shaft.",
                     provides: %i[cage_drive],
                     stats: { speed_m_s: 4.2, max_torque: 1_600.0 }) do |_spec|
        Mine.manriding_fragment(speed_m_s: 4.2, max_torque: 1_600.0, label: "Cage")
      end

      def self.manriding_fragment(speed_m_s:, max_torque:, label:)
        Fragment.new(
          nodes: [ Mine.cage_drive(max_torque: max_torque, rated_omega: WORKING_OMEGA) ],
          drive_links: [ DriveLink.new(a: :line_shaft, b: :cage_drive, stiffness: 2.2e3) ],
          passages: [ Mine.cage_passage(speed_m_s: speed_m_s, rated_omega: WORKING_OMEGA,
                                        label: label) ],
          # The gear it brings stands at bank. A fitting names only what it installs; the room
          # is the chassis's and the two declarations are unioned.
          places: [ Place.new(id: :bank, nodes: [ :cage_drive ]) ],
          control_points: [
            ControlPoint.new(id: :man_winding, label: "Man Winding", node: :cage_drive,
                             default: 0.0, place: :bank)
          ]
        )
      end

      # ---------------------------------------------------------------- ventilation

      Parts.register(:waddle_fan, kind: :fan, label: "Waddle Fan",
                     description: "Open-running, no casing. Cheap, and it shows.",
                     provides: %i[upcast], instruments: %i[air_quantity],
                     stats: { head_pa: 2_200.0 }) do |_spec|
        Mine.fan_fragment(head_pa: 2_200.0)
      end

      Parts.register(:guibal_fan, kind: :fan, label: "Guibal Fan",
                     description: "Spiral casing, shuttered discharge, evasee chimney.",
                     provides: %i[upcast], instruments: %i[air_quantity],
                     stats: { head_pa: 5_200.0 }) do |_spec|
        Mine.fan_fragment(head_pa: 5_200.0)
      end

      def self.fan_fragment(head_pa:)
        Fragment.new(
          nodes: [ Mine.upcast(head_pa: head_pa, rated_omega: WORKING_OMEGA) ],
          links: [
            Link.new(from: [ :district, :air_out ], to: [ :return_road, :inlet ]),
            Link.new(from: [ :return_road, :outlet ], to: [ :upcast, :inlet ]),
            Link.new(from: [ :upcast, :outlet ], to: [ :atmosphere, :exhaust ])
          ],
          control_points: [
            ControlPoint.new(id: :ventilation, label: "Fan", node: :upcast, default: 100.0,
                             place: :bank)
          ]
        )
      end

      # ---------------------------------------------------------------- drainage

      Parts.register(:sinking_set, kind: :pump, label: "Sinking Set",
                     description: "A small set on the sump. Keeps pace with an ordinary make of water.",
                     provides: %i[pump], instruments: %i[sump_level],
                     stats: { max_kg_per_s: 14.0 }) do |_spec|
        Mine.pump_fragment(max_kg_per_s: 14.0, efficiency: 0.5)
      end

      Parts.register(:cornish_set, kind: :pump, label: "Cornish Set",
                     description: "Heavy lift gear. Expensive to turn, and it holds the water down.",
                     provides: %i[pump], instruments: %i[sump_level],
                     stats: { max_kg_per_s: 26.0 }) do |_spec|
        Mine.pump_fragment(max_kg_per_s: 26.0, efficiency: 0.68)
      end

      def self.pump_fragment(max_kg_per_s:, efficiency:)
        Fragment.new(
          nodes: [ Mine.pump(max_kg_per_s: max_kg_per_s, lift_m: SHAFT_DEPTH_M,
                             efficiency: efficiency, rated_omega: WORKING_OMEGA) ],
          links: [
            Link.new(from: [ :pit_bottom, :water_out ], to: [ :pump, :inlet ]),
            Link.new(from: [ :pump, :outlet ], to: [ :drainage, :in ])
          ],
          control_points: [
            ControlPoint.new(id: :pumping, label: "Pumping", node: :pump, default: 100.0,
                             place: :bank)
          ]
        )
      end

      # ---------------------------------------------------------------- the crew

      # **The lamp cabin is at bank**, which is where a shift starts and where the walk starts
      # from. Found by what the slot accepts, so the mine gets `crew_capacity` and an origin
      # without reimplementing either.
      Parts.register(:lamp_cabin, kind: :crew_quarters, label: "Lamp Cabin",
                     description: "Where lamps are issued and tallies are taken. Four hands.",
                     stats: { crew_capacity: 4, recovery_rate: 2.0 }) do |_spec|
        Fragment.new(
          control_points: [
            ControlPoint.new(id: :quarters, label: "Lamp Cabin", place: :bank,
                             recovery: Fatigue::BASE_RECOVERY * 2.0)
          ]
        )
      end

      Parts.register(:pit_head_baths, kind: :crew_quarters, label: "Pit Head Baths",
                     description: "Lamps, lockers and hot water. Somewhere worth resting.",
                     stats: { crew_capacity: 6, recovery_rate: 3.0 }) do |_spec|
        Fragment.new(
          control_points: [
            ControlPoint.new(id: :quarters, label: "Pit Head Baths", place: :bank,
                             recovery: Fatigue::BASE_RECOVERY * 3.0)
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
          Slot.new(id: :fan, accepts: :fan, label: "Fan", group: :air,
                   required: true, default: fitted.fetch(:fan)),
          Slot.new(id: :pump, accepts: :pump, label: "Pump", group: :water,
                   required: true, default: fitted.fetch(:pump)),
          Slot.new(id: :quarters, accepts: :crew_quarters, label: "Lamp Cabin", group: :crew,
                   required: true, default: fitted.fetch(:quarters))
        ]
      end

      # What no slot owns: the hole in the ground itself, the air in it, the coal in the seam and
      # the water behind it. A mine without a fan is a legal thing to build; a mine without a
      # shaft is not a mine.
      #
      # **Its gauges are supplied rather than named**, for the same reason its nodes are: they
      # read fixtures, so no part can take them away. Pulled from the catalogue rather than
      # rebuilt here, so a gauge has one definition wherever it arrives from.
      def self.fixtures(_spec)
        Fragment.new(
          diagnostics: Mine.catalogue.values_at(:flame_cap, :lamp_flame, :canary, :shaft_speed,
                                                :shaft_supply, :district_air, :seam_remaining),
          # Every shaft can be climbed. Only one that has bought the gear can be ridden.
          passages: Mine.passages,
          places: PLACES,
          nodes: [
            Mine.atmosphere, Mine.line_shaft(rated_torque_nm: 5.4e3, rated_omega: WORKING_OMEGA),
            Mine.downcast, Mine.pit_bottom, Mine.main_road, Mine.district, Mine.return_road,
            Mine.seam(kg: 90_000.0, firedamp_kg: 4_000.0),
            Mine.dust_source(kg: 3_000.0),
            # Deep enough that it never runs dry: a pit does not stop making blackdamp.
            Mine.goaf(kg: 20_000.0), Mine.goaf_seep(conductance: 1.8e-5),
            Mine.blower(conductance: 2.5e-4), Mine.dust_line(max_kg_per_s: 0.30),
            Mine.dust_store(kg: 6_000.0), Mine.dusting_line(max_kg_per_s: 0.55),
            Mine.tub_road(max_kg_per_s: 6.0), Mine.screens,
            # 18 kg/s through a broken fissure, against a sinking set's 14 and a Cornish set's
            # 26 — so the starting pump is overwhelmed by an inrush and the upgrade is what
            # holds it. That gap is the reason to buy the better set.
            Mine.strata(kg: 5.0e5), Mine.seepage(inrush_kg_per_s: 18.0), Mine.drainage
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
            Link.new(from: [ :seepage, :outlet ], to: [ :pit_bottom, :water_in ])
          ],
          control_points: [
            ControlPoint.new(id: :clutch, label: "Clutch", node: :line_shaft, default: 100.0,
                             place: :bank),
            # **Naked lights.** Off by default, because the default has to be the one that does
            # not kill anybody. Historically the decision that separates a pit that has had an
            # explosion from one that has not, and it is a lever rather than a fitting because
            # it is a standing order to the shift rather than a thing you buy.
            ControlPoint.new(id: :naked_lights, label: "Naked Lights", node: :district,
                             default: 0.0, place: :bank),
            # **The most boring lever in the game, and the one that decides whether an ignition
            # is an incident or a disaster.** It wins no coal, spends stores that run out, and
            # does nothing whatever until the day the gas goes up.
            ControlPoint.new(id: :stone_dusting, label: "Stone Dusting", node: :dusting_line,
                             default: 0.0, place: :bank),
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
                             effort: { strength: 0.8, toughness: 0.2 },
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
                             effort: { strength: 0.6, dexterity: 0.4 },
                             gated_by: %i[mining_effectiveness darkvision],
                             exertion: 1.0e-3)
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
