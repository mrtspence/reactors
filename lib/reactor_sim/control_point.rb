# frozen_string_literal: true

module ReactorSim
  # A lever, and the gap between what was asked for and what has actually happened. `target` is
  # what the command set; `actual` is where the lever really is.
  #
  # The separation protects the Kafka ingress design: commands set `target` and nothing else — an
  # absolute, clamped, idempotent write — so replaying "target = 85" twice is indistinguishable
  # from once, at-least-once delivery stays harmless, and offsets can be committed after
  # snapshotting. Everything else happens inside the tick; entropy drawn during command
  # application would make replay diverge.
  class ControlPoint
    attr_reader :id, :label, :node, :min, :max, :default, :unit, :stiffness, :effort, :aided_by,
                :exertion, :recovery

    # **A valve is not a job, and that distinction is what makes a crew matter.** Most controls
    # are valves: a regulator goes where you put it and who put it there is irrelevant. A few are
    # **effort** — stoking is not a setting, it is somebody shovelling — and for those the lever
    # is the player's *intent* while what gets done depends on who is doing it.
    #
    # `effort:` is a **weighted blend of stats**, because almost no real job draws on exactly one:
    # shovelling is mostly back and a little placement. `aided_by:` names the tag that helps at
    # this job specifically, so a shovel counts for shovelling and not for reading a gauge.
    #
    # **The weights must sum to 1.0**, which keeps "a fit, unaided human scores 1.0" true at every
    # station — and therefore lets a node's declared throughput mean "what a competent person
    # achieves". A blend summing to anything else silently rescales that station against every
    # other. `Tick#control_values` multiplies the lever's position by what the minion posted here
    # can manage; **nobody posted means nothing gets done.**
    #
    # > **`stiffness` is the wrong lever for this.** A stiff work station means a weak minion
    # > takes longer to reach full effort and then delivers exactly as much as a strong one — so
    # > a kobold with no shovel would eventually equal an ogre with a specialised tool. Stiffness
    # > is a derivative; capability is the rate itself.
    #
    # `stiffness` remains, unused by any shipped control, for a lever that should genuinely take
    # time to travel. Infinite means frictionless — `actual` snaps to `target`.
    # **`exertion:` is what this job costs, and it belongs here for the same reason `effort:`
    # does** — the machine is what knows that shovelling is not watching a gauge. It is fatigue
    # per second for a competent, unaided human with the lever hard over, so its reciprocal reads
    # as "flat out, spent in": the stoker's `8.3e-4` is twenty minutes.
    #
    # `recovery:` is the other direction and is a property of *where somebody is standing* rather
    # than what they are doing. An effort station recovers nothing, because you are still at the
    # fire; a valve is somewhere to stand down to. Both apply every tick and net out, which is
    # what keeps light work sustainable without a special case at zero demand.
    def initialize(id:, label: nil, node: nil, min: 0.0, max: 100.0, default: 0.0,
                   unit: "%", stiffness: Float::INFINITY, effort: nil, aided_by: nil,
                   exertion: 0.0, recovery: nil)
      @id = id.to_sym
      @label = label || @id.to_s.tr("_", " ").capitalize
      @node = node&.to_sym
      @min = min.to_f
      @max = max.to_f
      @default = default.to_f
      @unit = unit
      @stiffness = stiffness
      @effort = effort&.to_h { |stat, weight| [ stat.to_sym, weight.to_f ] }&.freeze
      @aided_by = aided_by&.to_sym
      @exertion = exertion.to_f
      @recovery = (recovery || (effort ? 0.0 : Fatigue::BASE_RECOVERY)).to_f
      validate_effort!
      validate_fatigue!
      freeze
    end

    # Work somebody does, as opposed to a setting somebody chooses.
    def effort? = !@effort.nil?

    # **Something a player can move, as opposed to somewhere a person can stand.** Every station
    # is a control point — that is what `station_index`, `endangers:` and fatigue all resolve
    # through — but the crew quarters controls nothing, so it has no `node:` and belongs on the
    # crew screen rather than the lever strip. Derived rather than declared, because a lever with
    # nothing on the other end of it is not a lever by construction.
    def lever? = !@node.nil?

    # The lever as a 0..1 fraction of its travel, which is what `intent ÷ capability` needs — a
    # station's raw units are its own business and would make `exertion:` mean something different
    # at every control.
    def demand(state)
      span = @max - @min
      return 0.0 unless span.positive?

      ((value(state) - @min) / span).clamp(0.0, 1.0)
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

    private

    # Both failures here are the silent kind. A stat the sheet does not carry is a station
    # nobody can ever be good at; weights that do not sum to 1.0 rescale this station against
    # every other one, so its node's throughput quietly stops meaning "what a competent person
    # achieves". Each would read as a balance problem rather than as a typo.
    def validate_effort!
      return if @effort.nil?

      unknown = @effort.keys - Sheet::STATS
      raise Error, "control #{@id}: unknown effort stat(s) #{unknown.join(', ')}" if unknown.any?

      total = @effort.values.sum
      return if (total - 1.0).abs <= 1e-9

      raise Error, "control #{@id}: effort weights sum to #{total}, not 1.0"
    end

    # Both of these are the silent kind too. A negative rate runs the arithmetic backwards —
    # exertion that rests people, recovery that tires them — and an exertion on a valve is a job
    # nobody is doing, because `Fatigue.accrual` only ever charges an effort station.
    def validate_fatigue!
      raise Error, "control #{@id}: exertion #{@exertion} is negative" if @exertion.negative?
      raise Error, "control #{@id}: recovery #{@recovery} is negative" if @recovery.negative?
      return if @exertion.zero? || effort?

      raise Error, "control #{@id}: exertion declared on a control with no effort:"
    end
  end
end
