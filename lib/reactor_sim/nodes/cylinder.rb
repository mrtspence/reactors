# frozen_string_literal: true

module ReactorSim
  module Nodes
    # Where a gas pressure difference becomes shaft torque.
    #
    # Generic: nothing here knows what the working fluid is. Steam, compressed air, hot flue
    # gas — the cylinder cares only that something on the inlet side is at higher pressure
    # than whatever it exhausts into.
    #
    # ## Torque, not power
    #
    # Work is computed as a TORQUE from the pressure difference across the piston:
    #
    #     torque = ΔP × piston_area × crank_radius × efficiency
    #
    # which is independent of how fast it is turning. That matters enormously. Deriving
    # torque from a power figure means dividing by ω, which is infinite at rest — and a
    # machine that cannot be started from standstill is not much use. This way a stalled
    # cylinder has full torque and `power = torque × ω` correctly comes out as zero.
    #
    # ## Self-starting and self-limiting, with no special cases
    #
    #     at rest    inlet open → charge builds → pressure rises → torque → it turns
    #     spinning   exhaust flow ∝ ω → charge drops → pressure falls → torque falls → settles
    #
    # It finds its own operating point because turning faster means breathing harder. That
    # is also where the danger lives: shed the load and ω climbs, which admits more working
    # fluid, which pushes ω higher still. Nothing stands between that loop and a burst
    # rotating mass except a governor and an operator.
    #
    # ## What it exhausts into decides what kind of machine it is
    #
    # Wired to exhaust into a condenser held near vacuum, it is driven by the difference
    # between its supply and that vacuum. Wired to exhaust into the open air, it is driven
    # by however far its supply exceeds ambient. Same node, same formula, different graph —
    # which is what lets one definition cover machines that look nothing alike.
    class Cylinder < Node
      include Concerns::Thermal
      include Concerns::Holds
      include Concerns::Obstructs
      include Concerns::Pressurized
      include Concerns::Wearing

      # Valve gear cannot notch to nothing, and the expansion term goes logarithmic as it
      # tries — 5% of the stroke is already an extreme setting.
      MINIMUM_CUTOFF = 0.05

      OBSTRUCTION_TAGS = %i[liquid].freeze

      # What the drain cocks prefer. They are there to get water out, and a cock that took a
      # strictly proportional cut of the charge would be a small second exhaust rather than a
      # drain — blowing mostly steam past a cylinder that is filling with water.
      DRAIN_AFFINITY = { liquid: 30.0 }.freeze

      # The floor on how much water the exhaust stroke carries away. Never zero: some water
      # always goes out with the steam, and a part that removed *nothing* would make flooding a
      # certainty rather than a hazard.
      MIN_ENTRAINMENT = 0.02

      attr_reader :volume_m3, :heat_capacity, :ambient_conductance, :ambient_k,
                  :bore_m, :stroke_m, :crank_radius_m, :efficiency, :drives,
                  :cutoff_control_id, :clearance_fraction, :max_pressure_pa, :stress_rate,
                  :exhausts_to, :supplied_by, :default_working_fluid, :expansion_index,
                  :compression_fraction

      def initialize(id:, label: nil, bore_m:, stroke_m:, drives:, exhausts_to:, supplied_by:,
                     crank_radius_m: nil, efficiency: 0.85, clearance_fraction: 0.08,
                     heat_capacity: 6.0e4, ambient_conductance: 25.0,
                     ambient_k: Units::STANDARD_TEMPERATURE_K, cutoff_control_id: nil,
                     inlet_kg_per_s: 8.0, exhaust_kg_per_s: 12.0, drain_kg_per_s: 0.25,
                     relief_kg_per_s: 2.0, working_fluid: :steam,
                     expansion_index: 1.135, compression_fraction: 0.08,
                     entrainment_omega: 10.0, standing_kg_per_s: 0.15, standing_omega: 1.0,
                     max_pressure_pa: Float::INFINITY, stress_rate: 0.0)
        @bore_m = bore_m.to_f
        @stroke_m = stroke_m.to_f
        # Half the stroke, unless the crank is geared otherwise.
        @crank_radius_m = (crank_radius_m || (@stroke_m / 2.0)).to_f
        @efficiency = efficiency.to_f
        @clearance_fraction = clearance_fraction.to_f
        # Swept volume plus the clearance the piston never sweeps.
        @swept_m3 = Math::PI * ((@bore_m / 2.0)**2) * @stroke_m
        @volume_m3 = @swept_m3 * (1.0 + @clearance_fraction)

        super(
          id: id, label: label,
          ports: [
            # **Permissive, not gas-only.** A cylinder admits whatever its chest sends it, and
            # a `[:gas]` filter here would do what the same filter did on the chimney: strand
            # condensate upstream with no route out, because `Arbiter` requires every port on a
            # path to accept a resource. Wet steam reaching the valve is real, it is how priming
            # travels, and it is the road by which water gets into the cylinder at all.
            Port.new(id: :inlet, direction: :inlet, max_kg_per_s: inlet_kg_per_s),
            Port.new(id: :exhaust, direction: :outlet, max_kg_per_s: exhaust_kg_per_s),
            # Drain cocks. Small, permissive, and separate from the exhaust because it has to
            # work when the exhaust cannot: the exhaust is swept by the piston, so it carries
            # nothing at all while the engine is standing, which is exactly when condensate
            # collects. Leave it unlinked and a cylinder simply has no drain.
            Port.new(id: :drain, direction: :outlet, max_kg_per_s: drain_kg_per_s),
            # Separate from the drain because they are different devices with different jobs:
            # the cocks are a lever a driver works, this is a spring that acts whether anyone is
            # watching or not. One port each, because a port carries one path.
            Port.new(id: :relief, direction: :outlet, max_kg_per_s: relief_kg_per_s)
          ]
        )
        @drives = drives.to_sym
        # Declared rather than discovered from the link graph, so the cylinder knows what
        # it is working against without having to inspect topology it does not own. This is
        # the one line that decides what kind of machine this cylinder ends up being.
        @exhausts_to = exhausts_to.to_sym
        @supplied_by = supplied_by.to_sym
        @default_working_fluid = working_fluid.to_sym
        # Polytropic index for the expansion stroke. 1.135 is the usual figure for saturated
        # steam; 1.3 is nearer superheated, and 1.0 is the isothermal idealisation the
        # textbook `ρ·(1 + ln 1/ρ)` form assumes.
        @expansion_index = expansion_index.to_f
        # How much of the stroke is left when the exhaust valve shuts. Real valve gear closes
        # the exhaust early on purpose so the residue is recompressed into the clearance space
        # and kept rather than re-bought — see `displacement_kg`. Typical practice is 5–15%.
        @compression_fraction = compression_fraction.to_f
        # The speed at which the exhaust stroke carries water away as readily as steam. Set
        # comfortably below normal running speed so an engine at work is unchanged and only a
        # slow or standing one accumulates — the hazard should live where a driver already
        # expects it.
        @entrainment_omega = entrainment_omega.to_f
        # What blows through the valve while the engine is standing with steam on it. See
        # `blow_through_kg` — this is the difference between a stopped cylinder that quietly
        # sits there and one that a driver can hear.
        @standing_kg_per_s = standing_kg_per_s.to_f
        # The speed by which blow-through has stopped. **Deliberately tiny** — about 9.5 rpm.
        # Once the crank is turning at all the valve gear is opening and closing properly and
        # there is no steady leak past it, so this is a standstill phenomenon and not a
        # low-speed one. Fading it out over `entrainment_omega` instead put it at 31% strength
        # at 66 rpm, right across the normal operating range, and killed the engine outright.
        @standing_omega = standing_omega.to_f
        @heat_capacity = heat_capacity.to_f
        @ambient_conductance = ambient_conductance.to_f
        @ambient_k = ambient_k.to_f
        @cutoff_control_id = cutoff_control_id&.to_sym
        @max_pressure_pa = max_pressure_pa.to_f
        @stress_rate = stress_rate.to_f
        # Per `nodes/CLAUDE.md` step 6 — a node is configuration and holds no mutable state.
        # `Vessel` and `Conduit` cannot do this because `Boiler` and `ReliefValve` assign their
        # own ivars after `super`; nothing subclasses this one.
        freeze
      end

      def initial_temperature_k = @ambient_k

      def piston_area_m2 = Math::PI * ((@bore_m / 2.0)**2)

      def swept_volume_m3 = @swept_m3

      # Admit working fluid through the inlet, and sweep out what the return stroke displaces.
      #
      # **Admission is positive displacement at the density the SUPPLY is at.** Per revolution
      # the engine swallows `(cutoff + clearance) × swept_volume`, so notching up takes
      # proportionally less steam. Two separate things were wrong here and each was enough on
      # its own to make cut-off inert:
      #
      #   * It used the density of the charge **already held**, which is a collapsing feedback
      #     loop — less held means less demanded means less held. Measured at consistently half
      #     the supply density, because the charge has already expanded and partly exhausted.
      #   * It drew `max(displacement, headroom)`, where headroom is "enough to bring my whole
      #     free volume up to supply pressure". **That term contains no cut-off at all** —
      #     measured flat at 0.219 to 0.227 kg per tick from full gear down to 25% — so it won
      #     the `max` every time and the displacement never reached the demand. Steam
      #     consumption was constant to three significant figures while power fell 140-fold:
      #     notching up cost everything and saved nothing, which is the exact inverse of the
      #     machine.
      def plan(state, ctx)
        return Intent.none if broken?(state)

        Intent.new(
          draws: { inlet: [ port(:inlet).capacity_kg(ctx.dt), admission_kg(state, ctx) ].min },
          pushes: { exhaust: exhaust_demand_kg(state, ctx) }
        )
      end

      # What the engine swallows this tick: the stroke's displacement, or — standing — just
      # enough to fill the clearance space to chest pressure.
      #
      # The standing term is not a starting hack. A stopped engine with the regulator open
      # genuinely does fill its clearance space and no further, because nothing is sweeping;
      # it is the *displacement* that goes to zero at rest, not the admission. It matters that
      # this is small rather than a whole cylinder full: torque no longer comes from the held
      # charge (see `apply`), so a stopped cylinder does not have to be pumped up to supply
      # pressure before it will turn.
      def admission_kg(state, ctx)
        [ displacement_kg(ctx), clearance_fill_kg(state, ctx), blow_through_kg(ctx) ].max
      end

      # ## Steam blowing through a standing engine, which is what the cocks are actually for
      #
      # A stopped cylinder with the regulator open is not sealed. The valve is wherever the
      # crank left it, the ports are open, and steam blows straight through — into the cylinder
      # and out of the exhaust or the cocks. It is the noise a stationary locomotive makes.
      #
      # **Without it a standing cylinder admits only a static clearance top-up**, which stops
      # the moment the pressure equalises, so almost nothing arrives and the cocks have nothing
      # to drain. Measured: a standing engine reached 0.374 kg of water in nine thousand ticks
      # and was plainly asymptoting — against the 14.0 kg its clearance holds.
      #
      # **Gone by `standing_omega`, which is about 9.5 rpm and has to be that low.** This is a
      # standstill phenomenon, not a low-speed one: the moment the crank turns, the valve gear
      # opens and closes on schedule and there is no steady path through. Fading it over
      # `entrainment_omega` instead left it 31% active at 66 rpm — across the whole normal
      # operating range — and the engine reached 66 rpm and then died in every configuration
      # tested. A leak that only exists at rest must stop existing almost immediately.
      #
      # Deliberately a *rate* rather than a pressure-driven flow: the cylinder is the one part
      # that already sizes its own intake, and giving it a conductance as well would be two
      # numbers for one restriction again.
      def blow_through_kg(ctx)
        return 0.0 if @standing_kg_per_s <= 0.0 || @standing_omega <= 0.0

        omega = (ctx.node_omega(@drives) || 0.0).abs
        return 0.0 if omega >= @standing_omega

        @standing_kg_per_s * ctx.dt * (1.0 - (omega / @standing_omega))
      end

      # Mass swallowed per tick by the stroke itself: `cutoff × swept volume` per revolution at
      # admission density.
      #
      # **The clearance volume is deliberately NOT in this term**, and the textbook `(ρ + c)`
      # would be wrong here. That form is the gross fill, and it is paired with a credit for the
      # residue the compression stroke recompresses — real valve gear shuts the exhaust early
      # precisely so the clearance charge is *kept* rather than re-bought every stroke. This
      # model keeps it directly: `exhaust_demand_kg` holds `retained_kg` back, so the
      # residue never leaves and charging admission for it again would bill the engine twice.
      #
      # It is not a rounding error at the interesting end of the range. Billed twice, steam
      # consumption goes as `ρ + 0.08`, and at 15% cut-off that is a **53% surcharge** on the
      # setting where economy is supposed to be won — enough on its own to invert the efficiency
      # curve the cut-off lever exists to produce.
      def displacement_kg(ctx)
        omega = ctx.node_omega(@drives) || 0.0
        return 0.0 if omega <= 0.0

        revolutions = omega / (2.0 * Math::PI) * ctx.dt
        revolutions * cutoff_fraction(ctx) * @swept_m3 * supply_bulk_density(ctx)
      end

      # Enough to bring the clearance space up to chest pressure, and no more. Zero whenever the
      # cylinder already holds that much, which is always once it is running.
      def clearance_fill_kg(state, ctx)
        # Only the part of the clearance that liquid has not already taken can be filled with
        # gas, which is what makes a flooded cylinder stop breathing as well as stop turning.
        room = [ obstruction_volume_m3 - obstructing_volume_m3(state, ctx.content), 0.0 ].max

        [ (room * supply_gas_density(ctx)) - gas_kg(state, ctx.content), 0.0 ].max
      end

      # What the return stroke sweeps out: everything except what the clearance space keeps,
      # **and no more than the piston has actually swept this tick.**
      #
      # Planned from what is held rather than from what is about to arrive, because `plan` runs
      # before the grant. That converges in a single step rather than oscillating — and it is
      # not the `h ↦ T − h` involution a transport node would produce, because the admission
      # term does not depend on what is held.
      #
      # **The revolution cap is what makes the held inventory mean anything.** A cylinder
      # completes one exhaust stroke per revolution, so at 0.6 revolutions per tick it can only
      # sweep 0.6 of a cylinder-full; without the cap a barely-turning engine empties itself
      # completely every tick. The two rules settle at different inventories and only one of
      # them is a cylinder:
      #
      #     uncapped   contents → clearance + one TICK's admission     (< one stroke at 0.6 rev)
      #     capped     contents → clearance + one REVOLUTION's charge  (exactly one stroke)
      #
      # It also matters to the blastpipe, which breathes on `exhaust_kg`: uncapped, a slow
      # engine hands the chimney one large slug and then nothing.
      #
      # Zero when stopped, which is correct and is the reason a standing engine fills with its
      # own condensate. That is what drain cocks are for.
      def exhaust_demand_kg(state, ctx)
        omega = ctx.node_omega(@drives) || 0.0
        return 0.0 if omega <= 0.0

        revolutions = omega / (2.0 * Math::PI) * ctx.dt
        sweep = [ revolutions, 1.0 ].min

        # **What blows in has to be able to blow out**, or a standing cylinder simply packs with
        # steam instead of passing it. The mix is still the entrainment affinity's business, and
        # at rest that is `MIN_ENTRAINMENT` — so the steam leaves and the water does not, which
        # is precisely how a standing engine fills itself.
        [ sweep * [ contents_kg(state) - retained_kg(state, ctx), 0.0 ].max,
          blow_through_kg(ctx) ].max
      end

      # **What the piston cannot sweep out: whatever occupies the clearance volume at the top of
      # the stroke.** Liquid takes that space first, because it is dense and it collects exactly
      # where the piston cannot reach; gas fills whatever is left.
      #
      # This used to be `clearance_volume × supply_density` — the clearance priced as a **gas
      # mass**, about 0.029 kg — and everything above that figure was pushed out. So the model
      # would happily expel 14 kg of water from a space that can only hold 0.029 kg of steam,
      # and water could never accumulate however much of it arrived. Measured on a calm boiler:
      # **10.98 kg of water condensed inside the cylinder over 100 seconds and 10.98 kg left by
      # the exhaust**, with 0.0003 kg net retained. The exhaust was never the bottleneck; the
      # retention figure was simply too small to hold anything back.
      #
      # It is the same mass-for-volume confusion as pricing a tank's level by `contents_volume`
      # or setting an affinity without regard to the mass ratio it works against. **A clearance
      # is a volume. Whatever is in it is whatever fits.**
      def retained_kg(state, ctx)
        clearance = obstruction_volume_m3
        liquid_m3 = obstructing_volume_m3(state, ctx.content)
        kept_m3 = [ liquid_m3, clearance ].min
        kept_kg = liquid_m3 > Parcel::EPSILON ? kept_m3 * (liquid_kg(state, ctx.content) / liquid_m3) : 0.0

        kept_kg + ((clearance - kept_m3) * supply_gas_density(ctx))
      end

      def liquid_kg(state, content)
        obstructing_parcels(state, content).sum { |p| p.fetch(:kg) }
      end

      # Density of the working **gas** at the conditions the supply is offering. Ideal gas:
      # `ρ = P·M / (R·T)`. This is the right figure wherever the question is "how much gas fits
      # in this space" — filling the clearance, and the gas half of what the clearance retains.
      def supply_gas_density(ctx)
        pressure = ctx.node_pressure(@supplied_by) || Units::STANDARD_PRESSURE_PA
        temperature = ctx.node_temperature(@supplied_by) || @ambient_k
        return 0.0 if temperature <= 0.0 || pressure <= 0.0

        pressure * molar_mass_kg(working_fluid(ctx), ctx.content) /
          (Units::GAS_CONSTANT * temperature)
      end

      # **Mean density of everything the supply is holding, which is what the piston swallows.**
      #
      # A positive-displacement machine takes a *volume* and gets whatever is in it. Sizing the
      # intake at the working fluid's gas density instead asks for the mass that volume would
      # hold **if the supply were dry**, and that is the fourth mass-for-volume confusion in this
      # codebase — after `contents_volume` read as a level, an affinity set against a mass ratio,
      # and a clearance priced as 0.029 kg of steam.
      #
      # It is not a small error at the end that matters. At 170 rpm and 40% cut-off the piston
      # sweeps 0.0496 m³ per tick, which is **49.6 kg if the stream is water**; the gas figure
      # asks for 0.126 kg. So a chest full of primed water handed the cylinder a few hundred
      # grams of it, and hydraulic lock at speed was arithmetically unreachable however hard the
      # boiler primed — the piston could not swallow a slug because it was never asking for one.
      #
      # Dry, the two densities agree and nothing about normal running changes. Falls back to the
      # gas figure when the supply is not a holder with a volume.
      def supply_bulk_density(ctx)
        ctx.node_reading(@supplied_by, :bulk_density_kg_m3) || supply_gas_density(ctx)
      end

      def gas_kg(state, content)
        parcels(state).sum { |p| content.tags(p.fetch(:resource)).include?(:gas) ? p.fetch(:kg) : 0.0 }
      end

      # How far up the stroke steam is still being admitted. Never quite zero: the indicator
      # diagram's expansion term goes logarithmic as it approaches it, and a real valve gear
      # cannot notch to nothing either.
      def cutoff_fraction(ctx)
        return 1.0 unless @cutoff_control_id

        (ctx.controls.fetch(@cutoff_control_id, 100.0) / 100.0).clamp(MINIMUM_CUTOFF, 1.0)
      end

      # Work out the torque the charge is exerting, and declare it.
      #
      # The energy transfer itself is NOT done here. The shaft's kinetic energy gain from a
      # given impulse is not exactly `torque × ω × dt` — there is a second-order term that
      # grows with the timestep — so the Operation applies the impulse, measures what the
      # shaft actually gained, and bills the charge for precisely that. Doing it here with
      # the first-order figure would leak energy at large `time_scale`, which is the one
      # place this simulation refuses to be approximate.
      def apply(state, ctx, grant)
        # Recorded even when broken, so a seized engine stops making draught rather than
        # leaving a stale figure behind for the blastpipe to keep breathing on.
        state = state.merge(exhaust_kg: grant.sent_kg(:exhaust))
        # `shaft_power_w` is zeroed here every tick and written back by `Tick#transmit_torque`
        # if the crank actually turns. Reset rather than left alone, because that phase skips a
        # driver whose torque is nil or whose shaft has come apart — and a gauge reading a stale
        # figure would show a wrecked engine still making power.
        state = state.merge(shaft_power_w: 0.0)
        return state.merge(torque: 0.0, indicated_power_w: 0.0) if broken?(state)

        # **The diagram's admission pressure is what the SUPPLY is at, not what this node
        # holds.** A lumped charge that has already expanded and is halfway through being
        # exhausted sits near the *release* condition — measured at roughly 30% of boiler
        # pressure, and tracking it at under half rate. Worse, it is a function of the free
        # volume, so as the cylinder flooded with its own condensate the pressure ROSE and the
        # engine made more power the closer it came to hydraulic lock: 175 kW at a liquid
        # fraction of 1.455. The model was rewarding the failure it should punish.
        #
        # A cylinder has no single pressure — admission, cut-off, release, back and compression
        # differ by more than an order of magnitude inside one revolution — so asking a
        # lumped-body node for "the" pressure was always going to return the least useful of
        # the five.
        #
        # **Point `supplied_by:` at a steam chest, not at the boiler.** Both are "the supply",
        # and only one of them closes the loop. Reading the boiler leaves the regulator unable
        # to affect torque at all — it rations how much steam arrives but says nothing about the
        # pressure it arrives at — and the only thing then standing between this diagram and
        # inventing energy is the `extractable_joules` bound in `Tick#transmit_torque`.
        # Measured, that bound was discarding **30 to 50% of the declared work** and its scale
        # factor *was* the throttle mechanism: 0.496 at throttle 20, 0.596 at 40, 0.698 at 60,
        # with declared torque nearly flat across the range. A conservation clamp is not a
        # substitute for a mechanism, and it fails silently when it is used as one.
        #
        # A chest between regulator and valve fixes it structurally rather than with a bound:
        # swallow faster than the throttle can pass and the chest depletes, so the admission
        # density falls and P₁ falls with it.
        omega = ctx.node_omega(@drives) || 0.0

        # **A locked cylinder does not drive, it resists.** With the clearance space full of
        # water the piston cannot reach the top of its stroke, so the charge stops being a
        # source of work and becomes something the crank has to push against. Expressed as a
        # negative torque rather than as a special case in the tick: `transmit_torque` then
        # decelerates the shaft, measures the kinetic energy it lost, and hands it back to this
        # node as heat — which is what crushing water against a cylinder end actually does, and
        # it balances the books without a rule of its own.
        #
        # When the driveline has less energy stored than the charge costs to compress, this is
        # the whole story and the engine simply stalls; when it has more, `overload?` has already
        # destroyed the cylinder on the same tick.
        if locked?(state, ctx.content)
          resisting = compression_pressure_pa(state, ctx.content) *
                      piston_area_m2 * @crank_radius_m * @efficiency
          return state.merge(torque: -resisting, indicated_power_w: 0.0)
        end

        supply_pressure = ctx.node_pressure(@supplied_by) || Units::STANDARD_PRESSURE_PA
        exhaust_pressure = ctx.node_pressure(@exhausts_to) || Units::STANDARD_PRESSURE_PA
        mep = mean_effective_pressure(supply_pressure, exhaust_pressure, cutoff_fraction(ctx))
        torque = mep * piston_area_m2 * @crank_radius_m * @efficiency

        state.merge(torque: torque, indicated_power_w: torque * omega)
      end

      # ## The indicator diagram, which is what a steam engine actually is
      #
      # Torque used to be `(P_charge − P_back) × A × r × η`: the pressure difference applied
      # flat across the whole stroke. That is the diagram for an engine running at **full
      # admission** and nothing else, and it is why `cutoff` was a second, worse throttle —
      # it scaled the *rate* steam arrived at, so it bought less steam and less power in equal
      # measure, and above 24% of its travel it did not bind at all.
      #
      # Working expansively is the entire point of the machine. Steam admitted for a fraction
      # `ρ` of the stroke goes on pushing as it expands, so the work per cycle is
      #
      #     admission   P₁ · ρ
      #     expansion   P₁ · ρ · (1 − ρ^(n−1)) / (n − 1)        ( → ρ·ln(1/ρ) as n → 1 )
      #     exhaust     − P₂
      #
      # all per unit of swept volume, which sums to the mean effective pressure. At ρ = 1 the
      # expansion term vanishes and this is exactly the old formula, so nothing that was right
      # about full-gear running changed. At ρ = 0.25 with n = 1.135 it is 0.566·P₁ − P₂ —
      # **57% of the power on 25% of the steam**, which is the trade a driver notches up for.
      def mean_effective_pressure(supply_pa, back_pa, cutoff)
        return 0.0 if supply_pa <= back_pa

        n = @expansion_index
        expansion = if (n - 1.0).abs < 1.0e-9
          cutoff * Math.log(1.0 / cutoff)
        else
          cutoff * (1.0 - (cutoff**(n - 1.0))) / (n - 1.0)
        end

        # A cylinder pushes; it does not pull the crank back. Notched far enough up, the charge
        # expands below the back pressure before the stroke ends and the tail of the diagram is
        # genuinely negative — but modelling that as reverse torque needs the compression side
        # of the cycle too, so it is floored rather than fabricated.
        [ (supply_pa * (cutoff + expansion)) - back_pa, 0.0 ].max
      end

      # Whatever gas the supply is actually offering, so the headroom calculation uses the
      # right molar mass. Falls back to a configured default for the first tick, when there
      # is nothing upstream yet to look at. Hardcoding a fluid here was the last thing in
      # this class that assumed what kind of machine it belonged to.
      def working_fluid(ctx)
        upstream = ctx.node_state(@supplied_by)
        gas = upstream&.fetch(:parcels, [])&.find { |p|
          ctx.content.tags(p.fetch(:resource)).include?(:gas)
        }

        gas ? gas.fetch(:resource) : @default_working_fluid
      end

      # How much energy this cylinder can give up before its charge would be colder than
      # the outside world. Stops a starved cylinder inventing work from nothing.
      def extractable_joules(state)
        [ total_joules(state) - (@heat_capacity * @ambient_k), 0.0 ].max
      end

      # --- obstruction -----------------------------------------------------------
      #
      # Gas is compressible; liquid is not. Enough liquid in the clearance space and the piston
      # has nowhere to go at the top of its stroke, so something gives — the classic way a
      # priming supply destroys the machine it feeds.
      #
      # **Measured against the CLEARANCE, which is the whole reason this is a hazard.** The
      # 14 kg of water that wrecks this cylinder is 7% of its total volume, so against the
      # node's own volume the danger is invisible. `Concerns::Obstructs` exists to make that
      # denominator explicit rather than a number buried in one method.
      #
      # (The old spelling divided by `volume_m3 * clearance_fraction`, which is the clearance
      # times `1 + clearance_fraction` — 8% too generous, because `volume_m3` already includes
      # the clearance. `volume_m3 - swept_m3` is the clearance exactly.)
      def obstruction_volume_m3 = @volume_m3 - @swept_m3

      # Liquid only. Soot in a cylinder is a different and much slower problem; water is the
      # one that destroys it in a single revolution.
      def obstruction_tags = OBSTRUCTION_TAGS

      # ## The pressure the charge reaches at top dead centre
      #
      # The derived quantity hydraulic lock actually turns on, and the reason a relief valve
      # can now catch it. `pressure_pa` reports the charge spread over the **whole** cylinder,
      # so filling the clearance with enough water to destroy the engine moves it by about 7%
      # — the pressure that matters is one a lumped body never experiences.
      #
      # Reconstructed rather than traced, exactly as `mean_effective_pressure` reconstructs the
      # area of a diagram this model never draws. At exhaust closure the residue occupies
      # `clearance + compression_fraction × swept`; by top dead centre the piston has squeezed
      # it into whatever the water has left of the clearance:
      #
      #     P_tdc = P · (V_closure / (V_clearance − V_liquid))ⁿ
      #
      # Floored the same way `Pressurized#free_volume` is, so it is steep but finite — which is
      # what a real liquid's bulk modulus does, since the cylinder is not perfectly rigid and
      # the water is not perfectly incompressible.
      #
      # **It rises long before it locks, and that is the point.** Reciprocating-compressor
      # practice reports four to five times normal pressure on a *moderate* amount of liquid,
      # and a slug bending a rod in one revolution. Half a clearance of water here is 2.2× the
      # dry compression; nine tenths is 13.6×. So a cylinder run wet fatigues, over-pressure
      # trips a relief valve, and only the last of it is sudden.
      def compression_pressure_pa(state, content)
        pressure_pa(state, content) *
          ((compression_closure_m3 / compression_space_m3(state, content))**@expansion_index)
      end

      # The two ends of the compression stroke, named once because two methods need both and
      # having them inline twice is how the pair drifts apart.
      #
      # **They are separate engine dimensions that happen to share a value here**, and merging
      # them would be a modelling loss rather than a tidy-up. `clearance_fraction` is the volume
      # the piston never sweeps — a casting dimension. `compression_fraction` is where in the
      # return stroke the exhaust valve shuts — valve-gear timing, which a long-lap gear sets
      # independently. A real engine can have a tight clearance and late exhaust closure, or the
      # reverse; that both are 0.08 on this cylinder is a coincidence of two typical figures.
      def compression_closure_m3
        obstruction_volume_m3 + (@compression_fraction * @swept_m3)
      end

      # What is left of the clearance once the water has taken its share. Floored the same way
      # `Pressurized#free_volume` is, so compression is steep but finite — which is what a real
      # liquid's bulk modulus does, the cylinder not being perfectly rigid.
      def compression_space_m3(state, content)
        clearance = obstruction_volume_m3
        floor = clearance * Concerns::Pressurized::MINIMUM_FREE_VOLUME_FRACTION
        [ clearance - obstructing_volume_m3(state, content), floor ].max
      end

      # True once the clearance space is full: the piston cannot complete its stroke.
      def locked?(state, content) = occupancy(state, content) >= 1.0

      # ## What leaves with the steam, and what leaves through the cocks
      #
      # **A fast engine blows its own condensate clear; a slow one collects it.** Entrainment is
      # the exhaust stroke dragging droplets out with the steam, and it is a function of how
      # violent that stroke is — which is why a real driver opens the cocks when starting and
      # shuts them once the engine is away, and why hydraulic lock belongs to standing rather
      # than to running.
      #
      # Before this existed the choice was between the two settings a port tag can express, and
      # **both were wrong**: `accepts: [:gas]` on the chimney stranded condensate completely and
      # flooded the cylinder to 21.9 kg, while making it permissive carries water away
      # *proportionally by mass* — preferentially, since the stroke sweeps a volume and water is
      # a thousand times denser than the steam carrying it.
      #
      # The cocks pull the other way on the same tag, which is the point of them.
      def transport_affinity(port_id, _state, ctx)
        case port_id
        when :exhaust then { liquid: entrainment_fraction(ctx) }
        when :drain   then DRAIN_AFFINITY
        else {}
        end
      end

      # Rises to fully proportional at `entrainment_omega` and holds there — above that speed
      # the exhaust is violent enough to take everything it is offered, so there is nothing left
      # for more speed to buy.
      def entrainment_fraction(ctx)
        return 1.0 if @entrainment_omega <= 0.0

        omega = (ctx.node_omega(@drives) || 0.0).abs
        (omega / @entrainment_omega).clamp(MIN_ENTRAINMENT, 1.0)
      end

      # **Fatigue on the compression pressure, not the mean one.** What tires a cylinder end,
      # a cover or a rod is the peak load at top dead centre, and a cylinder taking water
      # reaches that peak while its average pressure looks ordinary. Fatiguing on the average
      # would report a healthy machine right up to the stroke that destroys it.
      def stress_per_second(state, ctx)
        return 0.0 if @stress_rate.zero? || @max_pressure_pa.infinite?

        over = compression_pressure_pa(state, ctx.content) - @max_pressure_pa
        over.positive? ? (over / @max_pressure_pa) * @stress_rate : 0.0
      end

      # ## The work the crank has to find to reach top dead centre
      #
      # Polytropic compression of the residue from exhaust closure into whatever the water has
      # left of the clearance: `W = (P₁V₁ − P₂V₂)/(n − 1)`. Floored exactly as
      # `compression_pressure_pa` is, so it is steep but finite.
      #
      # This is the quantity hydraulic lock actually turns on, and it is why the failure rule
      # below needs no declared speed. As the clearance fills, `V₂` collapses and this rises
      # without bound — so the question "does the engine break or merely stop?" is the question
      # "did the driveline have this much energy in it?", which is a comparison the model can
      # make rather than a threshold somebody has to guess.
      def compression_work_joules(state, content)
        space = compression_space_m3(state, content)
        start_pa = pressure_pa(state, content)

        ((compression_pressure_pa(state, content) * space) -
          (start_pa * compression_closure_m3)) / (@expansion_index - 1.0)
      end

      # Hydraulic lock, and **what it costs depends on what the driveline had stored.**
      #
      #     stopped / light        it stalls — see `apply`. Recoverable, and it should be
      #     heavy wheel at speed   a rod bends, a cover goes: destroyed in a single revolution
      #
      # **Derived, not declared.** This used to be `omega > lock_omega`, and that grading was
      # structurally unreachable on a real engine: filling the clearance needs a standing
      # cylinder, destruction needed a turning one, and a locked cylinder makes negative torque
      # so it can never accelerate out of one regime into the other. The two conditions could not
      # both hold, and the destruction branch had never once fired.
      #
      # A speed threshold was the wrong question anyway. What decides whether the piston reaches
      # top dead centre is whether the rotating mass carries enough **energy** to compress the
      # trapped charge — which is why a heavy flywheel is the danger and a light one merely
      # stops, and why the same slug that wrecks an engine at speed is survivable at a crawl.
      # A 3 200 kg wheel at 170 rpm holds 570 kJ; the same wheel at 10 rpm holds 2 kJ.
      #
      # Reads the node named by `drives:`, so a load coupled through a `DriveLink` is **not**
      # counted. Right for this engine, where the flywheel is the mass that matters; wrong for a
      # geared train, where the driven inertia would have to be summed across the drive network.
      #
      # An overload rather than fatigue: this is not a part wearing out, it is a geometric
      # impossibility that resolves in one stroke. Scaled by `integrity` like every other
      # overload, so a tired cylinder gives way sooner.
      def overload?(state, ctx, integrity)
        return false unless occupancy(state, ctx.content) >= integrity

        stored = ctx.node_kinetic_joules(@drives) || 0.0
        stored > compression_work_joules(state, ctx.content)
      end

      def failure_type = :cylinder_failure

      def failure_detail(state, ctx)
        { occupancy: occupancy(state, ctx.content).round(3) }
      end
    end
  end
end
