# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A join that earned its place in the graph.
    #
    # Most joins are edges and cost nothing. A join becomes a node when it is *interesting*
    # — it carries a control point, it can fail, or it restricts flow
    # (docs/simulation_architecture.md §5). A valve, a pump, a section of pipe that can
    # rupture: all of these are Conduits.
    #
    # This is also where control points naturally live. The fitting between two vessels is
    # exactly where a real plant puts a valve, and putting the lever here rather than on
    # the vessel disperses complexity out of the mechanisms and into the joins around them.
    #
    # ## A conduit holds nothing, and that is the whole point
    #
    # It used to hold what passed through it for one tick. That was the single worst bug in
    # the engine, and it was invisible: an intermediate node has to size its intake from tick
    # N−1, before it can know what it will discharge this tick, so the only bounded inventory
    # rule — `draws = throughput − held` — gives the map `h ↦ T − h`. That is an involution.
    # Its eigenvalue is exactly −1, so it oscillates forever and **cannot damp**, and
    # `Arbiter.cap_gas_by_pressure` then amplified the swing into a locked full/empty orbit by
    # comparing two nodes it had itself put into antiphase.
    #
    # What it cost: the damper alternated 0.84 kg / 0.000 kg indefinitely, the firebox held
    # *no air at all* every other tick, the cylinder's indicated power swung 16.4/78.2 kW at
    # operating speed, and a conduit delivered about **half** its rated throughput. Two
    # separate workarounds were written for the symptoms before the cause was found.
    #
    # So a conduit is now a **flow mediator**: it contributes a rate limit, a lever, a wall
    # and the ability to fail, and `Path` resolves material straight from one holder to the
    # next. It keeps `Thermal` and `Wearing` and loses `Holds` and `Pressurized` — removing
    # the *residence*, not the thermal contact, and removing a pressure that was never a
    # measurement in the first place.
    #
    # Do not give this class `Holds` again. `spec/reactor_sim/transport_spec.rb` asserts it.
    class Conduit < Node
      include Concerns::Thermal
      include Concerns::Wearing

      attr_reader :heat_capacity, :ambient_conductance, :ambient_k,
                  :control_id, :max_temperature_k, :stress_rate, :conductance,
                  :stack_height_m, :head_control_id, :blast_from, :blast_pa_per_kg_per_s,
                  :material

      def initialize(id:, label: nil, accepts: [], max_kg_per_s:, conductance: nil,
                     one_way: false,
                     stack_height_m: 0.0, head_pa: 0.0, head_control_id: nil,
                     blast_from: nil, blast_pa_per_kg_per_s: 0.0,
                     heat_capacity: 1.0e4, ambient_conductance: 0.0,
                     ambient_k: Units::STANDARD_TEMPERATURE_K, control_id: nil,
                     rangeability: 1.0, material: nil,
                     max_temperature_k: Float::INFINITY, stress_rate: 0.0)
        super(
          id: id, label: label,
          ports: [
            Port.new(id: :inlet,  direction: :inlet,  accepts: accepts,
                     max_kg_per_s: max_kg_per_s),
            Port.new(id: :outlet, direction: :outlet, accepts: accepts,
                     max_kg_per_s: max_kg_per_s)
          ]
        )
        @conductance = conductance&.to_f
        @one_way = one_way
        # A pressure source in series with this conduit. `stack_height_m` earns its draught
        # from buoyancy and therefore varies with the fire; `head_pa` is a fan or a pump and is
        # whatever it is told to be. They add.
        @stack_height_m = stack_height_m.to_f
        @head_pa = head_pa.to_f
        @head_control_id = head_control_id&.to_sym
        @blast_from = blast_from&.to_sym
        @blast_pa_per_kg_per_s = blast_pa_per_kg_per_s.to_f
        @heat_capacity = heat_capacity.to_f
        @ambient_conductance = ambient_conductance.to_f
        @ambient_k = ambient_k.to_f
        @control_id = control_id&.to_sym
        # Valve trim. 1.0 is linear — flow area proportional to lever — and is the default, so
        # every conduit that does not ask for this behaves exactly as it always did.
        @rangeability = rangeability.to_f
        @max_temperature_k = max_temperature_k.to_f
        # What the pipe is made of. Supplies a temperature rating only when one was not given
        # directly — see `Concerns::Thermal#rated_temperature_k`.
        @material = material&.to_sym
        @stress_rate = stress_rate.to_f
      end

      # Material passes through rather than stopping here, so the arbiter resolves past it.
      def transport? = true

      # A check valve. Pipes are bidirectional by default, because reverse flow is real
      # physics rather than an error: a chimney backdraughts when the fire dies, a line
      # siphons, an open valve blows back when the vessel it feeds is the higher of the two.
      #
      # It used to be forced on for every conduit, and the reasoning has since been shown to
      # be backwards. A pressure network built entirely from diodes **has no equilibrium** —
      # it can only ever move one way, so a single overshoot latches and is never corrected.
      # Two vessels joined by a pipe swapped their contents and stayed swapped forever.
      #
      # Say so explicitly on the parts that really are one-way. A safety valve is the obvious
      # one: it must never let the boiler breathe in.
      def one_way? = @one_way

      def initial_temperature_k = @ambient_k

      # A conduit declares no intent. It is not an endpoint for material, so there is nothing
      # for it to want — the path it belongs to is settled between the holders at its ends.
      #
      # This is what removed the oscillation. See the class comment before reinstating it.
      def plan(_state, _ctx) = Intent.none

      # How much this conduit will pass this tick, in kg.
      #
      # **A rupture is not a plug, so failure does not appear here at all.**
      #
      # This used to `return 0.0 if broken?(state)`, which made a burst pipe a *better* seal
      # than the working one — the line backed up all the way to the source and everything
      # downstream starved completely. Backwards on its own terms, and the shortcut
      # `design_sketches/blueprints.md` §3 rules out by name.
      #
      # The fix is not a leak fraction subtracted here either, which is what the failure-model
      # sketch first proposed. **A hole in a pipe does not reduce its bore**: the pipe still
      # passes what it always passed, and what starves the far end is that the upstream holder
      # is now being drained by two paths instead of one. So the hole is a `Nodes::Breach`
      # beside it — a parallel path the arbiter apportions against — and this method goes back
      # to being about nothing but rating and lever.
      #
      # Consequence worth knowing: **a ruptured conduit with no breach wired next to it does
      # nothing.** That is deliberate. It is strictly better than plugging, and it puts the
      # spill where it can be sized and pointed somewhere, rather than hiding it in a subtraction.
      # `_state` because this conduit needs none — but the arbiter calls it as
      # `throughput_kg(states.fetch(id), ctx)` and subclasses do use it, so the arity stays.
      def throughput_kg(_state, ctx)
        port(:outlet).capacity_kg(ctx.dt) * open_fraction(ctx)
      end

      # A fan or a pump: pressure this conduit supplies of its own, independent of temperature.
      # On a lever if it has one, so forced draught is something an operator turns up.
      #
      # Buoyancy is handled separately in `Arbiter.path_head`, because it depends on what is
      # flowing rather than on the fitting.
      def head_pa(ctx)
        fan = if @head_pa.zero?
          0.0
        elsif @head_control_id
          @head_pa * (ctx.controls.fetch(@head_control_id, 0.0) / 100.0).clamp(0.0, 1.0)
        else
          @head_pa
        end

        fan + blast_pa(ctx)
      end

      # The blastpipe: exhaust discharged up the chimney drags flue gas with it.
      #
      # This is how a locomotive breathes, and it is the reason one can steam at all — a fire
      # that has to raise steam faster than a tall stack can draw for cannot be fed by buoyancy,
      # which is temperature-limited and therefore weakest exactly when a cold engine needs it
      # most. Sending the exhaust up the stack instead makes draught scale with **how hard the
      # engine is working**: more steam used, more blast, more air, more steam. A real and
      # self-correcting loop, and the thing a driver actually feels when they open up.
      #
      # Reads the previous tick's discharge through `ctx`, like every other cross-node read.
      def blast_pa(ctx)
        return 0.0 if @blast_from.nil? || @blast_pa_per_kg_per_s.zero? || ctx.dt <= 0.0

        kg = ctx.node_state(@blast_from)&.fetch(:exhaust_kg, 0.0) || 0.0
        @blast_pa_per_kg_per_s * (kg / ctx.dt)
      end

      # How freely gas passes, in mol/(Pa·s) — a valve flow coefficient, and the same kind of
      # number `ThermalLink#conductance` is for heat.
      #
      # `nil` means this conduit does not model pressure-driven flow, and any path through it
      # stays rate-driven on `throughput_kg`. That is the migration seam: a conduit opts in to
      # the relaxation by declaring one. See docs/design_sketches/transport_model.md.
      # **This one was worse than a plug.** It used to `return 0.0 if broken?(state)`, and a
      # zero conductance does not merely shut the path — `Arbiter.gas_coupling` rejects any
      # conductance at or below zero, so the path stops being **pressure-driven at all** and
      # falls back to a rate rule with no head. `graph/CLAUDE.md` records what that costs when
      # it happens by accident: *"a single missing number deletes the draught, the chimney and
      # the blower together, with no error of any kind."* One ruptured flue section did exactly
      # that, on purpose. A failure that changes the *regime* of a path rather than its rate is
      # not a hobbled machine, it is a different one.
      def gas_conductance(_state, ctx)
        return nil if @conductance.nil?

        @conductance * open_fraction(ctx)
      end

      # Fully open unless a lever says otherwise. `ctx.controls` carries the *actual* lever
      # position, not the target, so a valve that a minion is still cranking open restricts
      # flow to where it has actually got to.
      #
      # ## Trim: where the lever's authority actually lands
      #
      # A linear valve is not a linear *control*, because what it opens into pushes back. A
      # pressure-driven path settles `n = k·dt·ΔP / (1 + k·dt·ΣC⁻¹)`, so once `k·dt·ΣC⁻¹`
      # passes 1 the two ends substantially equalise within a tick and further opening buys
      # almost nothing. Measured on the regulator, whose full-open term is **1.76**: the steam
      # chest reaches 85% of boiler pressure by lever 30, and **the remaining 70% of the travel
      # delivered 21% of the power range** — a control that does all its work in the first third
      # and then reads as broken.
      #
      # `rangeability` is the standard answer and a real piece of ironmongery: equal-percentage
      # trim, shaped so equal steps of travel give equal *proportional* steps of flow, which is
      # exactly how you linearise a valve working into a system that saturates.
      #
      #     fraction = (R^lever − 1) / (R − 1)
      #
      # Continuous at both ends, unlike the textbook `R^(lever−1)`, which never quite shuts —
      # real trim relies on a separate seat for that and this engine has no such part. That also
      # makes R here a gentler curve than the same number on the classic form, so **do not carry
      # the usual 30–50 rangeability across**: pick it from a sweep. The regulator wanted 8, and
      # 50 was restrictive enough to stop the engine turning below a third of its travel.
      #
      # **1.0 means linear**, so a conduit that does not declare this is bit-identical to before.
      def open_fraction(ctx)
        return 1.0 unless @control_id

        lever = (ctx.controls.fetch(@control_id, 0.0) / 100.0).clamp(0.0, 1.0)
        return lever if @rangeability <= 1.0

        ((@rangeability**lever) - 1.0) / (@rangeability - 1.0)
      end

      # Over-temperature is the generic failure mode. A conduit with no rated temperature
      # never wears out, which is the right default for plumbing that is not interesting.
      #
      # The wall reaches the temperature of whatever crosses it (`Tick#carry_through`), so
      # this still sees hot steam even though nothing lingers.
      def stress_per_second(state, ctx)
        return 0.0 if @stress_rate.zero?

        rated = rated_temperature_k(ctx.content)
        return 0.0 if rated.infinite?

        over = temperature_k(state, ctx.content) - rated
        over.positive? ? (over / rated) * @stress_rate : 0.0
      end

      # A pipe splits. Whether that is a weep or a severed line is a matter of *size*, which
      # belongs to the breach the rupture opens rather than to a second name here.
      def failure_modes = { rupture: {} }

      def failure_type = :conduit_rupture

      def failure_detail(state, ctx)
        { temperature_k: temperature_k(state, ctx.content).round(2) }
      end
    end
  end
end
