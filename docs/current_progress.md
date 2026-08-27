# Current progress

Last updated: 2026-08-26. Suite: **114 examples, 0 failures.** Rubocop: clean, 53 files.

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

`spec/reactor_sim/`: `purity`, `determinism`, `conservation`, `thermal`, `graph`, `content`,
`diagnostic`, `performance`, `steam_engine`. Plus `spec/environment_spec.rb` for
infrastructure facts with silent failure modes.

Performance guard: ~55 ms/tick at 100 nodes, against a 250 ms budget.

---

## What does not exist

### The whole delivery tier

- **No match runner.** No `bin/match_runner`, no tick loop, no `runner` line in
  `Procfile.dev`. This is the next thing to build.
- **No Kafka wiring.** `karafka.rb` boots with an empty `routes.draw`. Nothing produces or
  consumes; the runner's rdkafka client does not exist.
- **No web tier.** `app/` is stock `rails new` output. No controllers, channels,
  ViewComponents, or Stimulus.
- **No persistence.** No models, no migrations beyond the Solid schemas.
- **No auth, no lobby, no matchmaking.**

### Simulation features designed but not built

- **Minions.** Work stations are ordinary control points. The seams are reserved:
  `ControlPoint#stiffness` for actuation lag, `Diagnostic#observer` for who is reading a
  gauge. Commands must keep setting *targets* when this lands.
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

---

## What to do next

In dependency order. Steps 1–4 are the vertical slice that makes it playable.

1. **Match runner** — monotonic 4 Hz loop in `bin/match_runner`, no Kafka yet, state to
   stdout. Add `runner:` to `Procfile.dev` once it exists.
2. **Command ingress** — `POST /matches/:id/commands` → produce to `match.commands` → drain at
   the tick barrier with a non-blocking `poll(0)`. Use `max_wait_timeout_ms`, not the
   deprecated `max_wait_timeout`.
3. **Telemetry out** — `project` → `delta_from` → ActionCable. Broadcast **synchronously**
   from the runner; `broadcast_*_later` routes through Solid Queue's 1 s polling.
4. **Full-view path** — subscribe, resync and spectate are one mechanism.
5. **Snapshots + offset commits** — snapshot to `match.snapshots` embedding the command
   offset, *then* commit. Then the crash-recovery drill.
6. **Turbo incident broadcasts** — the first ViewComponent that earns its keep.
7. **Minions**, then the deferred failure modes, then Chemical Vats.

Architectural detail for 1–6 is in [`architecture.md`](architecture.md) §6–§10; it was written
before the simulation rewrite but is unaffected by it.

---

## Traps that have already cost time

Every one of these was a real bug. They are documented where they matter, but collected here
because they are the kind a fresh reader repeats.

- **Symbols as *values* do not survive JSON.** Resource ids in parcels and flags in instrument
  state both broke this way. `Operation#restore` normalises them.
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
- **`config/cable.yml` must not use the `async` adapter in development.** It is in-process
  only, so a runner broadcasting from its own process reaches nobody, silently.

---

## Repository state

Not committed. `git status` shows the entire simulation rewrite, the steam engine, `content/`
and `docs/` as uncommitted work on `main`. The last commit is `a26631b architecture looking
better`, which predates the current paradigm.
