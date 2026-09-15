# `app/` — the delivery tier

**Status: partly built.** Check [`docs/current_progress.md`](../docs/current_progress.md)
before assuming anything here exists.

```
app/simulation/   DevMatch, StreamNames — the ONLY code both web and runner touch
app/runner/       MatchRunner (4 Hz loop), CommandConsumer, ViewBroadcaster — bin/match_runner
app/kafka/        CommandProducer — web side, produces to match.commands
app/controllers/  Consoles(show), Commands(create), Loadouts(edit/update), LoadoutDrafts(create), MatchResets(create)
app/channels/     OperationChannel — read-only, telemetry out
app/components/   PanelComponent -> InstrumentComponent -> Instruments::{Needle,Digital,Prose,Lamp}
app/javascript/   controllers/console_controller.js, channels/consumer.js
```

`app/models/loadout.rb` is the **only** model and `db/migrate` holds one migration. That is
deliberate: match runtime state never touches Postgres (it lives in the runner's memory and
snapshots to Kafka), so what earns a table is the durable, low-volume stuff. A loadout — which
parts a machine is built from — is the first of it, because it has to survive a runner restart
and be readable by both processes.

**Zeitwerk treats every directory under `app/` as an autoload root**, so
`app/runner/match_runner.rb` defines `MatchRunner`, not `Runner::MatchRunner`. Don't fight it —
name things unprefixed, exactly as `app/jobs/foo_job.rb` gives `FooJob`.

`app/simulation/` is separate from `app/runner/` on purpose: it is genuinely shared, and
putting a class the controller depends on inside `app/runner/` would lie about the boundary.

The design for all of it is [`docs/architecture.md`](../docs/architecture.md) §6–§10. It was
written before the simulation rewrite and is unaffected by it.

## Controllers are routing, not logic

**Every action is one of the seven: `index`, `show`, `new`, `create`, `edit`, `update`,
`destroy`.** There are no others. An action named for a verb in the domain — `fit`, `preview`,
`reset`, `publish` — is a signal, and it means one of two things:

1. **A resource is missing.** Name the noun the verb acts on and the verb becomes standard.
   "Fit these parts" is `update` on a **loadout**. "Grant a blueprint" is `create` on an
   **unlock**, and revoking it is `destroy`. If a verb resists this, the noun is usually a
   *decision* or a *draft* rather than a record — those are resources too.
2. **The work belongs somewhere else.** Lift it into the model of the underlying resource, or
   into a service object beside it.

**A controller may express routing, authorisation, parameter permitting, and which template or
redirect follows. Nothing else.** No domain rules, no multi-step orchestration, no assembling a
view's data out of three collaborators. If an action needs more than a few lines, the lines are
in the wrong file.

> Written down after `ComponentsController#fit` grew an ownership check, a workshop query and a
> per-slot candidate list on top of the validate/store/reset sequence it already had. Each
> addition was individually reasonable and the total was not, which is how this always happens —
> **the rule is here so the first one gets refused, not the fifth.**
>
> Applying it retired three non-standard actions: `components#show`/`#fit` became
> `loadouts#edit`/`#update` plus `loadout_drafts#create`, and `matches#reset` became
> `match_resets#create`. `MatchesController.reset_command` — domain work living on a controller —
> moved to `DevMatch`. The work went to `Outfitting`.

The counter-pressure to watch for: a thin controller that delegates to a fat `params`-aware
service is the same problem moved. A service object takes **resolved arguments**, never
`params`, and never touches `session`, `request` or `flash` — that is what keeps it testable
without a request and reusable from a rake task.

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

**The one thing that must not differ between the processes is `chassis:`** (formerly
`variant:`), which changes both which diagnostics exist (`condenser_vacuum` is
atmospheric-only: 13 instruments vs 12) and the pressure gauge's full-scale reading. That is
why both processes read it through `DevMatch.chassis` and never from `ENV` directly.

> **`loadout:` is the second thing, and it came due in stage 4.** A player now chooses the
> configuration on the outfitting screen, which is exactly the moment the old TODO warned about.
> It stays sound with one word changed: **the panel is a pure function of the LOADOUT**, so two
> processes reading the same stored loadout cannot disagree. `DevMatch.panel` is therefore
> memoised **per loadout**, not per process. Verified — removing the safety valve takes the panel
> from 18 instruments to 16.
>
> What remains is a race rather than a design flaw: save a loadout and the console renders the
> new panel over the old machine for a tick or two until the reset lands. The real fix is still
> the panel coming *from* the runner — published to a compacted topic, or sent over the channel
> on subscribe — which is where this goes when matches are created on demand.

## The outfitting screen

```
GET   …/operations/:id/loadout/edit    the screen
PATCH …/operations/:id/loadout         fit it, and rebuild the engine from cold
POST  …/operations/:id/loadout_draft   evaluate a build without storing it
```

**The chassis is a choice on this screen, and it decides what slots exist** — the atmospheric
frame has a condenser and the high-pressure one does not. Two rules follow, and both were bugs
first:

- **Permit against the SUBMITTED chassis, not the stored one.** They differ for exactly one
  request — the one where a player changes frame — and permitting against the old chassis drops
  the slots only the new one has.
- **Carry through only the keys the submission contains.** Stage 4's rule that an unfitted slot
  is an explicit empty exists so removing the fusible plug and saving does not put it back. On a
  frame change it is wrong: the form was drawn for the *old* frame, so naming a slot it never
  offered sends an explicit empty for a question nobody asked — and switching to the atmospheric
  frame refused itself with *"Condenser is required and nothing is fitted."* A same-frame save
  names every slot anyway, because the form renders every slot, so nothing re-defaults.

**`Outfitting` does the work; the controllers route.** It takes an owner id and a parts hash —
never `params` — and answers everything the screen asks: what is fitted, what may be offered,
what is locked, what will not run, and `fit!`. That is what lets a rake task drive the same path
and a spec exercise it without a request.

It renders configuration only, exactly as the console does — `Assembly` answers every question
about the machine without building an operation, because most of what the screen shows is about
builds nobody has chosen.

**The order through the Fit button is the design: validate → store → reset.** A build that cannot
assemble never reaches the database, so a runner booting cold cannot inherit a machine the
validator already refused.

- **The loadout rides INSIDE the reset command, not merely referenced by it.** The runner has
  Rails booted and could read the `loadouts` table; it must not. The web process writes the row
  and *then* produces the command, so a runner reading the table would read it at whatever moment
  the record happened to arrive — a reset racing a save rebuilds the previous machine with
  nothing to show for it. `DevMatch.reset_command` builds the payload.
- **Two verdicts, reported apart.** "You have not unlocked this" and "this will not run" are
  different failures with different fixes; merging them into one list makes the first
  unactionable, because a player goes looking for a wiring problem that is not there. Ownership
  is checked **first**, for the same reason.
- **The dropdown filter is a courtesy; `Outfitting#locked` is the gate.** The form is a plain
  POST and anyone can submit any part id — a client-side-only filter is not a filter.
- **A locked part that is already fitted still appears in its dropdown**, flagged. Hiding it
  would report an error about something the player can neither see nor change.
- **The form's own action is Fit, and previewing is what the JavaScript overrides.** Previewing
  is inherently scripted — it fires on `change` — so degrading to "no live preview" is right
  where degrading to "cannot fit anything" would not be. `outfit_controller.js` borrows the form,
  points it at the draft resource, clears Rails' `_method` override so it posts rather than
  patches, and puts all three back.
- **An unchecked slot submits as an explicit empty, never as a missing key.** A partial loadout
  falls back to `slot.default` in `Assembly`, which would silently refit the part a player just
  removed.
- **`MatchRunner#reset` rescues `ReactorSim::Error`** so a loadout that somehow got past the
  controller cannot take every match on that runner down with it.

> **A button that overrides `formaction` needs the GLOBAL CSRF token, and a request spec cannot
> tell you that.** Rails mints *per-form* tokens scoped to the form's declared action and method.
> The outfitting form declares the preview path; the Fit button points elsewhere with
> `formaction`, so the token it carries is minted for the wrong path and verification refuses it
> with a 422. Passing `authenticity_token: form_authenticity_token` (no form options) supplies
> the global session token, which Rails accepts for any action.
>
> **CSRF verification is off in the test environment**, so the request specs passed with this
> broken. It was found by driving the real server with curl — which is the general lesson: a
> request spec proves routing and behaviour, not that a browser can submit the form.

> **`permit` with the keys you mean, never `permit!` — and the security warning is the lesser
> half.** Brakeman flagged `params.fetch(:loadout, {}).permit!` as mass assignment, which it is.
> What it was also doing was admitting **non-scalars**: `loadout[boiler][]=x` arrived as an Array,
> reached `Assembly#normalise_part_id`, and `Array#to_sym` raised. On `fit` that is caught by the
> rescue; on the **preview** action, which has none, it is a 500 — reachable by anyone who can
> open the page. `{"boiler": 1}` in a JSON body did the same through `Integer#to_sym`.
>
> `permit(*slot_ids)` fixes both at once, because `permit` only admits scalar values. Two habits
> that follow: **coerce a permitted value with `to_s` before treating it as an id**, since a JSON
> body can carry a number where a form always carries a String; and **check the parameter is an
> `ActionController::Parameters` before calling `permit` on it**, because `?loadout=x` makes it a
> String and `String#permit` does not exist. Malformed input should reach the validator as data
> and come back as "no such part", never as an exception.

**Run `bin/brakeman` before calling controller work done.** `bin/ci` does, but the feedback loop
is four seconds on its own, and this one was found by a scan on GitHub rather than locally.

## Blueprints: what a player owns

Progression lives entirely on this side of the boundary, and that is the design rather than an
accident — see [`design_sketches/blueprints.md`](../docs/design_sketches/blueprints.md).

- **`Blueprint` is a derived catalogue, never a hand-written list.** Every registered part,
  operation type, chassis and content archetype is unlockable, enumerated from the simulation's
  own registries. A second list would drift the first time somebody registered a part without
  looking, and it would drift *silently* — the new part simply unreachable, nothing failing.
  `rake blueprints:catalogue` prints it.
- **`Unlock` is `(owner_id, kind, blueprint_id)` and nothing else.** No quantity, no condition,
  no match id: owning a blueprint is the right to mint a **fresh instance**, it is never
  consumed by use, and nothing an instance accumulates comes back. A worn boiler between matches
  does not exist in this model.
- **A chassis id is scoped to its operation** (`steam_engine/high_pressure`). A chassis has no
  standalone existence, and two machines could each name a frame `standard` — unscoped, unlocking
  one would silently unlock the other.
- **The simulation must never learn about ownership.** `Assembly` answers *"will this build
  run?"*; the delivery tier answers *"are you allowed this part?"*. Two validators, and keeping
  them apart is what lets the first stay simple and the second stay testable without a player.
- **The gates live in `config/blueprints.yml`, not in `content/`.** A bill of materials and an
  achievement prerequisite per blueprint. `content/` is the simulation's own YAML and the sim
  must not learn what anything costs — but a bill may *name* a resource the sim knows, and that
  reference is checked when the catalogue builds. Prices are the one part of this system that
  genuinely is data: scalars, no logic, rebalanced constantly, and a rebalance should not be a
  change to `lib/reactor_sim` requiring both dev processes restarted.
- **A blueprint with no entry is an error; `materials: {}` is how something is free.** The
  difference between "decided to be free" and "nobody filled it in" has to survive in the file,
  for the same reason `content_spec` refuses a structural material with no temperature rating.
- **`DevPlayer.earn` goes through the gates; `grant` is an override.** Different words on
  purpose — if the only path bypassed the check, the check would have no live call site and
  would rot. `Achievement.earned?` is a stub returning true, so the gate never closes today; the
  specs prove it is wired by stubbing it `false`.
- **Operations come from `Operations.catalogued`, never `Operations.known`.** A spec rig registers
  globally and `known` includes it, so deriving from `known` made `spec/support/loop_rig.rb` an
  unlockable machine nobody had priced — which took the whole catalogue down, and **only in a
  full-suite run**, because nothing else loads that file.
- **`Blueprint.minions` enumerates the wrong noun and is marked as such.** It lists content
  archetypes — `fireman`, `yardhand` — which are *jobs*, not minions. A player unlocks an
  individual (Jim, Elowynne), each their own upgradable template carrying equipment in three
  slots. Nothing enforces minion ownership, so it cannot mislead anyone yet. Do not build on it;
  see [`design_sketches/minion-sketch.md`](../docs/design_sketches/minion-sketch.md).

> **`rake blueprints:audit` after renaming anything.** Validation refuses to *create* a row
> naming a blueprint that does not exist, but nothing revalidates rows already in the table —
> and stage 3 of the modularisation renamed `:stock_boiler` to `:locomotive_boiler`. A stranded
> row is not a crash; it is a player quietly missing something they earned, which is the class of
> bug that survives for months. The audit is deliberately **not** a boot check: building the
> catalogue reads the content YAML, which `config/initializers/reactor_sim.rb` keeps lazy on
> purpose, and a boot-time database read would be worse still.

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

- **The rdkafka duplication now crashes the process, and which gem wins has INVERTED.** Both
  `rdkafka` and `karafka-rdkafka` are in the lockfile and both define `Rdkafka`. This note used
  to say karafka-rdkafka 0.28.0 won and the duplication was harmless; measured 2026-09-14, it is
  **`rdkafka` 0.29.0** that loads (`Rdkafka::Bindings` resolves into that gem), while
  `karafka-core` 2.6.2 monkey-patches `Rdkafka::Bindings` expecting a constant
  (`RD_KAFKA_RESP_ERR__FATAL`) that 0.29.0 does not define.
  **Consequence: any broker error takes the process down.** The patched error callback raises
  `NameError` on rdkafka's background poll thread, so with Redpanda stopped, one produce is
  enough to kill Puma — which is exactly how this was found. It is latent whenever the broker is
  healthy, which is why it survived this long. Resolve the duplication (almost certainly by
  dropping `gem "rdkafka"`, since karafka-core patches the karafka fork) before the egress
  consumers, and do not reason from the version in the Gemfile.
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
