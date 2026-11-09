# frozen_string_literal: true

module ReactorSim
  module Operations
    module MobileEngine
      # **Where a train runs**: sections end to end from the loading end, each with the place it runs
      # through and its grade (rise over run, positive towards the far end), and the marks a train
      # stands at. The host's — the pit's geometry — handed to the train as configuration.
      Track = Struct.new(:sections, :marks, keyword_init: true) do
        def initialize(sections:, marks:)
          sections = sections.map { |s| { to_m: s.fetch(:to_m).to_f, place: s.fetch(:place).to_sym, grade: s.fetch(:grade, 0.0).to_f }.freeze }
          super(sections: sections.freeze, marks: marks.transform_values(&:to_f).freeze)
          freeze
        end

        def length_m = sections.last.fetch(:to_m)

        def mark(name) = marks.fetch(name)

        def places = sections.map { |s| s.fetch(:place) }.uniq

        def section_at(position_m) = sections.find { |s| position_m <= s.fetch(:to_m) } || sections.last

        def grade_at(position_m) = section_at(position_m).fetch(:grade)

        def place_at(position_m) = section_at(position_m).fetch(:place)
      end

      # **A train on its track: the winding drum laid flat.** The wheels are the shaft — positive `ω`
      # runs towards the far end — and the train's speed is their rim speed. `position_m` is
      # integrated off it, and the cars (`cars:`, a holder riding the train) are load like a cage's
      # deck. See `docs/design_sketches/locomotive.md` §2.
      #
      # **Gravity on the grade is a torque source in the drive solve**, as the hoist's is, so a brake
      # holds a train on a bank in the same step; its work is booked as it is done and nothing stores
      # potential energy. Rolling resistance is the wheels' friction.
      #
      # **Its inertia is fixed**, at the tare and half a load, while the grade and the rolling read
      # the true mass: wrong about how fast things happen, never about whether a brake holds.
      #
      # **The ends of the track** stop a train gently — a buffer, as a drag — and past `BUFFER_M_S`
      # do not: into the shovel at the loading end (`crashed`), over the edge at the tip (`over_the_tip`).
      # Past `DERAIL_SHARE` of its rated speed anywhere it leaves the rails (`derailed`). Decided by
      # speed and position, not a die; any of them ends its match.
      #
      # It answers `place_at` for the footplate it carries (`Place#carried_by`), `standing_at?` for a
      # landing, and writes **its board** (`signal`) from its own last tick and its engine's.
      class Train < Node
        include Concerns::Rotating
        include Concerns::Wearing
        include EngineBoard

        # Close enough to a mark, and slow enough, to call the train standing there.
        STANDING_M = 1.5
        STOPPED_M_S = 0.2

        # Faster than this a buffer stop does not stop her.
        BUFFER_M_S = 1.5
        DERAIL_SHARE = 1.6

        # Rolling resistance as a share of the weight at running speed.
        ROLLING = 0.003

        # Cars holding less than this are empty.
        EMPTY_KG = 1.0

        # The first that holds, in order.
        SIGNALS = {
          collided: "collided with the other train",
          crashed: "crashed into the shovel",
          over_the_tip: "over the tip",
          derailed: "off the road",
          brake_gone: "brake gone",
          standing: "standing — fire out",
          out_of_water: "out of water",
          short_of_water: "short of water",
          short_of_steam: "short of steam",
          standing_by: "standing by",
          blowing_off: "standing by — blowing off",
          loading: "loading",
          waiting_on_shovel: "at the shovel — nothing coming",
          waiting_on_road: "loaded — waiting on the road",
          in_the_loop: "in the loop — waiting on the shovel",
          tipping: "tipping",
          waiting_on_dumpmen: "at the dump — waiting on the dumpmen",
          at_the_stand: "at the stand — taking coal and water",
          stand_empty: "at the stand — nothing to take",
          tipped: "tipped",
          running_loaded: "running loaded",
          running_empty: "running empty",
          stopped: "stopped on the road"
        }.freeze
        # Her round going as it should (`Displays::Prose.signals`).
        CALM = %i[standing_by blowing_off loading waiting_on_road in_the_loop tipping at_the_stand tipped
                  running_loaded running_empty].freeze

        attr_reader :moment_of_inertia, :radius_m, :friction, :tare_kg, :load_kg, :rated_m_s, :track, :cars,
                    :brake, :engine, :loader, :tipper, :demand_control, :perils, :failure_hazards, :failure_damages

        # `tare_kg` is the engine and the empty cars, `load_kg` what the cars carry full. `loader:` and
        # `tipper:` are the landings at the loading and dump marks, which the board reads; `engine:`
        # the pieces `EngineBoard` reads; `demand_control:` the driver's post. `stand:` is the stand's
        # landings at the dump, `{ landing => its valve }`, which the board reads. `road:` is the other
        # train on its road and where the road begins (`{ other:, main_from_m:, signal: }`), which it
        # can collide with and its driver looks out for.
        def initialize(id:, tare_kg:, load_kg:, radius_m:, rated_m_s:, track:, cars:, brake:, engine:, loader:, tipper:,
                       demand_control:, position_m: nil, endangers: {}, damages: {}, perils: [], stand: {}, road: nil,
                       label: "Train")
          super(id: id, label: label)
          @stand = stand.to_h { |landing, valve| [ landing.to_sym, valve.to_sym ] }.freeze
          @road = road && { other: road.fetch(:other).to_sym, main_from_m: road.fetch(:main_from_m).to_f,
                            signal: road[:signal]&.to_sym }.freeze
          @tare_kg = tare_kg.to_f
          @load_kg = load_kg.to_f
          @radius_m = radius_m.to_f
          @rated_m_s = rated_m_s.to_f
          @track = track
          @cars = cars.to_sym
          @brake = brake.to_sym
          @engine = engine.freeze
          @loader = loader.to_sym
          @tipper = tipper.to_sym
          @demand_control = demand_control.to_sym
          @position_m = (position_m || track.mark(:loading)).to_f
          @perils = perils.freeze
          @failure_hazards = endangers.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          @failure_damages = damages.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
          @moment_of_inertia = (@tare_kg + (@load_kg / 2.0)) * (@radius_m**2)
          @friction = ROLLING * (@tare_kg + (@load_kg / 2.0)) * Units::GRAVITY_M_PER_S2 * (@radius_m**2) / @rated_m_s
          freeze
        end

        def base_initial_state(rng, content)
          super.merge(position_m: @position_m, load_torque: 0.0, signal: 0,
                      **(@road ? { misjudged_s: 0.0, own_look: false } : {}))
        end

        # **Two trains closer than this on the road are touching**: past `BUFFER_M_S` closing, they
        # have collided, and below it they buffer up. A fiat for now, and both trains go.
        #
        # TODO: derailment, the wreck lying across the road, and a gang to clear it — the first
        # caller of a road that can be blocked by something other than a train.
        TOUCHING_M = 8.0

        # A driver who misjudges the road believes it clear this long.
        MISJUDGED_S = 20.0

        def suffers?(kind) = kind == :misjudged_road || super

        def suffer(state, mishap, ctx)
          return super unless mishap.fetch(:kind) == :misjudged_road

          [ state.merge(misjudged_s: MISJUDGED_S), [] ]
        end

        def position_m(state, _content = nil) = state.fetch(:position_m)

        def speed_m_s(state) = omega(state) * @radius_m

        def standing_at?(state, mark_m)
          (position_m(state) - mark_m).abs < STANDING_M && speed_m_s(state).abs < STOPPED_M_S
        end

        def standing?(state) = speed_m_s(state).abs < STOPPED_M_S

        # The place the train is in, for the footplate it carries.
        def place_at(state) = @track.place_at(position_m(state))

        def cars_kg(ctx) = Parcel.total_kg((ctx.node_state(@cars) || {}).fetch(:parcels, []))

        def mass_kg(ctx) = @tare_kg + cars_kg(ctx)

        def loaded?(ctx) = cars_kg(ctx) > EMPTY_KG

        # Gravity along the grade where she stands, at the wheels.
        def drive_torque(state, ctx)
          return 0.0 if broken?(state)

          -Units::GRAVITY_M_PER_S2 * @radius_m * mass_kg(ctx) * @track.grade_at(position_m(state))
        end

        # What a brake on the wheels has to hold, as of last tick.
        def load_torque(state, _content = nil) = state.fetch(:load_torque, 0.0)

        # The rolling, and a buffer stop at either end taking a train that comes onto it gently.
        def drag_conductances(state, ctx)
          drags = super
          return drags unless onto_buffer?(state) || closing_m_s(state, ctx).positive?

          drags.merge(friction: drags.fetch(:friction, 0.0) + (moment_of_inertia / ctx.dt * Nodes::Brake::LOCK_MULTIPLE))
        end

        def apply(state, ctx, _grant)
          settled = state.merge(position_m: position_m(state) + (speed_m_s(state) * ctx.dt))
          settled = settled.merge(load_torque: drive_torque(settled, ctx))
          settled = settled.merge(misjudged_s: [ settled.fetch(:misjudged_s) - ctx.dt, 0.0 ].max, own_look: own_look?(settled, ctx)) if @road
          settled.merge(signal: SIGNALS.keys.index(signal(settled, ctx)))
        end

        # How hard she is moving through `place`, for a peril of somebody working there: nothing
        # standing or elsewhere. A quantity that is not one of the track's places is not hers.
        # `:own_look` is her driver looking up the road with nothing to tell him, loaded to go.
        def activity(state, quantity, _dt)
          return (state.fetch(:own_look, false) ? 1.0 : 0.0) if quantity == :own_look
          return nil unless @track.places.include?(quantity)
          return 0.0 if standing?(state) || place_at(state) != quantity

          (speed_m_s(state).abs / @rated_m_s).clamp(0.0, 1.0)
        end

        # --- the ends, and the rails ------------------------------------------------

        def overload?(state, ctx, _integrity) = derailing?(state) || into_the_end?(state) || closing_m_s(state, ctx) > BUFFER_M_S

        # Ascending severity.
        def failure_modes = { derailed: {}, collided: {}, crashed: {}, over_the_tip: {} }

        def failure_mode(state, ctx, _cause)
          return :collided if closing_m_s(state, ctx) > BUFFER_M_S
          return :crashed if position_m(state) <= 0.0 && into_the_end?(state)
          return :over_the_tip if position_m(state) >= @track.length_m && into_the_end?(state)

          :derailed
        end

        def failure_detail(state, _ctx)
          { speed_m_s: speed_m_s(state).abs.round(2), position_m: position_m(state).round(1) }
        end

        # **How fast she is closing on the other train**, both out on the road and touching, from
        # the other's last tick; zero when they are not. Both read each other the same tick, so both
        # see it.
        def closing_m_s(state, ctx)
          return 0.0 unless @road && position_m(state) >= @road.fetch(:main_from_m)

          other = ctx.node_state(@road.fetch(:other)) or return 0.0
          gap = ctx.nodes[@road.fetch(:other)].position_m(other) - position_m(state)
          return 0.0 if gap.abs > TOUCHING_M || ctx.nodes[@road.fetch(:other)].position_m(other) < @road.fetch(:main_from_m)

          closing = (speed_m_s(state) - ctx.nodes[@road.fetch(:other)].speed_m_s(other)) * (gap.negative? ? -1.0 : 1.0)
          [ closing, 0.0 ].max
        end

        private

        # Loaded and standing in the loop to go out, the other train on the road, and nothing telling
        # her driver whether it is clear.
        def own_look?(state, ctx)
          return false unless standing?(state) && loaded?(ctx) && position_m(state) < @road.fetch(:main_from_m)
          return false if @road[:signal] && !(ctx.node_state(@road.fetch(:signal)) || {}).dig(:clear, id).nil?

          other = ctx.node_state(@road.fetch(:other)) or return false
          ctx.nodes[@road.fetch(:other)].position_m(other) >= @road.fetch(:main_from_m)
        end

        def derailing?(state) = speed_m_s(state).abs > DERAIL_SHARE * @rated_m_s

        def into_the_end?(state)
          speed = speed_m_s(state)
          (position_m(state) <= 0.0 && speed < -BUFFER_M_S) || (position_m(state) >= @track.length_m && speed > BUFFER_M_S)
        end

        def onto_buffer?(state)
          speed = speed_m_s(state)
          (position_m(state) <= 0.0 && speed.negative?) || (position_m(state) >= @track.length_m && speed.positive?)
        end

        def signal(state, ctx)
          return state[:failure] if state[:failure]
          return :brake_gone if (ctx.node_state(@brake) || {})[:failure] == :rod_parted

          # Lifting her valve is no reason she is not working, so it shows only while she stands by.
          engine = engine_signal(ctx)
          return engine if engine && engine != :blowing_off

          round = round_signal(state, ctx)
          round == :standing_by && engine ? engine : round
        end

        def round_signal(state, ctx)
          return :standing_by unless ctx.controls.fetch(@demand_control, 0.0).positive?
          return (loaded?(ctx) ? :running_loaded : :running_empty) unless standing?(state)

          at = ->(mark) { (position_m(state) - @track.mark(mark)).abs < STANDING_M }
          carried = ->(landing) { (ctx.node_state(landing) || {}).fetch(:carried_kg, 0.0).positive? }
          # A dipperful lands in a tick, so a train with something in her is loading between them.
          return loading_signal(ctx, carried) if at.(:loading)
          return :in_the_loop if @road && at.(:passing)
          return stand_signal(ctx, carried) if at.(:dump) && !loaded?(ctx)
          return (carried.(@tipper) ? :tipping : :waiting_on_dumpmen) if at.(:dump)

          :stopped
        end

        def loading_signal(ctx, carried)
          return :loading if carried.(@loader)
          return :waiting_on_shovel unless loaded?(ctx)

          other = @road && ctx.node_state(@road.fetch(:other))
          on_road = other && ctx.nodes[@road.fetch(:other)].position_m(other) >= @road.fetch(:main_from_m)
          on_road ? :waiting_on_road : :loading
        end

        # Tipped: being topped up, or waiting on a stand with nothing in it.
        def stand_signal(ctx, carried)
          calling = @stand.select { |_, valve| ctx.controls.fetch(valve, 0.0).positive? }
          return :tipped if calling.empty?

          calling.keys.any? { |landing| carried.(landing) } ? :at_the_stand : :stand_empty
        end
      end
    end
  end
end
