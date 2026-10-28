# The open pit — unit 5, and 5a: the pit by hand

> Input to a decision, not a description of the system. Unit 5 of the open-pit sequence, after the
> mobile engines ([`mobile-engines.md`](mobile-engines.md), [`steam-shovel.md`](steam-shovel.md),
> [`locomotive.md`](locomotive.md)). The research is
> [`open-pit-iron-research.md`](open-pit-iron-research.md). **This draft proposes how the pit splits
> into sub-units (§2) and details only the first, 5a.** Each later one gets its own draft once the one
> before has landed. Second revision: §13 records the first review.

## 1. What is decided

From the review of the research (2026-10-19), the units since, and §13:

- **A sunk limonite pit**, one chassis. Washing is the draw.
- **Output is finished tons**: washed, crushed, calcined, dried. The session goal is N of them, and
  counts washed tons only while the finishing is being built.
- **The basic pit works entirely by hand**, with what fixed plant it has on the line shaft:
  - **Steam shovels and dinkeys are upgrades.** Work goes on with or without either.
  - Stripping by hand and carrying out by barrow is slower, not impossible.
  - With dinkeys and no shovel, the cars are loaded by hand.
- **Stripping is the player's own second gang.** Some ore starts uncovered, and overburden and ore are
  worked at the same time.
- **The ground varies per match.** The overburden varies not only from pit to pit but **along the
  face**: a few metres of boulders or other obstruction are harder than the rest.
- **The pit has geometry from the start**: benches that advance and uncover what is under them.
- **Outbuildings at each bench and at the dump** let some of the shift start there, as the colliery's
  shift parts do; every fitted engine's crew starts at its post.
- **This is a personnel game.** People tire, rotate out and rest.
- Weather and daylight, one season a match; 30–60 minutes, starting with an advance shift; no horses.

## 2. The pit, in sub-units (for review)

| | Sub-unit | What it adds | What the player gets |
|---|---|---|---|
| **5a** | **The pit by hand** | The operation, its chassis and places; the benches as geometry, the stripping face uncovering the ore; the ground drawn per match, hard stretches along each face; hand getters at each face, barrowmen up the ramp road, the spoil dump and the ore bin; quarters, outbuildings, a boss; the weather; the panel; a place in the dev match | Wash ore at bank, by hand, and two gangs to keep in step |
| 5b | Washing and water | The line shaft, coupled to an engine; the log washer separating limonite from clay into a mud dam; the reservoir and its line-shaft pumps | Washed ore, the goal's first count |
| 5c | Machines in the pit | The steam shovels and dinkeys as upgrades fitted into 5a's faces, each optional and each working with or without the other (§3); their tracks from the pit's geometry; hand loading of the cars | The upgrades that change the pace |
| 5d | Washing at scale | Multiple washers, bigger washers, a full washing plant on site — and the shaft's draw that comes with them | Washing that keeps up with a shovel |
| 5e | Drainage and rain | The pit's sump and pumps; rain on the pit and seepage from the strata; water on a bench; drowning | The pit's water problem |
| 5f | Benches and slides | Slope against repose; water and a cut toe; slides that bury a face and bring a boom down; dump breakbacks | The pit's commonest killer |
| 5g | The mud dam | Its filling, its bursting with counterplay, the decant, bigger dams; the larger reservoirs and their rupture | Somewhere for the washing to go |
| 5h | Blasting and hard ground | Powder and dynamite for 5a's hard stretches; frost; gopher holes; flyrock; the thawing house | Something to do about bad ground |
| 5i | Finishing | Crushing, calcining, drying | **Finished tons**, and the goal as it is meant to be |
| 5j | Pit logistics | A second train per shovel and the passing track; the coaling stage and water columns; boarding a train at a stand | The upgrades that keep a shovel digging |

*Renumbered at the 5f review*, when the mud dam became a sub-unit of its own. Sections before §20
name blasting 5g, finishing 5h and logistics 5i.

**Why this order:**

- **The basic operation comes first and whole**: 5a digs and carries by hand, and 5b washes on the
  line shaft. A hand pit then has the goal's first count before any machine exists.
- **5c fits the machines into it as upgrades**, and **5d scales the washing to keep up with them**
  (its own design pass, decided at the 5c review).
- **5e and 5f are the hazards a pit is known for**; 5g answers 5a's hard ground and 5f's bad faces.
- **5h completes the finished ton**, and **5i is upgrades**.

## 3. The shape every face has, by hand or by machine

Every face, stripping or ore, is the same three steps, so the machines fit in without the hand pit
changing shape:

```
bench ─(getting)─➤ muck at the face ─(carrying out)─➤ spoil dump | ore bin
```

| Step | By hand (5a) | By machine (5c) |
|---|---|---|
| **Getting** | getters with pick and shovel, an effort post at the face | the steam shovel, digging beside them |
| **Muck at the face** | a holder: what has been got and not yet taken away | — |
| **Carrying out** | barrowmen up the ramp road | a dinkey's cars, loaded at the face |

**In 5c the two machines combine four ways:**

| Fitted | What happens |
|---|---|
| **Neither** | by hand throughout |
| **A shovel, no dinky** | the shovel casts onto the muck, and the barrowmen take it away |
| **A dinky, no shovel** | loaders shovel the muck into the standing cars |
| **Both** | the shovel dumps straight into the cars while a train stands at the face, and casts onto the muck when none does |

How the slots say "with or without" is 5c's to settle; §12 names the likely shape.

## 4. 5a — the benches, as geometry

**A cut across the field**: the pit is worked as a cut of fixed width, two benches deep:

- the **stripping bench** — the overburden, its thickness drawn per match;
- the **ore bench** under it — wash ore, its thickness drawn too.

**Each face advances along the cut** as it is dug, by mass dug divided by `width × height × density`.

**`OpenPit::Bench`, a holder per bench**, as the colliery's seam is a stock:

- It knows how far its face has advanced (`advanced_m`), and offers its getters what is within reach.
- **The ore bench can be worked only behind the stripping face, a berm back.** What is uncovered is
  the length between the two faces, less the berm, times the ore's cross-section. Strip faster and
  more is uncovered; strip slower and the ore face catches up and stops — "stripping behind".
- **The stripping ratio is not drawn; it falls out of the two thicknesses.** A pit whose overburden
  is twice as thick as its ore needs twice the stripping, which is the number the player feels.
- **Some ore starts uncovered**: the stripping face starts some metres ahead of the ore face.
- **Conserved**: a bench is a stock, and what is dug leaves it.

**The cut is narrow, so the faces move.** Mesabi benches were 25–30 ft high and hundreds wide, and
faces there advanced a few metres a day. A match is an hour, so this is a stripping cut a few metres
wide. That makes a hand gang's advance tens of centimetres a match and a shovel's a few metres —
enough that metres mean something. The figures are the sweep's.

**What 5f needs from this**: each bench has a height, a face and a toe, and the distance between the
faces. Slopes and slides read those.

## 5. 5a — the ground, drawn per match

**`OpenPit::Ground`**, drawn once at `initial_state` from the pit's own stream, as `Mine::Ground` is:

- **Thicknesses**: the overburden's and the ore's, each about a median, so the stripping ratio
  varies from easy to the whole game. The spread deliberately exceeds what a bottom-tier stripping
  gang copes with.
- **Hard stretches along each face**, drawn as `Mine::Ahead` draws what lies in front of a coal face:
  - **None, one or a few** of them.
  - **Each has a position along the cut, a length of a metre or a few, and a hardness**: a multiple
    of the bench's ordinary hardness, for boulders, cemented hardpan, an old stump.
  - Positions are drawn within what a match's work reaches, or they would never be met.
- **While a face is in one, getting it is that much harder**:
  - A getter wins that much less for the same effort.
  - In 5c a shovel's cut costs its engine that much more (`work_j_per_kg`), so the shovel slows.
  - **5g's blasting is what breaks one.**
- **Nobody is told where they are.** The getters know when they are in one ("into hard ground", on
  the face's board). That is the only warning, as the colliery's weeping coal is.

**A spec pins it**, `Ground::ORDINARY` (median thicknesses, no hard stretches), for the colliery's
reason.

## 6. 5a — the work by hand

| Post | Where | Kind | What it does | Rated by |
|---|---|---|---|---|
| **Getters**, a gang a face | each bench | effort (`swing`, `force`) | win the bench into the muck at the face, slower in hard ground | per worker, scaled for the match — a navvy's 20 t a day of loose earth, brought into an hour's play |
| **Barrowmen**, a gang a face | each bench → bank | effort (`force`), a worked conduit | wheel the muck up the ramp road to the spoil dump or the ore bin | a barrowful a round trip of the ramp road's length, so a deeper pit is slower to clear |
| **Boss** | the benches | oversees | as the overman does the district | — |

- **The ramp road's length is the pit's depth over its grade**, so the ore, being deeper, is the
  longer carry. The barrows are a `burden.rb` load, so a small barrowman carries less.
- **Perils**:
  - **Struck by a fall from the face** while getting, scaled by the getting, and worse in a hard
    stretch.
  - **A fall on the barrow way**, scaled by the traffic and worse wet or icy (`underfoot:`, as the
    bank's deck).
  - Both are `opportunity: true`.
- **No hand loading in 5a**, because there are no cars to load. It comes with the dinkies (5c).

## 7. 5a — places, walks and outbuildings

**Places**, all open to the sky (`open_air:`, exposure 1.0):

| Place | What is there |
|---|---|
| **Bank** | quarters, the ore bin, the top of the ramp road |
| **Stripping bench** | the stripping face and its muck |
| **Ore bench** | the ore face and its muck, deeper |
| **Ramp road** | the barrow way out of the pit |
| **Spoil dump** | where the stripping is tipped |

**Walks**: bank ↔ stripping bench ↔ ore bench by the ramp road, and bank ↔ spoil dump.

**Outbuildings**, tiered parts in slots of their own, each letting some seats start there (the
colliery's `advance_seats:`, `advance_place:`):

- a **cabin at the stripping bench**;
- a **cabin at the ore bench**;
- a **shelter at the dump**.

Each is somewhere to rest, as the pit bottom's refuge is, so a tired getter need not climb out to
recover. **The quarters at bank** seat the rest, and the shift is dealt from the end of the roster
into the outbuildings first, as the colliery deals its face shift.

## 8. 5a — the panel

- **Each face's board in words**: getting, into hard ground, waiting on the barrows (the muck piling
  up), nothing to get (stripping behind), nobody at the face.
- **Ore at bank** (the bin) and **spoil tipped**.
- **Uncovered ore** in the boss's words: plenty, running short, stripping behind. The gauge that says
  which gang to send help to; a number would be a different game.
- **The weather gauges** (`WeatherGauges`).

## 9. 5a — the delivery tier

**The pit joins the dev match** as `open_pit: :open_pit`, with outfitting and crew screens from the
generic ones. **Nothing is coupled to it yet**: nothing in 5a is on a line shaft. 5b couples it.

## 10. Content

- **`limonite`** and **`clay`**, two solids. **Wash ore is about a quarter limonite by mass**: Lehigh
  took about 3 yd³ of ore-bearing ground to a ton washed (Lesley). The ore bench holds both, a getter
  wins the mix, and 5b's washer separates it.
- **`overburden`** is 4b's.

## 11. Specs (relational)

- **The benches:**
  - A face advances by what is dug off it.
  - The ore face stops a berm behind the stripping face, and starts again as the stripping goes on.
  - A thicker overburden uncovers less ore for the same stripping.
- **The ground:**
  - A face in a hard stretch wins less for the same effort, and out of it as before.
  - A pinned ground draws nothing; two seeds draw two pits, and a seed reproduces its own.
  - Across many draws, the stretches fall where a match reaches.
- **Carrying out:**
  - The barrowmen take the muck to the spoil dump or the bin, slower up a longer ramp.
  - With nobody barrowing, the muck piles up at the face and the getters wait on it.
- **The shift:** starts dealt into the outbuildings and the quarters, and the rest walk down. A tired
  getter recovers in a bench cabin.
- **The boards and the uncovered-ore gauge** read their bands from constructed states.
- **Regressions:** mass and energy close through a stretch of work, a snapshot replays, and the
  catalogue walkers (`failure_spec`, `injury_spec`, `assembly_spec`, `blueprint_spec`) take the new
  operation in.

## 12. Deferred

Everything in §2 past 5a. For 5c, what is visible from here:

- **A machine is a dozen slots** — its engine, bunker, tank, valve, readings, dipper, chain, boom, or
  its train and brake — and **all of them must be absent together** when the machine is not fitted.
  The likely shape is a slot that **`needs:`** another: a shovel's other slots needing its dipper, a
  dinky's its train. They build nothing and are not required while it is empty, and the outfitting
  screen groups them under it. That is a small, generic `Assembly` change.
- **The faces are wired for what is fitted**, decided at build from the resolved loadout, which is in
  `options:` already: the dipper casting onto the muck or into the cars, and the cars loaded by hand
  or by the shovel.
- **A hand-pushed tramway** between barrows and dinkies is a candidate tier: tubs on a light track,
  the colliery's putting.

Also deferred: ore grade beyond finished tons; contract stripping as a party of its own; a hillside
chassis.

## 13. Review decisions (first draft)

- **Machines are upgrades**; the basic pit works by hand plus its line shaft (§1, §3, the new 5c).
- **The overburden varies along the face**, not only from pit to pit (§5).
- **Washed tons are the goal only while building** (§1).
- **Geometry now** (§4), not a stripping ratio.
- **Wash ore as limonite and clay** (§10).
- **Outbuildings at each bench and the dump**, plus every engine's crew at its post (§7).
- **The pitmen's fatigue stays**: they rotate out and rest — a personnel game.
- **Uncoupled in the dev match** until the line shaft arrives (§9).

## 14. Review decisions (second draft)

1. **Washing (5b) before the machines (5c).**
2. **The narrow cut**: more movement a match is more appealing to play.
3. **Hard stretches hidden until met.** A boss or an instrument that finds them ahead is a later
   option.
4. **Barrows first, the hand tramway a later upgrade.**
5. **The outbuildings are somewhere to rest as well as to start**, as the colliery's refuges are.

## 15. Settled while building 5a

- **The ramp road is not a place.** The barrowmen are posted at their bench, and their peril is
  their post's; a place nobody stands in bought nothing. 5f may want one for slides.
- **The dump has a tip head the dumpmen spread from**, a small holder in front of the spoil dump.
  Unspread it fills in about twenty minutes of stripping, and then the barrows have nowhere to tip —
  the third job a face needs, and what the dump shelter's seats are for.
- **Getting is gated on a pick** (`mining_effectiveness`), as hewing is, so the kit matters.
- **Every job in the pit is gated on light** (`darkvision`): getting, barrowing and spreading. The
  sky lights the pit by day; at night only somebody who sees in the dark works (decided in review).
  Lighting bought as blueprints is for later — or a gang of dwarves, orcs and goblins who see in the
  dark and will fight.
- **Hard stretches are drawn from where the face starts**, 0.1–3 m ahead, so a hand gang meets the
  nearest and a shovel all of them.
- **The thicknesses are a triangular spread**, two uniform draws summed, rather than a log-normal:
  no transcendental, which is where IEEE results differ across platforms (`Rng`).
- **`Crew.minions` deals the roster for both operations**, moved out of the colliery, and
  **`Assembly#advance_shifts` takes an outbuilding's place from its slot's names** when the part
  does not name one, so one hut part serves either bench.
- **The uncovered-ore gauge is the ore gang's word** (`observer:` their post), not the boss's:
  the boss is an empty slot to start, and a gauge nobody can man from the first tick would be
  dark in every starting pit.
- **First figures on the rig**, a pick at the kit's 0.6, both faces' full gangs:
  - Four strippers win about 1.4 kg/s, a third of a metre an hour.
  - Two ore getters win about 0.7 kg/s.
  - The barrows keep up, and the books close exactly.
  - All for the sweep.

## 16. 5b — washing and water (for review)

**What it adds**: the pit's line shaft, a log washer on it parting the limonite from the clay, the
water the washer needs, and washed ore — the goal's first count.

### The line shaft

**`Nodes::Import`, as the colliery's**: a line shaft roped to another operation, a clutch at
bank, every fixed fitting a load on it. A pit with the shaft stopped washes nothing and pumps
nothing, but its hand work goes on.

### The washer

The period's machine is the **log washer**:
- **The machine**: two long shafts set with angled teeth, on a slope, turned off the engine. Wash
  ore is dumped in at the low end and the teeth work it up over a sieve.
- **The water**: from a perforated gutter.
- **The two outputs**: the clay floats off as slurry to a mud dam, and the limonite comes out clean
  at the top.
- **Output**: 15–35 t of washed ore a day, typically 20–25 (Prime 1875; research §2.2). Fed sticky
  clay, it rolls balls and passes them as ore.

**Proposed: `OpenPit::LogWasher`, a holder on the line shaft.**
- **What it washes**: wash ore from the bin, fed by a **washer hand** (an effort post, raking it
  in), and water from the gutter.
- **How fast**: as fast as its logs turn — the line shaft's speed against its rated speed, as the
  dipper reads its engine's.
- **What it costs**: the work of turning the logs through the clay is charged off the shaft as a
  drag (`work_j_per_kg`, the dipper's pattern).
- **Short of water, it washes less**: a share of what it is rated for, by how much water it has
  against what the clay needs.
- **It parts the two by tag** (question 1). Limonite gains a tag `ore` and clay `gangue`. The
  washer's two outlets are `washed` (accepts `ore`) and `slurry` (accepts `gangue` and `liquid`).
  The arbiter already refuses material a port does not accept anywhere on the path, so the
  separation needs nothing new in the engine.
- **Where they go**:
  - **The washed ore** goes to a stockpile at bank: **washed tons**, the goal's count until 5h.
  - **The slurry** goes to the mud dam, a holder that fills as the match goes on. Its failure — a
    dam bursting onto the bank — is 5f's.

**Tiers** (research §7):
- **Bottom**: a single-shaft log washer, about 15 t a day washed.
- **Above it**: the two-shaft Thomas washer, about 25.

At the bottom tier a full hand ore gang feeds about one single-shaft washer, so the washer and the
gang are sized against each other.

### The water

- **A reservoir at bank**: a holder stocked for a match. 5e's rain tops it up, and a dry season
  runs it down.
- **A pump on the line shaft lifting it to the washer's gutter**: the colliery's `Pump`, a driven
  displacement conduit. It charges the shaft for the lift and moves nothing with the shaft stopped.
- **A washer uses several tonnes of water a tonne of ore** (modern log washers; the period figure is
  not in the sources read). That water leaves with the slurry, so the reservoir is spent as the pit
  washes.
- **The shovels' standpipes** move onto this reservoir in 5c, when the shovels arrive.

### Who works it, and what can go wrong

| Post | Kind | Does |
|---|---|---|
| **Washer hand** | effort, at the washer | rakes the wash ore in from the bin, and clears the balls |

- **Caught in the logs**: a peril of the washer hand, scaled by how hard the logs are turning,
  `opportunity: true`.
- The pump and the washer wear and break as fittings do. A broken washer stops the washing and
  leaves the ore piling up in the bin.

### What powers the shaft (question 3)

In the dev match the steam engine already sells its one `load` to the colliery. The candidates:

- **(a) A second steam engine**, the pit's own engine house, roped to the pit's line shaft. It is
  the colliery's arrangement. The washer and the pump want perhaps 10–20 kW, so a 500 kW engine
  idles at a few percent — the same under-loading the colliery's open rebalance item names.
- **(b) The developer's engine**, for development only, as the colliery has.
- **(c) A small engine of the pit's own**, the vertical engine standing as a stationary blueprint.
  Right-sized, but an engine inside the operation, against "fixed plant is on a line shaft from
  elsewhere".

**Proposed: (a)**, with (b) available as it is for the colliery. The engine is throttled back by
whoever runs it, and the load grows as 5c to 5g add their fittings.

### The panel

- **Washed ore**: the stockpile, in tonnes — the goal's count.
- **The washer's board in words**: washing, short of water, waiting on the washer hand, the logs
  stopped, nothing to wash.
- **The reservoir**, as somebody's guess: plenty, getting low, nearly dry.
- **The mud dam**, as somebody's guess: room, filling, near the top.
- **The shaft's speed**, at bank, honest, as the colliery's is.

### Specs (relational)

- The washer parts wash ore into limonite and slurry, and nothing washes with the shaft stopped.
- It washes less short of water, and none dry.
- It costs the shaft more the more it washes.
- The pump lifts water only while the shaft turns.
- With no washer hand, the bin fills and nothing washes.
- Caught in the logs, only while they turn.
- The boards and guesses in their bands.
- Mass and energy close through washing; a snapshot replays.

### Questions

1. **Parting by tag** (`ore`, `gangue` on the two resources, the washer's outlets filtering) — or a
   washer that splits by resource in its own code?
2. **A perfect parting for now**, all the limonite out clean and all the clay to the dam? Fines lost
   to the dam, and balls passed as ore, would be a lossy washer — the thing a jig tier improves on.
   Later, or in from the start?
3. **What turns the shaft** (above): a second steam engine, as proposed?
4. **The reservoir as a stock for the match**, topped up by 5d's rain — or a stream past the pit that
   never runs dry, so water is a pumping problem rather than a supply one?
5. **The mud dam fills and does nothing yet**, its bursting left to 5e — agreed?

### Review decisions (5b)

1. **Parting by tag.** Simple, and adjustable later.
2. **Lossiness is one number**: each washer tier has an **efficiency**, the share of the limonite it
   washes that comes out as washed ore; the rest goes to the mud dam with the clay.
3. **Power is a match's, not an operation's.** A match will have one or more players running power
   generation for one or more consuming operations. The end goal is a **virtual shaft**: several
   consumers drawing from one, and several generators feeding one, fiated by the match-maker so
   every operation has power on paper, with no separate ropes and clutches between them.
   **A consuming operation has exactly one line shaft it draws from, and knows nothing of where
   that comes from.** For now the pit's is roped to a developer's engine.
4. **The reservoir runs dry only in exceedingly rare matches**, or for a pit running monstrous
   washers. **Larger reservoirs are an upgrade**, with a rupture risk that needs workshopping into a
   mechanic with counterplay rather than a random catastrophe — as the mud dam's does.
5. **The mud dam fills and does nothing yet.**

### Settled while building 5b

- **The washer is a holder that declares its own pushes**, as the dipper does, and its slurry outlet
  sets `transport_affinity` per resource to what it is sending against what it holds — so the lost
  limonite, the clay and the water leave in exactly the shares washed, measured to 10⁻⁴. The
  arbiter's floor on an affinity (10⁻⁶) means a perfect washer would still leak a trace, which it
  calls deliberate.
- **It draws only the water it needs**, two ticks ahead. A trough left to fill from an eager pump
  filled with water and locked the ore out, and nothing washed to let the water go.
- **The washed-ore stockpile accepts `ore` only**, so a route checker can follow the clean outlet
  to it, and the reachability is two routes: the bin to the washer as `solid`, the washer to the
  stockpile as `ore`.
- **Gauge ids are not node ids**: `washed_tons`, `water_supply` and `the_dam` read `washed_ore`,
  `reservoir` and `mud_dam`, because ids are one namespace.
- **The washer's figures**: the single-shaft washer washes 1.7 kg/s of wash ore at 80%, the Thomas
  2.8 at 90%, at 3 kg of water a kilogram. A full hand ore gang feeds the single one well under its
  rating: on the rig 0.72 kg/s in, 0.14 kg/s clean.
- **The dev match ropes a developer's engine of the pit's own** to its line shaft with
  `REACTOR_DEV_ENGINE=1`, because a rope has two ends; without the flag nothing turns the pit's
  shaft and the hand work goes on. A permanent one would be a machine with no outfitting screen in
  every match.

## 17. 5c — machines in the pit (for review)

**What it adds**: 4b's steam shovel and 4c's dinkey as upgrades at either face, each optional and
each working with or without the other (§3); the hand loaders a train brings; the tracks out of the
pit.

### A machine is a dozen slots that come and go together

A shovel is its engine, bunker, tank, safety valve, readings and plug, and its dipper, chain and
boom. A train is the same engine slots, its train and its brake. At the bottom tier none of them is
fitted.

**Proposed: `Slot#needs:`**, a slot built only while the slot it names is fitted:
- **The principal slots**: a shovel's is its **dipper** — "Stripping Shovel" or "Ore Shovel" on the
  outfitting screen — and a dinky's is its **train**. Both are empty by default.
- **While the principal is empty**: every slot that `needs:` it builds nothing, is not required,
  and is shown greyed under it.
- **Once it is fitted**: they take their defaults — the vertical engine, the small bunker, the iron
  chain — so fitting one part brings a working machine.
- **Routes may name a slot too** (`needs:` on a route), so the machine's own reachability is
  checked only when it is there.
- **What the operation builds around a machine** — its driver's post, its board — is built only
  when it is fitted.

It is a small, generic `Assembly` change; nothing in the tick sees it.

### The faces, wired for what is fitted

The operation reads the resolved loadout — already in `options:` — and wires each face for it:

| Fitted | Getting | Carrying out |
|---|---|---|
| Neither | the getters | the barrowmen |
| A shovel | the getters and the shovel, both into the muck | the barrowmen, who cannot keep up with a shovel: the muck fills, and the board says "waiting on the barrows" |
| A dinky | the getters | the barrowmen, and **hand loaders** shovelling the muck into a standing train |
| Both | the getters, and the shovel straight into a standing train's cars, onto the muck when none stands | the train, the loaders, and the barrows |

- **The dipper gets a second outlet** (question 2). `:out` stays its car, through the train's
  loading landing. A new `:cast` outlet is the muck at the face, used only when no train stands
  there. A dipper with no `cast` named behaves exactly as in 4b and 4c, and waits on cars.
- **The hand loaders** are a worked landing from the muck into a standing train's cars, a gang at
  the face. Without a train they have nothing to do.
- **A train's `serves:` is optional.** With a shovel, the train's crash wrecks the shovel's boom and
  its passing endangers the pitmen. Without one, it endangers the getters and the loaders.

### The face contract

- **A shovel reads its face as getters do** (question 3). Its moving-up conduit and its dipper read
  two keys off the bench they dig, if the bench reports them:
  - `hardness`: the cut costs the dipper's engine that much more (the `ground:` key 5a named);
  - `uncovered_kg`: moving up stops where the stripping stops.
- **No such keys means ordinary ground**, so 4b's rig bench is unchanged.

### The tracks, from the pit

**Each face's train runs a `Track` built from the pit's geometry**, at 2% out of the pit:
- **The spoil track**: from the stripping bench up to the tip head. The dinky tips onto it, so the
  dumpmen spread it as they do the barrows'.
- **The ore track**: from the ore bench, deeper and so longer, up to the bin at bank.

**Built from the median depths**, because a track is configuration and a drawn thickness is state
(question 7). A haul road place joins them. Each footplate is carried (4c).

### The engines start at work

**The advance shift raised steam** (mobile-engines.md §3): a fitted engine starts hot, at the
figures it was observed working at, not from cold.

**Proposed**: the at-work state the spec rig was seeding (`AT_WORK`, 81 kW at 34 rad/s) moves into
the library as **`MobileEngine.raised`**. It patches a freshly built operation's engines into it —
the same figures, the same rule that they were read off a running engine. A restore does not touch
it, because a snapshot carries its own state.

### The people

- **The machines' crews**: a shovel's driver, fireman, craneman and five pitmen, and a dinky's driver
  and fireman — eight and two more mouths on a quarters that seats fourteen.
- **The engine crews start at their posts** (question 4), the train crews aboard: they raised the
  steam. That is an exception to the build guide's rule that nobody starts at a working station. The
  rest of a machine's gang starts as 5a's do.
- **The shovels' hoses draw on the reservoir** (5b), so a shovel's water is the washer's water.

### What it means for balance

**A shovel digs about 23 kg/s, sixteen times a full hand gang**, so:
- **A shovel without a train is a muck pile**: barrows cannot clear it.
- **An ore shovel without a stripping shovel starves** for uncovered ore.
- **Either washer is overwhelmed** by an ore shovel — 1.7 or 2.8 kg/s against 23. The period's
  numbers agree: a 1,500 t/day shovel against a 25 t/day washer, which is why the Mesabi did not wash
  its soft hematite. **Bigger washing is its own question**, for after 5c: more washers, or a
  washing plant tier.

### Specs (relational)

- **The slots**: an unfitted shovel builds nothing and requires nothing, and fitting the dipper
  brings a whole shovel; the same for a train.
- **Each of the four combinations**:
  - **Shovel, no train**: the shovel casts onto the muck, and the muck fills past what the barrows
    clear.
  - **Train, no shovel**: the loaders fill a standing train from the muck, and nothing loads while
    it is away.
  - **Both**: the shovel loads a standing train and casts while it is away.
  - **Neither**: 5a, unchanged.
- **The face contract**: a shovel on the ore bench stops moving up where the stripping stops, and
  digs harder ground at more cost.
- **The trains**: a stripping train tips at the tip head, an ore train at the bin.
- **The start**: a pit built with a shovel starts its engine at work, and its engine crew at their
  posts.
- **Regressions**: 4b's and 4c's rigs are unchanged; mass and energy close; a snapshot replays.

### Questions

1. **`Slot#needs:`, with the dipper and the train as the principals** — or a single "machine" slot
   whose part is the whole shovel, its fittings slots of their own beneath it?
2. **The dipper casting onto the muck while no train stands**, through a second outlet, with 4b's
   waiting on cars kept when none is named?
3. **The face contract** (`hardness`, `uncovered_kg` read off whatever bench a shovel digs)?
4. **Engine crews starting at their posts**, an exception to "nobody starts at a working station" —
   or at the bench posted to nothing, like everybody else, with the engine standing hot until they
   step up?
5. **`MobileEngine.raised` in the library**, the rig's observed figures, applied to a fresh build?
6. **Hand loaders come with a train**, and load from the cast pile as well when there is a shovel?
7. **Tracks built from the median depths** — or should the track lengths follow the drawn thickness,
   which would put them in state?

### Review decisions (5c, first pass)

1. **Open: is `needs:` overbuilt?** What it gains over the alternatives:

   | Alternative | What it costs |
   |---|---|
   | **One part per whole machine** ("a shovel with an iron chain and a dead-weight valve") | Loses the per-fitting tiers 4a and 4b built — the chain, the boom, the valve, the readings, the bunker, the tank — or multiplies them into a part for every combination |
   | **Every machine slot optional, defaulting to nothing**, using what `Assembly` does today | Adding a shovel is ten picks, not one. A half-fitted shovel — a dipper with no engine — is a build the verdict refuses, so the player meets a wall of "no engine for the stripping shovel" errors on the way to one that works |
   | **Every slot always there, each part checking whether its machine is** | Every fragment learns to ask whether its host exists — the wiring decision leaks into a dozen parts, and a part fitted for a machine that is not there builds orphans |
   | **`needs:`** | One attribute on `Slot`, and three places in `Assembly` that read it: what is built, what is required, which routes are checked. The outfitting screen groups and greys the dependents |

   **What `needs:` buys is that one pick fits a working machine, an unfitted one costs nothing and
   says nothing, and the per-fitting tiers survive.** The leanest alternative that keeps the tiers is
   the second row, and its cost is the player's, every time they buy a machine. **Decided: `needs:`.**
2. **The player decides how much is delegated.** The cast outlet is built as proposed, and **a lever
   on each shovel** says what it does while no train stands: cast onto the muck, or wait on cars.
3. **The face contract**, agreed.
4. **Engine crews start at their posts.** "Nobody starts at a working station" no longer serves as a
   blanket rule; the build guide names the case it is right for — **a crew whose machine was already
   running when the match began**.
5. **`MobileEngine.raised`**, agreed: one set of observed figures for every hot engine keeps
   them in step, which makes tuning easier.
6. **Hand loaders come with a train**, and load from the cast pile too.
7. **Median depths.** Laying track is not a mechanic.

**Scale, decided alongside**:
- **Posts scale far up in people.** This operation could easily field fifty minions, through larger
  quarters tiers and gang parts with much larger `crew:` stats. Big races — ogres, dwarves, orcs —
  move more than a man, which is how a player eases a bottleneck they prioritise. Managing fifty
  wants a UI rework; that is the delivery tier's, later.
- **Washing scales far up**: multiple washers, bigger washers, a full washing plant on site. That is
  also what brings the shaft's draw up from its present tepid figure. **Decided: its own sub-unit,
  5d**, worth a design pass of its own — so 5c ships an ore shovel the bottom washer cannot keep up
  with, and 5d answers it.

### Settled while building 5c

- **`Slot#needs`** is one attribute and three places in `Assembly`: `part` is nil for a slot whose
  machine is not fitted, so it builds nothing and is not checked; a route may name `needs:` too. The
  loadout keeps a dependent's choice meanwhile.
- **The pit is wired in two passes**: the machines fitted are read off the loadout with the slots
  unwired, then the slots are built wired for them. Both passes have the same slot ids, so a
  restore rebuilds the same machine.
- **A machine's slots are a group of their own**, named for it, so the outfitting screen shows a
  "Stripping shovel" section rather than four sections of identical engines; the screen greys a
  machine's fittings while it is not fitted and keeps their choices selected.
- **The casting lever** is the player's, on each shovel with a train to load: at 100 it casts while
  no train stands, at 0 it waits on cars. The dipper's board says "the muck is full — waiting" when
  it would cast and cannot.
- **The shovel's and the train's outdoor posts are gated on light** — pitmen, craneman, dumpmen,
  loaders — so the rig's places are open to the sky; the engine posts are not, a machine carrying
  its own lamps.
- **The dipper's board shows "blowing off" only while it stands by**, as the train's does: a shovel
  lifts her valve at every swing, and it hid the digging.
- **Engine crews start at their posts** through `advance_posts:` on the engine part; the build
  guide names that as the one case the starting rule allows.
- **`MobileEngine.raised`** holds the at-work figures the rig had, and the rig's `at_work` is it
  plus its own test load.
- **The heaps' ports are a dipperful wide**, 2,000 kg/s, so a dump or a tipping is not throttled by
  the muck pile it lands on.
- **On the rig, both machines at the stripping face**: the shovel loads a standing train at about
  24 kg/s, the train climbs to the spoil dump and is tipped in under two minutes, and comes back
  while the shovel casts. The cast muck fills and the shovel waits, and the loaders work it back
  into the next train beside the shovel. The face advances about a metre and a half in ten minutes.

## 18. 5d — washing at scale (for review)

**The problem 5c left**: an ore shovel digs about 23 kg/s of wash ore, and the best washer takes
2.8 kg/s. The period's own figures agree — a 25 t/day washer against a 1,500 t/day shovel — and the
answer then was more washers, bigger washers, and in the end a **washing plant**: the Mesabi's
concentrators of about 1910, built to treat lean ores by the thousand tons a day (research §2.10,
[gk] on the figures). Scaling the washing is also what brings the line shaft's draw up from about
15 kW to the hundreds a stationary engine is worth.

### More washers: bays

**Proposed: a washing floor of four bays**, a slot each:
- **The first bay** is the bottom tier's single log washer, as now.
- **The other three are empty to start**, each taking a washer of its own, each with its own hands
  and its own board.
- **All of them draw on the one bin, the one water main and the one mud dam**, so the bays compete
  for the ore and for the water, and a pump that kept one washer wet starves four.
- **The ids are the bay's** (`washer_2_washer`, `washer_2_hands`), through `Names` as a mobile
  engine's are.

**Alternative: one washer part with a count** — "a battery of three log washers". Fewer slots, and no
way to fit one good washer beside two cheap ones, which is the kind of choice this game is made of.

### Bigger washers: the tiers

| Tier | Washes (wash ore) | Keeps | Work | Water | Hands | Notes |
|---|---|---|---|---|---|---|
| Single log washer | 1.7 kg/s | 80% | 6 kJ/kg | 3 kg/kg | 2 | the bottom |
| Thomas washer | 2.8 | 90% | 5 | 3 | 2 | two logs geared together |
| Heavy Thomas washer | 5.0 | 90% | 5 | 3 | 3 | longer logs, a grizzly ahead of it |
| **Washing plant** | 20 | 85% | 8 | 3 | 8 | its own slot (below) |

**The washing plant is a slot of its own**, because it is not one machine but a building:
- **What it is**: screens, log washers, jigs and tables, roughly a shovel's dig washed in one
  place.
- **What it costs**: about 160 kW off the line shaft, 60 kg/s of water, eight hands.
- **What it is for**: a pit with an ore shovel.
- **How it is built**: the same `LogWasher` node at a plant's figures. Its lower efficiency than the
  Thomas is the lean ore it was built to treat, and a number to sweep.

### The water and the shaft

- **The pump becomes a slot**, tiered:

  | Pump | Lifts | Enough for |
  |---|---|---|
  | Single pump | 8 kg/s | one or two log washers |
  | Duplex pump | 25 kg/s | a full washing floor |
  | Plant pumps | 80 kg/s | the washing plant |

  One pump lifting for every washer is what makes them compete.
- **The line shaft is rated for the plant** — about 12 kN·m at 22 rad/s, some 260 kW — so the shaft
  is never the limit and the supply is. Behind the virtual shaft (§16), the match-maker supplies
  what the pit draws.
- **The reservoir is unchanged**: 600 t, and the plant spends it in under three hours. **The larger
  reservoirs**, with their rupture risk, are the upgrade 5b's review named for exactly this, and
  need their own workshop; until then a plant pit runs its reservoir down within a long match,
  which is the pressure.

### The mud dam

**A plant's slurry fills the dam in well under a match**, because the dam keeps the water as well as
the clay. Two answers, not exclusive:
- **A decant** — clear water drawn off the top of the dam back into the reservoir. The dam's water
  outlet accepts only `liquid`, so the clay stays and the water returns by the same tag filtering
  the washer parts by. A share comes back, the rest held in the settled clay.
- **A bigger dam**, a tier.

### The panel

- **Each fitted washer's board in words**, the plant's too.
- **"Washed ore"**, unchanged — the goal's count.
- **The reservoir and the dam**, as the washer hands reckon them, unchanged.

### Specs (relational)

- Two bays wash more than one from the same bin, and starve each other of water on a single pump.
- A bigger washer washes more for its hands, and the plant far more.
- The plant draws far more off the shaft than a washer.
- The pump tiers lift what they say, and a washer short of water washes less.
- The decant returns water to the reservoir and keeps the clay in the dam.
- Mass and energy close with the plant washing.

### Questions

1. **Four bays as slots**, or one washer part with a count?
2. **The tiers** above, and the washing plant as a slot of its own rather than a top washer tier?
3. **The pump as a tiered slot**, and the line shaft rated for the plant?
4. **The decant**: in 5d, an upgrade, or left to the dam's mechanics in 5f?
5. **A board per washer** — up to five — or one board for the whole washing floor?
6. **A bigger mud dam** as a tier now, or with the dam's bursting in 5f?

### Review decisions (5d, first pass)

1. **Bays**, as slots.
2. **No washing plant.** A plant is only a combination of washers, so the player assembles their
   own. Instead:
   - **Upgrades raise the bay count**: a floor starts with room for three, and its upgrades go up to
     five or six.
   - **A final log-washer tier** with double the Thomas's throughput, power draw and water draw.
   - **A later-era series washer** — trommel, then log washer, then attrition cell — with the final
     log washer's throughput, half as much power again, and **dramatically better efficiency**. It
     is what lets a pit scale its output enormously.
   - **A belt from the dump** — the mine's belt conveyor — so the dump → jaws → washers run, and
     other runs at the dump end, can be massively improved.
   - **Rock crushers.** A log washer could not take large lumps, so the jaws belong in the run.
3. *(Not answered: the pump tiers and the shaft rating are carried below as proposed.)*
4. **The decant is left to the dam's mechanics** (5f).
5. **A board per washer.** One board for the floor would make the perils hard to assess, and would
   need logic for distributing the work between the washers.
6. **The bigger mud dam is left to the dam's mechanics** (5f).

### Second draft (for review)

**What it adds**: up to six washer bays in a washhouse, two new washer tiers, a rock crusher ahead
of the floor, and a belt from the bin to the jaws.

#### The washhouse and its bays

- **The washhouse is a slot**, tiered on one stat, `bays`:

  | Washhouse | Bays |
  |---|---|
  | Washhouse | 3 (the default) |
  | Extended Washhouse | 4 |
  | Long Washhouse | 5 |
  | Double Washhouse | 6 |

- **Six bay slots**, each taking a washer:
  - **Bay 1** is required and starts with the single log washer, as the pit's washer does now.
  - **Bays 2 and 3** start empty.
  - **Bays 4 to 6** are built only when the washhouse has room for them.
- **What every bay shares**: the bin (or the crusher's hopper), the one water pump and the mud
  dam. So the bays compete for ore and for water.
- **What each fitted bay has of its own**: its washer, its hands, its board, and its caught-in-the-
  logs peril. All its ids are the bay's (`bay_2_washer`, `bay_2_hands`, `bay_2_board`), through
  `Names`, as an engine's are.

**Proposed: `Slot#needs:` gains a level.** A slot can be built only while the slot it names is
fitted **with a part whose stat reaches a figure**:

```ruby
Slot.new(id: :bay_4, accepts: :log_washer, needs: :washhouse, needs_at_least: { bays: 4 })
```

- **What changes**: one more check in `Assembly#active?`. The outfitting screen greys bay 4 with
  "with a washhouse of 4 bays".
- **The alternative**: one extension slot per extra bay, each a part that is only a gate. That is
  three slots that hold nothing, and it allows a fifth bay without a fourth.

#### The washer tiers

| Tier | Washes (wash ore) | Keeps | Work | Water | Hands | When |
|---|---|---|---|---|---|---|
| Single log washer | 1.7 kg/s | 80% | 6 kJ/kg | 3 kg/kg | 2 | the bottom |
| Thomas washer | 2.8 | 90% | 5 | 3 | 2 | as now |
| **Double Thomas washer** | 5.6 | 90% | 5 | 3 | 3 | the last log washer |
| **Series washer** | 5.6 | 97% | 7.5 | 3 | 3 | a later era |

- **Work and water are per kilogram**, so doubling the throughput doubles the draws. The double
  Thomas washer takes 28 kW and 17 kg/s of water against the Thomas's 14 and 8.4.
- **The series washer is one part and one `LogWasher`** at its own figures. The trommel, the logs
  and the attrition cell are its description, not three nodes. A tier's efficiency is still the one
  number for its losses (§16).
  - Its 97% cuts the Thomas's loss to under a third, and 7.5 kJ/kg is half as much power again.
  - It is unlocked late, through its blueprint's `requires:`. The achievement that unlocks it is
    named when the pit's blueprints are priced.
- **A full floor**:
  - **Washing**: six series washers take 33.6 kg/s of wash ore, which is more than an ore shovel
    digs.
  - **Output**: 8.1 kg/s of washed ore.
  - **Draws**: about 250 kW off the shaft and 100 kg/s of water.

#### Lumps, the jaws and the belt

**Why a washer needs crushed ore**: run-of-pit wash ore carries lumps the logs cannot take. This is
modelled **as the hands' rate, not as a particle size**:

| What feeds the bays | A bay's hands, each | Why |
|---|---|---|
| **The bin, uncrushed** (as now) | 1.0 kg/s | raking it in, and breaking the lumps with a sledge first |
| **The crusher's hopper** | 3.0 kg/s | raking crushed ore down a chute |

So without a crusher, a double Thomas washer with three hands is fed only 3 kg/s and runs at half
its rating. **The bigger washers pay off only behind the jaws.** That is the dependency you named,
and it needs no new state.

**The crusher is a slot**, empty to start:
- **What it is**: a holder on the line shaft, built as the washer is, with its work charged per
  kilogram crushed.
- **Where it sits**: between the bin and a crushed-ore hopper over the washhouse. The bays draw on
  the hopper while a crusher is fitted, and on the bin while none is. The pit is wired for this in
  its first pass, as it is for the machines.
- **The tiers**:

  | Crusher | Crushes | Work | When |
  |---|---|---|---|
  | Blake jaw crusher | 6 kg/s | 4 kJ/kg | 1858 |
  | Large jaw crusher | 15 | 4 | |
  | Gyratory crusher | 40 | 3.5 | 1881, later era |

  The figures are [gk] (research §2.10 has only Biwabik's 1,000 t/h gyratory), and are a sweep's to
  set.
- **Its peril**: caught in the jaws, for whoever feeds it, scaled by how hard it is turning, with
  `opportunity: true`.
- **Its board, in words**: crushing, choked, waiting on its feeders, stopped, nothing to crush.

**What feeds the crusher**:
- **The crusher feeders**, by hand: a gang shovelling from the bin into the jaws, 1.5 kg/s each, up
  to six. This is the crusher's own fragment, wired when no belt is fitted.
- **The feed belt**, a slot that `needs: :crusher`:
  - **What it is**: the mine's belt conveyor, from the bin up to the jaws, off the line shaft, with
    its feed as a lever and nobody on it.
  - **Why it needs the crusher**: a belt into a log washer would be the same lumps.
  - **What it gains**: the feeders' six places, and their limit.
  - **What carries over from the mine**: grip, the stall when fed past it, and the drum `Bearing`
    heating while it turns under a stalled belt. These are lifted out of `Mine` into the library so
    that both operations can fit them. The roadway roof and the spillage that lights stay the
    mine's, since limonite does not burn.
- **Other runs at the dump end**: the belt is written once, so a second run is a fragment.
  - **The spoil tip**: a belt from the tip head over the dump, ahead of the dumpmen.
  - **The washed ore**: carried to wherever 5i loads it out.

  Neither is in this draft (question 3).

#### Water, the shaft and the people

- **The pump becomes a tiered slot**:

  | Pump | Lifts | Enough for |
  |---|---|---|
  | Single pump | 8 kg/s | two log washers (as now) |
  | Duplex pump | 30 kg/s | a floor of Thomas washers |
  | Compound pump | 100 kg/s | a full floor of the top tier |

  All the washers draw on the one pump, which is what makes them compete for water.
- **The line shaft is rated for a full floor and a gyratory crusher**: about 20 kN·m at 22 rad/s,
  roughly 440 kW. The shaft is not the limit; the supply is, and behind the virtual shaft the
  supply is the match-maker's.
- **The reservoir is unchanged at 600 t.** A full floor of the top tier spends it in under two
  hours. That is the "monstrous washers" case 5b's review named, and the reason the larger
  reservoirs are an upgrade.
- **The dam**: a full floor fills it in about eight hours. What happens when it is full, and any
  decant, is the dam's (5f). Until then a full dam backs up every washer at once, because the dam
  is their one outlet.
- **Quarters**: a full floor is up to 18 washer hands and 6 crusher feeders, against quarters that
  seat 14 or 20. **Proposed: a barracks tier, seating 40**, as the first step of the personnel
  scaling 5c's review decided. The UI to manage that many stays the delivery tier's, later.

#### The panel

- **A board in words for each fitted washer**, in bay order.
- **A board for the crusher, and one for the belt** when they are fitted.
- **Washed ore, the reservoir and the dam**, unchanged. The reservoir and the dam are as bay 1's
  hands reckon them.

#### Specs (relational)

- **Bays**:
  - Two bays wash more than one from the same bin.
  - Bays starve each other of water on the single pump.
  - A bay beyond the washhouse's count builds nothing.
- **Washers**:
  - The double Thomas washer washes more than the Thomas, and draws more off the shaft.
  - The series washer keeps more of the ore than the double Thomas, and draws more off the shaft.
- **Feed**:
  - Behind a crusher, a washer's hands feed it faster than from the bin.
  - The crusher stops with the shaft.
  - The belt feeds the crusher with nobody at it, and stalls when fed past its grip.
- **Regressions**: the mine's belt is unchanged by the lift; mass and energy close with a full
  floor washing; a snapshot replays.

#### Questions

1. **`needs_at_least:`** on a slot, or an extension slot per bay? And are the washhouse tiers of 3,
   4, 5 and 6 bays right?
2. **Lumps as the hands' rate**: 1 kg/s each breaking lumps, 3 kg/s crushed, and the belt needing a
   crusher. Or should an uncrushed feed also wear the logs or choke them?
3. **The crusher and the feed belt in 5d**, with the other runs at the dump end (the spoil tip, the
   load-out) left to the to-do list? Or the spoil tip belt now?
4. **The pump tiers and the shaft rating** above (unanswered in the first pass)?
5. **A barracks tier for 40** in 5d, ahead of the rest of the personnel scaling?

#### Review decisions (5d, second draft)

1. **`needs_at_least:`**, with washhouses of 3, 4, 5 and 6 bays.
2. **An uncrushed feed also wears the logs faster.** A player may run that risk, and accidents
   from wear are interesting gameplay.
3. **The other belts at the dump end are deferred**; the crusher and its feed belt are in.
4. **The pump tiers and the shaft rating as proposed**, to tune later.
5. **The barracks, so a full floor can be staffed.** The UI comes later.

### Settled while building 5d

- **The pump fills a head tank**, and every washer draws on that. A conduit carries one path, so
  one pump cannot be linked to six washers.
- **A washer keeps two ticks of water in hand once this tick's has gone with the slurry.** Drawing
  two ticks ahead of what it held before washing left exactly one in hand. The share of water came
  out at 1 ± ε, and the board flickered "short of water" at full rating.
- **Bay ids are the bay's** (`bay_1_washer`, `bay_1_feed`, `bay_1_hands`, `bay_1_board`), and the
  reservoir and dam guesses are the first bay's hands'. Bay 1 is required.
- **The crusher is a conduit**, so a path runs bin → feeders or belt → jaws → hopper. Its work is a
  `hydraulic_w` priced per kilogram crushed, booked to `:work`.
- **The feed belt has no attendant and no peril.** Its hazard is the drum heating under a stall,
  read on its board. Its feed lever starts at half, because at full it pushes past its grip and
  stalls.
- **The figures**:
  - A full floor of six series washers, behind a gyratory crusher, a belt at half feed and the
    compound pump, washes about 20 kg/s of wash ore. It draws about 150 kW at the logs, 70 at the
    jaws, 19 at the pump and 2 at the belt.
  - Uncrushed, the single washer's logs lose about 0.09 of durability a second at full rating:
    about three hours to wear through.
- **On the rig's uncoupled line shaft a full floor sags it to about 18 rad/s.** That is the
  `Import`'s linear curve against the rating, not a limit on the pit. In a match the coupling
  sets the stiffness.
- **The series washer and the gyratory crusher are priced but not gated.** The pit has no
  achievements yet. The TODO in `blueprints.yml` names them as the first callers.

## 19. 5e — drainage and rain (for review)

**What it adds**: water into the pit, from the strata and from the sky; a sump at the bottom of the
pit; a pump on the line shaft lifting it out; water standing on the ore bench; drowning.

**The period's problem** (research §2.9): "In all the banks water has stopped work" (Lesley). A
sunk pit is below the water table and catches every storm. The Mesabi pumped 22–88 kg/s. The
colliery's pumps lift 14 and 26.

### Where the water comes from

- **Seepage from the strata**, into the sump:
  - **More the deeper the pit**: a rate a metre of the ore bench's depth below the surface, read
    off the bench's `depth_m`. A pit that is getting deeper is getting wetter.
  - **The ground is drawn per match**, a multiplier as the colliery's `Ground` draws its seeps.
    A dry pit and a wet one, and nobody is told which. The spread deliberately exceeds what the
    starting pump holds, as the colliery's does.
  - **Proposed figures**: about 3 kg/s at the median depth, from under 1 to about 7 across the
    draw.
- **Springs along the ore cut**, drawn as the hard stretches are and **hidden until met**
  (question 4). A spring is a position along the cut and a rate. Once the ore face reaches it, it
  flows for the rest of the match: a limestone cavern, the "hill-clay" broken into. None, one or
  two, at 2–8 kg/s each.
- **Rain on the pit** (`Nodes::Catchment`, the sky's `runoff`): the pit's footprint and the ground
  that drains into it, about 1,500 m², into the sump.
  - A spell of unsettled weather is under 1 kg/s.
  - A storm is 2–5 kg/s, by the match's severity.
  - Snow melting in a thaw counts as well, as the colliery's yard does.
- **Rain on the reservoir**, its own catchment, into the reservoir. This is the topping-up 5b
  promised. It is small, a few hundred square metres.

### The sump and the water on the bench

**`OpenPit::Sump`, a holder at the bottom of the ore bench**, shaped as the colliery's sump is:

- **The hole**: about 15 m³ dug below the ore floor. While the water is in it, nothing is wet.
- **Water on the floor**: past the hole it stands on the ore bench's floor. `flooding`, 0 to 1, is
  how deep, up to the **flood mark**, about knee-deep across the cut. It is what the ore gang
  sees.
- **Over the flood mark**: deeper, to over a man's head.

**Water on the bench makes the ore face harder** (question 2). The bench reports its face's
`hardness`, and the sump's water raises it, so the face contract 5c built carries it everywhere:
- The getters win less, as in a hard stretch.
- An ore shovel's cut costs its engine more: wet clay is heavy, sticky work. The period's dry clay
  against damp clay is 1,350 yd³ a day against 900.
- **At the flood mark the face is under water**, and nothing is won. The face's board says "water
  on the floor", then "the face flooded".

The stripping bench is above it and stays dry. Its water drains down to the ore bench.

### Drowning

**A peril of the flooded ore bench** (question 3), on the sump:
- **What it is**: going under in the water standing over the bench, a `breath` wound.
- **How it bites**: it scales with how far over the flood mark the water stands, so it is nothing
  at knee-deep and real by chest-deep.
- **Who it reaches**: whoever is on the ore bench (`places:`), with `opportunity: true`, because
  somebody can be pushed.

**Nobody is stranded.** An open pit's water rises slowly and its walls can be climbed, so the ramp
road does not close. The danger is a gang left posted at a face that has flooded, which is the
personnel game: somebody has to send them up.

### The pump, and where the water goes

- **A sump pump on the line shaft**, a tiered slot, lifting the ore bench's depth and up to the
  reservoir: the colliery's displacement `Pump` pattern, nothing with the shaft stopped.

  | Pump | Lifts | When |
  |---|---|---|
  | **Lift pump** | 6 kg/s | the bottom tier: an ordinary pit, but not a storm on a wet one |
  | **Plunger pump** | 15 kg/s | a wet pit through a storm |
  | **Centrifugal pump** | 40 kg/s | a later era: a wet pit that has met its springs |

  At 10 m these are a few kilowatts. The pit's water is a volume problem, not a power problem.
- **The pumped water goes to the reservoir** (question 1), so draining the pit feeds the washers.
- **The reservoir gets a spillway**: what is over its crest runs off to drainage (`Delivery`, as
  the colliery's drainage is). A reservoir full in most matches would otherwise refuse the pump,
  and the pit would flood behind a full reservoir.
  - `OpenPit::Spillway` is a conduit that passes only what its holder holds over the crest.
  - TODO, for the larger reservoirs: the spillway is where an overtopped bank would start.

**Without its shaft turning, the pit now floods.** That is the line shaft's point. In the dev match
it is roped to the developer's engine only with `REACTOR_DEV_ENGINE=1`. Without that, a hand pit's
ore face drowns over a long match, faster on a wet draw.

### The people

No new post. The pump is a lever on the shaft, as the colliery's is, and the water is the ore gang's
to see.

### The panel

- **The sump**, in the ore gang's words: dry, water on the floor, the face flooded, over the bench.
- **The pump's board**: pumping, dry, stopped.
- **The reservoir**, unchanged, now able to rise.

### Specs (relational)

- **Seepage**: more in a deeper pit, and more on a wet draw. A pinned ground draws the median and no
  springs.
- **Springs**: a spring flows once the ore face has passed it and not before. Across many draws:
  none, one or two, within reach.
- **Rain**: rain on the pit reaches the sump, and none falls on a dry day.
- **The bench**:
  - Water on the floor makes the ore face harder, for getters and for a shovel alike.
  - At the flood mark nothing is won, and the board says so.
- **Drowning**: the peril bites only over the flood mark, and on the ore bench only.
- **The pump**:
  - It lifts the sump into the reservoir only while the shaft turns.
  - The bigger tiers lift more.
  - The spillway passes only what is over the crest.
- **The books**: mass and energy close with rain falling and the pump lifting; a snapshot replays.

### Questions

1. **Pumped water to the reservoir, with a spillway**, or straight to drainage? Into the reservoir
   ties the pit's water to the washers' and costs one small node.
2. **Water on the bench as the face's `hardness`**, through 5c's face contract, so the getters and
   a shovel both feel it and both stop at the flood mark? The alternative is a separate wetness
   term in each.
3. **Drowning as a peril of the flooded bench**, rather than the colliery's way, where the room's
   air is lost and the ways out close? An open pit is climbed out of, so stranding would be wrong.
4. **Springs met along the cut**, hidden until met, in 5e? Or ordinary seepage only, with the springs
   later?
5. **The bottom tier is a pump on the shaft**, or a bailing gang by hand, with the pump as the first
   upgrade? Bailing would put the drainage in the personnel game from the start, at the cost of a
   gang the pit does not yet seat.

### Review decisions (5e)

1. **The reservoir, with a spillway.**
2. **Water on the bench as the face's hardness.**
3. **A peril, but with the drowning itself on the asphyxiation pathway.** Somebody in an open pit
   only starts to drown once they are exhausted and stop treading water.
4. **Springs from the start.**
5. **A drainage gang to start; every pump is an upgrade.**

### Drowning, resolved

**Deep water tires; exhausted, you go under; under, you are not breathing.** That is the
colliery's suffocation exactly, with the water standing in for the bad air:

- **`Place#water:`** names a holder answering `deep?` — for the ore bench, the sump.
- **Treading water is exertion with no post**, as a fight is. Anybody in a deep place tires at
  `Breath::TREADING` over their endurance, with no recovery, and a load on them makes it worse
  (`Burden`, as hauling). Fatigue's `fighting:` term becomes `exerting:`, for both.
- **Exhausted in deep water, they go under**: their place reads no breathable air for them. From
  there it is `Breath` unchanged — the collapse, the asphyxia clock, a severe breath wound and
  then a mortal one. The event's cause is `drowning`.
- **The wound is the drowning one.** Breath's variants line up by place across the tiers, and the
  third is choking, then drowned, so a drowning names that variant (`Injury.succumb(variant:)`).
- **Got out in time, they recover**: out of the deep place the clock drains, as it does in good
  air. Going down the ramp for somebody is worth doing.
- **The peril stays for going in**: stepping off into the water over the flood mark, a minor
  breath wound, scaled by how far over the mark it stands, with `opportunity: true` — somebody
  can be held under.

### The drainage gang

- **Bailers at the sump**, a worked conduit from the sump up to the reservoir: buckets and a
  windlass, about 0.8 kg/s a man, a gang of four. A full gang just holds an ordinary pit on a dry
  day. A wet draw, a storm or a spring is beyond it.
- **They stand at the sump on the ore bench**, so a flooded bench is theirs first.
- **The sump pump slot is empty to start**; the lift, plunger and centrifugal pumps are upgrades.
- **The bailers stay a post with a pump fitted**, so a pit in trouble can bail as well as pump.
- The starting hut seats the starting gangs, so a pit with bailers posted is a pit with somebody
  else stood down. That is the personnel game the gang was chosen for.

### Settled while building 5e

- **`drowning` is a cause** (`Wounds::CAUSES`), so `drowning_resistance` resists it as
  `rockfall_resistance` resists a fall of rock. In the water it is less treading, and at 1.0
  somebody never goes under: a cork jacket, a race at home in the water. A rebreather needed
  nothing, because `respirator` already masks going under as it masks bad air.
- **The peril of going in is an impact, not a breath wound**: off the bench edge into the water,
  onto what lies under it (`causes: fall`). No other hazard deals a continuous kind through the
  Danger Check. One that did would leave a second breath wound beside the one the asphyxia clock
  deepens, so the drowning stays the water's alone.
- **The drowned wound is named** (`Injury.succumb(variant:)`, `Wounds::Catalogue#place_of`). Breath's
  variants hold the same place through the tiers, so it deepens from choking to drowned.
- **Fatigue's `fighting:` term is `exerting:`**, the work at no post a brawl and treading water
  share.
- **The figures**:
  - Ordinary ground seeps 3.0 kg/s at the median depth, and four bailers just hold it.
  - Water halfway to the flood mark makes the ore face a quarter harder.
  - Two getters left posted in deep water at fatigue 0.9 drown inside 100 seconds.
- **No pump board.** The sump guess says what the pump is not keeping up with, and the pump is a
  lever on the panel. A board can follow if the water wants one.

## 20. 5f — benches and slides (for review)

**What it adds**: faces that slide when they are undercut, and a spoil dump whose edge breaks back
— the pit's commonest killers (research §5: "falls or slides of rock or overburden" were the major
cause of quarry deaths). The mud dam is left out of this draft (question 5).

### The face hangs as it is dug

**Digging at the toe leaves the face overhanging it**, by hand or by shovel:
- **`overhang_kg`, on each bench**: the ground above that has lost its support. It grows by a share
  of everything dug off the bench, `UNDERCUT` (about a quarter), whoever dug it. A shovel digs
  sixteen times as fast as a hand gang, so it undercuts sixteen times as fast.
- **Barring down brings it down safely**: a new post at each face, the **barmen**, prising the
  overhang off with bars at a rate a man. What they bring down falls into the face's muck — the
  same ground, taken while nobody is under it.
- **Left hanging, the face slides.** Each bench draws its own thresholds per match — the overhang it
  will hold before it goes — as the colliery's goaf draws its spans:
  - **Triangular, not log-normal**: no transcendental, as 5a's thicknesses are.
  - **The first is the largest.** A fresh face holds more than one that has slid before.
  - **A taller bench holds less**: the threshold over the bench's thickness against its median.
  - **Water takes it away.** The sky's `wet` lowers it for both benches, and the ore bench's toe in
    standing water (5e's `flooding`) lowers it further. A wet pit in a storm is a pit that slides.
  - **Nobody is told where it is.** The getters and barmen see the face hanging, and the board says
    "the face hanging" past a share of the threshold. That share is the warning, and the counterplay.

### What a slide does

**A slide moves no mass** (question 3). What comes down was the bench's, and it stays the bench's:
- **It buries whoever is at the face**: a hazard on the bench's place, crush and `rockfall` (so a
  helmet helps), scaled by the overhang that came down. It reaches the getters, the barmen, the
  pitmen and the craneman, and a train standing at the face through its footplate (4c's `shares:`).
- **It wrecks what is under it**: a share of a fitted shovel's boom, by the size of it
  (`failure_damages`).
- **The slipped ground is the next dig** (`buried_kg`), loose and quick to get — a lower hardness —
  while the board says "digging out a slide". The face is a mess, not a wall.
- **The overhang resets**, and the face starts hanging again toward the next threshold.

### The dump breaks back

**A dump's edge takes load as spoil is tipped on it**, and gives it up as it settles:
- **`edge_load`, on the spoil dump**: grows with every kilogram tipped onto the tip head, and faster
  in the wet (`wet`, and the ground's drawn `wetness` from 5e: water under a dump "caused sudden
  sloughing"). It settles back with time, a few tens of minutes.
- **So steady hand tipping never breaks it back, and a train tipping every few minutes in a storm
  does.**
- **Past a threshold drawn per match, it breaks back**:
  - A hazard on the spoil dump's place, crush and `fall`. It reaches the dumpmen, and a train
    standing at the dump through its footplate.
  - The tip head's spoil goes down the face of the dump, into the spoil dump in one tick, so the
    tip head is empty and the dump is the same mass.
  - The edge load resets.
- **The dumpmen see it coming**: "cracks behind the edge" on a new board, past a share of the
  threshold. Standing them down, letting it settle, not tipping in the rain — that is the
  counterplay.

### The people

| Post | Where | Kind | Does |
|---|---|---|---|
| **Barmen**, a gang a face | each bench | effort (`force`, `swing`) | bar down the hanging face into the muck |

- **Their peril**: struck by what they bring down, by how hard they are barring, with
  `opportunity: true`. It is a dangerous job made less dangerous for everyone else.
- **Two a face to start.** The starting hut seats the starting gangs, so barmen are somebody else
  stood down — the personnel game again.

### The panel

- **Each face's board** gains "the face hanging" and "digging out a slide".
- **The dump's edge, in the dumpmen's words**: sound, cracks behind the edge.

### Specs (relational)

- **The overhang**: it grows with what is dug, faster for faster digging, and the barmen bring it
  down into the muck.
- **The thresholds**: across many draws, the first the largest; a taller bench, and a wet one,
  holds less. A pinned ground draws the median.
- **A slide**:
  - It comes when the overhang reaches the threshold, and not before.
  - It hurts whoever is on that bench and nobody on the other.
  - It wrecks a share of a fitted shovel's boom.
  - The slipped ground digs easier, then the face is as before.
- **The board** says the face is hanging before it goes.
- **A breakback**:
  - The edge loads faster wet, and settles with time.
  - It breaks back at its threshold, hurting whoever is on the dump.
  - The tip head's spoil goes into the dump.
- **The books**: mass closes through a slide and a breakback; a snapshot replays.

### Questions

1. **Overhang against a drawn, hidden threshold, warned on the board**, the goaf's pattern — or wear
   on the bench (`Wearing`), as the colliery's roadway does?
2. **The barmen as a post of their own** at each face, or barring done out of the getters' own
   effort (and the pitmen's on a shovel face)?
3. **A slide that moves no mass** — it hurts, it wrecks, and the slipped ground is the next dig — or
   a debris pile that blocks the face until it is cleared? The pile is truer, and it means a shovel
   face waits on barrows, because a dipper digs the bench, not the muck.
4. **Breakbacks driven by tipping in the wet and relieved by time**, warned by the dumpmen?
5. **The mud dam** — its filling, its bursting with counterplay, the decant and the bigger dams 5d
   left it — **a sub-unit of its own** after this one, or in 5f? It is a water system, not a face,
   and it ties to the larger reservoirs.

### Review decisions (5f)

1. **Hidden thresholds**, each a unique event: after a slide or a breakback the next threshold is a
   fresh draw, not the last one again.
2. **The barmen are a post of their own**, because otherwise the player has no balancing lever.
3. **A debris pile.** A slide brings the overhang down onto the face, and the face is buried until
   the pile is cleared.
4. **Breakbacks as proposed.**
5. **The mud dam is its own system, after this one.**

### The pile, resolved

- **A slide moves the overhang off the bench into a slip pile at the face**, through a conduit that
  passes what the bench has slipping, the way the colliery's shot brings its coal down.
- **While the pile holds anything the face is buried.** It offers nothing (`uncovered_kg` is
  nil-or-zero, as at the flood mark), and the board says "buried by a slide".
- **The pile drains into the muck**, so the barrows and the loaders clear it. **With a shovel fitted
  it drains into the shovel's reach as well**, so the dipper digs it out. A shovel's reach is a
  holder the pitmen fill from the face, and the pile is just as good a source. So a shovel face
  is dug out in minutes, and a hand face waits on its barrows.
- **A breakback is the same shape at the dump**: the tip head's spoil goes down a conduit into the
  spoil dump, and the tip head is broken back while it does.

### Settled while building 5f

- **Each slide and breakback is a part failure that heals itself**: `overload?` past the threshold
  raises it, the event carries the overhang or the edge load the hazard scales by, and on the next
  tick the node brings the ground down, takes the next threshold off its run and clears the
  failure. This is the goaf's pattern.
- **Sixteen thresholds are drawn at once**, each its own triangular draw about the median, so no two
  are the same and one slide says nothing about the next.
- **Bench ports**: `:out` (getting and moving up, which undercut), `:barred` (the barmen, which
  relieve) and `:slide`. The overhang is reckoned from what left each port in the same tick.
- **The slip pile drains into the muck at once**, as far as the muck has room. A slide therefore
  overfills the face's muck, and the face is buried for as long as the barrows take to clear the
  rest. With a shovel the pile drains into its reach too.
- **The figures**:
  - The median threshold came down from 3 t to 1.2 t (the first 1.5 times that). At 3 t a hand face
    took hours to slide, and the barmen would never matter in a 30–60 minute match.
  - Now an unbarred hand face goes in about an hour, sooner wet, and an unbarred shovel face every
    few minutes.
  - The slide's weight is 1.6 against its median. At 6, a 1.8 t slide killed all seven at the face;
    at 1.6 it breaks bones.
- **A board's starting signal names its quiet state** (`getting`, `nothing to wash`), not index 0:
  putting new signals first in a list made index 0 read "the face flooded" and "logs broken" before
  the first tick.

## 21. 5g — the mud dam, and the reservoir's bank (for review)

**What it adds**: the mud dam as an embankment that holds a settling pond and can fail, a decant
that gives its water back, bigger dams, and larger reservoirs with a bank that can rupture.
**Every failure here can be seen coming and headed off** — the review's condition for both
(§16, decision 4).

**The period** (research §2.2): the Thomas washer's slurry "floats off to a mud-dam on trestles",
and the settling ponds survive as clay deposits. A tailings dam fails three ways:
- **Overtopping**: the pond comes over the crest and cuts through it.
- **Piping**: water working through a wall that has stood wet too long, seen first as a weeping toe.
- **Slumping**: a saturated wall going.

The counterplay was always the same: keep the pond down, and keep the wall made.

### Where they stand

**A new place, the dams**, a walk from the bank, holding the mud dam and the reservoir.
**It stands above the pit** (question 1), so whatever a breach lets go runs down into the sump. 5e's
water then does the rest — the ore bench floods, and whoever is posted there is out of their
depth.

### The pond settles

**What the dam holds is clay, the limonite lost with it, and water.**
- **The water settles out on top**: free water, less what the settled clay keeps in its pores (about
  0.6 kg a kilogram of clay).
- **A decant** gives the free water back (question 3). It is a gate the player sets (`decant`, a
  lever) on a conduit from the dam to the reservoir, passing only free water.
- **So a full washing floor's dam fills by its clay**, about a third of what it receives, and not by
  its water — and the reservoir gets most of its water back. The decant is the answer to the
  reservoir running down under a big floor (5d) as well as to the dam filling.

### The wall

**`OpenPit::Embankment`, a holder whose wall can fail**, one class for the mud dam and the reservoir
(question 2):

- **Wet against the wall, the wall weakens.** The wall wears by how far the pond stands above a safe
  fill (about 60%), squared. The fuller it is held, the faster it goes. Its starting strength is the
  usual hidden roll (`Wearing`), so nobody knows how long it will stand.
- **The dam hands heal it**: puddling the wall with clay, a post at the dams, at a rate a man. It is a
  wall kept made, which is the period's work.
- **The wall tells you first**, in the dam hands' words: sound; weeping at the toe (integrity under a
  half); slumping (under a fifth); breached.
- **Over the crest, it breaches at once**: overtopping, `overload?` on contents past the crest. You
  can see it coming on the dam's level gauge, and nothing hidden decides it.
- **Breached** (`Nodes::Breach`, opened by `breached`): the pond's free water runs into the sump. It
  carries liquid only, so the clay stays where it settled.
  - Whoever is at the dams is hurt: swept off the wall, impact.
  - The pit takes the water.
  - Washing goes on pouring through the hole into the pit until somebody stops it.
- **Rebuilt in the match** (question 5): the dam hands' puddling brings a breached wall back, and once
  it is whole again the breach shuts, as `Breach` already does when a failure clears.

### Bigger dams, bigger reservoirs

| Dam | Holds | Wall | Note |
|---|---|---|---|
| **Mud dam** | 3,000 m³ | as now | a starting floor never troubles it |
| **Raised dam** | 6,000 m³ | a little weaker for its height | |
| **Settling ponds** | 12,000 m³ | two walls in one: stronger, slower to weep | the last tier |

| Reservoir | Holds | Its bank |
|---|---|---|
| **Reservoir** | 600 t | wears so slowly no match sees it |
| **Large reservoir** | 2,000 t | wears when held full |
| **Great reservoir** | 6,000 t | wears faster, and lets go far more |

- **The reservoir is the same embankment**, its safe fill higher (about 80%), with its spillway at the
  crest as now.
- **A scour valve** on the larger ones, a lever, lets the player draw it down to drainage. Water
  spent to spare the bank — the trade.
- **Reservoir bankmen**, a post that comes with a larger reservoir, puddle its bank as the dam hands
  do the dam's. The bottom reservoir needs none.

### Starting state

**The dam starts part full**, drawn per match (question 6): the clay of the seasons before, about a
fifth to two-fifths, mostly settled, with a little free water on top. The reservoir starts as 5b
drew it.

### The people

| Post | Where | Kind | Does |
|---|---|---|---|
| **Dam hands** | the dams | effort (`force`, `swing`) | puddle the mud dam's wall, and rebuild it breached |
| **Reservoir bankmen** | the dams | effort | puddle a larger reservoir's bank (with the part) |

Their peril is the wall they stand on: swept off when it breaches, and the hazard reaches the dams.

### The panel

- **The dam**, as now, in its level's bands, adding "over the crest".
- **The dam's wall** in the dam hands' words: sound, weeping at the toe, slumping, breached.
- **The reservoir's bank** in the bankmen's words, with a larger reservoir.

### Specs (relational)

- **Settling**: the decant passes the dam's free water and leaves the clay and its pore water; it
  gives nothing with the gate shut.
- **The wall**: it wears held above its safe fill and not below; the fuller the faster. The dam
  hands heal it. Its board weeps before it breaches.
- **Overtopping**: past the crest it breaches at once.
- **A breach**: the free water runs into the sump, the clay stays, whoever is at the dams is hurt. A
  rebuilt wall shuts it.
- **Tiers**: a bigger dam holds more; a larger reservoir's bank wears where the small one's does
  not; the scour valve draws it down.
- **The books**: mass closes through a breach; a snapshot replays.

### Questions

1. **The dams stand above the pit**, so a breach floods it through the sump — or does it run off the
   site, hurting only whoever is at the dams?
2. **One `Embankment` for the dam and the reservoir**: wear by fill above a safe level, healed by a
   post, warned in words, overtopping at the crest?
3. **The decant to the reservoir**, a gate passing only free water?
4. **The tiers above**, and a scour valve on the larger reservoirs?
5. **A breached wall rebuilt by the dam hands in the match**, or gone for the match?
6. **The dam starting part full**, a fifth to two-fifths, drawn — or empty?

### Review decisions (5g)

1. **The dams stand above the pit.** Flooding the pit is the entire point.
2. **One `Embankment`**, as proposed.
3. **The decant to the reservoir**, as proposed.
4. **The tiers and the scour valve are a start.** Proper spillways and relief can come later if
   needed.
5. **Rebuilt in the match.**
6. **The dam starts part full**, drawn, as proposed.

### Settled while building 5g

- **`Embankment` is a self-healing failure, as 5f's are**, but healed by people rather than at once:
  puddling puts durability back at a rate a man, and a breached wall whole again clears its failure,
  which shuts the `Breach` with no code of its own.
- **Overtopping is past 99.5% of the vessel's volume.** A reservoir has a tenth of freeboard over
  what it is built to hold, so its spillway holding it at the crest does not count as coming over the
  top.
- **The dams are their own place**, so the dam hands' peril and a breach's hazard reach them and
  nobody at the bank.
- **The decant gate starts half open.** The starting pit never notices it; a full floor needs it.
- **The figures**:
  - A dam held at 96% full with nobody on it breaches in about an hour.
  - Three dam hands put back 0.45 a second, which holds a full dam and rebuilds a breached wall from
    nothing in about forty minutes.
  - A great reservoir held full by its spillway goes in about fifty minutes, and its three bankmen
    just hold it.
- **The washing spec's dam is no longer empty to start**, so it measures what the washer added to it.

## 22. 5h — blasting and hard ground (for review)

**What it adds**: an answer to 5a's hard stretches — powder in the face — and the hard ground winter
adds, frost; with what blasting brings: flyrock, misfires, gopher holes, and dynamite that freezes.

**The period** (research §2.6):
- **Black powder in hand-drilled holes** wherever the ground was hard. Clay and soft slate needed
  none.
- **Gopher holes on the Mesabi**: man-sized, heavy charges, which "caused frequent accidents".
- **Dynamite from 1867.** It freezes at about 8 °C, and frozen it misfires and is dangerous to handle.
- **Frost runs 3–8 ft into the banks** and is opened with powder.
- **Blasting takes about 6% of operating time** (Marsh).

### A shot breaks the ground ahead

**Blasting does not bring ground down as mass. It loosens what the face is about to dig**
(question 1):
- **`broken_kg` on each bench**: ground ahead of the face a shot has loosened.
- **While the face is in broken ground, it reads loose**: a hardness under ordinary, whatever
  stretch or frost it is in, so the getters and a shovel both go faster. The digging uses up the
  broken ground first.
- **So powder is the answer to a hard stretch, and worth having in ordinary ground too.** Broken
  ground digs faster than ground in the bank, as the period's figures for hardpan after blasting say.

### The powder gang and the shot

**A blasting slot, empty to start**, its part the method and the explosive. **Each face gets a
powder gang** — drilling, charging, firing — a post that **needs the Shotfirer's Ticket**, the
colliery's, because it is the same trade:

| Blasting | A shot breaks | A hole takes | Peril of its own |
|---|---|---|---|
| **Jumper holes**, black powder | about 2 t | about 10 min | — |
| **Gopher holes**, black powder | about 8 t | about 25 min | the hole falling in on the man in it |
| **Dynamite shots** | about 8 t | about 12 min | it freezes (below) |

**The shot fires on the player's word** (question 2):
- A charged hole waits for **the fire lever**, a lever at each face, and the board says "charged —
  ready to fire".
- That gap is the player's to clear the range in. Fired with the lever left at fire, the gang fire
  as soon as each hole is charged.
- Its fumes go up into the open air, booked, as the colliery's shot fumes do.

### What a shot can do

- **Flyrock**: on firing, a hazard across the pit by distance — the face it fires at heaviest, the
  other bench less, the haul road and the bank least — and by the size of the shot. It reaches
  whoever was not cleared. That includes a shovel's crew and a train standing at the face, through
  its footplate.
- **Misfires, as the colliery's**: the powder gang's judgement splits one peril (`judged:`).
  Recognised, the misfire is dug out, and may go off on them. Misjudged, it is left live in the face,
  and whoever digs there strikes it: the getters, or a shovel's dipper, which sets it off under its
  crew.
- **A premature shot**, going off on the gang while they charge.

### Frost

**In freezing weather the benches freeze** (question 4):
- **`frost`, on each bench**: grows while the air is below freezing, faster the colder, and thaws
  above it.
- **A frozen face reads harder**, up to several times over.
- Blasting breaks it, as it breaks a hard stretch.
- A winter match with no powder is a slow one.

### Dynamite freezes

- **The magazine is at the bank, in the weather**, and its dynamite is at the magazine's temperature.
- **Below 8 °C it is frozen**: a frozen charge misfires several times as often.
- **The thawing house** (question 5): a heated magazine, its heat a lever.
  - Too low, the dynamite freezes.
  - Too high, the nitroglycerin exudes, and the magazine can go off: a blast at the bank.
  - The period's 101 thawing accidents, as a lever to set.

### The people

| Post | Where | Kind | Does |
|---|---|---|---|
| **Powder gang**, a gang a face | each bench | effort (`precision`, `intelligence`), complexity, the Shotfirer's Ticket | drill, charge and fire; dig out a misfire |

- **The fire lever**, at each face: a lever, not a post.
- **The starting hut seats the starting gangs**, so a powder gang is somebody else stood down.

### The panel

- **Each face's board** gains "charged — ready to fire" and "in broken ground".
- **The powder gang's board** at each face: drilling, charged, fired, a misfire to dig out.
- **The magazine**, with dynamite: in the powdermen's words, thawed or frozen.

### Content

- **`dynamite`**, an `explosive`, with its firing reaction: mostly gas and steam, and the kieselguhr
  left behind.
- **`black_powder`**, the colliery's.

### Specs (relational)

- **Broken ground**: a shot leaves the bench broken ground ahead, and the face digs it faster than the
  bank, a hard stretch included.
- **The gang**: it charges only at its post, the hole waits for the fire lever, and a bigger method
  breaks more for longer.
- **Flyrock** reaches the firing bench hardest and the bank least, and only on firing.
- **Misfires**: recognised it waits to be dug out; misjudged it is struck by digging.
- **Frost** builds below freezing, thaws above, and hardens the face.
- **Dynamite** misfires more frozen. With the thawing house, too hot is a hazard.
- **The books**: mass and energy close through a shot; a snapshot replays.

### Questions

1. **A shot as broken ground ahead** — loosened, dug faster — rather than ground brought down onto the
   muck?
2. **Firing on a lever**, the player clearing the range themselves, with flyrock across the pit by
   distance?
3. **One blasting slot** (jumper holes, gopher holes, dynamite), and **a powder gang at each face**
   needing the Shotfirer's Ticket?
4. **Frost in 5h**, as hardness that builds below freezing and thaws?
5. **The thawing house now**, or dynamite freezing now with the thawing house later?
6. **The colliery's `ShotHole` lifted into a shared node** — it is wired to the colliery's own posts
   (`:shotfiring`, `:hewing`, the pick line) — or a pit version beside it? Lifting it means the
   colliery's posts become configuration, with the colliery's behaviour unchanged.

### Review decisions (5h)

1. **A shot breaks the ground ahead.**
2. **Firing on a lever**, with flyrock across the pit by distance.
3. **One blasting slot and a powder gang at each face.**
   - **An unticketed gang still works**, at a much higher risk of accident.
   - **The holes take half as long** as drafted, or a player fires one a match at most and the
     mechanics hung on a shot are worth little: jumper holes about 5 minutes, gopher holes about
     12, dynamite about 6.
4. **Frost in 5h.** Its main reason to exist is to make blasting a necessity at times.
5. **The thawing house now.**
6. **`ShotHole` lifted into a shared node.** Other mines will have it.

### Settled while building 5h

- **`Nodes::ShotHole` is the colliery's, configured.** Its posts are now `fired_by:` and `struck_by:`
  (a post and the node whose crew it is counted against), and its figures are `shot_s`, `clear_s`,
  `yield_kg` and `blown_out_yield`. Added for the pit: `fire_control:`, `charge_from:` with
  `freezes_below_k:`, a `charged` status at the end of the list, and `:frozen` and `:flying`
  activities. `Mine::ShotHole` supplies the colliery's posts and figures. A colliery run through a shot of
  each tier is bit-identical once its renamed key is put back (`hewing` became `struck`).
- **An unticketed gang has more accidents through perils of its own**, `unless_tagged: :shotfirer`:
  a premature shot five times as often, and a charge misjudged and left live three times as often.
  A ticket only spares slips at a lever, and a shot's accidents are perils.
- **Flyrock is perils with rates in the hundreds** during the two seconds after a shot. A shot is
  seconds under falling rock, and a margin of 0.35–2.6 spent at that rate is gone at the face fired
  at and dented across the pit. It reaches places, so a train's footplate is not on its list.
- **A charge goes off in a small vessel at its face**, hosting the firing reactions, its fumes
  venting to the atmosphere through a conduit, its residue staying.
- **Frost starts where the season leaves it**: a bench that has not yet seen the sky takes the frost
  of the first air it sees, at once; after that it moves over half an hour. Winter's mean is above
  freezing, so frost is a cold snap's and a night's, as intended — blasting a necessity at times.
- **The thawing house wears through its vessel's own over-temperature** (`max_temperature_k` at
  45 °C, `stress_rate`), and its going up is the vessel's rupture, a blast across the bank. Its
  dynamite is not consumed when it goes; it is the hazard that is modelled, not the charge.
- **The hole times are halved from the draft**: 5 minutes a jumper hole, 12½ a gopher hole, 6 a
  dynamite shot. The colliery's hole is halved with them, to 7½ minutes.
- **The thawing house goes up with what is in it**: its rupture opens a breach that sends every
  charge in it to where it fires, its fumes away, and the hazard across the bank scales by the
  `charge_kg` it held. An empty house going up hurts nobody.
- **A train's crew at the face is under its flyrock**: a peril of a place reaches whoever is on a
  carried place standing there, at its `shares:` — the rule hazards already followed, now in
  `Tick#weigh`. The train's own perils are keyed by station, so its crew is not struck by it.
