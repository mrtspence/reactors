# The tick

One advance of one operation. Implemented in `lib/reactor_sim/tick.rb`; `Operation#step!`
delegates to it and installs the result atomically.

```ruby
@state = Tick.new(self, @state).call(tick:, dt:)
```

`dt` is **simulated** seconds — `ReactorSim::DT (0.25) × operation.time_scale`. Wall-clock is
always 4 Hz; `time_scale` is how fast the world runs relative to that, per operation. A steam
engine uses 1.0; an operation running alone may use much more.

> **Coupled operations must share a `time_scale`**, and `Match#validate_couplings!` refuses to
> build a match where they do not. Work crossing between operations is energy, and energy per
> *tick* means nothing unless both sides agree what a tick is worth: at 40× an operation lives 10
> simulated seconds per tick against 0.25 at 1.0, so it would need forty times the joules to run
> the same machines and would be starved in exactly that proportion — while the supplier's own
> instruments read correct throughout. Scaling the transfer to compensate would mint energy. Two
> operations joined by a shaft are in the same world at the same time.

---

## The eight phases

| # | Phase | What it does | May draw entropy? |
|---|---|---|---|
| 0 | `draw_fates` → `actuate` | **Every die thrown for a person this tick**, then levers travelling toward their targets at the rate their minion can manage — and not always to the lever they were aimed at, because somebody out of their depth at a tricky post freezes, pulls it backwards, or grabs a different one in the same room | **yes** |
| 1 | read | Freeze tick N−1, build the `Context` every node sees. `ctx.controls` is not the lever positions: an **effort** station's value is its position scaled by what the person posted there can manage, gates included — and a gate may be met by the **room** as well as by the person, which is `Tick#ambient_tags` (light on the roadway against a lamp on a belt; the better of the two, never the sum) | no |
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
| 6b | `endanger` | What a failure does to the **people** near it: a Danger Check per minion, against both the **place** they are standing in and the station they are posted to. Severity adds where both reach them | no |
| 6b′ | `scorch` | What the **heat** of the room does to the people in it: resilience ground away at a rate set by the gas's volumetric heat capacity and how far it is past what that person tolerates. The gas phase only — you stand beside water, not in it — and a threshold rather than a multiplier, so below somebody's rating it costs exactly nothing | no |
| 6c | `tire` | What the **work** does to the people doing it, and what the **air** does to them: fatigue accrues on `intent ÷ capability`, recovery and suffocation net against it. Pinned at the ceiling in bad air is the collapse, and the clock from there to a mortal injury runs here | no |
| 6d | `blunder` | **What the people do to themselves**, which is the route into harm that needs nothing to break first. A hidden `margin` of safety, spent by the **perils of the place** in proportion to how hard it is being worked, and mended only where no peril reaches at all — a lull between tubs is not recovery. Crossing zero is an accident, and the peril that fires is whichever took most of it; `safety_equipment` fitted in that place may turn it into a `:minion_near_miss` instead | no |
| 6e | `travel` | Where the people have got to, in **two passes**. One: everybody who can walk moves toward the place their `posting` is worked, at their own `pace` less whatever they are carrying, by the **quickest passage that is actually running**. Two: anybody being carried is *stowed* — their place written from their carrier's, their station and posting cleared. Also keeps `remaining` and `journey`, which are how far there is left to go and how far there was to go at the farthest point of this walk — a panel divides them for a progress bar. A posting may name **a person** rather than a lever, which is a fetch order and becomes a pickup on arrival. A no-op in an operation that declares no passages | no |
| 7 | `observe` | Instruments sample; their filters advance. An instrument that names an `observer:` is **somebody's word**: it reads through whoever is posted at that station and goes `:offline` when nobody is | **yes** |
| 8 | publish | Freeze the new state, return this tick's events | no |

Entropy is confined to phases 0 and 7 (plus `initial_state`). That is what makes projection
pure — see [`invariants.md`](invariants.md#2-determinism).

**Phase 6b draws no entropy, and that is why it can sit here at all.** A minion's `resilience` is
rolled once at `initial_state`, so the Danger Check is a deterministic comparison rather than a
throw — which keeps injuries replayable and needed no amendment to the rule above. It runs after
all wear is settled, never inside it, so two parts failing on the same tick hurt the same people
whatever order they were visited in. It reads the failure events rather than the nodes, which is
also what lets a hazard's severity scale with how big the event actually was.

**Phase 6b′ grinds `resilience` directly rather than draining a pool of its own**, because heat
is not tiredness and does not recover by standing somewhere cooler for a minute. It is beside
`endanger` rather than inside it because the two are different shapes: a hazard is a blow
delivered by a part that failed, and heat is a condition of the room that keeps working for as
long as somebody is in it.

> **A steady harm needs a dwell to be able to kill.** Grinding resilience to zero proposes
> `:severe`, every bite after proposes `:severe` again, and `Severity.escalate` rightly refuses
> to announce the same injury twice — so nothing ever reaches `:mortal` without a bite of
> `Injury::MORTAL_BITE`, which no steady hazard grows. `Breath` counts `asphyxia` past the
> collapse and `Scorch` counts `burns`, both for this reason. Anything added here that harms
> continuously owes the same counter, or it produces a minion who is permanently stood down in
> a furnace and never dies.

**Phase 6c draws no entropy either, and it runs after 6b rather than at phase 0** — which is where
a long-standing `TODO` said it belonged. Three reasons: the effort actually demanded this tick is
settled at phase 1, so phase 0 would charge people for last tick's levers; `endanger` already
writes `minions`, and a second writer would need a merge rule between them; and a minion carried
out in 6b has `station: nil` on **this** tick and must stop working on this tick, not the next.
The TODO's premise — that accrual would sit alongside the actuation entropy it draws — was simply
wrong, because it draws none.

**Phase 6d grinds the accident margin, and it runs after `tire` so it reads this tick's fatigue
rather than last tick's.** The usual rule that everything must read the frozen N−1 constrains what
*nodes* may see of each other; a minion's fatigue and their margin are one object being advanced
twice in a fixed order. Running after `endanger` matters too: somebody already carried out by an
exploding boiler this tick has no station before their own margin is weighed.

**Phase 6e runs last of the five and reads no controls at all.** Who is standing where is built in
phase 0 from the *previous* tick (`station_index`, `control_values`), so a minion who arrives in 6e
takes up their post on the **next** tick — the same one-hop delay everything else in the engine
has, and what keeps arrival from depending on phase order. It runs after `tire` so a minion carried
out in 6b has already had their posting cancelled and does not get up and resume the walk.

> **Geometry is opt-in, and that is what kept this from touching anything.** An operation that
> declares no `passages:` has an empty `Layout`, `travel` returns immediately, and `assign_minion`
> sets `station` the moment the command lands exactly as it always did. The steam engine did not
> acquire a walk to the firehole.

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
so a lever with a finite `stiffness` moves at `stiffness × rate_multiplier × dt`, where
`stiffness` is percent of the lever's range per second. The mine's valves ship finite figures —
the fan is forty seconds hard over — and everything else keeps the default `Float::INFINITY`,
which snaps `actual` to `target` and discards the multiplier before it is read.

**An unattended lever travels at its rated speed**, deliberately: surface plant is the overseer's
own, and a colliery's fan, pump and winder are at bank where nobody is normally posted. Posting
somebody makes a lever faster or slower than rated, never possible at all.

**Effort stations stay frictionless on purpose.** There the lever is intent and `capability`
already supplies the rate, so a finite travel would charge the same minion twice.

**`control_values` — what comes of the lever.** This is the live path, and it is not phase 0: it
runs wherever a control becomes the number a node reads.

```ruby
control.effort? ? worked(control, s) : control.value(s)
```

A control declares itself an **effort station** with a weighted stat blend, and what the node
reads is then `lever × capability`, where capability is the blend × kit × condition:

```ruby
ControlPoint.new(id: :stoking, effort: { swing: 0.75, dexterity: 0.25 }, aided_by: :shovelling)
```

**A blend may name the six stats and two derived quantities.** `strength` is a strength-to-weight
*ratio*, so a job that wants absolute output asks for `force` (`strength × mass ÷ 70`) or for
`swing` (`√force`, where a tool caps what bulk buys). All three are 1.0 for a reference human, so
every weight set still sums to 1.0 against the same baseline.

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
