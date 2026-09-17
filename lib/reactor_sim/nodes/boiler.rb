# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A vessel where a liquid and its own vapour live together, with the vapour outlet above the
    # liquid. A steam drum, an evaporator, a flash vessel, a reboiler.
    #
    # A `Vessel` in every respect but one: **what leaves through the vapour outlet is never quite
    # dry**, and how wet depends on how the thing is being run.
    #
    # **Carryover is declared as steam quality.** `Arbiter` biases a stream's composition with a
    # per-tag multiplier (`Node#transport_affinity`), but that multiplier works against the mass
    # ratio actually held — a drum at 2620 kg of water and 6.2 kg of steam is 424 to 1, so
    # anything near 1.0 sends almost pure water down the steam line, and the right figure is
    # around 1.2 × 10⁻⁵. So the declaration is the **wetness of the steam delivered** and the
    # multiplier is solved for:
    #
    #     w·L / (w·L + G) = wetness   →   w = wetness · G / ((1 − wetness) · L)
    #
    # That is self-calibrating, which a fixed multiplier is not: the declaration keeps meaning
    # the same thing as the level moves through the run.
    #
    # **The level is what makes it worse, and the level is the player's lever.** Mechanical
    # carryover comes from water too close to the outlet for the drum to separate — high level,
    # unstable level, sudden load. Below `onset_fill` this is a 99.5%-dry boiler and invisible in
    # play; above it the quality degrades toward `foaming_wetness`. Filling the boiler therefore
    # has a ceiling as well as a floor, and holding the band between them is the job.
    #
    # Chemical foaming (alkalinity, dissolved solids) is the other real cause and is not
    # modelled; water chemistry would belong here as a second term on `wetness`.
    class Boiler < Vessel
      # How far past the offtake the level rises before delivery is essentially solid water, as a
      # fraction of the drum's volume. **Short on purpose**: a pipe whose mouth is under water
      # draws water almost at once, so this is the submergence at which the drum has stopped
      # separating, not a gradual second ramp. A long range makes the slug regime unreachable —
      # it needs a drum ~99.9% full, and a boiler that full makes no steam, so there is no flow
      # to carry the water anywhere.
      SLUG_RANGE = 0.15

      # Where the metal starts losing strength, as a fraction of the temperature at which it stops
      # being structural. Steel and the irons hold up well to a dull heat and then give way
      # quickly, so this is flat below and steep above. 0.7 of 750 K is 525 K for wrought iron,
      # which leaves a drum at its own saturation temperature (430–455 K) at full strength — the
      # point being that a healthy boiler must not be taxed for being hot, only a starved one.
      CREEP_ONSET_FRACTION = 0.7

      # **What destroys a boiler is its water, not its pressure.** A drum holds water at
      # saturation *under pressure*; open it and the water is instantly superheated against its
      # new boiling point, and the excess sensible heat flashes part of it to steam:
      #
      #     x = c_p · (T_sat(P_vessel) − T_sat(P_ambient)) / h_fg
      #
      # At 609 kPa that is 11% of the water at once — 362 kg from a full drum, **604 m³ at
      # atmospheric pressure trying to leave a 5 m³ shell.**
      #
      # **Flashing cannot raise the pressure**: making steam costs latent heat, so the water
      # cools and the pressure follows it down (a vessel run water-solid is the exception). The
      # destructive quantity is the *volume*, which peels the plate back from the rent and
      # unzips the shell — one staybolt lets go and the rest follow together.
      #
      # So the mode turns on how much flash steam is available, as a multiple of the drum's own
      # volume. That reproduces the history a pressure ratio gets backwards: a low-water
      # crown-sheet failure at working pressure is the classic catastrophic explosion, not a
      # gentle split. A drum splits quietly only when there is little superheat to release — low
      # pressure, or nearly no water left.
      #
      # **12 is measured at the real event**, not from a table: running into the low-water hazard
      # with the plug removed, the drum ruptures holding 626 kg at 609 kPa — 67 kg of flash
      # steam, **22.8 drum-volumes**. That keeps the crown-sheet rupture explosive by a factor of
      # 1.9 while leaving the quiet regimes quiet: the same water at 265 kPa is 11.4, a nearly-dry
      # drum 4.0, a cold one 0. Ten-odd volumes is also where the criterion means something
      # physically — no rent passes ten vessel-volumes in the time the flash takes.
      FLASH_EXPANSION_FOR_RUPTURE = 12.0

      attr_reader :steam_port, :carryover_tags, :wetness, :foaming_wetness, :priming_wetness,
                  :onset_fill, :swell_pa_per_s, :max_swell, :swell_settle_s, :swell_rise_s,
                  :crown_fill, :fired_by

      def initialize(id:, steam_port:, carryover_tags: [ :liquid ],
                     wetness: 0.005, foaming_wetness: 0.30, priming_wetness: 0.97,
                     onset_fill: 0.55, swell_pa_per_s: 0.0, max_swell: 0.35,
                     swell_settle_s: 8.0, swell_rise_s: 2.0,
                     crown_fill: 0.0, fired_by: nil, working_pressure_pa: nil, **options)
        super(id: id, **options)
        # What this drum is FOR, as opposed to what its shell can stand. `rated_pressure_pa`
        # comes from hoop stress and is ~2.4x this on a correct boiler, so it is no use as a
        # "there is a full head of steam" mark. Nil means this drum declines to say — an
        # evaporator has no working pressure worth announcing — and then nothing is emitted.
        @working_pressure_pa = working_pressure_pa&.to_f
        @steam_port = steam_port.to_sym
        @carryover_tags = carryover_tags.map(&:to_sym).freeze
        @wetness = wetness.to_f
        @foaming_wetness = foaming_wetness.to_f
        @priming_wetness = priming_wetness.to_f
        @onset_fill = onset_fill.to_f
        # The fill fraction at which the fire-side plate begins to come out of the water, and the
        # node whose fire is on the other side of it. Zero (the default) means this drum has no
        # crown sheet modelled at all, which is right for an evaporator or a flash vessel — the
        # hazard belongs to a drum with a furnace under it.
        @crown_fill = crown_fill.to_f
        @fired_by = fired_by&.to_sym
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
          steam_kg_per_s: grant.sent_kg(@steam_port) / ctx.dt,
          # Recorded rather than derived on demand because it needs the *fire's* temperature,
          # which is a cross-node read — so a `Sources::Derived` gauge could not compute it and
          # the fusible plug would have to reach for the firebox itself. One node owns it.
          crown_exposure: crown_exposure(next_state, ctx.content),
          crown_temperature_k: crown_temperature_k(next_state, ctx)
        )

        next_state, raised = note_steam_raised(next_state, ctx, now)
        events += raised

        events.empty? ? next_state : [ next_state, events ]
      end

      # How far the pressure has to fall before a second full head of steam counts as a new one,
      # as a fraction of the working pressure. Hysteresis for the same reason `ReliefValve` needs
      # it, though the danger is milder here: a drum hovering at its working pressure would
      # otherwise announce itself at the tick rate.
      REARM_FRACTION = 0.9

      # **This re-arms rather than latching forever**, and that is a deliberate difference from
      # the fusible plug. "The first time ever" is the delivery tier's question to answer from
      # its own records; what the drum can honestly report is that it has *a* full head of steam
      # now, each time it comes back up to one. An interval predicate — an hour of running
      # without lifting the safety valve — needs that interval re-opened after a bad spell, and a
      # latch would give it exactly one chance per match.
      def note_steam_raised(state, ctx, pressure_pa)
        return [ state, [] ] if @working_pressure_pa.nil?

        had = state.fetch(:full_head, false)
        has = pressure_pa >= @working_pressure_pa ||
              (had && pressure_pa > (@working_pressure_pa * REARM_FRACTION))
        return [ state.merge(full_head: has), [] ] if has == had || !has

        [ state.merge(full_head: true),
          [ Event.build(type: :steam_raised, node: id, label: label, severity: :info,
                        tick: ctx.tick,
                        detail: { pressure_pa: pressure_pa.round(1),
                                  working_pressure_pa: @working_pressure_pa.round(1) }) ] ]
      end

      # **The crown sheet: the plate over the fire, and the one hazard a lumped body cannot
      # express.** `temperature_k` on a drum at 5% water is not high — it is the same saturation
      # temperature as one at 60%, held by a smaller mass. **A dry boiler in a lumped model is
      # not hot, merely empty**, so no `max_temperature_k` on this node could ever trip however
      # far the water fell.
      #
      # The real failure is *positional*. While water covers the plate it runs a few degrees
      # above the water and is safe at any fire, because boiling water against steel is an
      # excellent heat sink. Uncover it and it is steel with a fire on one side and steam — a
      # poor conductor — on the other: red heat in minutes, then it lets go, and the whole water
      # content flashes through the hole at once.
      #
      # So the plate gets a derived temperature, blended between the water it should be under and
      # the fire it is over:
      #
      #     T_crown = T_water + exposure · (T_fire − T_water)
      #
      # A lumped approximation of its own, deliberately: a bare plate still conducts something
      # into the steam space, so it does not truly reach fire temperature. What matters is that
      # it is monotone in exposure and destructive before *full* exposure, which makes low water
      # a gradient rather than a cliff.
      #
      # > **It reads the TRUE fill while the gauge glass shows the swelled one, and that gap is
      # > the trap.** `effective_fill` includes the bubbles, because that is what a real glass
      # > shows; the plate is cooled by water, not froth. So exactly when the engine is worked
      # > hard enough to swell the drum, the glass reads high while the plate uncovers — which is
      # > why every firing manual says to trust the try-cocks over the glass.
      def crown_exposure(state, content)
        return 0.0 if @crown_fill <= 0.0 || volume_m3 <= 0.0

        fill = (volume_m3 - room_m3(state, content)) / volume_m3
        return 0.0 if fill >= @crown_fill

        ((@crown_fill - fill) / @crown_fill).clamp(0.0, 1.0)
      end

      # What the plate is actually at. Falls back to the drum's own temperature when there is no
      # fire declared or the firebox cannot be read, so an unfired drum is never in danger.
      def crown_temperature_k(state, ctx)
        water = temperature_k(state, ctx.content)
        exposure = crown_exposure(state, ctx.content)
        return water if exposure <= 0.0 || @fired_by.nil?

        fire = ctx.node_temperature(@fired_by)
        return water if fire.nil? || fire <= water

        water + (exposure * (fire - water))
      end

      # Pressure and bulk temperature still apply — a boiler can still be over-pressured — but
      # the crown sheet is measured against the **plate's** temperature rather than the drum's.
      #
      # Taken as the larger of the two rather than the sum, because they are two descriptions of
      # the same shell and adding them would charge a boiler twice for one degree of overheat.
      def stress_per_second(state, ctx)
        [ super, crown_stress_per_second(state, ctx) ].max
      end

      # Ascending severity — `Concerns::Wearing` escalates forward through this order and never
      # back, so a drum that has let go cannot be re-described as merely split once its own hole
      # has taken the pressure away.
      def failure_modes = { seam_split: {}, explosion: {} }

      # **The same drum can be destroyed two ways and the mode is not the cause.** Over-pressure
      # and a dry crown sheet both end as a hole in the shell; what separates a split from an
      # explosion is how much superheated water is behind the metal when it goes, which is a
      # reading at that instant rather than a property of what broke it.
      def failure_mode(state, ctx, _cause)
        flash_expansion(state, ctx) >= FLASH_EXPANSION_FOR_RUPTURE ? :explosion : :seam_split
      end

      # How much of the water would boil away the instant the shell is opened to the outside.
      #
      # Straight from the saturation curve the engine already uses for everything else — the
      # superheat is the gap between the boiling point at this pressure and at ambient, and the
      # sensible heat in that gap buys latent heat at `h_fg`. Per parcel, because a drum may
      # hold more than one condensable and each has its own curve.
      def flash_steam_kg(state, ctx)
        content = ctx.content
        pressure = pressure_pa(state, content)
        return 0.0 if pressure <= Units::STANDARD_PRESSURE_PA

        parcels(state).sum { |parcel| parcel_flash_kg(parcel, pressure, content) }
      end

      # The flash steam's volume at ambient, as a multiple of the drum's own — which is the
      # figure that decides whether a rent relieves or unzips. Dimensionless on purpose: it
      # means the same thing to a locomotive barrel and a tea urn.
      # **How big it was, not merely that it happened.** `Vessel` reports the temperature and
      # pressure; a drum adds what actually decides the violence — the flash expansion that
      # peeled the plate back, and the water behind it.
      #
      # This is on the event rather than left to be looked up, because it is what a hazard
      # SCALES with: a small drum letting go and a locomotive barrel letting go are not the same
      # event for anybody standing nearby, and `Tick#hazards_from` reads this figure to say so.
      # It also means the durable record carries why an injury was as bad as it was.
      def failure_detail(state, ctx)
        super.merge(flash_expansion: flash_expansion(state, ctx).round(2),
                    contents_kg: contents_kg(state).round(1))
      end

      def flash_expansion(state, ctx)
        return 0.0 if volume_m3 <= 0.0

        content = ctx.content
        pressure = pressure_pa(state, content)
        return 0.0 if pressure <= Units::STANDARD_PRESSURE_PA

        volume = parcels(state).sum do |parcel|
          kg = parcel_flash_kg(parcel, pressure, content)
          next 0.0 if kg <= Parcel::EPSILON

          kg * vapour_volume_per_kg(parcel, content)
        end
        volume / volume_m3
      end

      # ## What the plate can still hold at the temperature it has reached
      #
      # **A crown sheet does not fail because it is hot. It fails because it is hot and there is
      # pressure behind it**, and that distinction is the whole of this method. A bare plate over
      # a dead fire warps; a bare plate with steam pushing on it tears out along its seams.
      #
      # So the two ratings are multiplied rather than checked separately: `rated_pressure_pa` is
      # what the shell holds cold (derived from the plate by hoop stress — see
      # `Concerns::Pressurized`), and that allowance is knocked down as the metal loses strength.
      # The immediate consequence is the one that matters in play: **a boiler carrying more
      # pressure fails sooner on the same amount of overheating.** A driver who has wound the
      # safety valve up has less margin when the water goes, not the same margin.
      #
      # Metal keeps essentially all of its strength until creep sets in and then gives it up
      # quickly, so this is flat below `CREEP_ONSET_FRACTION` of the rating and falls linearly to
      # nothing at it — rather than declining from ambient, which would tax a perfectly healthy
      # boiler for being at its own saturation temperature.
      def crown_allowable_pressure_pa(state, ctx)
        ceiling = rated_pressure_pa(ctx.content)
        rated_t = rated_temperature_k(ctx.content)
        return ceiling unless rated_t.finite? && ceiling.finite?

        onset = rated_t * CREEP_ONSET_FRACTION
        crown_t = crown_temperature_k(state, ctx)
        return ceiling if crown_t <= onset

        ceiling * ((rated_t - crown_t) / (rated_t - onset)).clamp(0.0, 1.0)
      end

      # Measured against the **cold** rating rather than against the allowance, because the
      # allowance goes to zero and a fraction with zero underneath it is not a gradient. This way
      # the worst case is bounded at `pressure / rated × stress_rate`, and it still rises smoothly
      # as the plate softens.
      def crown_stress_per_second(state, ctx)
        return 0.0 if stress_rate.zero? || @crown_fill <= 0.0

        ceiling = rated_pressure_pa(ctx.content)
        return 0.0 unless ceiling.finite? && ceiling.positive?

        excess = pressure_pa(state, ctx.content) - crown_allowable_pressure_pa(state, ctx)
        excess.positive? ? (excess / ceiling) * stress_rate : 0.0
      end

      # **The pressure fall the water responds to, which is not one tick's worth.** A rate of
      # change measured across a single timestep is whatever the solver did in that step, not a
      # physical signal — a one-tick 2.3 kPa dip reads as 9 102 Pa/s, past the figure that
      # saturates the mechanic, so the glass would jump 40 percentage points in 250 ms on
      # ordinary solver noise.
      #
      # Smoothed over `swell_rise_s` because that is the physics rather than a filter: bubbles
      # take finite time to nucleate and grow, so a void fraction cannot track a 250 ms
      # transient. It is also the discrimination the mechanic needs — a sustained demand step
      # saturates within seconds, while one tick of noise reaches a tenth of the way and decays.
      #
      # The raw signal is zero on most ticks even under load, because a fire keeping up leaves
      # the pressure *rising*. This must integrate rather than sample: the quantity is how hard
      # the drum is pulled down over a second or two, not whether it fell on the tick we looked.
      #
      # > **Smooth the SIGNED rate and rectify afterwards, never the other way round.** Rectifying
      # > first takes the mean of `|x|` where the mean of `x` was wanted, so a symmetric ripple
      # > with no net drift averages to a large positive fall out of nothing — pinning swell at
      # > its maximum on a boiler whose pressure is not falling. A rectified average is a
      # > rectifier, not an average.
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

      # **Swell: the bubbles the water is holding, and the reason priming is an *event*.** A drum
      # working hard is water full of bubbles, and the bubbles take room. Draw harder and the
      # pressure falls, the water flashes, the void grows and the level lifts, which is what
      # carries it over into the offtake; ease off and it collapses back. This is why the sources
      # put priming at *"the regulator opened sharply or steam demand high"* rather than at any
      # particular water level: **the hazard is something you do, not somewhere you are.**
      #
      # Driven by how fast the drum is losing pressure, which is what flashes the water into
      # bubbles. Zero in steady running whatever the load, so it costs an ordinary engine
      # nothing. Evolved in `apply`; see `settled_swell` for why it decays rather than tracks.
      #
      # Named `swell_fraction` rather than `void_fraction` because `Vessel` already has one — the
      # packing of a bed, which is configuration rather than state.
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
      # its nominal density, gases included, and a gas expands to fill whatever it is in — read
      # that way a drum measures over 300% full and pins at the foaming figure from tick one.
      # `room_m3` applies the right rule (condensed phases only), so the water level is what it
      # has not left room for.
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

      private

      # Per parcel, because a drum may hold more than one condensable and each has its own
      # saturation curve. Anything with no vapour phase declared simply does not flash.
      def parcel_flash_kg(parcel, pressure, content)
        resource = parcel.fetch(:resource)
        spec = content.resource(resource)
        phase = spec[:phase]
        return 0.0 unless phase && phase[:vapour]

        superheat = Resources::Saturation.saturation_temperature_k(spec, pressure) -
                    Resources::Saturation.saturation_temperature_k(spec, Units::STANDARD_PRESSURE_PA)
        return 0.0 unless superheat.positive?

        fraction = (content.specific_heat(resource) * superheat) /
                   phase.fetch(:latent_heat_j_per_kg).to_f
        parcel.fetch(:kg) * fraction.clamp(0.0, 1.0)
      end

      # Ideal gas at the vapour's own boiling point, which is the state the flash lands in.
      def vapour_volume_per_kg(parcel, content)
        spec = content.resource(parcel.fetch(:resource))
        vapour = spec.fetch(:phase).fetch(:vapour).to_sym
        molar = content.resource(vapour).fetch(:molar_mass_g_per_mol).to_f / 1000.0
        boiling = Resources::Saturation.saturation_temperature_k(spec, Units::STANDARD_PRESSURE_PA)

        Units::GAS_CONSTANT * boiling / (molar * Units::STANDARD_PRESSURE_PA)
      end
    end
  end
end
