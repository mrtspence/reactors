# The event system: a durable record of what happened

**Status:** reviewed, agreed, and **built** — stages A–E in §13 all landed. §14 records what was
settled at review and §15 what the build itself found, including two things this sketch had
wrong. The body below is the design as agreed; where the build corrected it, §15 says so.

The failure model gave parts expressive, legible ways to come apart — modes, escalation,
collateral, a drum that flashes itself open. All of it is **ephemeral**. An event lives inside
one tick's projection and is gone: `Operation#to_h` rejects `:events` on the grounds that they
are "already published to the event log", and there is no event log. A spectator joining one
tick later never learns the flywheel burst, `Achievement.earned?` returns `true` for everything
because nothing can observe a match, and the `requires:` gate on `reflex_gauge_glass` is
decorative.

This sketch decides the shape of the record: what the engine emits, what carries it, who
digests it, and where the permanent facts land.

The framing question from the brief is the right one — **in-engine performance against a
durable, inspectable, extensible log** — and §3 answers it with numbers. The short version is
that the tension is smaller than it looks, and only because of a decision made in §2: the
engine emits *transitions*, never accumulations, because the accumulator already exists and is
called `Ledger`.

---

## 1. What exists, measured

The whole path, end to end:

```
Node#apply / #apply_wear  →  [next_state, events]      # a bare Hash, no schema
Tick#call                 →  state[:events] = (apply + wear).freeze
Operation#step!           →  returns state[:events]
Match#step!               →  event.merge(tick:, operation_id:)
Operation#project         →  PlayerView#incidents      # ← the only exit
ViewBroadcaster           →  ActionCable, inside the delta
console_controller.js     →  appendIncidents, prepend to a <ul>
```

One exit, and it is the fast path. There is no slow path.

**Two emitters exist.** `Concerns::Wearing#break_part` (every part failure) and
`Nodes::FusiblePlug` (`:fusible_plug_melted`). That is the entire vocabulary of the game's
event stream today.

An event is this hash:

```ruby
{ type: :vessel_rupture, node: :boiler, label: "Boiler", severity: :critical,
  tick: 412, detail: { pressure_kpa: 1180.4, … },
  cause: :overload, mode: :explosion, escalated_from: :seam_split,
  damaged: [ :cylinder, :flywheel ], operation_id: :engine }
```

### Four findings

**1. The type is not enumerable, and where it is stable it says less than `mode:` does.**
`failure_type` defaults to `:"#{id}_failure"` — derived from the *node id*, so renaming a node
silently renames an event type, and no consumer can be checked against a list of types the way
`Blueprint.key?` and `Achievement.known?` check everything else in this codebase. Four classes
override it (`:flywheel_burst`, `:vessel_rupture`, `:conduit_rupture`, `:cylinder_failure`),
which fixes the renaming problem for those four and introduces a second: the names are
pre-`mode` vintage and now duplicate a field that is strictly better. `Nodes::Boiler < Vessel`
and does not override, so **a boiler explosion and a steam-chest rupture arrive under the same
type, `:vessel_rupture`**, separable only by `node:` and `mode:`. A consumer matching on type
is matching on the least informative field available.

**2. `tick` is not unique per match, because a reset restarts it at zero.** `Match.create`
passes `tick: 0`, and `MatchRunner#reset` rebuilds the match in place under the same
`match_id`. The dev match is reset constantly — that is what `match_resets_controller` is for.
So `(match_id, tick)` names two different moments in two different runs, and any consumer
folding a stream keyed that way corrupts itself the first time a tester recovers from a burst
flywheel. §6.

**3. Nothing counts production, and nothing needs to.** `Ledger` already carries nine
monotonic floats inside operation state — `joules_to_work`, `joules_from_reactions`,
`mass_added`, `mass_spilled` and the rest — snapshotted every tick, conserved to zero drift
over 1200 ticks, and guarded by the conservation specs. "Generate X of power" is not an
event-counting problem. §2.

**4. The exclusion from the snapshot is currently a lie, and becomes a hazard.** `to_h` drops
`:events` because they are "already published". Once something does publish them, the *order*
of publish and snapshot is load-bearing in exactly the way `docs/architecture.md` §6 already
describes for command offsets — snapshot first and the events of that tick are unrecoverable.
§7.

---

## 2. Three shapes of fact, and only one of them is an event

Enumerating what the achievements actually want — including the four already named in
`Achievement::KNOWN`, which were chosen as things the simulation can observe — gives three
shapes, not one.

| Shape | Example | What it needs |
|---|---|---|
| **Point** — a thing happened once | `burst_a_flywheel` | one discrete record |
| **Cumulative** — N of a thing, or X total of a quantity | generate X joules of work; burn Y kg of coal | a running total |
| **Extent** — a property held over an interval | `ran_an_hour_without_blowing_off`; `raised_steam_from_cold_alone` | the interval's bounds, **and confidence the stream had no gaps** |

Point facts are events, obviously and only.

**Cumulative facts are not events, and treating them as events is the single worst thing this
design could do.** The naive shape — emit `power_generated` every tick and let a consumer add
it up — costs 4 records per second per match forever, of which essentially all are boring, and
it creates a *second* running total that can drift from the one the conservation specs check.
The engine already added those numbers. The consumer should read the sum, not re-derive it.

**Extent facts are the interesting ones, and they are why a fan-out of "interesting moments"
is not sufficient.** `raised_steam_from_cold_alone` is a claim about an *absence* — no igniter
between cold and a full head of steam. You cannot conclude an absence from a stream of positive
events unless you know the stream was complete over the interval. That is a property of an
ordered log with offsets, and it is not a property of a best-effort broadcast. It is the
strongest argument for the topic existing at all.

### The boundary rule this produces

Extent facts tempt you to put the predicate in the engine — the boiler knows whether the
igniter was held in, so let it emit `raised_steam_from_cold_alone` directly. **No.** That is
progression logic inside the pure simulation, and it fails the project's own boundary: the sim
would have to know what an achievement is, and every new achievement would become a sim change
requiring both dev processes restarted.

The rule instead:

> **The engine reports transitions in the machine. The app composes transitions into meaning.**
> If deciding whether to emit it requires knowing the rules of progression, it does not belong
> in the engine.

So the engine emits `:fire_lit`, `:fire_out`, `:steam_raised`, `:blew_off`, `:igniter_used` —
facts about a steam engine, true regardless of whether anyone is scoring them. The digest
composes `raised_steam_from_cold_alone` from `:steam_raised` with no `:igniter_used` since the
preceding cold state. The engine never learns the word "achievement".

This also keeps the emission cheap: a transition fires when something *changes*, not per tick.

---

## 3. The performance question, with numbers

The brief asks to balance in-engine performance against durability. Measured against the
budget that already exists:

- The tick budget is **250 ms**. A steam-engine tick is ~1 ms of simulation work; the
  performance guard is 55 ms for a hundred-node network and this machine has twelve nodes.
- The existing per-tick egress is one `ActionCable.server.broadcast`, which is **a Postgres
  INSERT through Solid Cable** — already far more expensive than a Kafka produce, and already
  skipped on unchanged ticks.
- `CommandProducer#produce` is fire-and-forget with `linger.ms: 0`; it does not wait on the
  broker.

Against that, the expected event volume for one match under §2's rule:

| Source | Records per match |
|---|---|
| Part failures | 0–6 (a match usually ends at the first) |
| Fusible plug | 0–1 |
| Machine transitions (lit, out, steam raised, blew off, …) | tens |
| Meter readings (§4) | one per minute of play |
| Lifecycle | 2 |

**Dozens of records per match, against 4 broadcasts a second.** The event topic is a rounding
error on a path that already carries far more, and it stays that way *by construction* rather
than by luck — because §2 put accumulation in the ledger.

The rule that keeps it true is worth writing down where it can be violated:

> **Nothing that happens every tick may be an event.** A per-tick quantity belongs on the
> ledger, and reaches the log as a periodic absolute reading. If you find yourself emitting a
> record whose interesting content is a number that changed a little, you want §4.

The remaining cost is JSON encoding, which is the same encoding `ViewBroadcaster` already does
every tick for a much larger payload.

---

## 4. Two record kinds, with different idempotence

Kafka is at-least-once and redelivery *will* happen. `docs/architecture.md` §6 solved this for
commands by making them **absolute intents** — "set the throttle to 42", never "open it by 5" —
so a duplicate is a no-op with no dedup table anywhere. The same trick works here, applied
twice in two different ways, because there are two different things to carry.

**Facts** — a failure, a transition, a lifecycle change. Append-only, individually meaningful,
deduped by identity (§6). A consumer that sees one twice must recognise it.

**Meter readings** — the ledger as it stands, at this tick, **absolute rather than a delta**.
Emitted every `METER_TICKS` — **40, ten seconds of wall clock**, which is exactly the
broadcaster's `FULL_VIEW_TICKS` and the runner's `HEARTBEAT_TICKS`, so all three periodic
things in this system tick together — and once more at match end.

Ten seconds rather than a minute because §3 says the volume does not matter: six readings a
minute per match is still a rounding error beside four broadcasts a second, and the finer
interval buys a more responsive power figure and a smaller worst-case loss on a crash. Tune it
if a measurement ever says otherwise.

```jsonc
{ "kind": "meter", "match_id": "dev", "run_id": "…", "operation_id": "engine", "tick": 2400,
  "ledger": { "joules_to_work": 4.21e8, "joules_from_reactions": 1.9e9, "mass_added": 812.4, … } }
```

Absolute is what makes it safe: a duplicate reading writes the same value, and a *lost* reading
costs nothing because the next one carries the whole total. The consumer's write is
`total = greatest(total, reading)` — idempotent, order-insensitive, and correct under
redelivery, out-of-order arrival and a consumer restart alike. A crash costs at most one
interval of progress, never a corrupted total.

Two payoffs worth noting:

- **Power falls out of it.** The ledger gives *energy*; "generate X MW" is a rate and needs a
  derivative. Two consecutive readings give exactly that — `Δjoules_to_work / Δticks · DT` is
  the mean shaft power over the interval, so both "delivered X joules" and "sustained X
  kilowatts for ten seconds" are answerable without the engine emitting anything new.
- **It makes the ledger inspectable during play**, which it has never been outside a spec or
  the runner's stdout.

---

## 5. The event becomes a typed record

`ReactorSim::Event` — a module of functions over a Hash, exactly as `Ledger` and `Parcel` are,
and for the same stated reason: it lives inside match state, it is serialised, and a class
would add a `to_h`/`from_h` round trip and buy nothing.

```ruby
module ReactorSim
  module Event
    # Enumerated for the reason every other id namespace here is enumerated: a consumer
    # keyed to a type that no longer exists is a feature silently switched off, and an
    # unenumerable type cannot be checked at all.
    TYPES = %i[
      part_failed          # any Wearing part reaching or worsening a failure mode
      fusible_plug_melted
      fire_lit fire_out
      steam_raised
      blew_off
      igniter_used
    ].freeze

    SEVERITIES = %i[info notice warning critical].freeze
  end
end
```

**`failure_type` collapses to one type, `:part_failed`.** Every distinction those four class
names were carrying is already on the record and carried better:

```ruby
{ type: :part_failed, node: :boiler, mode: :explosion, escalated_from: :seam_split, … }
```

A consumer wanting flywheel bursts matches `type == :part_failed && node == :flywheel`, or
`mode == :burst`, either of which survives a node rename in a way `:"#{id}_failure"` does not.
The four overrides and the dynamic fallback all go.

> **This breaks four spec assertions**, in `steam_engine_spec` — `:cylinder_failure` ×3 and
> `:flywheel_burst` ×2. They should be rewritten to assert node and mode, which is what they
> were really testing and states it more precisely.

Validation is a **build-time and spec-time** check, never a tick-path one: `Event.build` raises
on an unknown type in specs, and the runner's producer refuses to publish one. Nothing
validates inside `apply`.

### What the engine does *not* put on an event

- **No wall-clock time.** Forbidden in the sim, and `tick` is the better clock anyway — it is
  the one both replay and the projection agree on. The runner stamps `produced_at_ms` on the
  envelope if a consumer ever wants it.
- **No player id.** The engine does not know who is watching. Attribution is the runner's, from
  the match roster.
- **No progression meaning.** §2.

---

## 6. Identity, and the reset hazard

Every fact needs a deterministic identity so at-least-once delivery is harmless. The natural
key is:

```
(match_id, run_id, operation_id, tick, seq)
```

`seq` is the event's index within the tick. **It is deterministic, and that is not an
accident**: `Tick#apply_nodes` and `Tick#stress` both iterate `@nodes` in build order, and
`Operation#step!` returns `apply` events then wear events, so replaying a tick from a snapshot
emits the same events in the same order. The property that makes replay work makes dedupe free.
It deserves a spec of its own, because nothing currently holds it.

**`run_id` is the finding from §1.2 and it is not optional.** A reset restarts `tick` at 0
under the same `match_id`, so without it the key collides between runs and any fold over the
stream is corrupted by a tester pressing reset. It cannot come from the sim — no clock, no
ambient entropy — so **the runner assigns it at build time**, where a clock is allowed, and
carries it on the envelope rather than inside the event.

It buys two more things:

- **A new `run_id` implicitly abandons the previous run's open intervals.** An extent fold
  waiting for a closing transition that will now never arrive is discarded on sight, rather
  than being left to match against the next run's transitions and award
  `ran_an_hour_without_blowing_off` for two half-hours in different machines.
- It is what `match.lifecycle` will carry when matches are created on demand, so this is not a
  throwaway — it is the identifier that concept needs anyway, introduced early because the dev
  match forces it.

---

## 7. Who produces, and in what order

The sim must not produce — purity. So the runner gains an `EventProducer` beside
`ViewBroadcaster`, which is precisely the dual-write `docs/architecture.md` §7 already
specifies: *"Durable event → `match.events` (the record). Projection delta → ActionCable
directly (the fast path). The cable message is a cache; the log is the truth."*

```ruby
def advance(match)
  # … commands applied at the barrier, as now
  events = match.step!
  @events&.publish(match, events)   # the record
  publish(match)                    # the cache — unchanged
end
```

Keyed by `match_id`, same as commands, so one match's events sit on one partition **in tick
order**. Extent facts depend on that ordering; without it a fold sees `blew_off` before the
`steam_raised` that opened the interval.

### The ordering against snapshots

This is where §1.4 bites. When snapshots land (the deferred item), the sequence is:

1. Tick N runs, consuming commands through offset `X`.
2. **Produce tick N's events.**
3. Produce the snapshot of state after N, embedding `X`.
4. Commit offset `X`.

Events before the snapshot, because the snapshot does not contain them — `to_h` drops
`:events`, correctly, since they are output rather than state. Snapshot first and a crash in
between loses them with nothing able to re-derive them.

A crash between 2 and 3 replays tick N from the older snapshot and **re-emits its events**.
That is fine and it is what §6 is for: same `run_id`, same tick, same `seq`, so the consumer
recognises them. Determinism is doing the work.

> This is a note for when snapshots are built, not work for this change. Today there is no
> snapshot in the loop at all, so step 2 stands alone.

`EventProducer` follows `CommandProducer`'s shape exactly, including the fork-safety memoisation
(rdkafka handles are not fork-safe and the failure is silent) — though the runner does not fork,
so it is a copied convention rather than a live hazard.

> **Nothing may block the tick loop. Ever.** A lost failure event is a lost permanent fact
> rather than a lever the player will move again, so the *temptation* is to wait on the delivery
> handle — and that temptation must be refused. The loop has to stay cheap enough that a
> four-player match of much larger machines is not something anyone has to think about, and a
> broker hiccup must degrade the record, never the simulation. So: `linger.ms: 0`, a delivery
> callback that logs and counts failures, and a counter on the heartbeat beside `applied`.
> Durability improves by making the *producer* better, never by making the loop wait.

---

## 8. Who digests: live fold vs post-game handler

The brief proposes a post-game handler. This is the one place I want to recommend something
different, so here is the comparison in full.

### A — post-game digest only

The consumer buffers or re-reads a match's events when `match.lifecycle` says ended, folds them
in one pass, and writes progression.

- **Pros.** One pass over a complete stream — every extent fact is decidable with no partial
  state anywhere. No half-finished rows in Postgres. Matches `docs/architecture.md` §8's
  "Match state never reaches Postgres during play" exactly. Simplest possible consumer state:
  none between matches.
- **Cons.** It requires a match to *end*, and match lifecycle is an unbuilt item on the same
  list this work came from — so this design would be blocked behind it. **The dev match never
  ends**; it is reset. So in the environment where this would actually be exercised, a post-game
  digest awards nothing, ever, and would rot unexercised exactly as `Achievement.earned?` has.
  It also needs the whole match's events at end, which means either holding them in consumer
  memory for the match's duration (state you have to recover after a consumer crash) or seeking
  backwards in the partition (awkward in karafka, and the offsets to seek to are themselves
  state). And it forecloses the mid-match unlock, which is a genuinely good moment in a game
  about slow-building tension.

### B — live streaming fold

The consumer processes each record as it arrives, holding a small fold per open match, writing
progression as facts complete.

- **Pros.** No dependency on match lifecycle — **it works today, against the dev match, which is
  the only way this gets exercised before it is trusted**. Each record is handled once; no
  seek-back, no buffering the match. Consumer state is small and bounded. Mid-match unlocks are
  available. A match that dies without ending still banks everything that completed before it
  died.
- **Cons.** Writes to Postgres during play, which reads against §8. Every write must be
  idempotent under redelivery (though §4 and §6 have already paid for that). Extent facts need
  in-memory fold state that a consumer restart loses — an open interval is abandoned, and the
  player has to do it again.

### Recommended: B, with the split that makes the cons mostly disappear

Live, but routed by shape rather than uniformly:

- **Point facts** are complete on arrival. Award immediately.
- **Cumulative facts** come from absolute meter readings, so the write is
  `greatest(total, reading)` and there is nothing to fold. A restart costs at most one interval.
- **Extent facts** hold a small open-interval record *in Postgres, not in memory* — one row per
  `(owner, run_id, achievement)` with the opening tick and the disqualifying flags seen so far.
  That answers the one real con: a consumer restart resumes the interval rather than losing it,
  and the row is itself the inspectable artifact when an achievement does not fire and somebody
  asks why.

**On the §8 objection — it is narrower than it looks.** §8 says *match state* never reaches
Postgres during play, and the reason is that match state is large, high-frequency and belongs to
a match that will not outlive the session. Progression is none of those things: it is small,
rare, belongs to a *player*, and is the one thing explicitly described as "the only permanently
meaningful data". They are different objects with different lifetimes, and the rule was written
about the first.

**End of match then stops being a special mechanism and becomes an ordinary record**: a final
meter reading and a lifecycle `ended` fact, which the consumer treats like any other arrival.
When match lifecycle lands it makes this *better* — a clean close for open intervals — but
nothing here waits for it.

### Two consumer groups, not one

`match.events` gets two independent groups:

- **`progression`** — §9, writes the permanent record.
- **`incidents`** — §11, writes the display log the client backfills from.

Independent offsets and independent lag, so one can be restarted, replayed or rewound without
touching the other, and a bug in progression does not stop the player seeing their boiler
explode. That fan-out is the reason a topic exists here instead of a direct write, and it is
what the architecture doc means by "Fan-out to consumers".

---

## 9. What lands in Postgres

Four tables. Sketched rather than settled — the shapes matter more than the columns.

```
match_runs      run_id (pk), match_id, seed, chassis, loadout, started_at, ended_at
                  ── one row per build. The thing §6's run_id names.

incidents       run_id, operation_id, tick, seq, type, node, mode, severity, detail jsonb
                  ── unique on (run_id, operation_id, tick, seq): §6's key IS the constraint,
                     so redelivery is an upsert no-op rather than a duplicate line in the feed.

progress        owner_id, run_id, metric, value        ── the meters, greatest() on write
                owner_id, metric, value                ── lifetime totals, summed at close

achievements    owner_id, achievement_id, run_id, tick, awarded_at
                  ── unique on (owner_id, achievement_id). This is what Achievement.earned?
                     finally reads.
```

`Achievement.earned?` then becomes the one-method change its own TODO promises:

```ruby
def earned?(id, owner_id: nil)
  return false if owner_id.nil?

  Award.exists?(owner_id: owner_id.to_s, achievement_id: id.to_s)
end
```

…and the `requires: raised_steam_from_cold_alone` gate on `reflex_gauge_glass` stops being
decorative. **Note the sequencing risk**: the moment that method tells the truth, every
blueprint naming a prerequisite locks. That is correct, but it must land together with at least
one achievement that can actually be earned, or the first thing this work does is take a part
away from the player. §13 stages it accordingly.

There is no auth yet, so `owner_id` is whatever `DevPlayer` supplies — the same placeholder
`Unlock` already uses. Deliberately unchanged here: a real user record arrives with the ordinary
Devise + OmniAuth setup later, and every table above already names the column it will fill.

**Retention is one week, on every feed.** Seven days on the topics (already what
`script/create_topics.sh` sets) and seven days on `match_runs` and everything that cascades from
it. The permanent record is `achievements` and the lifetime rows in `progress`; the rest is
working material — incidents about runs nobody will revisit, meter readings already folded into
totals. One week matches `match.commands` retention, which is what bounds replay anyway, so
there is one number to change rather than two that can disagree. A `match_runs` sweep is the
whole implementation.

---

## 10. Achievements: two shapes and an escape hatch

Most achievements are boring and should cost one line. A few are peculiar and should not have
to contort a DSL. So: two declarative shapes covering the boring ones, and a Ruby predicate for
the rest.

```ruby
Achievement.define :burst_a_flywheel,
  when_seen: { type: :part_failed, node: :flywheel }

Achievement.define :first_full_head_of_steam,
  when_seen: { type: :steam_raised }

Achievement.define :generated_a_gigajoule,
  when_meter: :joules_to_work, reaches: 1.0e9, scope: :lifetime

Achievement.define :ran_an_hour_without_blowing_off,
  between: { opens: :steam_raised, closes: :fire_out },
  lasting_ticks: 14_400,
  disqualified_by: { type: :blew_off }

Achievement.define :raised_steam_from_cold_alone,
  between: { opens: :fire_lit, closes: :steam_raised },
  disqualified_by: { type: :igniter_used }
```

Three constructs — `when_seen`, `when_meter`, `between/disqualified_by` — cover all four
existing ids and most plausible additions. Anything stranger takes a block receiving the fold
state and the record, which is the extension seam the brief asks for and costs nothing to leave
open.

**This stays in Ruby, not YAML**, on the same reasoning that settled parts authorship: these
are authored in-house, they are game design rather than configuration, and half of them will
eventually want a predicate anyway. Blueprints are YAML because they are a flat catalogue of
numbers; achievements are rules.

`KNOWN` becomes the keys of the definition table rather than a hand-written array, so the list
cannot drift from the definitions — the same move `Operations.chassis_for` makes.

---

## 11. The client, and what this means for the incident feed

The current client-side list is the thing that actually fails today: it accumulates from the
projection, so a spectator who joins a tick late sees "nothing has gone wrong yet" beside a
wrecked engine, and a reset clears it by detecting a tick regression.

The minimum fix is **backfill on subscribe**: `OperationChannel#subscribed` reads the last N
rows from `incidents` for the current `run_id` and sends them, after which the existing live
append is unchanged. One query, no new mechanism, and it fixes the complaint exactly.

**This does not settle the Turbo question.** Item 4 on the "What to do next" list plans to
replace the client-side list with server-rendered Turbo Stream incidents, and that is probably
right for the reasons the architecture doc gives — rare, structural, genuinely better as HTML.
But it is a rendering decision, and it is strictly easier once there is a durable row to render
*from*. Backfill first; the Turbo change then has a table to read and becomes a smaller change,
not a larger one.

---

## 12. What this must not foreclose

- **Replay.** `seed + command log` is the archive, and events are *derived* from replaying it,
  not part of it. Nothing here may make an event a source of truth about what happened in the
  machine — it is a record of what the machine reported. If the two disagree, the replay is
  right.
- **Multiple operations and multiple players per match.** Every record carries `operation_id`
  already. `owner_id` attribution is the runner's job at publish time and nothing in the schema
  assumes one player.
- **Shared production.** The premise has all players sharing in total production, so
  `joules_to_work` will eventually be summed across operations at match level. Meter readings
  are per-operation and absolute, so that sum is a consumer-side concern and needs no engine
  change.
- **Minions.** They will have their own facts — injured, killed, reassigned — and they are the
  next unit of work. `TYPES` is a list to extend, and a minion event is a transition like any
  other. The collateral-damage machinery from the failure model already knows which parts took
  which bystanders with them, which is what an injury event will be derived from.

---

## 13. Staging

Each stage is independently shippable and leaves the system working.

**A — the record takes shape, in the sim.** `ReactorSim::Event` with `TYPES` and `SEVERITIES`;
`failure_type` collapses to `:part_failed`; the four class overrides and the dynamic fallback
go; `steam_engine_spec`'s five type assertions are rewritten to node-and-mode. A spec that
replaying a tick emits identical events in identical order (§6). **No delivery-tier change** —
the projection carries the new shape and the client already leads with `mode`.

**B — the machine's transitions.** `:fire_lit`, `:fire_out`, `:steam_raised`, `:blew_off`,
`:igniter_used` on the steam engine. Each is a state-change detection in a node's `apply`,
emitted once on transition — the same discipline `break_part` already follows, and for the same
reason. This is the stage where a design mistake is cheapest to find, because the events have
nowhere to go yet.

**C — the log.** `EventProducer`; runner dual-write; meter readings every `METER_TICKS`;
`run_id` assigned at build. Verifiable in the Redpanda console with nothing consuming yet,
which is the cheapest possible integration test.

**D — the consumers.** Karafka (in the Gemfile, currently unused), two groups, four tables.
Progression writes; incidents write; channel backfill.

**E — achievements tell the truth.** The definition table, the fold, and `Achievement.earned?`
reading `Award`. **Must include at least one earnable achievement in the same change**, per §9 —
otherwise the first effect of this work is a locked blueprint.

Docs in the same commit, per the table in the root `CLAUDE.md`: `docs/architecture.md` §6 and §7
(the topic stops being aspirational), `docs/reference/nodes.md` and `concerns/CLAUDE.md` (the
event shape and `failure_type`), `lib/reactor_sim/CLAUDE.md` (a sixth entry for the
symbols-as-values trap — `type`, `mode`, `severity` and `node` are all symbols living as values
and every one of them comes back from Kafka as a string), `spec/CLAUDE.md`, and
`docs/current_progress.md`.

> **The JSON trap is worse here than it has been before.** Five instances so far have all been
> inside the snapshot round-trip, where `Operation#restore` is a single choke point. An event
> crosses into Kafka, into Postgres `jsonb`, and back out to a consumer — three boundaries, none
> of which is `restore`. A consumer matching `event[:type] == :part_failed` against a string
> silently matches nothing, and the failure mode is an achievement that never fires, which
> nobody notices because it looks exactly like not having earned it. The consumer should
> normalise once on the way in and assert with `be`, never `eq`.

---

## 14. Settled at review

1. **`:part_failed` stays, and vocabulary drift goes to zero.** An extra field read by the
   consumer costs nothing; two places that must be remembered together when a mode changes is a
   footgun, and this codebase has already paid for that class of mistake several times. The mode
   vocabulary lives in `failure_modes` and nowhere else. The rejected alternative — a type per
   mode, `:boiler_exploded` beside `:flywheel_burst` — reads marginally better at a call site and
   buys a second list to keep in step.

2. **`METER_TICKS = 40`, ten seconds.** Finer unless something measures a reason not to be.

3. **Nothing may block the tick loop, ever.** This is the hard constraint the whole design sits
   under, not a preference: purity and tick cost stay top priority so that four-player matches of
   much larger machines need no thought later. A lost event is logged and counted; it never
   becomes a wait. §7.

4. **`owner_id` stays `DevPlayer`.** Devise + OmniAuth arrives on its own schedule and every
   table already names the column.

5. **One week of retention on every feed**, matching `match.commands`, tunable from one place.
   `achievements` and lifetime `progress` are the permanent record; everything else is working
   material and gets swept with its `match_runs` row. §9.

---

## 15. What the build found

Three things this sketch got wrong or left unsaid, each found by measuring rather than by
reading.

### The volume budget held, and by a wider margin than claimed

§3 predicted "dozens of records per match". Measured on a reference high-pressure cold start —
4200 ticks, the standard lighting procedure — the engine emits **5 events**: `heater_engaged`
at t1, `fire_lit` at t2, `blew_off` at t1300, `steam_raised` at t1582, `blew_off` at t1860.
That is 0.005 records a second against four broadcasts a second on the cable. The rule in §3 is
what makes it true, and `event_pipeline_spec` now holds it under 20.

### A deadband is the wrong hysteresis for a reconstructed signal

The first measurement was **25 events, not 5**, and twenty of them were one valve announcing
itself every other tick from 1381 to 1420. §4's assumption was that chatter comes from a
boiler hovering a few pascals either side of its safety valve setting, which a percentage
deadband handles. That is not where it came from.

`cylinder_relief` senses `compression_pressure_pa` — a per-stroke pressure **reconstructed from
crank geometry**, which swings through its whole range tick to tick rather than wandering around
a level. A 2% band re-armed on every stroke. The fix is a **time hold**: `REARM_SECONDS` of
quiet before a second blow-off counts as a new episode, refreshed while the valve is open, so a
boiler sitting on its safety valve for an hour is one record. It reports what an observer would
say — the valve was blowing off *between* two moments — and it does not care what the sensed
quantity is doing, which is the property a deadband lacked.

`Nodes::Boiler` keeps a pressure band for `:steam_raised` and can afford to, because drum
pressure is a real lumped quantity that moves slowly.

### An achievement named something the machine cannot express

`raised_steam_from_cold_alone` — §10's worked example of the `between`/`disqualified_by` shape —
was awarded on **every ordinary start**, and the end-to-end spec caught it by asserting the
opposite and failing.

The igniter is how a cold fire is lit; there is no other route. So `heater_engaged` always
arrives at tick 1 and `fire_lit` at tick 2, and "no heater between lighting and steam" describes
a window the disqualifying event falls *outside* of. Not a fold bug — a spoiler arriving before
an interval opens is correctly ignored, because you cannot ruin what has not started — but a
rule written against a machine it did not match. Exactly the decorative-gate failure this whole
release exists to remove, reintroduced in the release that removes it.

Redefined as **a clean cold start**: the window runs from the fire catching to working pressure,
spoilt by the pilot coming back on *or* by the fire going out. That is the skill
`SteamEngine.firebox` already describes — the igniter is a match, not a furnace, and a player
who leans on it has a dying fire. `disqualified_by` became a list to express it.

> The lesson generalises past this one rule: **an achievement is only real once something has
> driven the actual machine through it.** A definition that reads correctly against a vocabulary
> list can still name a window the machine never produces, and nothing raises.

### Two bugs only a live broker could find

Both were invisible to the specs, and both are the kind that fail quietly forever.

**`report.error` is an error CODE, and 0 means success.** The delivery callback was written
`next if report.error.nil?`, so every *successful* delivery was logged and counted as a
failure: four records sent, four `delivery failed: 0`. §7 puts that counter on the heartbeat
precisely so a lossy record is visible — and a counter that is always wrong in the alarming
direction is worse than none, because the heartbeat then cries wolf permanently and a real loss
hides inside the noise. (A freshly constructed `DeliveryReport` *does* have `error` nil, which
is why the fix accepts both.)

**Postgres treats NULLs as distinct in a unique index, so the lifetime totals were never
unique.** §9's `progresses` table carries a per-run row and a lifetime row distinguished by a
null `run_id`; the index on `(owner_id, run_id, metric)` enforced the first and silently did
nothing for the second, because `NULL = NULL` is unknown rather than true. `ON CONFLICT` never
matched, so **every meter reading inserted a fresh lifetime row** — forty seconds of live
consumption left 40 rows for 10 metrics.

The spec that should have caught it came closest and still passed: `lifetime_totals` builds a
Hash with `pluck(...).to_h`, and the last value for a repeated key happened to be the correct
total sitting on top of three wrong rows. **Asserting the number was not enough; the row count
was the assertion that mattered.** The index is `nulls_not_distinct` now.

### Smaller corrections

- **`:igniter_used` became `:heater_engaged`.** §5 named it for the steam engine's pilot, but
  the emitter is `Nodes::Vessel`, which is generic. The engine reports a heater; only the rule
  knows what touching it costs.
- **The meter interval is enforced by the runner, not the producer.** Gating inside
  `EventProducer#publish_meters` hid the cadence from anything standing in for it, and a fake
  that cannot be wrong about timing tests nothing about timing. The constant still lives on the
  producer; `MatchRunner#record` decides which tick is a sampling tick, beside the heartbeat.
- **The projection needed curating, which §11 did not anticipate.** Transitions ride the same
  `state[:events]` the panel's incident feed reads, so `fire_lit` would have buried a burst
  flywheel. `Operation#incidents` filters to `REPORTED_SEVERITIES`, and `Incident.backfill`
  applies the same filter so history and live agree about what the feed is for.
