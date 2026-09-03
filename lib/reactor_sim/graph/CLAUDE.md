# `graph/` — nodes, ports, links, and the arbiter

The structure a node plugs into, plus the settlement that makes order-independence possible.
Reference: [`docs/reference/settlement.md`](../../../docs/reference/settlement.md) and
[`docs/reference/nodes.md`](../../../docs/reference/nodes.md).

## The arbiter is why evaluation order cannot matter

Nodes declare what they *want* against tick N−1; the arbiter sees every claim at once and
decides what actually moves. **Mass, heat and momentum all go through it because they are the
same problem** — claims against a shared limit, settled once, with the remainder staying put.

```ruby
Arbiter.settle(nodes:, states:, links:, thermal_links:, drive_links:, intents:, content:, dt:)
#=> Settlement(flows:, heat:, ambient:, drive:)
```

**Nothing granted is ever created; nothing ungranted is ever destroyed** — it stays where it
was, which is what back-pressure *is*. Nothing in here reads a clock, draws entropy, or
depends on hash order.

## `settle_mass` — four stages, each may only reduce a claim

1. **Desired flow per link.** `sink_declared_a_draw? ? sink.draw(port) : source.push(port)`,
   capped by both ports' `capacity_kg(dt)`.
2. **`scale_by_source_availability`** — competing draws split proportionally to request.
3. **`cap_gas_by_pressure`** — no link delivers more gas than would bring the destination up
   to its source's pressure.
4. **`scale_by_sink_room`** — volume is the currency, because that is what a vessel runs out of.

Four things here are load-bearing and each was a bug:

- **An active sink is authoritative about its own intake.** This used to be
  `max(push, draw)`, which meant a sink could not refuse — a valve shoving its contents at a
  cylinder overrode the cylinder's limit and packed it to eight times its supply pressure.
  A passive tank declares nothing and still accepts what arrives, which is what makes
  pump-into-tank work.
- **Gas cannot be limited by volume** — it expands and raises pressure instead. Without the
  cap a small vessel ends up at higher pressure than the thing feeding it. It is a **cap
  only**, never a block, so a chimney cannot deadlock waiting for a pressure difference.
  `Atmosphere` and `Conduit` report `gas_headroom_kg` as `Infinity` and are unaffected.
- **`volume_of` skips gases, and must agree with `Holds#room_m3`.** Fixing one without the
  other made a damper deliver 1.2 kg of air a tick when the grate wanted seven.
- **Material must satisfy *both* ports' tag filters.** A gas outlet wired to a liquid inlet
  moves nothing. That is a wiring mistake the graph is allowed to make.

Desired mass is split across the resources present proportionally, so a drawn mixture has the
same composition as what it left behind. Energy follows mass exactly, because a node's
contents are all at one temperature.

## `settle_heat` / `settle_drive`

Both delegate to `Physics::Relaxation` — heat capacity ↔ moment of inertia, temperature ↔
angular velocity, same mathematics. See [`../physics/CLAUDE.md`](../physics/CLAUDE.md).

**The per-node bound is not optional.** Pairwise closed form alone is not enough in a network:
each link independently moves most of the way to *its own* two-body equilibrium and the
contributions stack. Three 600 K bodies feeding one small 300 K body drove it to **1067 K** —
energy perfectly conserved, the node simply hotter than anything touching it. Totals are
capped at the conductance-weighted mean of a node's own neighbours; the rest stays with the
sender.

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
  from graph shape. There is no `delay:` parameter anywhere — do not add one.
- `Operation#validate_graph!` rejects unknown nodes, links into an outlet, links out of an
  inlet, and thermal links to a non-thermal node, at construction.

## `Node`

A node holds **no mutable state** — it is configuration and behaviour, and all state lives in
the operation's frozen hash and is passed in. This is what makes order-independence
enforceable rather than merely intended. Most node classes `freeze` at the end of
`initialize`. See [`../nodes/CLAUDE.md`](../nodes/CLAUDE.md) to write one.
