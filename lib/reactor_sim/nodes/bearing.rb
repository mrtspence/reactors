# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A modelled friction interface — somewhere enough rubbing happens that the heat and the wear
    # should be real.
    #
    # Most interfaces in a machine never earn a node. A main journal does; a piston in its bore
    # very much does; a rope over a pulley will. What they share is two numbers — **sliding speed
    # and normal load** — and they differ only in how those are derived, which is what `duty:`
    # selects. Everything after that is one law.
    #
    #   config: supports (the shaft it drags on), duty, geometry, heat_capacity, material
    #   state:  joules, parcels (the oil in it)
    #
    # **It does not rotate.** The shaft turns; this is the stationary half it turns in, which is
    # why it is `Thermal` and not `Rotating` — and why it is a node at all rather than a property
    # of the flywheel. A journal running red hot inside a cool housing on a cool shaft is the
    # case `concerns/CLAUDE.md` means by "things that need genuinely distinct temperatures are
    # distinct nodes".
    #
    # Design: `docs/design_sketches/bearings.md`.
    class Bearing < Node
      include Concerns::Thermal
      include Concerns::Holds
      include Concerns::Wearing
      include Concerns::Fusible

      DUTIES = %i[journal slide].freeze

      # **Maximum operating temperature as a fraction of the melting point.** Babbitt melts at
      # 235–370 °C and is run to about 150 °C; against the 520 K in `materials.yml` that is 0.81.
      # One content figure therefore gives both thresholds — wiping above the service limit,
      # seizing at the melt — rather than a second number that could drift from the first.
      SERVICE_FRACTION = 0.8

      # **What "it has stopped turning" costs, as a multiple of the shaft's own `I/dt`.** That
      # figure halves a body per tick and no more, which is the right bound for a linearised brake
      # and far too gentle for a lock: against a cylinder still pushing, a seized journal at
      # `I/dt` left the engine limping at 45 rpm instead of stopping. At 40× the shaft keeps
      # 2.4% of its speed per tick and is at rest within two.
      SEIZED_CONDUCTANCE_MULTIPLE = 40.0

      # The Stribeck span, and it is the whole mechanic. A full oil film carries the shaft on
      # fluid and costs almost nothing; the same journal dry is a brake that destroys itself.
      # Real plain bearings run 0.001–0.005 flooded and 0.05–0.20 in boundary contact.
      # The Stribeck span, and a `:slide` sits an order of magnitude higher than a journal at
      # both ends. **`film:` does not mean hydrodynamic for a slide** — a piston ring is pressed
      # into the bore by the gas behind it, reverses twice a revolution, and stops dead at each
      # end of its travel, so it never builds a full wedge and runs mixed at best. That is why a
      # steam engine's mechanical loss lives in its rings and gland rather than in its journals,
      # and why a flooded journal costs well under a percent while these cost ten.
      #
      # Measured against the reference run: 0.10 puts the rings at 11% of indicated power, which
      # is the friction mean effective pressure a real engine of this size shows.
      MU = { journal: { film: 0.0025, boundary: 0.12 },
             slide: { film: 0.16, boundary: 0.34 } }.freeze

      attr_reader :supports, :duty, :loaded_by, :heat_capacity, :ambient_conductance,
                  :initial_temperature_k, :ambient_k, :volume_m3, :material,
                  :journal_radius_m, :static_load_n, :load_arm_m, :film_speed_m_s,
                  :viscous_c, :oil_charge_kg, :stroke_m, :load_area_m2,
                  :stress_rate, :wear_rate, :damages, :endangers, :oil_loss_kg_per_m, :lining_kg,
                  :mu_film, :mu_boundary, :emissivity, :radiating_area_m2

      def initialize(id:, supports:, heat_capacity:, label: nil, duty: :journal,
                     material: :babbitt, loaded_by: nil,
                     journal_radius_m: 0.11, static_load_n: 26_000.0, load_arm_m: 0.4,
                     stroke_m: 0.8, load_area_m2: 0.1,
                     film_speed_m_s: 0.9, viscous_c: 3.5, oil_charge_kg: 1.2,
                     volume_m3: 0.01, ambient_conductance: 42.0,
                     stress_rate: 0.0, wear_rate: 0.0, damages: {}, endangers: {},
                     oil_loss_kg_per_m: 0.0, lining_kg: 0.0, ports: nil,
                     mu_film: nil, mu_boundary: nil,
                     emissivity: 0.0, radiating_area_m2: 0.0,
                     initial_temperature_k: 293.15, ambient_k: 293.15)
        super(
          id: id, label: label,
          # One inlet, for the oil round. Tagged rather than named, so a better grade of oil is
          # a content change and not a wiring one.
          ports: ports || [ Port.new(id: :oil_in, direction: :inlet, accepts: [ :lubricant ]) ]
        )
        @supports = supports.to_sym
        @duty = duty.to_sym
        raise Error, "unknown bearing duty #{@duty.inspect}" unless DUTIES.include?(@duty)

        @loaded_by = loaded_by&.to_sym
        @heat_capacity = heat_capacity.to_f
        @ambient_conductance = ambient_conductance.to_f
        @initial_temperature_k = initial_temperature_k.to_f
        @ambient_k = ambient_k.to_f
        @volume_m3 = volume_m3.to_f
        @material = material&.to_sym
        @journal_radius_m = journal_radius_m.to_f
        @static_load_n = static_load_n.to_f
        @load_arm_m = load_arm_m.to_f
        @stroke_m = stroke_m.to_f
        @load_area_m2 = load_area_m2.to_f
        @film_speed_m_s = film_speed_m_s.to_f
        @viscous_c = viscous_c.to_f
        @oil_charge_kg = oil_charge_kg.to_f
        @stress_rate = stress_rate.to_f
        @wear_rate = wear_rate.to_f
        @damages = damages.freeze
        @endangers = endangers.freeze
        @oil_loss_kg_per_m = oil_loss_kg_per_m.to_f
        @lining_kg = lining_kg.to_f
        @mu_film, @mu_boundary = mu_for(@duty, film: mu_film, boundary: mu_boundary)
        @emissivity = emissivity.to_f
        @radiating_area_m2 = radiating_area_m2.to_f
        freeze
      end

      # **The white metal itself, which is not the assembly's thermal mass.** `heat_capacity` is
      # the brasses, their caps and the shaft between them; this is only the soft lining poured
      # into them, and only it can run out.
      def fusible_kg = @lining_kg

      # --- the oil round -------------------------------------------------------

      # **An active sink is authoritative about its own intake**, so a bearing asks for exactly
      # what it is short of.
      #
      # **The draw is declared even when it is zero**, and that is the whole method. Returning
      # `Intent.none` when full declares nothing, and a path with nothing declared at either end
      # is driven by the path — so oil kept arriving until the housing's *volume* was full. A
      # journal meant to hold 1.2 kg sat at 8.9, which is 0.01 m³ of oil, and no bearing could
      # ever run short of anything.
      def plan(state, _ctx)
        Intent.new(draws: { oil_in: [ @oil_charge_kg - contents_kg(state), 0.0 ].max })
      end

      # **Oil is spent by rubbing, not by time.** It is flung off the journal and burnt on it, so
      # the loss goes with sliding distance — a faster engine drinks more — and rises again with
      # temperature, which is the second half of the hot box: a bearing getting low runs hot, and
      # a bearing running hot loses oil faster.
      #
      # It leaves the operation. Nothing recovers burnt oil, so it is reported here and booked by
      # `Tick#record_injections`, the same way an injector reports what it put in.
      #
      # **The enthalpy goes with it**, or the energy balance drifts by the whole heat content of
      # every drop ever burnt off.
      def apply(state, ctx, _grant)
        lost = oil_loss_kg(state, ctx)
        state = state.merge(mass_consumed: 0.0, joules_discarded: 0.0)

        if lost.positive?
          gone, kept = Parcel.draw(state.fetch(:parcels, []), lost, ctx.content)
          state = rebalance(state.merge(parcels: kept,
                                        mass_consumed: Parcel.total_kg(gone),
                                        joules_discarded: Parcel.total_joules(gone)),
                            ctx.content)
        end

        # **After the oil, because melting is measured against the temperature the part is at.**
        # The white metal running out is what stops a seized bearing's temperature climbing
        # without limit, and it is the event a hot box is actually named for.
        run_melt(state, ctx)
      end

      def oil_loss_kg(state, ctx)
        return 0.0 unless @oil_loss_kg_per_m.positive?

        omega = ctx.node_omega(@supports).to_f
        return 0.0 unless omega.positive?

        sliding_m = omega * lever_m * ctx.dt
        [ @oil_loss_kg_per_m * sliding_m * heat_multiplier(state, ctx), contents_kg(state) ].min
      end

      # Roughly double at the service limit, and never less than 1. A bearing that is merely warm
      # is not losing oil appreciably faster than a cold one.
      def heat_multiplier(state, ctx)
        limit = service_temperature_k(ctx.content)
        return 1.0 if limit.infinite? || limit <= @ambient_k

        over = (temperature_k(state, ctx.content) - @ambient_k) / (limit - @ambient_k)
        1.0 + [ over, 0.0 ].max
      end

      # It starts wet. Nothing consumes the charge yet — the oiling round is what will, and what
      # will let it run out.
      def holds_initial_state(_rng, content)
        return { parcels: [] } unless @oil_charge_kg.positive?

        { parcels: [ Parcel.build(resource: :bearing_oil, kg: @oil_charge_kg,
                                  temperature_k: @initial_temperature_k, content: content) ] }
      end

      # --- the friction law ----------------------------------------------------

      # The shaft this drags on, rather than itself: a bearing has no momentum of its own.
      def drag_shaft = @supports

      # Where its dissipation goes: into its own metal, which is what makes it able to get too
      # hot. Nothing else in the engine books a drag this way — a belt's slip leaves as
      # `joules_to_friction` because a belt is not a node we model.
      #
      # **A seized interface declares a large multiple of the shaft's stall conductance**, which
      # is the only way a seizure can stop anything: `Tick#stress` zeroes momentum on the
      # *failing* node and this one does not rotate, and `Arbiter.settle_drive` severs a link
      # whose *end* failed and this is not an end. Both look like they would handle it. Neither
      # does — and a miss here fails silently, in the safe direction.
      def drag_conductances(state, ctx)
        omega = ctx.node_omega(@supports).to_f
        return {} unless omega.positive?

        cap = ctx.states[@supports] ? shaft_stall_conductance(ctx) : Float::INFINITY
        if state.fetch(:failure, nil) == :seized
          return { id => cap.finite? ? cap * SEIZED_CONDUCTANCE_MULTIPLE : cap }
        end

        { id => [ boundary_conductance(state, ctx, omega) + @viscous_c, cap ].min }
      end

      # **Coulomb friction, divided by ω to become a conductance.** The rubbing term is a force
      # times a lever and does not fall away as the shaft slows, so its conductance diverges at
      # rest — which is stiction, correctly, and why the caller caps it.
      def boundary_conductance(state, ctx, omega)
        mu = @mu_boundary - ((@mu_boundary - @mu_film) * film(state, omega))
        mu * load_n(ctx) * lever_m / omega
      end

      # **The duty supplies the kinematics; the fitting may supply its own friction.** `MU` is the
      # default for a plain bearing of that duty, and a part that behaves differently says so
      # rather than being approximated by one that does not.
      #
      # A roller is the case that forces it: it needs no oil film at all, so its friction is flat
      # across the Stribeck curve instead of swinging forty-fold, and there is no combination of
      # `film_speed_m_s` and oil charge that expresses "does not care about oil".
      def mu_for(duty, film:, boundary:)
        curve = MU.fetch(duty)
        [ (film || curve.fetch(:film)).to_f, (boundary || curve.fetch(:boundary)).to_f ]
      end

      # **Sliding speed per radian of shaft**, which is the one thing `duty:` has to supply. A
      # journal rubs at its own radius; a piston covers two strokes a revolution, so its mean
      # speed is `2·stroke·rev/s` — the same `v = lever × ω` with `stroke/π` for the lever.
      def lever_m = @duty == :slide ? @stroke_m / Math::PI : @journal_radius_m

      # **How much of the load the oil film is carrying**, 1.0 hydrodynamic and 0.0 metal on
      # metal. Two things have to be true at once: there has to be oil, and the journal has to be
      # turning fast enough to drag a wedge of it under itself.
      #
      # > **The speed gate does not bite on an ordinary start**, and that is worth knowing before
      # > relying on it. Measured: the film goes 0.000 to 1.000 inside ten simulated seconds of
      # > the regulator opening, because a full wedge forms by 78 rpm and the engine passes that
      # > almost at once — which is what real bearings do. It is live for a machine **barred
      # > over, stalling, or dragging a load it cannot turn**, not for starting one. The hazard
      # > that matters in normal running is **starvation**, through `wetness`.
      #
      # **Damage enters here rather than anywhere else**, and that is what makes the hot box a
      # runaway: wiped metal cannot hold a wedge, so a mode that opens the clearance raises the
      # boundary fraction, which raises the heat, which is what wiped it.
      def film(state, omega)
        return 0.0 if @oil_charge_kg <= 0.0 || @film_speed_m_s <= 0.0

        wetness = (contents_kg(state) / @oil_charge_kg).clamp(0.0, 1.0)
        speed = (omega * lever_m / @film_speed_m_s).clamp(0.0, 1.0)
        wetness * speed * derating(state, :film)
      end

      # What the machine is pressing this interface together with. **Declared rather than
      # discovered** — `loaded_by:` names the part doing the pressing, the same way `Cylinder`
      # declares what it drives. Read a tick late, like every cross-node read.
      #
      # A journal is bent by the **torque** passing over its crank throw; a piston ring is pushed
      # into its bore by the **gas pressure** behind it. Both make working the engine hard the
      # thing that wears it, which is the connection the whole mechanic rests on.
      def load_n(ctx)
        return @static_load_n if @loaded_by.nil?

        @static_load_n + (@duty == :slide ? gas_load_n(ctx) : torque_load_n(ctx))
      end

      def torque_load_n(ctx)
        return 0.0 if @load_arm_m <= 0.0

        ctx.node_state(@loaded_by)&.fetch(:torque, nil).to_f.abs / @load_arm_m
      end

      # **The area the gas presses this interface together over**, which for a piston ring is its
      # back face against the bore rather than the piston's own face. Not the swept area.
      def gas_load_n(ctx) = ctx.node_pressure(@loaded_by).to_f * @load_area_m2

      # A drag may not take more than the shaft has. The shaft owns that limit, not this.
      def shaft_stall_conductance(ctx)
        shaft = ctx.nodes[@supports]
        shaft.respond_to?(:max_drag_conductance) ? shaft.max_drag_conductance(ctx.dt) : Float::INFINITY
      end

      # --- the ladder ----------------------------------------------------------

      # **Running hot is not a failure — it is a gauge reading.** `break_part` zeroes durability,
      # so anything named here is already damage.
      #
      # A **wiped** bearing has lost the soft metal that gave it its clearance, so it can no
      # longer carry a film; it still turns, badly and hotly. A **seized** one has stopped, and
      # takes the shaft with it through the drag term.
      def failure_modes
        { wiped:  { derates: { film: 0.3 } },
          seized: { derates: { film: 0.0 } } }
      end

      def failure_mode(_state, _ctx, cause) = cause == :overload ? :seized : :wiped

      def failure_damages = @damages

      def failure_hazards = @endangers

      # **Two mechanisms, because they are two things**, and the measurement that proves they
      # cannot be one is in `docs/design_sketches/bearings.md` §3.10: a starved journal rubs at
      # 10 kW while healthy piston rings rub at 76, so any single coefficient fast enough to wipe
      # the one destroys the other.
      #
      #   rubbing   Archard — metal carried away, a service life measured in hours
      #   heat      time above the service limit — softening and oxidation, measured in minutes
      def stress_per_second(state, ctx)
        rubbing_wear(state, ctx) + heat_wear(state, ctx)
      end

      # **Archard: wear goes with load × sliding distance**, which per unit time is exactly the
      # boundary friction power the law already computes. The viscous term is left out on
      # purpose — an oil film shears, it does not wear anything, and that is the whole reason a
      # flooded journal lasts and a dry one does not.
      def rubbing_wear(state, ctx)
        return 0.0 unless @wear_rate.positive?

        omega = ctx.node_omega(@supports).to_f
        return 0.0 unless omega.positive?

        boundary_conductance(state, ctx, omega) * omega * omega * @wear_rate
      end

      # Time spent above the **service** limit, the same shape as `Conduit#stress_per_second`.
      def heat_wear(state, ctx)
        return 0.0 if @stress_rate.zero?

        limit = service_temperature_k(ctx.content)
        return 0.0 if limit.infinite?

        over = temperature_k(state, ctx.content) - limit
        over.positive? ? (over / limit) * @stress_rate : 0.0
      end

      # **Seizure is the melting point, flat, for a sound bearing and a wiped one alike.**
      #
      # `integrity` is deliberately unused, which is a departure from the concern's usual advice
      # that a worn part should fail sooner. Sliding the threshold down as durability drains
      # collapses the ladder: the bearing crosses the falling threshold before fatigue can finish,
      # so it seizes **without ever wiping** and the warning rung never happens. Measured — a
      # starved journal went straight to `:seized` at 481.7 K on a 0.63 integrity.
      #
      # What "running on wiped metal is worse" actually means here is the `film:` derate, which
      # raises the boundary fraction and drives the temperature up faster. That is a mechanism
      # rather than a second threshold, and it leaves the two rungs genuinely separate.
      def overload?(state, ctx, _integrity)
        rated = rated_temperature_k(ctx.content)
        return false if rated.infinite?

        temperature_k(state, ctx.content) >= rated
      end

      def service_temperature_k(content)
        rated = rated_temperature_k(content)
        rated.infinite? ? rated : rated * SERVICE_FRACTION
      end

      # `rim_speed_m_s` is what a hazard scales with: how fast the shaft was going when it went.
      def failure_detail(state, ctx)
        shaft = ctx.nodes[@supports]
        shaft_state = ctx.node_state(@supports)
        { temperature_k: temperature_k(state, ctx.content).round(2),
          rim_speed_m_s: (shaft.rim_speed(shaft_state).round(2) if shaft.respond_to?(:rim_speed) && shaft_state) }.compact
      end
    end
  end
end
