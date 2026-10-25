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
`control_point.rb`, `minion.rb` (who stands at a lever), `command.rb`, `event.rb`, `rng.rb`,
and `conditions.rb` — the sky a match is played under: kinds of condition (the weather, the light)
that draw once from the outdoors node's **match-wide** stream at `initial_state` and are read as a
pure function of the clock, through a fixed set of channels a later kind reuses. No die is thrown
after the start. See [`design_sketches/conditions.md`](../../docs/design_sketches/conditions.md).

What a person is subject to lives in eight pure modules over a state hash they do not own,
none of which draws entropy: `injury.rb` (a blow), `fatigue.rb` (the work), `breath.rb` (the
air), `scorch.rb` (the heat), `chill.rb` (the cold, and the strain of working in heat),
`peril.rb` (the place, and the hidden margin it spends), `burden.rb` (what they are carrying) and
`animosity.rb` (each other). **What any of them leaves is wounds** (`wounds.rb`): a harm declares
the kinds it deals as shares of its severity and its causes, each kind is bitten separately, and
each bite past the first band leaves a named wound out of `content/wounds/`. Wounds stack, derate
the stats they name, and outlive the match, healing between them; every bite also comes off
`resilience`, which collapses somebody at empty. **Only grave harm kills by attrition** — the
continuous harms and acute bites of the severe band or worse, counted in `grave` — so no pile of
knocks finishes anybody, and a run of stab wounds does. **One bite of `OUTRIGHT` times their
toughness kills outright** however much is left, which is the only route to death a person's own
build moves. `injury` is the
condition all that comes to, derived. **A harm that works continuously deepens one standing wound
of its kind** — heat, cold, bad air — rather than adding one a tick, from a running `dose`, and
owes a dwell counter past collapse (`asphyxia`, `burns`, `chilled`) to reach `:mortal`.

> **A burden is gear and people, and the arithmetic cannot tell them apart.** `mass_kg` is the
> body; `worn_kg` is what is hanging off it; a carried person contributes both of theirs. Keeping
> the two apart is load-bearing — fold equipment into the body and gear makes you *better* at
> carrying somebody. **Strength decides what you can lift and the mass ratio decides how much it
> slows you**, which is why a kobold is refused an ogre outright while the same kit costs a kobold
> three times the pace it costs a human.
>
> **Carrying a person is the only burden that stops you resting.** `Fatigue.recovery` returns
> zero while `carrying` is non-empty, because accrual and recovery *net*: a light casualty
> produces a small accrual that `BASE_RECOVERY` still beats, so without the gate carrying a
> kobold out reads as a rest. Measured — a kobold on a half-tired human over a minute is +0.064
> fatigue with the gate and **−0.068 without it**. Armour you can rest off; a body you cannot.

> **Every die thrown for a person is thrown in phase 0, unconditionally for everybody** — in
> `Tick#draw_fates` from their own stream, in `Tick#draw_tempers` from a second stream of
> their own (`Animosity.stream`), and in `Tick#draw_wounds` from a third (`Injury.stream`), so
> none moves another. A conditional draw makes
> the RNG stream depend on the condition and the divergence surfaces as a snapshot replaying
> differently, days later, somewhere unrelated. Keeping the count fixed and in one method per
> stream is what makes it checkable — see
> [`invariants.md`](../../docs/reference/invariants.md#2-determinism).

> **What people do to each other is `animosity.rb`, and its phase is `provoke.rb` (6d′).** A
> grudge runs holder → target and comes from the race, the individual (`grudges:`, and
> `resented_by:` written from the target's side), earlier matches (`options[:grudges]`, from the
> delivery tier) and this one (the holder's state), added and clamped — `Operation#grudges` is the
> built table. A hidden `patience`, `Blunder`'s margin with a target, runs out into a row, a brawl,
> a shove into a peril declared `opportunity: true`, or sabotage through a post's `openings:`
> (`Animosity::Opening`: a mishap through `state[:mishaps]`, or a slip of their own through
> `state[:spite]`). A post with `oversees:` is a boss's. **Shoves and sabotage are all or
> nothing; blows are graded** by how far `strike` beat `defend`, and hit by `attack` — the
> contest itself (a bell-curved roll, landing, damage, a critical that `pierces:` the armour and
> part of the toughness) is `combat.rb`, pure arithmetic any future fight reuses. **A brawl is a
> melee of any size**, one `fight: { melee: }` per member and no shared record, lasting while anybody
> in it is still angry with somebody there. **It spreads**: a fighter drags in somebody watching, and
> somebody standing by piles in — spoiling for it, or near snapping with somebody in it they hate. A
> fighter mans nothing (`Tick#crews` leaves them out), so a fight empties every post it takes in, and
> does not walk. See
> [`design_sketches/animosity-and-distraction.md`](../../docs/design_sketches/animosity-and-distraction.md).
>
> **`Minion#avoid` is every hazard's getting-out-of-the-way** — `√(wits × agility)`, the agility
> slowed by what is carried — and safety saves, refuges, being caught by a runaway, the accident
> margin and `defend` all read it. Wits alone stays where the question is judgement: slips,
> lateness, misjudging, gauges. **Distraction** is `ambient_for`'s `distracting` — the allure of
> everybody else in the room — and divides wits.

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
- **Events are output and are not snapshotted**, so nothing the engine needs next tick may wait
  in them. A `:minion_mishap` is reported as an event *and* written to `state[:mishaps]`, which
  is what the next tick's `stress` reads; waiting only in the events it would vanish across a
  restore and the restored match would diverge from the one that ran straight through.

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
>
> **A post takes as many as its `capacity` and their work sums** (`Tick#crews`). A lever defaults
> to one; a gang's part raises it. An effort post reaches its node in **worker-equivalents** —
> 100 is one competent hand flat out — so nodes are rated per worker and cap nothing but the crew.

> **`aided_by:` adds and `gated_by:` multiplies, and the difference is a design decision rather
> than an arithmetic one.** A shovel makes shovelling better and its absence makes it merely
> unaided. A pick and a lamp are not like that: an ogre with no pick gets no coal out of a seam
> however strong they are, and nobody gets any in the dark. So hewing declares
> `gated_by: %i[mining_effectiveness darkvision]`, a missing tag is a **zero**, and a crude kit
> is a punishing 0.25 × 0.1 against a proper one's 0.8 × 0.75. That spread is the whole reason
> equipment is worth buying.
>
> **A gate can also be satisfied by the ROOM.** A lamp on the wall and a lamp on your belt are
> the same fact to `darkvision`, so a node that answers `ambient_tags(state, levers)` offers its
> tags to everybody standing in its place, and `Minion#gate` takes **the better of the two,
> never the sum** — two lamps do not let you see twice. `Tick#ambient_tags` builds the map from
> N−1 node state and this tick's lever positions, so it cannot depend on phase order; an
> operation with no places skips it and every gate stays what the minion carries.
>
> **An ignition source belongs to the room, the same way.** A node that answers
> `ignition(state, levers)` offers `{ kg_per_s:, watts:, cause: }` to the air of its place, and
> `Tick#ignition_sources` sums the offers per air node — **walked by sorted id**, because a float
> sum depends on its order and `graph_spec` shuffles declaration order. A vessel names no
> igniters of its own beyond its heater lever, so a candle, a sparking bell and a hot bearing are
> all simply things standing in the room. **So is a person**: anybody carrying `open_flame` offers
> `Minion::HAND_FLAME` to the air where they stand, summed after the nodes, by sorted minion id.

> **`posting` is where somebody has been SENT; `station` is what they are actually working.**
> `assign_minion` writes the first and names a destination, never a step — which is what lets it
> ride an at-least-once log with no dedup table. The walk happens inside the tick, in phase 6e,
> and the two fields differ only for as long as it takes. An operation that declares no
> `passages:` has no geometry, so they are always equal and none of this costs anything.
>
> `graph/passage.rb` carries both halves: `Passage` is the fourth kind of edge (a way **people**
> use, beside material, heat and momentum) and `Layout` is where everything is. **Both are
> build-time only** — routing tables are computed once per distinct capability set, never
> searched in a tick, which is the same discipline `Path.resolve` follows.
>
> **A ridden passage is boarded, not walked.** One that names a `hoist:` is a cage: a rider waits
> at the landing until it is there and stopped, is then `via` the drum and wherever the cage is,
> and gets off at the far landing. Their weight is the drum's cargo next tick (`ctx.cargo_kg`).
> It is offered only while its `staffed_by` post is manned, its drum sound and its shaft turning.
> Getting in takes `boarding_s`, and a marshal at the landing stops boarding at the cage's rating.
> Somebody part-way along any other powered way is `riding` its drive — the man engine's rods —
> and is cargo to it the same way. **`via` and `riding` are both what a `riders:` hazard or peril
> keys on**, and both are symbols held as values, normalised on restore.

> **`air` is the only substance tagged `breathable`, and every other gas asphyxiates by taking
> up the room it was in.** That is the whole of `breath.rb`, and it is why afterdamp needed no
> content at all: firedamp combustion consumes 17.2 kg of air per kilogram of gas and hands back
> `flue_gas`, so a district that has just burnt is a district nobody can breathe in. A new gas
> nobody thought about is therefore dangerous by omission rather than safe by omission, which is
> the only direction a hazard tag may fail in.
>
> Measured by **volume**, never by mass — firedamp is 0.668 kg/m³ against air's 1.225, and it is
> displacement that suffocates. Bad air drains `fatigue` rather than a pool of its own, so
> somebody works worse before they drop and recovers by walking out; `endurance` is already its
> divisor, **clamped by `Breath::RESERVE`** so the tireless reference crew is not immune.
>
> **Only the gas phase is breathed.** Water on the floor and coal in the tubs take up none of a
> lungful. A room whose air node answers `submerged?` — the pit bottom, water to the roof — has
> nothing to breathe at all, so drowning is the same dwell, collapse and rescue race as afterdamp.
>
> **Apparatus runs out, and a set with no air left is no protection at all** — no taper, because
> there is no half a breath. `respirator:` is how well it filters, `respirator_air:` is how many
> ticks it holds, and the two go together: `respirator` alone is inert. It is spent every tick
> the air is foul, whether or not that tick needed it, and walking out is the only way to stop.
> That is what makes a rescue a race rather than a decision.

> **A hazard belongs to a place, not to a job.** `place.rb` declares the spaces, and a node
> belongs to one: a node's `endangers:` may key by `places:`, by `stations:` or by both, and
> phase 6b looks a minion up in each. The station key says somebody was hurt *because of the work
> they were doing*, which is false of nearly everything — a boiler letting go hurts whoever is in
> the engine room, including the visitor with no job and the man just stood down from his post,
> and misses the fireman who left two minutes ago. Prefer `places:` for anything that fills a
> room; keep `stations:` for the genuinely hands-on, and for an operation with no geometry, which
> has only stations to name. Both keys are walked by `injury_spec`, because a declaration in the
> namespace nobody looks up is a hazard that silently hurts nobody. **A place can move**: a
> footplate is carried by its train (`carried_by:`), and phase 6b shares what reaches it with the
> place the train stands in, and back, by its `shares:` — nothing else about it moves.

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
> — so every check afterwards is a deterministic comparison; the one die it reads, which of a
> tier's variants a wound is, was thrown in phase 0. Injuries therefore replay exactly, survive a
> snapshot, and need no amendment to the entropy invariant. The uncertainty is the hidden
> threshold, exactly as `durability_range` is for a part.
>
> **Nothing reaches it untyped.** A hazard with no `wounds:`, an unknown kind or cause, or shares
> that do not sum to one is refused when the machine is built (`Operation#validate_hazards!`), a
> peril or a weapon when it is made, and an incomplete catalogue at boot.
>
> A hazard's severity **scales with a figure the part reports on its failure event**
> (`scales_with:`/`reference:`), because a small steam escape is not a large one. Reading the
> event rather than the node keeps phase 6b order-independent and puts the magnitude on the
> durable record.

Plus the assembly layer — `names.rb` (what a machine built more than once calls its pieces),
`part.rb` (`Part` and `Fragment`), `parts.rb` (the registry), `slot.rb`, `assembly.rb`. **All five
are build-time only.** They resolve a chassis and a
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
  ids inside parcels, flags inside instrument state, a minion's `station`, **`posting` and
  `place`** beside it, a loadout's part
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
