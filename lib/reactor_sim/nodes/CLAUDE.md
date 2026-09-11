# `nodes/` — generic, reusable machinery

Everything here is **generic**, in code *and* comments. Anything genuinely specific to one
machine belongs under `operations/<name>/`. Reference:
[`docs/reference/nodes.md`](../../../docs/reference/nodes.md).

## A node holds no mutable state

It is configuration and behaviour; all state lives in the operation's frozen hash and is
passed in. A node physically *cannot* write to the tick it is reading from, which is what
makes order-independence enforceable rather than merely intended. `freeze` at the end of
`initialize`.

## The two methods you write

```ruby
def plan(state, ctx)         -> Intent   # what I want to draw and push, against N−1
def apply(state, ctx, grant) -> state    # what I actually got, and what it does to me
```

`apply` may also return `[state, events]`.

```ruby
Intent.new(draws: { inlet_port_id => kg }, pushes: { outlet_port_id => kg })
Intent.none

grant.received_at(:inlet)   # parcels that ARRIVED, after the walls took their share
grant.sent_at(:outlet)      # parcels that left, carrying their enthalpy
grant.sent_kg(:outlet)
grant.rejected_kg(:outlet)  # what could not be pushed — back-pressure
grant.blocked?
```

`received` is not `sent` seen from the other end: a stream gives up energy to every conduit it
crosses. Ledger a crossing from these, never from a before/after delta — a delta is the net of
both directions, and at a boundary they cancel.

Optional hooks: `reactions` (ids this node hosts), `broken?(state)`, `stress_per_second`,
`overload?`.

## What the engine already did for you

By the time `apply` runs, **parcel bookkeeping is done**: granted parcels removed from
senders, added to receivers, every node rebalanced to one temperature. Heat transfer, ambient
loss, friction, phase change, reactions, wear and observation are all driven generically.

**A node that re-implements any of that is a bug.** `apply` is only for what makes this node
*this* node — a heater, a brake, a torque source.

## Holders and transport is the key distinction

A node either **holds** material or **transports** it, never both. `Node#transport?` says
which, and only `Conduit` and its subclasses answer yes.

Holders are passive — they declare no intent and take what arrives. Transport nodes are
resolved *through*: `Path` runs from one holder's outlet to the next holder's inlet, and a
conduit contributes a rate limit, a lever, a wall and the ability to fail. **With nothing
declared at either end the path drives the flow**, which is what replaced the conduit's
`pushes: held`.

> **Never give a transport node `Holds`.** It must size its intake from N−1, before it knows
> what it will discharge, so the only bounded rule — `draws = throughput − held` — gives
> `h ↦ T − h`: an involution, eigenvalue exactly −1, oscillates forever, cannot damp. Drop the
> `− held` and you get steady flow with an unbounded duct instead. **Steady inventory and
> steady throughput are mutually exclusive for a stateful intermediate node.**
>
> It cost a damper alternating 0.84 / 0.000 kg forever, a firebox with no air at all every
> other tick, a cylinder swinging 16.4/78.2 kW, and every conduit quietly delivering half its
> rating. `spec/reactor_sim/transport_spec.rb` asserts a conduit holds nothing.

If you write a node that both holds and moves material, it is a holder — put the restriction
on a conduit beside it.

## A prime mover is a cycle, and needs a supply node to read

Three rules, each of which `Cylinder` broke first. Full detail and the measurements are in
[`docs/reference/nodes.md`](../../../docs/reference/nodes.md).

- **Size a displacement intake at the SUPPLY's density**, never the held charge's. The charge
  has already expanded; a demand built on it is a collapsing feedback loop.
- **And that density is the supply's BULK density, not its working gas's.** A piston sweeps a
  *volume* and gets whatever is in it — `Holds#bulk_density_kg_m3`. Pricing the swept volume at
  the ideal-gas figure asks for the mass it would hold *if the supply were dry*, so a chest full
  of primed water handed the cylinder a few hundred grams of it: at 170 rpm and 40% cut-off the
  piston sweeps 49.6 kg of water and the gas figure asked for 0.126 kg. **Hydraulic lock at speed
  was arithmetically unreachable** — the piston could not swallow a slug because it never asked
  for one. The fourth mass-for-volume confusion in this codebase; see `Obstructs` below.
- **Never `max` a displacement rule with a pressure-equalisation rule.** `gas_headroom_kg` has
  no cut-off, speed or geometry in it, so it wins every time and the real lever goes dead.
- **A cycle's P₁ comes from its supply, and the supply must be a real holder.** A lumped body
  has five pressures per revolution and reports roughly the least useful one. Pointing the
  diagram at the *boiler* instead is not a fix — the regulator then cannot affect torque, and
  the `extractable_joules` bound in `Tick#transmit_torque` silently becomes the throttle
  (measured discarding 30–50% of declared work). **A conservation clamp is not a mechanism.**
  Give the machine the part it is missing — a steam chest — and the loop closes on its own.

## Obstruction: a deposit in the way, not merely taking up room

`Obstructs` gives a node `occupancy` against a **characteristic volume it declares**, and that
denominator is the whole idea: the water that destroys the steam engine's cylinder is 7% of its
volume and 100% of its clearance. Detail in
[`docs/reference/nodes.md`](../../../docs/reference/nodes.md).

- **What occupancy means is yours, not the concern's.** A cylinder derives a top-dead-centre
  pressure; a bed throttles its reactions; a tank does nothing.
- **The pressure that destroys a part is not always the one it reports.** A lumped body has no
  crank angle, so `Cylinder#compression_pressure_pa` reconstructs it — and `ReliefValve` takes
  `senses_quantity:` because a valve pointed at `pressure_pa` here would look like protection
  and be none.
- **Tag precisely.** `:solid` on a firebox makes the coal an obstruction as well as the ash.
- **Ship the remedy with the hazard.** A deposit a player cannot clear is a dead end, not a
  mechanic — which is why the ashpan and its lever landed with the choke.
- Needs `Holds`, so **a conduit cannot foul**: it holds nothing by design.

## A conduit is still a real part

It keeps `Thermal` and `Wearing`. `Tick#carry_through` mixes the passing stream with the wall
to one temperature — the same lumped-body rule every other node obeys — so a chimney still
cools its flue gas and a hot line can still rupture. We removed the *residence*, not the pipe.

## The stock nodes

A snapshot — `ls lib/reactor_sim/nodes/*.rb` is the truth. **Adding or removing one means
updating this table and [`docs/reference/nodes.md`](../../../docs/reference/nodes.md) in the
same commit.**

| Node | Concerns | What it is |
|---|---|---|
| `Vessel` | Thermal, Holds, Obstructs, Wearing, Pressurized | Tank, vat, drum, pressure vessel. **Passive** — declares no intent. Optional heater, `reactions:`, and `obstruction_tags:` + `void_fraction:` for a bed its own waste can choke. |
| `Conduit` | Thermal, Wearing | Pipe or valve. **Transport** — holds nothing. Rate limit, lever, wall, failure. Optional `control_id`, `rangeability:` (valve trim). |
| `Boiler` | (a `Vessel`) | A drum holding a liquid and its own vapour. Its vapour outlet is never quite dry; **swell** lifts the level when it is pulled hard, and priming is what happens when a high glass and a hard pull coincide. |
| `Atmosphere` | Thermal, Holds | The outside world: unlimited source and sink, fixed pressure reference. |
| `Flywheel` | Rotating, Wearing | Any heavy spinning mass. Bursts on overspeed. `material:` from content. |
| `Load` | Rotating | Where useful work leaves the operation. |
| `Cylinder` | Thermal, Holds, Obstructs, Pressurized, Wearing | An indicator diagram → shaft torque. Positive-displacement intake at **supply** density. Working fluid is configuration. |
| `ReliefValve` | (a `Conduit`) | Opens itself above a sensed quantity. `senses_quantity:` defaults to `pressure_pa` and need not be it. |

Reach for these first. Write a new node only when the behaviour genuinely does not exist.

## Reading another node

Safe via `ctx.node_pressure(id)`, `ctx.node_omega(id)`, `ctx.node_temperature(id)`,
`ctx.node_state(id)` — all read the **previous tick**, which is settled and identical for
everyone. All return `nil` when the node cannot answer.

**Declare the relationship in config so it stays visible**: `Cylinder` has `drives:`,
`exhausts_to:`, `supplied_by:`; `ReliefValve` has `senses:` and `senses_quantity:`. Reaching for an id that is not
declared anywhere is how a graph becomes unreadable.

## Adding a node: checklist

1. Subclass `Node`, include the concerns you need, provide their config as **readers**.
2. Define ports in `super(id:, label:, ports: [...])`.
3. Write `plan` (against previous-tick state) and `apply` (given the grant).
4. If it injects or extracts mass/energy, set the matching state key so `record_injections`
   ledgers it — see
   [`settlement.md`](../../../docs/reference/settlement.md#how-a-node-reports-a-crossing).
5. If it can fail, implement `stress_per_second` and/or `overload?`.
6. `freeze` at the end of `initialize`.
7. Add the require to `lib/reactor_sim.rb`, in dependency order.
8. Keep it generic. If it is machine-specific, put it under that operation's folder instead.
