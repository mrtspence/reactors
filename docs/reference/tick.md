# The tick

One advance of one operation. Implemented in `lib/reactor_sim/tick.rb`; `Operation#step!`
delegates to it and installs the result atomically.

```ruby
@state = Tick.new(self, @state).call(tick:, dt:)
```

`dt` is **simulated** seconds — `ReactorSim::DT (0.25) × operation.time_scale`. Wall-clock is
always 4 Hz; `time_scale` is how fast the world runs relative to that, per operation. A steam
engine uses 1.0; a mine would use much more.

---

## The eight phases

| # | Phase | What it does | May draw entropy? |
|---|---|---|---|
| 0 | `actuate` | Levers travel toward their targets | **yes** |
| 1 | read | Freeze tick N−1, build the `Context` every node sees | no |
| 2 | `plan` | Every node declares intent, independently, against N−1 | no |
| 3 | settle | One pure function over every claim — mass, heat, momentum | no |
| 4a | `advect` | Granted parcels move, carrying their energy | no |
| 4b | `conduct` | Granted heat moves across thermal links | no |
| 4c | `shed_to_ambient` | Waste heat leaves for the environment → ledger | no |
| 4d | `drive` | Angular momentum crosses the drivetrain; friction → ledger | no |
| 4e | `apply_nodes` → `transmit_torque` | Node-specific effects, then prime movers pay for their torque | no |
| 5 | `react` | Phase change and chemistry, local to each node | no |
| — | `record_injections` | Everything injected or extracted goes on the ledger | no |
| 6 | `stress` | Durability, overload, failure events | no |
| 7 | `observe` | Instruments sample; their filters advance | **yes** |
| 8 | publish | Freeze the new state, return this tick's events | no |

Entropy is confined to phases 0 and 7 (plus `initial_state`). That is what makes projection
pure — see [`invariants.md`](invariants.md#2-determinism).

---

## Orderings that are load-bearing

These are the parts most likely to be broken by a well-meaning rearrangement.

**Mass moves before heat (4a before 4b).** A parcel carries its own energy, so advection must
happen first or a parcel's energy arrives without it.

**Torque is transmitted after node effects (4e after `apply_nodes`).** A prime mover computes
its torque in `apply`; `transmit_torque` then applies that impulse to the driven shaft,
measures the kinetic energy the shaft *actually* gained, and charges the mover exactly that.

> Why measured rather than predicted: a shaft's KE gain from an impulse is `ω·ΔL + ΔL²/2I`.
> Billing the first-order `torque × ω × dt` alone manufactures the second term. Invisible at
> small timesteps, very visible at large `time_scale`.

**`record_injections` runs after `react` (phase 5).** Combustion releases energy in phase 5.
Ledgering before that would miss it entirely — this was a real bug worth ~1.8 MJ/tick.

**`observe` runs last (phase 7).** Instruments must see the settled tick, not a partial one.

---

## The Context

What a node is allowed to see. Built once in phase 1 and passed to every `plan` and `apply`.

```ruby
Tick::Context = Struct.new(:controls, :dt, :tick, :content, :nodes, :states)
```

| Member | What it is |
|---|---|
| `controls` | `{ control_id => actual_value }` — the lever's **actual** position, not its target |
| `dt` | simulated seconds this tick |
| `tick` | tick number |
| `content` | the frozen `Content::Registry` |
| `nodes` / `states` | the **previous tick's** nodes and frozen states |

Helpers over previous-tick state, all returning `nil` when the node cannot answer:

```ruby
ctx.node_pressure(:boiler)    # Pa
ctx.node_omega(:flywheel)     # rad/s
ctx.node_temperature(:firebox)# K
ctx.node_state(:supply)       # the raw frozen state hash
```

Note `Operation::Context` is an alias for `Tick::Context`; both names work.

---

## What a node does NOT have to do

The engine handles all of this generically. A node that re-implements any of it is a bug:

- **Parcel bookkeeping.** By the time `apply` runs, granted parcels have already been removed
  from senders and added to receivers, and every node rebalanced to one temperature.
- **Heat transfer, ambient loss, friction.** Driven by concerns and links.
- **Phase change and reactions.** Driven by content and the node's `reactions` list.
- **Wear and failure.** Driven by `Concerns::Wearing`.
- **Observation.** Driven by the operation's diagnostics.

A node author writes `plan` and `apply`. See [`nodes.md`](nodes.md).
