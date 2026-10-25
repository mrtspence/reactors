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
          tipping: "tipping",
          waiting_on_dumpmen: "at the dump — waiting on the dumpmen",
          tipped: "tipped",
          running_loaded: "running loaded",
          running_empty: "running empty",
          stopped: "stopped on the road"
        }.freeze

        attr_reader :moment_of_inertia, :radius_m, :friction, :tare_kg, :load_kg, :rated_m_s, :track, :cars,
                    :brake, :engine, :loader, :tipper, :demand_control, :perils, :failure_hazards, :failure_damages

        # `tare_kg` is the engine and the empty cars, `load_kg` what the cars carry full. `loader:` and
        # `tipper:` are the landings at the loading and dump marks, which the board reads; `engine:`
        # the pieces `EngineBoard` reads; `demand_control:` the driver's post.
        def initialize(id:, tare_kg:, load_kg:, radius_m:, rated_m_s:, track:, cars:, brake:, engine:, loader:, tipper:,
                       demand_control:, position_m: nil, endangers: {}, damages: {}, perils: [], label: "Train")
          super(id: id, label: label)
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
          super.merge(position_m: @position_m, load_torque: 0.0, signal: 0)
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
          return drags unless onto_buffer?(state)

          drags.merge(friction: drags.fetch(:friction, 0.0) + (moment_of_inertia / ctx.dt * Nodes::Brake::LOCK_MULTIPLE))
        end

        def apply(state, ctx, _grant)
          settled = state.merge(position_m: position_m(state) + (speed_m_s(state) * ctx.dt))
          settled = settled.merge(load_torque: drive_torque(settled, ctx))
          settled.merge(signal: SIGNALS.keys.index(signal(settled, ctx)))
        end

        # How hard she is moving through `place`, for a peril of somebody working there: nothing
        # standing or elsewhere. A quantity that is not one of the track's places is not hers.
        def activity(state, quantity, _dt)
          return nil unless @track.places.include?(quantity)
          return 0.0 if standing?(state) || place_at(state) != quantity

          (speed_m_s(state).abs / @rated_m_s).clamp(0.0, 1.0)
        end

        # --- the ends, and the rails ------------------------------------------------

        def overload?(state, _ctx, _integrity) = derailing?(state) || into_the_end?(state)

        # Ascending severity.
        def failure_modes = { derailed: {}, crashed: {}, over_the_tip: {} }

        def failure_mode(state, _ctx, _cause)
          return :crashed if position_m(state) <= 0.0 && into_the_end?(state)
          return :over_the_tip if position_m(state) >= @track.length_m && into_the_end?(state)

          :derailed
        end

        def failure_detail(state, _ctx)
          { speed_m_s: speed_m_s(state).abs.round(2), position_m: position_m(state).round(1) }
        end

        private

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
          return (carried.(@loader) || loaded?(ctx) ? :loading : :waiting_on_shovel) if at.(:loading)
          return :tipped if at.(:dump) && !loaded?(ctx)
          return (carried.(@tipper) ? :tipping : :waiting_on_dumpmen) if at.(:dump)

          :stopped
        end
      end
    end
  end
end
