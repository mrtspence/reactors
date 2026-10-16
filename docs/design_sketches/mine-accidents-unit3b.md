# Mine accidents, unit 3b — new physics on top of 3a

**Status: reviewed; building in order.** Re-drafted from the sketches in
[`mine-accidents-unit3.md`](mine-accidents-unit3.md) §11–§13 and §16–§18 against the code as 3a left
it. Unit 3a (C0, 14, 15, 9, 10) is built; its as-built notes are in that file. The decisions taken in
review are in §8; where one changed a section, the section says so.

Every section keeps the unit 2 shape: what exists, the model with its options, counterplay, what
crosses the coupling, and specs. §0 of the unit 3 sketch (thin specs, machines do not know they are
unattended, dice only in phase 0, steep tag levels, places not jobs, docs with the change) carries
over unchanged.

---

## 1. Findings from the survey

Five things reading the code turned up, several of which change the earlier sketches.

1. **`Breath` counts standing water and coal as if they were air.** `Tick#breathability` hands
   `Breath.breathable_fraction` every parcel in the room's air node, so 1 t of water in the pit
   bottom displaces 1 m³ of breathing space exactly as 1 m³ of blackdamp would. It is negligible
   today — the sump floods at 2.4 t against 900 m³ of air — but it is wrong, and item 18 would
   build on it. **Breath should read the gas phase only**, and drowning should be its own rule on
   the water's depth (§2).
2. **There is no self-ignition.** A fire only starts from a seed — a heater lever or something alight
   in the room (`Tick#ignition_sources`). From zero lit mass a reaction stays at zero, which is right
   for a grate and wrong for timber against a seized sheave or coal heating itself in the goaf. Items
   12 and 13 both need **a fuel that lights itself past a temperature**, so it is one mechanism, and
   it belongs in content (§4).
3. **The unit 3 sketch's "no timber in content" was wrong.** `wood` and `wood_combustion` exist —
   the engine's kindling. A headframe is made of `wood`; no new resource is needed.
4. **Every failure latches.** `Wearing` breaks once and stays broken (only `Rope#renew` resets
   durability). That is right for an inrush (18) and wrong for goaf falls (17), which recur through
   a working life. Recurring hazards need a schedule of their own (§6).
5. **Drowning is reachable only at the edge of the pump tiers, which is where it should be.** The
   seepage fissure lets go at 18 kg/s. Water to the roof of the pit bottom — about six times the
   2.4 t flood mark, ~14 t — arrives in ~13 minutes with no pump; the sinking set (14 kg/s) stretches
   that to about an hour; the Cornish set (26 kg/s) holds it. So the inrush kills only when the
   pump is too small, stopped, or burst by a surge — which is the pump tier's whole job.

## 2. Build order

| Order | Item | Size | Why here |
|---|---|---|---|
| 1 | **18 Inundation that kills** | medium | Fixes finding 1, which everything after it breathes through. Reuses `through:` and `blocks_passage?` |
| 2 | **11 The Cornish beam, and Hartley** | small (option B) | One bystander node with failure damages; the shaft and brattice already know how to be wrecked |
| 3 | **12 Fire on the intake** | medium | Lands self-ignition (finding 2), a headframe slot and the reversible fan |
| — | *playtest checkpoint* | | The three above change what kills a shift; worth playing before the goaf work |
| 4 | **16 Sudden outburst** | medium | Lands the boring-ahead station, which 18's survey instrument then also uses |
| 5 | **17 Goaf falls and the windblast** | medium | Lands the recurring-hazard schedule |
| 6 | **13 Gob fire** | medium, tuning-heavy | Uses self-ignition (from 12) and the goaf (from 17); the most balance-sensitive item |

Recommended as one unit with a checkpoint after item 3, rather than a 3b/3c split with its own
draft: the second half needs no design the first half will invalidate, only a playtest.

---

## 3. Item 18 — inundation that kills

**What exists.** `Inrush` — the seepage fissure, stressed by worked hewing, latches to `inrush` and
passes up to 18 kg/s into the pit bottom (`Sump`). `Sump#flooding` is a 0–1 gauge against
`FLOOD_KG` (2.4 t, water over the rails). Nothing happens to anybody standing in it.

**Model.**

- **Breath reads gas only.** `Tick#breathability` filters the room's parcels to the `gas` phase
  before handing them to `Breath`. A behaviour change, so measured before and after on the existing
  breath and afterdamp specs; expected to move nothing measurable.
- **Drowning is the room being submerged.** `Sump` gains `ROOF_KG` (the depth at which there is no
  air left to stand in — ~6 × `FLOOD_KG`), and a room whose air node answers `submerged?` is
  unbreathable for the people in it: breathability 0, so the existing dwell, collapse and rescue race
  apply unchanged. **No separate drowning hazard**: sharing the afterdamp path is what makes a
  rescue from a flooding pit bottom play like one from a gassed district.
- **A flooded pit bottom closes the ways through it.** The main road and every shaft passage gain
  `through: :pit_bottom`, and `Sump` answers `blocks_passage?` past `ROOF_KG`. The district, higher
  up, becomes the **air pocket**: the shift there is trapped, not drowned, until the air fouls —
  Tynewydd.
- **The survey reading.** A prose instrument on the fissure's integrity ("the plans show forty yards
  of solid coal" → "the borer's water is coming back dirty"), heavily banded, observed by the
  **boring** station from item 16 and `:offline` without one. Until item 16 lands it is observed by
  the timbering post, as the flame cap is.

**Revised after playtest review — the water is part of the ground.** As for the gas pockets (item 16,
decision 7), **old workings full of water are drawn per match**: 0, 1 or 2 of them at 50% / 45% /
5%, each at a random distance into the face and each holding a finite body of water (20–80 t, not
scaled by `ground` — vary the ordinary make, never the catastrophe). Nobody is told.

- **Real scale** (decision 15): the face advances by coal won at **4.7 t a metre** — a heading 3 m
  wide in a 1.2 m seam — so the 90 t district is about 19 m deep and a pit raising 2–3.5 kg/s
  advances 1.5–2.5 m an hour. Water and gas lie **between 2 m and 12 m** in: most short matches meet
  none, a long one probably meets one.
- **The breach is positional, not a wear-out.** The fissure lets go when the face reaches the water;
  driving the face is still the cause, because it is the only thing that advances it. **Within a few
  metres the coal weeps** — the ordinary seep rises as the barrier thins — which the water-make gauge
  and the plans both show.
- **A body of water runs out.** Breached, it comes in at the inrush rate until its tonnes are through,
  and the fissure goes back to the ordinary seep — so a second body further in is a second event.
- **`Mine::Ahead`** holds what both share: the draw, the depth range, the advance read off the seam.
- **A pinned `ground:` draws no water**, so a spec measuring the machine meets none; a spec about the
  inrush constructs the body it wants.

**Options for the depth rule.**

- **A. A mark on the sump (recommended).** `ROOF_KG` beside `FLOOD_KG`. *Pros*: one number, read the
  way the flood gauge already is. *Cons*: the pit bottom's 900 m³ of air and its 14 t roof are
  separate figures that have to be kept consistent by hand.
- **B. Derive depth from volume and a floor area.** *Pros*: geometry rather than a constant.
  *Cons*: the 900 m³ air volume and the 2.4 t flood mark already disagree about the floor area by
  two orders of magnitude; reconciling them moves every ventilation figure.

**Counterplay.** The pump tier; keeping the pump turning (the line shaft, the trip, a surge); boring
ahead to find the water before the face does; withdrawing the district before the pit bottom closes.

**Across the coupling.** None directly. A surge that bursts the pump's main (item 9) is now how an
engine-house mistake drowns a shift.

**Specs.** Breath ignores standing water (0); `submerged?` and `blocks_passage?` either side of
`ROOF_KG` (0); somebody in a pit bottom constructed at the roof mark collapses where somebody in the
district does not (≤ 20); the survey reading bands the fissure's integrity (0).

**Deferred.** Liquid peat (Knockshinnoch), as before.

---

## 4. Self-ignition (for 12 and 13)

**Model.** A reaction's `ignition:` block may declare **`autoignition_k:`**. Past it, a node's bulk
temperature seeds the fire itself: `Ignition.advance` adds a seed of `AUTO_SEED_KG_PER_S` while the
node is hotter than that, exactly as a match does. Opt-in per reaction, so a reaction without it
behaves bit-identically.

| Reaction | `autoignition_k` | Effect elsewhere |
|---|---|---|
| `wood_combustion` | ~570 K | The engine's kindling already burns with a lit grate; no change expected |
| `coal_combustion` | ~700 K | A firebox above 700 K is already alight. Measured on the steam engine specs before accepting, because a banked fire relighting itself would change the stoking procedure |
| `firedamp_combustion` | none | Gas needs a flame; a hot roadway does not light it in this model |

**Alternative: a hot bearing as an igniter.** `Bearing#ignition` offers a flame to its place's air
past a temperature. *Pros*: no content change, reuses the room-ignition path. *Cons*: it lights the
*room's air*, not the timber next to the bearing, so it cannot reach a headframe that is not the
bank's air node; and it does nothing for the gob fire, which has no room. **Recommend
`autoignition_k`.**

**Specs.** A vessel of wood and air held above `autoignition_k` lights with no igniter, and below it
does not (≤ 10); a reaction without the key is unchanged (0).

---

## 5. Item 11 — the Cornish beam, and Hartley

**What exists.** The pump is a `Pump` conduit off the line shaft; `cornish_set` is a bigger,
more efficient tier of it. The man engine (`ManEngine`) is a `Load` with a strap that wears per
stroke and parts, and its `failure_damages` already wreck the shaft and, in a single shaft, the
brattice. A wrecked shaft closes every way through it.

**Model, as decided: the beam is the Cornish set's driven element** (decision 4). The fragment adds
a `PumpBeam` — a `Load` drive-linked to the line shaft, exactly as the man engine is, with `Wearing`
— and the pump conduit is `driven_by: :pump_beam` with `displacement: true`. **The beam is a power
sink on the operation's own shaft**, never an engine of its own: whatever is putting work into the
line shaft works the pump through it, and a broken beam stops the pump by itself, because nothing
turns its conduit. It wears per stroke under the column's weight and overloads on overspeed (item 9's
ratio). Mode `broken`:

- `failure_damages`: the shaft and, in a single shaft, the brattice — Hartley.
- `failure_hazards`: `impact` to the bank and anyone `riders:` in the shaft.
- A prose `beam_condition` gauge read by the banksman, banded and late.

The sinking set has no beam and cannot do this. **The upgrade brings the hazard**, which is the
historical shape: Hartley's beam engine was the better pump.

**Not built: a rod engine extracted from `ManEngine`** and shared with the pump. The two stay
separate nodes until something wants the strap and the beam on one class.

**Counterplay.** Two shafts — the upgrade meaning what the 1862 Act meant; the overspeed trip; not
running the Cornish set flat out; watching the beam.

**Across the coupling.** A surge breaks the beam sooner, so an engine-house mistake can close the
only shaft.

**Specs.** The beam wears with pumping and not idle (0); overspeed breaks it (0); broken, it wrecks
the shaft and brattice and stops the pump (≤ 5); in a single shaft the shift is stranded, in two it
is not (the existing shaft_spec claim, pointed at this cause, ≤ 20).

---

## 6. Item 12 — fire on the intake

**What exists.** The sheave is a `Bearing` at bank that runs hot when it is not greased and seizes
(W3). The intake is `atmosphere → downcast → pit_bottom`. The fan exhausts on the upcast, at a fixed
positive head.

**Model.**

- **A headframe slot.** `timber_headframe` (default) and `iron_headframe` (upgrade). The timber tier
  adds a `Headframe` vessel at bank holding ~15 t of `wood` and some air, thermally linked to the
  sheave, hosting `wood_combustion` with `autoignition_k` (§4). The iron tier adds nothing that
  burns.
- **How its smoke reaches the downcast.** Two options:
  - **A. On the intake path** (`atmosphere → headframe → downcast`). *Pros*: all the intake passes
    the timber, so a burning headframe is the whole intake. *Cons*: a holder on the intake adds a
    tick of lag and a volume to every ventilation figure measured so far, so every mine spec's air
    numbers move.
  - **B. In parallel with it (recommended)**: the headframe draws from the atmosphere through its own
    small conduit and exhausts into the downcast, so the fan's suction pulls a share of the intake
    through it. *Pros*: the existing circuit is untouched while it is not burning; the share is one
    conductance to tune. *Cons*: a smaller fire than reality, air-limited by that share.
- **Collapse.** Burnt through (the vessel's temperature rating), it fails and takes the sheave and
  part of the shaft with it — a second way to close the shaft.
- **The reversible fan.** A third fan tier, `reversible_fan`, with a `fan_reversed` lever that
  negates the head. Reversed, smoke goes back up the downcast — and so does the district's firedamp,
  past whatever is alight at the pit bottom. **Risk**: the gas solve has never run with a negative
  head; measure first, and fall back to rewiring the fan's ports on reversal if it misbehaves.
- **A slipping drive as an igniter** stays deferred to unit 4 with belts.

**Counterplay.** Grease the sheave; an iron headframe; reverse the fan (if fitted); withdraw the shift.

**Across the coupling.** None.

**Specs.** A sheave constructed seized lights a timber headframe and not an iron one (≤ 20); smoke
reaches the pit bottom with the fan forward and not reversed (≤ 20); a headframe constructed burnt
through wrecks the sheave and shaft (≤ 5).

### 6a. Re-drafted after measuring the sheave — for review

Building 12 started with self-ignition (§4, built) and a measurement, and the measurement says the
**sheave does not heat the way a real one does**. Wood keeps its real ignition temperature —
**573 K**, timber held at ~300 °C — and the model is what gets corrected (review guidance: never
pin a threshold to what an unrealistic model happens to reach).

**What a real neglected sheave does.** Hand estimate for the cage tier, wound dry with coal:

| | Model before | Realistic |
|---|---|---|
| Load on the journal | 2 cages, 29 kN | the ropes' pull over a quarter-turn wrap: √2 · g · (two cages, a full deck, two ropes) ≈ 63 kN |
| Friction once wiped | μ 0.12, lubricated boundary | lining gone, metal on metal: μ 0.3–0.4 |
| Heat while winding | ~1.5 kW | ~10 kW |
| What seizure does | locks the drum, so heating stops | the engine winds on and **the rope drags through the seized groove** — the classic headgear fire |

Measured on the cage tier, wound dry with an empty cage on a half duty: **372 K** after 1000 s
before, **459 K and still climbing** with the load corrected. It then seizes at the babbitt's
melting point (520 K) and locks the drum — so 573 K timber is unreachable whatever the numbers,
and the real headgear fire cannot happen in the model.

**Already changed** (a numbers fix, within the review guidance): the sheave's load is the ropes'
pull with both cages, a full deck and the ropes' own weight, at a constant 3.5 kg/m that the rope
tiers below will replace.

**Proposed, for review:**

- **A. Wiped bearings rub metal on metal.** A `wiped` mode raises the boundary μ to ~0.35 instead of
  only derating the film. *Generic* — the steam engine's journals rub harder once wiped too, which
  is right and moves its bearing figures, so it is re-measured. Alternative: a `mu_wiped:` the sheave
  passes alone. **Recommend generic.**
- **B. A seized sheave is a brake on the rope, not a lock on the drum.** Seized, it stops turning
  and the rope slides through its groove: friction `μ_groove × rope load × rope speed` heats the
  sheave (and so the headframe through `hot_spot`), the rope scores fast through the existing
  hot-sheave wear, and the engineman feels a drag rather than a wall. **This reverses W3's "seized,
  it stops the winding"** (unit 2), which is why it is a decision. Alternative: keep the lock and
  accept that headframe fires need a fire brought to them. **Recommend B.**
- **C. The headframe as built in §6, with `hot_spot: :sheave`**, so the timber the sheave sits on is
  lit by the sheave's temperature rather than by heating 15 t of frame through a thermal link —
  which no lumped body could do honestly.

### 6b. Rope tiers — new, for review

**Mechanism.** The winding rope becomes its own slot. Historically: flat hemp ropes in the early
pits, wrought-iron wire rope from the 1840s, steel wire rope from the 1870s. Cheaper ropes are
weaker, and a rope is now something a player chooses and can skimp on.

| Tier | Breaking strain | kg/m | Wears | Character |
|---|---|---|---|---|
| `hemp_rope` (default) | ~110 kN | ~1.1 | rots: wetness bites it hardest | light and stretchy, so a snatch is softer; weak, so a laden cage is near its limit |
| `iron_wire_rope` | ~400 kN | ~5.5 | corrodes; bending wear | the upgrade that makes coal winding safe |
| `steel_wire_rope` | ~1000 kN | ~5.8 | corrodes least; bending wear | strongest, stiffest — the hardest snatch |

Figures are for a ~40 mm rope and are first guesses to check against period tables in the build.

**Model.**

- **A `rope` slot** in the shaft group, required, default `hemp_rope`. Each tier is a `Rope` with its
  own `breaking_kn`, `kg_per_m`, `stiffness_n_per_m` and wear rates; `ROPE_BREAKING_KN` goes from the
  hoist tiers.
- **The rope's own weight enters its tension**: `kg_per_m × the length hanging below the sheave`, so a
  heavy rope is a load the drum lifts and a deep shaft strains a rope at bank even with the cage
  empty.
- **The sheave reads its load off the rope.** A bearing gains a generic third load source: a
  `loaded_by:` node answering `bearing_load_n(ctx)`. The rope answers √2 × both sides' tension, so a
  laden wind heats the sheave more than an empty one — and the constant in §6a goes. The slots stay
  independent: the hoist names `:winding_rope` by id, as it already does.
- **The spare is the same kind of rope.** Re-roping puts on a new rope of the fitted tier; nothing
  else changes.
- **Blueprints** price each tier by its bill of materials (hemp; wrought iron; steel).

**Counterplay.** Buy the better rope; recap and re-rope on time; keep the shaft dry; wind lighter
on hemp.

**Specs.** Each tier's breaking strain and weight reach the rope (0); a rope's weight is in its
tension with the cage empty (0); the sheave's load follows the rope's tension, laden against empty
(0); a laden cage on a worn hemp rope parts where a steel one holds (≤ 10).

**Where it goes in the order:** before 12, because the sheave's load reads the rope.

---

## 7. Items 16, 17 and 13 — the face and the goaf

### Item 16 — sudden outburst

**Model, as decided** (decision 7). **Pockets are part of the ground**: how many a match has, and
where, is drawn at `initial_state` beside the seeps, and nobody is told.

- **How many**: 0, 1 or 2, at 50% / 45% / 5% as a first pass. Not knowing whether there is one —
  or, having dealt with one, whether there is another — is the tension.
- **Where**: each at a distance into the face, drawn between a sensible floor (never in the first
  few metres) and the advance a match plausibly reaches. **The face's advance** is coal won from the
  seam (its contents against its starting mass, read N−1) over a figure of tonnes per metre — the
  same reading item 17's void uses.
- **What one holds**: a mass of firedamp and coal dust, scaled by `ground`, which **stays in the seam
  and the face dust** until released — so the gas exists from the start and the books need nothing new.
- **The burst**: the face reaching a pocket that still holds gas releases it through an `Outburst`
  conduit from the seam into the district, owed mass passed over a few seconds — gas, and dust that
  the next flame will find. A `crush` hazard at the face. The pocket is then spent.

**Boring ahead**, the counterplay: an optional effort station in the district that **drains the next
pocket within reach ahead of the face** slowly into the district air — gas the fan must carry, so it
is not free — shrinking the outburst, or ending it if bored out before the face arrives. The borer
**hitting gas** is the first anyone knows of a pocket, through the boring reading below. The borer
is also the **observer of the survey reading** (item 18): the one who finds the water. Staffing it
costs a hand at a face that already has fewer hands than jobs, which is the trade.

**Specs.** The draw gives 0/1/2 pockets in roughly the stated shares across seeds, and none in the
first few metres (0, over many `initial_state`s); a face constructed just short of a pocket bursts
when worked into it and the district's gas jumps (≤ 10); a pocket bored out first releases nothing
(≤ 10).

### Item 17 — goaf falls and the windblast

**Model.** The goaf gains **hanging void**: coal won from the seam (read from the seam's contents,
N−1) less what has been packed. A fall comes when the void passes the goaf's next **span**, and
spans are a **schedule drawn at `initial_state`** — a short list of figures from the goaf's own RNG
stream (finding 4), consumed one per fall, so replay is exact and nothing is drawn mid-tick. A fall:

- flushes the goaf: the blackdamp seep's conductance is multiplied for a few seconds;
- drives a windblast: an `impact` hazard to the district and the main road, scaled by the void that
  came down;
- resets the void.

The **first weighting** — the first, largest fall — is the dangerous one, so the first span is the
largest.

**Packing**, the counterplay: an optional effort station that fills the void with stone. The cost is
the hand.

**Specs.** Void grows with coal won and not idle (0); a goaf constructed at its span falls, flushes
gas into the pit bottom and hurts the district (≤ 10); the next fall waits for the next span (0);
packing slows the void (0).

### Item 13 — gob fire

**Model.**

- **Content**: `coal_oxidation` — slow, mildly exothermic, sustaining from ambient, consuming coal
  and air into blackdamp. No `ignition:` block: it simply runs.
- **The goaf holds coal** — pillar coal left behind. Two options: **a fixed amount scaled by
  `ground` (recommended)**, or a share of every tonne hewn (more honest, and it makes hard working
  feed the fire; but it couples the fire to production in a way that is hard to tune).
- **A leak through the goaf**: a conduit from the goaf to the return road beside the existing seep
  into the pit bottom, so the fan's suction draws a trickle of intake air through the waste. **This
  moves where the blackdamp goes** (some to the return instead of the pit bottom); measured before
  accepting.
- **The runaway is emergent**: with too little air oxidation starves, with too much the air carries
  the heat away, and between them the goaf climbs to `coal_combustion`'s `autoignition_k` (§4).
- **Fire stink**: a prose instrument on the goaf's temperature, observed by whoever is at the face —
  a deputy's nose.
- **Sealing**: an optional effort station that throttles the goaf's leak and seep (stoppings
  built). Seals blowing out stay in the last pass.

**Counterplay.** Seal early; less fan head; stone dusting does nothing for it, which its description
says.

**Specs.** Oxidation warms an insulated goaf with a trickle of air, and not one with none or a gale
(three constructed states, ≤ 20 each, as temperature rise); a goaf constructed past
`autoignition_k` lights (≤ 10); the stink gauge bands the goaf's temperature (0); sealing throttles
the leak (0).

**Risk.** The balance between heating and loss is the most tuning-sensitive thing here. Budget a
sweep, and accept that the first figures are guesses.

---

## 8. Decisions from review

1. **Breath reads the gas phase only** (finding 1) — a fix, not a feature.
2. **Drowning is a depth mark on the sump** (option A), shared with the afterdamp path, and a
   flooded pit bottom closes the ways through it.
3. **Self-ignition as `autoignition_k` in content**, opt-in per reaction, on wood and coal only. It
   is expected to serve beyond this unit.
4. **The Cornish beam is a node of its own, and a power sink on the operation's line shaft** — never
   an outboard or separate engine. Whatever is putting work into that shaft works the pump through
   the beam.
5. **The headframe in parallel with the intake** (option B), not on it.
6. **A reversible fan as a third tier**, its lever negating the head — with the risk in §6 measured
   first.
7. **Outbursts: 0, 1 or 2 per match, at 50% / 45% / 5%**, drawn with the ground, each at a random
   distance into the face and never in the first few metres. Uncertainty is the point. **Goaf falls
   on a schedule drawn at `initial_state`.**
8. **One boring-ahead station** serving both the outburst (drains the next pocket) and inundation
   (observes the survey reading).
9. **Pillar coal in the goaf is fixed, scaled by ground**, not a share of hewing.
10. **One unit with a playtest checkpoint after item 12**, rather than a further split.
11. **Physical thresholds keep their real figures** (raised while building 12): wood ignites at
    573 K, and where the model cannot reach a real threshold its own numbers are what change.
12. **The rope becomes a slot with tiers** — hemp, iron wire, steel wire (§6b) — cheaper ropes being
    likelier to fail. *Its details are open: §6b.*

13. **§6a approved as recommended**: wiped bearings rub metal on metal, generically, with the steam
    engine re-measured; **a seized sheave is a brake on the rope, not a lock on the drum** —
    reversing W3's "seized, it stops the winding"; the headframe reads the sheave as its hot spot.
14. **§6b approved**: rope tiers as blueprints, the rope's weight in its tension, the sheave loaded
    by the rope. Built before 12.
15. **The water behind the face gets the gas pockets' treatment** (§3, revised): 0–2 bodies per match
    at a random depth, never in the first couple of metres, at real scale — 4.7 t of coal a metre,
    depths 2–12 m. Uncertainty is the tension.
16. **Pocket sizes are drawn too, at an accurate size and variance** — a fixed size is a known one.
17. **The gob is inherited, not grown** (item 13, revised in review). A match starts with whatever
    waste the previous workings left: none at all in some pits, and otherwise a heating zone of
    drawn size **already part-way through heating**, with its own rate — so the danger runs from none
    to a fire ready to erupt in fifteen minutes, **weighted heavily to a fire appearing between 45
    minutes and an hour and a half**, with lots of variance. Juggling chronic hazards like this, the
    dust and the roof against the acute ones is the tension.
18. **A lit gob fire is deadly three ways**: smouldering short of air it makes **carbon monoxide**
    (an air-starved pathway on `coal_combustion`, which also gives a choked firebox CO); past a
    temperature it **breaks out** at the face; and it **lights firedamp** — firedamp gains an
    `autoignition_k` (~870 K) read against the waste as the district's hot spot, **reversing
    decision 3's "gas needs a flame"** for this one case.

## As built — where it parted from the design

- **18.** Built as designed. `through:` became a **list**, because every shaft passage already ran
  through `:shaft` and now runs through `Mine::THROUGH_SHAFT` (`%i[shaft pit_bottom]`) as well; the
  main road runs through `:pit_bottom`. `blocks_passage?` gained `content`, which the sump needs to
  tell water from air. Drowned, somebody tires at exactly the rate of air with no breath in it —
  +0.005 fatigue a tick, about 50 s to collapse — which is the afterdamp path unchanged. `ROOF_KG`
  is 14.4 t. The survey reading is `The Plans`, observed by the timberman until item 16's borer
  exists (a named TODO). The gas-phase fix moved no existing spec.
- **11.** Built as decided: `PumpBeam` is a `Rotating` + `Wearing` node drive-linked to the line
  shaft (stiffness 2×10⁴), and the Cornish set's pump is `driven_by: :pump_beam`. Measured on the
  spec rig's supply, the beam runs within 5% of the line shaft and the Cornish set lifts 16.7 kg/s
  against the sinking set's 10.2. **Fatigue alone is slow** — about 28 h at the rig's speed, so in a
  match the beam is broken by a surge, or by a surge it would once have stood once wear has eaten
  its margin; `STROKE_PER_S` is a first guess for the tuning pass. The fall reaches the bank, the
  pit bottom and **the cage's riders only**: a part cannot name the man engine's riders without
  knowing it is fitted (a named TODO). The gauge is `Pump Beam`, read by the banksman.
- **Rope tiers (§6b).** Built as approved, with one restructuring the design did not foresee: **the
  cage's mass and its catches were on the rope**, and the hoist read the cage's mass off it. They
  moved to the hoist (`cage_kg:`, `catches:`), the rope reads them off the drum, and a parted rope
  fails `parted` or `parted_held` by asking the drum — so the rope and winder slots never need to
  know each other. Recapping and re-roping went with the rope. The drum now lifts the ropes'
  imbalance as well as the cage's load.
- **12.** Self-ignition (`autoignition_k` on wood at 573 K, `Vessel#hot_spot`,
  `Ignition.advance(hottest_k:)`). Wiped bearings rub metal on metal at μ 0.35 (a steel journal dry
  on bronze), generically. A seized sheave slips: the groove holds back the capstan figure —
  `e^(0.25·π/2) − 1` of each side's pull — and the drum winds on through it, heating the sheave
  about 0.15 K a tick at a crawl on this line shaft. The headframe is a vessel in parallel with the
  downcast drawing 10% of the intake, on both tiers alike; timber lights off the sheave, burns at
  what its share of air allows (~100 minutes to burn through), and comes down at 30% burnt. The
  reversible fan negates its head and is billed on its magnitude; the gas solve ran reversed without
  complaint (pit bottom 101.9 kPa, district 102.6 — air in by the upcast).

  **Two pre-existing bugs the rope weight exposed**, both fixed: the engineman hunted round the bank
  landing against the ropes' imbalance with full clutch each way — he now holds the cage with the
  brake at the mark — and **a sliding brake capped at `I/dt` could not stop a creeping cage** whose
  load exceeded ~800 N·m, settling at `load ÷ (I/dt)` above the stick speed for ever; it is now capped
  only where it cannot hold the load. The first was found as an overwind in a dry-sheave run, the
  second as a rescuer put off a cage that would not stop at the bottom landing.

  Measured, a dry cage-tier sheave wound on a half duty now reaches ~430 K in 1000 s (459 K with
  the corrected load alone, 372 K before), scoring a hemp rope to 18% of its life on the way —
  which is the warning: the rope goes visibly before the frame does.

- **18, revised.** `Mine::Ahead` draws the bodies at `initial_state` from the fissure's own RNG
  stream (measured over 200 pits: 87 / 107 / 6 for none / one / two). The fissure records
  `barrier_m` each tick, which the plans read; it breaks on `overload?` when the barrier reaches
  zero, drains the body through `drained_kg`, then heals itself — failure cleared and durability
  restored, as a renewed rope is. **The depth range was chosen on a mistaken rate**: the question
  put to review quoted the *winding* rate (2–3.5 kg/s, so 1.5–2.5 m an hour), but the face advances
  at the *hewing* rate, ~0.6 kg/s with hand picks — about half a metre an hour. With hand picks the
  nearest water is four hours or more away; with the cutter it is within a session. Raised for
  review rather than changed.

- **16.** Built on `Mine::Ahead` with the water. **Sizes are drawn too** (review: a fixed size is a
  known one): log-normal on the coal thrown, median 20 t and σ 1.0 in log space, clamped at 2.5σ
  (1.6–245 t); firedamp at 10 m³ a tonne × `ground`; airborne fines 1% of the coal, a guess.
  Measured over 300 pits: none / one / two 141 / 142 / 17; firedamp median 156 kg, 10–90% 38–529 kg,
  tail to 2.5 t — a median pocket puts a 1,400 m³ district in the explosive band, a large one simply
  displaces its air. The gas is held from the start in a `GasPocket` vessel, which keeps the ledger of
  what each pocket has left, spending what the `Outburst` and the `BoreLine` carried as of last tick.
  The outburst is a conduit that fails `outburst` — so its crush hazard, scaled by the coal thrown,
  rides the ordinary failure path — releases at 60 kg/s, and heals once the pocket is spent. **An
  outburst into a candle-lit district fires it at once**, which is Agrappe and which the spec asserts.
  The borer draws a pocket within 4 m at 0.25 kg/s into the district and is the observer of both the
  bore holes and the plans, so a pit with nobody boring sees neither. The coal an outburst throws is
  not moved out of the seam — only its gas and fines — so the crush is the coal's whole effect.
- **17.** Built as designed, with **spans log-normal** in the same spirit as the pockets: the first
  weighting median 6 m, later falls median 3 m, σ 0.4 (measured over 200 pits: first 2.2–16.3 m,
  later 1.1–8.2 m). Twelve are drawn, more than a district's 19 m can use. The goaf
  (`OldWorkings`) owns it all: `hanging_m` is metres won since the last fall less `packed_m`; past
  the next span it fails `fell` (the windblast rides the failure path, scaled by what hung), and on
  the next tick resets, drops the span and flushes for 20 s — `GoafSeep` passing 150× its make — then
  heals. Packing fills about half what a hewer wins. The timberman hears the goaf working
  (`The Goaf`), banded on how near the span it is.

- **13.** Built as revised in review (decisions 17–18). **A waste of its own** (`Mine::Gob`, "The
  Waste") rather than the old workings: the goaf is a 20 t blackdamp reservoir at about six
  atmospheres, which air could never trickle into without moving every blackdamp figure, so the
  heating waste is a separate vessel on a trickle from the pit bottom to the face — and its smoke and
  CO come out where people are, not up an airway nobody breathes. **It is inherited**: 25% of pits
  nothing; otherwise a zone of log-normal coal (median 3 t) whose start temperature is solved, by
  Newton's law of cooling against a design heat, to fire at a log-normal time (median 65 min, σ 0.4,
  never under 15 min). A heating waste starts **oxygen-depleted** — little air, the rest blackdamp —
  because a full charge of fresh air burnt in its first minutes put 90–250 K on the zone at once and
  fired it five times early. The design heat was then **calibrated off running pits** (70 kW assumed,
  ~35 kW measured). **Revised after the playtest**: the waste kept its cold gas charge at its hot
  start temperature — 2.3 atmospheres at 670 K — and blew 200 kg of hot gas into the roads in its
  first minute, which is what burnt the district. It now starts at the roads' pressure, holding less
  gas the hotter it is, on the 18 kg of air the trickle settles to and the 50 kW it then makes;
  seven draws fire within 12% of their drawn time. Self-heating needs no Arrhenius term: with a temperature-independent rate the
  window is still emergent — too little air starves it, too much carries its heat away. Alight, it
  smoulders on `coal_combustion`'s new air-starved pathway to whitedamp; past 1000 K it **breaks
  out** (an immediate overload, burning the district); past 870 K it fires the district's gas through
  the district's `hot_spot: :gob`. Sealing builds stoppings at about two hours' work; a fully sealed
  leak keeps a hair of conductance, because a zero drops the path out of the pressure-driven regime
  and it then passes its port's whole rating.

  **The CO pathway is on `coal_combustion` itself, grate included.** It moved two engine specs; at
  steady working the engine is identical with or without it (1010 K, 608 kPa, 160 rpm, 455 kW, no
  CO), and it bites only on an over-fed bed — so the engine rig's fire bed, which had been seeded
  at 2.9 kg of coal against a running engine's 0.46, was retaken from the running engine (review:
  fit the specs to the physics, never the physics to the specs).

## 9. Small leftovers from 3a that fit here

Optional, each small; recommended only where they touch an item above.

- **A hand-carried Davy lamp failing in a draught** — the hand-flame path reading the district's
  `draught_m_s`. Fits with 12 (the reversible fan changes the draught). Recommended.
- **A trapper who slips leaving the door open** — needs the door to see the slip, not just the worked
  lever. Not recommended here; it belongs with the last pass's stoppings.
- **A self-closing door jamming** — a mishap with no person behind it. Same.

## 10. Documentation owed when 3b lands

`reference/physics.md` and `physics/CLAUDE.md` (self-ignition); `content/CLAUDE.md` and
`guides/add-content.md` (`autoignition_k`, `coal_oxidation`); `reference/nodes.md` and
`nodes/CLAUDE.md` if any node lands under `nodes/`; `lib/reactor_sim/CLAUDE.md` (Breath on the gas
phase, drowning); `reference/tick.md` (breathability); `reference/diagnostics.md` (the survey
reading, beam condition, fire stink); `operations/CLAUDE.md` and the build guide (headframe slot,
the stations); `spec/CLAUDE.md`; `current_progress.md`.
