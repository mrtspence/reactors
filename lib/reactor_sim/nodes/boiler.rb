# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A vessel where a liquid and its own vapour live together, and the vapour outlet is above
    # the liquid. A steam drum, an evaporator, a flash vessel, a reboiler.
    #
    # It is a `Vessel` in every respect but one: **what leaves through the vapour outlet is
    # never quite dry**, and how wet it is depends on how the thing is being run. That is the
    # whole of the difference, and it is enough to want its own class — a tank does not care
    # what shape its contents are, and it should not have to carry configuration explaining
    # that it does not.
    #
    # ## Carryover, declared as steam quality
    #
    # `Arbiter` biases a stream's composition with a per-tag multiplier (see
    # `Node#transport_affinity`). **The multiplier for this is around 1.2 × 10⁻⁵ and nobody
    # could have guessed that**, because it works against the mass ratio actually held: a drum
    # sitting at 2620 kg of water and 6.2 kg of steam is 424 to 1, so anything near 1.0 sends
    # almost pure water down the steam line. Measured on the steam engine — opening the outlet
    # to liquid without this made **99.77%** of what left the boiler water.
    #
    # So it is declared the way an engineer already thinks about it, as the **wetness of the
    # steam delivered**, and the multiplier is solved for:
    #
    #     w·L / (w·L + G) = wetness   →   w = wetness · G / ((1 − wetness) · L)
    #
    # That is also self-calibrating, which a fixed multiplier is not: the same declaration keeps
    # meaning the same thing as the water level moves through the run.
    #
    # ## What makes it worse is the level, which is the lever a player has
    #
    # Mechanical carryover comes from the water being too close to the outlet for the drum to
    # separate — high level, unstable level, sudden load. Below `onset_fill` this is a
    # 99.5%-dry boiler, which is what a real one manages and is invisible in play. Above it,
    # the quality degrades toward `foaming_wetness` and the water goes over with the steam.
    #
    # **This is the mechanic the feed pump was missing.** Filling the boiler used to be free
    # above the level needed to avoid burning it — a floor with no ceiling. Now there is both,
    # and holding the band between them is the job.
    #
    # Chemical foaming (alkalinity, dissolved solids) is the other real cause and is not
    # modelled; if water chemistry ever arrives, it belongs here as a second term on `wetness`.
    class Boiler < Vessel
      # How far past the offtake the level has to rise before delivery is essentially solid water,
      # as a fraction of the drum's volume. **Short on purpose**: a pipe whose mouth is under
      # water draws water almost at once, so this is the depth of submergence at which the drum
      # has stopped separating at all, not a gradual second ramp.
      #
      # It was 0.5, and that made the slug regime unreachable in practice. Reaching a wetness that
      # can actually flood a cylinder then needed the drum to be **99.9% full of liquid** — and a
      # boiler that full makes no steam, so `transport_affinity` returns nothing and there is no
      # flow to carry the water anywhere. The mechanic defeated itself: the only states wet enough
      # to matter were states with nothing moving.
      SLUG_RANGE = 0.15

      attr_reader :steam_port, :carryover_tags, :wetness, :foaming_wetness, :priming_wetness,
                  :onset_fill, :swell_pa_per_s, :max_swell, :swell_settle_s, :swell_rise_s

      def initialize(id:, steam_port:, carryover_tags: [ :liquid ],
                     wetness: 0.005, foaming_wetness: 0.30, priming_wetness: 0.97,
                     onset_fill: 0.55, swell_pa_per_s: 0.0, max_swell: 0.35,
                     swell_settle_s: 8.0, swell_rise_s: 2.0, **options)
        super(id: id, **options)
        @steam_port = steam_port.to_sym
        @carryover_tags = carryover_tags.map(&:to_sym).freeze
        @wetness = wetness.to_f
        @foaming_wetness = foaming_wetness.to_f
        @priming_wetness = priming_wetness.to_f
        @onset_fill = onset_fill.to_f
        # Rate of pressure fall at which the drum holds `max_swell` of its water as
        # bubbles. Zero disables swell and leaves carryover a function of the static level.
        @swell_pa_per_s = swell_pa_per_s.to_f
        @max_swell = max_swell.to_f.clamp(0.0, 0.95)
        # How long the bubbles take to disengage once the pressure steadies.
        @swell_settle_s = swell_settle_s.to_f
        # And how long they take to form. Zero makes the void track a single tick's pressure
        # difference, which is solver noise rather than physics — see `smoothed_fall`.
        @swell_rise_s = swell_rise_s.to_f
        freeze
      end

      # How fast the drum is losing pressure, kept so `swell_fraction` can read it next tick.
      #
      # Recorded rather than derived because a rate of change is the one thing a node reading a
      # single frozen tick cannot see. Stored already divided by `dt` so the key is a rate and
      # says so — the first version stored a per-tick mass and compared it against a per-second
      # constant, which made the void 25× too small and the mechanic inert.
      #
      # > **Offtake was the wrong driver and it is worth saying why.** Swell was first scaled by
      # > how much steam was leaving, which sounds equivalent and is not. It taxed *steady*
      # > running — a hard-pulling engine at a safe level sat at 20% void permanently — while
      # > giving almost nothing on the transient that actually causes priming, because opening a
      # > regulator that is already 60% open barely changes the flow. Worse, it is anti-correlated
      # > with the hazard: a drowning engine is slow, so it pulls *less*, so it swells *less*,
      # > exactly when the glass is highest.
      # >
      # > Pressure fall is what the sources describe and what the physics is: demand outruns
      # > generation, the drum pressure drops, the saturation temperature drops with it, and the
      # > water's own sensible heat flashes it into bubbles. In steady running `dP/dt` is zero and
      # > **normal operation is untouched exactly**, rather than merely a little worse.
      def apply(state, ctx, grant)
        result = super
        next_state, events = result.is_a?(Array) ? result : [ result, [] ]
        now = pressure_pa(next_state, ctx.content)
        was = state.fetch(:pressure_pa_seen, now)
        trend = smoothed_trend(state, (was - now) / ctx.dt, ctx.dt)
        fall = [ trend, 0.0 ].max
        next_state = next_state.merge(
          pressure_pa_seen: now,
          pressure_trend_pa_per_s: trend,
          pressure_drop_pa_per_s: fall,
          swell: settled_swell(state, fall, ctx.dt),
          steam_kg_per_s: grant.sent_kg(@steam_port) / ctx.dt
        )

        events.empty? ? next_state : [ next_state, events ]
      end

      # ## The pressure fall the water actually responds to, which is not one tick's worth
      #
      # **A rate of change measured across a single timestep is whatever the solver did in that
      # step, not a physical signal.** Taken raw, a one-tick 2.3 kPa dip on opening the regulator
      # read as 9 102 Pa/s — past the 8 000 Pa/s that saturates the mechanic — so the void went
      # from nothing to its maximum in 250 ms and the gauge glass jumped **40 percentage points
      # in one tick**, then decayed for twelve seconds. Every isolated blip did that. It was a
      # spike detector wearing a swell model's clothes, and it made the glass unreadable: at a
      # steady feed of 35 it showed 90.9% full on a drum genuinely 50.7% full.
      #
      # Smoothed over `swell_rise_s`, because that is the physics rather than a filter: bubbles
      # take finite time to nucleate and grow, so a void fraction **cannot** track a 250 ms
      # transient. It is also exactly the discrimination the mechanic needs — a sustained demand
      # step still saturates it within a few seconds, while a single tick of solver noise reaches
      # about a tenth of the way and decays.
      #
      # Note the raw signal is zero on most ticks even under load, because a fire keeping up with
      # demand leaves the pressure *rising*. That is why this must integrate rather than sample:
      # the interesting quantity is how hard the drum is being pulled down over a second or two,
      # not whether it happened to be falling on the tick we looked.
      #
      # > **Smooth the SIGNED rate and rectify afterwards, never the other way round.** Rectifying
      # > first and then averaging takes the mean of `|x|` where the mean of `x` was wanted, so a
      # > symmetric tick-scale ripple with no net drift averages to a large *positive* fall out of
      # > nothing at all. Measured: swell pinned at its 45% maximum permanently whenever the engine
      # > was working, on a boiler whose pressure was not falling — the glass read 92% full on a
      # > drum genuinely 50.6% full, and a sustained 8 kPa/s would have emptied it of pressure
      # > eighteen times over in the time it supposedly held. A rectified average is a rectifier,
      # > not an average.
      def smoothed_trend(state, instant, dt)
        return instant if @swell_rise_s <= 0.0

        held = state.fetch(:pressure_trend_pa_per_s, 0.0)
        held + ((instant - held) * (1.0 - Math.exp(-dt / @swell_rise_s)))
      end

      # **Bubbles form as fast as the smoothed pressure fall implies and disengage slowly**, so
      # the void follows that signal up and decays back over `swell_settle_s`. That asymmetry is the
      # mechanic: without it swell existed for the one or two ticks the pressure was actually
      # moving, which is far too brief to carry any quantity of water anywhere — measured peak
      # wetness of 0.62 that had collapsed to 0.04 fifty ticks later, and a cylinder that never
      # got above 0.17 occupancy.
      #
      # A real drum takes tens of seconds to settle after a sharp demand change, which is exactly
      # why the level swings so far and why a driver has time to be caught by it.
      def settled_swell(state, fall, dt)
        target = @swell_pa_per_s.positive? ?
          @max_swell * (fall / @swell_pa_per_s).clamp(0.0, 1.0) : 0.0
        held = state.fetch(:swell, 0.0)
        return target if target >= held || @swell_settle_s <= 0.0

        held * Math.exp(-dt / @swell_settle_s)
      end

      # **The port's `accepts:` still has to admit liquid**, and that is not a redundancy. A tag
      # filter is structural — it is the operation saying what the pipework is for — and it runs
      # before any of this. A `[:gas]` outlet makes carryover impossible however hard the drum
      # is boiling, which is exactly the trap the chimney fell into.
      def transport_affinity(port_id, state, ctx)
        return {} unless port_id == @steam_port

        content = ctx.content
        held = parcels(state)
        gas = held.select { |p| content.tags(p.fetch(:resource)).include?(:gas) }
        # **Only what actually carries over goes in the denominator.** Partitioning gas vs
        # not-gas put every solid in here too, so a drum holding any sludge or scale delivered
        # less wetness than it declared — the solve is `w·L/(w·L + G) = wetness`, and `L` has to
        # be the mass the weight is published against or the identity does not hold.
        liquid = held.select { |p|
          (content.tags(p.fetch(:resource)) & @carryover_tags).any?
        }
        gas_kg = Parcel.total_kg(gas)
        liquid_kg = Parcel.total_kg(liquid)
        return {} if gas_kg <= Parcel::EPSILON || liquid_kg <= Parcel::EPSILON

        wet = carryover_wetness(state, content)
        weight = wet * gas_kg / ((1.0 - wet) * liquid_kg)

        @carryover_tags.to_h { |tag| [ tag, weight ] }
      end

      # ## Swell: the bubbles the water is holding, and the reason priming is an *event*
      #
      # A drum working hard is not water with steam above it — it is water full of bubbles, and
      # the bubbles take room. Draw harder and the pressure falls, the water flashes, the void
      # grows and **the level lifts**, which is what carries it over into the offtake. Ease off
      # and it collapses back. This is the shrink/swell every boiler-level controller is built to
      # fight, and it is why the sources put priming at *"the regulator opened sharply or steam
      # demand high"* rather than at any particular water level.
      #
      # Without it, carryover was a function of the static level alone: a steady property of how
      # full the boiler was, with no transient and therefore no moment. A player could be at 74%
      # for an hour and nothing would ever happen. **The hazard has to be something you do, not
      # somewhere you are.**
      #
      # Driven by how fast the drum is **losing pressure**, which is what flashes the water into
      # bubbles. Zero in steady running, whatever the load, so this costs an ordinary engine
      # nothing at all — it is a transient or it is not there. Evolved in `apply`; see
      # `settled_swell` for why it decays rather than tracking.
      #
      # (Named `swell_fraction` rather than `void_fraction` because **`Vessel` already has a
      # `void_fraction`** — the packing of a bed, which is configuration, not state. Overriding it
      # here gave one name two meanings and two arities on the same class.)
      def swell_fraction(state) = state.fetch(:swell, 0.0)

      # The level the water actually stands at, bubbles included: `fill / (1 − swell)`.
      #
      # The bubbles are held *in* the liquid, so a drum 60% full of water carrying 40% swell reads
      # 100% — full to the offtake, and every bit of it two-phase. That is the geometry of it,
      # and it is why a high glass and a hard pull are dangerous together and neither is alone.
      #
      # **Deliberately not clamped at 1.0.** How far *past* the offtake the swelled level reaches
      # is the difference between wet steam and a slug of water, and clamping threw that away.
      def effective_fill(state, content)
        return 0.0 if volume_m3 <= 0.0

        fill = (volume_m3 - room_m3(state, content)) / volume_m3
        fill / (1.0 - swell_fraction(state))
      end

      # Calm below the onset level, degrading linearly toward the foaming figure as it fills.
      #
      # **Level means the LIQUID, and `contents_volume` is not it.** That counts every parcel at
      # its nominal density, gases included, and a gas has no business being measured that way —
      # it expands to fill whatever it is in. Using it read a **317% full** boiler and pinned
      # this at the foaming figure from the first tick, so every engine primed itself to death
      # regardless of how it was fired. `room_m3` already applies the right rule (condensed
      # phases only), so the water level is what it has not left room for.
      #
      # ## Two regimes, because carryover is not one phenomenon
      #
      # **Foam and mist** below the offtake: the drum has less and less height to separate in as
      # the level rises, so quality degrades toward `foaming_wetness`. This is the whole of what
      # a well-run boiler ever does, and it is gradual.
      #
      # **A slug** above it: once the swelled level reaches the steam pipe, what is in the pipe is
      # water, and delivery goes to `priming_wetness` over `SLUG_RANGE` of further swell. That is
      # a different thing with a different shape, and collapsing the two into one linear ramp gets
      # both wrong — raising `foaming_wetness` alone to reach slug quality made an ordinary 73%
      # glass deliver 40% wet steam, which turned the whole upper half of the feed range into a
      # failure. Foam is what you run in; a slug is what breaks the engine.
      def carryover_wetness(state, content)
        return @wetness if volume_m3 <= 0.0 || @onset_fill >= 1.0

        fill = effective_fill(state, content)
        return @wetness if fill <= @onset_fill

        over = ((fill - @onset_fill) / (1.0 - @onset_fill)).clamp(0.0, 1.0)
        foam = @wetness + ((@foaming_wetness - @wetness) * over)
        return foam if fill <= 1.0

        slug = ((fill - 1.0) / SLUG_RANGE).clamp(0.0, 1.0)
        foam + ((@priming_wetness - foam) * slug)
      end
    end
  end
end
