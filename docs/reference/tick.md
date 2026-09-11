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
| 0 | `actuate` | Levers travel toward their targets, at the rate their minion can manage | **yes** |
| 1 | read | Freeze tick N−1, build the `Context` every node sees | no |
| 2 | `plan` | Every node declares intent, independently, against N−1 | no |
| 3 | settle | One pure function over every claim — mass, heat, momentum | no |
| 4a | `advect` | Granted parcels cross a whole **path**, carrying their energy. Returns what was *delivered* per inlet, which is what the walls left of it | no |
| 4b | `conduct` | Granted heat moves across thermal links | no |
| 4c | `shed_to_ambient` | Waste heat leaves for the environment → ledger | no |
| 4d | `drive` | Angular momentum crosses the drivetrain; friction → ledger | no |
| 4e | `apply_nodes` → `transmit_torque` | Node-specific effects, then prime movers pay for their torque | no |
| 5 | `react` | Ignition spreads, then chemistry (scaled by the node's `reaction_throttle`), then phase change — local to each node | no |
| — | `record_injections` | Everything injected or extracted goes on the ledger | no |
| 6 | `stress` | Durability, overload, failure events | no |
| 7 | `observe` | Instruments sample; their filters advance | **yes** |
| 8 | publish | Freeze the new state, return this tick's events | no |

Entropy is confined to phases 0 and 7 (plus `initial_state`). That is what makes projection
pure — see [`invariants.md`](invariants.md#2-determinism).

---

## Orderings that are load-bearing

These are the parts most likely to be broken by a well-meaning rearrangement.

**A choked node reacts on a shorter second.** `run_reactions` scales `dt` by
`Node#reaction_throttle` (1.0 unless a node says otherwise), which is how a grate banked with
its own ash smothers its fire: the air can no longer reach the fuel. Applied to `dt` rather than
to the finished extent **on purpose** — the closed form stays a closed form and stays exact, and
scaling the extent would charge a fire for its draught twice, which is the mistake
`Resources::Ignition` records having made with the lit-mass term.

**Mass moves before heat (4a before 4b).** A parcel carries its own energy, so advection must
happen first or a parcel's energy arrives without it.

**Material crosses a whole path in one tick.** Settlement resolves from one node that *holds*
material to the next, straight through any conduits between them, so a valve or a length of
pipe adds no delay. `Tick#carry_through` then mixes the stream with each conduit's wall to a
single temperature on the way past — that is what keeps a chimney cooling its flue gas and
lets a hot line still rupture, now that nothing lingers in one. See
[`settlement.md`](settlement.md#mass-settles-over-paths-not-links) for why a conduit may not
hold material.

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

## Phase 0 consults the crew

A control point travels at `stiffness × rate_multiplier × dt`, and the multiplier comes from
whichever minion is stood at that lever:

```ruby
control_points.fetch(id).actuate(cp_state, dt:, rate_multiplier: crew_multiplier(id))
```

`Tick#station_index` maps station → minion from **state**, not configuration, because a minion
who has been reassigned is at the post their state names.

A lever with `stiffness: Float::INFINITY` — the default, and what every steam engine lever
uses — snaps `actual` to `target` and discards the multiplier before it is read. So a crew is
inert until a control point is given a finite stiffness. That is deliberate: it is what let a
crew be added to the steam engine without re-measuring its skill gradient.

Current shortcuts, all marked `TODO` at the code:

- An **unmanned** lever moves at full rate rather than not at all.
- Two minions at one station is **last writer wins**.
- Nothing advances `fatigue` or `health`, so a minion never tires. Accrual belongs here in
  phase 0, where actuation entropy is already permitted.

### The state hash must name it

`Tick#call`'s phase-8 return **is** the next state, so a key it does not name is silently
dropped. `minions:` is passed through untouched for exactly that reason — omitting the line
deletes the crew on tick 1 and raises on tick 2.

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
