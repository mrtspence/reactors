# Mine accidents, unit 3 — the hazards that ride on P1–P4

**Status: unit 3a built** (as-built notes below); unit 3b is re-drafted in
[`mine-accidents-unit3b.md`](mine-accidents-unit3b.md), and its sections here are superseded.
Decisions in §4. Units 1 (P1–P4)
and 2 (the shaft, W1–W8) are built; see
[`mine-accidents-winding.md`](mine-accidents-winding.md) for both, its §5 for every decision taken in
review, and its "Unit 2, as built" section for where the build parted from the design. This draft
covers **unit 3 only**: the non-winding hazards that lean on the prerequisites, plus coal on the
hoist, which the unit 2 review put first. Unit 4 and the brattice/stopping hazards stay deferred
(§5).

Every section follows the unit 2 shape — mechanism, model, counterplay, what crosses the coupling,
specs — and where there is a real choice it gives the options with their costs and a
recommendation.

---

## 0. Carried over, not reopened

- **Thin specs.** Zero ticks for a function; ≤ 20 from a constructed state for behaviour; anything
  over 50 is justified in the spec.
- **A machine does not know it is unattended.** Removing an operator removes their forces and
  nothing else.
- **Failures are deterministic**; dice are thrown only in `draw_fates`, phase 0, unconditionally.
- **A trait tag's level matters, steeply** (`Minion#daftness`): a 1.0 tag is an extreme.
- **Mishaps are general**; a peril can damage a part. **Places, not jobs**, for anything that fills
  a room.
- **Docs land with the change**, comments are present-tense, seams left for later are named TODOs.

## 1. What exists, and three findings from the survey

The pieces this unit leans on, all built:

| Piece | Where | Used here by |
|---|---|---|
| Two-way rope coupling, load rejection, surges | P1, `Concerns::Roped` | 9 (overspeed), C0 (the real load) |
| The hoist, brake, rope, governor engineman, marshals | P2, W1–W6 | C0 |
| Ignition as a property of the room | P3, `ignition(state, levers)` | 10, 12, 15 |
| Mishaps; perils with `rate:`; the weighted pick | P4 | 14 (trappers), 16 |
| The shaft node, `through:`, closed ways, jams | S0, W4 | 11, 18 |
| The brattice as a leak conduit | S0 | 14 (the door is the same shape) |
| The man engine's strap (`ManEngine`) | W7 | 11 (the Cornish set's rods) |
| `Inrush` — a fissure driven by hewing, sized for the breach | first mine | 16, 17, 18 |
| `OldWorkings` — the goaf, seeping blackdamp | first mine | 13, 17 |

**Three findings from reading the code for this draft:**

1. **The restart slug (item 10) already happens.** Measured on a constructed single-shaft pit: a
   district at 9.5% firedamp by mass (~16% by volume, just too rich to burn) under lit sconces
   stays dark with the fan stopped, and **lights at tick 122 when the fan is restarted**, because
   the fan dilutes it down through the flammable band. From 17% by mass the same restart is still
   at 14.2% after 240 ticks — so the slug is real, slow, and arrives late, which is the historical
   shape. Item 10 is therefore counterplay and an instrument, not mechanism.
2. **A minion's own flame ignites nothing.** `open_flame` is carried by the crude and proper
   miner's tools and the hand lamp, and nothing in `lib/` reads it — only the wall sconces are an
   igniter. A hewer with a naked candle in a gassy district is safe so long as the sconces are
   safe lamps. Item 15 fixes it.
3. **There is no timber in content.** A headgear fire (12) needs a combustible the headframe is
   made of, and the timbering post already consumes "timber" only as a lever, never as a resource.

## 2. Build order, and why

| Order | Item | Size | Why here |
|---|---|---|---|
| 1 | **C0 Coal on the hoist** | large | Decided first in review. Makes the hoist the mine's main load, which is half of the pending "rebalance the mine up" |
| 2 | 14 Doors and trappers | small | Cheap, and it is what makes the ventilation circuit fragile in the ordinary way; 13 and 12 read better with it |
| 3 | 15 Ignition beyond the candle | small | Finding 2 is a hole in the existing game, not a new hazard |
| 4 | 9 Overspeed downstream | small | Pure P1 consumers; three `overload?`s |
| 5 | 10 The restart slug | small | Instrument and procedure only |
| 6 | 12 Fire on the intake | medium | New content (timber); the fan-reversal lever |
| 7 | 16 Outburst, 17 Goaf falls | medium | Both are the `Inrush` pattern on another node |
| 8 | 18 Inundation that kills | medium | Needs drowning and closed ways through a flooded pit bottom |
| 9 | 13 Gob fire | medium, tuning-heavy | A self-heating reaction is the most balance-sensitive thing here |
| 10 | 11 The Cornish set and Hartley | large | Wants C0's slot reshuffle and W7's strap generalised |

**Unit 3 is split at the line after item 5** (decision 1): **3a** — C0, 14, 15, 9, 10 — is one large
refactor and four small consumers of what exists, and is built first; **3b** — the rest — is new
content and new physics, and is re-drafted after 3a has landed and been played.

---

## C0. Coal on the hoist

**Mechanism.** Coal goes up the shaft in tubs on the cage deck: onsetter loads at the bottom,
engineman winds, banksman unloads at bank. The deck's weight is the hoist's load, so coal is what
the line shaft actually lifts, overload counts tubs, and an empty-of-men overwind is possible.

**Today.** `winder` is a rate-limited conduit (`Mine::Winder`, 2.2 kg/s for the steam whim, 7 for
the cage winder) driven off the line shaft, worked from a certificated `winding` lever. It shares
nothing with the hoist, so there are two certificated winding posts for one shaft.

### Options

**A. The cage carries the coal (recommended).** A `cage_deck` holder rides on the hoist: a loading
conduit fills it from the pit bottom only while the cage stands at the bottom landing and the
onsetter is working; an unloading conduit empties it into the screens at bank under the banksman.
The deck's contents are cargo (`Hoist#cargo_kg` adds them), so the work of lifting coal is booked
by the hoist's gravity source like any rider's, and the `Winder` conduit is deleted.

- *Pros*: one engine, one engineman, one certificated post; every unit 2 hazard now applies to coal
  winding (a parted rope drops a deck of coal, a hang-up with a laden deck snatches hardest);
  overload is tubs; the mine's power draw becomes real, which is most of the rebalance.
- *Cons*: the largest change in the unit. Every spec that relies on `winder`'s rate (mine_spec,
  mine_tech_spec, carrying, the coal-raised gauge's figures) is restated. Coal arrives in **deck
  loads**, so `coal_raised` steps rather than flows. And the engineman needs a **shuttle** mode, or
  the player is clicking a destination every forty seconds.

**B. The winder stays a conduit but loads the hoist.** Keep `Winder`, and add its carried mass to
the drum's cargo.

- *Pros*: small; coal output figures barely move.
- *Cons*: still two machines in one shaft; no decks, so overload is by rate and an overwind cannot
  have coal in it; the abstraction the review called hard to justify survives.

**C. Leave it.** Two certificated posts, coal by rate. Listed only to say why not: it is the
inconsistency the review flagged.

### The shuttle

The engineman's post keeps its destination lever and gains a **coal winding** lever (on/off). With
it on and nobody waiting or aboard, he shuttles: down when the deck is empty, waits at the bottom
for the onsetter's bell (deck full, or the pit bottom empty), up, waits at bank for the banksman's
bell (deck empty). **Men always take precedence**: a rider waiting at a landing turns the next trip
into a man-riding trip, and W6's bells and boarding rules apply unchanged — which is what keeps a
rescue from queuing behind a deck of coal. This reuses `Winding.govern`
with the destination chosen by the shuttle rather than the lever.

**Alternative:** the player drives every trip. Honest, and tedious enough that nobody would wind
coal; recommended against.

### Slots

The `winder` slot takes the hoist tiers; the `manriding` slot keeps only the man engine.

| Slot | Today | Proposed |
|---|---|---|
| `winder` | steam whim, cage winder (conduits) | **steam whim** (a kibble: no guides, no deck, small, slow — and men ride it, badly), **cage**, **hooked cage**, **tripped cage** |
| `manriding` | man engine, the three cages | **man engine**, rod catches tier |

The W1–W8 cage tiers move slot, keeping their ids; blueprints follow.

### The kibble

The steam whim is a hoist with a **kibble** for a cage: a bucket on the rope, no guides, a small
load. Coal goes up in it by the same deck mechanism, smaller. **Men ride it**, standing in the
bucket or on its rim, and a `riding_the_kibble` peril reaches its riders (`riders: %i[cage_drive]`),
scaling with the kibble's speed — it swings, catches the shaft side, and throws people out. No
catches, no hook, no trip. The cage tiers are then a safety upgrade as well as a speed one, which is
what the review wanted.

**Specs.** The deck fills only at the bottom landing with the cage stopped and the onsetter posted,
and empties only at bank (5 each); a laden deck is cargo (0); the shuttle makes one round trip from
a cage constructed near the bottom landing (≤ 60 — justified: one trip is the claim); men waiting
take the next trip (≤ 20); conservation through a trip (the existing cage conservation example,
re-pointed).

**Across the coupling.** The mine's draw rises to the scale the "rebalance the mine up" item asks
for; measure before tuning rather than after.

---

## 9. Overspeed delivered downstream

**Mechanism.** A surge on the engine (P1) arrives at the mine as line-shaft overspeed. A fan rotor
bursts (hoop stress goes as rim speed squared); a pump overspeeds and hammers its rising main;
electric lamps on a dynamo over-run and blow.

**Model.** Three `overload?`s against the line shaft's speed ratio, each scaled by integrity:

- **Fan** — `Wearing` on the upcast conduit, overload at `ω/ω_rated > burst × integrity`, mode
  `burst`: `derates: { head: 0.0 }`, an `impact` hazard to `bank`, damage to the upcast casing.
  The burst ratio comes from the rotor's material the way `Flywheel`'s does.
- **Pump** — stress per second as `(ratio − 1)²` above rated; mode `main_burst`, a `Breach` that
  spills the rising main back down into the pit bottom.
- **Electric lamps** — `Lighting` gains `Wearing`; overload past 1.25× rated, mode `blown`,
  `derates: { illumination: 0.0 }` — **an engine-house surge turns the district dark**, and the
  darkvision gate does the rest.

**Counterplay.** The engine's governor (deferred to after the mine pass). Mine-side, an **overspeed
trip** fitting on the line shaft that throws the clutch past a set ratio — which saves the fan and
then **sheds the whole mine as a load rejection**, running the engine away harder. That chain is the
point and should be visible in its description.

**Specs.** Each `overload?` at zero ticks, either side of its ratio; one seeded overspeed bursting
the fan in ≤ 10; the trip throwing the clutch (≤ 5).

---

## 10. The restart slug

**Mechanism.** Gas accumulated while the fan was stopped is diluted through its flammable band, or
driven past an igniter, when the fan starts. Already emergent (finding 1).

**Model.** No new mechanism. Two additions:

- **The procedure becomes legible**: a **gas reading before restart** — the flame cap already reads
  the district, so this is the deputy's report on the panel, plus a one-line advisory in the fan's
  description. Withdrawing the lights (`naked_flame` to 0) and men before restarting is the
  counterplay, and it already works.
- **The slug in the return.** In a single shaft the return passes the upcast foot, where nothing is
  alight today. A **furnace** ventilation tier (a fire at the upcast foot: buoyancy instead of a fan,
  and the classic igniter of return gas, answered by the "dumb drift" that routed gassy air around
  it) is the honest source — but it is a **new tier**, so it belongs to unit 4. Flagged there.

**Specs.** The measured example as a spec, constructed at the edge of the rich limit so the band is
reached inside ~60 ticks (justified: dilution is the claim): restarted, lit; stopped, not; restarted
with the lights withdrawn, not.

---

## 11. The Cornish set, and Hartley

**Mechanism.** A Cornish pump is a beam at the shaft top working rods down the shaft to plungers at
each lift. Rods break; at Hartley (1862) **the beam itself broke and fell into the only shaft**,
choking it, tearing out the brattice and trapping 204 men, who died of the foul air while rescuers
dug. The Act that followed required two shafts.

**Model.**

- **Generalise W7's strap** into a rod engine both the man engine and the pump use — the bob, the
  strap (`parted` worn through, `torn_out` on a hard stroke) and, new here, **the beam** (`broken`,
  fatigue per stroke under the column's weight). Extract it from `ManEngine` rather than copying it.
- **The pump becomes rods**: the Cornish set's conduit is `driven_by:` the rod engine instead of the
  line shaft, with `displacement: true`, so parted rods stop the pumping by themselves.
- **The beam falling** has `failure_damages` that choke the shaft outright and breach the brattice
  — the frame decision S0 made pays off: in `single_shaft` this is Hartley; in `two_shaft` the
  Upcast Ladders are the way out.
- **The rising main bursting** is item 9's `main_burst` on the same conduit.

**Counterplay.** Two shafts (the upgrade meaning what the 1862 Act meant); rod catches; slower
strokes; the sinking set, which is lighter and has no beam over the shaft.

**Specs.** The beam falling chokes the shaft and breaches the brattice (≤ 5); parted rods stop the
pump (≤ 5); a choked single shaft strands the shift where two shafts do not (the existing shaft_spec
claim, pointed at this cause).

---

## 12. Fire on the intake

**Mechanism.** A fire on the intake side — a hot sheave in a timber headframe, a slipping drive, a
belt — sends its smoke down with the ventilation, so the fan carries it through every working.
Creswell (1950), Sunshine (1972), Mauricewood (1889). Reversing the fan is the textbook answer and
reverses everything else with it.

**Model.**

- **Content**: `timber` (a solid fuel) and `timber_combustion`. Needed by this and by the
  last-pass brattice fires.
- **A headframe node** — a holder of timber and air at bank, on the intake path
  (`atmosphere → headframe → downcast`), thermally linked to the sheave. A sheave running hot or
  seized (W3) heats it; past the reaction's threshold it burns, and its flue gas goes down the
  downcast. One tick of lag on the intake for a holder on the path; measured before accepting.
- **A slipping drive** — a `DriveLink`'s slip work booked to a node rather than to friction would
  make a slipping belt an igniter. Recommended **deferred**: belts arrive with conveyors (unit 4).
- **Fan reversal** — a lever on a reversible fan tier only (decision 4) that negates the head.
  Reversed, the smoke goes back up the downcast; so does the district's firedamp, past whatever is
  in the intake.

**Counterplay.** Grease the sheave (W3 already); an iron headframe as an upgrade with no timber in
it; reverse the fan; withdraw the shift.

**Specs.** A constructed hot sheave lights the headframe (≤ 20); smoke reaches the pit bottom with
the fan forward and not with it reversed (≤ 20); an iron headframe never lights (0).

---

## 13. Gob fire

**Mechanism.** Coal left in the goaf oxidises slowly; where a trickle of air leaks through it —
driven by the fan's pressure — the heat cannot escape fast enough and it runs away, days later, as a
fire nobody can reach. The first sign is "fire stink". The answer is to seal the district, which
traps whatever gas is behind the seal with the fire.

**Model.**

- **Content**: `coal_oxidation`, a slow, mildly exothermic reaction that sustains from ambient,
  consuming coal and air into `flue_gas` (and a share of whitedamp for the stink).
- **The goaf** holds some coal and gains an air leak from intake to return through itself
  (a `Seep`-shaped conduit, pressure-driven — the fan's head is what drives it). Its own ambient
  loss is near zero: that insulation is the whole hazard.
- **The runaway is emergent**: too little air and oxidation starves; too much and the air carries
  the heat away; in between it climbs until `coal_combustion` takes over.
- **Fire stink** is an instrument on the return, observed by whoever is at the face (a deputy's
  nose; `observer:`, banded prose).
- **Sealing** is an effort job that throttles the goaf leak (stoppings built), which starves the
  fire — and lets firedamp accumulate behind the seal. The seal **blowing out** is a stopping hazard
  and stays in the last pass.

**Counterplay.** Seal early; run the fan at lower head (less leak); stone dusting does nothing for
this, which is worth saying in its description.

**Specs.** Oxidation warms an insulated goaf with a trickle of air, and not one with none or with a
gale (three constructed states, ≤ 20 each, read as temperature rise); a constructed hot goaf lights
(≤ 10); stink reaches the return gauge (≤ 10); sealing throttles the leak (0).

**Risk.** The balance between heating and loss is the most tuning-sensitive thing in the unit.
Budget a sweep, not a guess.

---

## 14. Doors, trappers and stoppings

**Mechanism.** Where the haulage road crosses from intake to return there is a door, and every set
of tubs opens it. A trapper — historically a child — shuts it after them. Left open, the air takes
the short way back to the upcast and the district starves. Thornley (1841), Burdon Main (1835).

**Model.**

- **A `Door`**, the brattice's shape: a leak conduit from the pit bottom to the return, whose
  conductance is its **open fraction** (in state). Tub traffic (the haulage road's `activity`) pushes
  it open; a trapper (an optional effort station, `trapping`, at the pit bottom) closes it at a
  rate. With nobody posted it stays as the last tub left it — the door does not know it is
  unattended.
- **Anybody can be sent to trap, and small is better.** The station is `aided_by: :diminutive`, a
  new tag on small creatures (the kobold now; pixies and gnomes later), with `exertion:` low and an
  `effort:` blend that pays nothing for force. The incentives make the smallest, cheapest hand the
  obvious choice — which is the historical trapper, emerging from the node rather than declared as
  an archetype.
- **A trapper who slips leaves it open** — the slip machinery, gated on `daftness` as everything is.
- **An explosion blows it out**: the district's fire `failure_damages` reach the door; `blown_out`
  is open for good. (Seals blowing out are the last pass's.)
- **Generalise `Brattice`** into a leak conduit both use, rather than copying it.

**Counterplay.** A trapper; a **self-closing door** tier (weighted, needs nobody, and jams now and
then — a mishap with no person behind it, or a slow wear); an **air lock** (two doors, so one is
always shut) as the top tier.

**Specs.** Traffic opens it and a posted trapper shuts it (≤ 5); unmanned under traffic it stays
open and district air falls (≤ 20); an explosion blows it out (≤ 5); the self-closing tier shuts
with nobody there (≤ 5).

---

## 15. Ignition beyond the candle

**Mechanism.** Safe lamps are not unconditionally safe: a gauze passes flame in a fast draught or
when it is damaged. Frictional sparks from a cutter pick striking sandstone ignite gas. And a man's
own naked light is the commonest igniter of all.

**Model.**

- **The hand flame** (finding 2): a minion carrying `open_flame` offers it to the room they are in
  — the same `ignition` map, fed from minions as well as nodes, summed by sorted id. Scaled by
  nothing: a candle is a candle.
- **Gauze in a draught**: the safe-lamp sconce tier offers a flame once the district's through-flow
  passes a velocity threshold (derived from the main road's carried volume and a declared area).
  The Davy lamp in kit gets the same rule through the hand-flame path.
- **Cutter sparks**: the coal cutter offers a spark while it is cutting, scaled by the worked
  hewing value. Water sprays as a counter are a cutter **tier**, so unit 4.

**Counterplay.** Safety lamps for everybody, not only on the wall; slower air at the face; the
deputy's flame cap.

**Specs.** A hewer with `open_flame` lights a mixture in the band where one without does not (≤ 5);
a gauze sconce offers nothing in still air and a flame past the draught (0); the cutter sparks only
while cutting (0).

**The harder opening is wanted** (decision 7). The starting kit carries `open_flame`, so the
starting pit becomes more dangerous in gas than it plays today, and safety lamps are what
progression buys. Measure how much harder, rather than assume it.

---

## 16. Sudden outburst

**Mechanism.** Gas-charged coal under stress fails all at once, ejecting coal and a flood of gas
into the face. Agrappe (1879).

**Model.** The `Inrush` pattern on the firedamp blower: `Wearing` stressed by worked hewing ×
the pit's gas `ground`; mode `outburst` derates its throughput upward by an order of magnitude and
dumps a mass of coal and dust into the district (a one-off transfer from the seam), with a
`crush` / asphyxia-by-displacement hazard at the face. Gassy pits are more prone by construction.

**Counterplay.** **Advance boreholes** — an effort station that drains the seam's gas ahead of the
face, lowering the stress term; cutting slower.

**Specs.** Stress accrues with hewing and not idle (0); a seeded-thin seam outbursts and the
district's gas jumps (≤ 10); boring lowers the rate (0).

---

## 17. Goaf falls and the windblast

**Mechanism.** The void behind the face hangs until it falls; when it does it flushes the goaf's
gas into the workings, and a large fall drives the air out ahead of it as a blast.

**Model.** The goaf gains a void (coal won, less what has been packed) and `Wearing` stressed by
it. Mode `fall`: the goaf seep's conductance derates upward for the flush, and an `impact` hazard to
the district and main road scales with the void. The void resets.

**Counterplay.** **Packing** (stowing) — an effort station that fills the void with stone, the
production cost being the hands; controlled caving as a later procedure.

**Specs.** Void grows with coal won and not idle (0); a seeded-thin goaf falls, flushes gas into the
pit bottom and hurts the district (≤ 10); packing slows the void (0).

---

## 18. Inundation that kills

**Mechanism.** Breaking into old workings full of water is already built (`Inrush`); what is not is
what the water does to people. Tynewydd (1877) — men survived ten days in an air pocket; Lofthouse
(1973) — the old plans were wrong; Knockshinnoch (1950) — liquid peat filled the roads.

**Model.**

- **Drowning** — a pit bottom whose water fills most of its volume has no breathable air *for the
  people in it*: `Breath` treats a submerged room as unbreathable. Recommended over a separate
  drowning hazard, because it then shares the dwell, the collapse and the rescue race with afterdamp.
- **The flooded pit bottom closes the ways through it** — the shaft and the main road gain
  `through: :pit_bottom` and the sump answers `blocks_passage?` past its flood mark. The district,
  higher, becomes **the air pocket**: people there are trapped, not drowned, until their air fouls.
- **Survey plans as an instrument** — the fissure's integrity read through a surveyor's plan:
  heavily noised and banded ("the plans show forty yards of solid coal"), with an `observer:`.
  Better plans narrow it; **boring ahead** (the same effort station as 16) is the counterplay that
  finds the water before the face does.
- **Liquid peat** — a mud resource that flows and fills roadways. **Deferred**: it is a new
  resource with its own transport behaviour, and the water half carries the hazard.

**Specs.** A flooded pit bottom closes the shaft and the road (0, on `blocks_passage?`); someone in a
flooded pit bottom drowns where someone in the district does not (≤ 10); the survey gauge reads the
fissure with noise (≤ 10).

---

## Unit 3a, as built — where it parted from the design

- **C0.** Built as option A. Three things the load forced that the design did not foresee:
  - **The winding clutches had to be ten times stiffer.** A clutch carries torque only as
    stiffness × slip; a tonne of coal is 14 kN·m at the drum, and at 4×10³ the slip that took was
    more than the drum's rated speed, so a laden cage ran backwards into the sump. At 3×10⁴ it
    climbs at ~1.8 m/s on the spec rig's supply.
  - **The engineman winds by speed.** At that stiffness a fixed full clutch hunts round the landing
    and a gap-proportional one stalls a laden cage short of bank; he now wants rated speed easing
    to a 0.4 m/s creep and takes the clutch up or lets it out each tick by the shortfall, and his
    braking margin moved inside the landing's width (0.3 m).
  - **The overwind trip cuts the drive** (`DriveLink#cut_by`, `Brake#cuts_drive?`) as well as
    braking, because a stiff clutch still in out-pulls the brake.
  - Also: winding coal takes **three posts** (engineman, onsetter, banksman), where the conduit
    winder ran unattended; the man engine's ids became `:man_engine` / `rods`, since a man engine
    and a hoist now stand side by side; `coal_raised` averages over a minute because coal comes a
    deck at a time; the `winding_gear` gauge went with the winder (the rope report replaces it).
- **14.** Built as designed, the door leaking from the pit bottom into the return road so one
  wiring serves both frames. Not built: **a trapper who slips leaving the door open** — a node reads
  the worked lever and cannot see a slip — and a self-closing door jamming. At hand-putting traffic
  the air lock is indistinguishable from a self-closing door; it wants heavier haulage to matter.
  The plain door standing open under the tubs with nobody trapping it is the starting pit's new
  normal, and it costs a third of the district's air.
- **15.** Built as designed. The gauze threshold is **2.3 m/s**, set from draught measured with
  the door shut (waddle 1.84 / 2.02, Guibal 2.54 / 3.03 m/s, single / two shafts; natural draught
  about 1.9) so that the Guibal is what defeats the gauze. A hand-carried Davy lamp does not yet fail
  in a draught — only the wall sconces read it. Constructing gas **on top of** a district's air
  over-pressures it into a 35 m/s gust down the intake for a tick; specs construct by displacement.
- **9.** Built as designed, the trip reaching the rope through a `tripped` flag in the line
  shaft's own state, because the rope's report sees only that state. Tested as **prevention**: a
  surge geared to 2.4× rated bursts the pump's main at 1.44× by tick 15 and the lamps and fan by
  tick 18 without a trip, and nothing with one. A trip cannot save a shaft already past every
  burst speed, and was never meant to.
- **10.** Specced, nothing built: the flame cap is the reading before a restart. The clean split
  needs the district just past its rich limit (9.5% by mass); just below it the stopped fan's
  natural draught dilutes it into the band too, only later.

## 3. Mechanisms this unit adds, collected

| Mechanism | First caller | Also used by |
|---|---|---|
| A deck holder riding a hoist, loaded and unloaded at landings | C0 | — |
| The shuttle mode on `Winding` | C0 | — |
| A leak conduit with a state-driven open fraction (from `Brattice`) | 14 | 13 (the goaf leak), last pass (stoppings) |
| The rod engine (from `ManEngine`) | 11 | W7 |
| Minions as igniters (`open_flame`) | 15 | — |
| `Breath` reading a submerged room | 18 | — |
| `through:` a node that is not a shaft (`:pit_bottom`) | 18 | — |
| Content: `timber`, `timber_combustion`, `coal_oxidation` | 12, 13 | last pass (brattice fires) |

## 4. Decisions from review

1. **Unit 3 is split.** **3a** is C0, 14, 15, 9 and 10 — one refactor and four small consumers of
   what exists — and is the unit to build. **3b** is 12, 16, 17, 18, 13 and 11 — new content and
   new physics — and gets its own draft once 3a has landed and been played. The 3b sections above
   are sketches to be re-drafted, not designs to build from.
2. **Coal goes on the hoist, option A.** The cage carries the coal on a deck, the `Winder` conduit
   goes, and there is one certificated winding post.
3. **Men ride the kibble**, as a peril: the starting shaft can be ridden, dangerously, and the cage
   is a safety upgrade as well as a speed one.
4. **Fan reversal is an upgrade** — the reversible tier only (3b, with 12).
5. **Men take priority on the shuttle**, always. It spares the player during a rescue as much as in
   ordinary running.
6. **The trapper is an optional work station anybody can be sent to.** Smaller hands are better at
   it: a new **`diminutive`** tag (kobolds now; pixies and gnomes when they exist) aids the
   station, and the station itself is tuned — light work, low exertion, nothing that rewards
   strength — so that the cheapest, smallest hand is the natural choice. The historical trapper (a
   child) emerges from those incentives rather than from an archetype.
7. **The harder opening is wanted.** Open flames from the start; safety lamps arrive later through
   progression. No compensating kit.

Nothing is open.

## 5. Deferred

- **Unit 4 — new production tiers**: rope haulage and runaway tubs (19), shotfiring (20), and from
  this draft: the **furnace** ventilation tier (10's slug in the return), **water sprays** on the
  cutter (15), **conveyors** and belt fires (12's slipping drive).
- **Last — brattices and stoppings as hazards**: collapse, fire load, and **seals blowing out**
  (13's sealing, 14's stoppings).
- **Liquid peat** (18), as a resource with its own transport.
- **Still open from unit 2**: a tub falling onto a cage hurting its riders, a snatch the rope
  survives jolting anybody, a "ready to wind" instrument.

## 6. Documentation owed when unit 3 lands

`reference/nodes.md` and `nodes/CLAUDE.md` (deck, door, rod engine, headframe, `Lighting` and
upcast `Wearing`); `concerns/CLAUDE.md` (minions as igniters, if it lands in `Tick`);
`reference/tick.md` (the shuttle in phase 0, minion igniters in phase 1); `content/CLAUDE.md` and
`guides/add-content.md` (timber, the two reactions); `reference/diagnostics.md` (fire stink, survey
plans, the gas-before-restart reading); `operations/CLAUDE.md` and the build guide (the slot
reshuffle); `spec/CLAUDE.md` (new and re-pointed spec files); `current_progress.md`.
