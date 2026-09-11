# Current progress

Last updated: 2026-09-05. Sim suite: **179 examples, 0 failures.** Rubocop: clean, 111 files.

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

Working skill gradient at `time_scale 1.0`, re-measured 2026-09-05 after mass transport became
an implicit network solve, the mill gained a torque curve, and the flue gas was routed past the
water. Flywheel bursts at ~322 rpm.

| throttle / stoking / load | outcome |
|---|---|
| 45 / 45 / 70 | survives, ~98 rpm, ~38 kW |
| **60 / 60 / 80** | **survives indefinitely, ~104 rpm, ~50 kW** |
| 100 / 80 / 100 | survives, ~144 rpm, ~150 kW — hard work, still inside the limit |
| 100 / 80 / 40 | ~217 rpm, ~224 kW — the profitable, frightening one |
| 100 / 80 / 90, then **shed to 0** | flywheel bursts |

**The danger is shedding the load, not opening the regulator**, and that inverted when the mill
stopped being a constant-torque brake. A brake has no stable intersection with the cylinder's
torque curve, so full demand used to be the most dangerous setting on the panel; a fan-law mill
holds the engine at its duty point instead, and less load means more speed, more power, and
less margin. That gradient is the game.

Startup is a real procedure: light with the damper nearly shut, wait for the fire to catch,
kill the igniter, **put the mill on the belt, and only then open the regulator.** That order
matters now and did not before: against a fan-law load, running at open throttle with nothing
engaged bursts the wheel, and every configuration that made more steam did so inside that
window until the procedure was corrected.

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
  seizure, crankshaft fatigue fracture. **Hydro-locking now has a consequence** — see the
  obstruction rows below — but it is not yet *reachable*, which is a separate gap.
- **Chemical Vats** — deleted with the old paradigm, to be rebuilt on the new one.

---

## Known gaps and rough edges

| Gap | Detail |
|---|---|
| ~~Condensate cannot leave a gas-only line~~ | **Closed, as a side effect.** Steam used to condense inside a cooling conduit and be stuck there as liquid in a gas-only pipe. Conduits stopped holding material when transport moved to paths, and `run_phase_change` needs a `volume_m3` a conduit no longer has — so condensation now happens in the destination vessel, where it belongs. No `SteamTrap` node was needed. |
| ~~Non-condensables ignored in the phase solve~~ | **Not a gap — this entry described correct physics as a defect.** `Saturation` solves the condensable pair against its own **partial** pressure, which is what vapour–liquid equilibrium actually depends on; the non-condensable then adds its partial pressure to the vessel total through `Pressurized#pressure_pa`. Measured: 10 kg of water at 380 K in 1 m³ gives a 62.1 kPa steam partial pressure with or without air present, and 1 kg of air takes the **vessel** from 62.1 kPa to 166.7 kPa. So a condenser losing its vacuum to inleakage is already modelled. The real simplification is narrower and worth stating instead: the model does not distinguish evaporative equilibrium from **bulk boiling**, which needs the vapour pressure to reach the *total* pressure before bubbles can form. |
| A ruptured conduit blocks instead of leaking | `Conduit#throughput_kg` returns zero when broken, so a failure is a solid wall and the line backs up to its source. A burst pipe is a **leak**: upstream should still see a moving flow, downstream should starve, and the difference should reach `Atmosphere` as a real loss with `mass_spilled` finally having a writer. Wants the atmosphere to act as the universal sink for anything an operation loses. Marked `TODO` at the code. **Much later** — it needs a rupture size, which is a failure-model decision. |
| **Stoking is inverted above ~60, and it has not been attributed** | Measured 2026-09-08 at throttle 60, damper 85, load 80, everything else held: **stoking 50 gives 169.5 rpm and 368 kW; stoking 70 gives 161.5 rpm and 325 kW.** More coal, less power. The firebox falls 966.5 → 937.9 K and the boiler 537.0 → 501.1 kPa, which is consistent with an air-limited fire: the extra coal cannot burn at a fixed damper, so it sits in the box absorbing heat. **The direction is real** — smothering a fire by over-stoking is exactly why firemen fire little and often — but three things are unknown. Whether the optimum belongs at 60 rather than higher; whether the penalty should be this steep; and **whether this predates the cylinder work**, which is not established either way (the only coupling touched is blastpipe draught through `exhaust_kg`). It cost a spec: `steam_engine_spec` used to raise the throttle and the stoking together, so it was measuring two levers whose effects oppose and passing on the balance. Isolate a lever before asserting on it. Wants a damper × stoking sweep. |
| ~~Obstruction could not be expressed at all~~ | **Closed 2026-09-08** by `Concerns::Obstructs`. Volume occupancy had exactly two consequences — less room to accept (`Holds#room_m3`) and higher pressure for the gas left (`Pressurized#free_volume`) — and neither could say a deposit was in the **way** of anything. The concern measures occupancy against a **characteristic volume the node declares**, which is the whole idea: the 14.0 kg of water that destroys the cylinder is 7% of its volume and 100% of its clearance space, so against the node the hazard is invisible. Two callers with nothing in common but the fraction — a cylinder deriving a top-dead-centre pressure, a firebox throttling its reactions — which is the test it had to pass to earn a file. Design and the rejected alternatives: [`design_sketches/obstruction.md`](design_sketches/obstruction.md). |
| ~~A cylinder relief valve could not sense what destroys a cylinder~~ | **Closed 2026-09-08.** `pressure_pa` spreads the charge over the whole cylinder, so filling the clearance with enough water to wreck the engine moves it about 7% — there was no spike for a valve to lift on, because **a lumped body has no crank angle**. `Cylinder#compression_pressure_pa` reconstructs the pressure at top dead centre the way `mean_effective_pressure` reconstructs a diagram we never trace: 1.51× the dry figure at a quarter of a clearance of water, 2.56× at half, 17.7× at nine tenths, monotone throughout. `ReliefValve` gained `senses_quantity:` — **a valve pointed at the wrong quantity is worse than none, because it looks like protection**, and `obstruction_spec` asserts both halves. |
| ~~Composition could only be all-or-nothing~~ | **Closed 2026-09-09** by `Node#transport_affinity` — a per-part, per-tag multiplier on what crosses, as opposed to how much. Design and the rejected alternatives: [`design_sketches/tag_based_transport_overrides.md`](design_sketches/tag_based_transport_overrides.md). A stream used to carry the composition of wherever it came from in exactly the proportion held, with a binary tag gate as the only other control — two settings, and for a cylinder exhausting condensate up a chimney **both were wrong**. Verified inert: a neutral affinity on every vessel leaves the steam engine's digest bit-identical. |
| ~~Boiler priming was unrepresentable~~ | **Closed 2026-09-09.** `Nodes::Boiler` declares the **steam quality** it delivers and solves for the multiplier, because the multiplier is about 1.2 × 10⁻⁵ and nobody would have guessed it. Below 55% full it is a 99.5%-dry drum and invisible; above that the quality degrades and water goes over with the steam. Measured at throttle 60: feed 45 → 52.7% full, 0.005 wetness, a bone-dry chest and 369 kW; feed 90 → 73.3% full, **0.125 wetness**, water in the chest and **102 kW**. **The feed pump finally has a ceiling as well as a floor.** (Part of that fall is thermal — heating more feedwater — but the chest stays dry below the onset and only wets above it, which is the carryover.) |
| ~~Hydro-lock has a consequence but is not reachable~~ | **Closed 2026-09-09, and demonstrated rather than argued.** A primed boiler feeding a standing cylinder with the cocks shut reaches occupancy **1.11 by t=5000 and 2.87 by t=9000** — 40 kg of water in a clearance space that holds 14. The same run with the cocks open holds **0.0003**, and opening them at t=4000, with the cylinder already **55% of the way to lock**, clears it inside a thousand ticks. Reachable, preventable, and recoverable, with normal running unchanged (the feed sweep matches its pre-blow-through numbers to 0.2 rpm and 0.6 kW). |
| **A locked cylinder: the mechanism is proven, the engine-level demonstration is WITHDRAWN** | **Retracted 2026-09-10.** A run was reported here showing 56.6 kg of water in the cylinder at occupancy 4.06, destroyed at speed, and described as the historical failure reproduced end to end. **It does not stand.** It depended on boiler swell saturating, and at the time swell saturated on a *single-tick pressure spike* rather than on physics — see the two smoothing traps above. With a corrected signal the same scenario peaks at wetness 0.509 and occupancy 0.163, and the cylinder survives. The **mechanism** is still sound and is proven where it can be proven cleanly: `obstruction_spec` shows a flooded chest making the intake ask for 50× more, matching swept volume × supply bulk density, enough to fill the clearance inside twenty ticks — and the energy rule breaking a heavy wheel where a light one stalls. What is now open is whether the hazard sits inside the engine's **reachable operating envelope**, which is a balance question and not a settled one. **Do not write a spec against it until that is answered.** The old entry's diagnosis was right about the symptom and wrong about the cause. It was not that filling and breaking lived in disjoint speed bands — it was that **the piston never asked for a slug**. `displacement_kg` priced the swept volume at the working fluid's *gas* density, so a cylinder sweeping 0.0496 m³ a tick (49.6 kg if that volume is water) demanded 0.126 kg. A chest full of primed water handed it a few hundred grams. `Holds#bulk_density_kg_m3` is what a positive-displacement machine actually swallows, and with it the slug arrives. Three other things had to move with it: the boiler needed **swell** so priming is an event rather than a level, `Arbiter.entrained` needed to stop dropping liquid on a path with no declared opinion, and the steam line's ports had to be rated for water rather than steam. The old advice still holds — **do not close this with thresholds**; the whole `lock_omega` idea is gone, replaced by asking whether the driveline has the energy to compress the charge. |
| **Four mass-for-volume confusions now, and it is the signature bug of this codebase** | `contents_volume` read as a level (a 317%-full boiler). A transport affinity set without regard to the mass ratio it works against (needed 1.2 × 10⁻⁵, a 10⁻³ floor made it violent priming). A clearance priced as 0.029 kg of steam, so the piston expelled 14 kg of water from a space that could not hold it. And now a swept volume priced at gas density, which made hydraulic lock at speed arithmetically unreachable. Every one of them looked like a tuning problem and was found only by measuring a mass budget. **When a quantity is a volume, carry it as a volume** — and when a rule converts between the two, the conversion is the first place to look. |
| ~~Feedwater arrives with no preheat~~ | **Closed 2026-09-10 by `Nodes::Vessel` wired as an injector** — live steam and cold water meet in a small vessel, the steam condenses into the water and the hot mixture goes to the drum. No new class: the saturation solve already does the condensing and `h = c·T + h_f` already makes the latent heat exact. Feedwater now arrives at **357 K** instead of 293 K, halving the cooling, and it **costs steam rather than heat** — about 0.28 kg/s at full feed, diverted from the cylinder — so filling the boiler and pulling hard finally compete for the same supply. Design and the rejected cheap version (warming the tank, which is free and therefore deletes the trade): [`design_sketches/injector.md`](design_sketches/injector.md). |
| **Priming is still out of reach, and it is now a ratio rather than a mechanism** | The injector was expected to open the envelope and **did not**, which is worth recording because the controlled experiment said it would. Warming the supply tank to 370 K let the boiler stay at 432 K at *every* feed setting and a regulator slam at feed 80 reached occupancy 3.346 — but that experiment handed out **free** hot water. A real injector charges for it, so overfeeding still costs, and overfeeding is unavoidable: **the pump moves 2.5 kg/s against roughly 1 kg/s of evaporation**, so raising the glass from 50% to 80% means running 2.5× over for around 6 000 ticks. What blocks the hazard now is feed capacity against evaporation rate, and boiler volume against firing rate — **balance numbers, deliberately left for the balance pass.** The lesson for next time: a free-parameter experiment proves *which quantity* matters, never that a priced version of it will behave the same. |
| ~~The draught gauge could only ever say "thin"~~ | **Closed 2026-09-10, found by a player, and provable without running anything.** Bands were 0.5 / 3.0 / 10.0 kg of air held in the firebox — but a 6 m³ box **entirely full of pure air** at 900 K holds 2.35 kg, so "adequate" and "strong" asked for more air than the vessel can physically contain and were unreachable by construction. It read "thin" through half a megawatt. Measured across the damper the signal is fine — 0.0083 / 0.0269 / 0.0477 / 0.1744 / 0.3669 kg at 20 / 40 / 60 / 80 / 100, **44× and monotone**, tracking a fire of 333 → 715 K and an engine that will not turn below damper 80. Only the calibration was wrong. **Check a band against the range the quantity can actually occupy**; an unreachable band is a phrase that never displays, and nothing fails loudly when it does not. |
| **A boiler filled solid with water makes the pressure model swing wildly** | Feed 100 with a fire that cannot evaporate it drives the liquid to **100.0% of the drum**, at which point `Pressurized#free_volume` is sitting on its 0.1% floor and the pressure swings ±23 kPa/s on nothing — which then saturates swell and pins the glass at its display ceiling. A boiler primed solid is a real and dangerous condition, and arguably a pressure that spikes is *correct*; what is missing is any **consequence** for reaching it, so today it is just a numerically ugly corner. Needs a design decision, not a clamp. |
| Nothing punishes a **low** water glass | Feed 0 runs happily at 357 kW while the water drains away. There is no crown-sheet failure, so that lever has a ceiling and no floor — half a mechanic. |
| **A rate of change measured across one timestep is solver noise, not a signal** | Boiler swell was driven by `(P_prev − P_now)/dt` taken raw. A single-tick 2.3 kPa dip on opening the regulator read as **9 102 Pa/s** — past the 8 000 Pa/s that saturates the mechanic — so the void went from nothing to maximum in 250 ms and **the gauge glass jumped 40 percentage points in one tick**, then decayed for twelve seconds. Every isolated blip did it. Found by a player driving the UI, not by a spec, because it looks like a plausible transient in a table and like a broken instrument on a dial. **A derived transient needs a physical time constant**, and here there is a real one to cite: bubbles take finite time to nucleate, so a void fraction cannot track a 250 ms pressure blip. Smoothed over `swell_rise_s`, a sustained demand step still saturates within seconds while one tick of noise reaches a tenth of the way. |
| **Smooth the signed quantity and rectify afterwards, never the other way round** | The first attempt at the fix above rectified first — `max(rate, 0)` then averaged — which takes the mean of `\|x\|` where the mean of `x` was wanted. A symmetric tick-scale ripple with **no net drift** then averages to a large positive "fall" out of nothing, and swell pinned at its 45% maximum permanently whenever the engine was working: the glass read **92.1% full on a drum genuinely 50.6% full**. The arithmetic that caught it is worth copying — a sustained 8 kPa/s for the 1 050 s it supposedly held would have dropped the boiler by 8 MPa, eighteen times its actual pressure. **When a smoothed signal implies something impossible over its own window, suspect the smoothing, not the physics.** |
| **A linear valve is not a linear control, and the lever's authority lands where the solve saturates** | Found by a player: the regulator "has almost no effect". It has plenty — 3.37× of power across its travel — but **5 → 30 does 79% of it and the top 70% of the lever delivers 21%**. A pressure path settles `n = k·dt·ΔP / (1 + k·dt·ΣC⁻¹)`, and the regulator's full-open value of that second term is **1.76**: past 1 the two ends substantially equalise within a tick, so 5× more conductance buys 2.4× more flow. Measured, the chest reaches 85% of drum pressure by lever 30. Fixed with **equal-percentage valve trim** (`Conduit#rangeability`), which is the standard answer to a valve working into a system that saturates and leaves the full-open figure untouched. **Check where a lever's authority actually lands before concluding it is undersized** — and note the first attempt at the trim over-corrected, moving the dead zone from the top of the travel to the bottom, so this wants picking from a sweep rather than from the algebra. |
| **Pick the driver that is zero in steady state** | Boiler swell was first scaled by **offtake rate**, which sounds like the same thing as "working hard" and is not. It taxed steady running — a hard-pulling engine at a perfectly safe level sat at 20% void forever — while giving almost nothing on the transient, because opening a regulator that is already 60% open barely changes the flow. And it is **anti-correlated with the hazard**: a drowning engine is slow, so it pulls less, so it swells less, exactly when the glass is highest. Scaling by the **rate of pressure fall** is what the sources describe (demand outruns generation → pressure drops → saturation temperature drops → the water's own sensible heat flashes it), and it is zero in steady running of any intensity, so normal operation is untouched *exactly* rather than merely a little worse. **When a mechanic is meant to be an event, drive it with something that is zero when nothing is happening.** |
| ~~The cylinder relief valve passed water in exactly zero states~~ | **Closed 2026-09-09.** Fitted to relieve hydraulic lock, permissive on both ports, sitting under a comment reading *"Permissive, because what it has to pass is water"* — and it had never passed any. Lifted, its `conductance: 0.02` made the path **pressure-driven**, where `Arbiter.entrained` dropped liquid outright because the cylinder declares no affinity for `:relief`; shut, `throughput_kg` was zero. Two states, no water in either. Worst in the case it exists for: a fully locked cylinder holds no gas, so `mean_molar_mass` returned nil and the path carried nothing whatever. **The regime a path lands in is structural** — any conductance-bearing path whose ends declare no intent — so this was quietly the rule for most of the graph, not an edge case. Liquid now falls to the same proportional rate term solids take. |
| **`Arbiter.entrained` shipped with no test coverage at all, and that is why** | `grep -rn "entrained" spec/` returned nothing. `transport_affinity_spec` builds its rig from a conduit with **no `conductance:`**, so all 13 of its examples exercise the rate-driven branch and the entire pressure-driven half of settlement went untested from the day it landed — including the additive-total semantics, the amplification cliff, and the liquid-dropped rule above. `spec/reactor_sim/entrainment_spec.rb` now covers it. **A rig that cannot reach a branch is not coverage of it**, and the tell was there in the fixture: a spec about pressure-driven transport whose pipe declares no conductance is testing something else. |
| Two wrong explanations for it, both worth keeping | It took three attempts to find out why the cylinder would not fill, and the first two were confident and wrong. **"A cycle averaged over a revolution cannot represent a slug"** was wrong: per-revolution admission is `water_kg_per_tick ÷ revolutions_per_tick` and every term of it is already in state — nothing was being averaged away. **"Condensation will be the route"** was also wrong, and the arithmetic says so: filling the clearance by condensation needs 31.6 MJ of latent heat removed, and at `ambient_conductance` 25 W/K over ~87 K that is 2.2 kW, or 57,500 ticks. **Priming is the route precisely because the water arrives already liquid and no heat has to be shed** — which is what the sources meant by "the water volume is far greater than that from condensation". Both times the real cause was an ordinary bug, found by measuring the water budget rather than by reasoning about it. |
| ~~The cylinder cocks are a cliff, not a trade~~ | **Re-measured 2026-09-10 and the old entry was wrong on both counts.** It is not a cliff and the `extractable_joules` bound is not the cause. Swept at throttle 60 / load 80: **233 / 179 / 135 / 100 / 75 / 54 kW** at cocks 0 / 10 / 25 / 50 / 75 / 100 — smooth and monotone, every notch of the lever costing its share. The clamp sat at **0.962–0.974 across the whole sweep**, with 0.9–2.8 MJ extractable against a 14–60 kJ demand, i.e. 20–60× headroom and barely varying: it is inert, not the mechanism. **The steam chest fixed this without anyone noticing** — the cocks now act through chest pressure (440 → 256 kPa across the sweep), because a vented cylinder keeps drawing to refill its clearance and the chest depletes, so `P₁` and the MEP fall with it. That is the honest route, and the old note was describing a machine that no longer existed. **A stale measurement is worse than none**: it was cited twice as a reason not to touch the cocks. |
| ~~A standing cylinder admitted almost nothing~~ | **Closed 2026-09-09.** `admission_kg` at rest returned only `clearance_fill_kg`, a static top-up that stops the moment the pressure equalises — so a stopped engine with the regulator open took in almost no steam and the cocks had nothing to drain. A stopped cylinder is not sealed: the valve is wherever the crank left it and steam blows straight through, which is the noise a stationary locomotive makes and the reason its cocks stream. `blow_through_kg` is that flow, fading out as the engine picks up and displacement takes over. Measured before: 0.374 kg in nine thousand ticks, plainly asymptoting. After: lock in about 2,600. |
| Pressure model is minimal | Ideal gas over free volume. No hydrostatic term and no flow-induced pressure drop; pump and fan head exist as a conduit's `head_pa`. |
| ~~The ledger records **net** boundary flow, not gross~~ | **Closed 2026-09-05.** `Atmosphere#apply` used to net its intake against its exhaust inside one tick: 68.06 kg drawn in and 103.12 kg pushed out were booked as `mass_added` **0.00** and `mass_vented` 35.06, so nothing built on the ledger could measure anything. It now reads `grant.sent` and `grant.received`, which are gross. This is also what turned `Grant#sent` from a bare kg figure into the parcels themselves, and what exposed a second bug — `received` was built from the parcels the *source* dispatched rather than what survived the conduit walls, crediting a sink with energy still sitting in the pipe. |
| ~~The fire and the boiler could not both be hot~~ | **Closed 2026-09-05**, by giving the gas a second route to the water: a `boiler_tubes` conduit between firebox and chimney, thermally linked to the boiler. With only the one conduction link, the firebox temperature was pinned at `T_boiler + Q/k` — so a realistic fire and a well-fed boiler were mutually exclusive, and weakening the link to get one starved the other (measured: k = 9000 gave 676 K; k = 1000 gave the same 692 K on a fifth of the burn, and the engine never turned). Measured after: **2331 kW into the water at a 896 K firebox, against 2300 kW at a 676 K one** — same heat, a fire twice as far above its surroundings, and more power out (50 kW against 41). |
| **Two entries here were wrong and are corrected** | A first pass at this analysis claimed "90% of the fuel goes up the chimney" and blamed the firebox's low temperature on 197 kg of coal being 85% of its thermal mass. **Both were misread.** The 90% came from `joules_advected_out`, which is gross enthalpy against a **0 K** reference and is dominated by the exhaust *steam's* 3.07 MJ/kg of formation enthalpy, not by flue gas — the actual stack loss was ~18%, and most of the rest is latent heat leaving with the exhaust of a non-condensing engine, which is real and is precisely why Watt's condenser mattered. And the coal's thermal mass sets the firebox's *response time*, not its equilibrium: `T_firebox − T_boiler` tracked `Q/k` exactly across the sweep above. **Do not read a 0 K-referenced ledger line as a loss fraction**, and check a temperature against its heat balance before blaming a heat capacity. |
| ~~The cylinder is a tank, not a cycle~~ | **Closed 2026-09-08**, and it took four separate fixes because one node was doing three jobs. It now works an **indicator diagram** — admit to `cutoff`, expand along `pVⁿ`, exhaust against back pressure — with a positive-displacement intake sized at *supply* density, drawing from a **steam chest** rather than straight from the boiler. See [`design_sketches/cylinder_solutions.md`](design_sketches/cylinder_solutions.md) for the analysis and the options that were rejected. Cut-off is now a real economy lever with an **interior optimum** near 40%: at an open regulator, steam falls 1.000 → 0.041 kg/s across the range while `kW per kg/s` runs 478.8 → 618.3 → **688.7** → 612.5 → 324.3. The optimum is not tuned — it is the fixed back-pressure subtraction eating a growing share of a shrinking MEP, which is exactly why a non-condensing engine cannot notch as far as a condensing one. |
| ~~The regulator was a conservation clamp~~ | **Closed 2026-09-08.** With the diagram reading the boiler, the throttle rationed *how much* steam arrived but said nothing about the pressure it arrived at, so it could not affect torque at all — and `extractable_joules` in `Tick#transmit_torque` silently became the throttling mechanism, measured **discarding 30–50% of declared work** (scale 0.496 at throttle 20, 0.698 at 60) with declared torque nearly flat across the range. A steam chest between regulator and valve closes it structurally: swallow faster than the throttle can pass and the chest depletes, so admission density *and* P₁ fall together. The clamp is now inert at 0.957–0.960 and declared torque rises with the regulator as it should. **A conservation clamp is not a mechanism**, and it fails silently when used as one. |
| ~~A burst flywheel keeps accelerating~~ | **Closed 2026-09-05.** It used to burst at 400.8 rpm against a 321.6 limit and be doing **2364.7 rpm and 3.97 MW** 600 ticks later. `Tick#stress` now zeroes a broken rotor's momentum and ledgers the kinetic energy it was carrying; `settle_drive` drops couplings to a broken part and `transmit_torque` will not drive one. Generic, in one place. **Still open for holders:** a broken vessel does not spill, for the same reason a ruptured conduit still acts as a plug — it needs a rupture size, which is a failure-model decision rather than a transport one. |
| ~~`Load` is a constant-torque brake~~ | **Closed 2026-09-05.** `Load` now has a torque curve — `:fan` (τ ∝ ω²), `:viscous`, or `:constant` — absorbing `max_torque` at `rated_omega`. A constant-torque brake has no stable intersection with a prime mover's torque curve, which is why the engine sat on a knife edge (throttle 80 → 452 rpm, throttle 100 → 1211 rpm). It also inverted the danger: full load used to be the *safe* setting. |
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
2. **Incidents have no consequence.** **Half done (2026-09-05).** A burst flywheel now stops
   dead, drops off the drivetrain, takes the cylinder's output with it, and has its kinetic
   energy ledgered — it used to keep accelerating to 2365 rpm and 3.97 MW. The rule is generic
   and lives in `Tick#stress` and `Arbiter.settle_drive` rather than in `Flywheel`.
   **Still open: a broken *holder* does nothing at all.** A ruptured vessel should spill and a
   ruptured conduit should leak rather than plug, both with `mass_spilled` finally having a
   writer and `Atmosphere` as the universal sink. Both need a rupture size, which is a
   failure-model design decision rather than a physics one — the same reason the conduit TODO
   has been deferred.
3. **The UI is opaque.** No tooltips, no explanation of what any gauge or lever does. Fine for
   someone who knows the simulation, useless to anyone else. Wants hover copy per instrument
   and per lever — which likely means the operation declaring a description alongside each
   diagnostic and control point, rather than the view layer inventing one.
4. **Period-2 limit cycles, and the starvation they cause. Needs a proper investigation —
   this is the most load-bearing item on the list.**

   **Investigated in
   [`design_sketches/flow_through_issue_draft.md`](design_sketches/flow_through_issue_draft.md)**,
   design in [`design_sketches/transport_model.md`](design_sketches/transport_model.md).

   **Step 1 of 7 is DONE (2026-09-04): the oscillation is gone.** Conduits are zero-residence
   transport nodes; `Path` resolves material from one holder to the next in a single settlement;
   the arbiter settles over paths. Measured: the damper no longer alternates at all, and the
   firebox air is smoothly monotonic where it used to read `0.000` every other tick.

   Consequences that landed with it: a conduit now delivers its **full** rating rather than half,
   so the steam engine's flow constants were re-measured from scratch (damper 8.0 → 4.0, throttle
   2.5 → 1.0, atmospheric draught 4.0 → 2.0) and the skill gradient re-established —
   **60/60/80 survives at ~212 rpm / 103 kW; 80/70/90 makes 175 kW and bursts the flywheel.**
   Delay dropped one tick per conduit. `spec/reactor_sim/transport_spec.rb` guards all of it.

   **Steps 2 and 4 are DONE (2026-09-05), and the oscillation is gone for a second and larger
   reason.** A physics autopsy found that the replacement transport law was itself an explicit
   integrator running 400–600× past its stability limit, held together by a per-node bound
   that was wrong by a factor of two. `Relaxation` now solves the whole coupling network
   implicitly — heat, rotation and gas through one function — and `flow_bounds`,
   `node_headroom`, `pairwise` and `bounds` are all deleted.

   Measured at 60/60/80 over 80 steady ticks: firebox air **CV 0.522 → 0.00015**, sign flips
   **38 → 0**, the fire's heat output steady instead of swinging 5.9×. The damper is now
   monotone across its whole travel (593 → 3371 kW) and the firebox pressure crosses from
   −333 Pa with the damper nearly shut to +389 Pa wide open, which is real furnace behaviour
   nobody put there. Gas conductances came down 10× as a consequence — they were previously
   inert, and the note in `steam_engine/definition.rb` records how the new ones were measured.

   Still to come: liquid relaxation on a hydrostatic potential (3), cylinder and relief valve
   onto conductance (5), `Sources::Flow` and pulling both workarounds (6), rebalance (7).
   `cap_gas_by_pressure` still exists but no longer runs on pressure-driven paths.

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

   ~~Two workarounds are in place and neither addresses the cause:~~ **Both are settled
   (2026-09-05), which was the acceptance test the transport design set for itself.**

   - `Filters::Average(8)` on `engine_power` and `cylinder_pressure` is **removed**. The raw
     cylinder signal now has a coefficient of variation of 0.006 and **no sign reversals** over
     120 ticks, where it used to alternate every tick. Both gauges are that much more
     responsive for losing it.
   - `Ignition::OXIDISER_MEMORY_PER_S` **stays, but as physics rather than as a prop**:
     disabling it entirely leaves the engine bit-identical — same fire temperature, same burn
     rate, same speed. A fuel bed does have inertia, `ignition_spec` pins that, and the comment
     now says so instead of blaming an oscillation that no longer exists.

   The reusable lesson turned out not to be about reading flows rather than inventories. It was
   simpler and worse: **the integrator was unstable, and the limiter hiding it was doing most of
   the work.** If a bound is granting 1.8 of a requested 1972, the thing underneath it is wrong.

Every shortcut taken for the prototype is marked `TODO:` at the code with what it does, why,
and what a proper implementation must solve. `grep -rn "TODO:" app/ lib/ content/` is the list.

Architectural detail for 1–6 is in [`architecture.md`](architecture.md) §6–§10; it was written
before the simulation rewrite but is unaffected by it.

---

## Traps that have already cost time

Every one of these was a real bug. They are documented where they matter, but collected here
because they are the kind a fresh reader repeats.

- **An explicit integrator is only stable while `dt < τ`, and a limiter is not a substitute.**
  Mass transport used `k·ΔP·dt` with a per-node bound holding it together. Every gas coupling
  in the steam engine ran **400–600× past** the stability limit (firebox τ = 0.58 ms against a
  250 ms tick), so the flow was decided by the limiter rather than by conductance — the flue
  asked for 1972 mol and was granted 1.8. Symptoms: the fire's heat output swung by 5.9× every
  few ticks forever, and **doubling the draught conductance cut engine power to a fifth**.
  Fixed by solving the whole network implicitly. Two things follow: never reach for a
  per-coupling law in a network, and **if a limiter is doing most of the work, the integrator
  underneath it is wrong.**
- **`node_headroom` was wrong by exactly a factor of two.** It moved a sender to the
  receiver's *current* potential, ignoring that the receiver rises as it fills. Two 2 m³
  vessels holding 6 kg and 1 kg of air joined by a pipe **swapped contents on tick 1 and
  stayed swapped forever**. It went unnoticed for as long as it did because every gas coupling
  in the steam engine has `Atmosphere` on one end, whose capacity is ~10⁸× a vessel's, so the
  receiver never rises and the error vanishes. `transport_spec` asserts equalisation now.
- **One restriction, one number.** A path governed by both a conductance and a
  `max_kg_per_s` that disagree is choked at every pressure it can reach, and a choked coupling
  carries a *fixed* flow — which leaves the pressure at either end with no feedback at all.
  The firebox ran to an 80 kPa vacuum in one direction and 3.2 atm at 1079 K in the other,
  depending only on which bound the solve reached first.
- **A conservation clamp is not a mechanism, and it hides the fact that one is missing.**
  `Tick#transmit_torque` scales a prime mover's impulse back to what its charge can pay for.
  That is a correct backstop. But with the cylinder's diagram reading the boiler directly, the
  regulator could not touch torque at all, and the clamp quietly became the *whole* throttling
  mechanism — measured discarding **30–50% of the declared work**, scale 0.496 at throttle 20
  against 0.698 at 60, with declared torque nearly flat. The engine still behaved plausibly,
  which is what made it invisible. **If a backstop is firing on most ticks, it is standing in
  for something and the something is what you should build.** Here it was the steam chest;
  with it the clamp sits at 0.957 and does nothing.
- **Do not apply an equalisation rule to a positive-displacement claim.** Two separate bugs,
  the same mistake. `Cylinder#plan` drew `max(displacement, gas_headroom_kg)`, and the headroom
  term — which contains no cut-off, speed or geometry — won every time, so steam consumption
  was **flat to three significant figures while power fell 140-fold**. Then
  `Arbiter.cap_gas_by_pressure` capped the displacement claim against a gradient, on **400
  ticks out of 400** at full gear, to a scale of 0.81 set by the temperature difference between
  the two nodes rather than by anything physical. A piston does draw its cylinder below chest
  pressure — that is wire-drawing — and the claim is self-bounding, because a swept volume
  filled at supply density cannot out-densify the supply. `gas_coupling` already stated the
  rule correctly; the cap contradicted it twenty lines away.
- **A delta is not a measurement.** A boundary node that ledgers its own before/after totals
  records the **net** of everything that crossed in the tick, and air coming in nets against
  flue gas going out — 68 kg in and 103 kg out booked as `mass_added` 0.00. Conservation
  survives it (the net is exactly what the invariant constrains) so no spec fails; every
  figure is simply useless as a measurement. Book gross crossings from the granted flows.
- **What a sink receives is not what the source sent.** The stream gives up energy to every
  conduit wall it crosses, so `Grant#received` must be built from what advection actually
  delivered, not from the parcels the source dispatched. Harmless for years because only mass
  was read from it; the moment the atmosphere ledgered the *enthalpy* it was handed, the
  energy books drifted 4 kJ a tick.
- **A constraint belongs inside the solve, not after it.** Capping the flue's flow after
  settling left the damper solved against an exhaust four times larger than the one allowed to
  cross, and pumped the firebox to 25 kPa. And a pinned coupling must be able to be released:
  pinning the flue drove the pressure down to where it was no longer choked, and with no way
  back it kept extracting from a box the damper could not fill.
- **A node that both holds material and forwards it cannot deliver a steady flow.** It must
  size its intake from tick N−1, before it knows what it will discharge, so the only bounded
  rule — `draws = throughput − held` — gives the map `h ↦ T − h`: an involution with eigenvalue
  exactly −1, which oscillates forever and cannot damp. Drop the `− held` and you get steady
  flow with an unbounded duct instead (measured: 1.2 kg climbing to 7.0 in a 1 m³ damper).
  **Steady inventory and steady throughput are mutually exclusive**, which is why `Conduit`
  stopped being an endpoint rather than getting a cleverer rule. It cost a firebox with no air
  at all every other tick, a cylinder swinging 16.4/78.2 kW, and every conduit silently
  delivering half its rating. Two workarounds were written for the symptoms first.
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
