# frozen_string_literal: true

module ReactorSim
  module Nodes
    # Where a gas pressure difference becomes shaft torque. Generic: the working fluid is
    # configuration, and the cylinder cares only that the inlet side is at higher pressure than
    # whatever it exhausts into.
    #
    # **Torque, not power**, from the pressure difference across the piston:
    #
    #     torque = ΔP × piston_area × crank_radius
    #
    # **Indicated, with nothing taken off for friction.** There was a `0.85` here and it did not
    # do what it looked like: `Tick#transmit_torque` bills a driver for the kinetic energy the
    # shaft *measurably gained*, so derating the torque never removed the other 15% from the
    # charge — it was energy nobody claimed rather than energy that went anywhere. Rubbing is
    # modelled where it happens now, by a `Nodes::Bearing` with `duty: :slide` carrying the
    # rings, crosshead and gland, so the loss is real, lands as heat, and wears the part out.
    #
    # independent of speed. Deriving torque from a power figure means dividing by ω, which is
    # infinite at rest, so the machine could not be started from standstill. This way a stalled
    # cylinder has full torque and `power = torque × ω` comes out as zero.
    #
    # **Self-starting and self-limiting**, with no special cases:
    #
    #     at rest    inlet open → charge builds → pressure rises → torque → it turns
    #     spinning   exhaust flow ∝ ω → charge drops → pressure falls → torque falls → settles
    #
    # It finds its own operating point because turning faster means breathing harder. That is
    # also where the danger lives: shed the load and ω climbs, admitting more fluid, pushing ω
    # higher still. Only a governor and an operator stand between that loop and a burst wheel.
    #
    # **What it exhausts into decides what kind of machine it is** — a condenser near vacuum, or
    # the open air. Same node, same formula, different graph.
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
                  :bore_m, :stroke_m, :crank_radius_m, :drives,
                  :cutoff_control_id, :clearance_fraction, :max_pressure_pa, :stress_rate,
                  :drain_control_id, :drain_authority,
                  :material, :wall_thickness_m, :safety_factor,
                  :exhausts_to, :supplied_by, :default_working_fluid, :expansion_index,
                  :compression_fraction

      def initialize(id:, label: nil, bore_m:, stroke_m:, drives:, exhausts_to:, supplied_by:,
                     crank_radius_m: nil, clearance_fraction: 0.08,
                     heat_capacity: 6.0e4, ambient_conductance: 25.0,
                     ambient_k: Units::STANDARD_TEMPERATURE_K, cutoff_control_id: nil,
                     drain_control_id: nil, drain_authority: 0.25,
                     inlet_kg_per_s: 8.0, exhaust_kg_per_s: 12.0, drain_kg_per_s: 0.25,
                     relief_kg_per_s: 2.0, working_fluid: :steam,
                     expansion_index: 1.135, compression_fraction: 0.08,
                     entrainment_omega: 10.0, standing_kg_per_s: 0.15, standing_omega: 1.0,
                     material: nil, wall_thickness_m: nil, safety_factor: 1.0,
                     max_pressure_pa: Float::INFINITY, stress_rate: 0.0)
        @bore_m = bore_m.to_f
        @stroke_m = stroke_m.to_f
        # Half the stroke, unless the crank is geared otherwise.
        @crank_radius_m = (crank_radius_m || (@stroke_m / 2.0)).to_f
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
            Port.new(id: :relief, direction: :outlet, max_kg_per_s: relief_kg_per_s),
            # Where the front of the cylinder goes when the head lets go. Nothing crosses it
            # while the barrel is sound — a `Nodes::Breach` on the far side is shut until the
            # failure mode opens it — and it is rated well above anything the working machine
            # uses so the hole is the restriction rather than this port.
            Port.new(id: :breach_out, direction: :outlet, max_kg_per_s: 50.0)
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
        # The drain cocks, as the diagram sees them. See `admission_pressure_pa` — the lever is
        # read here as well as on the conduit because a node cannot ask another node for its
        # `open_fraction`: `Context#node_reading` calls `method(state, content)` and that one
        # takes `ctx`.
        @drain_control_id = drain_control_id&.to_sym
        @drain_authority = drain_authority.to_f.clamp(0.0, 1.0)
        @max_pressure_pa = max_pressure_pa.to_f
        # What the barrel is made of and how thick it is. `shell_radius_m` is not configurable
        # here because a cylinder already knows it — it is the bore — which is the nice thing
        # about deriving a rating from geometry on a part whose geometry is the point.
        @material = material&.to_sym
        @wall_thickness_m = wall_thickness_m&.to_f
        @safety_factor = safety_factor.to_f
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
      # **Admission is positive displacement at the density the SUPPLY is at**, never the charge
      # already held — that is a collapsing feedback loop, since less held means less demanded.
      # Per revolution the engine swallows `cutoff × swept_volume`, so notching up takes
      # proportionally less steam.
      #
      # `admission` is what the rings still hold: a sound cylinder is 1.0, a scored one swallows
      # a full charge and wastes part of it past the piston, a blown head is 0.0.
      def plan(state, ctx)
        works = derating(state, :admission)
        return Intent.none unless works.positive?

        Intent.new(
          draws: { inlet: [ port(:inlet).capacity_kg(ctx.dt), admission_kg(state, ctx) ].min },
          pushes: { exhaust: exhaust_demand_kg(state, ctx) }
        )
      end

      # What the engine swallows this tick: the stroke's displacement, or — standing — just
      # enough to fill the clearance space to chest pressure. It is the *displacement* that goes
      # to zero at rest, not the admission. Keeping the standing term small matters because
      # torque does not come from the held charge (see `apply`), so a stopped cylinder need not
      # be pumped up to supply pressure before it will turn.
      def admission_kg(state, ctx)
        [ displacement_kg(ctx), clearance_fill_kg(state, ctx), blow_through_kg(ctx) ].max
      end

      # Steam blowing through a standing engine, which is what the cocks are for. A stopped
      # cylinder with the regulator open is not sealed: the valve is wherever the crank left it,
      # the ports are open, and steam blows straight through. Without it a standing cylinder only
      # tops up its clearance, which stops as soon as pressure equalises, so the cocks have
      # nothing to drain.
      #
      # **Gone by `standing_omega`, about 9.5 rpm, and it has to be that low.** This is a
      # standstill phenomenon: the moment the crank turns, the valve gear opens and closes on
      # schedule and there is no steady path through. Fading it over `entrainment_omega` instead
      # leaves it 31% active at 66 rpm — across the whole normal operating range — and the engine
      # dies there.
      #
      # A *rate* rather than a pressure-driven flow: the cylinder already sizes its own intake,
      # and a conductance as well would be two numbers for one restriction.
      def blow_through_kg(ctx)
        return 0.0 if @standing_kg_per_s <= 0.0 || @standing_omega <= 0.0

        omega = (ctx.node_omega(@drives) || 0.0).abs
        return 0.0 if omega >= @standing_omega

        @standing_kg_per_s * ctx.dt * (1.0 - (omega / @standing_omega))
      end

      # Mass swallowed per tick by the stroke itself: `cutoff × swept volume` per revolution at
      # admission density.
      #
      # **The clearance volume is deliberately not in this term.** The textbook `(ρ + c)` is a
      # gross fill paired with a credit for the residue the compression stroke recompresses.
      # This model keeps that residue directly — `exhaust_demand_kg` holds `retained_kg` back —
      # so charging admission for it again bills the engine twice. At 15% cut-off that is a 53%
      # surcharge, on exactly the setting where economy is supposed to be won.
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
      # completes one exhaust stroke per revolution, so at 0.6 revolutions per tick it sweeps
      # 0.6 of a cylinder-full; uncapped, a barely-turning engine empties itself every tick:
      #
      #     uncapped   contents → clearance + one TICK's admission     (< one stroke at 0.6 rev)
      #     capped     contents → clearance + one REVOLUTION's charge  (exactly one stroke)
      #
      # It also matters to the blastpipe, which breathes on `exhaust_kg`: uncapped, a slow engine
      # hands the chimney one large slug and then nothing.
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
      # the stroke.** Liquid takes that space first, because it is dense and collects exactly
      # where the piston cannot reach; gas fills whatever is left.
      #
      # **A clearance is a volume — whatever is in it is whatever fits.** Pricing it as a gas
      # mass instead (`clearance_volume × supply_density`, about 0.029 kg) lets the model expel
      # 14 kg of water from a space that holds 0.029 kg of steam, so water can never accumulate
      # however much arrives.
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

      # **Mean density of everything the supply holds, which is what the piston swallows.** A
      # positive-displacement machine takes a *volume* and gets whatever is in it; the working
      # fluid's gas density asks for the mass that volume would hold **if the supply were dry**.
      #
      # At 170 rpm and 40% cut-off the piston sweeps 0.0496 m³ per tick — 49.6 kg if the stream
      # is water, against 0.126 kg on the gas figure. On that figure a chest full of primed water
      # hands the cylinder a few hundred grams of it and hydraulic lock at speed is arithmetically
      # unreachable, because the piston never asks for a slug.
      #
      # Dry, the two densities agree. Falls back to the gas figure when the supply is not a
      # holder with a volume.
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
        # A blown head does no work; a scored bore does some of it. The same `admission` figure
        # that rations what the cylinder draws also scales what it can push with, because they
        # are one fact about the rings — steam that blows past the piston is neither swallowed
        # usefully nor turned into torque.
        works = derating(state, :admission)
        return state.merge(torque: 0.0, indicated_power_w: 0.0) unless works.positive?

        # **The diagram's admission pressure is what the SUPPLY is at, not what this node
        # holds.** A cylinder has no single pressure — admission, cut-off, release, back and
        # compression differ by more than an order of magnitude inside one revolution — so a
        # lumped charge reports the least useful of the five, near the *release* condition. It is
        # also a function of free volume, so a cylinder flooding with condensate would read a
        # RISING pressure and make more power the closer it came to hydraulic lock.
        #
        # **Point `supplied_by:` at a steam chest, not at the boiler.** Both are "the supply" and
        # only one closes the loop: reading the boiler leaves the regulator unable to affect
        # torque, because it rations how much steam arrives but says nothing about the pressure
        # it arrives at. A chest fixes it structurally — swallow faster than the throttle can
        # pass and the chest depletes, so admission density and P₁ fall with it.
        omega = ctx.node_omega(@drives) || 0.0

        # **A locked cylinder does not drive, it resists.** With the clearance full of water the
        # piston cannot reach the top of its stroke, so the charge becomes something the crank
        # pushes against. Expressed as negative torque rather than a special case in the tick:
        # `transmit_torque` decelerates the shaft, measures the kinetic energy lost and returns
        # it here as heat, which is what crushing water against a cylinder end does — and it
        # balances the books without a rule of its own.
        #
        # With less stored driveline energy than the charge costs to compress the engine stalls;
        # with more, `overload?` has already destroyed the cylinder on the same tick.
        if locked?(state, ctx.content)
          resisting = compression_pressure_pa(state, ctx.content) *
                      piston_area_m2 * @crank_radius_m
          return state.merge(torque: -resisting, indicated_power_w: 0.0)
        end

        supply_pressure = ctx.node_pressure(@supplied_by) || Units::STANDARD_PRESSURE_PA
        exhaust_pressure = ctx.node_pressure(@exhausts_to) || Units::STANDARD_PRESSURE_PA
        admission = admission_pressure_pa(supply_pressure, exhaust_pressure, ctx)
        mep = mean_effective_pressure(admission, exhaust_pressure, cutoff_fraction(ctx))
        torque = mep * piston_area_m2 * @crank_radius_m * works

        state.merge(torque: torque, indicated_power_w: torque * omega)
      end

      # **An open drain cock is a hole in the working space, and the diagram has to feel it.**
      # The mass budget is the wrong place to look: the cylinder holds so little gas that the
      # smallest cock takes all of it, so `drain_kg_per_s` is inert across an order of magnitude.
      #
      # What an open cock does is short-circuit the working space to atmosphere while the piston
      # pushes against it. During admission the space is fed through the valve and vented through
      # the cock at once, which is a pressure divider:
      #
      #     P_eff = (A·P_supply + B·P_back) / (A + B)
      #
      # Writing `b = B/(A+B)` for the cock's authority wide open, that is
      # `P_supply − b·(P_supply − P_back)`. Two properties make it the right shape: shut, it is
      # exactly `P_supply`, so an engine with its cocks closed is bit-identical to one that never
      # had any; and the loss is proportional to the pressure difference, so it is largest when
      # the engine is working hardest. *A restriction, not a ration* — what matters about an
      # orifice is the pressure it destroys.
      def admission_pressure_pa(supply_pa, back_pa, ctx)
        bleed = drain_open_fraction(ctx) * @drain_authority
        return supply_pa if bleed <= 0.0 || supply_pa <= back_pa

        supply_pa - (bleed * (supply_pa - back_pa))
      end

      # How far the cocks are open, 0 with none fitted. Reads the lever's **actual** position, so
      # a cock a minion is still cranking shut is still bleeding.
      def drain_open_fraction(ctx)
        return 0.0 unless @drain_control_id

        (ctx.controls.fetch(@drain_control_id, 0.0) / 100.0).clamp(0.0, 1.0)
      end

      # **The indicator diagram, which is what a steam engine is.** Working expansively is the
      # point of the machine: steam admitted for a fraction `ρ` of the stroke goes on pushing as
      # it expands, so the work per cycle is
      #
      #     admission   P₁ · ρ
      #     expansion   P₁ · ρ · (1 − ρ^(n−1)) / (n − 1)        ( → ρ·ln(1/ρ) as n → 1 )
      #     exhaust     − P₂
      #
      # per unit of swept volume, summing to the mean effective pressure. At ρ = 1 the expansion
      # term vanishes and this reduces to a flat `(P₁ − P₂)` across the stroke. At ρ = 0.25 with
      # n = 1.135 it is 0.566·P₁ − P₂ — **57% of the power on 25% of the steam**, which is the
      # trade a driver notches up for, and why cut-off is not simply a second throttle.
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

      # **The pressure the charge reaches at top dead centre** — the quantity hydraulic lock
      # turns on, and the reason a relief valve can catch it. `pressure_pa` reports the charge
      # spread over the *whole* cylinder, so enough water to destroy the engine moves it by about
      # 7%: the pressure that matters is one a lumped body never experiences.
      #
      # Reconstructed, as `mean_effective_pressure` reconstructs a diagram this model never
      # draws. At exhaust closure the residue occupies `clearance + compression_fraction ×
      # swept`; by top dead centre the piston has squeezed it into what the water left:
      #
      #     P_tdc = P · (V_closure / (V_clearance − V_liquid))ⁿ
      #
      # **It rises long before it locks, and that is the point.** Half a clearance of water is
      # 2.2× the dry compression, nine tenths is 13.6×, so a wet cylinder fatigues and trips a
      # relief valve before anything is sudden.
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

      # **A fast engine blows its own condensate clear; a slow one collects it.** Entrainment is
      # the exhaust stroke dragging droplets out with the steam, scaling with how violent that
      # stroke is — which is why a driver opens the cocks when starting and shuts them once the
      # engine is away, and why hydraulic lock belongs to standing rather than running.
      #
      # A port tag alone cannot express this: gas-only strands condensate entirely, and
      # permissive carries water away *proportionally by mass*, which is preferential, since the
      # stroke sweeps a volume and water is a thousand times denser than the steam carrying it.
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
        return 0.0 if @stress_rate.zero?

        rated = rated_pressure_pa(ctx.content)
        return 0.0 if rated.infinite?

        over = compression_pressure_pa(state, ctx.content) - rated
        over.positive? ? (over / rated) * @stress_rate : 0.0
      end

      # The barrel's own radius, for the hoop-stress rating in `Concerns::Pressurized`. A cylinder
      # is the one pressure part that never has to be told this.
      def shell_radius_m = @bore_m / 2.0

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
      #     stopped / light        it stalls — see `apply`. Recoverable, and should be
      #     heavy wheel at speed   a rod bends, a cover goes: destroyed in a single revolution
      #
      # **Derived from stored energy, not from a speed threshold.** What decides whether the
      # piston reaches top dead centre is whether the rotating mass carries enough energy to
      # compress the trapped charge, which is why a heavy flywheel is the danger and a light one
      # merely stops. A 3 200 kg wheel at 170 rpm holds 570 kJ; at 10 rpm it holds 2 kJ. A speed
      # threshold is also unreachable in practice: filling the clearance needs a standing
      # cylinder, and a locked one makes negative torque, so it can never accelerate into the
      # regime that would destroy it.
      #
      # Reads the node named by `drives:`, so a load coupled through a `DriveLink` is **not**
      # counted — right where the flywheel is the mass that matters, wrong for a geared train,
      # where driven inertia would have to be summed across the drive network.
      #
      # An overload rather than fatigue: a geometric impossibility that resolves in one stroke.
      # Scaled by `integrity`, so a tired cylinder gives way sooner.
      def overload?(state, ctx, integrity)
        return false unless occupancy(state, ctx.content) >= integrity

        stored = ctx.node_kinetic_joules(@drives) || 0.0
        stored > compression_work_joules(state, ctx.content)
      end

      # Ascending severity, and **the two are genuinely different machines afterwards**, which is
      # why `failure` carries a mode rather than a boolean.
      #
      # A **scored bore** is a worn-out engine, not a dead one: the rings no longer seal, so part
      # of every charge blows past the piston. It still turns and still pulls, badly, and a
      # driver can nurse it home. A **blown head** is a hole where the front of the cylinder was;
      # `admission: 0.0` is how a mode says "this part no longer does that thing at all".
      def failure_modes
        { scored_bore: { derates: { admission: 0.55 } },
          blown_head:  { derates: { admission: 0.0 } } }
      end

      # **The cause separates these cleanly**, which is not usually true (see `Nodes::Boiler`).
      # Here the two routes are physically different events rather than two severities of one:
      # fatigue is a barrel worn out hot and wet over hours, and the only overload this part has
      # is hydraulic lock, which breaks things in a single stroke.
      def failure_mode(_state, _ctx, cause) = cause == :overload ? :blown_head : :scored_bore

      def failure_detail(state, ctx)
        { occupancy: occupancy(state, ctx.content).round(3) }
      end
    end
  end
end
