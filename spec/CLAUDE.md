# `spec/`

```sh
bundle exec rspec                                        # everything (~2.5 min)
bundle exec rspec spec/reactor_sim/conservation_spec.rb  # one file
```

## Two helpers, and the split is load-bearing

- **`spec_helper`** — deliberately Rails-free. It must never load Rails, boot the app, or touch
  a database. Simulation specs use this. A `spec_helper` that quietly booted Rails would let
  the `lib/reactor_sim` boundary rot without anyone noticing.
- **`rails_helper`** — for specs that genuinely exercise the web tier: request specs,
  ViewComponent specs, channel specs. Requires `spec_helper` first.

`.rspec` requires `spec_helper` only, so a sim spec needs no database and no services.

## The specs that guard the invariants

Each of the four invariants has a spec that fails loudly when it is broken. **If you are
changing the engine, run these before anything else** — a violation does not crash, it produces
a match that quietly cannot be recovered or replayed.

The table below is a snapshot; `ls spec/reactor_sim/` is the truth. **A new spec file gets a
row here in the same commit** — this table is how a reader finds out a guard already exists
instead of writing a second one.

| Spec | Guards |
|---|---|
| `purity_spec` | Boots the sim in a bare Ruby subprocess **and** sweeps the source statically |
| `determinism_spec` | Same seed + commands → byte-identical state; snapshot round-trip; idempotence |
| `graph_spec` | Shuffles node and link order and compares digests |
| `conservation_spec` | Mass and energy balance against the ledger |
| `thermal_spec` | Relaxation, ambient loss, rebalancing |
| `content_spec` | Eager validation, mass balance, latent-heat encoding |
| `diagnostic_spec` | The instrument chain, `record` vs `read`, `distortion?` |
| `player_view_spec` | The wire protocol — that merging deltas equals receiving a full view |
| `minion_spec` | The crew, and the actuation seam nothing else can reach |
| `performance_spec` | ~55 ms/tick at 100 nodes against a 250 ms budget |
| `steam_engine_spec` | The operation end to end — startup, output, failure, conservation |

## The delivery tier

`spec/runner/` and `spec/components/` use `rails_helper`.

| Spec | Guards |
|---|---|
| `runner/match_runner_spec` | The tick barrier and command routing — sim vs runner-addressed, and that a bad record cannot kill the loop |
| `requests/commands_spec` | Ingress validation and status codes; that the operation id is stamped server-side, not trusted |
| `runner/view_broadcaster_spec` | The wire envelope, `prev_tick` chaining, and the resync contract |
| `components/instrument_component_spec` | That every gauge carries the `data-` attributes Stimulus writes into |

Component specs assert against the **Nokogiri fragment `render_inline` returns**, not Capybara's
`page` — Capybara is not a dependency and this prototype does not need one.

**The runner spec does not assert timing.** The 4 Hz cadence and drift behaviour are checked by
running `bin/match_runner` and reading its heartbeat, because a spec that asserts on `sleep`
is slow, flaky, and tests the machine's mood. What it does guard is routing, which would
otherwise break in silence.

`spec/environment_spec.rb` asserts infrastructure facts with silent failure modes: the Postgres
test databases, that the sim is requirable from Rails, that **Zeitwerk does not manage the
simulation**, and that development is not on the in-process `async` cable adapter.

> **How the Zeitwerk boundary is enforced changed.** It used to be tested by consequence —
> eager load the app in a fresh process, fail if `ReactorSim` was defined with nobody having
> required it. That proxy died the moment the delivery tier legitimately required the sim
> (`config/initializers/reactor_sim.rb`), because "defined" stopped distinguishing *we asked
> for it* from *Zeitwerk took it*. It now asks Zeitwerk directly, via
> `Rails.autoloaders.main.unloadable_cpaths`, with `ApplicationController` and `DevMatch` as
> positive controls — **without those a typo'd constant name would make the check pass while
> proving nothing.** If you add a consequence-style test, add its control at the same time.

**It asserts nothing about Kafka**, despite what this file and `current_progress.md` used to
claim. The "same-key records land on one partition" check was done by hand. The suite needs no
services running — not Redpanda, and not `docker-compose`.

### Why `minion_spec` builds its own rig

Every steam engine lever has `stiffness: Float::INFINITY`, so `ControlPoint#actuate` snaps
`actual` to `target` and **throws the minion's rate multiplier away before reading it**. The
engine's own specs therefore pass whether or not a minion is ever consulted. A bare rig with a
deliberately stiff lever is the only thing in the suite that can prove the seam is connected —
if you change how the crew reaches `actuate`, that is the file that notices.

## `support/loop_rig.rb`

A deliberately small operation that exercises the whole engine at once: a **closed loop**
(boiler → steam line → condenser → return line → boiler, which no topological order exists
for), pressure-driven phase change, conduction, ambient loss, and back-pressure. Its
diagnostics list is one of each instrument kind.

It is a **test fixture, not a game operation**. Prefer extending it over building a new rig.

## Writing new specs

- **Conservation is the spec that catches real physics bugs.** Write it early, not last.
- Inject an in-memory `Content.build(...)` registry to isolate behaviour — a substance with no
  `phase:` cannot boil, so nothing turns into anything else while you test something unrelated.
- **Spec unused palette pieces too.** An upgrade slot nobody has exercised is one that will not
  work when it is first reached for.
- The suite is slow, dominated by the steam engine's long startup runs. Run one file while
  iterating.

## Debugging a conservation failure

1. Step one tick at a time, recording `Ledger.energy_balance(op.total_joules, op.ledger)`
   before and after.
2. Any tick where the balance moves by more than float noise is the culprit.
3. Diff **per-node** energy (`state[:joules] + Parcel.total_joules(state[:parcels])`) across
   that tick, alongside the ledger deltas.

Both conservation bugs found so far were invisible by inspection. Watch for a node with a huge
`heat_capacity` absorbing energy nothing resets, and for reactions, which conserve *enthalpy*
rather than temperature.
