# frozen_string_literal: true

module ReactorSim
  # How work tires the person doing it.
  #
  # **Effort is subjective, and that is the whole idea.** Fatigue accrues with
  # `intent ÷ capability` rather than with the lever's position: working somebody past what they
  # can manage tires them, and a strong worker coasting at a setting that is killing a weak one
  # does not. A lever at 80 is one number; what it costs is a different number for every person
  # who stands there.
  #
  # Shaped like `Injury` — a pure module over a state hash it does not own, drawing no entropy, so
  # a tired minion replays exactly and survives a snapshot. Unlike `Injury` it runs every tick for
  # everybody posted, which is why it is a rate on the control point rather than a hazard table:
  # nothing that happens every tick may be an event.
  #
  # See `docs/design_sketches/fatigue.md`.
  module Fatigue
    # Superlinear, so half effort costs a QUARTER. That is what makes sustainable work genuinely
    # sustainable and working flat out a decision rather than a default.
    EXPONENT = 2.0

    # `capability` already contains `(1 - fatigue)`, so tiring raises `load`, which tires faster —
    # a runaway, and a wanted one: a tired person does work harder to achieve the same thing.
    #
    # **The runaway divides time-to-spent by exactly three, at every load.** With
    # `capability = C(1-f)`, accrual is `K/(1-f)²`, and integrating `(1-f)²df = K dt` gives
    # `t = (1 - (1-f)³)/3K` — so reaching `f = 1` takes `1/3K` against the `1/K` a flat rate
    # would. **An `exertion:` reciprocal is therefore a nominal figure and the real one is a third
    # of it.** Predicted 824 ticks against 832 measured, so this is the arithmetic rather than an
    # estimate of it.
    #
    # **And it is a runaway with a pole.** At `fatigue` 1.0 capability is zero and `load` is
    # infinite, and a severely injured minion reaches that on the tick they are hurt, because every
    # derate is 0.0. Four times over-matched is already far past anything the design distinguishes,
    # so this bounds a bug without bounding the design — the same constant and the same reasoning
    # as `Tick::HAZARD_SCALE`.
    LOAD_CEILING = (0.0..4.0)

    RANGE = (0.0..1.0)

    # `Sheet::MIN_STAT` is 0.0 and endurance is a DIVISOR, so enough bulky kit would divide by
    # zero. Floored at the point of use rather than in `Sheet`, because `MIN_STAT`'s reasoning is
    # about what a sheet may hold and this is about what one consumer can do with it.
    MIN_ENDURANCE = 0.1

    # Standing by is not resting, but it is not the fire either. A minion off post recovers at the
    # same rate, because "nowhere" is somewhere to stand down to until the Crew Quarters exists —
    # see `docs/design_sketches/crew_capacity.md`.
    #
    # **Calibrated against the game's clock, not a real shift.** The steam engine runs at
    # `time_scale` 1.0, so `dt` is 0.25 s and a whole cold start is about seven simulated minutes.
    #
    # Recovery has no runaway — it is a flat rate — so this reciprocal is the literal figure:
    # spent to fresh in 455 s, against roughly 300 s to spend somebody at a heavy station. Rather
    # under two people per post to keep one running flat out, which is the scarcity the Crew
    # Quarters then sells a way out of.
    BASE_RECOVERY = 2.2e-3

    # What a burden equal to your own body mass costs per second, before `endurance`. Pitched
    # against `BASE_RECOVERY`: at 3.0e-3 a fireman's carry out-accrues a standing rest by a
    # little, so somebody hauling a body their own weight tires over minutes rather than being
    # written off in seconds — slow enough that a rescue across a district is possible and fast
    # enough that it is a race. **Ordinary gear is a small fraction of this** (a 6.5 kg kit on a
    # 70 kg human is a burden of 0.09), which is the intent: kit should be felt over a shift
    # rather than noticed in a minute.
    HAUL_RATE = 3.0e-3

    # Spent, and the hysteresis that keeps it from announcing itself at the tick rate. `ReliefValve`
    # cried wolf 20 times in 40 ticks without one.
    SPENT = 0.95
    RECOVERED = 0.8

    module_function

    # What one tick of standing there does. Returns the next minion state.
    #
    # **Accrual and recovery both always apply and net out.** The alternative — accrue while
    # working, recover while not — puts a discontinuity at zero demand and makes a lightly worked
    # station behave like an idle one. Netting is continuous, and it is what makes "light work is
    # sustainable, hard work is not" fall out of the arithmetic instead of being a special case.
    #
    # **`suffocation:` is a third term rather than part of `accrual`**, because everything in
    # `accrual` is about the work — station, lever, capability — and bad air is about *where you
    # are standing*, which no lever describes. Added here it nets with recovery like everything
    # else, so walking into clean air is recovery with no mechanism of its own. `Breath` computes
    # it; see `docs/design_sketches/breathable-air.md`.
    # **`burden:` is a fourth term, for the same reason `suffocation:` is a third** — it is about
    # what is on your back rather than about a station. It applies to gear as much as to a
    # casualty, so a minion in an asbestos suit is paying for it while standing still.
    def advance(minion, state, control:, dt:, demand: 0.0, suffocation: 0.0, burden: 0.0)
      rate = accrual(minion, state, control, demand) - recovery(control, state) +
             suffocation + hauling(minion, burden)
      next_fatigue = (state.fetch(:fatigue, 0.0) + (rate * dt)).clamp(RANGE.begin, RANGE.end)

      state.merge(fatigue: next_fatigue)
    end

    # What a load costs per second. Linear in the burden rather than squared: `EXPONENT` exists
    # because a mismatch between what work demands and what a worker brings should *compound*,
    # and a burden is already a ratio. Divided by `endurance` like every other accrual, so
    # staying power is staying power whatever the source.
    def hauling(minion, burden)
      return 0.0 unless burden.positive?

      HAUL_RATE * burden / endurance(minion)
    end

    # The station sets the base rate — shovelling is not watching a gauge, and the machine is what
    # knows the difference — and the person sets what that base costs them.
    def accrual(minion, state, control, demand)
      return 0.0 if control.nil? || !control.effort?

      exertion = control.exertion
      return 0.0 unless exertion.positive? && demand.positive?

      exertion * (load(minion, state, control, demand)**EXPONENT) / endurance(minion)
    end

    # `intent ÷ capability`. Guarded at zero demand because `0.0 / 0.0` is NaN and `NaN.clamp`
    # raises — a lever at rest must not be able to throw.
    def load(minion, state, control, demand)
      return 0.0 unless demand.positive?

      capability = minion.capability(state, effort: control.effort, aided_by: control.aided_by)
      return LOAD_CEILING.end unless capability.positive?

      (demand / capability).clamp(LOAD_CEILING.begin, LOAD_CEILING.end)
    end

    # Where you are standing, not what you are doing: an effort station declares nothing and
    # recovers nothing, because you are still at the fire.
    # **Holding somebody is not standing down, at any weight.** Without this gate the accrual
    # term alone leaves the bug in place for every load under some threshold: accrual and
    # recovery *net*, so a light casualty produces a small accrual that `BASE_RECOVERY` still
    # beats, and carrying a kobold out reads as a rest. A bigger number cannot fix that — only
    # refusing to recover at all can.
    #
    # **It keys on carrying a person, never on the burden.** Standing about in armour is still
    # standing about; you are merely tired from wearing it. That is the same split
    # `ControlPoint#recovery` already draws — an effort station recovers nothing because you are
    # still at the fire, a valve is somewhere to stand down to — so armour you can rest off and a
    # casualty you cannot, and putting somebody down in a refuge becomes a real decision.
    def recovery(control, state = nil)
      return 0.0 if state && Burden.carrying?(state)
      return BASE_RECOVERY if control.nil?

      control.recovery
    end

    def endurance(minion) = [ minion.endurance, MIN_ENDURANCE ].max

    def spent?(state) = state.fetch(:fatigue, 0.0) >= SPENT

    # A transition, which is the only thing an event may be. Returns the next state plus `true`
    # when this is the tick they went — never on the ticks after, and re-armed only once they have
    # genuinely recovered rather than at the threshold they failed at.
    def check_spent(state)
      was = state.fetch(:spent, false)
      return [ state, false ] if was && state.fetch(:fatigue, 0.0) > RECOVERED
      return [ state.merge(spent: false), false ] if was

      return [ state, false ] unless spent?(state)

      [ state.merge(spent: true), true ]
    end
  end
end
