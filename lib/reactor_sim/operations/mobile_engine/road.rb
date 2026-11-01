# frozen_string_literal: true

module ReactorSim
  module Operations
    module MobileEngine
      # **Two trains on one road**: they share a single track out to the dump and pass in a loop by
      # the shovel, and the road past `main_from_m` is one train's at a time. Each driver's round
      # (`Round#road`) waits in the loop while the other train has the shovel, and goes out onto the
      # road only when it reads clear.
      #
      # **What tells him it is clear is the signalling**, a node of its own reading the trains a
      # tick old and writing `clear`, train by train, as its kind does:
      #
      # - `:flagman`: a post at the loop waving them on. With nobody posted it says nothing (`nil`),
      #   and each driver goes on his own look. Out of his depth he waves one on with the road taken
      #   (`judged: :wrongly`, a mishap on this node: `false_clear_s`).
      # - `:staff`: one staff for the road; only the train holding it may go out, and it is handed
      #   over in the loop, both trains standing, which takes `HANDOVER_S`. Never wrong, and slow.
      # - `:block`: track circuits, true to where the trains are. They wear while a train is on the
      #   road, and worn through stick at clear (`stuck_clear`), the wrong-side failure.
      #
      # It writes **the road's board** (`signal`).
      #
      #   state: clear, false_clear_s, holder, handover_s, waiting, signal, durability, failure
      class RoadSignal < Node
        include Concerns::Wearing

        SIGNALS = {
          stuck_clear: "signals stuck at clear",
          waved_on: "waved on with the road taken",
          own_look: "no flagman — the drivers' own look",
          handing_over: "handing over the staff",
          on_the_road: "a train on the road",
          clear: "road clear"
        }.freeze

        KINDS = %i[flagman staff block].freeze

        FALSE_CLEAR_S = 20.0
        HANDOVER_S = 30.0

        # Durability a second with a train on the road: hours of it, against
        # `Wearing::DEFAULT_DURABILITY_RANGE`.
        BLOCK_WEAR_PER_S = 0.08

        attr_reader :kind, :trains, :main_from_m, :flagman, :perils

        # `trains:` the two trains, the first having the shovel when both want it; `main_from_m` where
        # the single road begins; `flagman:` his post, for a `:flagman`.
        def initialize(id:, kind:, trains:, main_from_m:, flagman: nil, perils: [], label: "Road Signals")
          super(id: id, label: label)
          @kind = kind.to_sym
          raise Error, "road signal #{id}: kind #{kind.inspect} is none of #{KINDS.inspect}" unless KINDS.include?(@kind)

          @trains = trains.map(&:to_sym).freeze
          @main_from_m = main_from_m.to_f
          @flagman = flagman&.to_sym
          @perils = perils.freeze
          freeze
        end

        def base_initial_state(_rng, _content)
          { clear: @trains.to_h { |train| [ train, true ] }, false_clear_s: 0.0, holder: @trains.first, handover_s: 0.0,
            waiting: false, signal: SIGNALS.keys.index(:clear) }
        end

        def suffers?(kind) = kind == :false_clear || super

        def suffer(state, mishap, ctx)
          return super unless mishap.fetch(:kind) == :false_clear

          [ state.merge(false_clear_s: FALSE_CLEAR_S), [] ]
        end

        def stress_per_second(_state, ctx) = @kind == :block && @trains.any? { |t| on_the_road?(t, ctx) } ? BLOCK_WEAR_PER_S : 0.0

        # Only track circuits wear, so only they ever come to this.
        def failure_modes = { stuck_clear: {} }

        def failure_mode(_state, _ctx, _cause) = :stuck_clear

        def apply(state, ctx, _grant)
          state = handed_over(state, ctx)
          clear = @trains.to_h { |train| [ train, reading(state, ctx, train) ] }
          state = state.merge(clear: clear, false_clear_s: [ state.fetch(:false_clear_s) - ctx.dt, 0.0 ].max,
                              waiting: @trains.any? { |t| waiting?(t, ctx) })
          state.merge(signal: SIGNALS.keys.index(signal(state, ctx)))
        end

        # A train standing in the loop to go out, with the road taken: a moment to get it wrong.
        def activity(state, quantity, _dt) = quantity == :waving ? (state.fetch(:waiting) ? 1.0 : 0.0) : nil

        def on_the_road?(train, ctx) = position(train, ctx) >= @main_from_m

        def other(train) = (@trains - [ train ]).first

        private

        def position(train, ctx) = ctx.nodes[train].position_m(ctx.node_state(train) || {}, ctx.content)

        def standing?(train, ctx) = ctx.nodes[train].standing?(ctx.node_state(train))

        def waiting?(train, ctx) = !on_the_road?(train, ctx) && standing?(train, ctx) && on_the_road?(other(train), ctx)

        def reading(state, ctx, train)
          truth = !on_the_road?(other(train), ctx)
          case @kind
          when :flagman
            return nil unless ctx.controls.fetch(@flagman, 0.0).positive?

            truth || state.fetch(:false_clear_s).positive?
          when :staff then state.fetch(:holder) == train
          when :block then state[:failure] == :stuck_clear || truth
          end
        end

        # **The staff changes hands in the loop**, both trains standing off the road, to the one
        # nearer the shovel, which goes out next.
        def handed_over(state, ctx)
          return state unless @kind == :staff

          holder = state.fetch(:holder)
          nearer = @trains.min_by { |train| [ position(train, ctx), @trains.index(train) ] }
          both_in = @trains.none? { |t| on_the_road?(t, ctx) } && @trains.all? { |t| standing?(t, ctx) }
          return state.merge(handover_s: 0.0) unless both_in && nearer != holder

          held = state.fetch(:handover_s) + ctx.dt
          held >= HANDOVER_S ? state.merge(holder: nearer, handover_s: 0.0) : state.merge(handover_s: held)
        end

        def signal(state, ctx)
          return :stuck_clear if state[:failure] == :stuck_clear
          return :waved_on if state.fetch(:false_clear_s).positive?
          return :own_look if @kind == :flagman && state.fetch(:clear).values.all?(&:nil?)
          return :handing_over if state.fetch(:handover_s).positive?

          @trains.any? { |t| on_the_road?(t, ctx) } ? :on_the_road : :clear
        end
      end
    end
  end
end
