# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A join that earned its place in the graph. Most joins are edges and cost nothing; a join
    # becomes a node when it is *interesting* — it carries a control point, it can fail, or it
    # restricts flow. A valve, a pump, a section of pipe that can rupture.
    #
    # It is also where control points naturally live: the fitting between two vessels is where a
    # real plant puts a valve, and the lever here rather than on the vessel disperses complexity
    # out of the mechanisms and into the joins around them.
    #
    # **A conduit holds nothing, and that is the whole point.** An intermediate node has to size
    # its intake from tick N−1, before it knows what it will discharge, so the only bounded
    # inventory rule — `draws = throughput − held` — gives the map `h ↦ T − h`. That is an
    # involution with eigenvalue exactly −1: it oscillates forever and **cannot damp**. Symptoms
    # are a damper alternating 0.84 kg / 0.000 kg indefinitely, a firebox with no air at all
    # every other tick, and every conduit delivering about half its rated throughput.
    #
    # So it is a **flow mediator**: a rate limit, a lever, a wall and the ability to fail, with
    # `Path` resolving material straight from one holder to the next. It keeps `Thermal` and
    # `Wearing` and has no `Holds` or `Pressurized` — no *residence*, but full thermal contact.
    #
    # Do not give this class `Holds` again. `spec/reactor_sim/transport_spec.rb` asserts it.
    class Conduit < Node
      include Concerns::Thermal
      include Concerns::Wearing

      attr_reader :heat_capacity, :ambient_conductance, :ambient_k,
                  :control_id, :max_temperature_k, :stress_rate, :conductance,
                  :stack_height_m, :head_control_id, :blast_from, :blast_pa_per_kg_per_s,
                  :material, :driven_by, :lift_m, :efficiency, :rated_omega, :delivers_to

      def initialize(id:, label: nil, accepts: [], max_kg_per_s:, conductance: nil,
                     one_way: false,
                     stack_height_m: 0.0, head_pa: 0.0, head_control_id: nil,
                     blast_from: nil, blast_pa_per_kg_per_s: 0.0,
                     driven_by: nil, lift_m: 0.0, efficiency: 1.0, rated_omega: nil,
                     delivers_to: nil,
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
        # **What pays for the head.** A conduit naming no shaft behaves exactly as it always
        # did, which is what lets this land without touching anything already working.
        #
        # `lift_m` is static head the fitting must OVERCOME where `head_pa` is head it supplies;
        # they sit in the same term because they are the same physics, differing only in sign.
        @driven_by = driven_by&.to_sym
        @lift_m = lift_m.to_f
        @efficiency = efficiency.to_f
        # The speed at which a driven fitting delivers its rated `head_pa`. Head goes as ω², so
        # a machine turning at half speed supplies a quarter of its head — which is what makes a
        # struggling engine deliver less draught rather than the same draught more slowly.
        @rated_omega = rated_omega&.to_f
        # Where the hydraulic half of the bill lands. Defaults to this fitting, which heats what
        # it is blowing or pumping — see `drag_conductances`.
        @delivers_to = (delivers_to || id).to_sym
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

      # A check valve. Pipes are bidirectional by default, because reverse flow is real physics
      # rather than an error: a chimney backdraughts when the fire dies, a line siphons, an open
      # valve blows back when the vessel it feeds is the higher of the two.
      #
      # **A pressure network built entirely from diodes has no equilibrium** — it can only move
      # one way, so a single overshoot latches and is never corrected, and two vessels joined by
      # a pipe swap contents and stay swapped forever. Declare it only on parts that really are
      # one-way, such as a safety valve, which must never let the boiler breathe in.
      def one_way? = @one_way

      def initial_temperature_k = @ambient_k

      # A conduit declares no intent. It is not an endpoint for material, so there is nothing
      # for it to want — the path it belongs to is settled between the holders at its ends.
      #
      # This is what removed the oscillation. See the class comment before reinstating it.
      def plan(_state, _ctx) = Intent.none

      # How much this conduit will pass this tick, in kg.
      #
      # **A rupture is not a plug, so failure does not appear here at all.** Returning zero for a
      # broken conduit makes a burst pipe a *better* seal than a working one, backing the line up
      # to the source and starving everything downstream. A leak fraction subtracted here is
      # wrong too: **a hole in a pipe does not reduce its bore.** The pipe passes what it always
      # passed; what starves the far end is the upstream holder being drained by two paths. So
      # the hole is a `Nodes::Breach` beside it, and this method is about nothing but rating and
      # lever.
      #
      # Consequence: **a ruptured conduit with no breach wired next to it does nothing**, which
      # is deliberate — it puts the spill somewhere it can be sized and pointed.
      def throughput_kg(state, ctx)
        port(:outlet).capacity_kg(ctx.dt) * open_fraction(ctx) * derating(state, :throughput)
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

        (fan * speed_fraction(ctx)) + blast_pa(ctx)
      end

      # **Head goes as ω².** A fitting belted to a shaft supplies its rated head only at its
      # rated speed; a stalling engine delivers a quarter of it at half speed, which is what
      # makes a driven blower fail the way a real one does rather than merely slowly.
      #
      # 1.0 for an undriven conduit, so every existing fitting is untouched. Reads the previous
      # tick's speed, like every other cross-node read — §4.2 of the sketch: the loop is
      # negative feedback (faster shaft → more head → more flow → more torque → slower shaft),
      # and a lag on negative feedback is damped.
      def speed_fraction(ctx)
        return 1.0 if @driven_by.nil?
        return 0.0 if @rated_omega.nil? || !@rated_omega.positive?

        omega = ctx.node_omega(@driven_by).to_f
        return 0.0 unless omega.positive?

        ((omega / @rated_omega)**2).clamp(0.0, 1.0)
      end

      # The blastpipe: exhaust discharged up the chimney drags flue gas with it, which is how a
      # locomotive breathes. Buoyancy is temperature-limited and so weakest exactly when a cold
      # engine needs it most; sending the exhaust up the stack makes draught scale with **how
      # hard the engine is working** — more steam used, more blast, more air, more steam.
      #
      # Reads the previous tick's discharge, like every other cross-node read.
      def blast_pa(ctx)
        return 0.0 if @blast_from.nil? || @blast_pa_per_kg_per_s.zero? || ctx.dt <= 0.0

        kg = ctx.node_state(@blast_from)&.fetch(:exhaust_kg, 0.0) || 0.0
        @blast_pa_per_kg_per_s * (kg / ctx.dt)
      end

      # How freely gas passes, in mol/(Pa·s) — a valve flow coefficient, and the same kind of
      # number `ThermalLink#conductance` is for heat.
      #
      # `nil` means this conduit does not model pressure-driven flow, and any path through it
      # stays rate-driven on `throughput_kg`: a conduit opts in to the relaxation by declaring a
      # conductance. See `docs/design_sketches/transport_model.md`.
      #
      # **Zero here is worse than a plug**, so failure must not appear in it. `Arbiter.gas_coupling`
      # rejects any conductance at or below zero, which stops the path being pressure-driven *at
      # all* and drops it to a rate rule with no head — deleting the draught, the chimney and the
      # blower together, with no error of any kind. A failure that changes a path's *regime*
      # rather than its rate is a different machine, not a hobbled one.
      def gas_conductance(state, ctx)
        return nil if @conductance.nil?

        @conductance * open_fraction(ctx) * derating(state, :throughput)
      end

      # Fully open unless a lever says otherwise. `ctx.controls` carries the *actual* lever
      # position, not the target, so a valve that a minion is still cranking open restricts
      # flow to where it has actually got to.
      #
      # **Trim: a linear valve is not a linear control**, because what it opens into pushes back.
      # A pressure-driven path settles `n = k·dt·ΔP / (1 + k·dt·ΣC⁻¹)`, so once `k·dt·ΣC⁻¹` passes
      # 1 the two ends substantially equalise within a tick and further opening buys almost
      # nothing — a control doing all its work in the first third of its travel and then reading
      # as broken.
      #
      # `rangeability` is equal-percentage trim, shaped so equal steps of travel give equal
      # *proportional* steps of flow:
      #
      #     fraction = (R^lever − 1) / (R − 1)
      #
      # Continuous at both ends, unlike the textbook `R^(lever−1)`, which never quite shuts —
      # real trim relies on a separate seat and this engine has no such part. That makes R a
      # gentler curve than the same number on the classic form, so **do not carry the usual
      # 30–50 across**: pick it from a sweep.
      #
      # **1.0 means linear**, so a conduit that does not declare this is unaffected.
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
      #
      # The derating is the **damage to the pipe**, not the leak: a split line is bent, scaled
      # and partly collapsed around the tear, so it delivers less onward even counting nothing
      # that escapes. The escaping part is a `Nodes::Breach`, and conflating the two is the
      # mistake this model made first — see that class for why a throughput term cannot express
      # a spill.
      # --- driven fittings ---------------------------------------------------------------
      #
      # **The shaft this fitting hangs off.** `Arbiter.drive_drags` already gathers drag from any
      # node answering to `drag_shaft`, whether or not it rotates — that is exactly what a
      # `Nodes::Bearing` is — so a driven conduit is picked up with no change to the arbiter, the
      # relaxation solver or the tick.
      def drag_shaft = @driven_by

      # What the shaft pays, as a **conductance** rather than a torque.
      #
      # A drag conductance `c` means `τ = c·ω`, so `P = c·ω²` and `c = P/ω²`. Declaring it this
      # way lands it on the diagonal of the backward-Euler drive solve, which is unconditionally
      # stable at any `dt`; an applied torque would hand that back. It is also the right shape:
      # for a centrifugal machine head goes as ω² and flow as ω, so `P ∝ ω³` and `c` is linear
      # in ω — the same curve `Load`'s `:fan` already uses.
      #
      #   P_hydraulic = (head_pa + ρ·g·lift_m) · Q
      #   P_shaft     = P_hydraulic / efficiency
      #
      # **Both terms collapse to zero when nothing is flowing**, which is the behaviour that
      # matters: a pump against a shut valve costs its shaft almost nothing, and one that has
      # lost its water costs nothing and delivers nothing.
      #
      # > A real centrifugal machine still churns against a closed valve — perhaps half its
      # > rated power — so this understates a throttled pump. Modelling that needs a duty point
      # > and a curve shape, which is `Load`'s `curve:`/`rated_omega:` machinery again and is
      # > worth reaching for only if a sweep shows the flat answer makes the choice dull.
      # **The two halves are different claims and are booked separately.** The hydraulic half
      # went where the fitting sends it; the rest is what the fitting wasted. `Tick#book_drive`
      # understands three kinds of destination — `:work` leaves the operation on the ledger,
      # `:friction` leaves it as loss, and a node id becomes heat in that node's metal.
      #
      # `delivers_to:` defaults to the fitting itself, which is right for a **fan**: the air it
      # blows stays in the operation and the pressure it put there dissipates into the stream,
      # warming what passes. A **sump pump** says `delivers_to: :work`, because the water it
      # lifted genuinely leaves and takes that energy with it.
      def drag_conductances(state, ctx)
        return {} if @driven_by.nil?

        omega = ctx.node_omega(@driven_by).to_f
        return {} unless omega.positive? && @efficiency.positive?

        hydraulic_w = hydraulic_w(state, ctx)
        return {} unless hydraulic_w.positive?

        square = omega * omega
        lost_w = (hydraulic_w / @efficiency) - hydraulic_w

        { @delivers_to => hydraulic_w / square, id => lost_w / square }
          .each_with_object(Hash.new(0.0)) { |(to, c), acc| acc[to] += c if c.positive? }
      end

      # `ΔP × Q`, where `Q` is the volume this wall actually passed last tick and `ΔP` is what
      # it supplied plus what it had to lift against. `Tick#advect` records both, because a
      # conduit is resolved through and has no other way to know.
      def hydraulic_w(state, ctx)
        return 0.0 unless ctx.dt.positive?

        flow_m3_per_s = state.fetch(:carried_m3, 0.0) / ctx.dt
        return 0.0 unless flow_m3_per_s.positive?

        delta_pa = head_pa(ctx) + lift_pa(state)
        return 0.0 unless delta_pa.positive?

        delta_pa * flow_m3_per_s
      end

      # `ρ·g·h`. Static head is a property of the fluid being lifted, so the density is what
      # actually went through — `kg/m³` of the stream itself — rather than a configured number
      # that could disagree with it.
      def lift_pa(state)
        return 0.0 unless @lift_m.positive?

        volume = state.fetch(:carried_m3, 0.0)
        return 0.0 unless volume.positive?

        (state.fetch(:carried_kg, 0.0) / volume) * Units::GRAVITY_M_PER_S2 * @lift_m
      end

      def failure_modes = { rupture: { derates: { throughput: 0.7 } } }

      def failure_detail(state, ctx)
        { temperature_k: temperature_k(state, ctx.content).round(2) }
      end
    end
  end
end
