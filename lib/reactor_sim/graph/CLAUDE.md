# `graph/` — nodes, ports, links, and the arbiter

The structure a node plugs into, plus the settlement that makes order-independence possible.
Reference: [`docs/reference/settlement.md`](../../../docs/reference/settlement.md) and
[`docs/reference/nodes.md`](../../../docs/reference/nodes.md).

## The arbiter is why evaluation order cannot matter

Nodes declare what they *want* against tick N−1; the arbiter sees every claim at once and
decides what actually moves. **Mass, heat and momentum all go through it because they are the
same problem** — claims against a shared limit, settled once, with the remainder staying put.

```ruby
Arbiter.settle(nodes:, states:, paths:, thermal_links:, drive_links:, intents:, content:, dt:, ctx:)
#=> Settlement(flows:, heat:, ambient:, drive:)
```

**Nothing granted is ever created; nothing ungranted is ever destroyed** — it stays where it
was, which is what back-pressure *is*. Nothing in here reads a clock, draws entropy, or
depends on hash order.

## Mass settles over paths, not links

A `Path` runs from one holder's outlet to the next holder's inlet through zero or more
**transport** nodes (`Node#transport?`). Resolved once at construction by `Path.resolve`,
because the graph is configuration rather than state.

> **A conduit may not hold material.** It has to size its intake from N−1, before it knows what
> it will discharge, so the only bounded rule — `draws = throughput − held` — gives `h ↦ T − h`:
> an involution, eigenvalue exactly −1, oscillates forever, cannot damp. Drop the `− held` and
> you get steady flow with an unbounded duct instead. **Steady inventory and steady throughput
> are mutually exclusive for a stateful intermediate node.**
>
> It cost a damper alternating 0.84 / 0.000 kg forever, a firebox with no air at all every
> other tick, a cylinder swinging 16.4/78.2 kW, and every conduit silently delivering about
> half its rating. Do not give `Conduit` `Holds` again — `spec/reactor_sim/transport_spec.rb`
> asserts it.

## `settle_mass` — four stages, each may only reduce a claim

1. **Desired flow per path.** Sink's draw, else source's push, else **the path itself drives
   it** — holders are passive, so nothing would move otherwise. Capped by the narrowest port
   anywhere along the path and by every conduit's `throughput_kg(state, ctx)`.
2. **`scale_by_source_availability`** — competing draws split proportionally to request.
3. **`cap_gas_by_pressure`** — no path delivers more gas than would bring the destination up
   to its source's pressure. **Scheduled for deletion** (see `transport_model.md`): it is the
   relaxation transfer without its time constant, so it equalises instantly where it should
   set a rate.
4. **`scale_by_sink_room`** — volume is the currency, because that is what a vessel runs out of.

Load-bearing, and each was a bug:

- **An active sink is authoritative about its own intake.** This used to be
  `max(push, draw)`, which meant a sink could not refuse — a valve shoving its contents at a
  cylinder overrode the cylinder's limit and packed it to eight times its supply pressure.
- **Gas cannot be limited by volume** — it expands and raises pressure instead. It is a **cap
  only**, never a block, so a chimney cannot deadlock waiting for a pressure difference.
  `Atmosphere` reports `gas_headroom_kg` as `Infinity` and is unaffected.
- **`volume_of` skips gases, and must agree with `Holds#room_m3`.** Fixing one without the
  other made a damper deliver 1.2 kg of air a tick when the grate wanted seven.
- **Material must satisfy *every* port's tag filter along the path**, not just the two ends.

Desired mass is split across the resources present proportionally, so a drawn mixture has the
same composition as what it left behind — unless a part on the path declares a
`transport_affinity`. Energy follows mass exactly, because a node's contents are all at one
temperature.

**Stage 1 forks on the regime, and the two halves obey different rules.** Rate-driven paths go
through `apportion`, where an affinity may only redistribute a fixed throughput. Pressure-driven
paths go through **`entrained`**, where the solve rates the *gas* and condensate rides on top —
so the total is larger than the settled figure, deliberately. Full table in
[`settlement.md`](../../../docs/reference/settlement.md).

- **Liquid is bounded by the bore, gas by the conductance.** Unbounded, the entrainment term
  claimed a whole drum in one tick, and the only backstop scaled the claim uniformly — dragging
  the gas figure below what the solve settled.
- **A path with no declared opinion still passes liquid.** Dropping it there is why the cylinder
  relief valve passed water in exactly zero states: lifted it was pressure-driven with no
  affinity, shut its throughput was zero. `spec/reactor_sim/entrainment_spec.rb` exists because
  none of this was covered.

## `settle_heat` / `settle_drive` / `settle_gas`

All three delegate to `Physics::Relaxation` — heat capacity ↔ moment of inertia ↔ `dn/dP`,
temperature ↔ angular velocity ↔ pressure, same mathematics. See
[`../physics/CLAUDE.md`](../physics/CLAUDE.md).

**It is one implicit solve over the whole network, not a law applied per coupling.** A
pairwise closed form does not compose — three 600 K bodies feeding one small 300 K body drove
it to **1067 K**, energy perfectly conserved and the node simply hotter than anything touching
it — and it cannot express flow *through* a body at all, which is what a firebox is. The
per-node bound that stood in for both is gone, along with `flow_bounds` and `node_headroom`:
they were papering over an explicit integrator running 400–600× past its stability limit, and
the bound was itself wrong by a factor of two.

> **Two vessels joined by a pipe used to swap contents and stay swapped forever.** 6 kg/1 kg
> became 1 kg/6 kg on tick 1 and never moved again, at every conductance stiffer than
> `dt < τ`. The engine survived only because every gas coupling in it has `Atmosphere` on one
> end. `transport_spec` asserts equalisation at five conductances now.

**Conductance is the whole restriction on a pressure-driven path.** `Port#max_kg_per_s`
governs rate-driven paths and nothing else — applying both makes every throat permanently
choked, and a choked coupling carries a fixed flow, which leaves the pressure at either end
with no feedback at all.

**Gas may flow backwards.** `Flow#source_node` / `#sink_node`, never `path.from_node`.
`Conduit#one_way?` is the opt-out for parts that really are check valves.

`settle_ambient` is not arbitrated — a fixed-potential reservoir cannot be overshot.

## Ports and links

```ruby
Port.new(id:, direction: :inlet | :outlet, accepts: [tags], max_kg_per_s:)
Link.new(from: [node_id, port_id], to: [node_id, port_id])
ThermalLink.new(a:, b:, conductance:)          # W/K
DriveLink.new(a:, b:, stiffness:, max_torque:)
```

- `accepts: []` means "anything".
- `max_kg_per_s` is **throughput, never storage.** Conflating those was the original sin of
  the old `Buffer`.
- **Links hold no state, and delay is not configurable.** It is one tick per hop, emergent
  from graph shape. There is no `delay:` parameter anywhere — do not add one. **A hop is one
  `Path`, holder to holder**; conduits are resolved through and cost no tick.
- `Operation#validate_graph!` rejects unknown nodes, links into an outlet, links out of an
  inlet, and thermal links to a non-thermal node, at construction.

## `Node`

A node holds **no mutable state** — it is configuration and behaviour, and all state lives in
the operation's frozen hash and is passed in. This is what makes order-independence
enforceable rather than merely intended. Most node classes `freeze` at the end of
`initialize`. See [`../nodes/CLAUDE.md`](../nodes/CLAUDE.md) to write one.
