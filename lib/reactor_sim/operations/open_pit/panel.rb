# frozen_string_literal: true

module ReactorSim
  module Operations
    module OpenPit
      # **The panel**: what the gangs would tell you, and what is piling up at bank. Everything in
      # an open pit is in plain sight, so most of it is the gang's own word rather than a dial.
      module_function

      PANEL_ORDER = (%i[finished_tons kiln_board kiln_fire coal_stock_left washed_tons] +
                     (1..BAYS).map { |number| bay(number).(:board) } +
                     %i[crusher_board belt_board shaft_speed water_supply the_dam dam_wall reservoir_bank
                        stripping_face ore_face stripping_shots ore_shots the_magazine uncovered_ore the_sump the_tip
                        the_edge ore_at_bank spoil_tipped] +
                     WeatherGauges::ORDER).freeze

      # Uncovered ore under these, in kilograms: stripping behind, running short, plenty.
      UNCOVERED_BANDS = [ 1.0, 6_000.0 ].freeze

      # The sump's water, in kilograms: in its hole, on the floor, at the flood mark, out of depth.
      SUMP_BANDS = [ SUMP_HOLE_KG, SUMP_FLOOD_KG, SUMP_DEEP_KG ].freeze

      def catalogue
        {
          # **Each face's board**: what the gang is doing and what is holding it up — nothing
          # uncovered, the muck piling up, nobody at it, into hard ground. Their word, as it is.
          stripping_face: board(:stripping),
          ore_face: board(:ore),

          # **How much ore lies uncovered ahead of the ore gang**, in their words: the gauge that says
          # which gang needs help. Their word, so nobody at the face means nobody saying.
          uncovered_ore: Diagnostic.new(
            id: :uncovered_ore, label: "Uncovered Ore", observer: face(:ore).(:getters),
            source: Sources::Field.new(:ore_bench, :uncovered_kg),
            filters: [ Filters::Lag.new(4), Filters::Bands.new(UNCOVERED_BANDS) ],
            display: Displays::Prose.new([ "stripping behind", "running short", "plenty uncovered" ])
          ),

          # **The water at the bottom of the pit**, in the ore gang's words: theirs is the face it
          # floods.
          the_sump: Diagnostic.new(
            id: :the_sump, label: "The Sump", observer: face(:ore).(:getters),
            source: Sources::Field.new(:sump, :standing_kg),
            filters: [ Filters::Lag.new(4), Filters::Bands.new(SUMP_BANDS) ],
            display: Displays::Prose.new([ "dry", "water on the floor", "the face flooded", "over a man's head" ])
          ),

          # **Each face's shot holes, in the powder gang's words**: charged and waiting for the word is
          # the moment to clear the range.
          stripping_shots: shot_board(:stripping),
          ore_shots: shot_board(:ore),

          # **The thawing house, as the powdermen find it**: frozen, thawed, or sweating.
          the_magazine: Diagnostic.new(
            id: :the_magazine, label: "Thawing House", observer: face(:stripping).(:powder_gang),
            source: Sources::Derived.new(:magazine, :temperature_k),
            filters: [ Filters::Lag.new(8), Filters::Bands.new([ DYNAMITE_FREEZES_K, EXUDES_K - 5.0 ]) ],
            display: Displays::Prose.new([ "frozen", "thawed", "sweating" ])
          ),

          # **The dump's edge, in the dumpmen's words**: the cracks behind it before it breaks back.
          the_edge: Diagnostic.new(
            id: :the_edge, label: "The Edge", observer: :dumpmen, source: Sources::Field.new(:tip_head, :signal),
            display: Displays::Prose.new(TipHead::SIGNALS.values)
          ),

          # **Whether the barrows can tip**: the tip head as the dumpmen see it.
          the_tip: Diagnostic.new(
            id: :the_tip, label: "The Tip", source: Sources::Level.new(:tip_head),
            filters: [ Filters::Lag.new(2), Filters::Bands.new([ 50.0, 85.0 ]) ],
            display: Displays::Prose.new([ "room to tip", "filling up", "full — nowhere to tip" ])
          ),

          ore_at_bank: Diagnostic.new(
            id: :ore_at_bank, label: "Ore at Bank",
            source: Sources::Aggregate.new(WASH_ORE.keys.map { |resource| Sources::Contents.new(:ore_bin, resource) }),
            filters: [ Filters::Lag.new(2), Filters::Quantize.new(100.0) ],
            display: Displays::Digital.new(unit: "t", precision: 1, convert: :kilo)
          ),

          spoil_tipped: Diagnostic.new(
            id: :spoil_tipped, label: "Spoil Tipped", source: Sources::Contents.new(:spoil_dump, :overburden),
            filters: [ Filters::Lag.new(2), Filters::Quantize.new(100.0) ],
            display: Displays::Digital.new(unit: "t", precision: 1, convert: :kilo)
          ),

          # **Finished ore, the goal's count**: the hematite drawn from the kiln, weighed. Ore drawn
          # before it was burnt through is on the same heap and counts for nothing.
          finished_tons: Diagnostic.new(
            id: :finished_tons, label: "Finished Ore", source: Sources::Contents.new(:finished_ore, :hematite),
            filters: [ Filters::Lag.new(2), Filters::Quantize.new(50.0) ],
            display: Displays::Digital.new(unit: "t", precision: 2, convert: :kilo)
          ),

          # **Washed ore waiting for the kiln**: what the washers have put on the stockpile.
          washed_tons: Diagnostic.new(
            id: :washed_tons, label: "Washed Ore", source: Sources::Contents.new(:washed_ore, :limonite),
            filters: [ Filters::Lag.new(2), Filters::Quantize.new(50.0) ],
            display: Displays::Digital.new(unit: "t", precision: 2, convert: :kilo)
          ),

          # **The kiln's coal, as somebody's guess** at the heap.
          coal_stock_left: Diagnostic.new(
            id: :coal_stock_left, label: "Kiln Coal", source: Sources::Level.new(:coal_stock),
            filters: [ Filters::Lag.new(6), Filters::Bands.new([ 15.0, 40.0 ]) ],
            display: Displays::Prose.new([ "nearly out", "getting low", "plenty of coal" ])
          ),

          # **What the crusher and its belt are doing**, in words.
          crusher_board: Diagnostic.new(
            id: :crusher_board, label: "Crusher", source: Sources::Field.new(:crusher, :signal),
            display: Displays::Prose.new(Crusher::SIGNALS.values)
          ),
          belt_board: Diagnostic.new(
            id: :belt_board, label: "Feed Belt", source: Sources::Field.new(:feed_belt, :signal),
            display: Displays::Prose.new(Nodes::Belt::SIGNALS.values)
          ),

          # The one honest gauge in the yard: the shaft is in front of you.
          shaft_speed: Diagnostic.new(
            id: :shaft_speed, label: "Line Shaft", source: Sources::Derived.new(:line_shaft, :rpm),
            filters: [ Filters::Lag.new(1), Filters::Noise.new(1.2, deadband: 4.0) ],
            display: Displays::Needle.new(unit: "rpm", precision: 0, min: 0.0, max: 320.0)
          ),

          # **The water and the mud, as the first bay's hands reckon them.** Their word, so nobody at
          # that washer means nobody saying.
          water_supply: Diagnostic.new(
            id: :water_supply, label: "Reservoir", observer: bay(1).(:hands), source: Sources::Level.new(:reservoir),
            filters: [ Filters::Lag.new(6), Filters::Bands.new([ 10.0, 35.0 ]) ],
            display: Displays::Prose.new([ "nearly dry", "getting low", "plenty of water" ])
          ),
          the_dam: Diagnostic.new(
            id: :the_dam, label: "Mud Dam", observer: bay(1).(:hands), source: Sources::Level.new(:mud_dam),
            filters: [ Filters::Lag.new(6), Filters::Bands.new([ 60.0, 85.0, 98.0 ]) ],
            display: Displays::Prose.new([ "room in the dam", "dam filling", "dam near the top", "over the crest" ])
          ),

          # **The walls, in the words of whoever is on them**: weeping, then slumping, before they go.
          dam_wall: Diagnostic.new(
            id: :dam_wall, label: "Dam Wall", observer: :dam_hands, source: Sources::Field.new(:mud_dam, :signal),
            display: Displays::Prose.new(Embankment::SIGNALS.values)
          ),
          reservoir_bank: Diagnostic.new(
            id: :reservoir_bank, label: "Reservoir Bank", observer: :bankmen, source: Sources::Field.new(:reservoir, :signal),
            display: Displays::Prose.new(Embankment::SIGNALS.values)
          )
        }.merge(WeatherGauges.instruments)
      end

      # **What a bay's washer is doing and what it is waiting on**, in words, as its hands see it:
      # built by the washer fitted there, one board a bay.
      def washer_board(names)
        Diagnostic.new(id: names.(:board), label: bay_label(names), source: Sources::Field.new(names.(:washer), :signal),
                       display: Displays::Prose.new(LogWasher::SIGNALS.values))
      end

      # **The kiln's board**, in the burners' words: built by the kiln fitted.
      def kiln_board
        Diagnostic.new(id: :kiln_board, label: "Kiln", source: Sources::Field.new(:kiln, :signal),
                       display: Displays::Prose.new(Kiln::SIGNALS.values))
      end

      # **The kiln's heat, as whoever charges it judges it**: by the colour of the fire.
      FIRE_BANDS = [ 750.0, 900.0, 1_050.0 ].freeze

      def kiln_fire(observer)
        Diagnostic.new(id: :kiln_fire, label: "Kiln Fire", observer: observer, source: Sources::Derived.new(:kiln, :temperature_k),
                       filters: [ Filters::Lag.new(8), Filters::Bands.new(FIRE_BANDS) ],
                       display: Displays::Prose.new([ "black", "dull red", "cherry red", "bright" ]))
      end

      SHOT_WORDS = {
        idle: "no shot charged", charging: "drilling and charging", fired: "shot fired — ground broken",
        misfire: "a misfire in the hole", clearing: "digging out a misfire", charged: "charged — ready to fire"
      }.freeze

      def shot_board(face_id)
        names = face(face_id)
        Diagnostic.new(id: :"#{face_id}_shots", label: "#{face_label(names)} Shots", observer: names.(:powder_gang),
                       source: Sources::Field.new(names.(:shot_hole), :status),
                       display: Displays::Prose.new(Nodes::ShotHole::STATUSES.map { |status| SHOT_WORDS.fetch(status) }))
      end

      def board(face_id)
        names = face(face_id)
        Diagnostic.new(id: :"#{face_id}_face", label: "#{face_label(names)} Face",
                       source: Sources::Field.new(names.(:bench), :signal),
                       display: Displays::Prose.new(Bench::SIGNALS.values))
      end
    end

    # At `Operations` level, because `register` is a method on this module.
    register(OpenPit::TYPE,
             chassis: OpenPit::CHASSIS.keys,
             assembler: lambda { |chassis, loadout|
               OpenPit.assembly_for(chassis || OpenPit::CHASSIS.keys.first, loadout || {})
             }) do |id:, seed:, time_scale: OpenPit::DEFAULT_TIME_SCALE, state: nil, rngs: nil, content: nil,
                    chassis: OpenPit::CHASSIS.keys.first, loadout: {}, crew: {}, ground: nil, conditions: nil,
                    grudges: nil, wounds: nil|
      OpenPit.build(id: id, seed: seed, chassis: chassis, loadout: loadout, crew: crew, ground: ground,
                    conditions: conditions, grudges: grudges, wounds: wounds, time_scale: time_scale, state: state,
                    rngs: rngs, content: content)
    end
  end
end
