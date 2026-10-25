# Mobile engines — unit 4a: the engine itself

> Input to a decision, not a description of the system. Unit 4 of the open-pit sequence
> ([`open-pit-iron-research.md`](open-pit-iron-research.md); the sequence is on
> `current_progress.md`). **This draft covers 4a only.** 4b (the steam shovel) and 4c (the
> locomotive and its trains) get drafts of their own once this has landed; what they need from
> 4a is listed in §8.

## 1. What is decided

- **The shovel and the locomotive are engines of their own**, crewed, not loads on the line shaft
  (fixed plant stays on the shaft). Each carries its own coal and water.
- **Reuse the working steam engine** — the firebox chemistry, `Boiler`, `ReliefValve`,
  `FusiblePlug`, the steam chest, `Cylinder`, the flywheel — with **new, smaller blueprints**. No new
  physics: the locomotive boiler and its cylinder make 500–650 kW, and a shovel's engine wants
  about a tenth of that.
- **A bottom tier with almost no safety**, upgrades as parts: a dead-weight valve and try-cocks to
  start; a spring safety valve, a gauge glass, a pressure gauge, a fusible plug, bigger bunkers and
  tanks above it.
- **Full fidelity inside, little to watch outside.** The pit will hold several of these; a full
  panel for each would bury the player. Most levers are **set by the blueprint**, a few are
  **worked by the crew**, and the player sees a board in words and whatever gauges are fitted.
- **Proven through a shared helper** (`operations/mobile_engine.rb`) on a `harness: true` rig,
  since the pit does not exist yet. A rig of its own may come later.

## 2. Reuse needs every id namespaced

The steam engine names its nodes and levers outright — `:boiler`, `:firebox`, `:stoking` — about
130 of them across its builders and fragments, and **ids are one flat namespace per operation**. A
pit with a shovel and two locomotives has three boilers.

**Proposed: the builders take the ids they make and the ids they refer to**, through one small
naming object (`Names.new(prefix)`, whose `.(:boiler)` is `:boiler` with no prefix and
`:shovel_boiler` with one). Every `SteamEngine` builder and fragment helper takes it, defaulting to
no prefix. **The steam engine must come out bit-identical** — its snapshot digest unchanged — which
is the guard for a refactor this wide.

Alternatives:

- **Rename a built fragment after the fact.** Generic, and touches no builder — but nodes hold other
  nodes' ids inside their own configuration (the relief valve's drum, the plug's firebox, a link's
  ends, a diagnostic's source), and nothing can rename those from outside. It fails silently: a
  relief valve watching the steam engine's boiler instead of its own.
- **Write the mobile engine's builders afresh** from the stock node classes. No risk to the steam
  engine, but the derivations (a shell's rating from its plate, a cylinder's thermal mass) live
  twice and drift — the "write the wiring once" rule.

## 3. The engine

One fragment per engine, named by its prefix and standing in one place (fixed in 4a; a moving one is
4c's):

| Piece | From | Notes |
|---|---|---|
| Firebox and grate | the steam engine's firebox | a small grate |
| Bunker and stoker | `stock_bunker`, `stock_stoker` | the bunker is a tiered part: small to start |
| Boiler | `boiler_fragment` | a **vertical boiler**: small drum, thick plate |
| Chimney | `plain_chimney` | natural draught; the blastpipe comes with the locomotive |
| Tank and feed | the water supply and injector | the tank is a tiered part |
| Relief | a **dead-weight valve** to start | a fixed setting, no easing lever |
| Steam chest, throttle, cylinder, cocks | the steam chest, regulator, cylinder, cocks | a small bore and stroke |
| Engine shaft | `flywheel_fragment` | a small flywheel, its own shaft |
| Load | `load` | the rig's; 4b and 4c replace it with a drum and with traction |

Sized to a period shovel's engine — a 2¼-yd³ railroad shovel burned 12,000–15,000 gallons of water a
day (Marsh), about 0.6 kg/s of steam, so **40–100 kW** at work. The figures are a sweep on the rig,
not this draft.

**The advance shift raised steam.** Every operation starts with one, so an engine starts hot and
working: the rig constructs that state (an `EngineRig`-like seed taken from a running engine, as the
steam engine's is) rather than raising steam from cold every example.

## 4. Who works it, and what is left to the blueprint

Two posts, both multi-skilled rather than many levers:

- **The fireman** — an effort post, stoking from the bunker, exactly the steam engine's.
- **The driver** — a **governor** post, as the winding engineman is, working the engine's levers
  as `internal: true` levers the player never sees: the throttle to what the engine is asked for,
  and **the feed to the water**. Asked for nothing, he shuts the throttle. A complexity on the post
  with a ticket to match, so a driver out of his depth slips — and a slip at the feed is a low
  water and a crown sheet.

**Everything else is the blueprint's**: the damper, the cut-off, the cocks and any blower are
internal levers **held at a default the fitted part declares** — a damper part saying 70% open, a
cylinder its cut-off — so swapping a part changes what the engine does without anybody touching a
lever. Nobody moves them; they hold.

**Why the feed is the driver's and not a fixed setting:** a fixed feed can only match one rate of
evaporation. Worked harder, the water falls; eased, it rises and primes. Somebody has to keep it,
and that somebody being a person — with a temper, a fatigue and a ticket — is what keeps the
boiler's hazards alive without a dial for the player.

## 5. The gauges are the driver's

**A gauge fitted to a mobile engine improves the driver's keeping of it**, and only secondarily the
player's view. The driver governs from the machine's last tick, read through what is fitted:
**try-cocks give him the water in coarse steps**, a gauge glass gives it him nearly true; no pressure
gauge leaves him working the throttle by the sound of her. Read as a deterministic quantization in
phase 0, so it draws nothing (the noisy `Diagnostic` chain stays phase 7's).

So the upgrade that makes a mobile engine safer is the one that makes its crew better at it — the
same ladder as the steam engine's, with the crew between the dial and the boiler.

**The player sees**, per engine:

- **A status board in words**, as `winding_signals` is for the cage: steaming, short of steam, short
  of water, priming, out of coal, fire low, standing.
- **The fitted gauges**, if any, as ordinary dials — at the end of `PANEL_ORDER`, an engine's
  together.

## 6. The bottom tier and the ladder

| Kind | Bottom | Above it |
|---|---|---|
| Relief | dead-weight valve: one setting, sticks with wear | spring safety valve |
| Water reading | try-cocks | gauge glass |
| Pressure reading | none | Bourdon gauge |
| Fusible plug | none | fusible plug |
| Bunker | small | larger |
| Tank | small | larger |

Unlocks costing extracted coal and gated behind achievements are the delivery tier's, stubbed as
every other blueprint's gate is.

## 7. Specs (relational, on the rig)

- The steam engine is bit-identical after the namespacing (its digest).
- Two engines in one operation do not touch each other's water, steam or shaft.
- A seeded engine carries on at work with no transient.
- The driver holds the water band at work, and its spread is wider on try-cocks than on a glass.
- Asked for more, the engine makes more; asked for nothing, the throttle shuts.
- An empty bunker lets the fire die; an empty tank lets the water fall.
- A driver slipping at the feed lets the crown sheet uncover; with no plug the drum goes, with one
  the plug goes first.
- The dead-weight valve lifts at its setting and the spring valve holds a closer band.
- A blueprint's default reaches its lever.
- Conservation through a working spell.

## 8. Deferred

- **4b, the steam shovel**: the load becomes a hoisting drum digging a bench into cars, with the
  craneman and pitmen (moving up, track); water by hose from a standpipe, coal brought up; struck by
  the dipper, caught in the swing.
- **4c, the locomotive and trains**: traction on grades, cars, positions (at the shovel, running,
  at the dump), the coaling and water point, runaways; **a node whose place moves**, which
  `place.rb` refuses today and `Tick#endanger` would read from the train's state.
- **Slots for several engines in one pit**: one set of fittings per engine, or per class of engine
  — decided in 4b, when the first pit-side engine needs slots.

## 9. Questions

1. **Namespacing by threading the names through the builders** (§2), or one of the alternatives?
2. **The driver works the throttle and the feed; the blueprint holds the rest** (§4). Is anything
   else his — the cocks when she has stood, the damper?
3. **Gauges serve the driver first** (§5): agreed, or should a fitted gauge be the player's alone?

## 10. Review decisions

1. **Names threaded through the builders, and unique per engine, not per kind** — a pit may have
   two shovels. **An engine's prefix is the slot it is fitted in** (`shovel_1`, `shovel_2`): slot
   ids are unique by construction, and the flat-namespace check refuses a collision if they ever
   were not.
2. **As few levers as we can get away with**: the driver works the throttle and the feed, the
   blueprint holds the rest. Sidegrade blueprints that come with an adjustable lever are the way a
   player buys more control, later.
3. **The gauges serve the driver.** Upgrades or sidegrades that serve the player as well come later.
4. The steam engine's locomotive boiler and cylinder make **500–650 kW**; a shovel's engine is
   about a tenth.

## 11. Settled while building

- **A slot carries a spec of its own** (`Slot#spec`, merged over the assembly's for the part fitted
  in it), which is how a part learns which engine it belongs to; `Assembly` checks `provides:`
  under the slot's names. The stationary engine's builders and fragment helpers take `names:`,
  defaulting to `SteamEngine::HOUSE`, and came out **bit-identical** — node configuration and a
  300-tick working run, on five loadouts across both chassis.
- **The inline wiring a mobile engine shares became fragment helpers** (`firebox_fragment`,
  `stoker_fragment`, `feedwater_fragment`, `regulator_fragment` and the rest), each taking the
  lever's own options so a blueprint can hold it.
- **She exhausts up the stack.** A plain chimney over a small fire on a 6 m stack drew so little
  that the fire burnt rich on what reached it and banked its coal unburnt; with a blastpipe she draws
  as hard as she works, as a period shovel did. The gas path keeps the stationary engine's
  conductances (damper 0.35, tubes 4.0, chimney 0.4): a quarter of the coal at a sixth of the
  restriction starved the fire.
- **Observed at work** (the rig's `at_work`): at the driver's 60 and the load at 60, **81 kW** from an
  890 kW fire, the drum at 8 atm on its dead-weight valve, 34 rad/s; coal 0.03 kg/s, so the small
  bunker lasts nearly three hours, and water 0.27 kg/s, so the small tank about ninety minutes. On
  try-cocks the driver holds the water between 45% and 54%, feeding on and off. (Taken first at 61 kW
  and 37 rad/s, with a light wheel the engine's own fragment had also belted to the load beside the
  rig's belt; the wheel is the shovel's heavier one now, belted by the host alone.)
- **The rings carry a lubricator's 3 kg of oil**: they drink about a kilogram an hour, and nobody goes
  round with a can.
- **The driver's ticket is the hot work ticket** (`licensed`): live steam, an open fire and somebody
  else's life on the footplate. No new course.
- **Built and not built**: the dead-weight valve does not stick with wear — it has one setting and a
  loose band, and sticking wants a wear model on `ReliefValve` first. **The status board in words
  waits for 4b**, where the pit's panel is the first thing to show it; built now it would have no
  caller. Raising steam from cold is not supported and needs not be: no match starts an engine cold.
- **Blueprint prices** are in `config/blueprints.yml`; the large bunker and tank cost coal the pit has
  raised. Their achievement gates wait for the achievements.
