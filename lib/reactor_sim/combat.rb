# frozen_string_literal: true

module ReactorSim
  # **One blow against one guard**: whether it lands, how cleanly, and how hard it hits. Pure
  # arithmetic over figures and dice somebody else drew — a brawl's are thrown in phase 0 on each
  # person's temper stream — so anything that ever comes to blows reads the same contest.
  #
  # What a person brings is theirs (`Minion#strike`, `#attack`, `#defend`); this is what the dice
  # make of it. See `docs/design_sketches/animosity-and-distraction.md` §2.5 and §6.
  module Combat
    # **How wide a contest die stretches a figure**: a bell in log space, `exp(spread × z)` where `z`
    # is the die's standard normal deviate. A median of one, most rolls near it, and the far ends
    # rare — which is what lets a high roll be an event (`CRITICAL_AT`).
    CONTEST_SPREAD = 0.45

    # Keeps a die of exactly 0 or 1 off the ends of the curve.
    DIE_EDGE = 1.0e-9

    # A blow at this ratio of strike to defence lands in full; at 1.0 it misses.
    FULL_AT = 1.5

    # **A critical**: a strike that beats the guard by twice what a clean hit needs **finds the
    # gap** — a soft spot, round the armour — and meets no resistance kit and only
    # `CRITICAL_TOUGHNESS` of the body's toughness (`Injury.check`'s `pierces:`). Nothing is added, so
    # a big hand's critical is a hard blow and not a killing one twice over, a light one's can still
    # take somebody huge off the shift, and somebody huge can take a beating.
    CRITICAL_AT = FULL_AT * 2.25
    CRITICAL_TOUGHNESS = 0.33

    # Severity per unit of `attack`, for a blow that lands clean.
    BLOW = 1.0

    # **How hard a landed blow hits**, from the same attack die as whether it landed — a good swing
    # is good both ways — on a much tighter stretch than the contest's, so a blow is nearly always
    # about what the attacker brought. Bare hands are a poor weapon by their own handling
    # (`Equipment::UNARMED`), not by a rule here.
    DAMAGE_SPREAD = 0.2

    module_function

    # What a contest die makes of a figure.
    def rolled(figure, die) = figure * Math.exp(CONTEST_SPREAD * deviate(die))

    # How much of a blow lands, from strike against defence: nothing at or below even, all of it
    # from `FULL_AT`.
    def landed(strike, defend)
      return 1.0 unless defend.positive?

      ((strike / defend) - 1.0).fdiv(FULL_AT - 1.0).clamp(0.0, 1.0)
    end

    def critical?(strike, defend) = !defend.positive? || strike / defend >= CRITICAL_AT

    # All or nothing: a shove, a deed.
    def succeeds?(strike, defend) = strike > defend

    # `attack` is what the hand brings (`Minion#attack`), stretched by the swing's die;
    # `weapon_edge` what the weapon brings by itself, whoever holds it. A glancing blow lands a
    # share of both.
    def blow_severity(attack, weapon_edge, die, share)
      u = edge(die)
      BLOW * ((attack * ((u / (1.0 - u))**DAMAGE_SPREAD)) + weapon_edge) * share
    end

    def edge(die) = die.clamp(DIE_EDGE, 1.0 - DIE_EDGE)

    # **The standard normal deviate of a uniform die** — Acklam's rational approximation to the
    # inverse normal distribution, good to about 1e-9 everywhere, and arithmetic only.
    LOW = 0.02425
    A = [ -3.969683028665376e+01, 2.209460984245205e+02, -2.759285104469687e+02,
          1.383577518672690e+02, -3.066479806614716e+01, 2.506628277459239e+00 ].freeze
    B = [ -5.447609879822406e+01, 1.615858368580409e+02, -1.556989798598866e+02,
          6.680131188771972e+01, -1.328068155288572e+01 ].freeze
    C = [ -7.784894002430293e-03, -3.223964580411365e-01, -2.400758277161838e+00,
          -2.549732539343734e+00, 4.374664141464968e+00, 2.938163982698783e+00 ].freeze
    D = [ 7.784695709041462e-03, 3.224671290700398e-01, 2.445134137142996e+00,
          3.754408661907416e+00 ].freeze

    def deviate(die)
      u = edge(die)
      return -tail(u) if u < LOW
      return tail(1.0 - u) if u > 1.0 - LOW

      q = u - 0.5
      r = q * q
      horner(A, r) * q / horner(B + [ 1.0 ], r)
    end

    def tail(edge_die)
      q = Math.sqrt(-2.0 * Math.log(edge_die))
      -horner(C, q) / horner(D + [ 1.0 ], q)
    end

    def horner(coefficients, point) = coefficients.reduce(0.0) { |acc, c| (acc * point) + c }
  end
end
