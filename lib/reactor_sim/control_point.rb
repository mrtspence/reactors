# frozen_string_literal: true

module ReactorSim
  # A lever, and the gap between what was asked for and what has actually happened.
  #
  # `target` is what the command set. `actual` is where the lever really is. In v0 these
  # were the same number; they are separate now because a minion stands between the two,
  # and a stiff valve takes several ticks to traverse (docs/simulation_architecture.md §7).
  #
  # The separation is also what protects the Kafka ingress design. Commands set `target`
  # and nothing else — an absolute, clamped, idempotent write. Replaying "target = 85"
  # twice is indistinguishable from once, so at-least-once delivery stays harmless and
  # offsets can still be committed after snapshotting. All minion movement and every
  # mishap roll happens inside the tick, never during command application; entropy drawn
  # in `apply` would make replay diverge.
  class ControlPoint
    attr_reader :id, :label, :node, :min, :max, :default, :unit, :stiffness

    # `stiffness` is how hard the lever is to move, in units of range per simulated second
    # at unit strength. Infinite means frictionless — the actual snaps to the target, which
    # is the correct default until minions exist.
    def initialize(id:, label: nil, node: nil, min: 0.0, max: 100.0, default: 0.0,
                   unit: "%", stiffness: Float::INFINITY)
      @id = id.to_sym
      @label = label || @id.to_s.tr("_", " ").capitalize
      @node = node&.to_sym
      @min = min.to_f
      @max = max.to_f
      @default = default.to_f
      @unit = unit
      @stiffness = stiffness
      freeze
    end

    def initial_state(_rng) = { target: @default, actual: @default }

    # Out-of-range values are clamped rather than rejected: a command that arrives late, or
    # from a stale client, should still land somewhere sane.
    def set_target(state, value)
      state.merge(target: value.to_f.clamp(@min, @max))
    end

    # Phase 0. Converge the actual toward the target at whatever rate the operator can
    # manage. Deterministic; any mishap entropy belongs to the minion, drawn here.
    def actuate(state, dt:, rate_multiplier: 1.0)
      target = state.fetch(:target)
      actual = state.fetch(:actual)
      return state if (target - actual).abs <= Float::EPSILON

      return state.merge(actual: target) if @stiffness.infinite?

      step = @stiffness * rate_multiplier * dt * (@max - @min) / 100.0
      state.merge(actual: actual + (target - actual).clamp(-step, step))
    end

    def value(state) = state.fetch(:actual)
    def target(state) = state.fetch(:target)

    # True while the lever is still travelling — worth surfacing, since "the valve is not
    # where you asked for yet" is information the player needs.
    def settling?(state) = (state.fetch(:target) - state.fetch(:actual)).abs > Float::EPSILON
  end
end
