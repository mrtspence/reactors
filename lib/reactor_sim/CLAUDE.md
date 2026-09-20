# `lib/reactor_sim` — the simulation

Pure Ruby. This library stands alone: `ruby -Ilib -e 'require "reactor_sim"'` must work, and
`spec/reactor_sim/purity_spec.rb` boots it in a bare subprocess to prove it.

## Hard rules

**Forbidden anywhere under this directory:** `Time.now`, `Time.current`, `Date.today`,
`SecureRandom`, `Random.new`, `Kernel#rand`, `Rails`, `ENV`, `String#hash`.

- Time arrives as `dt` — *simulated* seconds, passed in. Never measured.
- Randomness comes from `ReactorSim::Rng`, seeded, with state stored **inside** match state
  so it snapshots and restores. `String#hash` is randomised per process — use
  `Rng.stream(seed, name)`.
- `content.rb` is the **one** filesystem exception, and only at boot. Nothing else touches
  `File`, `IO`, `Dir` or `YAML`; nothing reads a file during a tick.

**Entropy may only be drawn in three places:** `initial_state`, phase 0 (`actuate`), and
phase 7 (`observe` / `Diagnostic#record`). Anywhere else and projection stops being pure —
how many people happened to be watching would change the match.

**Nothing here is autoloaded.** Add new files to the `require_relative` chain in
`lib/reactor_sim.rb`, in dependency order. That chain is the dependency graph, on purpose.

## Layout, in dependency order

```
physics/      substances, energy bookkeeping, the relaxation solver — no graph awareness
graph/        nodes, ports, links, paths, and the arbiter that settles every claim between them
concerns/     composable state+behaviour fragments a node opts into
nodes/        generic machinery, reusable across operations
diagnostics/  the instrument chain — the only thing that leaves the simulation
operations/   specific machines, assembled from everything above
```

Top-level files: `tick.rb` (the eight phases, in order), `operation.rb` (config, commands,
projection, serialisation), `match.rb` (many operations in lockstep), `content.rb`,
`control_point.rb`, `minion.rb` (who stands at a lever), `command.rb`, `event.rb`, `rng.rb`.

## Events are the other output, and they have one rule

`Event` is what the machine *reported*: a part failing, a fire catching, a drum reaching
working pressure. `Event::TYPES` is the whole vocabulary and it is enumerated, because a
consumer keyed to a type that no longer exists is a feature silently switched off.

> **Nothing that happens every tick may be an event.** A per-tick quantity belongs on the
> `Ledger`, which already accumulates it and is checked by the conservation specs; emitting one
> as an event would cost four records a second per match forever *and* create a second running
> total that can drift from the audited one. Measured on a reference cold start: **5 events over
> 4200 ticks.** If a record's interesting content is a number that changed a little, it is a
> meter reading and the runner samples it.

Two more rules that cost something to learn:

- **The engine reports transitions; the delivery tier composes them into meaning.** A node may
  not know what an achievement is, or every new one becomes a simulation change.
- **Emit on a transition, with hysteresis where the signal is noisy.** `ReliefValve` announced
  itself 20 times in 40 ticks before it had a time-based re-arm, because it senses a
  reconstructed per-stroke pressure that swings through its whole range every tick.
- **Spell the type literally at the `Event.build` call.** `spec/reactor_sim/event_spec.rb`
  finds emitters by scanning for `type: :name`, which is what makes "no type is unreachable" a
  check rather than a hope; a computed type is invisible to it.

Plus the crew layer — `minion.rb` (somebody stood at a lever), `equipment.rb` and `training.rb`
(two small registries), `kit.rb` (their catalogue). A minion's sheet is **four layers, each
offsetting the last**: archetype → individual → training → equipment. The first two are content
(`content/archetypes/`, `content/minions/`) and `Content::Registry#sheet` folds them; the last two
are things a player *owns*, so they are folded at build by the delivery tier and never looked up
here. **Merge adds, use multiplies** — stats and valued tags sum across layers, and whoever reads
them multiplies. Getting that round the wrong way makes every piece of kit a rounding error.

> **An archetype is a kind of person; a minion is a person; a seat is a place on the payroll.**
> What a player unlocks is Jim. `crew.rb` resolves a roster of **seats** — `crew_1`, `crew_2`,
> as many as the fitted crew quarters has `crew_capacity` for — and a seat carries **no
> station**: everybody starts in the quarters and is *sent* somewhere, so deploying the shift is
> the opening move of a match. Jobs are derived, never declared: they are exactly the control
> points with `effort:`. When there are more of those than seats, something is always
> unattended, which is the point.

`injury.rb` is `Concerns::Wearing` for people, and the copied shape is deliberate while the
vocabulary is not: a part has `durability` and a `failure`, a person has `resilience` and an
`injury`. What they genuinely share is `Severity.escalate`, extracted so the one rule that must
not drift between them cannot.

`fatigue.rb` is the other half of what a shift costs, and it is shaped the same way — a pure
module over a state hash, drawing no entropy — but it runs **every tick for everybody posted**
rather than on an event, which is why a station declares `exertion:` and `recovery:` instead of
there being a hazard table. Effort is *subjective*: accrual is `intent ÷ capability`, squared, so
the same lever costs a day-labourer far more than a strong fireman.

> **Two things about it are easy to get wrong and silent.** `endurance` is a **divisor** and
> `Sheet::MIN_STAT` is 0.0, so kit alone could divide by zero — hence `Fatigue::MIN_ENDURANCE`.
> And `capability` contains `(1 - fatigue)`, so accrual has a pole at 1.0 that a severely injured
> minion reaches the instant they are hurt — hence `LOAD_CEILING`. That same feedback makes
> time-to-spent **a third** of what the declared rate suggests; see `docs/reference/tick.md`.
>
> **A spent minion mans nothing**, because capability is then exactly zero and an unmanned effort
> station delivers nothing. Nothing is wired to make the fire go out when a fireman is exhausted;
> it simply does.

> **The Danger Check throws no dice, and that is the design rather than a workaround.**
> `resilience` is rolled ONCE, at `initial_state` — one of the three places entropy is permitted
> — so every check afterwards is a deterministic comparison. Injuries therefore replay exactly,
> survive a snapshot, and need no amendment to the entropy invariant. The uncertainty is the
> hidden threshold, exactly as `durability_range` is for a part.
>
> A hazard's severity **scales with a figure the part reports on its failure event**
> (`scales_with:`/`reference:`), because a small steam escape is not a large one. Reading the
> event rather than the node keeps phase 6b order-independent and puts the magnitude on the
> durable record.

Plus the assembly layer — `part.rb` (`Part` and `Fragment`), `parts.rb` (the registry),
`slot.rb`, `assembly.rb`. **All four are build-time only.** They resolve a chassis and a
loadout into the flat lists `Operation` has always taken, and nothing in them is reachable from
`Tick`, `Arbiter` or any node. Keep it that way: a `Context` method taking a slot id would put
assembly structure on the hot path for a lookup that could have been decided at build.

A `Fragment` carries nodes, links, thermal and drive links, control points — and `diagnostics`,
for the parts that **are** instruments. Everything else names its gauges by id and the
operation's panel holds the definitions; a dial's full-scale reading has nowhere else to live,
because it is a property of the dial rather than of what it is screwed to. Gauge ids are in the
same flat namespace as everything else and collide the same way.

## The tick

`Operation#step!` delegates to `Tick`, which reads the frozen previous state and returns the
next one; the operation installs it atomically. A half-finished tick is never observable.

Full phase table and the orderings that are load-bearing:
[`docs/reference/tick.md`](../../docs/reference/tick.md). The short version of what breaks if
you rearrange:

- **Mass moves before heat** (4a before 4b) — a parcel carries its own energy.
- **Torque is transmitted after node effects** (4e after `apply_nodes`) — a prime mover is
  charged the KE the shaft *measurably* gained, not a first-order prediction.
- **`record_injections` runs after `react`** — combustion releases energy in phase 5.
  Ledgering earlier missed ~1.8 MJ/tick.
- **`observe` runs last** — instruments must see the settled tick.

## Serialisation traps

- **Symbols as *values* do not survive JSON.** `deep_symbolize` converts keys only. Resource
  ids inside parcels, flags inside instrument state, a minion's `station`, a loadout's part
  ids, **a node's `failure` mode**, **every field of an `Event`**, and now **every id in a
  roster** (who is filling a job, what they have been trained in, what is in each of their three
  equipment slots) all broke this way. `Crew.normalise` handles the roster, at the single point
  where `options:` is resolved — the same shape as `Assembly#resolve_loadout`, and for the same
  reason.
  The sixth instance is the worst placed: an event crosses into Kafka, into Postgres `jsonb`,
  and out to a consumer — three boundaries, **none of which is `Operation#restore`**, which is
  the single choke point the other five are fixed at. A consumer matching `event[:type] ==
  :part_failed` against a string matches nothing, silently, and the symptom is an achievement
  that never fires — indistinguishable from one nobody has earned. Consumers normalise once on
  the way in; `Achievement`'s definitions are written with String values for the same reason. `Operation#restore` normalises
  all but the loadout, which `Assembly#resolve_loadout` handles — if you add state holding
  symbols as values, normalise it there too. Two of the five are worse than a nil: a part id
  that misses is a **different machine**, rebuilt in silence, and a failure mode that misses
  leaves the part broken in a mode nothing matches, so every consequence keyed to it goes
  quiet while `broken?` still reads true.
  **The digest cannot catch this**: `canonical` runs through `JSON.generate`, where `:stoking`
  and `"stoking"` are the same string, so a round-trip spec passes with the bug present. Only
  an identity assertion (`be(:stoking)`, never `eq`) finds it.
- **A sparse hash cannot express a removal by diffing.** `PlayerView#flags` omits instruments
  with nothing to say, so rejecting unchanged entries never mentioned a flag that *cleared*.
  `delta_from` emits an explicit empty list instead.
- **Ids are one flat namespace** across nodes, control points, diagnostics and minions,
  because they key one RNG table. `validate_graph!` refuses duplicates — a collision would
  hand two components the same stream, silently and through a snapshot.
- **Builder options that change the graph's shape must be in `options:`**, or a restored
  snapshot rebuilds a different machine. Silent, total divergence.

## Style

Comments here record the bug that produced the rule, and `Metrics/*` cops are deliberately
off because the ordering in `Arbiter#settle_mass` and `Tick#call` is the thing a reader most
needs to see in one place. Keep both conventions.
