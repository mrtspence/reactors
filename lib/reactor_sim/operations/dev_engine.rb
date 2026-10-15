# frozen_string_literal: true

module ReactorSim
  module Operations
    # **A developer's engine**: a shaft held at working speed by whatever torque that takes, up to
    # a power set by two levers — `setting × 10^range` watts, from 1 kW to 1 GW. Nobody tends it,
    # nothing on it wears, and it never runs short of steam, so a machine roped to it can be
    # tested without first raising steam on a real one.
    #
    # Registered as a harness, so it is never a blueprint and no player can own one. The dev match
    # fits it only when a developer asks (`DevMatch.dev_engine?`).
    #
    # Its power is injected and ledgered like a heater's (`joules_injected`), so the books close.
    # What crosses a rope is still the rope's to decide: the far end's `rope_conductance` caps the
    # torque it will take, so past what that end is rated for, more power changes nothing.
    module DevEngine
      TYPE = :dev_engine

      # The mine's line shaft speed, so it ropes to a pit at 1:1.
      RATED_OMEGA = 22.0
      LEAST_W = 1.0e3
      MOST_W = 1.0e9

      class Drive < ReactorSim::Node
        include Concerns::Rotating
        include Concerns::Roped

        # Heavy enough that a rope at any line shaft's conductance is far inside its `I/dt`.
        MOMENT_OF_INERTIA = 2_000.0

        def initialize(id:, label: nil)
          super(id: id, label: label)
          freeze
        end

        def moment_of_inertia = MOMENT_OF_INERTIA
        def initial_omega = RATED_OMEGA
        def control_id = nil
        def rope_capacity_joules = MOST_W * 10.0

        def setting_w(controls)
          watts = controls.fetch(:setting, 0.0) * (10.0**controls.fetch(:range, 0.0))
          watts.clamp(LEAST_W, MOST_W)
        end

        # Tops its buffer up to one tick's worth at the set power, and asks for the torque that
        # puts the shaft back at speed or spends the buffer, whichever is less. Sized by energy
        # rather than by the speed gap, because `Tick#transmit_torque` scaling a larger impulse
        # back to the buffer delivers less than the buffer.
        def apply(state, ctx, _grant)
          set = setting_w(ctx.controls)
          topped = [ (set * ctx.dt) - supply_joules(state), 0.0 ].max
          budget = supply_joules(state) + topped
          w = omega(state)
          reached = [ Math.sqrt((w * w) + (2.0 * budget / MOMENT_OF_INERTIA)), RATED_OMEGA ].min

          state.merge(supply_joules: budget, joules_injected: topped,
                      torque: reached > w ? MOMENT_OF_INERTIA * (reached - w) / ctx.dt : 0.0,
                      setting_w: set, work_joules: 0.0, shaft_power_w: 0.0)
        end

        def drag_conductances(state, ctx)
          super.merge(rope_drags(state, ctx)) { |_, a, b| a + b }
        end
      end

      module_function

      def build(id:, seed:, time_scale: 1.0, state: nil, rngs: nil, content: nil)
        Operation.new(
          id: id, type: TYPE, seed: seed, time_scale: time_scale,
          state: state, rngs: rngs, content: content,
          nodes: [ Drive.new(id: :drive, label: "Dev Engine") ],
          control_points: control_points, diagnostics: diagnostics
        )
      end

      def control_points
        [
          ControlPoint.new(id: :range, label: "Range (×10ⁿ W)", node: :drive,
                           min: 1.0, max: 7.0, default: 4.0, unit: ""),
          ControlPoint.new(id: :setting, label: "Setting", node: :drive,
                           min: 1.0, max: 100.0, default: 10.0, unit: "")
        ]
      end

      # True figures, unfiltered: this is a developer's meter, not an instrument.
      def diagnostics
        [
          Diagnostic.new(id: :set_power, label: "Set Power",
                         source: Sources::Field.new(:drive, :setting_w),
                         display: Displays::Digital.new(unit: "kW", precision: 1, convert: :kilo)),
          Diagnostic.new(id: :shaft_power, label: "Shaft Power",
                         source: Sources::Field.new(:drive, :shaft_power_w),
                         display: Displays::Digital.new(unit: "kW", precision: 1, convert: :kilo)),
          Diagnostic.new(id: :shaft_speed, label: "Shaft Speed",
                         source: Sources::Derived.new(:drive, :omega),
                         display: Displays::Digital.new(unit: "rad/s", precision: 2))
        ]
      end
    end

    register(DevEngine::TYPE, harness: true) do |id:, seed:, time_scale: 1.0, state: nil,
                                                 rngs: nil, content: nil|
      DevEngine.build(id: id, seed: seed, time_scale: time_scale, state: state, rngs: rngs,
                      content: content)
    end
  end
end
