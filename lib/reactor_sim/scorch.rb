# frozen_string_literal: true

module ReactorSim
  # What the heat where somebody is standing does to them.
  #
  # Shaped like `Breath` and `Fatigue`: a pure module over a state hash it does not own, drawing
  # no entropy, so a burning minion replays exactly and survives a snapshot. The uncertainty is
  # the hidden `resilience` rolled once at `initial_state`, exactly as for a blow.
  #
  # **The quantity is heat delivered per second, not temperature**, and that is the whole reason
  # 400 K air is a long shift's problem while boiling water is an emergency. A medium's ability
  # to deliver heat is its volumetric heat capacity, `ρ × c`, which `content/` already carries
  # for every resource:
  #
  #     air    1.2 × 1005  =     1 231 J/m³K
  #     steam  0.6 × 2010  =     1 206
  #     water  997 × 4181  = 4 168 457          — three thousand times the air
  #
  # **Ambient exposure reads the gas phase only.** You stand *beside* water, not in it,
  # and a sump at the pit bottom must not cook everybody standing near it. Liquids and melts
  # reach people as a splash instead, which is an event rather than a room.
  #
  # Burns differ from suffocation in one way that matters: **they do not drain.** Walking out of
  # the fire stops the accrual; it does not undo it.
  #
  # See `docs/design_sketches/thermal-injury.md` Part 2.
  module Scorch
    # Skin is being damaged from about 45 °C, so below this nothing happens at all — which is
    # the overwhelming majority of every match, and this must cost nothing there.
    TOLERATED_K = 318.0

    # Convection runs about ΔT^1.25 and radiation adds a steeply rising term on top. 1.5 is the
    # blend, and it is what separates the cases: linear in ΔT makes 1300 K only twelve times
    # worse than 400 K, where it should be nearer fifty.
    EXPONENT = 1.5

    # **Toughness raises the threshold as well as deepening the reserve**, the same doubling
    # `Injury` already applies — a tough minion both shrugs more off and has more to lose. In
    # kelvin per point, and deliberately small: being hardy is worth a few degrees, not a suit.
    HARDINESS_K = 20.0

    # What a full point of `heat_resistance` is worth, which is the gear tier's whole job: at
    # 1.0 somebody tolerates about 1200 K and can work in a place that would kill a bare hand
    # in seconds. Below the rating it is nothing special; this is a threshold, not a multiplier.
    SHIELDING_K = 900.0

    # **Calibrated at one point; everything else falls out of the law.** A fit, unaided person
    # in air at 1300 K is ground from unmarked to carried out in about ten seconds. The brief's
    # other cases then follow without being tuned separately — 400 K air reaches a minor in
    # roughly three minutes and a severe in seven, which is the "only on long exposure" it asked
    # for, and the ratio between them is ~41×.
    REFERENCE_K = 1_300.0
    REFERENCE_SECONDS = 10.0
    REFERENCE_RHO_C = 1_231.0

    SCALE = REFERENCE_RHO_C * ((REFERENCE_K - TOLERATED_K)**EXPONENT) * REFERENCE_SECONDS

    # How far past collapse somebody is, and the reason pulling them out is worth doing.
    #
    # `Injury.grind` cannot reach `:mortal` on its own: grinding resilience to zero proposes
    # `:severe`, every bite after proposes `:severe` again, and `Severity.escalate` rightly
    # refuses to announce the same injury twice. So the dwell past zero is counted here, exactly
    # as `Breath` counts `asphyxia`, and at 1.0 the burn is mortal.
    DWELL = 1.0

    module_function

    # The gas filling a room, as `[temperature_k, rho_c]`, or nil where there is no gas to
    # stand in. Worked out once per room per tick rather than once per person.
    def gas(parcels, content)
      volume = 0.0
      heat = 0.0
      capacity = 0.0

      parcels.each do |parcel|
        resource = parcel.fetch(:resource)
        next unless content.tags(resource).include?(:gas)

        m3 = Parcel.volume_m3(parcel, content)
        next unless m3.positive?

        volume += m3
        heat += m3 * Parcel.temperature_k(parcel, content)
        capacity += m3 * rho_c(resource, content)
      end

      return nil unless volume.positive?

      [ heat / volume, capacity / volume ]
    end

    # Resilience ground away per second. Zero for anybody who does not burn, and zero below the
    # threshold, which is where almost everybody almost always is.
    def rate(gas, minion)
      return 0.0 if gas.nil? || unburning?(minion)

      temperature_k, rho_c = gas
      excess = temperature_k - tolerated_k(minion)
      return 0.0 unless excess.positive?

      rho_c * (excess**EXPONENT) / SCALE
    end

    # Returns `[next_state, mode_or_nil]`, a mode only on a transition — the discipline every
    # other harm in the engine follows, because re-deciding each tick would announce the same
    # injury at the tick rate forever.
    def advance(minion, state, gas, dt)
      burn = rate(gas, minion) * dt
      return [ state, nil ] if burn <= 0.0

      state, mode = Injury.grind(state, burn)
      state = state.merge(burns: burns(state) + burn) if state.fetch(:resilience) <= 0.0
      return Injury.succumb(state, :mortal) if burned?(state)

      [ state, mode ]
    end

    # A heat a body does not answer to at all — a fire elemental, a thing made of slag. A gate
    # rather than a resistance, for the same reason `Breath#unbreathing?` is one.
    #
    # TODO: **nothing in `content/` declares `unburning`**, so this branch is unreachable in a real
    # match and is untested outside `scorch_spec`'s fixture. First caller is a race that does not
    # burn, and it is content rather than engine work. Kept for the same reason `unbreathing` is:
    # a resistance cannot say "this does not apply to me at all".
    def unburning?(minion) = Injury.numeric(minion.tag(:unburning)).positive?

    def tolerated_k(minion)
      TOLERATED_K + (HARDINESS_K * (minion.toughness - 1.0)) + (SHIELDING_K * shielding(minion))
    end

    def shielding(minion) = Injury.numeric(minion.tag(:heat_resistance)).clamp(0.0, 1.0)

    def burns(state) = state.fetch(:burns, 0.0)

    def burned?(state) = burns(state) >= DWELL

    def rho_c(resource, content)
      spec = content.resource(resource)
      spec.fetch(:density_kg_per_m3, 0.0).to_f * spec.fetch(:specific_heat_j_per_kg_k, 0.0).to_f
    end
  end
end
