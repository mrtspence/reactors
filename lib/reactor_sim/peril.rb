# frozen_string_literal: true

module ReactorSim
  # **A way a place can hurt the person standing in it**, as opposed to a way a machine can.
  #
  # `failure_hazards` answers "a part broke, who was near it". A peril answers the other half:
  # nothing broke, the haulage road is simply a place where tubs go past and sooner or later one
  # of them catches somebody. Declared on the node that embodies the danger, keyed by `places:`
  # or `stations:` exactly as `failure_hazards` is, so the two resolve through one mechanism.
  #
  # **A fitting removes a peril by not declaring it.** There is no `absent_when:` — railings are
  # a part, and a part that is fitted contributes a fragment without the fall in it. That is how
  # every other purchase in this engine works and it needs no second rule.
  Peril = Struct.new(:id, :tags, :severity, :scales_with, :when_tagged, :unless_tagged,
                     :places, :stations, keyword_init: true) do
    def initialize(id:, severity:, tags: [], scales_with: nil, when_tagged: nil,
                   unless_tagged: nil, places: nil, stations: nil)
      super(id: id.to_sym, severity: severity.to_f, tags: Array(tags).map(&:to_sym).freeze,
            scales_with: scales_with&.to_sym,
            when_tagged: when_tagged&.to_sym, unless_tagged: unless_tagged&.to_sym,
            places: Array(places).map(&:to_sym).freeze,
            stations: Array(stations).map(&:to_sym).freeze)
      freeze
    end

    # **A tag can select a kind of accident rather than only making one likelier.** A hulking
    # minion gets wedged in a narrow roadway where nobody else could; a small one is missed by
    # a driver and struck, which cannot happen to the ogre. Race and kit then matter in both
    # directions at a post rather than ranking on one scale.
    def applies_to?(minion) = weight_for(minion).positive?

    # **The gating tag's VALUE scales the accident, not merely its presence.** An ogre at
    # `hulking: 0.5` is half-way to filling the roadway, so he is wedged half as readily as
    # something that fills it completely — and still struck by tubs half as often as a kobold,
    # because he is only half as hard to miss. Presence-only gating made every large thing
    # identically large: a hob and a giant wedged at the same rate, and anything with a trace of
    # the tag became wholly immune to the peril on the other side of it.
    #
    # So the two road perils are **complementary rather than exclusive**, and only the extremes
    # are a clean either/or. `severity` is therefore the figure for a *fully* tagged creature.
    def weight_for(minion)
      want = when_tagged ? Injury.numeric(minion.tag(when_tagged)) : 1.0
      avoid = unless_tagged ? 1.0 - Injury.numeric(minion.tag(unless_tagged)) : 1.0

      (want * avoid).clamp(0.0, 1.0)
    end

    def reaches?(station, place) = stations.include?(station) || places.include?(place)
  end

  # The hidden margin of safety every worker carries, and what spends it.
  #
  # **`Concerns::Wearing` for people a second time, and this half is renewable.** A part's
  # durability only ever goes down; a person's margin comes back. That is the whole difference
  # and it is what makes a bad hour on the haulage road a reason to move somebody rather than a
  # sentence passed on them.
  #
  # Shaped like `Breath`, `Scorch` and `Fatigue`: pure, over a state hash it does not own, and
  # it draws nothing. The dice were thrown at `initial_state` and in phase 0; **what happens is
  # a deterministic comparison**, exactly as the Danger Check is.
  #
  # See `docs/design_sketches/mine-follow-ups.md` Part 4.
  module Blunder
    # **Wide on purpose, and the opposite of `RESILIENCE_SPREAD`.** That one is narrow because
    # it modifies a threshold the player is meant to reason about. This one's entire job is to
    # stop them ever being *sure*: without a wide spread they learn that eight minutes on the
    # haulage road is safe, and then farm it — unsuited workers doing a metered amount of
    # dangerous work at no real risk. The variance is what keeps a risk a risk.
    SPREAD = (0.35..2.6)

    # Margin spent per second by a peril of severity 1.0 running flat out, on a fit,
    # unremarkable worker.
    #
    # **Calibrated at the duty a working pit actually reaches, not at `activity` 1.0.** A road
    # rated for the whole mine runs at about a seventh of its rating with one hewer on the
    # face, so a figure chosen against flat-out traffic is seven times weaker than it reads and
    # the road quietly stops hurting anybody. Against the haulage road's two perils at that
    # duty and a middling margin of 1.5: an unremarkable hand has most of an hour, a clumsy
    # green one is in trouble inside a quarter of one, and a practised hand with pit sense is
    # good for the better part of two. Running more hewers loads the road and moves all three
    # figures down together, which is the point.
    #
    # Those are per *person*, and the two-shaft pit has six of them underground — three posted
    # and the three the advance shift already sent down. **What the player sees is therefore
    # six times as often**: an unremarkable crew meets something every few minutes and is worn
    # through in well under an hour. Read the shift figure, not the man's.
    SPEND_PER_S = 1.23e-3

    # And what comes back per second somewhere nothing is trying to hurt you — a full margin in
    # something over eight minutes. Deliberately on a timescale of minutes rather than of a
    # match: the answer to a low bar has to be a decision the player makes now, not a worker
    # written off. It is also what makes **rotating a shift through safe and dangerous posts**
    # a real strategy rather than a tax on playing at all.
    MEND_PER_S = 3.0e-3

    # **Fatigue multiplies and never divides.** `capability` already contains `(1 - fatigue)` and
    # has a pole at 1.0; a second term dividing by anything fatigue-derived would stack two
    # singularities. Squared for the reason `Fatigue` is squared — a mismatch between what the
    # work demands and what the worker brings should compound rather than add.
    EXPONENT = 2.0
    SPENT_WEIGHT = 4.0

    module_function

    def roll(rng) = rng.between(SPREAD.begin, SPREAD.end)

    def initial_state(rng)
      full = roll(rng)
      { margin: full, margin_full: full }
    end

    # What this tick's exposure costs, and which peril is doing the most of it.
    #
    # **One margin rather than one per peril**, so the state stays a single number — and the
    # accident that fires is whichever contributed most at the moment it crossed, which is also
    # the legible answer: a man who has spent his shift beside the haulage gets caught in it.
    def spend(reaching, minion, state, dt)
      exposed = susceptibility(minion, state)
      bites = reaching.filter_map do |peril, activity|
        bite = peril.severity * peril.weight_for(minion) * activity * exposed * SPEND_PER_S * dt
        [ peril, bite ] if bite.positive?
      end

      [ bites.sum { |_, bite| bite }, bites.max_by { |_, bite| bite }&.first ]
    end

    # How much of a peril actually reaches this person. Everything here already existed and was
    # pointed at severity; `hazard_sense` in particular belongs mostly here — pit sense is about
    # not being there, not about absorbing it better.
    def susceptibility(minion, state)
      careless = 1.0 + tag(minion, :clumsy) + tag(minion, :green) + tag(minion, :boneheaded)
      wary = 1.0 + tag(minion, :hazard_sense) + tag(minion, :practised)
      tired = 1.0 + (SPENT_WEIGHT * (state.fetch(:fatigue, 0.0)**EXPONENT))

      careless / wary * tired
    end

    # Returns `[next_state, peril_or_nil]` — a peril only when the margin has just run out,
    # which is the transition discipline every other harm in the engine follows.
    #
    # **Both transitions end an episode and draw a new margin**: running out, and filling back
    # up. The second is the one that is easy to miss and it closes an information leak — a
    # worker who has survived a long exposure has revealed a high roll, and with a bar that
    # refills they would be known-safe forever. The roll is a property of *this stretch of
    # work*, not of the person.
    #
    # **Filling up is a rising edge, and the margin is clamped so that it stays one.** Written
    # as a bare `margin >= margin_full` it is also true of somebody who has never spent
    # anything, so every tick at a quiet moment re-rolled the margin back to full and no
    # exposure ever accumulated: the whole mechanic was a clock that reset itself. It showed up
    # as a haulage road nobody could be hurt on, with no failing assertion anywhere.
    def advance(reaching, minion, state, dt, rolled)
      spent, worst = spend(reaching, minion, state, dt)
      full = state.fetch(:margin_full, 1.0)
      was = state.fetch(:margin, 1.0)
      margin = was - spent
      margin += MEND_PER_S * dt unless endangered?(reaching, minion)

      return [ renew(state, rolled), worst ] if margin <= 0.0
      return [ renew(state, rolled), nil ] if margin >= full && was < full

      [ state.merge(margin: [ margin, full ].min), nil ]
    end

    # **Recovery belongs to being somewhere safe, not to a quiet moment somewhere dangerous.**
    # Traffic is bursty, so a lull between tubs is most of the ticks on a working road; mending
    # through those hands back six times what the road takes and the haulage becomes a corridor
    # nobody can be hurt on. A man stood in the road while nothing is coming has not recovered
    # anything — he is still in the road.
    def endangered?(reaching, minion) = reaching.any? { |peril, _| peril.applies_to?(minion) }

    # **The ceiling on what any safety equipment is worth.** Guarding is no use whatever to
    # somebody who never noticed they needed it, so what it saves is its own effectiveness
    # scaled by the attention the person had to spare — and capped, because **buying safety
    # must never buy immunity.** The remaining sixth is what keeps it a risk being managed
    # rather than one that has been closed.
    MOST_EQUIPMENT_SAVES = 0.85

    # Whether the equipment did its job this time. `attention` is `Minion#wits`, which is
    # already gated on being able to see what is coming and already carries health and
    # fatigue — so a man at the end of his shift is slower to use what he was given.
    def accident_avoided?(effectiveness, attention, roll)
      return false unless effectiveness.positive?

      roll < (effectiveness * attention).clamp(0.0, MOST_EQUIPMENT_SAVES)
    end

    def renew(state, rolled) = state.merge(margin: rolled, margin_full: rolled)

    def tag(minion, key) = Injury.numeric(minion.tag(key))
  end
end
