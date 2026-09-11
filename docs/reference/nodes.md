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
| `Boiler` | (a `Vessel`) | A drum where a liquid and its own vapour coexist. Its vapour outlet is **never quite dry**, gets wetter as the level rises past `onset_fill`, and **swells** when the pressure falls sharply — which is what turns a high glass into a slug of water. |
| `Atmosphere` | Thermal, Holds | The outside world: unlimited source, unlimited sink, fixed pressure reference. |
| `Flywheel` | Rotating, Wearing | Any heavy spinning mass. Bursts on overspeed. `material:` from content. |
| `Load` | Rotating | Where useful work leaves the operation. Has a **torque curve** — `:fan` (τ ∝ ω²), `:viscous` (τ ∝ ω) or `:constant` — absorbing `max_torque` at `rated_omega`. |
| `Cylinder` | Thermal, Holds, Obstructs, Pressurized, Wearing | An indicator diagram → shaft torque. Positive-displacement intake at supply density. Working fluid is configuration. |
| `ReliefValve` | (a `Conduit`) | Opens itself above a sensed quantity — `senses_quantity:` defaults to `pressure_pa` but need not be it. |

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
