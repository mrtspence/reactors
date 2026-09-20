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
| 4d | `drive` | Angular momentum crosses the drivetrain, drag included; work → `joules_extracted`, the rest → ledger | no |
| 4e | `apply_nodes` → `transmit_torque` | Node-specific effects, then prime movers pay for their torque | no |
| 5 | `react` | Ignition spreads, then chemistry (scaled by the node's `reaction_throttle`), then phase change — local to each node | no |
| — | `record_injections` | Everything injected or extracted goes on the ledger | no |
| 6 | `stress` | Durability, overload, failure events | no |
| 6b | `endanger` | What a failure does to the **people** near it: a Danger Check per minion, against the station they are standing at | no |
| 6c | `tire` | What the **work** does to the people doing it: fatigue accrues on `intent ÷ capability`, recovery nets against it | no |
| 7 | `observe` | Instruments sample; their filters advance | **yes** |
| 8 | publish | Freeze the new state, return this tick's events | no |

Entropy is confined to phases 0 and 7 (plus `initial_state`). That is what makes projection
pure — see [`invariants.md`](invariants.md#2-determinism).

**Phase 6b draws no entropy, and that is why it can sit here at all.** A minion's `resilience` is
rolled once at `initial_state`, so the Danger Check is a deterministic comparison rather than a
throw — which keeps injuries replayable and needed no amendment to the rule above. It runs after
all wear is settled, never inside it, so two parts failing on the same tick hurt the same people
whatever order they were visited in. It reads the failure events rather than the nodes, which is
also what lets a hazard's severity scale with how big the event actually was.

**Phase 6c draws no entropy either, and it runs after 6b rather than at phase 0** — which is where
a long-standing `TODO` said it belonged. Three reasons: the effort actually demanded this tick is
settled at phase 1, so phase 0 would charge people for last tick's levers; `endanger` already
writes `minions`, and a second writer would need a merge rule between them; and a minion carried
out in 6b has `station: nil` on **this** tick and must stop working on this tick, not the next.
The TODO's premise — that accrual would sit alongside the actuation entropy it draws — was simply
wrong, because it draws none.

> **Fatigue is a runaway, and it has a closed form.** `capability` contains `(1 - fatigue)`, so
> tiring raises the load, which tires faster. Integrating `(1-f)²df = K dt` gives
> `t = (1 - (1-f)³)/3K`, so **time-to-spent is a third of what a flat rate would give, at every
> load** — an `exertion:` reciprocal is a nominal figure. `Fatigue::LOAD_CEILING` bounds the pole
> at `fatigue` 1.0, which a severely injured minion reaches the moment they are hurt.

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

## The crew is consulted twice, and the second one is the one that matters

`Tick#station_index` maps station → minion from **state**, not configuration, because a minion
who has been reassigned is at the post their state names. It is read in two different places.

> **Every seat starts in the crew quarters, so a machine nobody deploys does nothing at all.**
> Measured on the steam engine: 322.8 K and 0 kW undeployed against 1022.0 K and 495.5 kW with
> one hand on the shovel. Nothing implements that — an unmanned effort station already delivered
> zero — but it means a spec that runs a machine has to post somebody first.

**Phase 0 — how fast a lever travels.** `actuate` takes `rate_multiplier: crew_multiplier(id)`,
so a lever with a finite `stiffness` moves at `stiffness × rate_multiplier × dt`. Every shipped
control keeps the default `Float::INFINITY`, which snaps `actual` to `target` and discards the
multiplier before it is read — so **this path is currently inert on every machine**, and is kept
for a lever that should genuinely take time to travel.

**`control_values` — what comes of the lever.** This is the live path, and it is not phase 0: it
runs wherever a control becomes the number a node reads.

```ruby
control.effort? ? worked(control, s) : control.value(s)
```

A control declares itself an **effort station** with a weighted stat blend, and what the node
reads is then `lever × capability`, where capability is the blend × kit × condition:

```ruby
ControlPoint.new(id: :stoking, effort: { strength: 0.75, dexterity: 0.25 }, aided_by: :shovelling)
```

> **The lever is the player's intent; the crew supplies the rate.** An earlier design gave weak
> minions a finite `stiffness` instead, which models the *derivative* — a kobold would take longer
> to reach the setting and then deliver exactly as much as an ogre. Who can actually do the work
> is the comparison the game is about, and stiffness could not express it. See
> [`design_sketches/minions.md`](../design_sketches/minions.md) §9.

Weights must sum to 1.0, enforced, because that is what keeps *a fit unaided human scores 1.0*
true at every station — and therefore what lets a node's declared throughput mean "what a
competent person achieves". There is deliberately **no clamp**: the stoker's `0.25 kg/s` is a
person rather than a firehole, so somebody exceptional exceeds it.

**An unmanned effort station delivers nothing** — an unmanned shovel moves no coal. It applies
only to the controls that are somebody's work; a valve needs nobody. A minion carried out has
`station: nil` and therefore mans nothing, which falls out rather than needing a case.

Remaining shortcuts, marked `TODO` at the code:

- Two minions at one station is **last writer wins**.

### The state hash must name it

`Tick#call`'s phase-8 return **is** the next state, so a key it does not name is silently
dropped. `minions:` carries whatever 6b and 6c settled for exactly that reason — omitting the
line deletes the crew on tick 1 and raises on tick 2.

A minion's state is `health`, `fatigue`, `spent`, `station`, `resilience`,
`initial_resilience` and `injury`. **Only `station` and `injury` are Symbols held as values**, so
only those two need normalising on restore; `spent` is a boolean and `fatigue` a Float, and both
round-trip through JSON unchanged.

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
