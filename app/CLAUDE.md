# `app/` — the delivery tier

**Status: partly built.** Check [`docs/current_progress.md`](../docs/current_progress.md)
before assuming anything here exists.

```
app/simulation/   DevMatch, StreamNames — the ONLY code both web and runner touch
app/runner/       MatchRunner (4 Hz loop), CommandConsumer, ViewBroadcaster — bin/match_runner
app/kafka/        CommandProducer — web side, produces to match.commands
app/controllers/  ConsolesController (chrome), CommandsController (202), MatchesController
app/channels/     OperationChannel — read-only, telemetry out
app/components/   PanelComponent -> InstrumentComponent -> Instruments::{Needle,Digital,Prose,Lamp}
app/javascript/   controllers/console_controller.js, channels/consumer.js
```

Still stock: models and migrations — and the prototype deliberately needs none.

**Zeitwerk treats every directory under `app/` as an autoload root**, so
`app/runner/match_runner.rb` defines `MatchRunner`, not `Runner::MatchRunner`. Don't fight it —
name things unprefixed, exactly as `app/jobs/foo_job.rb` gives `FooJob`.

`app/simulation/` is separate from `app/runner/` on purpose: it is genuinely shared, and
putting a class the controller depends on inside `app/runner/` would lie about the boundary.

The design for all of it is [`docs/architecture.md`](../docs/architecture.md) §6–§10. It was
written before the simulation rewrite and is unaffected by it.

## The boundary

```
lib/reactor_sim/   PURE RUBY. Knows nothing about Rails, Kafka or the web.
app/               May call into the sim. The sim never calls back.
app/runner/        Thin Rails-booted host: Kafka client + tick loop + broadcast.
```

The engine is **not** a separate service — the separation that matters is a module boundary,
not a network boundary. A network hop inside a 250 ms control loop costs latency and
debuggability while buying nothing at this scale.

**Never reach into raw simulation state from here.** Only projections leave the sim:
`op.project(viewer:, tick:)` → `PlayerView` → `delta_from(previous)`. Shipping raw state and
filtering in the view layer would leak ground truth into the browser and turn a game-design
lever into a client concern. `op.telemetry` is for the runner's stdout and specs, never a
client.

## Process roles — one codebase, one image

```
web (Puma)        controllers, ViewComponents, ActionCable
runner            tick loop, hosts lib/reactor_sim, owns match state
consumers (Karafka)  persistence, archival, analytics
```

## The panel problem, and why rebuilding a Match in the web process is sound

The runner owns the only `Match`, in another process, so the web tier **cannot** call
`match.panel` — and the panel is what the console page needs to render at all.

`DevMatch.panel` therefore rebuilds a throwaway match just to ask it. That is sound for one
checkable reason: **`Operation#panel` reads only configuration.** It maps over frozen
instrument and control-point objects and never touches `@state`, so the same builder with the
same options returns byte-identical chrome regardless of seed, tick, or match history.
Verified: a cold engine and one 500 ticks into a hot run produce identical panels, as do two
different seeds.

**The one thing that must not differ between the processes is `variant:`**, which changes both
which diagnostics exist (`condenser_vacuum` is atmospheric-only: 13 instruments vs 12) and the
pressure gauge's full-scale reading. That is why both processes read it through
`DevMatch.variant` and never from `ENV` directly.

## Rules that are easy to break silently

- **The tick clock never lives in a queue.** A self-enqueueing `TickJob` inherits Solid Queue's
  ~1 s polling jitter, and a retry produces a *double tick* — silent state corruption. The
  runner is a plain Ruby loop against a monotonic clock with an absolute deadline, so
  scheduling error never accumulates. Measured: 0.1–0.2 ms drift over 215 ticks.
- **Never close an rdkafka handle from inside a signal trap.** It is an FFI client with a
  background polling thread and closing a native handle in trap context deadlocks. A handler
  may only set a flag; teardown happens on the main thread after the loop exits.
- **The runner must never be wrapped in the Rails executor or reloader.** It calls
  `eager_load!` once at boot. A reload would swap constants under a live `Match` — the exact
  hazard `config/application.rb` cites for keeping the sim out of Zeitwerk.
- **Measure loop lateness at the top of the tick**, against when the tick was due to start.
  Measuring after the work but before the sleep reports the idle time instead — about −250 ms,
  and identically so whether the loop is healthy or slowly falling behind.
- **Broadcast synchronously from the runner.** `broadcast_*_later` routes through ActiveJob →
  Solid Queue → ~1 s polling, handing your realtime path a job queue's latency.
- **`config/cable.yml` must not use the `async` adapter in development.** It is in-process
  only, so a runner broadcasting from its own process reaches nobody, silently.
- **Commands are absolute intents, never deltas.** `set_control` with a `value`, never
  `adjust_control` with a `delta`. Absolute values make Kafka's at-least-once delivery harmless
  with no dedup table — this is the highest-leverage decision in the ingress design, and it is
  the same rule as the sim's idempotence invariant.
- **Offset commits happen after snapshotting**, with the command offset embedded in the
  snapshot record. Order is load-bearing for crash recovery.
- **`lib/reactor_sim` is not autoloaded.** `config/application.rb` ignores both `reactor_sim`
  and `reactor_sim.rb` — the ignore list matches exact paths, so both entries are needed. Reach
  it with an explicit `require "reactor_sim"`. Letting Zeitwerk manage it would make the sim
  reloadable in development, so a long-running runner could hold state built from unloaded
  constants.
- **Solid Queue is for deferred, non-realtime work only** — end-of-match writes, cleanup, email.
  A job queue for jobs, a log for events.

## The view layer

- **The page renders chrome only.** Not one simulation value reaches it from the controller;
  every gauge starts at `—` and fills when the first projection arrives. Cheap to serve, and
  impossible to serve stale.
- **Driven by `panel[:instruments]`, never a hardcoded list.** High-pressure has 12 gauges,
  atmospheric 13. `InstrumentComponent` is a dispatcher on `chrome[:kind]`, and an unknown kind
  **raises** — a gauge silently missing from a control panel is the worst failure this page has.
- **`with_collection_parameter`** is required on `InstrumentComponent` and `LeverComponent`:
  `with_collection` otherwise derives the parameter from the class name and passes `instrument:`
  to an initializer that wants `chrome:`.
- **Needles position via one CSS custom property** (`--fraction`) with a 250 ms transition. That
  transition *is* the tweening — at 4 Hz it bridges exactly one tick for zero JS. Writing a
  custom property also avoids the layout that animating a width would cost.
- **`ProseComponent` must never infer severity** from a phrase's position. `Displays::Prose`
  withholds its phrase list on purpose; reconstructing it would hand back exactly the
  information the display exists to hide.
- **Tailwind cannot build classes from runtime strings** — map colour symbols to classes in
  Ruby (`LampComponent::COLOURS`), never interpolate into a class attribute.

## Realtime protocol, in one line each

- **Continuous telemetry** → JSON deltas over ActionCable, written into gauge elements by
  Stimulus. No interpolation buffer at any stage: buffering trades a full tick of display lag
  for smoothness, the wrong trade in a game about time pressure. Some instruments should stay
  unsmoothed deliberately — a twitchy needle is a diagnostic signal.
- **Discrete events** (incidents, alarms, chat) → Turbo Stream HTML. This is where
  ViewComponent and Turbo earn their place.
- **Input** → `POST /matches/:id/commands` via Stimulus `fetch` → authorize → produce to
  `match.commands` → `202 Accepted`. Optimistic UI moves the control immediately in a `pending`
  style; the next authoritative projection confirms or corrects it. That is what makes a 4 Hz
  game feel instant.
- **Gauge chrome is rendered once** by a ViewComponent carrying `data-` attributes; only values
  stream. `op.panel` supplies it.

## Kafka, as actually wired

`CommandProducer` (web) → `match.commands` keyed by `match_id` → `CommandConsumer#drain` at the
runner's tick barrier. Verified end to end: both records of a two-command burst landed on **one
partition** in order, and the runner applied them within a tick.

- **`require "rdkafka"` loads `karafka-rdkafka`, not the `rdkafka` gem.** Both are in the
  lockfile, both define `Rdkafka`, and karafka-rdkafka 0.28.0 wins — so the Gemfile's
  `gem "rdkafka", "~> 0.19"` is effectively inert. `poll_batch_nb` exists in both, so nothing
  here is affected, but do not reason from the version in the Gemfile. Resolve the duplication
  before building the egress consumers.
- **Build clients lazily, never in an initializer.** An initializer opens a broker connection
  inside `assets:precompile`, `rails console` and the test suite. `CommandProducer.instance` is
  memoised **per process id** because rdkafka handles are not fork-safe — one created before
  Puma forks is inherited broken, and the failure is silent.
- **Never `wait` on the delivery handle in a request.** That turns a 202 into a broker round
  trip inside the request cycle, which is the thing the 202 exists to avoid.
- **`auto.offset.reset` must be `latest`** while the dev match is rebuilt from a fixed seed at
  boot; `earliest` replays a week of stale commands into a cold engine on every restart.
- **`poll_batch_nb` returns errors inline** in the same array as messages. Not filtering them
  means calling `#payload` on an exception.
- **Runner-addressed commands ride the same topic** (`reset_match`, `resync`) so they stay
  ordered against the lever commands. A side channel could not promise that, and the web
  process has no other way to reach the runner.

## Testing

Specs here require `rails_helper`, not `spec_helper` — see [`../spec/CLAUDE.md`](../spec/CLAUDE.md).
Never make `spec_helper` boot Rails. Request specs stub `CommandProducer.instance`: a spec that
needs a broker running is a spec nobody runs.
