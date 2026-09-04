# Current progress

Last updated: 2026-08-29. Suite: **143 examples, 0 failures.** Rubocop: clean, 80 files.

---

## Where the project is

The **simulation is real and working**. The Rails delivery tier is scaffolded but essentially
untouched — nothing in `app/` has been written yet.

```
DONE      simulation engine (lib/reactor_sim)     — physics, graph, diagnostics
DONE      one playable operation                  — the steam engine, two variants
DONE      infrastructure                          — Postgres, Redpanda, topics, gems
NOT DONE  everything that makes it a game         — runner, Kafka wiring, web tier, minions
```

There is no way to *play* it yet. You can drive an operation from Ruby and watch it work.

---

## What exists

### Simulation core

Eight-phase tick with settlement for mass, heat and momentum; closed-form integrators
throughout; exact conservation with a ledger. Concerns: `Thermal`, `Holds`, `Wearing`,
`Pressurized`, `Rotating`. Stock nodes: `Vessel`, `Conduit`, `Atmosphere`, `Flywheel`,
`Load`, `Cylinder`, `ReliefValve`.

Content system loading resources, reactions and materials from YAML with eager validation.
Phase change (saturation, solved jointly with pressure) and rate-limited chemistry.

Diagnostics as `Source → Filters → Display`, with player and spectator projections and delta
compression.

### The steam engine

`Operations::SteamEngine`, in two variants from one definition — Watt atmospheric and
Trevithick high-pressure. The architectural thesis from
[`design_sketches/boiler.md`](design_sketches/boiler.md) holds: same parts, different wiring,
two machines that behave like their historical counterparts.

Working skill gradient at `time_scale 1.0`:

| throttle / load / stoking | outcome |
|---|---|
| 45 / 70 / 45 | survives, never starts — not enough steam |
| **60 / 80 / 60** | **survives indefinitely, ~101 rpm, ~77 kW** |
| 80 / 90 / 70 | ~508 kW, flywheel bursts |
| 100 / 100 / 80 | ~683 kW, flywheel bursts sooner |

Startup is a real procedure: light with the damper nearly shut, wait for the fire to catch,
kill the igniter, open the throttle, *then* engage the load.

### Infrastructure

Postgres (4 databases × 3 envs, socket auth), Redpanda via `docker-compose.yml` with four
topics created by `script/create_topics.sh` (`match.commands`, `match.events`,
`match.snapshots` compacted, `match.lifecycle`), `rdkafka` + `karafka` installed, RSpec,
Tailwind standalone, importmap. Entirely Node-free.

Verified end to end: same-key records land on one partition and are consumed in order.

### Specs

`ls spec/reactor_sim/` is the truth; at the time of writing: `purity`, `determinism`,
`conservation`, `thermal`, `graph`, `content`, `diagnostic`, `minion`, `player_view`,
`performance`, `steam_engine`. Plus `spec/environment_spec.rb` for infrastructure facts with
silent failure modes.

Note that `environment_spec` asserts Postgres, the sim boundary and the cable adapter — **not
Kafka.** The "same-key records land on one partition" check above was done by hand; nothing in
the suite guards it, and the suite needs no services running.

Performance guard: ~55 ms/tick at 100 nodes, against a 250 ms budget.

---

## What does not exist

### The whole delivery tier

Being built now, as a minimal end-to-end prototype. **Done:**

- **The match runner.** `bin/match_runner` runs `MatchRunner` in its own process from
  `Procfile.dev`, at a measured 4.00 Hz with 0.1–0.2 ms drift over 215 ticks. It holds one
  hardcoded match (`DevMatch`), applies commands at the tick barrier, steps, and publishes to
  an injected sink.

- **Command ingress over Kafka.** `POST /matches/:id/commands` validates, produces to
  `match.commands` keyed by `match_id`, and answers 202 without waiting on the broker. The
  runner drains with a non-blocking `poll_batch_nb(0)` at the tick barrier. Verified against a
  real Redpanda: a two-command burst landed on one partition in order, the levers moved, and
  the fire lit (firebox 447 K → 831 K over 40 ticks). A deliberately malformed record produced
  straight onto the topic was rejected — "3 applied, 1 rejected" — without touching the loop.
- **Reset**, as a `reset_match` record on the same topic, so it stays ordered against the
  levers.

- **Telemetry out.** `ViewBroadcaster` projects, deltas against the last view, and broadcasts
  over ActionCable in an explicit `{kind, tick, prev_tick, view}` envelope. Unchanged ticks are
  skipped, a full view is resent every 40 ticks, and `resync` forces one on demand. Verified
  cross-process: 25 messages written by the runner and read from Postgres by another process,
  1 full + 24 deltas, deltas carrying one changed gauge instead of twelve.
- **The console page.** `ConsolesController` renders chrome only — 12 instruments, 7 levers,
  2 crew — from `DevMatch.panel`. ViewComponents dispatch on chrome kind; `console_controller.js`
  merges deltas, drives needles through a CSS custom property, and does optimistic levers with
  a 2 s timeout.

**Verified end to end**: browser-shaped HTTP with CSRF → 202 → Kafka → runner → sim → cable,
raising steam from 2.9 kPa to 146.9 kPa with the firebox at 1078 K, while a malformed command
was refused with 422 and never reached the topic.

**Not yet:**

- **No snapshots, no offset-after-snapshot ordering, no recovery, no rebalance handling.**
  Auto-commit means a crash can lose ~5 s of commands, and a runner restart loses the match.
- **No Turbo Stream incidents.** They ride inside the JSON projection instead, which is a
  deliberate deviation from `architecture.md` §7 for the prototype.
- **No browser test.** The page has been fetched and asserted on, but nothing drives a real
  browser, so the JavaScript is verified by reading rather than by running.
- **Nothing produces to `match.events`.** Incidents exist only inside whatever projection is
  broadcast, so a spectator joining a tick later never learns the flywheel burst.
- **`karafka.rb` still boots with an empty `routes.draw`.** No egress consumers.
- **No persistence.** No models, no migrations beyond the Solid schemas — and the prototype
  deliberately needs none.
- **No snapshots or recovery.** A runner restart loses the match.
- **No auth, no lobby, no matchmaking.** Anyone who can reach the endpoint can drive the
  engine.

### Simulation features designed but not built

- **Minions — partly built.** `Minion` exists, archetypes load from `content/minions/`, state
  is `{health, fatigue, station}`, `assign_minion` is a command, and phase 0 consults the crew
  through `ControlPoint#actuate(rate_multiplier:)`. The steam engine has a fireman and a
  yardhand.
  **They are inert on purpose:** every steam engine lever keeps `stiffness: Float::INFINITY`,
  which discards the multiplier, so the measured skill gradient is untouched. Still missing —
  what makes fatigue accrue and health decline (nothing does, so a minion never tires);
  intelligence and the `Diagnostic#observer` gauge-reading path; skills and tags; a rule for
  an unmanned lever (currently full rate) and for two minions at one station (last writer
  wins). Every one is marked `TODO` at the code.
- **`ControlLink`** — one node sensing another as a declared, breakable graph edge. Needed for
  a governor that can fail on.
- **Failure modes** from `design_sketches/boiler.md`: governor fail-on, hot box / bearing
  seizure, crankshaft fatigue fracture. Hydro-locking is *detectable*
  (`Cylinder#liquid_fraction`) but has no consequence.
- **Chemical Vats** — deleted with the old paradigm, to be rebuilt on the new one.

---

## Known gaps and rough edges

| Gap | Detail |
|---|---|
| Condensate cannot leave a gas-only line | Steam condensing in a cooling pipe is liquid in a gas-only conduit, permanently. Real plants fit steam traps; undecided whether the answer is a `SteamTrap` node, a port accepting a phase pair, or an accumulating hazard. |
| Non-condensables ignored in the phase solve | `Saturation` accounts only for the pair being solved, so air sharing a vessel with boiling water would not raise its boiling point. |
| Pressure model is minimal | Ideal gas over free volume. No pump head, hydrostatic term, or flow-induced pressure drop. |
| Phase solve dominates the tick | ~50% of a 100-node step. `Saturation::ITERATIONS` (currently 20) is the dial. |
| `min_temperature_k` is a modelling compromise | Means "bulk temperature at which the reaction sustains", not ignition — a lumped-temperature node has no hot spot to light. |
| Suite is slow | ~2.5 min, dominated by the steam engine's long startup runs. |
| The atmospheric engine's condenser is capacity-limited | ~0.18 kg/tick of steam, set by `ambient_conductance × ΔT` over the latent heat. Fed the high-pressure draught it cannot keep up and the vacuum it exists to pull collapses, so the variant runs a smaller fire (`draught_kg_per_s: 4.0`). **Investigated and NOT a phase-solve bug** — in isolation a cold vessel condenses 2.3 kg of steam to 0.26 kg over 12 ticks, pressure falling 104 → 12 kPa. A more powerful Watt engine needs a bigger condenser, not a fix. |

---

## What to do next

Steps 1–4 of the original vertical slice are **done** — the prototype is playable in a browser.
What remains, in dependency order:

1. **Play it.** The whole point of the prototype. Drive the startup procedure by hand, find out
   whether the skill gradient is legible through instruments rather than through `telemetry`,
   and whether 250 ms feels responsive.
2. **Snapshots + offset commits** — snapshot to `match.snapshots` embedding the command offset,
   *then* commit. Then the crash-recovery drill. This is the largest deferred piece and the one
   the `auto.offset.reset: latest` shortcut is standing in for.
3. **`match.events`** — incidents currently exist only inside whatever projection is broadcast,
   so a spectator joining a tick later never learns the flywheel burst.
4. **Turbo incident broadcasts** — the first ViewComponent that earns its keep, replacing the
   client-side incident list.
5. **Match lifecycle** — real creation, `match.lifecycle`, and the end of `DevMatch`. This is
   also what retires the "web process rebuilds a Match to get the panel" shortcut.
6. **Auth**, then the deferred minion work (fatigue, the `observer` gauge path, finite lever
   stiffness), then the failure modes from `design_sketches/boiler.md`, then Chemical Vats.

### From the first playtest (2026-09-03)

In rough priority order. The first two are the ones that most damage the game as a game.

1. ~~**Ignition is not modelled; the igniter is a throttle.**~~ **Done.** `Resources::Ignition`
   carries the lit fuel mass per node; the igniter seeds it and the fire spreads, banks and can
   be nursed back. Measured: the igniter is held for ~150 ticks and then never again, and the
   engine reaches 440 K / 747 kPa, 72 rpm, 54 kW on its own. See
   [`design_sketches/ignition.md`](design_sketches/ignition.md) for the three things the sketch
   got wrong, and [`reference/physics.md`](reference/physics.md#ignition) for what is true now.
   The firebox draught widened from 4 to 8 kg/s to go with it — the fire now has to raise steam
   itself, where a permanently-held 2.5 MW igniter was quietly doing a third of it.
2. **Incidents have no consequence.** A player can power through a vessel rupture and a
   flywheel burst and keep going, provided the igniter stays on. `broken` stops a node planning
   but evidently does not stop the machine being useful. Until this bites, the whole
   accumulated-stress model is decoration.
3. **The UI is opaque.** No tooltips, no explanation of what any gauge or lever does. Fine for
   someone who knows the simulation, useless to anyone else. Wants hover copy per instrument
   and per lever — which likely means the operation declaring a description alongside each
   diagnostic and control point, rather than the view layer inventing one.
4. **Period-2 limit cycles, and the starvation they cause. Needs a proper investigation —
   this is the most load-bearing item on the list.**

   **Investigated and written up in
   [`design_sketches/flow_through_issue_draft.md`](design_sketches/flow_through_issue_draft.md)**
   (2026-09-03) — mechanism, measurements and diagrams. A solution is proposed in
   [`design_sketches/transport_model.md`](design_sketches/transport_model.md): **mass joins
   `Relaxation`** alongside heat and rotation, conduits become zero-residence but still failable
   nodes, and `cap_gas_by_pressure` is deleted rather than fixed. Awaiting review; nothing built.
   Three findings that were
   not known when the summary below was written: the oscillation is **undamped by construction**
   (`Conduit#plan`'s inventory map is `h ↦ T − h`, an involution with eigenvalue −1);
   `Arbiter.cap_gas_by_pressure` **amplifies** it by sampling both ends of a link in antiphase,
   making the saturated full/empty orbit an attractor; and a conduit therefore delivers only
   about **half its rated throughput**. There is also a third instance, live and unfixed: the
   **Draught gauge can only ever read "choked"**, on either variant, at any lever setting.

   Two confirmed instances, both from the one-tick-per-hop delay:

   - **The cylinder.** Indicated power alternates 14.9/21.4 kW and cylinder pressure 157/184
     kPa on successive ticks, indefinitely. It sizes its draw to equalise with the throttle's
     *previous* pressure, empties it, and finds it refilled a tick later.
   - **The firebox draught.** Air alternates 0.84 kg / 0.000 kg every tick. This one did real
     damage: `Ignition` read the instantaneous inventory, concluded "starved" every other tick,
     and killed the fire two ticks at a time — on a fire consuming barely 1% of the air blowing
     past it.

   **The generalisation is the dangerous part.** Any node that reads an *instantaneous
   inventory* of a **flow-through** quantity will hit this, because the standing amount of
   something passing through a node is not a measure of its supply. The failure is silent: no
   error, no conservation violation, just a system that quietly starves.

   Two workarounds are in place and neither addresses the cause:
   `Filters::Average` settles the gauges, and `Ignition` keeps a short memory of the draught.
   The memory is independently justifiable — a fuel bed genuinely does have thermal inertia —
   but it should not have been *necessary*.

   Worth investigating: whether the oscillation can be damped at source (a node sizing a draw
   against a supply it reads one tick late is the common shape); whether nodes should expose a
   *flow* rather than an inventory for this kind of question; and whether anything else already
   reads an inventory where it means a rate. What ignition taught us — that supply must be
   judged against demand, over a window, not against zero — is probably the reusable part.

Every shortcut taken for the prototype is marked `TODO:` at the code with what it does, why,
and what a proper implementation must solve. `grep -rn "TODO:" app/ lib/ content/` is the list.

Architectural detail for 1–6 is in [`architecture.md`](architecture.md) §6–§10; it was written
before the simulation rewrite but is unaffected by it.

---

## Traps that have already cost time

Every one of these was a real bug. They are documented where they matter, but collected here
because they are the kind a fresh reader repeats.

- **Symbols as *values* do not survive JSON.** Resource ids in parcels and flags in instrument
  state both broke this way. `Operation#restore` normalises them.
- **A sparse hash cannot express a removal by diffing.** `PlayerView#flags` omits instruments
  with nothing to say, so rejecting unchanged entries never mentioned a flag that *cleared* —
  a merging client showed `:pegged_high` forever, and `:warming_up` from the first few ticks
  of every match never went away. `delta_from` now emits an explicit empty list.
- **Coerce a value before it reaches the simulation.** `Command.parse` passed `value` through
  untouched; `ControlPoint#set_target` calls `.to_f` on it; a Hash does not answer to that, so
  one malformed record killed the runner process and every match on it.
- **Builder options must be in `options:`** or a restored snapshot rebuilds a different
  machine.
- **Gases are limited by pressure, not volume** — and `Holds#room_m3` and `Arbiter#volume_of`
  must agree. Fixing one alone throttles every duct.
- **An active sink's declared draw is authoritative.** `max(push, draw)` let a sink be
  overwhelmed by its supply.
- **An empty vessel is a vacuum (0 Pa)**, not one atmosphere.
- **Reactions conserve enthalpy, not temperature**, and their energy release must be ledgered.
- **Never replace a closed-form integrator with explicit Euler.** `time_scale` is a design
  dial; Euler returns negative Kelvin at `dt = 100 s`.
- **Rails 8.1 autoloads `lib` by default.** `config.autoload_lib(ignore:)` must list both
  `reactor_sim` and `reactor_sim.rb` — the ignore list matches exact paths.
- **A test-by-consequence dies quietly when its premise changes.** The Zeitwerk boundary check
  asserted that eager loading did not *define* `ReactorSim`; that stopped meaning anything once
  the delivery tier legitimately required the sim. It now asks
  `Rails.autoloaders.main.unloadable_cpaths` directly, with positive controls so a typo cannot
  make it pass vacuously.
- **`config/cable.yml` must not use the `async` adapter in development.** It is in-process
  only, so a runner broadcasting from its own process reaches nobody, silently.
- **`require "rdkafka"` loads `karafka-rdkafka`, not the `rdkafka` gem.** Both are in the
  lockfile and both define `Rdkafka`; karafka-rdkafka 0.28.0 wins, making the Gemfile's
  `gem "rdkafka", "~> 0.19"` inert. `poll_batch_nb` happens to exist in both, so nothing broke
  — but do not reason about the API from the version in the Gemfile.
- **rdkafka handles are not fork-safe.** One built before Puma forks is inherited broken and
  produces silently vanish. Build clients lazily, memoised per process id.
- **Never close an rdkafka handle inside a signal trap.** FFI plus a background polling thread
  means it deadlocks. A handler may only set a flag.

---

## Repository state

Not committed. `git status` shows the entire simulation rewrite, the steam engine, `content/`
and `docs/` as uncommitted work on `main`. The last commit is `a26631b architecture looking
better`, which predates the current paradigm.
