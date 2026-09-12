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
| `transport_spec` | That a conduit holds nothing, delivers its **full** rating, and leaves no node alternating — plus path resolution, chains, cycles and dead ends. Also the gas solver: two vessels equalise at **every** conductance, flow reverses when the gradient does, a check valve refuses to, and the same interval settles the same at any `dt` |
| `conservation_spec` | Mass and energy balance against the ledger |
| `thermal_spec` | Relaxation, ambient loss, rebalancing |
| `transport_affinity_spec` | `Node#transport_affinity` — that a neutral opinion is **bit-identical** to no opinion, that a weight changes the mix and never the total on a rate-driven path, the max-within-a-port / product-across-ports combining rule, and that `Boiler` declares a steam quality rather than the unguessable multiplier. **Built on an inert two-liquid registry**: a rig made of real water measures evaporation as well as apportionment, and drifted 90% → 82% while nothing under test had moved |
| `steam_engine_spec` → "priming and hydraulic lock" | The failure chain end to end: flood the glass while running hard, slam the regulator, and the drum swells past its offtake into the cylinder. **Assert the peak, not the end state** — a broken cylinder declares `Intent.none` and drains, so it read 0.21 on a run that had been at 4.06 and was already destroyed |
| `entrainment_spec` | `Arbiter.entrained` — the **pressure-driven** half of settlement, which had no coverage of any kind until the cylinder relief valve was found to pass water in exactly zero states. That the gas figure the solve settled survives any weight the clamp allows, that liquid is additive but bounded by the bore, and that a path with no declared opinion still passes what is in it. **Its rig declares a `conductance:` and that is the entire point** — `transport_affinity_spec`'s does not, which is why all 13 of its examples test the other branch |
| `obstruction_spec` | `Concerns::Obstructs` — occupancy against a **characteristic** volume, the derived top-dead-centre pressure, hydraulic lock graded by the driveline's stored energy, and that a relief valve sensing the wrong quantity stays shut on a state that would destroy the part. Also the concern's second caller, a bed choked by its own ash — **if it only ever had one it would not have earned a file** |
| `content_spec` | Eager validation, mass balance, latent-heat encoding. Also that **every `:structural` material carries a `max_temperature_k`** — a missing one is silent and total, and is why over-temperature fatigue existed from the day `Wearing` landed and had never once fired |
| `steam_engine_spec` → "water in the cylinder" | Warming through as a **procedure**: that leaving the cocks shut fills the cylinder with its own condensate (peak occupancy 0.859, "knocking badly", relief valve lifting, no damage) and that opening them and shutting them again stays dry at full power. **Assert the peak, not the end state** — the water is swept out the moment the engine is turning properly, so an end-state assertion passes on a startup that had been knocking badly the whole way up. `light_and_run` takes `each_tick:` for exactly this |
| `crown_sheet_spec` | The low-water hazard: that the plate is at water temperature while covered and costs nothing, that starving the feed uncovers it and blows the fusible plug, that **the plug goes before the plate does** (620 K against 750), that it stays melted once melted, and that the gauge glass reads high while the plate is already bare. **Requires `reactor_sim` directly** — `spec_helper` alone does not load the sim |
| `diagnostic_spec` | The instrument chain, `record` vs `read`, `distortion?` |
| `player_view_spec` | The wire protocol — that merging deltas equals receiving a full view |
| `minion_spec` | The crew, and the actuation seam nothing else can reach |
| `ignition_spec` | That a fire needs a spark, spreads in a cold box, and dies without air |
| `performance_spec` | ~55 ms/tick at 100 nodes against a 250 ms budget |
| `steam_engine_spec` | The operation end to end — startup, output, wire-drawing, failure, conservation. **Move one lever per example**: it used to raise the throttle and the stoking together and passed on the balance between two effects that oppose each other. Also **check the engine is not saturated before asserting on power** — `LIGHT`'s damper 85 puts the drum at 608.0 kPa against a 607.95 kPa relief setting, so it feathers its safety valve continuously and every upstream change reads as zero. The ashpan example recovers 397.3 vs 380.4 kW at damper 60 and ±1 kW of noise at 70, 78 and 85; it passed for a long time only because the fire was oversized enough to be choked and still saturate. Pass `damper:` to `light_and_run` to get off the valve |

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
