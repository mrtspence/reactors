# frozen_string_literal: true

module ReactorSim
  # **What the cold where somebody is standing does to them**, and its mirror at the other end:
  # how the heat of a hot day makes the same work cost more.
  #
  # Shaped like `Scorch`: a pure module over a state hash it does not own, drawing no entropy. The
  # quantity is the air **as it feels** — its temperature with the wind on it, as far as the place
  # is open to the wind — because that is what takes the warmth out of somebody outside in a gale.
  #
  # Cold grinds resilience below a tolerance and costs nothing above it, which is nearly every
  # match. Heat is not a burn — outdoor summer air is nowhere near `Scorch`'s threshold — it is
  # **strain**: past a comfort band, labour tires a worker faster (`strain`), read by `Fatigue`.
  #
  # See `docs/design_sketches/conditions.md` §2.6.
  module Chill
    # A working man dressed for his trade is past discomfort and into harm from about −8 °C felt.
    TOLERATED_K = 265.0

    # Being hardy is worth a few degrees, the same shape as `Scorch::HARDINESS_K`.
    HARDINESS_K = 4.0

    # What a full point of `cold_resistance` buys — a greatcoat and mittens are about half of it.
    SHIELDING_K = 30.0

    # **Calibrated at one point.** At −30 °C felt, an unprotected fit hand is ground from unmarked
    # to carried out in about twenty minutes; at −15 felt it takes most of a long match, and above
    # −8 nothing happens at all.
    REFERENCE_K = 243.0
    REFERENCE_SECONDS = 1_200.0
    EXPONENT = 1.5

    # Past collapse, how long until it is mortal — the dwell every continuous harm owes.
    DWELL = 1.0

    # Labour starts costing more above this, felt.
    COMFORT_K = 295.0

    # Extra fatigue per kelvin above comfort: at 32 °C a labourer tires about a third faster.
    STRAIN_PER_K = 0.04

    module_function

    # The air of each place as a person in it would feel it, K: the gas there, with the wind chill
    # taken as far as the place is open to the sky.
    def felt_k(air_k, exposure, wind_m_s)
      return air_k unless exposure.positive?

      air_k + (exposure * (Nodes::Outdoors.feels_k(air_k, wind_m_s) - air_k))
    end

    # Resilience ground away per second. Carried out is the `cold` wound reaching severe, so that is
    # what the reference grinds through in its time.
    def rate(felt_k, minion)
      return 0.0 if felt_k.nil? || unfeeling?(minion)

      deficit = tolerated_k(minion) - felt_k
      return 0.0 unless deficit.positive?

      ((deficit / (TOLERATED_K - REFERENCE_K))**EXPONENT) * Wounds::BANDS.fetch(:severe) / REFERENCE_SECONDS
    end

    # **One `cold` wound, deepening while they stay.** `[next_state, mode_or_nil, wounds]`, a mode
    # only on a transition.
    def advance(minion, state, felt_k, dt, catalogue:, die:)
      bite = rate(felt_k, minion) * dt
      return [ state, nil, [] ] if bite <= 0.0

      state, mode, wounds = Injury.endure(state, :cold, bite, catalogue: catalogue, die: die)
      state = state.merge(chilled: chilled(state) + bite) if state.fetch(:resilience) <= 0.0
      return Injury.succumb(state, :mortal, kind: :cold, catalogue: catalogue, die: die) if chilled(state) >= DWELL

      [ state, mode, wounds ]
    end

    # How much harder labour is in this heat, as a multiple on what work costs. 1.0 in comfort.
    def strain(felt_k)
      return 1.0 if felt_k.nil?

      1.0 + (STRAIN_PER_K * [ felt_k - COMFORT_K, 0.0 ].max)
    end

    def tolerated_k(minion)
      TOLERATED_K - (HARDINESS_K * (minion.toughness - 1.0)) - (SHIELDING_K * shielding(minion))
    end

    def shielding(minion) = Injury.numeric(minion.tag(:cold_resistance)).clamp(0.0, 1.0)

    # A body the cold does not reach — a thing of stone, a fire spirit.
    #
    # TODO: **nothing in `content/` declares `unfeeling`**, so this branch is untested outside
    # `chill_spec`'s fixture. First caller is a race the cold does not touch; content, not engine
    # work. Kept for the reason `Scorch#unburning?` is.
    def unfeeling?(minion) = Injury.numeric(minion.tag(:unfeeling)).positive?

    def chilled(state) = state.fetch(:chilled, 0.0)
  end
end
