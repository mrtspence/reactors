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
| `steam_engine_spec` → "priming and hydraulic lock" | The failure chain end to end: flood the glass while running hard, slam the regulator, and the drum swells past its offtake into the cylinder. **Assert the peak, not the end state** — a broken cylinder declares `Intent.none` and drains, so it reads 0.21 at the end of a run that peaked at 4.06 and was destroyed by it |
| `entrainment_spec` | `Arbiter.entrained` — the **pressure-driven** half of settlement. That the gas figure the solve settled survives any weight the clamp allows, that liquid is additive but bounded by the bore, and that a path with no declared opinion still passes what is in it. **Its rig declares a `conductance:` and that is the entire point** — `transport_affinity_spec`'s does not, which is why all 13 of its examples test the other branch |
| `obstruction_spec` | `Concerns::Obstructs` — occupancy against a **characteristic** volume, the derived top-dead-centre pressure, hydraulic lock graded by the driveline's stored energy, and that a relief valve sensing the wrong quantity stays shut on a state that would destroy the part. Also the concern's second caller, a bed choked by its own ash — **if it only ever had one it would not have earned a file** |
| `assembly_spec` | Slots, parts, loadouts and the validator. **Two halves on purpose**: a deliberately tiny two-vessel registry, so which rule fired is never in doubt, then the same machinery pointed at the real engine — a mechanism that works on a toy and not on a real machine has proved nothing. Guards the id contract (`provides:`), the flat-namespace collision naming *both* slots, reachability through the real `Path` router, and **the error/warning split**, which is the game's risk/reward axis rather than two severities. Also the loadout's three snapshot traps: string part ids, a partial loadout re-defaulting, and `:none`. **`OPTIONAL` is written out rather than derived from the slots**, so a slot quietly becoming optional — or quietly ceasing to be — fails a spec instead of passing one; the converse example empties every *required* slot and insists each is refused. Also guards **`PANEL_ORDER`**: that a gauge a part *supplied* still lands where the panel says rather than at the end, and that every catalogued gauge has a place. Note that "takes its own pieces with it" counts every list plus the diagnostics, not `fragment.nodes` — an instrument part brings no nodes at all |
| `content_spec` | Eager validation, mass balance, latent-heat encoding. Also that **every `:structural` material carries a `max_temperature_k`** — a missing one is silent and total, and is why over-temperature fatigue existed from the day `Wearing` landed and had never once fired |
| `steam_engine_spec` → "the grate silts up" | The ash choke and its remedy. **Asserts its own precondition** — `headroom_pa > 10 kPa`, i.e. the drum is off its safety valve — because a pinned boiler reports every upstream change as zero and that reads exactly like a broken mechanic. A pinned `damper:` value instead breaks whenever the stoker rating or the damper conductance moves. The `× 1.01` floor on the recovery is there so noise cannot pass |
| `steam_engine_spec` → "running without the safety devices" | The claim modularisation rests on: that going without a safety device is a **decision**, not a strictly-worse choice. Four slow examples, and they earn it — no safety valve is **+13% pressure and +13% speed** (687.0 kPa / 196.6 rpm against 608.0 / 174.5), no cylinder relief **wrecks the cylinder on an ordinary startup**, no blower never raises steam at all, no boiler tubes will not turn the engine. **Three other optional parts show no effect here and that is correct** — the ashpan, the cocks and the plug have slow or conditional hazards and are covered where those conditions are reached. Assert the *relationship*, not a pinned figure, for the reason the ashpan example records |
| `steam_engine_spec` → "water in the cylinder" | Warming through as a **procedure**: that leaving the cocks shut fills the cylinder with its own condensate (peak occupancy 0.859, "knocking badly", relief valve lifting, no damage) and that opening them and shutting them again stays dry at full power. **Assert the peak, not the end state** — the water is swept out the moment the engine is turning properly, so an end-state assertion passes on a startup that knocked badly the whole way up. `light_and_run` takes `each_tick:` for exactly this |
| `crown_sheet_spec` | The low-water hazard: that the plate is at water temperature while covered and costs nothing, that starving the feed uncovers it and blows the fusible plug, that **the plug goes before the plate does** (620 K against 750), that it stays melted once melted, and that the gauge glass reads high while the plate is already bare. Also the other half of the plug's story: **take it off and the same run explodes the drum** and spills it, which is the end-to-end proof that the failure model fires in a real machine rather than only in a rig. **Requires `reactor_sim` directly** — `spec_helper` alone does not load the sim. **The most expensive file in the suite at ~12 min**, because every example runs the engine into the hazard from cold |
| `diagnostic_spec` | The instrument chain, `record` vs `read`, `distortion?`. Also that the water-gauge **tiers are a real progression** — mean misreading against the spectator's truth, ordered rather than pinned, because pinning figures makes every balance change a failure. It exists because both tiers shipped broken the first time: try-cocks never moved at all, and the reflex glass cut noise below the display's own precision. **~90 s**, four engine runs |
| `player_view_spec` | The wire protocol — that merging deltas equals receiving a full view |
| `minion_spec` | The crew, and the actuation seam nothing else can reach |
| `event_spec` | The durable record's contract, none of which was specced before it existed. That the vocabulary has no duplicate and — **derived by scanning the library for `Event.build(type: :name)`, never written out** — no entry nothing emits, because a type a consumer waits on forever is indistinguishable from an achievement nobody has earned. That imposes one rule on emitters: **spell the type literally**, so a computed `type:` cannot slip past the check. And the load-bearing one: **replaying from a snapshot re-emits the same events in the same order**, which is what makes `(match_id, run_id, operation_id, tick, seq)` a safe dedupe key and at-least-once delivery harmless |
| `services/progression_digest_spec` | The fold from log to permanent record, driven by hand-built records rather than a broker — what is worth guarding is the fold, and none of it is about Kafka. Point facts award once and are idempotent under redelivery; an interval can be spoiled, can re-open without restarting a clean one, and **cannot close against a different `run_id`**; meter readings are absolute, so an older reading arriving late never walks a total backwards. **The helper's `stringify_keys` is load-bearing**: `node: "flywheel"` under a Symbol key silently matches nothing |
| `services/event_pipeline_spec` | The whole chain on a real cold start: engine → the envelope the producer puts round each fact → `JSON` → the digest → an award. **The only spec that can catch a mismatch between hops**, which is how this system actually breaks — neither side wrong on its own, nothing raised, and an achievement that silently never fires. It earned its keep immediately: `raised_steam_from_cold_alone` was awarded on every ordinary start, because the igniter fires at tick 1 and the fire catches at tick 2, so the only heater event fell outside its own window. Also holds the volume budget — **under 20 events in 1700 ticks** |
| `failure_spec` | The failure contract independent of any machine: that `failure` is a **mode**, that `broken?` derives from it (and answers for a node with no `Wearing`), that a mode survives JSON **as a Symbol**, that escalation only moves forward and emits only on a transition, and that the boiler's mode splits on conditions rather than on `cause`. **Escalation is proved on a real part, not just on `escalate_to`** — a cylinder worn to `scored_bore` that then hydro-locks becomes `blown_head`, which is the only thing that shows the mechanism is reachable at all. The identity assertion is the point: with the normalisation disabled, the round-trip *digest* comparison in the same file still passes. **Walks every catalogued operation on every chassis** (44 wearing nodes today) and fails any part left on `Wearing::GENERIC_FAILURE`, which is the guard that keeps the fallback from becoming a silent off switch. Also the `Breach` rig: shut costs nothing, opens by the mode's size, stays shut for a mode it does not name, books `mass_spilled` rather than `mass_vented`, and conserves both balances across a burst. **Two things about it are easy to assert wrongly** — a drum empties to *ambient*, not to zero, and total spill *saturates*, so breach sizes must be compared by what is left rather than by what came out |
| `ignition_spec` | That a fire needs a spark, spreads in a cold box, and dies without air |
| `performance_spec` | ~55 ms/tick at 100 nodes against a 250 ms budget |
| `steam_engine_spec` | The operation end to end — startup, output, wire-drawing, failure, conservation. **Move one lever per example**: raising the throttle and the stoking together passes on the balance between two effects that oppose each other. Also **check the engine is not saturated before asserting on power** — `LIGHT`'s damper 85 puts the drum at 608.0 kPa against a 607.95 kPa relief setting, so it feathers its safety valve continuously and every upstream change reads as zero. The ashpan example recovers 397.3 vs 380.4 kW at damper 60 and ±1 kW of noise at 70, 78 and 85. Pass `damper:` to `light_and_run` to get off the valve |

## The delivery tier

`spec/runner/` and `spec/components/` use `rails_helper`.

| Spec | Guards |
|---|---|
| `runner/match_runner_spec` | The tick barrier and command routing — sim vs runner-addressed, and that a bad record cannot kill the loop |
| `requests/commands_spec` | Ingress validation and status codes; that the operation id is stamped server-side, not trusted |
| `requests/loadouts_spec` | The outfitting screen, and **the order behind the button — validate, store, reset**. Guards the two things that order prevents: a build the validator refused reaching the database, and a refused build reaching the runner. Also that the loadout rides **inside** the reset command rather than being referenced by it, that an unchecked slot arrives as an explicit nil rather than re-defaulting, and that the panel follows the loadout (18 instruments → 16 with the safety valve off). Plus **the second validator**: a part the player has not unlocked is refused *when posted directly*, because the dropdown filter is a courtesy and the form is a plain POST — and a locked part that is already fitted is still shown, flagged, since hiding it would report an error about something the player cannot see. **`Assembly`'s own verdict stays `ok?` throughout**, which is the assertion that keeps ownership out of the simulation. Finally the shapes `permit!` would admit — an Array, a Hash, a bare String, a number — each of which reaches `Array#to_sym` and 500s on the draft action |
| `runner/view_broadcaster_spec` | The wire envelope, `prev_tick` chaining, and the resync contract |
| `channels/operation_channel_spec` | Subscription, rejection, and **the backfill** a joining client gets from the durable log — the fix for a spectator one tick behind the flywheel being told nothing had gone wrong. It caught a bug the rescue around it would otherwise have hidden forever: `transmit(kind: …)` passes Ruby **keywords**, not a positional Hash, so it raised and the backfill silently did nothing. Braces are load-bearing. Also that a failure there costs the backfill and not the subscription, and that only the newest run is carried |
| `models/incident_spec` | That `type` is data rather than Rails' STI column, and that `(run_id, operation_id, tick, seq)` is a **unique index doing dedupe work** — a replayed tick re-emits identically, so redelivery must be an upsert no-op. Plus that backfill takes the *newest* rows before reversing (keeping the oldest fifty would show a joining spectator the start of a match and nothing since) and applies the same severity filter the live feed does |
| `models/match_run_spec` | One row per *build*, not per match, and the retention split: a sweep takes the run's working material — incidents, open attempts, per-run progress — and **leaves awards and lifetime totals alone**, because those are keyed to an owner rather than to a run. Both halves asserted, since the split is the policy |
| `components/instrument_component_spec` | That every gauge carries the `data-` attributes Stimulus writes into |
| `models/blueprint_spec` | Derived from `Operations.**catalogued**`, not `known`: a spec rig registers globally, so deriving from `known` makes it an unlockable machine nobody has priced and takes the whole catalogue down — **only in a full-suite run**, because nothing else loads `spec/support/loop_rig.rb`. That the unlock catalogue is **derived from the simulation's registries and never written down** — one part blueprint per registered part, one per operation type, one per content archetype — because a hand-maintained list drifts *silently*, leaving a new part simply unreachable. Also that a chassis id is scoped to its operation (`steam_engine/high_pressure`), so two machines that each name a frame `standard` cannot share an unlock, and that a real part id is not findable under the wrong kind. Plus **the gates**: every blueprint priced, bills denominated only in resources `content/` has, an unpriced blueprint raising rather than being free, and `materials: {}` as the written-down way to *be* free. **The achievement gate stubs nothing** — `Achievement.earned?` reads `awards`, so the spec opens the gate by granting a real `Award` and closes it by granting none |
| `requests/crews_spec` | The pre-match crew screen, and **validate, store, reset** — the same order `loadouts_spec` guards, for people. That every role is named including empty ones, that an unselected `<select>`'s `""` becomes an empty slot rather than `:""` (a posting for somebody with no name), that posting an injured minion is **refused rather than silently swapped**, and the four shapes `permit!` would admit. Note the assertion that reads `"Gauge Spanner"` and not `"Stoker's Shovel"`: **ERB escapes the apostrophe**, so asserting a label as written in `kit.rb` looks for something that cannot appear |
| `services/injury_list_spec` | The only consequence in this release that outlives its match. That `:mortal` alone reaches the list and the tier is **read from the event rather than re-derived** (the engine owns the ladder; a second copy here would fail in the direction of losing people forever); that a redelivered injury does not lengthen a sentence while a *later run* starts a fresh one; that the standin can never be listed, since an inexhaustible supply with a row against it would take the floor out from under every later match; and that recovery is derived from the run, so a replayed match takes the same person out for the same time |
| `support/reference_crew` | **The crew a spec runs a machine with, and deliberately nobody real.** Stoking is effort now, so a lever position is an instruction and what comes of it depends on who is carrying it out — an engine with no roster is worked by day-labourers and never raises steam (56 kPa, 0 rpm, against 608 kPa and 174.6 rpm for a competent hand). A spec that runs an engine and does not say who is working it measures the labour exchange rather than the machine. Pinning that to Jim would break every such spec on every balance tune, looking like a physics regression, so the fixture is flat 1.0 at every stat with no kit — capability exactly 1.0, the baseline every station's throughput is declared against. Tag a group `crew: :reference` to stub `Content.default`; **passing `content:` covers the build but not a restore**, since `Operation.from_h` never sees one, and `before(:all)` fires before the hook |
| `injury_spec` | The Danger Check and the ladder. **The claim it exists to prove is that no dice are thrown** — `resilience` is rolled once at `initial_state`, so a determinism example fails if a roll ever leaks onto the tick path and nothing else would notice. Asserts TIERS rather than tuned numbers (the curve is a sweep), the gradient that justifies the release (the same blast kills a day-labourer and severely hurts a kitted worker), both routes into harm (accumulation and one big blow), forward-only escalation, transition-only events, and the injury mode surviving JSON **as a Symbol** — a String is truthy, so a restored crew would read as injured while every derating fell back to 1.0. Also walks every catalogued machine for hazards wired to stations that do not exist, modes their parts cannot enter, or a `scales_with:` figure the part never reports. **Three of its own examples failed for reasons unrelated to what they tested**: `Vessel` has no `overload?` and a default `stress_rate: 0.0` never breaks; the saturation solve moves the pressure before the rupture, so a scale must be calibrated off the figure the part *reported*; and the ladder had already moved on when a test hit twice |
| `crew_spec` | **The quietest failure mode in the minion release.** A roster rides in `options:`, so it goes through JSON — every id a String, every deliberately-empty equipment slot a missing key — and one that fails to normalise restores a different crew in different kit without raising anything. Asserts every id returns as a **Symbol** (`be`, never `eq`; the digest cannot catch it, since `canonical` runs through `JSON.generate` where `:jim` and `"jim"` are one string), that an emptied slot does not grow its kit back, and that an unfilled role restores as the standin. Also the four-layer fold: Jim with a ticket, a shovel and an apron comes out at strength 1.35 and `heat_resistance` 0.5 — **added, not maxed** — and an item cannot be fitted in a slot it does not belong to |
| `kit_spec` | The two registries behind layers three and four of a minion's sheet. That every item is in one of exactly three slots and every slot has something in it; that an id cannot be quietly re-registered (a roster addresses kit by id, so an overwrite would rebuild a different kit from the same name — `Parts`' reasoning); and the one that is easy to get wrong: **an item's stats are OFFSETS, so a key it does not mention means "unchanged", never "zero"**. Zero would strip a worker of every stat their gloves had no opinion about |
| `models/unlock_spec` | That a row **cannot be created naming a blueprint that does not exist**, and — the half that matters more — that a row a *rename* stranded can still be found afterwards. Nothing revalidates rows already in the table, and a stale one is not a crash but a player quietly missing what they earned. `insert_all` is used deliberately, because that is what a rename leaves behind |

Component specs assert against the **Nokogiri fragment `render_inline` returns**, not Capybara's
`page` — Capybara is not a dependency and this prototype does not need one.

**The runner spec does not assert timing.** The 4 Hz cadence and drift behaviour are checked by
running `bin/match_runner` and reading its heartbeat, because a spec that asserts on `sleep`
is slow, flaky, and tests the machine's mood. What it does guard is routing, which would
otherwise break in silence.

`spec/environment_spec.rb` asserts infrastructure facts with silent failure modes: the Postgres
test databases, that the sim is requirable from Rails, that **Zeitwerk does not manage the
simulation**, and that development is not on the in-process `async` cable adapter.

> **Ask Zeitwerk directly, never by consequence.** Testing it by eager-loading the app and
> failing if `ReactorSim` is defined proves nothing once the delivery tier legitimately requires
> the sim (`config/initializers/reactor_sim.rb`), because "defined" stops distinguishing *we
> asked for it* from *Zeitwerk took it*. The check reads
> `Rails.autoloaders.main.unloadable_cpaths`, with `ApplicationController` and `DevMatch` as
> positive controls — **without those a typo'd constant name makes the check pass while proving
> nothing.** If you add a consequence-style test, add its control at the same time.

**It asserts nothing about Kafka.** The "same-key records land on one partition" check was done
by hand. The suite needs no
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
