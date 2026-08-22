# Reactor — Architecture

Technical companion to [concepts.md](concepts.md), which defines the game. This document defines how
it is built. Where a decision needed justifying, the reasoning is compressed to a line or two; the
full argument and the rejected alternatives live in the architecture review that produced this doc.

---

## 1. Goals and constraints

| Goal | Consequence |
|---|---|
| Deep simulation, narrow player agency | Sim complexity is unbounded; the *projection* layer is the game-design lever |
| Real-time decision-making under pressure | Fixed 4 Hz tick; input must feel instant regardless of tick rate |
| Learn Kafka properly | Kafka is on the critical path by choice, used for what a log is actually good at |
| Fast prototyping | One Rails codebase, one deployable image, no Node toolchain |
| Matches isolated; scalable later | Runner processes own matches via Kafka partition assignment |

**Non-goals for now:** multi-service deployment, horizontal web scaling, lobby/matchmaking.

---

## 2. Process topology

One codebase, one image, three process roles.

```
┌─ web (Puma) ────────── controllers, ViewComponents, ActionCable
├─ runner ────────────── tick loop, hosts lib/reactor_sim, owns match state
└─ consumers (Karafka) ─ persistence, archival, analytics
```

The engine is **not** a separate service. The separation that matters is a module boundary, not a
network boundary — a network hop inside a 250 ms control loop costs latency and debuggability while
buying nothing at this scale. Because the boundary below is enforced mechanically, extracting the
runner into its own service later is a directory move plus a Dockerfile.

---

## 3. The simulation boundary

```
lib/reactor_sim/     PURE RUBY. No Rails, no ActiveRecord, no ActiveJob, no Kafka, no I/O.
app/                 Web tier.
app/runner/          Thin Rails-booted host: Kafka client + tick loop + broadcast.
```

### Rules for `lib/reactor_sim`

1. No `Time.now`, `Date.today`, `SecureRandom`, `Rails.*`, or any global. **Clock and RNG are
   constructor arguments.**
2. No hash-iteration-order dependence; no object-identity or `object_id` dependence.
3. Plain Ruby objects in, plain Ruby objects out. Serialization is the caller's concern.
4. The RNG's state lives *inside* match state, so it snapshots and restores with everything else.

### Enforcement

Two specs, both of which must exist before the sim grows:

- **Purity spec** — loads the sim via `ruby -Ilib -e 'require "reactor_sim"'` and fails if `Rails`
  is defined. This single test is what makes the boundary real rather than aspirational.
- **Determinism spec** — same seed + same command sequence produces byte-identical final state.

Determinism is load-bearing: crash recovery (§6), replay (§8), and spectating (§7) all depend on it,
and it cannot be retrofitted into a sim that grew without it.

---

## 4. Simulation model

### Tick

Fixed rate, **4 Hz** (`DT = 0.25`). Driven by a plain Ruby loop against a monotonic clock with an
absolute deadline, so scheduling error never accumulates:

```ruby
t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
n  = 0
loop do
  deadline = t0 + (n += 1) * DT
  drain_commands(non_blocking: true)   # consumer.poll(0) → per-match inboxes
  live_matches.each(&:step!)           # pure sim
  publish_views_and_events
  snapshot_and_commit_offsets          # §6 — order matters
  sleep [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0].max
end
```

`DT` is a single config constant so raising the rate is a one-line experiment. One runner hosts many
matches in one loop; at ~1 ms of sim work per match, dozens of concurrent matches is a rounding error.

**The tick clock never lives in a queue.** A self-enqueueing `TickJob` would inherit Solid Queue's
~1 s polling jitter, and a retry would produce a *double tick* — silent state corruption. Job queues
are for work that must happen, not work that must happen on a schedule.

### Double-buffered evaluation

Each mechanism reads `state[t]` and writes into `state[t+1]`. Edges between mechanisms are buffers
with capacity and transport delay.

This is a game-design decision as much as a technical one: sequential in-tick resolution would
propagate a change through the entire chain instantly, deleting the delayed feedback that makes
managing a complex system interesting. It also eliminates a nasty class of evaluation-order bug, and
inter-player buffering means one player's meltdown *degrades* the chain rather than halting it —
which matters given that all players share in total production.

Enforce by freezing the read buffer; reading the write buffer must be impossible, not merely
discouraged.

### Incidents: accumulated stress, not per-tick dice

Mechanisms accumulate stress deterministically from operating conditions. An incident fires when
stress crosses a threshold rolled from the match seed at start.

A per-tick probability is memoryless — it produces incidents no diagnostic can predict and no player
can learn from, which fights the premise of a game about *reading* a system. Accumulated stress gives
legible causality, makes Diagnostics genuinely valuable, and keeps determinism clean. The player's
uncertainty comes from the hidden threshold and sensor noise, not from the system being arbitrary.

### Projection — player views are a first-class sim output

```ruby
match.project(player)     # → PlayerView
match.project(:spectator) # → god-view: no delay, no noise
```

At the end of each tick, the sim produces a per-viewer `PlayerView` applying gauge ranges, clamping,
noise, reporting delay, and broken-instrument behavior. **Only projections leave the sim.** Raw state
is never serialized to a client — shipping it and filtering in the view layer would leak ground truth
into the browser and turn a game-design lever into a client concern.

---

## 5. Where data lives

| Data | Home | Rationale |
|---|---|---|
| Mechanism types, port signatures, upgrade trees, minion archetypes | **YAML in the repo**, frozen objects at boot | Diffable, no migration to rebalance the game, testable, no DB round trip |
| Player progression, resources, achievements | **Postgres tables** | Real relational data; needs querying and indexing |
| Match runtime state | **Memory**, snapshotted to Kafka (§6) | Never touches a relational store during a match |

Content YAML is validated against a schema **at boot, failing fast**. Bad content data is otherwise a
miserable class of bug.

Note that Postgres is available but JSONB is deliberately *not* the home for progression — blob
columns can't be queried or indexed, and schema changes become code.

---

## 6. Event streaming

Kafka, via Redpanda locally (single binary, Kafka wire-compatible, ships a console UI).

### Topics

All keyed by `match_id`. **12 partitions, fixed** — key→partition mapping is only stable at a fixed
partition count, and changing it later reshuffles every match's ownership.

| Topic | Retention | Purpose |
|---|---|---|
| `match.commands` | 7 days | Player intent. Consumed by the runner group. |
| `match.events` | 7 days | Engine output: ticks, incidents, production. Fan-out to consumers. |
| `match.snapshots` | **compacted** | Latest full state blob per match. Recovery source. |
| `match.lifecycle` | 7 days | created / started / ended. |

One topic per match would be wrong: the partition is Kafka's unit of parallelism, and thousands of
topics is a well-known way to make a cluster unhappy.

### Partition assignment *is* match ownership

Runners join consumer group `match-runners`. Kafka assigns partitions; a runner owns every match
whose `match_id` hashes into its partitions. **Exactly-one-owner is a Kafka invariant, not code we
write** — there is no lease table, no heartbeat, no registry. When a runner dies, rebalance reassigns
its partitions and the new owner recovers those matches from snapshots.

Required config:
- `partition.assignment.strategy = cooperative-sticky` — the default eager assignor stops the world
  on every rebalance, so adding one runner would pause every live match.
- `max.poll.interval.ms` generous (≈60 s) — the runner does simulation work between polls.

### Commands are absolute intents, never deltas

Kafka is at-least-once; redelivery *will* happen on rebalance or crash-before-commit.

```jsonc
// Correct — idempotent, redelivery is a no-op, last-write-wins per (control_point, tick)
{ "type": "set_control", "control_point_id": "rod_bank_a", "value": 42,
  "player_id": "…", "client_seq": 118, "issued_at_ms": 1723… }

// Wrong — order-dependent and duplicate-sensitive
{ "type": "adjust_control", "control_point_id": "rod_bank_a", "delta": 5 }
```

Absolute values make at-least-once delivery harmless with no dedup table. This is the highest-leverage
single decision in the ingress design.

### Offset commits happen after snapshotting

Order is load-bearing:

1. Tick N consumes commands through `match.commands` offset `X`.
2. Runner produces the post-tick snapshot to `match.snapshots`, **embedding `X` in the record**.
3. *Only then* commit offset `X`.

Recovery: read the compacted snapshot for the key → state + offset `X` → seek `match.commands` to `X`
→ replay forward. Combined with a deterministic sim, the match resumes in exactly the state it left.

### Producer config

| | Commands | Snapshots |
|---|---|---|
| `linger.ms` | `0` | default |
| `acks` | `all` | `1` |
| `enable.idempotence` | `true` | — |
| compression | — | on |

The default 5 ms batching linger is a throughput tradeoff, which is the wrong one here.

### Clients

- **Runner: raw `rdkafka`.** Needs non-blocking `poll(0)` inside its own loop and manual offset
  commits at the tick barrier — neither fits a message-driven framework.
- **Egress: `karafka`.** Genuinely message-driven work. Its Web UI surfaces consumer lag, partition
  assignment, and rebalances, which is where the concepts stop being abstract.

### Solid Queue's remaining role

Deferred, non-realtime work only: end-of-match writes triggered by the persistence consumer, cleanup,
email. A job queue for jobs, a log for events.

### Latency budget

```
lever pull → POST → produce            ~2–10 ms
           → runner poll               ~1–10 ms
           → TICK BARRIER              up to 250 ms   ← dominates
           → sim step                  ~1 ms
           → cable → paint             ~10–30 ms
```

The tick barrier dominates by an order of magnitude, so Kafka is not worth micro-optimizing.
Perceived responsiveness comes from optimistic client UI (§7), not from a faster broker.

---

## 7. Realtime protocol

Split by data character, both riding one ActionCable connection.

### Continuous telemetry → JSON deltas

Each tick the runner diffs the current projection against the last one sent and publishes only what
changed:

```json
{ "tick": 412, "t_ms": 1723456789012, "changed": { "core_temp": 812.4, "pressure": 71.2 } }
```

A Stimulus controller writes values into gauge elements. **No smoothing initially** — at 250 ms a raw
update reads as a responsive instrument. Add it per-gauge, cheapest first:

1. A CSS transition on `transform`/`width` at ~250 ms — zero JS, and for a needle or bar this *is*
   tweening. Covers most gauges.
2. rAF interpolation, only where a gauge demonstrably needs it.

No interpolation buffer at any stage: buffering trades a full tick of display lag for smoothness,
the wrong trade in a game about time pressure. Some instruments should stay unsmoothed deliberately —
a twitchy needle is a legitimate diagnostic signal.

### Discrete events → Turbo Stream HTML

Incidents, alarms, a mechanism catching fire, a control point going offline, phase changes, chat.
Rare, structural, and genuinely better as server-rendered HTML — this is where ViewComponent, I18n,
and Turbo morphing earn their place.

**Broadcast synchronously from the runner.** `broadcast_*_later` routes through ActiveJob → Solid
Queue → ~1 s polling, which would hand your realtime path a job queue's latency.

Gauge *chrome* is rendered once by a ViewComponent carrying `data-` attributes; only values stream.
One source of truth for markup.

### Input path

`POST /matches/:id/commands` (Stimulus `fetch`, not a Turbo form) → authorize that this player owns
that control point → produce to `match.commands` → `202 Accepted`.

- **Optimistic UI:** the control moves immediately in a `pending` style; the next authoritative
  projection confirms or corrects it. This is what makes a 4 Hz game feel instant.
- **Rate limit:** coalesce client-side (send on change, throttle ~10/s) and apply Rails 8's
  `rate_limit` in the controller, so a player mashing a lever can't flood a partition.

### Fan-out: the runner dual-writes

Durable event → `match.events` (the record). Projection delta → ActionCable directly (the fast path).

**The cable message is a cache; the log is the truth.** There is no sync hazard, because the engine
owns all state — the two writes are a broadcast and a record of the *same already-decided* fact, not
two parties negotiating. A dropped cable message self-heals on the next tick.

### Resync, reconnect, spectating — one mechanism

Deltas require a base state, so there is a "full projection" request. Everything else falls out of it:

- **Resync is reconnect.** A client detecting a gap in the `tick` sequence does exactly what a newly
  subscribed client does. One code path, exercised constantly in normal operation — which is why it
  will actually work during a real reconnect.
- **AFK needs no engine support.** The sim never knows whether anyone is watching, so an absent
  player's Operation keeps running on its last settings. There is no AFK mode, no pause, no takeover
  — the feature is the *absence* of one. Presence is purely a web-tier concern. An unattended reactor
  drifting toward an incident is a threat other players can see coming and must react to.
- **Spectating is a projection.** Subscribe, get a full view, then deltas — a player minus the
  command endpoint. Spectators get the god-view. It still goes through `project`, so §4's rule holds
  and a shadow-a-player mode can be added later without reworking the path.

Every snapshot carries `tick` and server time so clients can detect gaps.

---

## 8. Persistence and replay

Match state never reaches Postgres during play. At end of match, the persistence consumer writes:

- **Progression** — resources gained, achievements, unlocks. The only permanently meaningful data,
  since players start each match from a fresh Operation.
- **Replay archive** — `seed + command log`. Because the sim is deterministic, this is a few KB per
  match rather than a recording of every frame.

Playback re-runs the sim from the archive and drives the same projection the live client uses, so
replay and spectating share the entire rendering path. `match.commands` retention (7 days) must
outlive a match by enough margin for archival to happen.

---

## 9. Development environment

The project is **entirely Node-free**: importmap for JS, `tailwindcss-rails` standalone binary for
CSS. No `package.json`, no `.node-version`.

- **Postgres** for `primary`, `cache`, `queue`, and `cable` databases.
- **`config/cable.yml` must not use `adapter: async` in development.** Async is in-process only, and
  the runner is a different process from Puma — broadcasts from the runner would silently reach
  nobody. This fails quietly rather than erroring, so it is worth getting right up front.
- **`Procfile.dev` + foreman**, since `bin/dev` must start web, runner, and consumers together.
- **`docker-compose.yml`** for Redpanda, plus a rake task creating topics with the right partition
  count and compaction settings.

---

## 10. Roadmap

### v0 — one operation, one player

One Operation (Chemical Vats: enough control points to be interesting, far less domain research than
the RBMK). No supply chain, no upgrades, no progression, no smoothing, no lobby. The goal is proving
tick loop + Kafka round-trip + realtime rendering end to end on the smallest possible surface, with
every §3–4 invariant designed in from the start.

1. **Groundwork** — Postgres; drop `cssbundling-rails` for `tailwindcss-rails`; add `view_component`;
   `Procfile.dev`; `cable.yml` off async; Redpanda compose + topic creation.
2. **Pure sim** — one mechanism, double-buffered, seeded RNG. Purity and determinism specs pass
   before anything else touches it.
3. **Runner** — monotonic 4 Hz loop, no Kafka yet, state to stdout.
4. **Command ingress** — controller → produce → drain at the tick barrier.
5. **Telemetry out** — projection → diff → cable, raw values.
6. **Full-view path** — subscribe / resync / spectate.
7. **Snapshots + offset commits**, then the recovery drill.
8. **Turbo incident broadcasts** — the first ViewComponent that earns its keep.

Steps 2–3 are where the game becomes real. Step 1 is unglamorous, but every item on it is far cheaper
now than later.

### Then
Second player and the first chain link — the parts a single-player slice never exercises: inter-player
buffering, shared production rewards, and real queue fan-out.

---

## 11. Verification

| Check | Asserts |
|---|---|
| Determinism spec | Same seed + command log → byte-identical state |
| Purity spec | Sim loads outside Rails; fails if `Rails` is defined |
| Recovery drill | `kill -9` the runner mid-match; state resumes from snapshot, browser sees no interruption |
| Rebalance drill | Second runner joins mid-match; unaffected matches don't stutter |
| Redelivery drill | Replay commands from an earlier offset; final state unchanged |
| Reconnect drill | Close and reopen the tab; all gauges correct, Operation ran unattended throughout |
| Replay check | Archived seed + command log re-simulates to the same final state |
| Latency check | Instrument lever-pull → paint; tick barrier still dominates |
| Karafka Web UI | Watch lag and partition assignment during the drills above |
| Playtest | Whether managing the vats under pressure is actually *fun* |

---

## 12. Deferred by design

Both are **game-design outputs, not architectural inputs**. Deciding them now would mean guessing.

1. **Lobby / matchmaking / match lifecycle.** Whether this wants a matchmaker, open lobbies, or
   something else depends on what the Operations turn out to be and how a supply chain actually
   plays. `match.lifecycle` reserves the seam; nothing else is committed.
2. **Resource and port type system.** `{kind, quantity, quality}` with `accepts:`/`produces:` port
   signatures is a sketch of the *shape*, not a specification. The real contract falls out of building
   a second and third mechanism and discovering what compatibility needs to mean. It should end up
   **enforceable** — schema-validated at boot, failing fast — and the enforcement mechanism can arrive
   well before the final shape does.

**Risk to watch:** deferring is correct, but neither should harden by *accident*. If v0's single
mechanism ends up defining the port contract by default, that's the failure mode. Keep the first
implementation obviously provisional.
