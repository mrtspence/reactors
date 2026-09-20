# Current progress

Last updated: 2026-09-16. Suite: **631 examples, 0 failures, 1 pending** (48 min). Rubocop:
clean, 184 files.

---

## Where the project is

The **simulation is real and working**, and it is now playable in a browser by a crew of people
who can be equipped, trained and hurt.

```
DONE      simulation engine (lib/reactor_sim)     — physics, graph, diagnostics
DONE      one playable operation                  — the steam engine, two variants
DONE      infrastructure                          — Postgres, Redpanda, topics, gems
DONE      the delivery tier                       — runner, Kafka wiring, web tier, panel
DONE      minions                                 — individuals, kit, training, injury, the IL
DONE      the durable record                      — match.events, incidents, progression, awards
DONE      fatigue                                 — endurance, station exertion, recovery, spent
NOT DONE  match lifecycle, snapshots + recovery, auth, movement
```

You can play it. What is missing is everything around a match rather than inside one: a match
still has no real beginning or end (`DevMatch` stands in), a crash loses the run, and there are
no user accounts.

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

`ls spec/reactor_sim/` is the truth; at the time of writing: `assembly`, `conservation`,
`content`, `crew`, `crown_sheet`, `determinism`, `diagnostic`, `entrainment`, `event`, `failure`,
`graph`, `ignition`, `injury`, `kit`, `minion`, `obstruction`, `performance`, `player_view`,
`purity`, `steam_engine`, `thermal`, `transport`, `transport_affinity`. Plus
`spec/environment_spec.rb` for infrastructure facts with silent failure modes, and the delivery
tier's own directories (`ls spec/`): `channels`, `components`, `models`, `requests`, `runner`,
`services`.

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
- **The console page.** `ConsolesController` renders chrome only — 21 instruments, 14 levers,
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

- **Minions — built, with two seams left open.** Individuals with stats and tags, a four-layer
  sheet, equipment in three slots, training, a roster in `options:`, injury through a Danger
  Check, effort stations that make the crew load-bearing on output, and **fatigue** (phase 6c;
  `endurance` is the sixth stat). What is still missing: **the `Diagnostic#observer`
  gauge-reading path** (`intelligence` is read by fatigue's `:oiling` blend but nothing reads a
  *gauge* yet), and **two minions at one station** (last writer wins). Both are marked `TODO` at
  the code.
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
| A ruptured conduit blocks instead of leaking | `Conduit#throughput_kg` returns zero when broken, so a failure is a solid wall and the line backs up to its source. A burst pipe is a **leak**: upstream should still see a moving flow, downstream should starve, and the difference should reach `Atmosphere` as a real loss with `mass_spilled` finally having a writer. Wants the atmosphere to act as the universal sink for anything an operation loses. Marked `TODO` at the code. **Much later** — it needs a rupture size, which is a failure-model decision. **That decision was made 2026-09-14** — see [`design_sketches/blueprints.md`](design_sketches/blueprints.md) §3: a broken part stays in the graph and behaves worse, with the severity declared per part and running as a spectrum rather than a switch. Note also that the sketch questions the *universal* sink: once a spill can deny a repair crew access to the part it came from, where it went starts to matter. |
| ~~The blower is a free power button~~ | **Closed 2026-09-12, and it was not a blower problem.** Reported from play: the blower was worth about +60 kW on demand, for free, taking a slowly-climbing engine from 230 to 450 kW in twenty seconds and sustaining over 0.5 MW, with output sagging whenever it was shut off. The cause was that **`damper_conductance` was undersized by roughly a factor of two**, and the blower's 600 Pa of head — against a 10 m stack worth ~69 Pa and a blastpipe worth ~361 Pa — was quietly making up the difference. Measured at full controls with the blower OFF, sweeping the conductance alone: **335.1 / 432.2 / 476.6 / 493.3 / 491.3 / 497.4 / 499.0 kW** at 0.20 / 0.25 / 0.30 / 0.35 / 0.40 / 0.50 / 0.60, with the fire hottest at 0.35 (1001 K). Raised to **0.35**, and the exploit disappears on its own: the blower is then worth **+152.7 kW at 0.2, +16.4 at 0.3, +2.9 at 0.4 and −2.4 at 0.5** — past the knee it over-draughts and cools the fire (993 → 931 K). There is no longer a free 45% behind a lever because the engine is already getting the air, which is what a blower is actually for. Above the knee the engine burns more fuel for no more work and starts feathering its safety valve: 0.4 burns 3.4% more coal for 0.4% *less* power. **The old note claiming "×1.5 and above simply pins the boiler on its safety valve and the engine stops gaining anything" was wrong** — ×1.5 is 0.3, which measures at 599.5 kPa, off the valve, and +142 kW. It predated the steam chest, the regulator trim and the stoker rating, and had been cited as a reason not to touch this. *(The blower still wants a cost of its own for the starting phase — crew time, then a fuel reserve — but it is no longer an exploit.)* |
| ~~The blower is still free, it just no longer buys anything~~ | **Closed 2026-09-19** by driven transport: the Hand Bellows occupies a crew member full time and the Donkey Blower carries its own fuel oil. Both honour the black-start constraint the original note set, because neither depends on the engine being lit. The note below is the 2026-09-12 original. Design note, 2026-09-12. With the damper correctly sized the blower is worth +2.9 kW and there is nothing to game, but it remains a lever with no cost, and that is not the intent: it should **occupy a crew member full time** to get anything out of, and later carry a limited fuel reserve or equivalent. Note the constraint that rules out the obvious answer — **assume a black start**, since the player may be the only one generating power in a match, so anything requiring electrical supply is not acceptable. Blocked on minions doing real work, which is itself blocked on giving the work-station levers a finite `stiffness:` (see the TODO in `control_points`). |
| ~~MUST ADDRESS: 60% of shaft power is going into the drive coupling~~ | **Closed 2026-09-17, and the coupling was never the cause.** Found 2026-09-12: 499 kW delivered, 199.7 kW to the mill, 297.5 kW to `joules_to_friction`. The books balanced, so nothing was lost silently — but a real belt loses single digits. Three layers, each hiding the next. **(1)** `Load#apply` integrated its brake explicitly, and explicit Euler on a fan-law brake is stable only while `dt < 2I/(dτ/dω)` — 0.156 s at working speed against a 250 ms tick. The mill was spun up and slammed to a standstill every tick; the coupling then slipped ~100% against a load that was stationary whenever anything read it. Measured: flywheel 18.24 rad/s, load **0.13**, yet extracting 40 kJ a tick — the kinetic energy of a body at 14.1 rad/s. It read as a steady state only because it saturated into the `max(…, 0.0)` clamp. **(2)** Integrating each curve exactly was necessary and insufficient: friction fell 58.6% → 38.7%, but the mill settled at 8.5 rad/s against a true equilibrium of 19.6, because phases 4d and 4e were each exact while the *split between them* was first order. Halving `dt` halved the gap — the signature. So drag moved **into** the drive solve as a conductance to a reservoir at rest (`Relaxation.settle`'s `drags:`, a diagonal term), with a nonlinear brake linearised as `τ(ω)/ω` capped at `I/dt`. **(3)** Only then was the coupling visibly too soft, at 22% slip; `stiffness` went 9 000 → 150 000. **Result: 88–90% mechanical efficiency across 3× power and 2× speed**, rings 7.7–10.2%, journals 0.2–0.4%, belt 1.6%. Two traps worth keeping: measuring the halves separately charges each for a state the machine was never in, which inflated the mill's output past its own engine's and drove `joules_to_friction` **negative** while the totals still balanced; and **`stiffness` must never be tuned to hit a loss target** — a viscous coupling's loss goes as `P/(k·ω²)`, which is a fluid coupling rather than a belt, so the law has the wrong shape and only its smallness makes it safe. Design: [`design_sketches/bearings.md`](design_sketches/bearings.md) §1.1 and §6.3. |
| **A lever, not a defect: the prime mover's torque is applied after the drivetrain settles** | Phase 4d solves couplings and drag implicitly; phase 4e then applies the cylinder's impulse separately. Same operator split that was fatal for the load brake, and benign here for a reason worth knowing — **a brake is stiff feedback, a prime mover is a near-constant source**, and splitting a source is first order with a small constant. The residue is real but harmless: the shaft sheds **11% of its speed** in 4d and regains it in 4e every tick, and `indicated_power_w` therefore reads `ΔL²/2I` — about **5%** — high. Nothing is lost; `transmit_torque` bills the measured kinetic energy gain and a steady-state audit closes to **0.01%**. Two consequences: **never use `indicated_power_w` as an efficiency denominator** (`work_joules` is the honest figure, and the `engine_power` gauge already shows it), and the **`extractable_joules` clamp is dormant** — checked at throttle 10, 20, 60 and 100, the impulse lands unscaled every time, so the "discarding 30–50%" figure predates the steam chest. If the sawtooth ever bites, the fix is written up in [`design_sketches/bearings.md`](design_sketches/bearings.md) §6.4: `Relaxation.settle` already accepts current sources on its right-hand side, so the impulse could be solved with the network and `transmit_torque` reduced to its billing. |
| ~~A vessel's burst pressure was a number somebody picked~~ | **Closed 2026-09-12.** The boiler's `max_pressure_pa` was `relief_pa * 1.5`, which is **circular** — the pressure a shell can survive cannot depend on where somebody set its safety valve — and it made the two impossible to separate, since raising the valve dragged the damage threshold up in lockstep. `Concerns::Pressurized#rated_pressure_pa` now derives it from the plate by hoop stress, `p = σ·t/r·safety_factor`, which is the shape `Flywheel#burst_speed_m_s` has always had (`√(σ/ρ)·safety_factor`). An explicit `max_pressure_pa:` still wins, so a part can be special. Both ratings on a `Vessel` now come from its `material:` — temperature through `Thermal#rated_temperature_k`, pressure through this — and `stress_rate` stays per-part. Derived figures: high-pressure **14.39 atm** (0.6 m radius, 14 mm wrought iron) and atmospheric **4.93 atm** (0.75 m, 6 mm), both landing close to the `burst_pa` each variant already carried, which is a good sign given they came from the plate rather than from a gauge scale. `safety_factor: 0.25` is the **seams, not the metal**: a riveted wrought-iron boiler loses ~30% to joint efficiency before any allowance for the grooving and corrosion that run along a seam. |
| ~~The flywheel failed before the crown sheet could, so the low-water hazard was unreachable~~ | **Closed 2026-09-12.** Found in play: the crown could not be made to fail because the wheel always went first. Measured — at `safety_factor: 0.35`, winding the safety valve down to 9 atm burst the wheel at **tick 1511, in the acceleration transient, with the plate still at 449 K**. Swept flywheel strength against pressure band and starvation, reporting which part fails first and the wheel's peak stress: at sf 0.35 the crown wins at margins 100/70/40 (wheel 0.27/0.38/0.50) and **the wheel wins at margin 0**; at **sf 0.45** (×1.29 burst speed, ×1.65 energy) the crown wins at every margin with the wheel at 0.16/0.23/0.30/0.41. Higher factors work too (0.55 → 0.11–0.27, steel → 0.09–0.22) and were rejected *because* they work too well — the wheel stops being a hazard at all, and steel is better kept as the modular upgrade. **0.45 is the minimum that works and the minimum is the point**: the Wheel Stress gauge still spans 0.16 → 0.41 as the margin is spent, so the wheel remains something a driver watches. With the plug scaled over the plate ruptures at **711 / 702 / 692 / 675 K** across the same margins — *cooler at higher pressure*, which is the crown's pressure coupling working and why it fails below wrought iron's bare 750 K rating. Watt's wheel stays at 0.35: unmeasured, irrelevant in its normal running (0.007 of burst stress), and 1776 foundry practice was not 1802's. |
| ~~The cylinder could not fatigue from over-pressure, and its relief valve was not adjustable~~ | **Closed 2026-09-12.** Two things. `Cylinder#stress_per_second` has fatigued on `compression_pressure_pa` since it was written and **had never once fired**, because the steam engine set neither `max_pressure_pa` nor `stress_rate` — the fifth silent-off-switch in this engine, after the four inert rate caps and the material ratings. The barrel now derives its own hoop rating from the **bore** (a cylinder is the one pressure part that never has to be told its radius): 25 mm of cast iron over 0.225 m at `safety_factor: 0.3` gives **49.35 atm**, far above any relief setting, which is right — a barrel is a thick casting and its danger is the compression *spike*, not steady working pressure. And the cylinder relief valve gained the same adjusting screw as the boiler's, margin 100 → 9.00 atm and 0 → 20.00 atm, stated absolutely instead of as `relief_pa * 1.5` because a cylinder valve's setting is a property of the cylinder and not of where the boiler's valve sits. The range is deliberately generous against the current barrel so a better cylinder later finds room rather than a leftover limit. **Narrower in effect than the boiler's screw, and worth being honest about**: this valve never lifts in ordinary running, so the setting does nothing until the cylinder is wet — then a higher setting keeps the engine pulling through a damp patch at the price of telling the last device between a slug and a wrecked cylinder to wait longer. |
| ~~The safety valve was a fixed setting, and it was doing the flywheel's job~~ | **Closed 2026-09-12, and the diagnosis was the interesting part.** Raising `relief_pa` so the drum stops living on its valve turned out to be impossible as things stood: at 8, 10 or 12 atm the flywheel burst every time, at both cut-offs, with the drum never passing about **7 atm** — so the higher setting never even lifted. **The 6 atm valve was not protecting the boiler, it was capping the power before the driveline failed**, which is exactly why it sat in the middle of normal running. Measured at cut-off 40: relief 6 gives 364.1 kW at wheel stress 0.27; relief 8 bursts the wheel. Options were measured (`scratchpad/relief3.rb`): a steel wheel gives 714.8 kW at stress 0.17, heavier-and-smaller cast iron 708.0 kW at 0.29, and **a stronger mill alone still bursts** — the load is not the limiter, the wheel is, because the burst happens in the acceleration transient before a fan-law load bites. Resolved instead by making the valve **adjustable in play**: `relief_pa` is the safe end of a range, `ReliefValve#setting_pa` reads a lever as *margin* defaulting to 100, and winding it down raises the setting toward `max_relief_pa` (9 atm, deliberately 63% of the shell's derived 14.39 so the shell is never the binding constraint). Measured gradient at cut-off 40 — margin 100/90/80/70/60/40 gives **364.1 / 406.8 / 451.9 / 499.9 / 552.6 / 653.2 kW** with wheel stress 0.27 → 0.49, bursting between 40 and 20. At **full gear the safe band is much narrower** (margin 70 bursts), so a driver can have high pressure *or* full gear and not both. Margin 100 leaves the engine bit-identical, and the load-shed hazard unchanged (burst at 0.97 against 0.96 before). It also makes the saturation masking a *choice*: at margin 90 and below the drum sits under its setting and is fire-limited again. |
| **The boiler sits on its safety valve at the nominal operating point, and that masks mechanics** | Found 2026-09-11 while attributing the stoking inversion. At damper 85 — which is what `LIGHT` and every sweep in this file use — the drum holds **608.0 kPa against a 607.95 kPa relief setting** across most of the stoking range, so it is feathering its safety valve continuously. Anything that makes the fire slightly weaker therefore has **no effect on power at all**, because the surplus was going over the roof anyway. Two mechanics are invisible because of it: the stoking falloff above the optimum (the fire measurably cools 903 → 886 K while power stays at 332 kW), and the ash choke (`steam_engine_spec`'s raking example inverted by 0.23%, pure noise, while its ash assertions still passed). **A saturated system reports every upstream change as zero**, which looks exactly like a mechanic that does not work. The honest fixes are a higher relief setting or a hungrier engine, not moving the lever that exposed it — deliberately left for the next pass. |
| ~~Stoking is inverted above ~60, and it has not been attributed~~ | **Closed 2026-09-11, and the hypothesis on the sheet was wrong.** It was not air starvation. Two measurements ruled it out: scaling the damper's **rate cap** to 4.0 / 6.6 / 9.0 kg/s gives **byte-identical results** at every stoking level and damper position (`max_kg_per_s` is inert beside a `conductance:` — see the new trap below), and scaling the **conductance**, which is real extra air, raises the whole curve (894 → 988 K at stoking 30) while leaving the slope unchanged at −60 K from stoking 30 to 100. Ash was ruled out too: raking 100 moved stoking-100 power by 5 kW out of 250. The cause is arithmetic and only visible if the lever is read as kg/s: **the fire needs ~0.12 kg/s of coal to establish, can usefully burn ~0.12–0.15, and the stoker was rated 0.60.** So the entire useful band sat below lever 25 and the rest was strictly harmful — the surplus banks as unburnt coal, which is cold thermal mass the fire then has to heat, measured at **401 kg sitting in a 6 m³ firebox** at damper 85 / stoking 100 against 22 kg at stoking 20. Rated at **0.25** the optimum lands at lever 50 with a rising limb below and a real falloff above (kW at damper 70, levers 30/40/50/60/80/100: 0 / 35.7 / 279.6 / 265.3 / 237.3 / 212.5), and the nominal point is almost unmoved — stoking 60 at damper 85 gives 332.9 kW against 332.1 — so the lever is re-centred without the engine being re-tuned. **Read a lever in the units the physics uses, not in lever percent**; as a percentage this looked like a mysterious inversion and as kg/s it is a ratio anyone can check against the reaction's stoichiometry. Still open: the window between "will not light" and "over-fuelled" is only 0.12 → 0.15 kg/s, which is narrow whatever the rating is. The original entry had also asked whether this predated the cylinder work — it did not matter; the stoker has been over-rated since it was written. It cost a spec on the way in, which is worth keeping: `steam_engine_spec` used to raise the throttle and the stoking together, so it measured two levers whose effects oppose and passed on the balance between them. **Isolate a lever before asserting on it.** |
| ~~Obstruction could not be expressed at all~~ | **Closed 2026-09-08** by `Concerns::Obstructs`. Volume occupancy had exactly two consequences — less room to accept (`Holds#room_m3`) and higher pressure for the gas left (`Pressurized#free_volume`) — and neither could say a deposit was in the **way** of anything. The concern measures occupancy against a **characteristic volume the node declares**, which is the whole idea: the 14.0 kg of water that destroys the cylinder is 7% of its volume and 100% of its clearance space, so against the node the hazard is invisible. Two callers with nothing in common but the fraction — a cylinder deriving a top-dead-centre pressure, a firebox throttling its reactions — which is the test it had to pass to earn a file. Design and the rejected alternatives: [`design_sketches/obstruction.md`](design_sketches/obstruction.md). |
| ~~A cylinder relief valve could not sense what destroys a cylinder~~ | **Closed 2026-09-08.** `pressure_pa` spreads the charge over the whole cylinder, so filling the clearance with enough water to wreck the engine moves it about 7% — there was no spike for a valve to lift on, because **a lumped body has no crank angle**. `Cylinder#compression_pressure_pa` reconstructs the pressure at top dead centre the way `mean_effective_pressure` reconstructs a diagram we never trace: 1.51× the dry figure at a quarter of a clearance of water, 2.56× at half, 17.7× at nine tenths, monotone throughout. `ReliefValve` gained `senses_quantity:` — **a valve pointed at the wrong quantity is worse than none, because it looks like protection**, and `obstruction_spec` asserts both halves. |
| ~~Composition could only be all-or-nothing~~ | **Closed 2026-09-09** by `Node#transport_affinity` — a per-part, per-tag multiplier on what crosses, as opposed to how much. Design and the rejected alternatives: [`design_sketches/tag_based_transport_overrides.md`](design_sketches/tag_based_transport_overrides.md). A stream used to carry the composition of wherever it came from in exactly the proportion held, with a binary tag gate as the only other control — two settings, and for a cylinder exhausting condensate up a chimney **both were wrong**. Verified inert: a neutral affinity on every vessel leaves the steam engine's digest bit-identical. |
| ~~Boiler priming was unrepresentable~~ | **Closed 2026-09-09.** `Nodes::Boiler` declares the **steam quality** it delivers and solves for the multiplier, because the multiplier is about 1.2 × 10⁻⁵ and nobody would have guessed it. Below 55% full it is a 99.5%-dry drum and invisible; above that the quality degrades and water goes over with the steam. Measured at throttle 60: feed 45 → 52.7% full, 0.005 wetness, a bone-dry chest and 369 kW; feed 90 → 73.3% full, **0.125 wetness**, water in the chest and **102 kW**. **The feed pump finally has a ceiling as well as a floor.** (Part of that fall is thermal — heating more feedwater — but the chest stays dry below the onset and only wets above it, which is the carryover.) |
| ~~Hydro-lock has a consequence but is not reachable~~ | **Closed 2026-09-09, and demonstrated rather than argued.** A primed boiler feeding a standing cylinder with the cocks shut reaches occupancy **1.11 by t=5000 and 2.87 by t=9000** — 40 kg of water in a clearance space that holds 14. The same run with the cocks open holds **0.0003**, and opening them at t=4000, with the cylinder already **55% of the way to lock**, clears it inside a thousand ticks. Reachable, preventable, and recoverable, with normal running unchanged (the feed sweep matches its pre-blow-through numbers to 0.2 rpm and 0.6 kW). |
| **A locked cylinder: the mechanism is proven, the engine-level demonstration is WITHDRAWN** | **Retracted 2026-09-10.** A run was reported here showing 56.6 kg of water in the cylinder at occupancy 4.06, destroyed at speed, and described as the historical failure reproduced end to end. **It does not stand.** It depended on boiler swell saturating, and at the time swell saturated on a *single-tick pressure spike* rather than on physics — see the two smoothing traps above. With a corrected signal the same scenario peaks at wetness 0.509 and occupancy 0.163, and the cylinder survives. The **mechanism** is still sound and is proven where it can be proven cleanly: `obstruction_spec` shows a flooded chest making the intake ask for 50× more, matching swept volume × supply bulk density, enough to fill the clearance inside twenty ticks — and the energy rule breaking a heavy wheel where a light one stalls. What is now open is whether the hazard sits inside the engine's **reachable operating envelope**, which is a balance question and not a settled one. **Do not write a spec against it until that is answered.** The old entry's diagnosis was right about the symptom and wrong about the cause. It was not that filling and breaking lived in disjoint speed bands — it was that **the piston never asked for a slug**. `displacement_kg` priced the swept volume at the working fluid's *gas* density, so a cylinder sweeping 0.0496 m³ a tick (49.6 kg if that volume is water) demanded 0.126 kg. A chest full of primed water handed it a few hundred grams. `Holds#bulk_density_kg_m3` is what a positive-displacement machine actually swallows, and with it the slug arrives. Three other things had to move with it: the boiler needed **swell** so priming is an event rather than a level, `Arbiter.entrained` needed to stop dropping liquid on a path with no declared opinion, and the steam line's ports had to be rated for water rather than steam. The old advice still holds — **do not close this with thresholds**; the whole `lock_omega` idea is gone, replaced by asking whether the driveline has the energy to compress the charge. |
| **Four mass-for-volume confusions now, and it is the signature bug of this codebase** | `contents_volume` read as a level (a 317%-full boiler). A transport affinity set without regard to the mass ratio it works against (needed 1.2 × 10⁻⁵, a 10⁻³ floor made it violent priming). A clearance priced as 0.029 kg of steam, so the piston expelled 14 kg of water from a space that could not hold it. And now a swept volume priced at gas density, which made hydraulic lock at speed arithmetically unreachable. Every one of them looked like a tuning problem and was found only by measuring a mass budget. **When a quantity is a volume, carry it as a volume** — and when a rule converts between the two, the conversion is the first place to look. |
| ~~Feedwater arrives with no preheat~~ | **Closed 2026-09-10 by `Nodes::Vessel` wired as an injector** — live steam and cold water meet in a small vessel, the steam condenses into the water and the hot mixture goes to the drum. No new class: the saturation solve already does the condensing and `h = c·T + h_f` already makes the latent heat exact. Feedwater now arrives at **357 K** instead of 293 K, halving the cooling, and it **costs steam rather than heat** — about 0.28 kg/s at full feed, diverted from the cylinder — so filling the boiler and pulling hard finally compete for the same supply. Design and the rejected cheap version (warming the tank, which is free and therefore deletes the trade): [`design_sketches/injector.md`](design_sketches/injector.md). |
| **Priming is still out of reach, and it is now a ratio rather than a mechanism** | The injector was expected to open the envelope and **did not**, which is worth recording because the controlled experiment said it would. Warming the supply tank to 370 K let the boiler stay at 432 K at *every* feed setting and a regulator slam at feed 80 reached occupancy 3.346 — but that experiment handed out **free** hot water. A real injector charges for it, so overfeeding still costs, and overfeeding is unavoidable: **the pump moves 2.5 kg/s against roughly 1 kg/s of evaporation**, so raising the glass from 50% to 80% means running 2.5× over for around 6 000 ticks. What blocks the hazard now is feed capacity against evaporation rate, and boiler volume against firing rate — **balance numbers, deliberately left for the balance pass.** The lesson for next time: a free-parameter experiment proves *which quantity* matters, never that a priced version of it will behave the same. **Partly addressed 2026-09-11** in the first tuning pass: the pump is now **2.0 kg/s** and the injector takes a true 1:10 of it (0.20 kg/s, down from 0.28 — it was quietly the engine's largest single steam consumer at ~28% of what the drum could raise). Measured evaporation is also lower than this row claims — **0.42–0.57 kg/s**, not 1 kg/s — so the ratio is still roughly 4:1 and the glass sits stable at 47–53% at feed 40. |
| ~~The draught gauge could only ever say "thin"~~ | **Closed 2026-09-10, found by a player, and provable without running anything.** Bands were 0.5 / 3.0 / 10.0 kg of air held in the firebox — but a 6 m³ box **entirely full of pure air** at 900 K holds 2.35 kg, so "adequate" and "strong" asked for more air than the vessel can physically contain and were unreachable by construction. It read "thin" through half a megawatt. Measured across the damper the signal is fine — 0.0083 / 0.0269 / 0.0477 / 0.1744 / 0.3669 kg at 20 / 40 / 60 / 80 / 100, **44× and monotone**, tracking a fire of 333 → 715 K and an engine that will not turn below damper 80. Only the calibration was wrong. **Check a band against the range the quantity can actually occupy**; an unreachable band is a phrase that never displays, and nothing fails loudly when it does not. |
| **A boiler filled solid with water makes the pressure model swing wildly** | Feed 100 with a fire that cannot evaporate it drives the liquid to **100.0% of the drum**, at which point `Pressurized#free_volume` is sitting on its 0.1% floor and the pressure swings ±23 kPa/s on nothing — which then saturates swell and pins the glass at its display ceiling. A boiler primed solid is a real and dangerous condition, and arguably a pressure that spikes is *correct*; what is missing is any **consequence** for reaching it, so today it is just a numerically ugly corner. Needs a design decision, not a clamp. |
| ~~Nothing punishes a **low** water glass~~ | **Closed 2026-09-12 by the crown sheet.** Feed 0 used to run happily at 357 kW while the drum emptied — a lever with a ceiling and no floor. The missing piece was genuinely missing physics rather than a missing rating: **a lumped drum at 5% water is not hot, merely empty**, holding the same saturation temperature a full one does on a smaller mass, so no `max_temperature_k` on the boiler node could ever trip however far the water fell. The failure is *positional* and a lumped model has no positions. `Boiler#crown_temperature_k` gives the plate its own temperature, blended between the water it should be under and the fire it is over by `crown_exposure`, and `stress_per_second` is measured against that instead. Measured: the plug blows at tick **5538 / 6522 / 8079 / 10930** at feed 0 / 10 / 20 / 30, and feed 45 is safe indefinitely — so the hazard scales with neglect rather than arriving as a cliff, and normal running (feed 40–60) is untouched at crown exposure 0.00. **The trap is that the glass shows the swelled level and the plate is cooled by water**, so the needle reads comfortable exactly when a hard pull is uncovering the plate: measured, the glass read **20.1%** on the tick the plug went. That is the classic accident, not a contrivance. |
| ~~Thermal damage is fully built and has never been switched on~~ | **Closed 2026-09-12.** `Vessel#stress_per_second` and `Conduit#stress_per_second` had both fatigued on `max_temperature_k` since `Wearing` landed, `Wearing` accumulated it, `integrity` surfaced it — and `grep -rn "max_temperature_k:" lib/ content/` returned **nothing**, so every node shipped `Float::INFINITY` and the first branch returned 0.0 every time. Complete, wired, and inert. Ratings now live on the **material** (`content/resources/materials.yml`), resolved by `Concerns::Thermal#rated_temperature_k`: an explicit `max_temperature_k:` on the part wins, else the part's `material:`, else infinity. That is where a rating belongs — it is a property of the metal, and a hundred future operations must not each invent their own number for "steel" — while `stress_rate` stays per-part, exactly as `safety_factor` does on the flywheel. `content_spec` now refuses a `:structural` material with no rating, because **a default of infinity is a silent off switch** and nothing fails loudly when one is missing. |
| **The fusible plug is a fuse, and had to not be a `ReliefValve`** | Recorded 2026-09-12 because it was nearly built the wrong way. Both sense a quantity on another node and open above a threshold, so `ReliefValve` looked like the obvious base class — but **a relief valve re-seats and a fusible plug does not**, and that single difference is the whole character of the part. Built on the reversible one, a boiler would have quietly healed itself the moment water came back over the plate: exactly the consequence-free behaviour the low-water hazard exists to not have. `Nodes::FusiblePlug` latches `melted` in state instead. It also senses a **state key** rather than a method, because `Context#node_reading` calls `method(state, content)` and the crown temperature depends on the firebox — a cross-node read has the wrong arity for it entirely. One node owns the derivation and records it; everyone else reads the key, the way `Conduit#blast_pa` already reads the cylinder's `exhaust_kg`. |
| **The plug always saves the boiler, and the explosion is underneath it** | Measured 2026-09-12. With the plug fitted, the crown peaks at 620 K (its melting point), the boiler keeps integrity 1.00 and no `vessel_rupture` fires in any run — correct, that is what the part is for. Scale the plug over (`melts_above` set absurdly high, which is what "scaling a plug" meant and was a sacking offence) and the hazard is plainly there: crown reaches **1152 K** and the boiler ruptures at tick **7088** at feed 0, **10316** at feed 20, with the tubes bursting after it. So the iconic failure exists and the safety device is what stands between the player and it — which is the risk/reward shape the modularisation plan wants, where automatic safeties are a luxury part a player may choose to go without. |
| **A rate of change measured across one timestep is solver noise, not a signal** | Boiler swell was driven by `(P_prev − P_now)/dt` taken raw. A single-tick 2.3 kPa dip on opening the regulator read as **9 102 Pa/s** — past the 8 000 Pa/s that saturates the mechanic — so the void went from nothing to maximum in 250 ms and **the gauge glass jumped 40 percentage points in one tick**, then decayed for twelve seconds. Every isolated blip did it. Found by a player driving the UI, not by a spec, because it looks like a plausible transient in a table and like a broken instrument on a dial. **A derived transient needs a physical time constant**, and here there is a real one to cite: bubbles take finite time to nucleate, so a void fraction cannot track a 250 ms pressure blip. Smoothed over `swell_rise_s`, a sustained demand step still saturates within seconds while one tick of noise reaches a tenth of the way. |
| **Smooth the signed quantity and rectify afterwards, never the other way round** | The first attempt at the fix above rectified first — `max(rate, 0)` then averaged — which takes the mean of `\|x\|` where the mean of `x` was wanted. A symmetric tick-scale ripple with **no net drift** then averages to a large positive "fall" out of nothing, and swell pinned at its 45% maximum permanently whenever the engine was working: the glass read **92.1% full on a drum genuinely 50.6% full**. The arithmetic that caught it is worth copying — a sustained 8 kPa/s for the 1 050 s it supposedly held would have dropped the boiler by 8 MPa, eighteen times its actual pressure. **When a smoothed signal implies something impossible over its own window, suspect the smoothing, not the physics.** |
| **A linear valve is not a linear control, and the lever's authority lands where the solve saturates** | Found by a player: the regulator "has almost no effect". It has plenty — 3.37× of power across its travel — but **5 → 30 does 79% of it and the top 70% of the lever delivers 21%**. A pressure path settles `n = k·dt·ΔP / (1 + k·dt·ΣC⁻¹)`, and the regulator's full-open value of that second term is **1.76**: past 1 the two ends substantially equalise within a tick, so 5× more conductance buys 2.4× more flow. Measured, the chest reaches 85% of drum pressure by lever 30. Fixed with **equal-percentage valve trim** (`Conduit#rangeability`), which is the standard answer to a valve working into a system that saturates and leaves the full-open figure untouched. **Check where a lever's authority actually lands before concluding it is undersized** — and note the first attempt at the trim over-corrected, moving the dead zone from the top of the travel to the bottom, so this wants picking from a sweep rather than from the algebra. |
| **Pick the driver that is zero in steady state** | Boiler swell was first scaled by **offtake rate**, which sounds like the same thing as "working hard" and is not. It taxed steady running — a hard-pulling engine at a perfectly safe level sat at 20% void forever — while giving almost nothing on the transient, because opening a regulator that is already 60% open barely changes the flow. And it is **anti-correlated with the hazard**: a drowning engine is slow, so it pulls less, so it swells less, exactly when the glass is highest. Scaling by the **rate of pressure fall** is what the sources describe (demand outruns generation → pressure drops → saturation temperature drops → the water's own sensible heat flashes it), and it is zero in steady running of any intensity, so normal operation is untouched *exactly* rather than merely a little worse. **When a mechanic is meant to be an event, drive it with something that is zero when nothing is happening.** |
| ~~The cylinder relief valve passed water in exactly zero states~~ | **Closed 2026-09-09.** Fitted to relieve hydraulic lock, permissive on both ports, sitting under a comment reading *"Permissive, because what it has to pass is water"* — and it had never passed any. Lifted, its `conductance: 0.02` made the path **pressure-driven**, where `Arbiter.entrained` dropped liquid outright because the cylinder declares no affinity for `:relief`; shut, `throughput_kg` was zero. Two states, no water in either. Worst in the case it exists for: a fully locked cylinder holds no gas, so `mean_molar_mass` returned nil and the path carried nothing whatever. **The regime a path lands in is structural** — any conductance-bearing path whose ends declare no intent — so this was quietly the rule for most of the graph, not an edge case. Liquid now falls to the same proportional rate term solids take. |
| **`Arbiter.entrained` shipped with no test coverage at all, and that is why** | `grep -rn "entrained" spec/` returned nothing. `transport_affinity_spec` builds its rig from a conduit with **no `conductance:`**, so all 13 of its examples exercise the rate-driven branch and the entire pressure-driven half of settlement went untested from the day it landed — including the additive-total semantics, the amplification cliff, and the liquid-dropped rule above. `spec/reactor_sim/entrainment_spec.rb` now covers it. **A rig that cannot reach a branch is not coverage of it**, and the tell was there in the fixture: a spec about pressure-driven transport whose pipe declares no conductance is testing something else. |
| Two wrong explanations for it, both worth keeping | It took three attempts to find out why the cylinder would not fill, and the first two were confident and wrong. **"A cycle averaged over a revolution cannot represent a slug"** was wrong: per-revolution admission is `water_kg_per_tick ÷ revolutions_per_tick` and every term of it is already in state — nothing was being averaged away. **"Condensation will be the route"** was also wrong, and the arithmetic says so: filling the clearance by condensation needs 31.6 MJ of latent heat removed, and at `ambient_conductance` 25 W/K over ~87 K that is 2.2 kW, or 57,500 ticks. **Priming is the route precisely because the water arrives already liquid and no heat has to be shed** — which is what the sources meant by "the water volume is far greater than that from condensation". Both times the real cause was an ordinary bug, found by measuring the water budget rather than by reasoning about it. |
| ~~Warming through was not a procedure, because the cylinder warmed in three seconds~~ | **Closed 2026-09-12.** The drain cocks are meant to matter during *starting* — a cold cylinder condenses a great deal of what is admitted to it, which is why the real procedure is *cocks open, crack the regulator, warm through, shut the cocks*. It was unreachable, and the cause was one constant: `heat_capacity: 6.0e4` J/K against a charge of ~0.25 kg of steam a tick carrying ~2.75 MJ/kg, so the metal rose ~11.5 K per tick and reached steam temperature in about a dozen ticks. **Three seconds.** Peak occupancy over a whole startup was 0.188 — "damp", and nothing a driver would act on. Taken from the casting instead: 0.45 m bore, 1.1 m stroke, ~25 mm wall gives a barrel of 0.041 m³ and two covers of ~0.016 m³, so 410 kg of cast iron at **189 kJ/K** before counting the piston, rod, cover bolting or valve faces. **4.0e5** is about twice the bare barrel. Measured peak occupancy with the cocks left shut: **0.188 / 0.579 / 0.859 / 0.924 / 0.947** at hc 6.0e4 / 2.0e5 / 4.0e5 / 6.0e5 / 8.0e5. At the shipped figure the engine reads **"knocking badly"**, lifts the cylinder relief valve (0.28), takes **no damage**, and clears to 0.004 once it is turning — a scare that teaches the procedure rather than a death sentence for forgetting it. Opening the cocks holds it at 0.002 and costs ~5% of the power; opening them and shutting them at the right moment gives 0.006 **and full power**, which is what makes it a procedure rather than a toggle. **Per-variant**, because the atmospheric cylinder is a different casting: 2.0e6, which is 5× rather than the 9× the raw volumes suggest, because shell thickness goes as `p·r` and 1.4 atm across a 0.65 m radius is a gentler duty than 6 atm across 0.225 m. That engine still does not need its cocks (peak 0.086) and should not — **it exhausts to a condenser, which drains liquid continuously**. |
| ~~The cylinder cocks are a cliff, not a trade~~ | **Re-measured 2026-09-10 and the old entry was wrong on both counts.** It is not a cliff and the `extractable_joules` bound is not the cause. Swept at throttle 60 / load 80: **233 / 179 / 135 / 100 / 75 / 54 kW** at cocks 0 / 10 / 25 / 50 / 75 / 100 — smooth and monotone, every notch of the lever costing its share. The clamp sat at **0.962–0.974 across the whole sweep**, with 0.9–2.8 MJ extractable against a 14–60 kJ demand, i.e. 20–60× headroom and barely varying: it is inert, not the mechanism. **The steam chest fixed this without anyone noticing** — the cocks now act through chest pressure (440 → 256 kPa across the sweep), because a vented cylinder keeps drawing to refill its clearance and the chest depletes, so `P₁` and the MEP fall with it. That is the honest route, and the old note was describing a machine that no longer existed. **A stale measurement is worse than none**: it was cited twice as a reason not to touch the cocks. |
| ~~A standing cylinder admitted almost nothing~~ | **Closed 2026-09-09.** `admission_kg` at rest returned only `clearance_fill_kg`, a static top-up that stops the moment the pressure equalises — so a stopped engine with the regulator open took in almost no steam and the cocks had nothing to drain. A stopped cylinder is not sealed: the valve is wherever the crank left it and steam blows straight through, which is the noise a stationary locomotive makes and the reason its cocks stream. `blow_through_kg` is that flow, fading out as the engine picks up and displacement takes over. Measured before: 0.374 kg in nine thousand ticks, plainly asymptoting. After: lock in about 2,600. |
| ~~Neither relief valve was visible to the player~~ | **Closed 2026-09-11, raised from a playtest.** Both safety valves acted entirely unsupervised and unwatched: the boiler could sit blowing off — wasting water and heat over the roof — with nothing on the panel saying so, and the cylinder relief could lift without a word. The cause is structural and general: **a relief valve is transport, so it holds nothing and `Arbiter` leaves no trace of it in state**, and there was simply no quantity for a `Field` source to read. `ReliefValve#apply` now records `lift:` purely so an instrument can see it. Two gauges: `safety_valve` (prose, and deliberately **no lag and no noise** — a valve blowing off is the loudest thing in the building, so the player is not reading a dial) and `cylinder_relief_valve` (a lamp, because there is nothing progressive about it — it is set above any pressure ordinary running reaches, so any light at all means trouble). The boiler valve also gained an **easing lever**, which is the real part: `max(lift, eased)`, so it can only ever open the valve further than the spring has, never hold it shut. |
| Pressure model is minimal | Ideal gas over free volume. No hydrostatic term and no flow-induced pressure drop; pump and fan head exist as a conduit's `head_pa`. |
| ~~The ledger records **net** boundary flow, not gross~~ | **Closed 2026-09-05.** `Atmosphere#apply` used to net its intake against its exhaust inside one tick: 68.06 kg drawn in and 103.12 kg pushed out were booked as `mass_added` **0.00** and `mass_vented` 35.06, so nothing built on the ledger could measure anything. It now reads `grant.sent` and `grant.received`, which are gross. This is also what turned `Grant#sent` from a bare kg figure into the parcels themselves, and what exposed a second bug — `received` was built from the parcels the *source* dispatched rather than what survived the conduit walls, crediting a sink with energy still sitting in the pipe. |
| ~~The fire and the boiler could not both be hot~~ | **Closed 2026-09-05**, by giving the gas a second route to the water: a `boiler_tubes` conduit between firebox and chimney, thermally linked to the boiler. With only the one conduction link, the firebox temperature was pinned at `T_boiler + Q/k` — so a realistic fire and a well-fed boiler were mutually exclusive, and weakening the link to get one starved the other (measured: k = 9000 gave 676 K; k = 1000 gave the same 692 K on a fifth of the burn, and the engine never turned). Measured after: **2331 kW into the water at a 896 K firebox, against 2300 kW at a 676 K one** — same heat, a fire twice as far above its surroundings, and more power out (50 kW against 41). |
| **Two entries here were wrong and are corrected** | A first pass at this analysis claimed "90% of the fuel goes up the chimney" and blamed the firebox's low temperature on 197 kg of coal being 85% of its thermal mass. **Both were misread.** The 90% came from `joules_advected_out`, which is gross enthalpy against a **0 K** reference and is dominated by the exhaust *steam's* 3.07 MJ/kg of formation enthalpy, not by flue gas — the actual stack loss was ~18%, and most of the rest is latent heat leaving with the exhaust of a non-condensing engine, which is real and is precisely why Watt's condenser mattered. And the coal's thermal mass sets the firebox's *response time*, not its equilibrium: `T_firebox − T_boiler` tracked `Q/k` exactly across the sweep above. **Do not read a 0 K-referenced ledger line as a loss fraction**, and check a temperature against its heat balance before blaming a heat capacity. |
| ~~The cylinder is a tank, not a cycle~~ | **Closed 2026-09-08**, and it took four separate fixes because one node was doing three jobs. It now works an **indicator diagram** — admit to `cutoff`, expand along `pVⁿ`, exhaust against back pressure — with a positive-displacement intake sized at *supply* density, drawing from a **steam chest** rather than straight from the boiler. See [`design_sketches/cylinder_solutions.md`](design_sketches/cylinder_solutions.md) for the analysis and the options that were rejected. Cut-off is now a real economy lever with an **interior optimum** near 40%: at an open regulator, steam falls 1.000 → 0.041 kg/s across the range while `kW per kg/s` runs 478.8 → 618.3 → **688.7** → 612.5 → 324.3. The optimum is not tuned — it is the fixed back-pressure subtraction eating a growing share of a shrinking MEP, which is exactly why a non-condensing engine cannot notch as far as a condensing one. |
| ~~The regulator was a conservation clamp~~ | **Closed 2026-09-08.** With the diagram reading the boiler, the throttle rationed *how much* steam arrived but said nothing about the pressure it arrived at, so it could not affect torque at all — and `extractable_joules` in `Tick#transmit_torque` silently became the throttling mechanism, measured **discarding 30–50% of declared work** (scale 0.496 at throttle 20, 0.698 at 60) with declared torque nearly flat across the range. A steam chest between regulator and valve closes it structurally: swallow faster than the throttle can pass and the chest depletes, so admission density *and* P₁ fall together. The clamp is now inert at 0.957–0.960 and declared torque rises with the regulator as it should. **A conservation clamp is not a mechanism**, and it fails silently when used as one. |
| ~~A burst flywheel keeps accelerating~~ | **Closed 2026-09-05.** It used to burst at 400.8 rpm against a 321.6 limit and be doing **2364.7 rpm and 3.97 MW** 600 ticks later. `Tick#stress` now zeroes a broken rotor's momentum and ledgers the kinetic energy it was carrying; `settle_drive` drops couplings to a broken part and `transmit_torque` will not drive one. Generic, in one place. **Still open for holders:** a broken vessel does not spill, for the same reason a ruptured conduit still acts as a plug — it needed a rupture size, which is a failure-model decision rather than a transport one. **Decided 2026-09-14** in [`design_sketches/blueprints.md`](design_sketches/blueprints.md) §3; the code is still to write. |
| ~~`Load` is a constant-torque brake~~ | **Closed 2026-09-05.** `Load` now has a torque curve — `:fan` (τ ∝ ω²), `:viscous`, or `:constant` — absorbing `max_torque` at `rated_omega`. A constant-torque brake has no stable intersection with a prime mover's torque curve, which is why the engine sat on a knife edge (throttle 80 → 452 rpm, throttle 100 → 1211 rpm). It also inverted the danger: full load used to be the *safe* setting. |
| Phase solve dominates the tick | ~50% of a 100-node step. `Saturation::ITERATIONS` (currently 20) is the dial. |
| `min_temperature_k` is a modelling compromise | Means "bulk temperature at which the reaction sustains", not ignition — a lumped-temperature node has no hot spot to light. |
| Suite is slow | ~2.5 min, dominated by the steam engine's long startup runs. |
| The atmospheric engine's condenser is capacity-limited | ~0.18 kg/tick of steam, set by `ambient_conductance × ΔT` over the latent heat. Fed the high-pressure draught it cannot keep up and the vacuum it exists to pull collapses, so the variant runs a smaller fire (`draught_kg_per_s: 4.0`). **Investigated and NOT a phase-solve bug** — in isolation a cold vessel condenses 2.3 kg of steam to 0.26 kg over 12 ticks, pressure falling 104 → 12 kPa. A more powerful Watt engine needs a bigger condenser, not a fix. **Corrected 2026-09-12:** this row used to say the variant runs a smaller fire via `draught_kg_per_s: 4.0`. That constant was inert and has been deleted — the fire size comes from `damper_conductance`, 0.1 against the high-pressure engine's 0.35. |

---

## Before the mine

Four things, and **two of them are not features** — they are places the delivery tier names the
steam engine by constant, so a second operation type cannot reach the same code path.

| | | |
|---|---|---|
| ~~**1**~~ | ~~**Crew capacity + Crew Quarters**~~ | **Done 2026-09-18.** Seats replace roles, a required `:crew_quarters` slot carries `crew_capacity` and the origin station, and everybody starts there. Three effort stations against two seats. See [`crew_capacity.md`](design_sketches/crew_capacity.md) §8. |
| ~~**3**~~ | ~~**Registry introspection**~~ | **Done 2026-09-18, with crew capacity.** `Operations.register` takes an `assembler:`; `Operations.assembly_for(type, chassis:, loadout:)` answers what a build would be. `Crewing` and `DevMatch` no longer name `Operations::SteamEngine`. |
| ~~**2**~~ | ~~**Driven transport**~~ | **Done 2026-09-19**, stages A–E. `mass_delivered` on the ledger, the shaft adapter on `Conduit` (`driven_by:`, `lift_m:`, `efficiency:`, `delivers_to:`), `Nodes::Motor`, and the blower split into Hand Bellows and Donkey Blower. See [`driven_transport.md`](design_sketches/driven_transport.md) §7. |
| ~~**4**~~ | ~~**`DevMatch` gains an operation axis**~~ | **Done 2026-09-19** with operator identity. `DevMatch::OPERATION_ID` and `DevMatch::TYPE` are gone; `OPERATIONS` is a list and the dev match runs **two steam engines in lockstep**. See [`operator_identity.md`](design_sketches/operator_identity.md) §8. |

**All four pre-mine blockers are closed.**

**Driven transport — built 2026-09-19, stages A–E.** The blower was *"a pressure source with a
lever on it and nobody paying the bill"*, and now there are two ways to pay: a **Hand Bellows**
that costs a person on the handles continuously, and a **Donkey Blower** that costs fuel oil out
of its own tank. Both honour the black start — neither depends on the engine they are lighting.

Measured on a cold start, and the donkey reproduces the pre-release machine exactly:

| blower | fire | boiler | air | 500 kPa at |
|---|---|---|---|---|
| donkey | 1015.9 K | 608.8 kPa | 3.093 kg/s | **t=1600** |
| bellows, manned | 897.3 K | 608.1 kPa | 0.927 | **t=3800** |
| bellows, nobody on it | 667.8 K | 67.4 kPa | 0.302 | never |
| none fitted | 667.8 K | 67.3 kPa | 0.302 | never |

An unmanned bellows is **identical to no blower at all**, and nothing implements that — an
unmanned effort station already delivered nothing. The donkey's 3.093 against the old 3.199 is
the governor working: it holds ω at 58.4 of a rated 60, so the fan sees `(58.4/60)² = 0.947` of
its head.

> **Natural draught already existed and nobody had noticed.** 0.302 kg/s with no blower at all —
> enough to keep a fire alive at 668 K, never enough to raise steam. That deleted the sketch's
> own fallback plan (§3.4: *"if a bellows cannot raise steam, add natural draught"*), because it
> was already there and already counted.

> **The bellows ships whole rather than at its sustainable figure**, which the sketch said it
> could not. Fatigue landing first is what changed: the top of the lever is priced, so working
> flat out to raise steam in 3800 ticks instead of 1600 is a decision with a cost rather than a
> free slower button.

**Deliberately not blockers**: snapshots + offset commits, match lifecycle, Turbo incidents and the
`console_controller.js` split, auth, `ControlLink`, the `boiler.md` failure modes, Chemical Vats.
None of them is reached by building a second operation. **Probabilistic injury is Tim's to design**
and is sequenced after, not before.

**The open design question is answered** in [`design_sketches/mine.md`](design_sketches/mine.md):
getting people to the face needs real distance, and the mine is a single-seam bord-and-pillar shaft
colliery in its fan-ventilated era. Space is modelled as volume nodes on the existing graph, so one
topology carries men, material, air and water. Power arrives from the upstream operation as an
**imported shaft** — a real rotating body the pump and fan couple to — which is the first thing that
has ever crossed between two operations and wants its own sketch before code. Coal goes outward to a
third operation, never back into the engine.

---

## What to do next

**The minion release is built — all seven stages, 2026-09-16.** Design and findings in
[`design_sketches/minions.md`](design_sketches/minions.md). Individuals rather than jobs, equipment
in three slots, training, injury through a Danger Check, and a crew that is load-bearing on the
machine's output. What landed:

- **The noun is corrected.** What you unlock is Jim, not "fireman". `content/` splits into
  `archetypes/` and `minions/`, a four-layer sheet resolves archetype → individual → training →
  equipment (**merge adds, use multiplies**), and the catalogue carries blueprints across six kinds.
- **The crew rides in `options:`**, which `definition.rb` had been warning about since the crew was
  written — a restored snapshot now rebuilds the *same* crew.
- **Injury needs no dice.** `resilience` is rolled once at `initial_state`, an already-permitted
  entropy point, so every Danger Check is a deterministic comparison: replay, order-independence
  and snapshot safety with no amendment to the invariants. Hazards resolve through **stations**,
  which gives coarse place with no geometry and upgrades cleanly when volumes arrive.
- **Effort stations replaced `stiffness`** — the lever is intent, the crew supplies the rate. A
  locomotive cannot be run by day-labourers; a competent human reproduces the tuned machine.

**Movement and the spatial model are the release after**, deliberately. The mine's release
sequence is in [`design_sketches/mine.md`](design_sketches/mine.md) §4.6: the inter-operation
shaft first, the spatial model second, both provable on a rig before a mine exists.

Steps 1–4 of the original vertical slice are **done** — the prototype is playable in a browser.
What remains, in dependency order:

1. **Play it.** The whole point of the prototype. Drive the startup procedure by hand, find out
   whether the skill gradient is legible through instruments rather than through `telemetry`,
   and whether 250 ms feels responsive.
2. **Snapshots + offset commits** — snapshot to `match.snapshots` embedding the command offset,
   *then* commit. Then the crash-recovery drill. This is the largest deferred piece and the one
   the `auto.offset.reset: latest` shortcut is standing in for.
3. ~~**`match.events`**~~ — **done, 2026-09-15.** The durable record exists end to end:
   `ReactorSim::Event` with an enumerated vocabulary, transitions the machine reports
   (`fire_lit`, `fire_out`, `heater_engaged`, `steam_raised`, `blew_off`) alongside
   `part_failed`, `EventProducer` dual-writing beside `ViewBroadcaster`, absolute meter
   readings every 40 ticks, two karafka consumer groups, five tables, and a channel that
   backfills a joining client from the log. **`Achievement.earned?` reads `awards` now** rather
   than returning true for everything, so the `requires:` gates in `config/blueprints.yml` are
   live. Design and findings: [`design_sketches/event_system.md`](design_sketches/event_system.md).
4. **Turbo incident broadcasts** — the first ViewComponent that earns its keep, replacing the
   client-side incident list.

   **Refactor `console_controller.js` while you are in there.** It has grown past the point where
   one Stimulus controller should hold it: subscription and resync, delta merging, gauge painting,
   lever painting and optimistic lever state, the incident feed, the backfill, and now the crew
   panel. Several of those are independent concerns that happen to share a socket. The Turbo work
   removes one of them outright (the incident feed), which makes this the natural moment — split
   the rest by what they paint rather than letting the file keep accreting. **Cheaper than it was**: there is now an `incidents` table to
   render from rather than a transient projection, and `Incident.backfill` already produces the
   shape.
5. **Match lifecycle** — real creation, `match.lifecycle`, and the end of `DevMatch`. This is
   also what retires the "web process rebuilds a Match to get the panel" shortcut. **No longer
   blocks progression**: `run_id` already carries the identity lifecycle will key on, and every
   fold closes on a transition the engine emits, so a match that never ends still banks what it
   earned.
6. **Probabilistic injury** — **Tim is designing this one**, after the currently open work closes.
   It introduces *"an accident happened"* as a thing with a **likelihood**, which is today
   inexpressible: the only route into harm is a `failure_hazards` table on a part that has just
   broken. Fatigue is one of its natural inputs.

   **The distinction it turns on, which cost a wrong line in the fatigue sketch.** A tired worker
   gets their hand caught in the belt; **the belt does not then care how tired they are.** So
   fatigue belongs on the *incidence* of an injury and never on its severity — and the
   obvious-looking seam is the wrong one, because `Injury.resistance` reduces the **bite**, so
   wiring fatigue there would say a tired body is mangled worse by the same blast. `Injury` is
   deliberately untouched by the fatigue release for this reason.

   Build nothing before then that assumes every injury originates in a part failing.
7. **Auth**, then the rest of the deferred minion work (the `observer` gauge path, finite lever
   stiffness for a control that should genuinely take time to travel), then the failure modes
   from `design_sketches/boiler.md`, then Chemical Vats.

**Frictional bearings, and the load's integrator goes first.** Designed in
[`design_sketches/bearings.md`](design_sketches/bearings.md): a bearing is a **modelled friction
interface** — a place where enough rubbing happens that the heat and the wear should be real — so
one node class covers a journal under a flywheel, a piston in a bore, and a rope over a pulley
later, with `duty:` supplying the kinematics. A coarse Stribeck law (boundary term
load-proportional, Petroff term load-independent, blended by an oil film fraction) puts the
dissipation into the bearing's **own joules** instead of the `joules_to_friction` exit, which is
what makes over-temperature wear, the hot-box runaway and seizure all fall out of one mechanism.
`Cylinder#efficiency`'s 0.85 is deleted and replaced by a `:slide` bearing — it is a torque derate
that is never ledgered, and folding it in is also what finally makes cylinders wear from ordinary
hard running rather than only from hydraulic lock. Oiling becomes a dexterity-led effort station.
**Stages A to D are done, and the engine measures 88–90% mechanical efficiency across 3× power
and 2× speed** (rings 7.7–10.2%, journals 0.2–0.4%, belt 1.5–1.6%). A put drag inside the drive
solve; B added the `lubricant` tag, the `bearing_oil` resource, a required `:oil_store` slot
holding 180 kg and an `oil_remaining` gauge; C brought `Nodes::Bearing`, the two-term friction law
and bearing heat; D fitted the `:slide` bearing and deleted `Cylinder#efficiency`.

**E is done too, and the hot box is real.** `Nodes::Bearing` carries `Wearing`; one fraction
(`SERVICE_FRACTION = 0.8`, which the research picked — babbitt melts at 235–370 °C and is run to
150 °C) turns the material's own rating into both thresholds. A starved journal **wipes at +119 s
and 487.9 K, then seizes at +150 s and 520.1 K** — a 31-second warning window — and the seizure
collapses the shaft from 167.7 rpm to 26.9 and shaft power from 400 kW to 57. Two instruments make
it visible: `bearing_temp` (lagged needle, scaled to the babbitt) and `bearing_condition` (prose,
exempt from upgrades like `flywheel_condition`). Full write-up and measurements in
[`design_sketches/bearings.md`](design_sketches/bearings.md) §6.5.

**F is done, and the ladder is now reachable in play.** Bearings draw oil through an `:oil_in`
inlet, spend it by **sliding distance** rather than by the clock, and book it to a new
`mass_consumed` ledger line — neither a vent nor a spill, because an engine working properly
would otherwise read as one that is leaking. `:lubrication` is a required slot with
`:hand_oiling` in it: one `:oiling` lever, two oil lines, `effort: { dexterity: 0.6,
intelligence: 0.4 }` — the first station in the game that is not a strength check and the first
thing that has ever read `intelligence`. With nobody sent to oil, the journal **wipes at 524 s
and seizes at 632 s**; conservation holds to 2.1 × 10⁻¹⁵. §6.6 has the rest. **G is next.**

Two findings from F, and both are about design rather than physics:

> **Adding a crew role to a station is how you accidentally un-design a mechanic.** The first cut
> gave `:oiling` an `:oiler` role, and an unfilled role gets `Crew::STANDIN` — so a posted oiler
> is somebody permanently on the round for free, and the "nobody oiling" run still filled its
> bearings. A station meant to compete for somebody's time must have **no role of its own**, so
> that manning it costs the fireman's place at the shovel.

> **`Intent.none` does not mean "I want nothing".** A path with nothing declared at either end is
> driven by the *path*, so a bearing that stopped declaring a draw once full kept taking oil until
> its housing was full — 8.9 kg into a 1.2 kg charge, and nothing could ever run dry again.
> `rate_desired` tests `draws.key?`, not `positive?`: declare the zero.

**G is next and carries three things**, not just the catalogue: the parts themselves, **Archard
wear** (§3.10) and **melting out** (§3.11). The seizure was audited and is honest — conservation
exact to 2.3 × 10⁻¹⁵ through the failure, every joule traceable — but its *temperature* is
unbounded, and only lands somewhere defensible because this flywheel is small; a heavier one takes
the same bearing to 15,563 K. The fix is the event a hot box is actually made of: the white metal
melts and runs, carrying its latent heat out.

> **It does not bound the temperature, and the sketch expected it to.** Measured: 6 kg of babbitt
> takes 31 K off the spike and **nothing** off the 1652 K equilibrium, because a seizure dumps
> 480 kJ of shaft energy in its first tick — more than the whole lining can absorb. A phase change
> caps a temperature only when the heat arrives slower than the latent heat can take it, which is
> true of a plug warmed through a crown sheet and false of a bearing absorbing a flywheel. What
> would actually bound it is **radiation** — `ambient_conductance` is linear and a body at 1650 K
> radiates as T⁴ — and that is a change to `settle_ambient` touching every hot node.

What melting does buy is still worth having: `:seized` gets a reason a player can be told (the
lining ran out and the carrier is riding the shaft), and a re-babbitting job becomes the obvious
first in-match repair.

It lands as `Concerns::Fusible`, because **`Nodes::FusiblePlug` is the bespoke version of the same
idea** — it reaches the outcome by proxy, sensing the crown sheet's recorded temperature against a
configured threshold and latching, with no mass and no latent heat of its own, and a tick of lag
its own comment apologises for. A plug built on the real thing melts when *its own* temperature
passes *its own* material's melting point, which deletes the sensed key, the threshold and the
lag. **Not converted in G** — it is safety-critical and specced, and `crown_sheet_spec` is the
most expensive file in the suite. Land the concern on the bearing; convert the plug deliberately.

**Radiation — built 2026-09-18.** Designed in
[`design_sketches/radiation.md`](design_sketches/radiation.md). Nothing in the engine radiated:
heat left a node one way, linearly, which is why a seized bearing settled at 1652 K and why a
firebox heated its boiler through a flat conductance. **Balance was explicitly not a
consideration** — pre-alpha is exactly when to get the physics right, because good physics means
fewer special cases later and better emergent play.

**It cost almost nothing, because `T⁴ − T_amb⁴` factors exactly** into
`(T² + T_amb²)(T + T_amb)·(T − T_amb)`. The bracketed part *is* a conductance in W/K, so radiation
became an ordinary term in machinery that already existed — summed with `ambient_conductance` for
loss to the environment, and added to a `ThermalLink`'s conductance for body-to-body exchange.
`Relaxation` needed **no change at all**, and the whole thing inherits backward Euler's
unconditional stability; an explicit `T⁴` would have been the one integrator this library forbids.
Opt-in through `emissivity`/`radiating_area_m2`, both defaulting to zero, and a spec asserts a node
declaring neither is **bit-identical** to before.

Both proofs of concept landed:

- **The firebox.** Brightening the fire 1.056× multiplies convective transfer by 1.102 — exactly
  the ratio of temperature differences, as a linear term must — and radiant transfer by **1.254**,
  exactly the ratio of `T⁴ − T_water⁴`. Radiation carries about **63%** of the path, which is a
  firebox.
- **The bearing.** A seized one settles far below the old 1652.4 K, because a body that hot
  radiates far more than 42 W/K can conduct. The unbounded behaviour is gone because the missing
  physics arrived, not because anything was clamped.

> **The firebox split had to be calibrated against the TOTAL, and the first attempt was wrong by
> 38%.** It shipped as `900 W/K + ε0.9 / 12 m²`, summing to ~2200 against the flat 3500 it
> replaced — because the flat figure had been standing in for radiation all along. **An
> under-strength path makes the fire run hotter, not cooler**, since the heat cannot leave it, so
> the reading that looked like a better fire was the bottleneck, and a claim that the engine had
> gained 100 kW went in this file on the strength of it. It cost four spec failures: the reference
> cold start stopped reaching working pressure, `steam_raised` never fired, and three
> achievement-pipeline examples went with it. Now `1100 W/K + ε0.9 / 24 m²`, ~3280 total.
>
> **Two claims made here were withdrawn.** That the engine became substantially more powerful — it
> did not — and that more air is no longer simply better. The second may well be true and **was
> not measured**: the boiler sat at 432.3 K at every damper in that sweep, on its safety valve, so
> the run could not say. Demonstrating an optimum needs the drum off its valve.
>
> **Balance figures from before radiation are still stale**, including the cold-start gradient and
> the sweeps in `bearings.md` §6.3, because the path's temperature *dependence* changed even
> though its working-point magnitude did not.

**Fatigue — built 2026-09-18, stages A–E.** Designed in
[`design_sketches/fatigue.md`](design_sketches/fatigue.md). Phase **6c**, after `endanger` and not
at phase 0 where a long-standing TODO put it: the effort demanded is settled at phase 1, `endanger`
already writes `minions`, and somebody carried out must stop working on *that* tick. It draws no
entropy, exactly as the Danger Check does not. Accrual is `exertion × (intent ÷ capability)² ÷
endurance`, netted against a recovery rate the *station* declares — so an effort station recovers
nothing and a valve is somewhere to stand down to. `endurance` is the sixth stat, and heavy kit
now carries a negative offset, which is the first equipment in the catalogue with a real downside.

**The balance sweep (stage F) is deliberately skipped** — it folds into the larger sweep that comes
with the mine and the tech tree.

> **One fireman cannot hold the firehole, and nothing was wired to make that true.** `injury_spec`
> fired at `stoking: 70` for 7000 ticks to burst a drum; it now goes spent at **t=832**, capability
> zero, **the fire dies** (firebox 918 K → 319 K) and the boiler cools for six thousand ticks with
> nobody hurt. A spent minion is unmanned in all but name, and an unmanned effort station delivers
> nothing. `ReferenceCrew` therefore sets `endurance: TIRELESS` — it divides accrual and never
> enters `capability`, so a machine spec keeps measuring the machine at no cost to any baseline.

**Crew capacity — built 2026-09-18, stages A–C.** Roles are gone: a roster is **seats**
(`crew_1`, `crew_2`), as many as the fitted `:crew_quarters` part has `crew_capacity` for, and a
seat carries **no station** — everybody starts in the quarters and is *sent* somewhere, so
deploying the shift is the opening move of a match. Jobs are derived rather than declared (every
`ControlPoint` with `effort:`), which makes the scarcity arithmetic: **three effort stations
against two seats.**

Measured: an engine with nobody deployed sits at **322.8 K and 0 kW**; deploy one hand to the
shovel and it is **1022.0 K, 547.9 kPa, 495.5 kW** — the pre-release reference exactly. Nothing
was wired to make the first row true; an unmanned effort station already delivered zero and there
is simply no way to start manned now.

> **Two things the sketch had wrong, both found by building it.** `provides: %i[quarters]` is a
> duplicate-id error, because `provides:` names *node* ids and a quarters needs no node — it is a
> `ControlPoint` with no `node:`, which is what `#lever?` now keys off. And `panel[:controls]` was
> feeding both the lever strip and the crew station dropdown; those stop being one list the moment
> a station is not a lever, so `panel` gained `stations:`.

The original sketch, its alternatives and the defect it came from:

**Crew capacity, and the standin defect it comes from.** Designed in
[`design_sketches/crew_capacity.md`](design_sketches/crew_capacity.md). `Crew.normalise` fills
*every* declared role with a `STANDIN`, so roles and people are 1:1 and **nothing in the model can
express scarcity of people** — which is how adding an `:oiler` role silently deleted the oil-round
mechanic in stage F. Jobs become derived (any `ControlPoint` with `effort:`), hands become declared
and upgradeable, and the roster becomes positional *seats* rather than job titles — matching the
noun correction the minions release already made. **The crew quarters is the load-bearing piece**:
a required part carrying `crew_capacity`, `recovery_rate` and, critically, **the station every seat
starts at**. Nobody starts at a working station, because a machine that lets them hands the player
a shift already at the face for free — and for a mine, getting people in and out safely is most of
what the operation does.

Three findings from E worth carrying:

> **A failure threshold that slides with durability collapses a ladder.** The first `overload?`
> slid from the melting point to the service limit as integrity drained — the concern's own
> advice that a worn part fails sooner. The part then crosses the falling threshold *before*
> fatigue can finish, so it seized at 481.7 K on a 0.63 integrity having never wiped, and the
> warning rung never happened. The threshold is flat; "worse once damaged" is expressed as a
> derate that raises the friction, which is a mechanism rather than a second threshold.

> **`max_drag_conductance` is not a stop, and three docs said it was.** At `c = I/dt` backward
> Euler gives `ω′ = ω/2` — it **halves** a body per tick. It bounds how far a linearised brake is
> trusted. A drag meaning "this has locked" declares a large multiple of it; a seized bearing
> uses 40×.

> **Seizure is the first mechanic to make the phase 4d/4e split bite.** A locked bearing cannot
> quite stop the engine — it limps at 26.9 rpm — because 4e puts the cylinder's impulse back after
> 4d has taken it out. The lever in `bearings.md` §6.4 stays unpulled, but it now has a cost.

**And one thing E did not deliver, now scheduled.** Stage D claimed that folding in
`Cylinder#efficiency` would make cylinders wear from ordinary hard running. Measured, the rings
reach **459.3 K against a 560 K limit at throttle 100 / load 100** — a hundred Kelvin of headroom
— so that rung is unreachable and hydraulic lock is still the only route to a worn bore.

The cause is that the law describes the wrong thing: **a bearing does not wear because it is hot,
it wears because it is rubbing, and it is hot for the same reason.** Heat correlates for a journal
cooking itself and fails completely for rings that shed theirs into a tonne of iron casting. The
fix is Archard — wear against the **boundary** friction power the friction law already computes,
with the hydrodynamic term absent because an oil film wears nothing. **Decided 2026-09-17 and
scheduled for stage G**, beside the parts catalogue, because it makes bearings consume themselves
in ordinary running and a part that wears out needs somewhere to be bought. Design in
[`design_sketches/bearings.md`](design_sketches/bearings.md) §3.10.

**Driven transport — BUILT 2026-09-19**, stages A–E; findings in `driven_transport.md` §7 and
summarised above. The original design note follows.

**Driven transport, and the blower stops being free.** Designed in
[`design_sketches/driven_transport.md`](design_sketches/driven_transport.md). `Conduit#head_pa` is
a pressure source with a lever and nobody paying the bill — measured at **1.59 kW given away while
raising steam**, which is free at the one moment the engine itself produces nothing. Three things
can pay for a head and only one is missing: **crew effort already works** (`Tick#control_values`
routes an effort control through the crew, so `effort:` on the lever is the whole change), a
consumable needs one small prime mover, and **shaft power is the genuine gap** — `Load` absorbs
and produces nothing, `head_pa` produces and absorbs nothing, and the two halves of a pump cannot
be wired together. The shaft adapter costs **no arbiter or solver change at all**, because
`drive_drags` already gathers drag from a non-rotating declarer naming a shaft it is not — which is
what a `Bearing` is. The blower becomes a slot with two blueprints: a **Hand Bellows** worked by a
minion, and a **Donkey Blower** at exactly today's figures, so every existing balance measurement
survives the release.

**This is what the mine needs.** Drainage and ventilation are both *shaft work buys flow*, and a
mine's output is mass leaving usefully — which the ledger cannot currently say, having
`mass_vented` and `mass_spilled` and no productive exit.

### The stated direction, as of 2026-09-12

Recorded so the ordering is not rediscovered later: **finish the steam engine's balance pass →
modularise it → then implement minions properly.**

#### Modularisation — design agreed 2026-09-13, stage 1 built

Design and the six junctures it turns on:
[`design_sketches/modular_components.md`](design_sketches/modular_components.md). All six were
reviewed and agreed; two moved under review — **part authorship stays in-house permanently**,
which makes the Ruby registry the answer rather than a waypoint to content YAML, and the slot
*shape* taxonomy was dropped for a single `when_empty:` axis after `:branch` turned out to
describe neither a shape nor a consequence correctly.

| Stage | State |
|---|---|
| 1. `Part`/`Parts`/`Slot`/`Fragment`/`Assembly` + validator; every node function becomes a part | **Done 2026-09-13.** 19 parts, 19–20 slots, `variant:` → `chassis:` + `loadout:` |
| 2. Make the optional ones optional | **Done 2026-09-14.** Seven optional slots, both `when_empty:` behaviours, measured one at a time — see below |
| 3. Promote the remaining attributes; redistribute `CHASSIS` onto parts | **Done 2026-09-14, and bit-identical** — see below. The blower was pulled forward; the blastpipe turned out not to want promoting at all |
| 4. Rails: `Loadout` model, components controller, outfitting screen, test drive | **Done 2026-09-14** — see below |
| 5. Minion-powered parts | **Moved to last.** They cannot preserve identicality and they are only adjacent to the modularisation goal, so they no longer gate anything |

#### The blower, pulled forward out of stage 3

Promoted from `head_pa: 600.0, head_control_id: :blower` on the damper to `:blower_fan`, its own
conduit in series on the air path — **the first optional part on this engine and the first
`when_empty: :bypass` slot.** With no blower fitted the atmosphere joins straight to the damper
and the fire draws on stack buoyancy alone, which is a real machine and a real decision: a cold
stack has no draught, so an engine built without one cannot raise its own first steam.

**Physics-neutral, and the atmospheric engine proves it exactly.** Mass bit-identical, every
reading unchanged at 900/1800/2700/3600, and `total_joules` up by **586,300 J — which is
precisely the new casing's own `2000 J/K × 293.15 K`, to the joule.** Nothing else moved at all.
The high-pressure engine shows the usual ulp-level drift, for the link-order reason above.

**It is a WIP part and flagged as one** (`Parts.register(..., wip: true)`, so the outfitting
screen can say so). It is still free and should not be: the intended cost is crew time first and
a consumable second, and the constraint that rules out the easy answer is **a black start** — a
player may be the only one generating power in a match, so nothing may depend on electrical
supply. A fuel-oil reserve bolts onto this part when minions land.

**Stage 1's acceptance test had to change, and the reason is worth reading**: "bit-identical
digest" turned out to be unachievable for *any* change that reorders links, because the engine
is sensitive to link order at the last bit. See the traps list. What was proved instead:
identical node set and configuration, identical link **set**, identical levers, identical panel,
identical cold state, and running agreement to ~1e-15 per tick (174.84 → 174.77 rpm at t3600).

#### Stage 2: what can be left off, and what happens

**Seven optional slots of twenty.** Each was removed **on its own** — removing all seven at once
would only tell you the result is bad, not what any one part is *for*. Measured at 2400 ticks
through the spec's own `light_and_run` startup, high-pressure chassis:

| Left out | | Drum | Speed | What it means |
|---|---|---|---|---|
| *(stock)* | | 608.0 kPa | 174.5 rpm | pinned on its valve |
| **safety valve** | `:omit` | **687.0 kPa** | **196.6 rpm** | **more power** — the shell's derived rating is now the only limit |
| **cylinder relief** | `:omit` | 608.5 kPa | 0.9 rpm | **`cylinder_failure` on an ordinary startup** |
| **blower** | `:bypass` | 8.8 kPa | 0 rpm | never lights — a cold stack has no buoyancy |
| **boiler tubes** | `:bypass` | 101.7 kPa | 0 rpm | plain shell boiler; radiant path only |
| ashpan | `:omit` | 608.0 kPa | 174.5 rpm | no effect *yet* — ash takes thousands of ticks |
| cylinder cocks | `:omit` | 608.0 kPa | 174.5 rpm | no effect here; the hazard is warming through |
| fusible plug | `:omit` | 608.0 kPa | 174.5 rpm | no effect here; only matters below the crown |

Each takes **exactly its own pieces** with it — one node, one or two links, its levers and its
gauges — with no edit anywhere else. That is the whole return on parts owning their fragments.

Three findings worth keeping:

- **The safety valve is the risk/reward axis, demonstrated.** Taking it off is a 13% pressure
  gain and a 13% speed gain, with nothing left to bleed the drum. That is a *decision*, which is
  what the design needed it to be.
- **The cylinder relief valve is load-bearing during an ordinary start**, and the comment on it
  did not say so. Its *setting* genuinely never matters in steady running — that part was right
  — but its *presence* does: warming through fills a cold cylinder with condensate (peak
  occupancy 0.859, "knocking badly"), the valve lifts, and the engine survives a scare. Remove
  it and the same startup wrecks the cylinder.
- **Three parts show no effect over a normal run, and that is correct.** Their hazards are slow
  or conditional. They are covered where those conditions are actually reached — the ashpan at
  7200 ticks, the cocks in `water in the cylinder`, the plug in `crown_sheet_spec` — and a
  "stripped build behaves identically" result would be alarming only if you expected every part
  to matter in every scenario.

**The condenser stays a chassis decision rather than becoming optional**, and `assembly_spec`
pins it so nobody finishes the job later. On Watt's engine the vacuum *is* the prime mover and
the cylinder exhausts into it, so an atmospheric engine without one is not a machine with a part
missing — it is one whose exhaust has nowhere to go.

**`boiler_tubes` was added to the optional list and was not in the sketch.** It is the single
biggest upgrade on the engine, it is `:bypass`, and a tubeless boiler is a real historical
machine rather than a broken one.

#### Stage 3: the chassis gives up its numbers

Done 2026-09-14. `CHASSIS` was twenty keys of which **seventeen belonged to six parts that were
not separate objects yet** — the observation in §1 of the sketch that modularisation came out of.
Those numbers now sit on the parts that own them, with the sweeps that chose them.

Eight kinds gained a second variant, and the loadout now genuinely identifies a machine where
`:stock_boiler` used to name two different ones:

| Kind | High-pressure | Atmospheric |
|---|---|---|
| boiler | `:locomotive_boiler` | `:beam_boiler` |
| chimney | `:blastpipe_chimney` | `:plain_chimney` |
| damper | `:wide_damper` | `:narrow_damper` |
| safety valve | `:ramsbottom_safety_valve` | `:low_pressure_safety_valve` |
| cylinder | `:high_pressure_cylinder` | `:atmospheric_cylinder` |
| cylinder relief | `:high_pressure_cylinder_relief` | `:low_pressure_cylinder_relief` |
| flywheel | `:light_flywheel` | `:beam_flywheel` |
| mill | `:mill_drive` | `:slow_mill_drive` |

`CHASSIS` now holds `exhausts_to`, `condenser`, `parts:`, and `burst_pa`. **`burst_pa` is the one
entry still in the wrong place** — it is the pressure gauge's full-scale reading rather than a
physical limit, and it stays because the panel catalogue is built from the chassis and does not
know which boiler is fitted. Moving it needs parts to own their `Diagnostic`s (§4 Option A).

**Acceptance: bit-identical, and this time literally.** Every node, link, path, control point,
instrument, panel digest, cold-state digest, all four running digests, mass, joules and per-node
digest matched on **both** chassis. The only line that moved in the whole comparison was the
loadout itself. Unlike stage 1 this was achievable because nothing reordered the link list.

Two things worth keeping:

- **Where two parts of a kind differ only in numbers, the wiring is written once.** Eight
  `*_fragment` helpers in `parts.rb` hold the shape; the registrations hold the figures. Sixteen
  copies of the same link list would have been sixteen chances to drift on something that is not
  supposed to vary.
- **The blastpipe did not want promoting, and the sketch was wrong about it.** §5 listed it with
  the blower and the stack as an attribute that had to become a node. The blower genuinely did.
  The blastpipe is *part of the chimney* — physically the two were proportioned together and are
  meaningless apart, and mechanically a separate node could not work: the blast head has to reach
  both paths through the chimney (the firebox draught and the cylinder's own exhaust), which the
  flue does because it sits on both. A blastpipe node between the tubes and the flue would sit on
  the draught path only, and one placed to catch both would have to own the chassis's exhaust
  link. So it is a chimney **variant**, and a taller stack is now a straightforward future
  variant rather than another promotion.

**Being a variant made the blastpipe MORE removable, not less.** It used to be `blastpipe: true`,
a chassis constant — the only way not to have one was to be the other engine. It is now a part
choice, so `chimney: :plain_chimney` is a legal high-pressure build. Measured at 2400 ticks:

| High-pressure engine | Drum | Speed | Fire |
|---|---|---|---|
| blastpipe chimney (stock) | 608.0 kPa | 174.5 rpm | 974.4 K |
| plain chimney, blower shut at 1600 | 303.8 kPa | 105.9 rpm | 567.6 K |
| plain chimney, blower held on | 608.1 kPa | 174.2 rpm | 1015.7 K |

A self-draughting engine that loses its blastpipe keeps **full power on a permanent blower** and
loses 39% of its speed without one. Nothing warns about this and nothing should — a bad swap
teaching you what the part was for is the mechanic, not an error case.

**It was the sharpest argument for giving the blower its cost**, and that landed 2026-09-19:
"plain chimney plus a blower left running" now costs either a person on the handles or fuel oil
from a tank, so the blastpipe's value is no longer masked by a free lever. **Worth re-measuring
the blastpipe against a blower somebody has to pay for** — the figures here were taken when it
was free.

#### Stage 4: the outfitting screen

Done 2026-09-14. **The first model and the first migration in this application**, which had
deliberately had none.

```
GET   /matches/:match_id/operations/:operation_id/components   the screen
PATCH /matches/:match_id/operations/:operation_id/components   fit, then test drive
```

- **`Loadout`** (`match_id`, `operation_id`, `chassis`, `parts` jsonb) — what a cold runner
  boots from and what the screen edits. **Not the authority during a match.**
- **`DevMatch`** gained `stored`, `outfitting`, and `build(chassis:, loadout:)`. `panel` is now
  memoised **per loadout** rather than per process.
- **`SteamEngine.assembly_for(chassis, loadout)`** is the one entry point outside the sim:
  slots, what is fitted, alternatives, verdict — all without building an operation, because most
  of what the screen renders is for builds nobody has chosen. `build` goes through it too, so the
  machine a player is shown and the machine they get cannot be assembled two different ways.
- **`Slot#group`** (`:fire`, `:water`, `:steam`, `:engine`) is the only presentation field on a
  slot, because a screen is read by system and alphabetical order scatters the four fittings on
  the boiler across the page. It defaults to `:other` and `assembly_spec` refuses that default,
  since a silent fallback is the shape of off switch this engine has paid for five times.

**The order through the button is the design, and it is: validate → store → reset.** A build
that cannot assemble never reaches the database, so a runner booting cold cannot inherit a
machine the validator already refused.

**The loadout rides INSIDE the reset command, not merely referenced by it.** The runner has Rails
booted and could read the table; it must not. The web process writes the row and *then* produces
the command, so a runner reading the table would read it at whatever moment the record happened
to arrive — and a reset racing a save would rebuild the previous machine with nothing to show for
it. `DevMatch.reset_command` builds the payload; `MatchRunner#reset` takes it and
rescues `ReactorSim::Error` so a bad loadout cannot take every match on the runner down with it.

**`DevMatch.panel`'s long-standing TODO is closed.** It said rebuilding a throwaway match in the
web process would stop being sound the moment configuration was chosen at creation rather than
read from the environment. It is chosen now, and it stays sound with one word changed: the panel
is a pure function of the **loadout**, so two processes reading the same stored loadout cannot
disagree. Verified — removing the safety valve takes the panel from 21 instruments to 19. What
remains is a race, not a design flaw: save a loadout and the console renders the new panel over
the old machine for a tick or two until the reset lands. The real fix is still the panel coming
*from* the runner, which is where this goes when matches are created on demand.

#### Stage 5a: blueprints, the progression model's skeleton

Done 2026-09-14. **Progression is blueprints**: a player unlocks the right to mint a *fresh
instance* of a thing, and nothing an instance accumulates survives the match it accumulated it
in. There is no inventory of part objects, no carried wear, and no condition round-trip — the
cost of wrecking something is paid inside the match, by everyone sharing its reward. Design and
the junctures: [`design_sketches/blueprints.md`](design_sketches/blueprints.md).

- **`Blueprint`** — a catalogue **derived from the simulation's own registries**, never written
  down: 1 operation, 2 chassis, 29 parts, 2 minion archetypes. A hand-maintained list would drift
  the first time somebody registered a part without looking, and drift *silently* — the new part
  simply unreachable. `rake blueprints:catalogue` prints it.
- **`Unlock`** (`owner_id`, `kind`, `blueprint_id`) and nothing else. No quantity, no condition,
  no match id, because none of those mean anything when instances are minted fresh.
- **`DevPlayer`** owns the whole catalogue, so the game plays exactly as it did. That is the
  acceptance criterion for this stage, not a placeholder: the machinery is real and enforcement
  is stage 5b.
- **A chassis id is scoped to its operation** — `steam_engine/high_pressure`. A frame has no
  standalone existence, and two machines could each name one `standard`; unscoped, unlocking one
  would silently unlock the other.

**The sketch asked for a boot sweep and it became two narrower guards, because the sweep was
aimed at the wrong failure.** Validation refuses to *create* a row naming a blueprint that does
not exist; `rake blueprints:audit` finds rows a **rename** stranded, exits non-zero and names
them. Nothing revalidates rows already in a table when a Ruby constant changes — and stage 3
renamed `:stock_boiler` to `:locomotive_boiler`, so this is drift that has already happened once.
A boot sweep would also have meant a database read in an initializer and would have forced the
content YAML read that `initializers/reactor_sim.rb` keeps lazy on purpose.

**One change inside `lib/reactor_sim`, and it is introspection rather than progression.**
`Operations.register` takes `chassis:` — the enumeration of frames a type offers — and
`Operations.chassis_for(type)` reads it back, because the delivery tier has to list chassis and
the alternative was a hand-written map from operation type to `SomeOperation::CHASSIS` living in
Rails. Nothing on the tick path reads it; the simulation still knows nothing about players,
ownership or cost.

#### Stage 5b: enforcement, and the controller rule that came out of it

Done 2026-09-14. A part the player has not unlocked is **refused when posted directly**, not
merely absent from the dropdown — the form is a plain POST, so a client-side filter is not a
filter. `Assembly` is untouched and still knows nothing about players: its verdict stays `ok?`
for a locked build, which is the assertion that keeps ownership out of the simulation.

**The first version was rejected for living in a controller, and the rule is the lasting part.**
`app/CLAUDE.md` now says: every action is one of the seven; an action named for a domain verb
means either a resource is missing or the work belongs elsewhere; a controller may express
routing, authorisation, parameter permitting and which template follows, and nothing else.
Applying it retired three non-standard actions —

| Was | Is |
|---|---|
| `components#show` | `loadouts#edit` |
| `components#show` (POST preview) | `loadout_drafts#create` — **a draft is a resource** |
| `components#fit` | `loadouts#update` |
| `matches#reset` | `match_resets#create` |
| `MatchesController.reset_command` | `DevMatch.reset_command` |

— and moved the work to **`Outfitting`**, a service object taking an owner id and a parts hash,
never `params`.

**A GitHub security scan found a 500 the specs could not.** Brakeman refused
`params.fetch(:loadout, {}).permit!` as mass assignment; the worse half is that `permit!` admits
**non-scalars**, so `loadout[boiler][]=x` arrived as an Array, reached
`Assembly#normalise_part_id`, and `Array#to_sym` raised — on the draft action, which has no
rescue, reachable by anyone who could open the page. `permit(*slot_ids)` fixes both. Five specs
cover those shapes now; none existed before, which is why it survived.

Dev affordance: `blueprints:grant[kind,id]`, `blueprints:revoke[kind,id]`, `blueprints:owned`. A
workshop screen was deliberately not built — it is progression UI and wants a tech tree.

#### Stage 5c: the gates, stubbed in their real shape

Done 2026-09-14. `config/blueprints.yml` prices all 34 blueprints as a **bill of materials** —
*this boiler is 3.2 t of wrought iron* — and may name an achievement prerequisite. Both are
delivery tier: `content/` is the simulation's own YAML and the sim must not learn what anything
costs, though a bill may *name* a resource the sim knows, and that reference is resolved through
`Content#resource` when the catalogue builds.

**Nothing can pay one yet**, and that is deliberate: there is no resource ledger, because a match
reward cannot be designed against a single steam engine. The quantities are plausible masses, not
balanced prices. What stage 5c bought is that the shape is now impossible to get wrong quietly.

- **A missing entry raises; `materials: {}` is how a blueprint is free.** "Decided to be free"
  and "nobody filled it in" are indistinguishable six months later unless the file says which.
  Free today: the steam engine itself and both minion archetypes.
- **The sketch's own worked example priced a boiler in `copper`, which `content/` does not
  have.** Small, and exactly the argument for the check — `copper: 420` does not announce itself
  as wrong. `rake blueprints:audit` builds the catalogue, so the existing command catches it.
- **`DevPlayer.earn` goes through the gates; `grant` bypasses them.** Different words on purpose:
  `Achievement.earned?` is a stub returning true, so a gate wired only into a spec would be
  indistinguishable from a method that returns true. The specs stub it **false** and watch an
  ungated part still earn while a gated one does not. Three blueprints carry a prerequisite.

#### Stage 5d: the frame becomes a choice, and a trap worth more than the feature

Done 2026-09-14, partly. **The chassis is now chosen on the outfitting screen** rather than read
from a stored row or an environment variable, filtered to frames the player owns, with an unowned
one refused on its own line. Switching frames exposed a real bug: stage 4's rule that *an unfitted
slot is an explicit empty* is wrong across a frame change, because the form was drawn for the old
frame and a slot only the new one has was never on it — switching to the atmospheric frame refused
itself with *"Condenser is required and nothing is fitted."* Fixed by carrying through only the
keys the submission actually contains.

**Operations have nothing to enforce yet** — one machine, no lobby, no point of choice.

**The minion row is NOT done, and what exists models the wrong noun.** `Blueprint.minions`
enumerates content archetypes — `fireman`, `yardhand` — which are *jobs a minion performs*. A
player unlocks an **individual**: Jim, who is human with his own stats and tags, or Elowynne, who
is an elf. Each is their own upgradable template, and each carries equipment in three slots — tool
set, gear, utility — whose blueprints are unlocked *per minion*. Tags carry values the simulation
reads (`mining_effectiveness: 0.25`, `darkvision: 0.1`, `open_flame: true`). Left in place and
marked, because the mechanism is right and the entities are not; nothing enforces minion ownership,
so it cannot mislead a player yet. See
[`design_sketches/minion-sketch.md`](design_sketches/minion-sketch.md) and `blueprints.md` §17.

> **A derived catalogue derives from whatever is in the registry.**
> `spec/support/loop_rig.rb` registers an operation globally — it must, or `Match.create` cannot
> resolve it — so it arrived in the blueprint catalogue as a machine nobody had priced and took
> the whole catalogue down: seventeen examples failing at once. It reproduced **only in a
> full-suite run**, because nothing else loads that file, so re-running the failures passed every
> time. `Operations.register(type, harness: true)` now marks a rig; `Operations.known` is
> everything and `Operations.catalogued` is the machines. The default is `harness: false`, so
> forgetting to mark a real machine does nothing and forgetting to mark a rig fails loudly.

#### Stage 5e: the dial becomes a fitting, and `CHASSIS` is finally just topology

Done 2026-09-14. **`CHASSIS` holds `exhausts_to`, `condenser` and `parts:` and nothing else** —
what §6 of the modularisation sketch asked for, true for the first time.

`burst_pa` was the last holdout, and the expected fix was wrong. The sketch assumed it meant
handing the fitted boiler to the panel catalogue; that is the same category error one object
closer, because **a gauge's range is not a property of the drum** — a 0–14 atm dial and a 0–4 atm
dial are different brass instruments chosen to suit the boiler. So the dial became a part:
a `:boiler_gauge` slot, three gauges, and the scale on the gauge. Same rule that moved the blower
and kept the blastpipe, applied to an instrument for the first time.

- **`Fragment#diagnostics`** lets a part that *is* an instrument build its own `Diagnostic`. The
  definitions stay in `panel.rb` with the reasoning; the part passes figures.
- **`PANEL_ORDER` is now explicit** and covers gauges from both sources. Selection used to run
  over the catalogue, whose insertion order *was* the panel order; a supplied gauge has no place
  in that hash, and appending would have put the most important dial on the engine at the end of
  the panel. `Assembly` refuses a gauge the order does not name.
- **The gauge is optional**, and it is the eighth optional part and the odd one out — every other
  is machinery, this is information. An engine with no pressure gauge assembles and runs.
- **`:compensated_pressure_gauge` is the upgrade and its shape is the rule**: one tick of lag
  instead of two, ±3 kPa instead of ±8, and **neither filter removed**. An instrument upgrade may
  reduce a filter, never remove a class of one; `safety_valve`, `crown_sheet` and
  `flywheel_condition` are exempt outright. The instruments are the game, not an obstacle in
  front of it.

Two checks earned their keep on the way: the id-collision check caught both boilers still
claiming `boiler_pressure` alongside the gauge that now supplies it, and a spec asserting *"takes
its own pieces with it"* by counting `fragment.nodes` had to widen — an instrument part brings no
nodes at all.

**Instruments cost almost nothing to make**, which is the open question this leaves. A Bourdon
gauge is a curled brass tube and a pointer, so a bill of materials cannot be what makes a better
one expensive. Whatever gates an instrument upgrade will not be tonnage.

Two consequences of modularisation that should shape decisions made before the rest of it
lands:

- **Automatic safety devices are a luxury tier**, because they add no power and sometimes cost
  some. That is the progression's risk/reward axis, and the crown sheet is already built to it:
  with the fusible plug fitted the boiler cannot rupture, and with the plug scaled over it goes
  at tick 7088. The hazard sits *underneath* the safety, which is what makes choosing to go
  without it a real decision rather than a strictly-worse one.
- **Several levers are still free** and should not be, the blower most obviously. It is now a
  part (above) and flagged WIP, which is where its cost will attach; the intended cost is crew
  time first and a consumable second — and note the constraint that rules out the easy answer:
  **assume a black start**, since a player may be the only one generating power in a match, so
  nothing may depend on having electrical supply.

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
   writer. Both needed a rupture size, which is a failure-model design decision rather than a
   physics one — the same reason the conduit TODO has been deferred.

   **Stages A and B are built (2026-09-14); C and D are not.** The sketch is
   [`design_sketches/failure_model.md`](design_sketches/failure_model.md), which stages the
   build A–D and makes stage C measurement-first; the rule it is built on was decided in
   [`design_sketches/blueprints.md`](design_sketches/blueprints.md) §3. That rule: **broken is
   not absent** — a failed part stays wired where it was and performs differently, and how
   differently is a property of that part's own failure mode. A leaking pipe lets the machine
   limp on; a boiler letting go ends the run. Two shortcuts are ruled out explicitly: a broken
   part must not be dropped from the node list (it would change the graph's shape under a
   running tick, which the snapshot contract assumes cannot happen), and a broken holder must
   not plug — today's behaviour by omission, and backwards, because it makes a rupture a
   *better* seal than the working part.

   **What A and B changed.** `broken: true` is now `failure: nil | <mode symbol>`, `broken?`
   derives from it, and every part declares a `failure_modes` table in ascending severity — 44
   wearing nodes across both chassis, none left on the generic fallback, with a spec that walks
   them and fails the build for any that is. A failed part **keeps being evaluated and can get
   worse**: the early return in `apply_wear` is gone, because a mild failure must never immunise
   a part against a catastrophic one, and `escalate_to` only ever moves forward. `Atmosphere`
   gained a second inlet so `mass_spilled` has a writer path distinct from `mass_vented`.

   **What C changed.** `Nodes::Breach` — a hole built with the machine and shut, which opens by
   the failed part's mode. The boiler part ships its own, wired to `Atmosphere`'s new `:spill`
   inlet, so **`mass_spilled` finally has a writer** and this playtest item's original complaint
   is answered. `Conduit` stopped plugging: both `broken?` guards deleted outright, because a
   hole does not narrow a pipe and what starves the far end is the upstream holder being drained
   by a second path. Conservation is exact across a burst on both balances.

   **The sizing was measured, and the first guess was wrong by four orders of magnitude** —
   sized against the safety valve it was a cliff, every hole fatal. The valve only opens above
   its setting; a breach is open always, so the reference is the *regulator wide open*. At
   conductance 1e-4 a 175 rpm engine falls to 151 over 600 ticks and can be limped to the shed;
   at full bore it is at 2 rpm with the drum empty. That is 5e-5 of the shell — about a 3 cm
   hole in a drum this size, which is what a weeping seam is. **Run-ending is still declared
   nowhere**: the engine stops because there is no pressure, because there is a hole.

   **What D changed so far.** A failing part now spends `failure_damages` on its neighbours —
   fiat, a durability write rather than a joule, so conservation is untouched by construction.
   And **flash evaporation decides how badly a boiler fails**, which is what made `:explosion`
   reachable at all.

   That last one reversed an earlier conclusion. A pressure-ratio rule could never fire (the
   drum peaks at 0.53× its rating) and, worse, it called a low-water crown-sheet failure a
   *gentle* split — backwards, because that is precisely the catastrophic locomotive explosion
   the accident reports describe. Open a drum holding water at saturation and 11% of it flashes
   instantly: at the real rupture, 626 kg at 609 kPa gives 67 kg of steam, **22.8 times the
   drum's own volume**, which is what peels the plate back. Note flashing does *not* raise the
   pressure — making steam costs latent heat, so the water cools; it is the volume that does the
   damage. Criterion and scale in `Nodes::Boiler`, reasoning in the sketch §14.

   The player-facing consequence is the good one: **how much water is in the glass now decides
   how badly the boiler fails, not merely whether it fails.**

   **And a mode now changes how a surviving part works.** `derates:` is read by the node's own
   code, which is what finally made the cylinder's two modes different machines: a **scored
   bore** turns, pulls, does both badly and can be nursed home; a **blown head** does neither
   and opens a hole. Until then *any* cylinder failure declared `Intent.none` and stopped the
   engine dead, so the milder mode was decoration.

   Three breaches are wired on both chassis — boiler, steam chest, cylinder — each shipped by
   the part that can fail, so fitting a different drum gets you that drum's way of failing.
   `failure_spec` checks the inverse too: no breach may name a mode its part can never enter,
   which would leave a hole inert and indistinguishable from a part meant to fail sealed.

   **The conduit case is done too, and it needed no new machinery.** A pipe holds nothing, so
   its hole has to drain a *holder* — and `Breach` already separated the two questions, because
   `senses:` is whose failure opens it while the inlet **link** is what empties. Which holder is
   a declaration rather than a deduction: on the pressure side of every valve, drain upstream
   and the leak continues whatever the driver shuts; past the restriction, drain downstream and
   closing the valve isolates it. `steam_pipe_breach` senses the **throttle** and drains the
   **boiler**, because a locomotive regulator sits in the dome on the boiler side of its own
   valve — so **the one control that would normally save you is on the wrong side of the hole.**

   A ruptured conduit also *derates* what it still delivers (0.7), which is damage to the pipe
   and deliberately **not** the leak: material a conduit declines to pass stays upstream as
   back-pressure, so a throughput term alone spills nothing and writes nothing to the ledger.

   Four breaches wired on both chassis: boiler, main steam pipe, steam chest, cylinder.

   **And escalation finally reaches a real part.** It had unit tests and nothing in any machine
   could trigger it — the same silent off switch this list keeps recording. The cylinder is the
   one that can: its `overload?` is hydraulic lock, which is *condition*-driven rather than
   durability-driven, so it still fires on a part whose durability is long gone. A cylinder worn
   to `scored_bore` that then takes a slug of water blows its head off, and the event says what
   it escalated from. A part whose only route is fatigue can never escalate, by construction —
   and the boiler deliberately cannot, because a split drum loses pressure through its own hole,
   so the severity that would name a worse mode is falling exactly when it is re-read.

   **What the player is told is thinner than what the engine knows.** There *is* an incident
   feed — `PlayerView#incidents` carries the events over the wire and the console renders them —
   but it prints one flat line of engine vocabulary, `vessel rupture (fatigue)`, identical in
   weight whether a fusible plug melted or the boiler exploded. The `mode` this whole pass
   exists to produce is not shown at all, nor `escalated_from`, nor `severity`, nor what the
   failure damaged. That is the next thing worth doing, and it is delivery-tier only: the wire
   already carries every field.

   One consequence worth knowing before `Atmosphere` is built as the universal sink: in-match
   repair is coming as a minion job, and **what a part spills can deny the crew access to it**.
   Once that is true, *where* a spill went matters, and a single global sink cannot express it.
2b. **Instruments are blueprints too. Half done (2026-09-15).** The pressure gauge became a
   fitting in stage 5e; the **water gauge** followed, with three tiers — try-cocks, gauge glass,
   reflex glass. Both instrument slots are optional, which is the safety-device bargain applied
   to what a driver can *see*. 40 blueprints, up from 37.

   **Both tiers shipped broken the first time and only measurement caught it**, which is the
   lesson worth keeping. Try-cocks at 25% steps **never moved at all** over 1400 ticks of a level
   swinging 44% → 56% — the whole working band sits inside one step, so it was an absent gauge
   rather than a coarse one. And the reflex glass was a **placebo**: it cut noise three-fold and
   no player could have told, because the needle reads whole percent and the plain glass's ±1.2%
   was already below one unit of that. The plain glass had been accidentally noise-free, so there
   was nothing for an upgrade to improve; it is ±2.5% now. **A filter finer than the display's
   precision does not exist.**

   Measured mean misreading against truth: try-cocks 3.3%, glass 0.8%, reflex 0.3% — a real
   progression. The *maximum* error stays near 10–17% on all three, because that is lag during a
   fast change, which no tier removes: **the swell trap survives every upgrade**, which is the
   rule that instruments may be improved but never bought into telling the truth.

   **Still open:** sixteen instruments remain chassis furniture. Making each a fitting is not
   automatically right — `safety_valve` is deliberately *not a dial* (you hear it), and
   `crown_sheet` is vague because that is the hazard. The ones worth doing next are the ones a
   player would actually buy: the speed indicator and the firebox pyrometer.

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

## Traps

Each of these is a rule, and each is the kind a fresh reader breaks by accident. They are
documented where they matter and collected here because the collection is worth reading once.

- **Check which clock a rate is against before calibrating it.** `dt` is `ReactorSim::DT × the
  operation's time_scale`, and `DT` is **0.25 s**. The steam engine sets `time_scale: 1.0`
  deliberately, so one tick is a quarter of a second and the whole reference cold start is about
  seven simulated minutes. Fatigue's first figures were derived against an assumed `time_scale`
  40 and were **40× too slow** — a fireman finished raising steam 4.3% tired, and nothing would
  ever have tired anybody. Nothing announces this: the numbers look reasonable and the mechanic
  is simply inert.
- **A rate whose denominator contains its own output is three times faster than it reads.**
  Fatigue accrues on `intent ÷ capability` and `capability` contains `(1 - fatigue)`, so
  `df/dt = K/(1-f)²`. That integrates to `t = (1 - (1-f)³)/3K`, so **time-to-spent is `1/3K`, not
  `1/K`** — at every load. Any constant declared as "per second at full effort" is therefore a
  *nominal* figure and the real answer is a third of it. Verified against the machine: 824 ticks
  predicted, 832 measured.
- **Postgres treats NULLs as distinct in a unique index.** `progresses` distinguishes a per-run
  row from a lifetime total by a null `run_id`, so a plain unique index on
  `(owner_id, run_id, metric)` enforces nothing for the lifetime rows: `NULL = NULL` is unknown,
  not true, so `ON CONFLICT` never matches and **every meter reading inserts a fresh row** — 40
  rows for 10 metrics inside a minute. A spec asserting the *total* passes anyway, because
  `pluck.to_h` keeps the last value for a repeated key. `nulls_not_distinct: true` (PG 15+) is
  the fix; **count the rows, not just the total.**
- **An error CODE of 0 is success, not an error.** `Rdkafka::DeliveryReport#error` is an integer,
  so `next if report.error.nil?` logs and counts every successful delivery as a failure. A
  counter that is always wrong in the alarming direction is worse than no counter.
- **Do not pin a spec to a real minion, or to a balance figure.** Jim's stats are game content
  and will be tuned as more mechanics land; a spec that names him breaks on every tune, and it
  breaks looking like a physics regression. Use `spec/support/reference_crew.rb` — a flat-1.0
  fixture that only changes when somebody changes it on purpose. The same rule covers outcomes:
  "the drum lets go and Jim dies" asserts the balance pass, where "a real injury carries the
  person and the verdict" asserts the wiring. **Shape does not move with balance; outcomes do.**
- **Content is global and is never snapshotted.** `Operation.from_h` rebuilds through the
  registered builder with no `content:`, so a restored match always resolves against
  `Content.default` — a registry injected at build does not exist after a round trip, and the
  rebuild raises `unknown minion`. A spec needing fixture content in a *restore* must stub
  `Content.default`; passing `content:` only covers the build. And `before(:all)` fires before any
  `before(:each)`, so a hook-installed stub is not there yet for an expensive setup block.
- **A tier nothing can reach is a tier that does not exist.** Check that every branch of a ladder
  is reachable **by driving the real machine, not by reading the arithmetic**. Two shapes of this:
  an injury band so narrow that a worker goes from unmarked to carried-out in two hits, because
  bites large enough to get through any resistance are a decent fraction of what a minion has;
  and a pressure-ratio rule for a boiler explosion that no drum ever reaches.
- **A zero default is a silent off switch.** `Vessel` has no `overload?` — it depletes durability
  — so a rig with a tiny `max_pressure_pa` and the default `stress_rate: 0.0` never breaks
  however far past its rating it goes. Same shape as `max_temperature_k: Infinity` and the
  flywheel's `fatigue_rate`.
- **The pressure at rupture is not the pressure a vessel was built with.** The saturation solve
  settles the liquid/vapour split on the first tick, so calibrating against the constructor
  figure gives a number that looks right and is not. Read what the part *reported* on its event.
- **An achievement is only real once something has driven the actual machine through it.** A rule
  can name a window the machine never produces, and every term in it can exist, so it reads
  correctly and nothing raises. "Raised steam without the pilot" is the worked example: the
  igniter is how a cold fire is lit, so `heater_engaged` fires at tick 1 and `fire_lit` at tick 2,
  and a window opening at the lighting can never contain the disqualifying event. Only an
  end-to-end spec finds this, because each hop is individually correct.
- **Hysteresis on a deadband assumes the signal wanders around a level.** A valve sensing
  `compression_pressure_pa` — reconstructed from crank geometry, so it swings through its whole
  range every tick rather than hovering — re-arms on every stroke and announces itself 20 times
  in 40 ticks despite a 2% band. Deadbands do nothing to a cyclical quantity; a **time hold**
  does.
- **Never pipe a suite run through `tail`.** It truncates the failure output *and* masks the exit
  code, since `tail` exits 0 whatever rspec did — so the task reports success while printing a
  list of failed examples, with the tally line cut off. Capture the whole run; read the tail
  afterwards.
- **Check the example COUNT, not just the failure count.** A suite killed by a `timeout` prints
  `324 examples, 0 failures, 1 pending` and a normal `Finished in 19 minutes 52 seconds`, which
  reads exactly like a clean run; the only signal is the exit code. **A green summary line is not
  a green suite.** Give a full run a generous timeout and reconcile its count against
  `bundle exec rspec --dry-run`, which counts in seconds.
- **The suite takes the better part of an hour.** Measured at 48:23 for 631 examples, dominated
  by the steam engine's multi-thousand-tick runs, and it grows with every machine. Budget for it
  when backgrounding one, and give it a timeout well clear of the last measurement.
- **A failure that only appears in a full-suite run will not reproduce when you re-run it.**
  `spec/support/loop_rig.rb` is loaded by nothing but a full run, and it registers an operation
  globally, which poisons any catalogue derived from that registry — seventeen examples fail
  together and every targeted re-run passes. When a full run fails and a focused run does not,
  suspect load order and global registration before suspecting flakiness.

- **Link declaration order changes the answer, and `graph_spec` says it does not.** Reverse the
  steam engine's link list, change nothing else, and the state diverges on **tick 1** — by
  `1e-16` relative, one unit in the last place of a double, in the order floats are summed. By
  tick 1800 the boiler reads **608.183 / 608.046 / 607.866 kPa** for the list as declared,
  reversed and shuffled, and rpm differs by 0.07. **Node order, by contrast, is genuinely
  bit-identical.**
  **What decides whether an ulp grows is loop gain, and the two chassis are a controlled
  experiment for it**: the high-pressure engine diverges and keeps diverging, while the
  atmospheric one diverges transiently near tick 2700 and returns to a **byte-identical digest
  by 3600**, mass bit-identical throughout. The difference is the blastpipe — Trevithick's engine
  exhausts up its own chimney and so carries a closed draught loop that multiplies the
  perturbation; Watt's exhausts into a condenser and has none, so it damps away.
  `graph_spec` asserts both and passes, because it asserts them on `LoopRig` — four nodes, 60
  ticks, nothing to amplify an ulp — so the assertion is true there and does not generalise.
  Invariant 2 is untouched: `seed + command log` still replays exactly, because link order only
  changes when the code does. What this breaks is refactors: **any change that reorders links
  cannot be accepted on a bit-identical digest.** Use identical node set, identical link *set*,
  identical panel, identical cold state and per-tick agreement to 1e-15 instead. See
  `reference/invariants.md` §3.
- **One conduit without a conductance turns a whole path rate-driven, and a rate-driven path has
  no head.** `Arbiter.gas_coupling` requires *every* conduit on a path to declare one and returns
  nil otherwise, so the draught, the chimney and the blower stop existing at once: **296 K
  firebox, 3 kPa boiler, dead on both chassis, no error of any kind.** The tempting mistake is a
  fan, on the grounds that a pressure source is not a restriction — physically true, fatal here.
  A pressure source in series wants **`conductance: Float::INFINITY`**, which contributes
  `1/∞ = 0` to the reciprocal series sum and leaves the real restriction's measured rating
  untouched; a finite value re-rates the path, and 1000 already moves it 0.03%. This is the
  **one** place in the engine where `Float::INFINITY` is a statement rather than a silent off
  switch, and it is only safe because the restriction it defers to is next door and measured.
- **A cold digest is not a test.** A startup sequence that never lights the fire — 400 K firebox,
  zero rpm, boiler at 9 kPa — compares digests across 3000 ticks of a machine doing nothing, and
  passes with the cylinder, the flywheel and the whole drivetrain broken. **Drive the real
  procedure from the spec's own helper** (`light_and_run`, blower on, mill on the belt before the
  regulator) and assert on something that proves it ran: 174.8 rpm and a boiler on its safety
  valve.

- **A rate cap next to a conductance is a dead number, and it will be read as live.**
  `max_kg_per_s` does not apply to a conduit that declares a `conductance:`, so any rate beside
  one is inert — set it to three different values and the results are byte-identical at every
  setting. **Before tuning a constant, check it is on the path that decides the thing**; that
  three-value sweep is the cheapest possible test. The same shape applies to the cocks'
  `drain_kg_per_s`, which is inert across 0.25 → 4.0.

  **Delete a dead constant rather than documenting it as dead.** A number left in place with a
  comment explaining its inertness still *looks* like a tunable figure, and gets cited elsewhere
  as the reason for a behaviour it has nothing to do with. A misleading appendix costs more than
  it saves.

- **An assertion that needs the system unsaturated must assert that, not assume it.** The ashpan
  example claims raking recovers power, which is only true while the drum is **off its safety
  valve** — pinned, it reports every upstream change as zero, and raked-against-banked comes out
  at +0.45 / +0.43 / +0.14 / +0.81 / −0.22 / −0.03 / −0.59 / +0.57 percent across eight settings.
  Random sign, pure noise, and **indistinguishable from a mechanic that does not work.** A
  setting chosen to dodge saturation goes stale every time the path feeding it moves, so the fix
  is not a better number — it is asserting the precondition (`headroom_pa > 10 kPa`) so the
  failure message says *the boiler was saturated* rather than *raking did not help*, plus a
  `× 1.01` floor so noise cannot pass. Worth knowing: **raising the relief setting does not create
  headroom** — measured within 0.4 kPa of zero at margins 100, 70, 40 and 0, because the fire is
  oversized and the drum rises to meet the valve wherever it is put. Only a smaller fire gets off
  it.
- **Tune a spec's constants through the SPEC's rig.** A scratch script and a spec rig part
  company through defaults nobody wrote down: a scratch script setting `cutoff: 40` measures a
  materially different engine from `light_and_run`, which leaves cut-off at its `ControlPoint`
  default of **100 — full gear** (517 kW against 364 kW), so a damper that clears the valve in
  one is 4.4 kPa short in the other. When a number is destined for an assertion, sweep it through
  the spec's own helper and constructor rather than a convenient copy.
- **An explicit integrator is only stable while `dt < τ`, and a limiter is not a substitute.**
  `k·ΔP·dt` with a per-node bound holding it together runs **400–600× past** the stability limit
  on every gas coupling here (firebox τ = 0.58 ms against a 250 ms tick), so the flow is decided
  by the limiter rather than by conductance — the flue asks for 1972 mol and is granted 1.8. The
  symptoms are a fire whose heat output swings by 5.9× every few ticks forever, and **doubling
  the draught conductance cutting engine power to a fifth**. Solve the whole network implicitly
  instead. Two things follow: never reach for a per-coupling law in a network, and **if a limiter
  is doing most of the work, the integrator underneath it is wrong.**
- **A headroom bound that ignores the receiver rising is wrong by exactly a factor of two.**
  Moving a sender to the receiver's *current* potential makes two 2 m³ vessels holding 6 kg and
  1 kg of air **swap contents on tick 1 and stay swapped forever**. A graph with `Atmosphere` on
  one end of every gas coupling hides it, because its capacity is ~10⁸× a vessel's so the
  receiver never rises. `transport_spec` asserts equalisation.
- **One restriction, one number.** A path governed by both a conductance and a
  `max_kg_per_s` that disagree is choked at every pressure it can reach, and a choked coupling
  carries a *fixed* flow — which leaves the pressure at either end with no feedback at all.
  The firebox ran to an 80 kPa vacuum in one direction and 3.2 atm at 1079 K in the other,
  depending only on which bound the solve reached first.
- **A conservation clamp is not a mechanism, and it hides the fact that one is missing.**
  `Tick#transmit_torque` scales a prime mover's impulse back to what its charge can pay for,
  which is a correct backstop. With the cylinder's diagram reading the boiler directly the
  regulator cannot touch torque at all, and the clamp becomes the *whole* throttling mechanism —
  discarding **30–50% of the declared work**, scale 0.496 at throttle 20 against 0.698 at 60,
  with declared torque nearly flat. The engine still behaves plausibly, which is what makes it
  invisible. **If a backstop is firing on most ticks, it is standing in for something and the
  something is what you should build.** Here that is the steam chest; with it the clamp sits at
  0.957 and does nothing.
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
  flue gas going out — 68 kg in and 103 kg out booked as `mass_added` 0.00. Conservation survives
  it (the net is exactly what the invariant constrains) so no spec fails; every figure is simply
  useless as a measurement. Book gross crossings from the granted flows.
- **What a sink receives is not what the source sent.** The stream gives up energy to every
  conduit wall it crosses, so `Grant#received` must be built from what advection actually
  delivered, not from the parcels the source dispatched. It is invisible while only mass is read
  from it, and worth 4 kJ a tick of drift the moment anything ledgers the *enthalpy* it was
  handed.
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
  **Steady inventory and steady throughput are mutually exclusive**, which is why `Conduit` is
  not an endpoint rather than having a cleverer rule. The symptoms are a firebox with no air at
  all every other tick, a cylinder swinging 16.4/78.2 kW, and every conduit silently delivering
  half its rating — each of which invites its own workaround.
- **Symbols as *values* do not survive JSON.** Resource ids in parcels and flags in instrument
  state both broke this way. `Operation#restore` normalises them.
- **A sparse hash cannot express a removal by diffing.** `PlayerView#flags` omits instruments
  with nothing to say, so rejecting unchanged entries never mentions a flag that *cleared* — a
  merging client shows `:pegged_high` forever, and `:warming_up` from the first few ticks of
  every match never goes away. `delta_from` emits an explicit empty list.
- **Coerce a value before it reaches the simulation.** `ControlPoint#set_target` calls `.to_f`,
  and a Hash does not answer to that, so one malformed record passed through untouched kills the
  runner process and every match on it.
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
- **A test-by-consequence dies quietly when its premise changes.** Asserting that eager loading
  does not *define* `ReactorSim` means nothing once the delivery tier legitimately requires the
  sim. Ask `Rails.autoloaders.main.unloadable_cpaths` directly, with positive controls so a typo
  cannot make it pass vacuously.
- **`config/cable.yml` must not use the `async` adapter in development.** It is in-process
  only, so a runner broadcasting from its own process reaches nobody, silently.
- **Two gems define `Rdkafka`, and which one loads is not what the Gemfile says.** Both `rdkafka`
  and `karafka-rdkafka` are in the lockfile. Measured 2026-09-14, `rdkafka` 0.29.0 is what
  resolves, and `karafka-core` patches it expecting a constant it does not define — so any broker
  error kills the process. **Check which gem actually loads rather than reasoning from the
  Gemfile**; see `app/CLAUDE.md` for the full shape.
- **rdkafka handles are not fork-safe.** One built before Puma forks is inherited broken and
  produces silently vanish. Build clients lazily, memoised per process id.
- **Never close an rdkafka handle inside a signal trap.** FFI plus a background polling thread
  means it deadlocks. A handler may only set a flag.

---

## Repository state

`git status` and `git log` are the truth. Work happens on a branch per release; the minion
release is `on-to-minions`.
