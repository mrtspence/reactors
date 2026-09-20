# The Mine — research, shape, and the releases it needs

Input to design. Not a description of anything that exists.

## Why

Reactor has one working operation: a steam engine producing ~0.5 MW. The premise of the game is
that operations chain — one player makes power, another consumes it and makes something else. The
premise is currently asserted rather than demonstrated, because there is only one operation and
nothing crosses between operations at all.

Operation two is a mine, roughly period-accurate to c. 1780–1930 with wide bars either side for
upgrades. Three requirements shape it:

1. **It must consume power**, so the engine has a customer.
2. **It must be big enough to force a real spatial and minion-movement system.** Minion positions
   are arbitrary today. Mines historically spent enormous capital on moving *people* — man engines,
   cages, man-riding trains — precisely because distance underground is expensive. That machinery
   is both the power sink and the reason position has to become real.
3. It must chain outward, so there is something for a third player to do.

[`current_progress.md`](../current_progress.md) records all four pre-mine blockers as closed (crew
capacity, driven transport, registry introspection, `DevMatch`'s operation axis) and names the one
open question as exactly this document's subject: *whether getting people to the face needs real
distance.* It does. Part 4 says how.

---

# Part 1 — Research

## 1.1 A mine is five machines wrapped around a hole

Every underground mine in this period, regardless of what it is digging, is the same five
subsystems fighting each other over one shared space. This is the key structural insight, because
it maps almost directly onto a node graph.

| Subsystem | The job | Fails as |
|---|---|---|
| **Winning** | Break rock/coal off the face | Output stops |
| **Haulage** | Move broken material face → shaft | Faces choke, men idle |
| **Hoisting** | Move material *and men* shaft → surface | Everything stops; men trapped |
| **Drainage** | Keep water out | Mine drowns, slowly then instantly |
| **Ventilation** | Push fresh air in, foul air out | Men die; gas explodes |

Plus **dressing** on the surface (crushing, washing, sorting, screening), which turns run-of-mine
material into a saleable product and is the natural hand-off point to a downstream operation.

The critical tension, and the one that makes a mine a *game*: **all five compete for the same
shaft, the same roadways, and the same power.** You cannot wind men and wind coal at the same time.
The airway you need for ventilation is the roadway you want for haulage. The pump you switch off to
power the winder is the pump holding back the water.

## 1.2 Taxonomy — how mines are shaped

### By access

| Type | Description | Period | Depth | Needs power? |
|---|---|---|---|---|
| **Bell pit** | Shaft sunk to a shallow seam, worked outward until the roof threatens, abandoned, next shaft sunk beside it. Windlass and basket. | Medieval–c.1800 | 10–30 m | No |
| **Drift / adit mine** | Horizontal tunnel driven into a hillside on the seam. Self-draining by gravity. | All periods | n/a | Minimal |
| **Slope / slant** | Inclined roadway following the seam down from outcrop. Rope haulage up the slope. | 19th c.+ | 50–300 m | Yes (haulage) |
| **Shaft mine** | Vertical shaft(s), cage or skip winding. The classic deep mine. | c.1700–present | 100–1000 m+ | **Yes, heavily** |
| **Opencast / quarry** | Surface removal. | All | n/a | Some |
| **Placer / hydraulic** | Washing alluvial gravels with water jets. | 19th c. gold rushes | n/a | Water, not power |

### By deposit geometry — this determines the shape of the underground space

- **Stratiform / bedded** (coal, ironstone, salt, some slate). The deposit is a **layer**, often
  only 0.6–2 m thick, extending for kilometres. The mine is therefore **essentially
  two-dimensional**: a planar graph of roadways at one or two levels. By far the easiest geometry
  to model.
- **Lode / vein** (tin, copper, lead, gold). The deposit is a near-vertical **sheet**. The mine is
  a stack of horizontal *levels* every 10–20 fathoms, connected by shaft, winzes and raises, with
  irregular *stopes* eaten out between them. **Genuinely three-dimensional and irregular.**
- **Massive / disseminated** (large porphyry bodies). Block caving, sublevel caving. 20th century.

### By extraction method

**Bedded deposits:**

- **Bord-and-pillar** (room-and-pillar, stall-and-pillar). Roadways driven at right angles through
  the seam, leaving a regular grid of coal pillars to hold the roof. From the 17th century; the
  default in Britain's north-east and in the US into the 20th century. Recovery only ~40–60% on
  first working; the pillars may later be "robbed" on retreat, which is the most dangerous work in
  the pit. **Geometrically a grid.**
- **Longwall.** A single continuous face, 50–200 m long, advanced in one line. The roof behind is
  allowed to collapse into the *goaf*, controlled by stone *packs*. Documented by John Farey in
  1811 as a three-shift cycle: *holers* undercut the seam with picks and prop it; *hammermen* drive
  wedges to bring the coal down; *timberers* re-set supports for the next cycle. Near-total
  recovery, and it requires continuous disciplined coordination.
- **Pillar extraction / retreat.** Taking the pillars out on the way back, pulling props with a
  ratchet device (a *sylvester*) and letting the roof come down behind you.

**Lode deposits (stoping methods):**

- **Underhand stoping** — work downward. Dominant before power drills, since hand tools struck
  downward have mechanical advantage.
- **Overhand stoping** — work upward. Dominant after blasting and power drills; broken ore falls to
  the level below by gravity through *ore chutes*.
- **Stull stoping** — timbers ("stulls") wedged between footwall and hanging wall. Used to 3,500 ft.
- **Square-set stoping** — interlocking timber cubes filling the void. Invented by Philipp
  Deidesheimer at the Comstock Lode in 1860 to hold ground too broken for any other method. Let
  miners open cavities of arbitrary size. Consumed forests.
- **Shrinkage stoping** — for steeply dipping ore (70–90°). Work upward standing on your own broken
  ore; draw off ~40% as you go because broken rock swells, and empty the stope at the end.
- **Cut-and-fill** — mine a slice, backfill it, stand on the fill, mine the next slice.

## 1.3 The tech tree, by subsystem

This is the upgrade path. Each row is roughly a tier.

### Winning the material

| Tier | Technology | Date | Notes |
|---|---|---|---|
| 0 | Pick, wedge, hammer, fire-setting | ancient | A hewer wins a few tonnes a shift |
| 1 | Hand drilling — single-jacking (one man, hammer + drill steel), double-jacking (one holds, one strikes) | 18th c. | 6–8 inch holes; a Levant hole 20 in deep took ~2 hours |
| 2 | **Black powder** blasting | c.1620s, widespread 18th c. | Slow, heaving explosive; good for coal, poor for hard rock |
| 3 | **Bickford safety fuse** | 1831 | Jute-wrapped powder core, burns 1 in / 30 s. The first *predictable* ignition. Cornwall |
| 4 | **Nitroglycerin → dynamite** (Nobel) | 1866–67 | ~5× black powder by weight; 1 lb ≈ 2⅔ lb powder. Replaced powder in hard rock by mid-1870s |
| 5 | **Pneumatic rock drills** — ideas from the 1840s, workable from the 1860s; Mont Cenis Tunnel 1861; US mines from the 1870s (Burleigh, then Ingersoll-Sergeant) | 1860s–70s | Needs a **compressed-air plant** — a major new power sink |
| 6 | **Coal cutters** — Gillott & Copley rail-mounted disc cutter (compressed air); Ingersoll pneumatic punching machine c.1880; electric chain cutters (Sullivan, Jeffrey) from 1900 | 1868–1900 | Undercuts the seam so it breaks down under its own weight |
| 7 | Electric shearers, armoured face conveyors | post-1947 | Out of period, but the natural top of the tree |

Note the *dust* consequence: dry machine drilling late in the 19th century produced the worst
silicosis exposure in mining history. Water-fed drills were the fix.

### Moving material underground

| Tier | Technology | Date |
|---|---|---|
| 0 | Men and children dragging *corves* (wicker baskets) on sledges; *hurriers* harnessed to tubs | |
| 1 | Wooden rails and wheeled tubs; **John Curr's flanged cast-iron rails** | 1787 |
| 2 | **Pit ponies** — widespread after the 1842 Act barred women and boys under 10 underground. Under 1.4 m at the shoulder. Driven by *pony putters* | 1840s–1960s |
| 3 | **Self-acting inclines** — the loaded set descending hauls the empty set up, controlled by a brake wheel (jig pulley) and strap brake. Free energy from gravity | 19th c. |
| 4 | **Rope haulage** — *direct*, *main-and-tail* (one rope each way on a single track), and *endless rope* (a continuous loop over two parallel tracks with a tension bogey, tubs clipped on by *clippers*). Driven by a stationary engine | mid-19th c. |
| 5 | **Electric / battery locomotives** | 1887+ |
| 6 | Conveyors | 20th c. |

### Hoisting — material *and* men

The subsystem this design cares most about.

| Tier | Technology | Date | Men? |
|---|---|---|---|
| 0 | Hand windlass and basket | ancient | Climb ladders |
| 1 | **Horse whim / whim gin** — horse walks a circle turning a vertical-axle drum; rope over head pulleys raises a *kibble* as the other end lowers. One horse ≈ 250–400 lb from 60–90 m at ~0.5 m/s | 17th c.+ | No |
| 2 | Water-wheel winding | 18th c. | No |
| 3 | **Steam whim / winding engine** | late 18th c.+ | Eventually |
| 4 | **Wire rope** (Albert, Germany) replacing hemp and chain | 1834 | Enables real depth |
| 5 | **Man engine** — a reciprocating rod down the shaft with foot-platforms at stroke spacing and fixed *sollars* in the shaft wall. You step on, ride 12 ft, step off, wait, step on again. German Harz mines 1830s (water-driven); **Tresavean, Cornwall, 1842**; United Mines 1845; **Levant 1857** (Daubuz Shaft to the 170-fathom level). Strokes 12–15 ft, 2–8 s pause at reversal, depths beyond 350 fathoms (640 m) with counterweights in side galleries. **At Tresavean it cut the journey from ~1 hour to 24 minutes and raised output per shift by a fifth** | 1833–1919 | **Yes — this is the point** |
| 6 | **Cage winding** — a guided iron cage carrying men and tubs. Needs guides, a *banksman* at the top, an *onsetter* at the bottom, and a signalling code | mid-19th c.+ | Yes |
| 7 | **Safety gear** — cage safety catches; the **detaching hook** ("butterfly") which releases the rope and locks the cage into the headgear on an overwind; headframe catchgear to stop the fall-back | 19th c. | |
| 8 | **Koepe / friction winding**; skip winding for mineral with a separate man-riding shaft | late 19th c.+ | |
| 9 | Man-riding trains, man-riding conveyors | 20th c. | |

**Winding is a cycle, not a flow.** A wind takes 50–90 seconds. Every wind is *either* men *or*
mineral. Victorian records: 120 tons/hr at 2 tons per wind; a 90-second cycle in 1875; double-decked
cages doing the shaft in 50 s for a maximum 300 tons/hr. A pit raising 1,600 t/day was a large one.
Shift change therefore monopolises the shaft for a long block at each end of the day — which is
exactly why the man engine, and later the separate man-riding shaft, were worth their enormous cost.

### Drainage

| Tier | Technology | Date |
|---|---|---|
| 0 | Buckets on the winding rope | |
| 1 | **Adits / soughs** — a gently sloping tunnel driven from the lowest convenient valley point, draining the mine by gravity forever, for free. Cornwall from c.1700. The **Great County Adit** (begun 1748) eventually drained 100+ mines to 80–100 m depth over 65 km of tunnel, discharging ~66 million litres/day by 1839. **Everything above adit level is free; everything below must be pumped** | 1700+ |
| 2 | Rag-and-chain pumps driven by water wheels | 17th c. |
| 3 | **Newcomen atmospheric engine** — the first machine that let mines go deeper than water allowed | 1712 |
| 4 | **Watt separate condenser** | 1776 |
| 5 | **Cornish beam pumping engine** (Trevithick, high pressure, from c.1812) — the defining Cornish machine; cylinders 45"–90"+. Levant's pumping engine had a 45-inch cylinder | 1812+ |
| 6 | Electric centrifugal pumps — first electric motor pump on a coal mine, 1883, at 1½ hp. By 1900, banks of ~30 hp motors at 300 gal/min each | 1883+ |

### Ventilation

| Tier | Technology | Date |
|---|---|---|
| 0 | Natural ventilation — a temperature/density difference between two shafts | |
| 1 | **Furnace ventilation** — a fire at the bottom of the *upcast* shaft makes it a chimney and draws fresh air down the *downcast*. Cheap, but needs constant fuel and supervision, and you are running an open fire in a gassy mine | 18th–19th c. |
| 2 | **Coursing the air** — the air is not a cloud, it is a *circuit*. Controlled by **stoppings** (walls), **doors** (opened by child *trappers* before 1842), **regulators** (adjustable apertures on doors), **airlocks**, **overcasts** (air bridges letting intake cross return without mixing), and **brattice** (tarred air-tight cloth partitions, used to carry air up a blind heading) | 18th c.+ |
| 3 | **Panel working / splitting the air** — dividing the mine into separately ventilated districts so one district's foul air is not another's intake, and so an explosion is contained | 19th c. |
| 4 | **Mechanical fans** — Struve, then **Guibal (patented 1862)**, which dominated: a tight spiral casing with an adjustable discharge shutter plus an *evasée* chimney recovering velocity head as static pressure. A 46 ft Guibal of 1872 delivered 314,000 cfm at 2.8 in w.g. at 48 rpm. **Waddle fans** (from the 1860s) ran open with no casing — cheaper, less efficient. Later: Capell, Walker "Indestructible", **Sirocco** (1910, 175 hp electric motor) | 1849–1930 |
| 5 | Auxiliary fans and ducting for blind headings | 20th c. |

**The Hartley Colliery disaster of 1862 is the forcing event.** A single-shaft pit; the beam of the
pumping engine broke, fell down the only shaft, and sealed 204 men and boys underground to
suffocate. The resulting law required **two shafts** and drove the move from furnaces to fans.

### Lighting and gas detection — "narrow controls and imperfect instruments"

| Tier | Technology | Date |
|---|---|---|
| 0 | Candles, open flame. Explosions frequent | |
| 1 | Steel mill (a flint wheel throwing sparks) — a superstition that did not work | |
| 2 | **Davy lamp** — flame enclosed in wire gauze; the gauze conducts heat away so the flame cannot pass out. **Geordie lamp** (Stephenson), same year, different principle | 1815 |
| 3 | The **flame cap**: the *height of the blue cap* above the flame in a safety lamp is the gas reading. That is the instrument. A deputy or *fireboss* reads percentage methane off the length of a flicker in the dark, and everyone's life depends on his estimate | 19th c. |
| 4 | Bonneted and locked lamps; the *yardstick* used to raise the lamp into the roof cavity where gas accumulates | 19th c. |
| 5 | Electric cap lamps | 1900s+ |
| 6 | **Canaries** — carried by rescue teams with a flame lamp; collapse before humans in carbon monoxide | 1896+ |
| 7 | Methanometers | 20th c. |

### Ground support

Wooden **props** and **puncheons**; **chocks** (cribbed timber); **bars**; **packs** of stone built
in the goaf; **arches** (steel, 20th c.); **cast-iron supports** patented by John Charleton, 1802;
**stulls** and **square sets** in lode mines. The nemesis: a **bell** — a loose, roughly bell-shaped
stone in the roof which falls without warning, and which killed more miners than every explosion
combined. Slower killers: **creep** (soft floor bubbling up), **heave** (roadway floor lifting),
**squeeze/weight** (strata settling over worked-out ground, slowly closing the roadway).

### Surface / dressing

Coal: **screens** (sizing), picking tables worked by **pit brow lasses**, washeries.

Tin and copper (Cornwall): **stamps** (water- or steam-driven hammers crushing ore with water) →
**buddles** (circular sloping floors where flowing water and gravity separate heavy ore from light
*gangue*) → **jigging** (sieving) → **calciner** (roasting to drive off arsenic; the Brunton
pattern, mid-19th c., was mechanical and continuous, and the arsenic was itself saleable). At least
55,000 women and girls — **bal maidens** — worked this surface plant.

## 1.4 The anatomy of the underground space

Vocabulary worth reusing as node and link names.

**Coal (bedded):**
`shaft` (downcast / upcast) · `inset` (an opening part-way down giving access to an intermediate
seam) · `pit bottom` · `roadway` / `heading` (a roadway being driven) · `level` (a road at right
angles to the dip) · `drift` (a road between seams) · `maingate` (intake + conveyor) · `tailgate`
(return air) · `return` · `airway` · `overcast` · `district` (a named area of face) · `panel` ·
`face` · `goaf`/`gob`/`waste` (the collapsed void behind) · `pass-bye` (a tub siding) · `sump` (the
water collection point below the shaft bottom) · `jenkin` (a narrow cut through a pillar)

**Lode (3-D):**
`shaft` · `station` (the landing where a level meets the shaft) · `level` (every 10–20 fathoms) ·
`drift` (a level driven *along* the vein) · `crosscut` (driven *across* to reach it) · `winze` (a
shaft sunk between levels, no winding gear, ladder access) · `raise` (the same driven upward) ·
`ore pass` (a winze dedicated to gravity ore transfer) · `stope` (the irregular void where ore was
taken) · `ore chute` (draws broken ore from a stope down into a drift) · `sollar` (a fixed platform
in a shaft)

## 1.5 Labour — the minion layer

This period's mine is a hierarchy of *named jobs, each tied to a place*. Useful: the historical job
titles already encode the position binding the sim needs.

**Underground, at the face:** *hewer* / *collier* (wins the coal, usually paid by the tub) · *holer*
(undercuts) · *timberman* (sets props) · *ripper* (takes down roof rock to raise roadway height) ·
*shotfirer* (the only person permitted to fire a charge) · *putter* / *drawer* / *hurrier* (moves
tubs face → road)

**Underground, on the roads:** *pony driver* · *clipper* and *jigger* (attach tubs to the endless
rope) · *trapper* (a child sitting alone in the dark opening a ventilation door — abolished 1842) ·
*haulage engineman*

**Underground, supervisory:** *deputy* / *fireman* / *fireboss* (inspects his district for gas and
bad roof before the shift enters — the safety-critical role) · *overman* (foreman over deputies)

**At the shaft:** *onsetter* (pit bottom — sole control of what enters the cage) · *banksman* (pit
top — signals the winder, controls loading, collects tallies, searches every man for contraband:
matches, pipes, cigarettes)

**Surface:** *winding engineman* (moves only on an unambiguous signal from *both* banksman and
onsetter) · *lampman* (issues and maintains the lamps; the tally/lamp check is the roll-call that
tells you who is still underground) · *pit brow lasses* / *bal maidens* (screens and dressing
floors) · *manager* (certificated after 1872) · *agent* / *mine captain*

**Payment and contracting:** the Cornish **tribute** (bid for a share of the *value* of the ore you
raise — a gamble on the ground you are given) and **tutwork** (paid by the fathom for development
work that produces nothing saleable). The English **butty** / **charter master** system: a
contractor takes a seam at a price per ton and hires his own men. Noted for later — they make crew
assignment a wager.

## 1.6 The hazard catalogue

Where the drama is, and mining history is unusually well documented on exactly *how* each one kills.

### Gas — "the damps"

| Damp | Composition | Behaviour |
|---|---|---|
| **Firedamp** | mostly methane | Lighter than air — collects in roof cavities and rising headings. Explosive ~5–15%. Detected by the flame cap |
| **Blackdamp** / chokedamp / *stythe* | nitrogen + CO₂, i.e. air with the oxygen removed | Heavier than air — collects in dips and sumps and old workings. Silently asphyxiates. Puts a flame lamp out, which is the warning |
| **Whitedamp** | carbon monoxide, from incomplete combustion | Toxic at trace concentrations, odourless. Canaries were carried against this |
| **Stinkdamp** | hydrogen sulphide | Lethal quickly, but you can smell it — until it deadens your sense of smell |
| **Afterdamp** | what fills the mine *after* an explosion: blackdamp and whitedamp mixed | **Kills more people than the explosion did.** The survivors of the blast suffocate |

A **blower** is a fissure venting firedamp under pressure, often audibly. An **outburst** is a sudden
violent release of gas and coal from the face, sometimes preceded by a **bump** — a sound in the
strata.

### Coal dust — the mechanism that turns an accident into a catastrophe

The critical 19th-century discovery. A small local firedamp ignition raises fine coal dust off the
floor and roadway ledges *ahead of its own pressure wave*, and that dust then burns, raising more
dust further on. The result propagates through the **entire mine** at speed.

- **Courrières, France, 1906 — 1,099 dead.** Europe's worst. Initial ignition never determined.
- **Senghenydd, Wales, 1913 — 439 dead.** Britain's worst. Probably a spark from underground
  signalling gear igniting firedamp, then dust.

The fix, found after Senghenydd, was **stone dusting**: spreading inert limestone dust so the
airborne mixture cannot sustain combustion. A satisfying tech-tree entry — an expensive, boring,
invisible measure that does nothing at all until the day it saves everyone.

### Water

**Inundation** — breaking into flooded old workings, a water-bearing stratum, or in the worst cases
the sea or a river above. Water arrives at the face faster than men can walk out of a dipping road.
Historic cases include Diglake (1895) and the Knox disaster (1959), where the Susquehanna River
broke through a roof left too thin. The related slow failure: the pumps stop — a broken rod, a power
cut, a flooded pump station — and the mine drowns from the bottom up over hours or days.

### Ground

Roof falls — the steady, unspectacular majority of deaths. The **bell** stone. Pillar failure and
crush during pillar robbing. Floor heave closing a roadway. Shaft-lining collapse.

### The shaft

Overwind (the cage driven into the headgear). Rope failure. Men falling down the shaft. Objects
dropped down the shaft onto men below. Cage crashing. And the Hartley case: the shaft itself
blocked, with no second way out. **The man engine had its own version — Levant, 20 October 1919: a
metal bracket at the top of the rod failed, the whole rod and its timbers fell down the shaft, and
31 men died. The mine never replaced it and abandoned its lower levels.**

### Fire

Spontaneous combustion in the goaf. Timber fires. Conveyor-belt fires (later). A fire underground is
worse than one on the surface because the ventilation you rely on to live is also what feeds it and
distributes its smoke.

### Slow deaths

**Silicosis / miners' phthisis** (rock dust, worst from dry machine drilling; South Africa's Milner
Commission 1902 and Miners' Phthisis Act 1910). **Pneumoconiosis** (coal dust). **Nystagmus** (from
working years by a feeble lamp). **Ankylostomiasis** — hookworm, "miners' worm", from warm wet
workings. **Heat**: Levant's workings ran at ~92 °F (33 °C), and *"few are able to work underground
after the age of 35."* The Comstock was far worse — water at 108 °F, and scalding steam breaking
into the workings.

### Rescue

**First rescue station: Tankersley, West Yorkshire, 1902.** Garforth's training *gallery* concept,
1899. **Draeger** apparatus (US from 1907), **Siebe Gorman Proto** rebreather (early 1900s). US
Bureau of Mines founded 1910 with railway-car mobile rescue stations. Rescue teams go in with a
flame lamp and a canary, and the limit on how far they can go is the duration of the apparatus.

## 1.7 Calibration numbers

For sizing the operation against the existing ~0.5 MW steam engine.

**Power draws (c. 1900–1914):**

| Machine | Power |
|---|---|
| Ventilation fan engine | 74 hp relaxed / 203 hp nominal / 432 hp hard (≈55 / 150 / 320 kW). 1910 Sirocco: 175 hp electric (130 kW) |
| Centrifugal pump bank | ~30 hp (22 kW) per pump at 300 gal/min; several per station |
| Cornish beam pumping engine | 45–90 inch cylinder; hundreds of hp |
| Winding engine | Highly peaky — large draw for ~30 s, then nothing. Levant's engine house held six beam engines: 45" pump, 30" stamps, 26" whim, 24" man engine, 18" crusher, 14" winding |
| Compressed-air plant for drills | Large, continuous, very lossy |
| First electric mine pump, 1883 | 1.5 hp |

**A medium colliery's total load lands convincingly near 0.5 MW** — fan 130 kW + pumps 100 kW +
haulage 100 kW + winder averaging 150 kW. One steam engine ≈ one mine.

**Production and scale:**

- Victorian large colliery: 1,200–1,800 tons/day; records to 2,730 t
- Winding: 2 t per wind, 90 s cycle → 80–120 t/hr; double-deck cages 50 s → 300 t/hr
- Shaft depths: 150–400+ yards typical for British coal; Levant ~600 m
- Levant workings: passages 7 ft high × 3–4 ft wide; lodes 6 in to 3 ft wide
- Levant workforce 1883: ~366 men, boys and girls; three 8-hour shifts; **50–60 men underground per
  shift**. Peak 724 in 1901
- A hand hewer: a few tonnes per shift. A mechanised face post-1947: hundreds to thousands
- German average mine output: 8,500 short tons / 64 workers (1850) → 280,000 tons / 1,400 workers
  (1900)
- Fatality rates, France 1885: ~175 injuries and ~2 deaths per 1,000 workers per year — *before*
  counting the disasters

---

# Part 2 — Candidate shapes, and why they were rejected

Evaluated against: does it consume power; does it force spatial and minion movement; how hard is it
to build on what exists; does it chain outward.

### A. Bell pit / shallow drift

**Pros.** Trivially simple. Would ship in a week.
**Cons.** No power consumption at all — a windlass and a basket. No meaningful space: one shaft, one
chamber. No ventilation problem worth solving. No chaining. **Fails both hard requirements.**
**No** — but worth keeping as the tutorial, or as the "before" state in the tech tree.

### B. Drift / adit mine on a bedded deposit (ironstone, shallow coal)

**Pros.** Self-draining, so drainage is free and a whole subsystem disappears. Horizontal, so
movement is a simple linear graph. Rope haulage up the drift gives one real power sink.
**Cons.** No shaft means **no man-hoisting problem**, which is exactly the mechanic wanted.
Ventilation is easier. Too few tensions.
**No** — it removes the interesting parts.

### C. Single-seam shaft colliery, bord-and-pillar, fan-ventilated (c. 1870–1910) ★ **chosen**

See Part 3.

### D. Longwall colliery

**Pros.** Everything in C, plus near-total recovery, plus the goaf and its packs, plus a face-advance
cycle that forces tight three-shift coordination.
**Cons.** Strictly harder than C in every dimension — the face is a moving line, roof control is
continuous, the goaf is an active volume. Building it first would mean designing the spatial system
around the hardest case.
**Not first** — the obvious second coal variant. Plan the spatial model so it can accept this later.

### E. Deep Cornish lode mine — tin/copper (c. 1840–1880)

Levant, Dolcoath, Tresavean. Vertical shaft, man engine, levels every 10–20 fathoms, stopes, beam
pumping engine, stamps and dressing floors on the surface.

**Pros.**
- **The man engine is the single best fit for the movement mechanic.** A machine whose *entire
  purpose* is moving people, which consumes real power, whose economics are documented (Tresavean:
  1 hour → 24 minutes, +20% output per shift), and whose catastrophic failure (Levant 1919) is one
  of the most vivid accidents in mining history.
- **Pumping is the dominant load and the existential threat.** A Cornish mine is a machine for
  holding back water; it drowns the moment it stops paying for that. The adit line is a gorgeous
  binary: above it free, below it you pump forever.
- **Ore dressing chains beautifully.** Stamps → buddles → jigs → calciner → smelter. Grades and
  recovery rates give a rich product spec, plus arsenic as a by-product. Tribute and tutwork give
  crew assignment real texture.
- Heat as a working constraint (33 °C, "few work underground after 35") ties directly into the
  minion competence model.

**Cons.**
- **The geometry is genuinely three-dimensional and irregular.** Stopes are voids of arbitrary shape
  between levels, connected by winzes, raises and ore chutes. Solving the hard version of the
  spatial problem on day one.
- Timbering (stulls, square sets) is a whole structural sub-model.
- No firedamp, so the signature hazard is missing.
- Ore grade and metallurgical recovery is a second new model on top of the spatial one.

**The best thematic fit and the wrong first build.** Strong candidate for operation 3 or a mine
variant — and the man engine belongs in the coal mine's tech tree regardless.

### F. Comstock-style deep silver/gold mine

**Pros.** Maximum drama: square sets, 108 °F water, the Sutro drainage tunnel, Burleigh drills.
**Cons.** Every con of E amplified, plus geothermal heat as a first-class physics problem.
**No** — but a superb late-game variant.

### G. Slate mine / quarry

**Pros.** Water-balance hoists and powered inclines are lovely machines; mills are a clean power
sink; low gas risk.
**Cons.** Weak ventilation and drainage drama, a product with no obvious downstream consumer, and
chambers that are large and few — less movement pressure.
**No.**

---

# Part 3 — The shape

## A single-seam, bord-and-pillar shaft colliery, in its fan-ventilated era (c. 1870–1910).

Starting configuration:

- **Two shafts** — a downcast winding shaft with a cage, and an upcast ventilation shaft. Two, not
  one, because post-Hartley that is the law and because it makes the ventilation circuit a *circuit*.
- **One seam**, one pit bottom, **three or four districts** of bord-and-pillar workings reached by
  roadways of meaningful length.
- **A mechanical fan** on the upcast — a Guibal or Waddle. Constant load. Never stops.
- **A sump below the pit bottom and a pump station.** Water seeps in continuously and runs downhill;
  the pump is the only way out.
- **Cage winding** with a real cycle time and a real capacity, carrying men *or* tubs, never both.
- **Rope or pony haulage** on the main roads, hand putting at the faces.
- **Hewers at the faces**, deputies inspecting districts, an onsetter and a banksman at the shaft.
- **Safety lamps** as the gas instrument.

### Why this one

1. **It is the only candidate whose power demand has *shape*.** Base load that must never fail (the
   fan), deferrable load that accumulates debt (the pumps), and a violent peak the player triggers
   deliberately (the winder). The upstream engine player gets a customer who is genuinely hard to
   serve rather than a constant resistor.
2. **It forces the spatial system at the right difficulty.** A planar roadway graph is the simplest
   thing that can possibly work, and it is not a toy: travel time to a far district is a real cost,
   the cage is a real bottleneck, and the hoisting tech tree (ladders → cage → bigger cage → man
   engine → second shaft → man-riding haulage) is a ladder of power purchases that each buy back
   minutes of minion time. The movement system will not have to be thrown away for a 3-D lode mine.
3. **One graph carries four flows.** Men, material, air and water all move over the same roadway
   topology. Building the spatial abstraction once buys ventilation and drainage nearly free, and
   every one of those flows is a conservation-ledger citizen. The highest reuse-per-new-concept of
   any option.
4. **The instrument fiction writes itself.** "Narrow controls and imperfect instruments" *is* the
   Davy lamp: a number inferred from the height of a flame, reported by a minion of variable
   competence, from one point in a district, some minutes ago. No other operation has such an exact
   historical match to the game's own thesis.
5. **Coal chains outward.** The engine sells power to the mine; the mine sells coal onward to a
   third operation (gasworks, coke ovens, an ironworks). **Deliberately not back into the engine** —
   a two-node loop that sustains itself is a system with no reason for a third player, and it makes
   balance a question of loop gain rather than of skill. The chain is a chain, not a ring.

### Consciously deferred

- Longwall (variant 2), the goaf, and packs.
- Lode mines, stopes, winzes, ore grade and dressing (operation 3, or a mine variant).
- Coal cutters, electric haulage, stone dusting, rescue apparatus — all upgrades on this base.
- Multiple seams and insets — the spatial model should permit them; the first build need not use
  them.

### Risks

- **The gas model is the schedule risk.** Firedamp emission, accumulation, dilution and ignition is
  the one genuinely new piece of physics. It wants its own design pass, and v1 should keep it
  deliberately simple — a per-face emission rate, accumulation in a district, dilution by the
  airflow the ventilation solve already gives, an ignition threshold — with dust propagation held
  back for v2.
- **The coupling is genuinely new architecture.** See §4.1.
- **Don't let the mine become a spreadsheet.** What makes it a game is that you cannot see it — you
  have a plan, some gauges, some reports from minions, and a lot of dark.

---

# Part 4 — Implementation shape

Three decisions taken alongside the shape above:

- **Power arrives as an imported shaft node** — a real rotating body inside the mine, not a resource
  on a ledger.
- **Coal goes outward to a third operation**, never back into the engine.
- **Space is modelled as volume nodes on the existing graph** — the full commitment described in
  [`minion-sketch.md`](minion-sketch.md), not an abstract place graph beside it.

## 4.0 What the mine inherits for free

Far more than expected, and this is the argument for the shape above — almost none of it needs
inventing.

| Need | Already exists | Where |
|---|---|---|
| Assembly, slots, parts, outfitting screen, verdicts | The whole layer is generic | [`assembly.rb`](../../lib/reactor_sim/assembly.rb), `slot.rb`, `part.rb`, `parts.rb` |
| Crew capacity and a shift origin | Found by **what a slot accepts** (`:crew_quarters`), explicitly so a mine need not reimplement either | `assembly.rb` |
| A place that is not a lever | `ControlPoint#lever?` is false with no `node:`; `Operation#panel` already ships `stations` separately from `controls` | [`control_point.rb`](../../lib/reactor_sim/control_point.rb) |
| Effort stations, fatigue, spent | `effort:` / `aided_by:` / `exertion:`, phase 6c | `control_point.rb`, `fatigue.rb` |
| Injuries from a failing part, by station | `endangers:` → phase 6b Danger Check | `concerns/wearing.rb`, `injury.rb`, `tick.rb` |
| **Shaft work buys flow** — a pump or fan driven by a shaft | `Conduit` takes `driven_by:`, `lift_m:`, `efficiency:`, `rated_omega:`, `delivers_to:` | [`nodes/conduit.rb`](../../lib/reactor_sim/nodes/conduit.rb) |
| The productive mass exit | `mass_delivered` — *"water lifted out of a mine, ore sent up the shaft"* — already summed by `Tick`, **no writer yet** | `physics/ledger.rb` |
| A prime mover for a black start | `Nodes::Motor` carries its own rotor | `nodes/motor.rb` |
| A choked working | `Obstructs` + `reaction_throttle` | `concerns/obstructs.rb` |
| A roof fall opening a hole | `Nodes::Breach` senses a failure **mode**, `opens_by:` | `nodes/breach.rb` |
| A rope over a pulley | `Bearing` with `duty:` — named in [`nodes.md`](../reference/nodes.md) as the intended use | `nodes/bearing.rb` |
| Mining kit and traits | `crude_miners_tools`, `hand_lamp` (`mining_effectiveness`, `darkvision`, `open_flame`), `pit_sense` (`hazard_sense`), and `races.yml`'s darkvision — **written for this mine already** | `kit.rb`, `content/archetypes/races.yml` |
| New hazard kinds | The tag convention: `%i[rockfall firedamp]` resists against `rockfall_resistance` etc. with **no engine change** | `injury.rb` |
| A spec for driven transport | `driven_transport_spec` is written and passing — *"because the consumer it was built for is a mine that does not exist yet"* | `spec/` |

## 4.1 The imported shaft — the one genuinely new piece of architecture

**Nothing crosses between operations today.** `Match#step!` is
`@operations.flat_map { |op| op.step!(...) }`; operations share a tick counter, a seed and a default
`dt`, and nothing else. `DriveLink` is validated against *this* operation's nodes. There is no
electricity resource and no grid, and [`driven_transport.md`](driven_transport.md) says outright
*"assume a black start — nothing may depend on an electrical supply."* The engine's one productive
exit is `Nodes::Load`, whose brake is a `drag_conductances` entry booked to `joules_to_work` —
**a ledger line, not an edge.**

The shape:

- **A new node, `Nodes::Imported` (working name), including `Rotating`.** Inside the mine it is an
  ordinary shaft: other nodes couple to it with `DriveLink`, and the pump and fan conduits name it
  in `driven_by:`. Nothing downstream of it needs to know where the torque came from.
- **A new match-level exchange step**, between operations' ticks, moving the upstream operation's
  `joules_to_work` into the importer's angular momentum. This is the only place two operations meet
  and it must be as small as possible.
- **On the engine side**, a `Load` variant (or a flag on `Load`) marks its work as exported rather
  than absorbed, so the coupling is declared at both ends and visible in the graph.

Three things to settle before writing it:

1. **`time_scale` mismatch.** [`tick.md`](../reference/tick.md) says *"a steam engine uses 1.0; a
   mine would use much more."* If the mine runs 40× faster, one mine tick cannot consume one engine
   tick's work. Either the exchange integrates over simulated seconds on both sides, or coupled
   operations must share a `time_scale`. **Exchange in joules per simulated second and let each side
   integrate over its own `dt`** — but this needs its own conservation spec, because it is exactly
   where a factor-of-`time_scale` error hides. Fatigue's first figures shipped 40× too slow for this
   reason.
2. **Ordering and determinism.** Two operations exchanging inside one tick reintroduces
   order-dependence, which invariant 3 forbids. The exchange must read both operations' **frozen**
   N−1 state and write N, exactly like a node does.
3. **What a brownout feels like.** If the engine cannot supply, the imported shaft slows, the fan
   slows, the air falls, and gas accumulates. That cascade is the entire reason to do this as a
   shaft rather than a resource, and it should be specced as such.

This is a release of its own and wants its own sketch before code. It is also the piece that makes
the game's premise true rather than asserted.

## 4.2 Space as volume nodes

[`minion-sketch.md`](minion-sketch.md) is already most of the design:

> *"it might be as simple as roughing in the geometry in large volumes by adding a local environment
> node to describe what is in that volume of space … we could use an equivalent to our tagged
> transports for materials but for minions that could dictate who can go where and how fast."*

Concretely:

- **A roadway, district or shaft station is a `Vessel`-shaped volume node** holding air. It has a
  `volume_m3`, a temperature, parcels, and ports. The existing `Holds` + `Thermal` + `Pressurized`
  stack gives ventilation almost entirely for free: air is a substance, firedamp is a substance in
  the same volume, and `Physics::Relaxation` already solves gas as pressure-driven flow through
  conductances.
- **Roadways between volumes are `Conduit`s.** A ventilation door is a conduit with a `control_id`.
  A regulator is the same with a smaller `conductance`. An overcast is two conduits that do not
  meet. A brattice is a conduit fitted or not fitted. **Every historical ventilation control is
  already expressible.**
- **Water runs the same graph downhill to a sump**, and the pump out of the sump is a `Conduit` with
  `driven_by:` the imported shaft and `lift_m:` the depth — precisely the machine driven transport
  was built for. Its outflow writes `mass_delivered`.
- **Coal moves the same graph the other way**, face → roadway → pit bottom → cage → surface.

**One topology, four flows.** This is the whole reason to commit to volume nodes rather than a
parallel place graph.

### Costs, eyes open

- **Every holder costs one tick of lag per hop**
  ([`build-an-operation.md`](../guides/build-an-operation.md)). Many roadway volumes is many hops,
  and at a high `time_scale` each tick is many simulated seconds. Volumes must be coarse — "a
  district", not "a metre of roadway".
- **The phase solve is already ~50% of a 100-node tick** ([`current_progress.md`](../current_progress.md)).
  Node count is the budget. Target a first mine well under 100 nodes and measure against
  `spec/reactor_sim/performance_spec.rb`'s 250 ms.
- **Link declaration order changes the answer at 1e-16**, and the traps list says any change that
  reorders links cannot be accepted on a bit-identical digest. A generated roadway graph needs a
  deterministic, declared order.

## 4.3 Minion movement

The seam is named in [`crew_capacity.md`](crew_capacity.md):

> **"Do not build anything that assumes a minion is always at the station their state names — the
> seam for that is `assign_minion`, not `station_index`."**

- **The command stays absolute and idempotent.** `assign_minion(minion_id, station_id)` keeps meaning
  *"be at X"*, never *"step toward X"*. Non-negotiable: the at-least-once Kafka ingress rests on it
  (invariant 4).
- **Travel lives entirely inside the tick**, as state on the minion — roughly
  `{ station:, bound_for:, progress: }` — advanced in a new phase against the frozen N−1, using the
  declared-distance information the volume graph already carries.
- **Movement is tagged transport.** A minion's route between volumes is gated by tags, so a `flying`
  minion can reach a platform a walking one cannot, and speed is a function of the person, the route
  and what device is fitted on it.
- **The cage, the ladderway and the man engine are the same abstraction**: a route between two
  volumes with a capacity, a cycle time and a power draw. Ladders are free and slow. A cage is fast,
  capacity-limited, competes with coal for the same shaft, and costs power. A man engine is
  continuous-flow, high capacity, high power, and can fail catastrophically. **That is the upgrade
  ladder, and it falls straight out of the model.**

### Four edits, each with a written trap

| Edit | Trap |
|---|---|
| `Minion#initial_state` | — |
| `Tick#call`'s phase-8 return hash | **A key not named here is silently dropped** |
| `Operation#restore` | **Symbols as values do not survive JSON.** `station` was already the third instance. Assert with `be`, never `eq` |
| `Operation#crew_view` + the delta protocol | `player_view_spec` guards that merged deltas equal a full view |

### Two expedients a mine hits immediately

Both flagged `TODO: expedient` in [`tick.rb`](../../lib/reactor_sim/tick.rb); both are game-design
questions, not mechanical ones:

- **`station_index` is last-writer-wins** when two minions share a station. A gang at a face breaks
  this on day one. Needs a rule: refuse, or sum their effort.
- **An unmanned valve moves at full rate.** In a steam engine every lever is frictionless so it never
  showed. A ventilation door nobody is standing at should probably not swing itself.

## 4.4 Nodes and parts, first sketch

Mostly stock nodes with mine-shaped configuration. Machine-specific behaviour lives under
`lib/reactor_sim/operations/mine/`, never in `nodes/`.

| Thing | Node | Notes |
|---|---|---|
| Surface, pit bottom, roadway, district, face | `Vessel` | Air + firedamp + water + coal in one volume |
| Roadway, door, regulator, brattice | `Conduit` | `conductance:`, optional `control_id:` |
| Upcast shaft | `Conduit` | `stack_height_m:` already models draught — a furnace-ventilated variant is nearly free |
| Fan | `Conduit` with `driven_by:` + `head_pa:` | Constant load on the imported shaft |
| Sump pump | `Conduit` with `driven_by:`, `lift_m:`, `delivers_to: :work` | Writes `mass_delivered` |
| Winding engine / cage | new node, `Rotating` + a cycle | The one genuinely new mine node; carries capacity, cycle time, and the men-or-coal choice |
| Headgear sheave | `Bearing`, `duty: :journal` | Rope over a pulley — already the documented intended use |
| Roof fall | `Breach` sensing a support's failure mode | `opens_by:` per mode |
| Coal face | new node | Writes coal parcels, emits firedamp, reads the hewer's `mining_effectiveness` × light |

New content: coal already exists as a resource; **firedamp/methane, blackdamp, afterdamp and stone
dust are new**, with a firedamp combustion reaction. Per [`content/CLAUDE.md`](../../content/CLAUDE.md)
these want updating alongside [`add-content.md`](../guides/add-content.md).

**Blueprints are derived, not hand-listed.** A mine operation plus mine parts auto-generate blueprint
rows and will **fail the catalogue build until priced** in `config/blueprints.yml`. Check with
`rake blueprints:audit`.

## 4.5 Instruments

`Sources::Derived::SIGNATURES` is a whitelist — a quantity not in it will not build. The mine's
gauges want: a lamp flame-cap reading of firedamp (`Bands` + heavy `Noise` + `Lag`, because the
reading is a person's estimate), water level in the sump, air quantity at a measuring station, cage
position, and district temperature. `PANEL_ORDER` must name every one, and `Assembly` refuses a gauge
it does not name.

The upgrade rule holds: **an upgrade may reduce a filter, never remove a class of one.**

## 4.6 Release sequence

Each stage separately shippable and separately reviewable. Stages 1 and 2 each want their own sketch
before code.

1. **The imported shaft.** New node, match-level exchange, conservation spec across the boundary,
   brownout behaviour. Independently testable against two steam engines before a mine exists.
2. **The spatial model.** Volume nodes, roadway conduits, minion travel state, the four edits above,
   rules for the two expedients. Still no mine — provable on a rig.
3. **The mine, statically staffed.** Faces, hewers, coal to the pit bottom, `mass_delivered`,
   drainage on the imported shaft. Ventilation present but not yet dangerous.
4. **Ventilation and gas.** Firedamp emission, accumulation, dilution, the lamp instrument, ignition.
   The stage that makes it a game.
5. **Hoisting.** The cage as a real cycle competing for the shaft; the men-or-coal choice.
6. **Hazards and the tech tree.** Roof falls, inundation, the upgrade ladder (fan tiers, pump tiers,
   cage → man engine, coal cutters, stone dusting).

## 4.7 Documentation owed

Per the change→file table in the root `CLAUDE.md`, in the same commits:

- [`reference/nodes.md`](../reference/nodes.md) + `nodes/CLAUDE.md` — every new stock node; the
  concerns table drifts on a **column**
- [`reference/tick.md`](../reference/tick.md) + `lib/reactor_sim/CLAUDE.md` — if movement adds a phase
- [`reference/settlement.md`](../reference/settlement.md) — the `mass_delivered` writer, any new
  ledger line, the inter-operation exchange
- [`reference/diagnostics.md`](../reference/diagnostics.md) + `diagnostics/CLAUDE.md` — new
  `SIGNATURES` entries, sources, filters
- [`guides/build-an-operation.md`](../guides/build-an-operation.md) + `operations/CLAUDE.md` — the
  second operation is the first real test of this guide; anything it gets wrong should be fixed on
  sight
- [`guides/add-content.md`](../guides/add-content.md) + `content/CLAUDE.md` — the new gases and
  reactions
- [`reference/invariants.md`](../reference/invariants.md) — **if the inter-operation exchange changes
  what order-independence means, say so loudly**
- [`current_progress.md`](../current_progress.md) — the "what to do next" list and the traps list
- `spec/CLAUDE.md` — a row per new spec file

## 4.8 Verification

**Per stage:**

```sh
bundle exec rspec spec/reactor_sim/conservation_spec.rb   # first, always
bundle exec rspec --dry-run                               # example COUNT, not just failures
bin/rubocop
ruby -Ilib -e 'require "reactor_sim"'                     # boots with no Rails at all
bundle exec rake blueprints:audit                         # every new part priced
```

**The six specs a new operation owes** (copy `spec/reactor_sim/steam_engine_spec.rb`): cold start by
the real operating procedure; output, and more when driven harder; fails the way it should with the
right event type and detail; moderate settings survive a long run with no events; **conservation to
`< 1e-9` relative**; snapshot round-trip preserving chassis, loadout and digest, with part ids and
minion stations asserted using `be`, never `eq`.

**Specific to this work:**

- A conservation spec **across the operation boundary** — work leaving the engine equals work
  arriving at the mine's shaft, integrated over simulated seconds, at mismatched `time_scale`s.
- A movement spec proving `assign_minion` is still absolute and idempotent: apply the same command
  twice, mid-journey, and get an identical digest.
- `injury_spec` walks every catalogued machine for hazards wired to stations that do not exist — a
  typo'd station in `endangers:` fails the build, which is the behaviour wanted.
- Use `spec/support/reference_crew.rb` and `deploy!`; **never pin a spec to a real minion or a
  balance figure.**
- Drive it from a scratch script using `op.telemetry`, not a spec, while tuning.

**End to end:** `bin/dev` plus `bin/match_runner`, and **restart both.**

---

## Sources

- [Man engine](https://en.wikipedia.org/wiki/Man_engine) ·
  [Levant Mine and Beam Engine](https://en.wikipedia.org/wiki/Levant_Mine_and_Beam_Engine) ·
  [History of Levant Mine (National Trust)](https://www.nationaltrust.org.uk/visit/cornwall/levant-mine-and-beam-engine/history-of-levant-mine-and-beam-engine)
- [Glossary of coal mining terminology](https://en.wikipedia.org/wiki/Glossary_of_coal_mining_terminology) ·
  [History of coal mining](https://en.wikipedia.org/wiki/History_of_coal_mining) ·
  [Mining methods (oldminer.co.uk)](https://www.oldminer.co.uk/mining-methods.html)
- [Stoping](https://en.wikipedia.org/wiki/Stoping) ·
  [Philip Deidesheimer / square sets](https://en.wikipedia.org/wiki/Philip_Deidesheimer) ·
  [Mining levels: stations, drifts, crosscuts](https://www.911metallurgist.com/blog/mining-levels-stations-drifts-crosscuts/)
- [Drainage adits (Cornish Mining WHS)](https://www.cornishmining.org.uk/about/mining-in-cornwall-and-west-devon/inventions-and-technology/drainage-adits) ·
  [Dressing the ore (Cornish Mining WHS)](https://www.cornishmining.org.uk/about/mining-in-cornwall-and-west-devon/mining-processes/dressing-the-ore) ·
  [Bal maiden](https://en.wikipedia.org/wiki/Bal_maiden) ·
  [Glossary (balmaiden.co.uk)](http://www.balmaiden.co.uk/Glossary.htm)
- [Lifecycles in Coal Mine Ventilation Technologies, 1850–1914 (EHS)](https://files.ehs.org.uk/wp-content/uploads/2020/11/29060837/MurraySilvestreFullPaper2018.pdf) ·
  [Waddle fan](https://en.wikipedia.org/wiki/Waddle_fan) ·
  [Ventilation / gas control (undergroundCOAL)](http://undergroundcoal.com.au/fundamentals/07_ventgas.aspx)
- [Firedamp](https://en.wikipedia.org/wiki/Firedamp) ·
  [Blackdamp](https://en.wikipedia.org/wiki/Blackdamp) ·
  [Afterdamp](https://en.wikipedia.org/wiki/Afterdamp) ·
  [Whitedamp](https://en.wikipedia.org/wiki/Whitedamp) ·
  [Safety lamp](https://en.wikipedia.org/wiki/Safety_lamp)
- [Hartley Colliery disaster](https://en.wikipedia.org/wiki/Hartley_Colliery_disaster) ·
  [Senghenydd colliery disaster](https://en.wikipedia.org/wiki/Senghenydd_colliery_disaster) ·
  [Courrières mine disaster](https://en.wikipedia.org/wiki/Courri%C3%A8res_mine_disaster)
- [Safety fuse](https://en.wikipedia.org/wiki/Safety_fuse) ·
  [Drilling and blasting](https://en.wikipedia.org/wiki/Drilling_and_blasting) ·
  [1911 Britannica: Power Transmission / Pneumatic](https://en.wikisource.org/wiki/1911_Encyclop%C3%A6dia_Britannica/Power_Transmission/Pneumatic)
- [Whim (mining)](https://en.wikipedia.org/wiki/Whim_(mining)) ·
  [Pit pony](https://en.wikipedia.org/wiki/Pit_pony) ·
  [The History of Winding (dmm.org.uk)](https://www.dmm.org.uk/colleng/4406-01.htm)
- [From Picks to Shearers (National Coal Mining Museum)](https://www.ncm.org.uk/news/from-picks-to-shearers/) ·
  [Coalface Mechanisation through the Ages](https://miningheritage.co.uk/coalface-mechanisation-through-the-ages/)
- [Mine rescue](https://en.wikipedia.org/wiki/Mine_rescue) ·
  [Breathing Apparatus for Mine Rescue in the UK, 1890s–1920s (Springer)](https://link.springer.com/chapter/10.1007/978-3-031-06477-7_17)
- [Gold Miners' Phthisis (NCBI)](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC5269010/) ·
  [Mining: South Africa's legacy — occupational respiratory disease (NCBI)](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC3579952/)
- [Northern Mine Research Society](https://nmrs.org.uk/) ·
  [Technological innovation derived from the Comstock Lode](https://www.goldenstatemint.com/blog/technological-innovation-derived-from-the-comstock-lode/)
