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
    # How often somebody who simply is not sharp gets a job wrong, per second, at any lever at
    # all — about once every two minutes, which is frequent enough to be a character trait and
    # rare enough not to be a disability.
    BONEHEADED_PER_S = 0.008

    # And how often somebody out of their depth does, per second per point of shortfall.
    BEYOND_PER_S = 0.02

    # What working an uncertificated post is worth: the job is twice as far beyond you as it
    # would be with the ticket in your pocket.
    UNTICKETED = 2.0

    attr_reader :id, :label, :node, :min, :max, :default, :unit, :stiffness, :effort, :aided_by,
                :exertion, :recovery, :place, :gated_by, :capacity, :complexity, :requires

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
    # `stiffness` is for a lever that genuinely takes time to travel, in percent of its range per
    # second, scaled by whoever is stood there. The mine's valves ship finite figures; infinite
    # means frictionless, and `actual` snaps to `target`.
    # **`exertion:` is what this job costs, and it belongs here for the same reason `effort:`
    # does** — the machine is what knows that shovelling is not watching a gauge. It is fatigue
    # per second for a competent, unaided human with the lever hard over, so its reciprocal reads
    # as "flat out, spent in": the stoker's `8.3e-4` is twenty minutes.
    #
    # `recovery:` is the other direction and is a property of *where somebody is standing* rather
    # than what they are doing. An effort station recovers nothing, because you are still at the
    # fire; a valve is somewhere to stand down to. Both apply every tick and net out, which is
    # what keeps light work sustainable without a special case at zero demand.
    # `place:` is **where this lever stands** — a place id in the operation's `Layout` — and is
    # what makes manning it cost a walk. Nil means it can be worked from anywhere, which is every
    # control in an operation that declares no passages at all.
    # `capacity:` is **how many people this station has room for**, and nil — every lever in the
    # game but one — means it does not care. A hole cut in a roadway side takes one man, and a
    # bigger one is something a mine buys, so the number is a part's stat rather than a rule.
    # `Operation#assign_minion` refuses a posting past it, the way it refuses one nobody can
    # walk to.
    # `complexity:` is **how tricky this lever is to work correctly**, and is the exact parallel
    # to `effort:` — deliberately orthogonal to it. `effort:` says how *fast* a job happens and
    # therefore depends on who does it; `complexity:` says whether it happens *correctly*. A
    # strong idiot stokes perfectly well and sets the cut-off wrong, and with `effort:` alone he
    # would be good at both.
    #
    # `requires:` names the tag a certificated post wants. Lacking it never forbids the posting
    # — a player may always put the wrong person on anything — it makes them likelier to get it
    # wrong, which is what a ticket actually buys.
    def initialize(id:, label: nil, node: nil, min: 0.0, max: 100.0, default: 0.0,
                   unit: "%", stiffness: Float::INFINITY, effort: nil, aided_by: nil,
                   exertion: 0.0, recovery: nil, place: nil, gated_by: nil, capacity: nil,
                   complexity: 0.0, requires: nil)
      @id = id.to_sym
      @label = label || @id.to_s.tr("_", " ").capitalize
      @node = node&.to_sym
      @place = place&.to_sym
      @min = min.to_f
      @max = max.to_f
      @default = default.to_f
      @unit = unit
      @stiffness = stiffness
      @effort = effort&.to_h { |stat, weight| [ stat.to_sym, weight.to_f ] }&.freeze
      @aided_by = aided_by&.to_sym
      # Tags without which this job cannot be done at all — multiplied, so a missing one is a
      # zero rather than a penalty. See `Minion#capability`.
      @gated_by = gated_by&.map(&:to_sym)&.freeze
      @exertion = exertion.to_f
      @recovery = (recovery || (effort ? 0.0 : Fatigue::BASE_RECOVERY)).to_f
      @capacity = capacity&.to_i
      @complexity = complexity.to_f
      @requires = requires&.to_sym
      validate_effort!
      validate_fatigue!
      validate_capacity!
      freeze
    end

    # Room for somebody, given who is already posted here. Always true where none is declared.
    def room_for?(occupants) = @capacity.nil? || occupants < @capacity

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
      nudge(state, travel(state, dt: dt, rate_multiplier: rate_multiplier))
    end

    # **How far this lever would travel this tick, signed.** Separated from applying it so that
    # a mistake can send the movement somewhere else: a hand on the wrong lever is still a hand
    # doing the same amount of work, just not where it was meant to.
    def travel(state, dt:, rate_multiplier: 1.0)
      gap = state.fetch(:target) - state.fetch(:actual)
      return 0.0 if gap.abs <= Float::EPSILON
      return gap if @stiffness.infinite?

      step = @stiffness * rate_multiplier * dt * (@max - @min) / 100.0
      gap.clamp(-step, step)
    end

    # Clamped, because a movement that arrived here by mistake was aimed at a different lever
    # with a different range.
    def nudge(state, delta)
      return state if delta.zero?

      state.merge(actual: (state.fetch(:actual) + delta).clamp(@min, @max))
    end

    # **How likely whoever is stood here is to do the wrong thing**, per second.
    #
    # Two independent routes, because they are different failures: somebody **boneheaded** will
    # occasionally get any job wrong, and anybody will occasionally get wrong a job that is
    # **beyond them**. A careful expert at a simple lever is never wrong, and that is the point
    # — this must cost nothing at the fourteen levers that are just valves.
    def slip_chance(minion, wits, dt)
      careless = Injury.numeric(minion.tag(:boneheaded))
      beyond = @complexity.positive? ? [ difficulty(minion) - wits, 0.0 ].max : 0.0
      return 0.0 if careless.zero? && beyond.zero?

      ((BONEHEADED_PER_S * careless) + (BEYOND_PER_S * beyond)) * dt
    end

    # An uncertificated hand at a post that wants a ticket is further out of their depth than
    # their wits alone say — which is what a ticket *is*.
    def difficulty(minion)
      return @complexity if @requires.nil? || Injury.numeric(minion.tag(@requires)).positive?

      @complexity * UNTICKETED
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

      # Stats **plus** the derived quantities: a station may ask for `force` or `swing` as readily
      # as for a stat, and `Minion#effective` resolves either. A typo is still refused at build,
      # which is the only mistake here the engine can catch — a station left reading `strength`
      # where it meant `force` builds happily and simply makes a big worker no better at a heavy
      # job. See `docs/design_sketches/strength-to-weight.md` §8.
      unknown = @effort.keys - Sheet::STATS - Sheet::DERIVED
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

    # Zero would be a station nobody may ever be posted to, which is indistinguishable from one
    # that does not exist and is never what anybody meant to declare.
    def validate_capacity!
      return if @capacity.nil? || @capacity.positive?

      raise Error, "control #{@id}: capacity #{@capacity} must be positive or absent"
    end
  end
end
