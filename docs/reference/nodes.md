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
grant.received_at(:inlet)  # parcels that arrived
grant.sent_kg(:outlet)
grant.rejected_kg(:outlet) # what could not be pushed — back-pressure
grant.blocked?
```

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
  graph shape. There is no `delay:` parameter anywhere.
- `Operation` validates wiring at construction: unknown nodes, and links running into an
  outlet or out of an inlet, raise immediately.

---

## The stock nodes

All generic and reusable. Anything genuinely specific to one machine belongs under
`operations/<name>/`.

| Node | Concerns | What it is |
|---|---|---|
| `Vessel` | Thermal, Holds, Wearing, Pressurized | A tank, vat, drum or pressure vessel. **Passive** — declares no intent. Optional heater and `reactions:`. |
| `Conduit` | Thermal, Holds, Wearing, Pressurized | A pipe or valve. **Active** — draws and pushes. Optional `control_id`. |
| `Atmosphere` | Thermal, Holds | The outside world: unlimited source, unlimited sink, fixed pressure reference. |
| `Flywheel` | Rotating, Wearing | Any heavy spinning mass. Bursts on overspeed. `material:` from content. |
| `Load` | Rotating | Where useful work leaves the operation. |
| `Cylinder` | Thermal, Holds, Pressurized, Wearing | Gas pressure difference → shaft torque. Working fluid is configuration. |
| `ReliefValve` | (a `Conduit`) | Opens itself above a sensed pressure. |

### Active vs passive is the key distinction

**Vessels are passive; conduits are active.** A link's flow is set by whichever end is
actively driving it — valves and pumps move fluid, tanks do not. This means every link has
exactly one active end, which is what keeps settlement unambiguous.

If you write a node that both holds and moves material, decide which it is.

### Two behaviours to copy, not reinvent

**A conduit draws only what it can discharge:** `throughput − contents`. A conduit that draws
regardless becomes an infinite sink, draining its source every tick and holding it at
nothing.

**A conduit reports `gas_headroom_kg` as `Infinity`.** A duct is limited by flow rate, not
containment. Pressure-capping a pipe by its own volume throttles it to about a kilogram of
gas per cubic metre.

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
