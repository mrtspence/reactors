# frozen_string_literal: true

module ReactorSim
  # Whether the air where somebody is standing will keep them alive.
  #
  # Shaped like `Fatigue` and `Injury`: a pure module over a state hash it does not own, drawing
  # no entropy, so a suffocating minion replays exactly and survives a snapshot.
  #
  # **`air` is the only thing tagged `breathable`, and every other gas asphyxiates by taking up
  # the room it was in.** That is the entire model, and it is why afterdamp needed no content at
  # all: firedamp combustion consumes 17.2 kg of air per kilogram of gas and hands back
  # `flue_gas`, so a district that has just exploded is a district nobody can breathe in.
  #
  # Two things make air unbreathable and they are not the same mechanism:
  #
  #   displacement  a simple asphyxiant is harmless in itself and kills by being there instead
  #   poisoning     carbon monoxide ruins air it has barely diluted — a `toxic_fraction:` away
  #
  # **Measured by VOLUME, never by mass.** Firedamp is 0.668 kg/m³ against air's 1.225, so
  # kilograms make methane look half as dangerous as it is, and it is displacement that
  # suffocates.
  #
  # Bad air drains `fatigue`, which buys three things that a separate pool would not: it derates
  # capability, so somebody works worse before they drop; it recovers on its own, so walking into
  # good air needs no mechanism; and `endurance` is already its divisor, which is the right stat
  # for how long a person lasts. Being pinned at the ceiling **in bad air** is the collapse, and
  # the clock from there to a mortal injury is `asphyxia` below.
  #
  # See `docs/design_sketches/breathable-air.md`.
  module Breath
    # Air is about 21% oxygen and displacing air displaces oxygen with it, so these are the
    # standard thresholds divided by that: 19.5% oxygen is the safe floor and 10% is
    # unconsciousness in minutes.
    SAFE = 0.93
    DIRE = 0.48

    # Fatigue per second at total displacement. Flat out in clean air is about twenty minutes to
    # spent; this is forty-five seconds, which is the claim — bad air is not hard work, it is a
    # different order of thing.
    MAX_RATE = 2.2e-2

    # Superlinear, so air slightly under the line is survivable for a while and air well under it
    # is not. The same shape, and the same reasoning, as `Fatigue::EXPONENT`.
    EXPONENT = 2.0

    # **Endurance divides, but only within the range a body can actually vary over.** An oxygen
    # reserve differs between people by perhaps a factor of two, never by more — and
    # `spec/support/reference_crew.rb` sets `endurance: 1e6` to make a reference hand tireless,
    # which unclamped would make them immune to suffocating and every spec built on them silently
    # meaningless. Same trap as `Minion::PACE`; see the traps list.
    RESERVE = (0.5..2.0)

    # How far past collapse somebody is, 0 to 1, and the reason rescue is worth doing.
    #
    # `Injury.check` cannot produce this on its own: grinding `resilience` to zero gives
    # `:severe`, every bite after that proposes `:severe` again, and `Severity.escalate` rightly
    # refuses to announce the same injury twice. Reaching `:mortal` needs a bite of
    # `Injury::MORTAL_BITE`, which a steady hazard never grows. So the dwell is counted here,
    # and at 1.0 the peril delivers a bite that size.
    #
    # It drains in good air at the same rate it fills, which is what makes fixing the
    # ventilation the revival rather than a separate mechanic.
    RANGE = (0.0..1.0)

    module_function

    # The fraction of this volume that a person can breathe, 0 to 1.
    #
    # An empty volume reads 0.0 rather than 1.0: nothing to breathe is not clean air, and a
    # vacuum should not be the safest place in the mine.
    def breathable_fraction(parcels, content)
      total = 0.0
      breathable = 0.0

      parcels.each do |parcel|
        volume = Parcel.volume_m3(parcel, content)
        total += volume
        breathable += volume if content.tags(parcel.fetch(:resource)).include?(:breathable)
      end

      return 0.0 unless total.positive?

      breathable / total
    end

    # Whitedamp and stinkdamp: air that is still mostly air and still kills you. A resource
    # declaring no `toxic_fraction:` can never trip this, which is every substance we have.
    def poisoned?(parcels, content)
      total = parcels.sum { |p| Parcel.volume_m3(p, content) }
      return false unless total.positive?

      parcels.any? do |parcel|
        limit = content.resource(parcel.fetch(:resource))[:toxic_fraction]
        next false if limit.nil?

        (Parcel.volume_m3(parcel, content) / total) > limit.to_f
      end
    end

    # Fatigue per second from the air alone. Zero above `SAFE`, which is the great majority of
    # every match — this must cost nothing when nothing is wrong.
    def rate(fraction, minion, state)
      return 0.0 if fraction >= SAFE || unbreathing?(minion)

      deficit = ((SAFE - fraction) / SAFE).clamp(0.0, 1.0)
      MAX_RATE * (deficit**EXPONENT) / reserve(minion) * (1.0 - masking(minion, state))
    end

    # A golem does not breathe, and that is binary — a gate rather than a resistance, for the
    # same reason `gated_by:` multiplies where `aided_by:` adds.
    def unbreathing?(minion) = Injury.numeric(minion.tag(:unbreathing)).positive?

    # **Apparatus runs out, and that is the whole character of it.** A rescue team's range is
    # the duration of the set on their back, not their courage — so a respirator protects
    # exactly as well as it ever did right up until the moment it is a mask full of the same
    # air as the room. An empty set is worth nothing at all, with no taper: there is no half a
    # breath.
    def masking(minion, state)
      return 0.0 unless air_left(state).positive?

      respirator(minion)
    end

    def respirator(minion) = Injury.numeric(minion.tag(:respirator)).clamp(0.0, 1.0)

    # Ticks, not seconds, because what a player needs is "how many turns have I got" and a set
    # is rated by how long it lasts rather than by what it holds.
    def air_left(state) = state.fetch(:apparatus, 0.0)

    # One tick's worth, spent whenever the set is doing anything. **Nobody husbands it**: a
    # minion wearing apparatus in bad air breathes from it, and walking out is the only way to
    # stop. Refilling is not modelled.
    def draw(state, fraction, minion)
      return state unless respirator(minion).positive? && air_left(state).positive?
      return state if fraction >= SAFE || unbreathing?(minion)

      state.merge(apparatus: [ air_left(state) - 1.0, 0.0 ].max)
    end

    def reserve(minion) = minion.endurance.clamp(RESERVE.begin, RESERVE.end)

    # The clock past collapse. Fills only once they are down and the air is still bad; drains
    # otherwise, at the same rate, so somebody pulled back from 0.9 nearly died and recovers.
    def advance(state, rate, dt)
      down = state.fetch(:fatigue, 0.0) >= Fatigue::RANGE.end && rate.positive?
      step = (down ? rate : -MAX_RATE) * dt

      state.merge(asphyxia: (state.fetch(:asphyxia, 0.0) + step).clamp(RANGE.begin, RANGE.end))
    end

    def suffocated?(state) = state.fetch(:asphyxia, 0.0) >= RANGE.end
  end
end
