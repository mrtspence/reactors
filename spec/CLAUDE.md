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
| `assembly_spec` | Slots, parts, loadouts and the validator. **Two halves on purpose**: a deliberately tiny two-vessel registry, so which rule fired is never in doubt, then the same machinery pointed at the real engine — a mechanism that works on a toy and not on the thing it was built for has proved nothing. Guards the id contract (`provides:`), the flat-namespace collision naming *both* slots, reachability through the real `Path` router, and **the error/warning split**, which is the game's risk/reward axis rather than two severities. Also the loadout's three snapshot traps: string part ids, a partial loadout re-defaulting, and `:none`. **`OPTIONAL` is written out rather than derived from the slots**, so a slot quietly becoming optional — or quietly ceasing to be — fails a spec instead of passing one; the converse example empties every *required* slot and insists each is refused. Since instruments became parts it also guards **`PANEL_ORDER`**: that a gauge a part *supplied* still lands where the panel says rather than at the end, and that every catalogued gauge has a place. Note that "takes its own pieces with it" counts every list plus the diagnostics, not `fragment.nodes` — an instrument part brings no nodes at all |
| `content_spec` | Eager validation, mass balance, latent-heat encoding. Also that **every `:structural` material carries a `max_temperature_k`** — a missing one is silent and total, and is why over-temperature fatigue existed from the day `Wearing` landed and had never once fired |
| `steam_engine_spec` → "the grate silts up" | The ash choke and its remedy. **Asserts its own precondition** — `headroom_pa > 10 kPa`, i.e. the drum is off its safety valve — because a pinned boiler reports every upstream change as zero and that reads exactly like a broken mechanic. It broke twice on a pinned `damper:` value before this, once when the stoker was re-rated and once when the damper conductance moved. The `× 1.01` floor on the recovery is there so noise cannot pass |
| `steam_engine_spec` → "running without the safety devices" | The claim modularisation rests on: that going without a safety device is a **decision**, not a strictly-worse choice. Four slow examples, and they earn it — no safety valve is **+13% pressure and +13% speed** (687.0 kPa / 196.6 rpm against 608.0 / 174.5), no cylinder relief **wrecks the cylinder on an ordinary startup**, no blower never raises steam at all, no boiler tubes will not turn the engine. **Three other optional parts show no effect here and that is correct** — the ashpan, the cocks and the plug have slow or conditional hazards and are covered where those conditions are reached. Assert the *relationship*, not a pinned figure, for the reason the ashpan example records |
| `steam_engine_spec` → "water in the cylinder" | Warming through as a **procedure**: that leaving the cocks shut fills the cylinder with its own condensate (peak occupancy 0.859, "knocking badly", relief valve lifting, no damage) and that opening them and shutting them again stays dry at full power. **Assert the peak, not the end state** — the water is swept out the moment the engine is turning properly, so an end-state assertion passes on a startup that had been knocking badly the whole way up. `light_and_run` takes `each_tick:` for exactly this |
| `crown_sheet_spec` | The low-water hazard: that the plate is at water temperature while covered and costs nothing, that starving the feed uncovers it and blows the fusible plug, that **the plug goes before the plate does** (620 K against 750), that it stays melted once melted, and that the gauge glass reads high while the plate is already bare. Also the other half of the plug's story: **take it off and the same run explodes the drum** and spills it, which is the end-to-end proof that the failure model fires in a real machine rather than only in a rig. **Requires `reactor_sim` directly** — `spec_helper` alone does not load the sim. **The most expensive file in the suite at ~12 min**, because every example runs the engine into the hazard from cold |
| `diagnostic_spec` | The instrument chain, `record` vs `read`, `distortion?` |
| `player_view_spec` | The wire protocol — that merging deltas equals receiving a full view |
| `minion_spec` | The crew, and the actuation seam nothing else can reach |
| `failure_spec` | The failure contract independent of any machine: that `failure` is a **mode**, that `broken?` derives from it (and answers for a node with no `Wearing`), that a mode survives JSON **as a Symbol**, that escalation only moves forward and emits only on a transition, and that the boiler's mode splits on conditions rather than on `cause`. The identity assertion is the point — it was checked by disabling the normalisation, and the round-trip *digest* comparison in the same file still passed with the bug live. **Walks every catalogued operation on every chassis** (44 wearing nodes today) and fails any part left on `Wearing::GENERIC_FAILURE`, which is the guard that keeps the fallback from becoming a silent off switch. Also the `Breach` rig: shut costs nothing, opens by the mode's size, stays shut for a mode it does not name, books `mass_spilled` rather than `mass_vented`, and conserves both balances across a burst. **Two assertions in it were wrong before they were right** — a drum empties to *ambient*, not to zero, and total spill *saturates*, so sizes must be compared by what is left rather than by what came out |
| `ignition_spec` | That a fire needs a spark, spreads in a cold box, and dies without air |
| `performance_spec` | ~55 ms/tick at 100 nodes against a 250 ms budget |
| `steam_engine_spec` | The operation end to end — startup, output, wire-drawing, failure, conservation. **Move one lever per example**: it used to raise the throttle and the stoking together and passed on the balance between two effects that oppose each other. Also **check the engine is not saturated before asserting on power** — `LIGHT`'s damper 85 puts the drum at 608.0 kPa against a 607.95 kPa relief setting, so it feathers its safety valve continuously and every upstream change reads as zero. The ashpan example recovers 397.3 vs 380.4 kW at damper 60 and ±1 kW of noise at 70, 78 and 85; it passed for a long time only because the fire was oversized enough to be choked and still saturate. Pass `damper:` to `light_and_run` to get off the valve |

## The delivery tier

`spec/runner/` and `spec/components/` use `rails_helper`.

| Spec | Guards |
|---|---|
| `runner/match_runner_spec` | The tick barrier and command routing — sim vs runner-addressed, and that a bad record cannot kill the loop |
| `requests/commands_spec` | Ingress validation and status codes; that the operation id is stamped server-side, not trusted |
| `requests/loadouts_spec` | The outfitting screen, and **the order behind the button — validate, store, reset**. Guards the two things that order prevents: a build the validator refused reaching the database, and a refused build reaching the runner. Also that the loadout rides **inside** the reset command rather than being referenced by it, that an unchecked slot arrives as an explicit nil rather than re-defaulting, and that the panel follows the loadout (18 instruments → 16 with the safety valve off). Plus **the second validator**: a part the player has not unlocked is refused *when posted directly*, because the dropdown filter is a courtesy and the form is a plain POST — and a locked part that is already fitted is still shown, flagged, since hiding it would report an error about something the player cannot see. **`Assembly`'s own verdict stays `ok?` throughout**, which is the assertion that keeps ownership out of the simulation. Finally the shapes `permit!` used to admit — an Array, a Hash, a bare String, a number — each of which reached `Array#to_sym` and 500'd on the draft action |
| `runner/view_broadcaster_spec` | The wire envelope, `prev_tick` chaining, and the resync contract |
| `components/instrument_component_spec` | That every gauge carries the `data-` attributes Stimulus writes into |
| `models/blueprint_spec` | Derived from `Operations.**catalogued**`, not `known`: a spec rig registers globally and became an unlockable machine nobody had priced, which took the whole catalogue down — **only in a full-suite run**, because nothing else loads `spec/support/loop_rig.rb`. That the unlock catalogue is **derived from the simulation's registries and never written down** — one part blueprint per registered part, one per operation type, one per content archetype — because a hand-maintained list drifts *silently*, leaving a new part simply unreachable. Also that a chassis id is scoped to its operation (`steam_engine/high_pressure`), so two machines that each name a frame `standard` cannot share an unlock, and that a real part id is not findable under the wrong kind. Plus **the gates**: every blueprint priced, bills denominated only in resources `content/` has, an unpriced blueprint raising rather than being free, and `materials: {}` as the written-down way to *be* free. The achievement gate is specced by stubbing `Achievement.earned?` **false** — it always returns true, so without that the check would be indistinguishable from a method that returns true |
| `models/unlock_spec` | That a row **cannot be created naming a blueprint that does not exist**, and — the half that matters more — that a row a *rename* stranded can still be found afterwards. Stage 3 renamed `:stock_boiler` to `:locomotive_boiler`, and nothing revalidates rows already in the table; a stale one is not a crash but a player quietly missing what they earned. `insert_all` is used deliberately, because that is what a rename does |

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

## Tune a spec's constants through the SPEC's rig, not a scratch script

A scratch script and a spec diverge silently through **defaults nobody wrote down**, and the
divergence does not announce itself — it just produces a number that does not transfer.

Measuring the ashpan example's damper setting in a scratch script gave 35, and in the spec that
was still 4.4 kPa from the safety valve and could measure nothing. The cause was one line that was
never *written* in either place: the script set `cutoff: 40`, while `light_and_run` leaves cut-off
at its `ControlPoint` default of **100 — full gear**, which is a materially different engine
(517 kW against 364 kW at the same margin). Re-measured through `light_and_run` itself, the
answer was damper 30.

So when a value will end up inside an assertion, drive the sweep through the spec's own helper
and its own `engine` constructor. `Match.create` vs `SteamEngine.build`, the seed, and every
lever the helper does *not* set are all places the two rigs can quietly part company.

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
