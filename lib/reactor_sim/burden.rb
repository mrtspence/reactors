# frozen_string_literal: true

module ReactorSim
  # **What somebody is carrying, and what it costs them.** One concept with two sources: the gear
  # hanging off them, and the people in their arms. A rescue is the second kind; an asbestos suit
  # is the first; the arithmetic cannot tell them apart and should not.
  #
  # Shaped like `Breath`, `Scorch`, `Fatigue` and `Blunder`: pure, over a state hash it does not
  # own, drawing no entropy. It is handed the roster because a carried person's mass is config on
  # *them* — frozen at build, so reading it cannot depend on phase order.
  #
  # See `docs/design_sketches/carrying.md`.
  module Burden
    # What a reference human can pick up and still move, in kilograms. Scaled by `force`, so this
    # is the figure at `force` 1.0.
    #
    # **Calibrated against four cases, and the ogre is what caps it.** Measured on real content,
    # each casualty carrying an ordinary pick:
    #
    #     human  → a human            +78%   comfortable, as it should be
    #     human  → half again himself +20%   a fireman's carry, which untrained people manage
    #     elf    → a human            +30%   harder, and still possible
    #     kobold → one kobold         +16%   but never two, nor an elf, nor a human
    #     ogre   → another ogre       +20%   slowly, and on a slim margin
    #
    # And **nobody can carry two of their own kind**, which no requirement asked for and is the
    # right answer. The first figure here was 90 and had an elf unable to lift a man at all, which
    # is simply wrong about bodies.
    LIFT_KG = 130.0

    # How much a load equal to your own body mass costs you. At 1.0 it halves your pace, which
    # is a fireman's carry: slow, possible, and obviously worth doing.
    DRAG = 1.0

    # What a stretcher and a strong back are worth. `aided_by:` elsewhere **adds**, and so does
    # this — a tool makes you better at the job and its absence makes you merely unaided.
    AIDS = %i[stretcher strong_back].freeze

    module_function

    # **Gear plus people, and a carried person brings their own gear with them** — which is both
    # obviously right and the reason a casualty in a breathing set is harder to move than one in
    # a shirt.
    def load_kg(minion, state, minions)
      carried(state).sum { |id| body_kg(minions[id]) } + minion.worn_kg
    end

    # A person's whole weight as cargo: their frame and whatever is hanging off it. Nil for
    # somebody no longer on the roster, which costs nothing rather than raising — a restored
    # snapshot naming a seat that has gone is a bad save, not a reason to stop the match.
    def body_kg(minion) = minion.nil? ? 0.0 : minion.mass_kg + minion.worn_kg

    # The load against the frame that has to shift it. **Carrier mass belongs here rather than in
    # the lift limit**: shifting a load relative to your own body is what makes you slow, while
    # mass in the limit would make a fat weak minion a good stretcher-bearer.
    def ratio(minion, state, minions) = load_kg(minion, state, minions) / minion.mass_kg

    # What a burden does to a walk. Never zero, so a hopeless load crawls rather than dividing by
    # anything — the refusal that stops it happening at all lives in `liftable?`.
    def pace_factor(ratio) = 1.0 / (1.0 + (DRAG * [ ratio, 0.0 ].max))

    # **`force` rather than `strength`**, because picking somebody up is absolute work and
    # `strength` is only a ratio — and through `effective`, so an injured arm reduces what
    # somebody can lift without a line of code saying so.
    #
    # **Mass is not a second term here.** It enters exactly once, through `force`; adding it again
    # would double-count the body, and the diminishing return is already present because a large
    # race has less strength per kilogram of itself.
    def lift_kg(minion, state)
      aid = AIDS.sum { |key| Injury.numeric(minion.tag(key)) }

      LIFT_KG * minion.effective(:force, state) * (1.0 + aid)
    end

    # Could this minion take on `extra` as well as what they already have? Checked against the
    # TOTAL load, so somebody's own gear eats into their lifting allowance — an armoured rescuer
    # carries less, which is correct and needed no extra rule.
    #
    # **Asked at pickup and never again.** A limit re-checked every tick would force a drop as its
    # holder tired, which is a second way to lose somebody arriving with no warning, in a mechanic
    # whose whole point is a clock the player can see. Tiring instead shows up as pace collapsing,
    # which strands the pair where they stand and is legible.
    def liftable?(minion, state, minions, extra)
      load_kg(minion, state, minions) + body_kg(extra) <= lift_kg(minion, state)
    end

    def carried(state) = Array(state[:carrying])

    def carrying?(state) = !carried(state).empty?

    # **Carrying a person is the only burden that stops you resting**, which is why this asks
    # about people and not about weight. Standing about in armour is still standing about; you
    # are merely tired from wearing it. A body on your back is not rest at any weight.
    def resting?(state) = !carrying?(state)
  end
end
