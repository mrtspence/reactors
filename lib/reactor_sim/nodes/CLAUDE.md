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

grant.received_at(:inlet)   # parcels that arrived
grant.sent_kg(:outlet)
grant.rejected_kg(:outlet)  # what could not be pushed — back-pressure
grant.blocked?
```

Optional hooks: `reactions` (ids this node hosts), `broken?(state)`, `stress_per_second`,
`overload?`.

## What the engine already did for you

By the time `apply` runs, **parcel bookkeeping is done**: granted parcels removed from
senders, added to receivers, every node rebalanced to one temperature. Heat transfer, ambient
loss, friction, phase change, reactions, wear and observation are all driven generically.

**A node that re-implements any of that is a bug.** `apply` is only for what makes this node
*this* node — a heater, a brake, a torque source.

## Active vs passive is the key distinction

**Vessels are passive; conduits are active.** A link's flow is set by whichever end actively
drives it — valves and pumps move fluid, tanks do not. Every link having exactly one active
end is what keeps settlement unambiguous. If you write a node that both holds and moves
material, decide which it is.

## Two behaviours to copy, not reinvent

- **A conduit draws only what it can discharge** (`throughput − contents`). A conduit that
  draws regardless becomes an infinite sink, draining its source every tick and holding it at
  nothing, so whatever it feeds never receives anything.
- **A conduit reports `gas_headroom_kg` as `Infinity`.** A duct is limited by flow rate, not
  containment. Pressure-capping a pipe by its own volume throttles it to about a kilogram of
  gas per cubic metre.

## The stock nodes

A snapshot — `ls lib/reactor_sim/nodes/*.rb` is the truth. **Adding or removing one means
updating this table and [`docs/reference/nodes.md`](../../../docs/reference/nodes.md) in the
same commit.**

| Node | Concerns | What it is |
|---|---|---|
| `Vessel` | Thermal, Holds, Wearing, Pressurized | Tank, vat, drum, pressure vessel. **Passive** — declares no intent. Optional heater and `reactions:`. |
| `Conduit` | Thermal, Holds, Wearing, Pressurized | Pipe or valve. **Active** — draws and pushes. Optional `control_id`. |
| `Atmosphere` | Thermal, Holds | The outside world: unlimited source and sink, fixed pressure reference. |
| `Flywheel` | Rotating, Wearing | Any heavy spinning mass. Bursts on overspeed. `material:` from content. |
| `Load` | Rotating | Where useful work leaves the operation. |
| `Cylinder` | Thermal, Holds, Pressurized, Wearing | Gas pressure difference → shaft torque. Working fluid is configuration. |
| `ReliefValve` | (a `Conduit`) | Opens itself above a sensed pressure. |

Reach for these first. Write a new node only when the behaviour genuinely does not exist.

## Reading another node

Safe via `ctx.node_pressure(id)`, `ctx.node_omega(id)`, `ctx.node_temperature(id)`,
`ctx.node_state(id)` — all read the **previous tick**, which is settled and identical for
everyone. All return `nil` when the node cannot answer.

**Declare the relationship in config so it stays visible**: `Cylinder` has `drives:`,
`exhausts_to:`, `supplied_by:`; `ReliefValve` has `senses:`. Reaching for an id that is not
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
