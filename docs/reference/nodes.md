# Nodes, ports, links and concerns

The graph. `lib/reactor_sim/graph/` and `lib/reactor_sim/nodes/`.

---

## The rule that shapes everything

**A node holds no mutable state.** It is configuration and behaviour; all state lives in the
Operation's frozen hash and is passed in. A node physically *cannot* write to the tick it is
reading from, which is what makes order-independence enforceable rather than merely intended.

Most node classes call `freeze` at the end of `initialize`.

---

## The two methods you write

```ruby
def plan(state, ctx)         -> Intent   # what I want to draw and push
def apply(state, ctx, grant) -> state    # what I actually got, and what it does to me
```

`apply` may also return `[state, events]`.

```ruby
Intent.new(draws:  { inlet_port_id  => kg },
           pushes: { outlet_port_id => kg })
Intent.none
```

```ruby
grant.received_at(:inlet)  # parcels that ARRIVED — after the conduit walls took their share
grant.sent_at(:outlet)     # parcels that left, with the enthalpy that went with them
grant.sent_kg(:outlet)
grant.rejected_kg(:outlet) # what could not be pushed — back-pressure
grant.blocked?
grant.total_received_joules / grant.total_sent_joules
```

**`received` and `sent` are not two views of the same parcels.** A stream gives up energy to
every conduit it crosses, so what a sink is handed is cooler than what the source dispatched,
with the difference left in the pipe wall. Building `received` from the dispatched parcels
credits a sink with energy that has not arrived — invisible while only mass was read from it,
and worth 4 kJ a tick of drift the moment `Atmosphere` began ledgering the enthalpy.

**By the time `apply` runs, parcel bookkeeping is already done for you.** Granted parcels have
been removed from senders, added to receivers, and every node rebalanced to one temperature.
`apply` is for what makes this node *this* node — a heater, a brake, a torque source. See
[`tick.md`](tick.md#what-a-node-does-not-have-to-do).

Optional hooks: `reactions` (array of reaction ids this node hosts) and `broken?(state)`.

---

## Concerns

Composed in; each contributes a state fragment merged by `Node#initial_state`. A node that
includes nothing carries nothing — an indicator lamp should not have a specific heat.

| Concern | Config you must provide | State it adds | Key methods |
|---|---|---|---|
| `Thermal` | `heat_capacity`, `ambient_conductance`, `ambient_k`, `initial_temperature_k` | `joules` | `temperature_k`, `add_joules`, `rebalance`, `total_heat_capacity` |
| `Holds` | `volume_m3` | `parcels` | `contents_kg`, `room_m3`, `contents_volume` |
| `Wearing` | `durability_range`, `stress_per_second`, `overload?` | `durability`, `initial_durability`, `broken` | `apply_wear`, `integrity` |
| `Pressurized` | (needs `Holds` + `Thermal`) | none — derived | `pressure_pa`, `gas_headroom_kg` |
| `Obstructs` | `obstruction_volume_m3`, `obstruction_tags` (needs `Holds`) | none — derived | `occupancy`, `obstructing_volume_m3` |
| `Rotating` | `moment_of_inertia`, `radius_m`, `friction`, `initial_omega` | `angular_momentum` | `omega`, `rpm`, `kinetic_joules`, `apply_torque` |

Config is supplied as **reader methods**, not ivars — `def volume_m3` / `attr_reader
:volume_m3`. Concerns call them.

### Failure: fatigue vs overload

`Wearing` supports both, and the distinction matters:

- `stress_per_second(state, ctx)` — durability units consumed per second. Gradual. This is
  what lets a player learn "I ran it too hot for too long."
- `overload?(state, ctx, integrity)` — immediate failure this tick, bypassing durability. For
  things that do not deteriorate but simply let go past a limit.

`integrity` (0..1) is passed to `overload?` so a worn part fails sooner than a fresh one,
keeping accumulated history meaningful. Events carry `cause: :fatigue` or `cause: :overload`.

`Cylinder`'s hydraulic lock is the clearest overload in the codebase and shows what the hook is
for: water does not compress, so once the clearance space is full of it the piston has nowhere
to go and something lets go in a single stroke. Nothing about it is gradual. It also shows that
**an overload may depend on more than the state of the part** — it returns `false` while the
shaft is stopped, because a standing engine fills quietly with condensate and the damage is only
done on the first stroke after the regulator opens. That is why the remedy (the cocks) has to be
applied *before* the hazard becomes possible, which is what makes it a procedure rather than a
reaction.

Override `failure_type` and `failure_detail(state, ctx)` to describe the failure.

---

## Ports and links

```ruby
Port.new(id:, direction: :inlet | :outlet, accepts: [tags], max_kg_per_s:)
Link.new(from: [node_id, port_id], to: [node_id, port_id])
ThermalLink.new(a:, b:, conductance:)          # W/K
DriveLink.new(a:, b:, stiffness:, max_torque:) # angular momentum
```

- `accepts: []` means "anything". Material must satisfy **both** ports' filters to cross.
- `max_kg_per_s` is **throughput, never storage**. Conflating those two was the original sin
  of the old `Buffer`.
- Links hold no state. Delay is not configurable — it is one tick per hop, emergent from
  graph shape. There is no `delay:` parameter anywhere. **A hop is one `Path`, holder to
  holder**; conduits are resolved through and cost nothing, so inserting a valve no longer
  inserts a tick.
- `Operation` validates wiring at construction: unknown nodes, and links running into an
  outlet or out of an inlet, raise immediately.

---

## The stock nodes

All generic and reusable. Anything genuinely specific to one machine belongs under
`operations/<name>/`.

| Node | Concerns | What it is |
|---|---|---|
| `Vessel` | Thermal, Holds, Obstructs, Wearing, Pressurized | A tank, vat, drum or pressure vessel. **Passive** — declares no intent. Optional heater, `reactions:`, and `obstruction_tags:` + `void_fraction:` for a bed its own waste can choke. |
| `Conduit` | Thermal, Wearing | A pipe or valve. **Transport** — holds nothing; contributes a restriction, a lever, a wall and the ability to fail. Optional `control_id`, `conductance:`, `head_pa:`, `stack_height_m:`, `one_way:`, `rangeability:` (valve trim). |
| `Boiler` | (a `Vessel`) | A drum where a liquid and its own vapour coexist. Its vapour outlet is **never quite dry**, gets wetter as the level rises past `onset_fill`, and **swells** when the pressure falls sharply — which is what turns a high glass into a slug of water. With `crown_fill:` and `fired_by:` it also has a **crown sheet**: the plate over the fire, which burns when the level falls past it. |
| `Atmosphere` | Thermal, Holds | The outside world: unlimited source, unlimited sink, fixed pressure reference. |
| `Flywheel` | Rotating, Wearing | Any heavy spinning mass. Bursts on overspeed. `material:` from content. |
| `Load` | Rotating | Where useful work leaves the operation. Has a **torque curve** — `:fan` (τ ∝ ω²), `:viscous` (τ ∝ ω) or `:constant` — absorbing `max_torque` at `rated_omega`. |
| `Cylinder` | Thermal, Holds, Obstructs, Pressurized, Wearing | An indicator diagram → shaft torque. Positive-displacement intake at supply density. Working fluid is configuration. `drain_control_id:` + `drain_authority:` let an open cock bleed the working space; `material:` + `wall_thickness_m:` give it a hoop rating off its own bore. |
| `ReliefValve` | (a `Conduit`) | Opens itself above a sensed quantity — `senses_quantity:` defaults to `pressure_pa` but need not be it. `ease_control_id:` opens it further by hand (`max`); `control_id:` gags it shut (`×`). Records `lift:`. |
| `FusiblePlug` | (a `Conduit`) | Senses a **state key** on another node and fails **permanently** open above `melts_above:`. A fuse, not a valve. |

### Holders and transport are the key distinction

A node either **holds** material or **transports** it, and never both. `Node#transport?` says
which; only `Conduit` and its subclasses answer yes.

- **Holders** (`Vessel`, `Atmosphere`, `Cylinder`) are where material actually is. They are
  passive: they declare no intent and accept whatever arrives.
- **Transport** nodes are resolved *through*. `Path` runs from one holder's outlet to the next
  holder's inlet, and a conduit contributes a restriction, a lever, a wall and the ability to
  fail. With nothing declared at either end, **the path drives the flow.**

**Two restriction laws, and a conduit picks one.** Declare `conductance:` (mol/(Pa·s)) and the
path is pressure-driven, settled by `Relaxation` against the gradient plus whatever `head_pa`
and `stack_height_m` supply — conductance is then the *whole* restriction and `max_kg_per_s`
does not apply. Leave it off and the path is rate-driven on `throughput_kg` and the ports.
Do not expect both to bind: a throat governed by two numbers that disagree is choked at every
pressure, and a choked coupling carries a fixed flow, which leaves the pressure at either end
with no feedback at all.

**Pressure-driven paths are bidirectional** unless the conduit says `one_way: true`. Backflow
is real — a chimney backdraughts, a valve blows back — and a network built only from diodes
has no equilibrium to reach.

**Head composes along a path, so a pressure source belongs on its own conduit.**
`Arbiter.path_head` *sums* `head_pa` and `stack_height_m` over every conduit on a path, so
putting a fan in series with a valve contributes exactly what a `head_pa:` attribute on the
valve did. That is what makes a pump, a fan or a chimney a **swappable part** rather than an
attribute: you cannot bolt a different fan onto a number.

> **EVERY conduit on a path must declare a conductance, or the path is not pressure-driven at
> all.** `Arbiter.gas_coupling` returns nil the moment one of them does not, and a rate-driven
> path has **no head** — so one missing number deletes the draught, the chimney and the blower
> together.
>
> Measured 2026-09-13, promoting the steam engine's blower from `head_pa:` on the damper to its
> own `:blower_fan` conduit. Left without a conductance on the reasoning that "a fan is a
> pressure source, not a restriction" — true physically, fatal here. The fire never lit: 296 K
> firebox, 3 kPa boiler, dead on both chassis, **no error of any kind.**
>
> The fix is `conductance: Float::INFINITY`, which is the faithful spelling of what the
> attribute did. Series conductances combine **reciprocally** (`1/total = Σ 1/kᵢ`), so `1/∞`
> contributes exactly zero and the damper's measured rating comes through untouched. A finite
> value re-rates the path — 1000 already moves it 0.03% — which would quietly invalidate the
> sweep that chose `damper_conductance`. This is the one place in the engine where
> `Float::INFINITY` is a *statement* ("not the restriction") rather than a silent off switch,
> and it is only safe because the real restriction is next door and measured.
>
> **The blastpipe is NOT the same shape, and promoting it would have been a mistake.** It stayed
> an attribute on `flue` and became a chimney *variant* instead (`:blastpipe_chimney` against
> `:plain_chimney`), for two reasons that generalise: physically a blastpipe and the chimney
> above it are one assembly, proportioned together; and mechanically the blast head has to reach
> **both** paths through the chimney — the firebox draught and the cylinder's own exhaust — which
> only the flue does, because only the flue sits on both. A blastpipe node between the tubes and
> the flue would draught the fire and not the exhaust.
>
> The rule: **an attribute becomes a node when it is a separate object in the machine, and a
> variant when it is a different version of the same object.** `stack_height_m` is a chimney
> property for the same reason, so a taller stack is a variant too.

**Watch the wall when you insert a conduit.** A conduit carries a `heat_capacity` that
`Tick#carry_through` mixes the stream into, so adding one in series adds thermal mass to that
path. It is free on a path whose stream and wall sit at the same temperature (a blower breathing
ambient air) and is not free anywhere else — measure rather than assume.

### A conduit with a thermal link is a heat exchanger

`Tick#carry_through` mixes the passing stream into the conduit's wall, and a `ThermalLink`
couples that wall to anything else — so a pipe between a hot source and a cold sink recovers
heat from what crosses it, at a rate set by the flow rather than by a standing inventory.
That is the whole of the steam engine's boiler tubes, and it needs no new node type.

It matters because a **single** conduction link between two bodies pins the hot one at
`T_cold + Q/k`: the only way to move more heat is to run the source colder. The steam engine
lived on that trade for a long time — a 676 K firebox against a 420 K boiler — and giving the
gas a second route past the water removed it.

### A load needs a torque curve, or the machine has no operating point

A constant-torque brake has no stable intersection with a prime mover's torque curve: the
engine either overcomes it and accelerates without limit, or it does not and stalls. `Load`
was one, and the steam engine sat on the knife edge that produces — throttle 80 settled at
452 rpm, throttle 100 ran away to 1211. All the speed stability came from the cylinder's own
breathing rather than from what it was driving. (That breathing term is gone now — see the
next section. It was standing in for the load curve, and once the curve existed it was a prop.)

This also inverts where the danger is, correctly. Under a constant-torque brake, **full load
was the safe setting** and the way to hurt the machine was to open up against it. Under a fan
law the mill holds the engine at its duty point, and it is *shedding* the load that lets
everything the boiler is pouring in go into acceleration — which is the classic way real
machinery destroys itself, and needs no special case.

> **A transport node may not hold material.** It has to size its intake from tick N−1, before
> it knows what it will discharge, so the only bounded rule — `draws = throughput − held` —
> gives the map `h ↦ T − h`. That is an involution with eigenvalue exactly −1: it oscillates
> forever and cannot damp. Removing the `− held` term gives steady flow and an unbounded duct
> instead. **Steady inventory and steady throughput are mutually exclusive here**, which is why
> the conduit stopped being an endpoint rather than getting a better rule.
>
> The bill: a damper alternating 0.84 kg / 0.000 kg indefinitely, a firebox holding *no air at
> all* every other tick, a cylinder swinging 16.4/78.2 kW at operating speed, and every conduit
> delivering about half its rating with nothing measuring it. Two workarounds were written for
> the symptoms first. See
> [`../design_sketches/flow_through_issue_draft.md`](../design_sketches/flow_through_issue_draft.md).

### Occupancy is measured against a characteristic volume, not the node's

Volume occupancy used to have exactly two consequences, and both are about *room*: `room_m3`
caps what a node will accept, and `free_volume` raises the pressure of the gas that is left.
Neither says a deposit is in the **way** of anything. `Obstructs` is that third consequence, and
water in a cylinder, ash on a grate, tar in a line and scale in a tube are all the same shape.

**The denominator is the whole idea.** The 14 kg of water that destroys the steam engine's
cylinder is **7% of its total volume**, so measured against the node the hazard is invisible;
measured against the clearance space the piston has to fit into, it is exactly 1.0. Declare the
volume that matters and the tag that clogs it:

| Node | `obstruction_volume_m3` | `obstruction_tags` | What it does with `occupancy` |
|---|---|---|---|
| `Cylinder` | clearance (`volume − swept`) | `:liquid` | `compression_pressure_pa` rises, then it locks |
| `Vessel` | `volume × void_fraction` | declared | `reaction_throttle` — a choked bed reacts slower |

`Obstructs` deliberately provides the fraction **and nothing else**, because what occupancy
means genuinely differs and a shared answer would be wrong everywhere. It needs `Holds`: only a
holder can accumulate, so **a conduit cannot foul in this engine** — a fouling pipe has to be a
holder with a restriction beside it, or the deposit has nowhere to live.

Two traps, both real:

- **Tag precisely.** `:solid` on a firebox would make the *coal* an obstruction as well as the
  ash. That is not even wrong — over-filling a grate does choke it — but it is a second
  mechanism arriving silently alongside the one you meant.
- **A deposit with no remedy is a dead end, not a mechanic.** Ash is produced by combustion and
  consumed by nothing, so the choke shipped with an ashpan and a lever in the same commit. If a
  player cannot act on it, prefer not modelling it.

### The pressure that destroys a thing is not always the pressure it reports

`Cylinder#compression_pressure_pa` reconstructs what the charge reaches at top dead centre, the
same way `mean_effective_pressure` reconstructs the area of a diagram this model never traces.
It has to be reconstructed because **a lumped body has no crank angle**: `pressure_pa` spreads
the charge over the whole cylinder, so filling the clearance with enough water to wreck the
engine moves it by about 7% while the pressure at the top of the stroke goes up more than
tenfold.

That is also why `ReliefValve` takes `senses_quantity:`. A safety valve pointed at the plain
vessel pressure here would lift at nothing and look like protection — which is worse than
fitting none. `spec/reactor_sim/obstruction_spec.rb` asserts both halves: the valve that senses
the compression pressure lifts, and the one sensing `pressure_pa` stays shut on the same state.

### A drain has to reach the diagram, not just the mass budget

`Cylinder#admission_pressure_pa` blends the supply pressure toward the back pressure by
`drain_open_fraction × drain_authority`, because an open cock short-circuits the working space to
atmosphere **while the piston is pushing against it**. Shut, `bleed` is 0 and the result is exactly
the supply pressure, so an engine with its cocks closed is bit-identical to one that has none.

> **Draining mass was not enough, and the steam chest is what broke it.** The cocks' only route to
> the output used to be indirect — drain mass, deplete the chest, lower P₁ — and once the cylinder
> could refill from a 25 kg/s inlet the chest stopped depleting (543 → 545 kPa with the cocks wide
> open). Leaving them open cost 4–7% of the power and *gained* 1% at low throttle. `drain_kg_per_s`
> is inert too: 0.25, 0.5, 1.0, 2.0 and 4.0 give byte-identical results, because the cylinder holds
> so little gas that the smallest cock already takes all of it.

The loss is proportional to the pressure difference, so it is largest exactly when the engine is
working hardest — which is the point. Same correction the regulator needed: **a restriction, not a
ration.**

### A transient needs a time constant big enough to have a procedure about

`Cylinder#heat_capacity` is the metal a cold cylinder has to warm through, and it decides whether
warming through is a **procedure** or a formality. At `6.0e4` J/K against a charge of ~0.25 kg of
steam a tick carrying ~2.75 MJ/kg, the metal rises ~11.5 K per tick and reaches steam temperature
in about a dozen ticks — three seconds — so the drain cocks had nothing to do during starting and
peak occupancy over a whole startup reached 0.188.

Taken from the casting instead (bore, stroke, wall thickness, cast iron) it is ~4.0e5 for a
0.45 m × 1.1 m cylinder, and the three states separate properly: cocks shut peaks at 0.859 and
knocks, cocks open stays dry but throws 5% of the power away, cocks open-then-shut gets both.

**Size a thermal mass from the part, not from what makes the transient convenient.** Two general
points fall out:

- **Scale it per variant.** The atmospheric cylinder is a different casting — 5× rather than the
  9× its raw volume suggests, because shell thickness goes as `p·r` and 1.4 atm across a 0.65 m
  radius is a gentler duty than 6 atm across 0.225 m.
- **A drain changes whether the hazard exists at all.** The atmospheric engine never needs its
  cocks (peak 0.086) and should not: it exhausts into a condenser, which drains liquid
  continuously. The high-pressure engine exhausts up a chimney and has nowhere to put it.

### A lumped body cannot express a hazard that is positional

`temperature_k` on a boiler at 5% water is **not high** — it is the same saturation temperature
a boiler at 60% holds, on a smaller mass. **A dry boiler in a lumped model is not hot, merely
empty.** So no `max_temperature_k` on the node could ever trip however far the water fell, and
the low-water hazard was unreachable by configuration rather than by tuning.

The crown sheet is the plate over the fire. While water covers it, it runs a few degrees above
the water and is safe at any fire, because boiling water against steel is an extraordinarily good
heat sink. Uncover it and it is a plate with a fire on one side and steam — a poor conductor —
on the other.

```ruby
crown_exposure(state, content)      # 0 while covered, → 1 as the level falls past crown_fill
crown_temperature_k(state, ctx)     # T_water + exposure · (T_fire − T_water)
stress_per_second(state, ctx)       # max(the Vessel's own, the crown sheet's)
```

Three things worth copying when the same shape comes up again:

- **The derived value is recorded in state** during `apply`, because it needs a cross-node read
  (the fire) and therefore has the wrong arity for `Context#node_reading`, which calls
  `method(state, content)`. One node owns the derivation; everyone else reads the key.
- **It reads the true fill while the gauge glass shows the swelled one.** The glass includes the
  bubbles because a real one does; the plate is cooled by water, not froth. So the needle reads
  comfortable exactly when a hard pull is uncovering the plate — measured, 20.1% on the tick the
  plug went. That gap is the mechanic.
- **`max`, not sum.** Pressure stress and crown stress are two descriptions of one shell, and
  adding them would charge a boiler twice for a single degree of overheat.
- **A plate does not fail because it is hot, it fails because it is hot and there is pressure
  behind it.** So the two ratings *multiply* rather than being checked separately:
  `crown_allowable_pressure_pa` is the cold hoop-stress allowance knocked down as the metal loses
  strength, flat below `CREEP_ONSET_FRACTION` of the temperature rating and falling to nothing at
  it. The consequence that matters in play is that **a boiler carrying more pressure fails sooner
  on the same overheating** — a driver who wound the safety valve up has less margin when the water
  goes, not the same margin. The knockdown is flat at low temperature on purpose: declining from
  ambient would tax a perfectly healthy drum for sitting at its own saturation temperature.

### Irreversible is a different part from reversible

`FusiblePlug` looks like a `ReliefValve` — both sense a quantity elsewhere and open above a
threshold — and was nearly written as one. **A relief valve re-seats and a fusible plug does
not**, and that difference is the whole part: a safety valve is a control a driver works with, a
plug is a fuse that operates once and puts the engine out of service. On the reversible base a
boiler would have quietly healed itself once water came back over the plate, which is precisely
the consequence-free behaviour the hazard exists to not have. `melted` latches in state.

Measured on the steam engine: with the plug fitted the crown peaks at its 620 K melting point and
the boiler keeps integrity 1.00 in every run; scaled over, the crown reaches 1152 K and the shell
ruptures at tick 7088. **The explosion is underneath the safety device**, which is the risk/reward
the modularisation plan wants.

### Over-temperature ratings come from the material

`Concerns::Thermal#rated_temperature_k` resolves an explicit `max_temperature_k:` on the part
first — a water-cooled wall survives what its bare metal would not — then the part's `material:`
looked up in content, then infinity. `stress_rate` stays per-part: how fast a casting fails once
it is over is a property of the casting, as `safety_factor` is on the flywheel.

> **Infinity is a silent off switch.** `Vessel` and `Conduit` have fatigued on temperature since
> `Wearing` was written and never once fired, because every node shipped the default.

### A relief valve's two levers do not compose the same way

```ruby
open_fraction = [ lift(ctx), eased(ctx) ].max * super
```

`ease_control_id:` is the **easing lever** — the handle on the side of a Ramsbottom valve that
lifts it by hand. It is a `max`, so it can only ever open the valve further than the spring
already has: blowing pressure down deliberately is a real operating decision, and holding a
safety valve shut is not something a handle should be able to do.

`control_id:` (inherited from `Conduit`) is the **gag**, and it multiplies, so it *can* shut the
valve completely. That is deliberately available — it is exactly the sort of decision that gets
people killed, and a simulation that makes it impossible is not modelling the hazard.

`setting_control_id:` is the **adjusting screw**, and it is a third distinct thing: the other two
open a valve that is already set, this one decides where it is set. It reads as **margin, not
pressure** — 100 is the full safety margin and the declared `relief_pressure_pa`, 0 is the screw
wound down to `max_relief_pressure_pa` — so an untouched engine is the safe engine and spending
margin is a decision. `full_open_pa` scales with it, keeping the valve's character.

> **A safety valve can end up protecting something other than the vessel, and that is worth
> checking before tuning it.** The steam engine's 6 atm setting was not protecting its boiler; it
> was capping power before the **flywheel** failed. Raising it at all burst the wheel, with the
> drum never reaching the new setting — so the valve could not be moved without a stronger
> driveline, and the gauge that matters while winding the screw down is Wheel Stress, not
> pressure.

### A transport node leaves no trace, so it must record what it did

`ReliefValve#apply` writes `lift:` into its own state, and the reason is general: **a conduit
holds no material, so `Arbiter` leaves nothing in state for an instrument to read.** The one part
whose whole job is to act unsupervised was the one part a player had no way to watch — a boiler
blowing off is the loudest thing in the building and the panel could not say so.

Any transport node with a state a player should be able to see has to publish it the same way.
`apply` reads the previous tick through `ctx` exactly as transport does, so this records what the
valve did rather than predicting what it will do, and it breaks no invariant.

### A failure may be graded by more than the state of the part

`Cylinder#overload?` reads the shaft as well as its own contents, because hydraulic lock costs
what the driveline can pay: a light or slow shaft stalls against the trapped charge and can still
be drained, a heavy one at speed drives the piston into it and a rod bends in one revolution. The
stall needed no new machinery — a locked cylinder returns a **negative** torque, so
`Tick#transmit_torque` decelerates the shaft, measures the energy lost and books it back as heat,
which is what crushing water actually does.

> **Grade it on energy, not on speed.** This was `omega > lock_omega`, and that comparison was
> *structurally unreachable*: filling the clearance needs a standing cylinder, destruction needed
> a turning one, and a locked cylinder makes negative torque so it can never accelerate out of
> one regime into the other. The destruction branch had never once fired on a real engine, and
> moving the thresholds could not fix it — putting `lock_omega` below the filling speed just
> makes a 5 rpm engine shatter, which contradicts every source.
>
> The right question is whether the rotating mass carries enough **energy** to compress the
> charge to top dead centre: `node_kinetic_joules(drives) > compression_work_joules`. Both terms
> were already in state. A 3 200 kg wheel holds 570 kJ at 170 rpm and 2 kJ at 10 rpm, so the
> grading falls out instead of being declared — and it is now the *flywheel* that is the danger,
> which is what the sources actually describe.
>
> It reads only the node named by `drives:`, so inertia coupled through a `DriveLink` is not
> counted. Right for one wheel on one crank; wrong for a geared train.

That grading is what makes a flooded engine a predicament rather than an invisible timer, and it
is why the remedy is a procedure: you open the cocks *before* moving off.

### A prime mover is a cycle, and its intake is not an equalisation

A cylinder, a turbine or a pump is **positive displacement**: what it swallows per revolution is
set by its geometry, its speed and its valve gear, and by *nothing it currently holds*. Two rules
follow, and `Cylinder` got both wrong in ways that were invisible until they were measured.

**Size the intake at the SUPPLY's density, never the held charge's.** A charge that has already
expanded and is halfway through being exhausted is around half the density of what is being
offered, so a demand computed from it is a collapsing feedback loop — less held means less
demanded means less held — that can only settle below the right answer.

**And the supply's density means its BULK density — `Holds#bulk_density_kg_m3` — not the ideal-gas
density of its working fluid.** A piston sweeps a volume and swallows whatever is in it. Pricing
that volume as a gas asks for the mass it *would* hold if the supply were dry, and the gap is not
a rounding error: at 170 rpm and 40% cut-off this cylinder sweeps 0.0496 m³ a tick, which is
**49.6 kg if the stream is water**, and the gas figure asked for 0.126 kg. So a steam chest full
of primed water handed the piston a few hundred grams of it and **hydraulic lock at speed was
arithmetically unreachable** — not tuned out, but impossible, because the piston never asked for
a slug. Dry, the two densities agree and nothing about ordinary running changes.

That is the **fourth** mass-for-volume confusion this codebase has produced, after
`contents_volume` read as a level, a transport affinity set without regard to the mass ratio it
works against, and a clearance priced as 0.029 kg of steam. When a quantity is a volume, carry it
as a volume.

**Do not mix a displacement rule with a pressure-equalisation rule.** `Cylinder#plan` drew
`max(displacement, gas_headroom_kg(supply))`, and the headroom term — "enough to bring my free
volume up to supply pressure" — contains no cut-off, no speed and no geometry. Measured flat at
0.219–0.227 kg per tick from full gear down to 25% cut-off, it won the `max` every time. **Steam
consumption was constant to three significant figures while power fell 140-fold**, which made
the cut-off lever a pure loss and precisely inverted the trade the machine exists to make.

The clearance volume goes with the same care. The textbook admission is `(cutoff + clearance) ×
swept volume`, but that is the *gross* fill and is paired with a credit for the residue the
compression stroke recompresses. If the model keeps the residue instead — this one does, by
holding it back from the exhaust — then charging admission for it again bills the engine twice,
and at 15% cut-off that is a **53% surcharge on exactly the setting where economy is won**,
which is enough on its own to invert the efficiency curve.

> **A lumped body has no single pressure to give a cycle.** Admission, cut-off, release, back and
> compression pressures differ by more than an order of magnitude inside one revolution, so
> asking a `Pressurized` node for "the" pressure returns roughly the *release* condition — the
> least useful of the five. Feeding that back in as the diagram's *admission* pressure made the
> engine reward its own failure: as the cylinder flooded with condensate its free volume shrank,
> so the derived pressure rose, so the engine made **more** power the closer it came to
> hydraulic lock — 175 kW at a liquid fraction of 1.455. **A cycle's P₁ comes from its supply.**

If you write a node that both holds and moves material, it is a holder — put the restriction on
a conduit beside it.

### A conduit is still a real part

Losing residence did not lose the pipe. It keeps `Thermal`, and `Tick#carry_through` mixes the
passing stream with the wall to a single temperature — the same lumped-body rule every other
node obeys. That is what keeps a chimney cooling its flue gas and lets a hot line still rupture
from over-temperature.

---

## Reading another node

A node may read the **previous tick's** state of any node via `ctx.node_pressure(id)`,
`ctx.node_omega(id)`, `ctx.node_temperature(id)`, `ctx.node_state(id)`. Safe, because tick
N−1 is settled and identical for everyone.

Declare the relationship in config so it stays visible — `Cylinder` has `drives:`,
`exhausts_to:` and `supplied_by:`; `ReliefValve` has `senses:`. Reaching for an id that is
not declared anywhere is how a graph becomes unreadable.

---

## Adding a node: checklist

1. Subclass `Node`, include the concerns you need, provide their config as readers.
2. Define ports in `super(id:, label:, ports: [...])`.
3. Write `plan` (against previous-tick state) and `apply` (given the grant).
4. If it injects or extracts mass/energy, set the matching state key so
   `record_injections` ledgers it — see [`settlement.md`](settlement.md#how-a-node-reports-a-crossing).
5. If it can fail, implement `stress_per_second` and/or `overload?`.
6. `freeze` at the end of `initialize`.
7. Add the require to `lib/reactor_sim.rb` in dependency order.
8. Keep it generic — in code *and* comments. If it is machine-specific, put it under that
   operation's folder instead.
