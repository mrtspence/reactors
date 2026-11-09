# Lighting for night work (for review)

> Input to a decision, not a description of the system. The first of three units decided in the
> open-pit lookover (2026-11-01): lighting, then the blast whistle, then the UI overhaul. This
> draft covers lighting only.

## 1. What there is now

- **Light is a gate.** Every job in the pit is `gated_by: darkvision`, which multiplies: no light,
  no work, however strong the gang.
- **Where it comes from**, taking the better of the two, never the sum (`Minion#gate`):
  - **The place**: the sky's `daylight` times the place's `exposure`, and anything standing there
    that answers `ambient_tags` (`Tick#ambient_tags`).
  - **The person**: a lamp they carry. `miners_tools` carries 0.5 with its pick, `hand_lamp` 0.35,
    `crude_miners_tools` 0.1.
- **How dark it gets.** A match starts at a drawn hour. About one in ten is a night shift, dark
  throughout, and about a quarter start in the afternoon, so many cross dusk. Daylight falls
  through twilight to zero; `Outdoors` reports `:nightfall` and `:daybreak`, and every panel has
  "The Light" as somebody's guess.
- **So a pit at night today** works at whatever lamp each person carries, at best half pace, and
  anybody without one does nothing. Nothing lights a place.
- **The colliery already lights a place.** `Mine::Lighting` is a `Load` offering `darkvision` to the
  district: candles, oil flares, gauze lanterns, electric lamps on a dynamo off the line shaft. Its
  lever is a standing order at bank.

## 2. The period [gk throughout; to check before figures are fixed]

- **Fires.** Night work in cuttings and pits was lit by coal fires in iron baskets (cressets,
  braziers) on stakes along the work. Cheap, dim, smoky, fed from the coal heap.
- **Oil flares.** The **Wells light** (from about 1885): heavy oil forced by a hand pump to a
  burner, a flame of a few thousand candlepower on a tripod. The standard for night work on
  railway, dock and canal construction, the Manchester Ship Canal among them. It burns about a
  gallon or two of oil an hour and wants a man to pump it up and fill it.
- **Arc lamps.** Electric arcs on poles, from a dynamo, from the 1880s: the Forth Bridge was built
  through the night under them, and the Mesabi pits ran night shifts under arc lights by the 1900s.
  The carbons burn down over hours and are trimmed.
- **The machines carried their own.** A steam shovel had a headlight, kerosene and later electric.

## 3. The proposal

### 3.1 A light is a shared node

**`Mine::Lighting` moves into the library as `Nodes::Lighting`**, configured, as `ShotHole` was:

- A light offering `darkvision` to the place it stands in: its `illumination` × its lever × its
  shaft's speed share if it has a shaft × its derating.
- A flame if it is one (`flame:`), with the colliery's gauze as configuration (`gauze_passes_m_s:`,
  `draught_from:` with no default).
- A dynamo light wears and blows when over-run, as the colliery's do.
- **The colliery's four tiers stay bit-identical**, configured onto it.

This is the shape-written-twice rule: the pit is the second caller.

### 3.2 Where the pit is lit: two areas

**Proposed: two slots, each lighting an area.**

| Slot | Lights |
|---|---|
| **Pit lighting** | the stripping bench, the ore bench, the haul road |
| **Bank lighting** | the bank, the spoil dump, the dams, the kiln's top and foot |

Each is **empty to start**, as today. Each has a **lever at bank** ("Pit Lights", "Bank Lights"),
default off: lighting costs fuel or power, so it is lit at dusk as a standing order.

**Alternatives:**
- **(a) One slot lights the whole site.**
  - *For*: one decision, one lever.
  - *Against*: no choice of where. A player cannot light the faces and leave the dams dark.
- **(b) A slot per place**, eight of them.
  - *For*: the finest choice.
  - *Against*: eight slots and levers on an outfitting screen already too long to use. The UI
    overhaul may make this affordable later.

**Recommended: two areas.** It is a real choice — the faces make the ore, the bank holds the washing
and the kiln — for two slots.

### 3.3 The tiers, and what each costs

| Tier | Light | Runs on | Its trouble |
|---|---|---|---|
| **Fire baskets** | dim, about a candle's (0.35) | coal from the yard, carried and stoked | burns down unless fed; smoke |
| **Wells lights** | bright (0.75) | fuel oil from an oil store | runs dry unless pumped and filled |
| **Arc lamps** | daylight's equal (1.0) | a dynamo off the line shaft | dark when the shaft is; carbons burn down; blows when over-run |

The light figures follow the colliery's scale (candles 0.35, flares 0.75, electric 1.0), so a
lamp is worth the same in either operation.

**How each is built:**
- **Fire baskets are a fire, so they are a `FuelBed`** (the rule from the lookover): a bed of yard
  coal on a grate in the open, its air from the atmosphere. Its light is its fire: `illumination`
  times its lit coal against what a well-fed basket holds alight. Unfed, it burns down over
  minutes and dims.
  - **Alternative**: a fiat light that consumes coal at a rate while lit.
    - *For*: one node, no air path.
    - *Against*: a fire that cannot burn down is not a fire, and it is the copy the rule forbids.
- **Wells lights are a `Nodes::Lighting` with a flame**, drawing fuel oil from an **oil store** (a
  new sized holder at bank, as the coal yard is) through a feed only the lamp man works. Out of
  oil, out.
- **Arc lamps are a `Nodes::Lighting` on the line shaft**, as the colliery's electric lamps are: a
  drag on the shaft, dark with it stopped. Their carbons are `Wearing` while lit, and dim as they
  wear; trimming puts them back.

### 3.4 The people

**A lamp man for each area's lights**, an effort post at bank (for bank lighting) or on the ore bench
(for the pit's):
- **Fire baskets**: he carries coal from the yard to the baskets — a worked conduit, as the coalers'.
- **Wells lights**: he pumps them up and fills them from the oil store.
- **Arc lamps**: he trims the carbons.

With nobody posted, each fails its own way and slowly: baskets burn down, Wells lights run dry,
carbons burn short. Gated on light himself — he carries a lamp, or works by the lights he tends.

### 3.5 Darkness underfoot

**Proposed: poor light worsens the footing perils**, as wet and icy ground already do. A peril's
`underfoot:` gains `dark:`, read as one less the place's light (the better of sky and lamps). The
barrow way, the dump's edge and the dams' wall are then worse at night unlit.
- *For*: lighting is safety as well as output, which is what it was; and it needs no new
  machinery — `Tick#under_the_sky` already offers `wet` and `icy` to a place.
- *Against*: one more multiplier on perils that are still first guesses.

### 3.6 The panel

- **Each area's lights in the lamp man's words**: out, lit, burning low (baskets), running dry
  (Wells), carbons short (arc), dark — the shaft stopped.
- "The Light" stays somebody's guess at the sky.

### 3.7 What this is not

- **No change to personal lamps.** A gang in miner's tools still works at half pace in the dark. The
  trade is now per head (kit for each, light that goes where they go) against per area (fuel or
  power, and a lamp man, for everybody there).
- **No light on the machines.** Engine posts are already ungated; a shovel's headlight lighting its
  own face for its pitmen is a candidate for later.
- **No new ignition hazard.** The pit has no firedamp; a flame at bank sits in open air.

## 4. Specs (relational)

- **The lift**: the colliery is bit-identical through a run of each lighting tier.
- **A light**: a lit area lets its gang work in the dark where an unlit one does not; the better of
  the light and a carried lamp, never the sum; the lever off is dark.
- **The tiers**: a brighter tier wins more at night; fire baskets burn down unfed and dim; Wells
  lights go out with the oil store or the feed empty; arc lamps go dark with the shaft stopped and
  dim as their carbons wear; trimming restores them.
- **Coverage**: pit lighting lights the benches and not the bank, and the reverse.
- **Darkness underfoot**: the barrow way's fall is likelier at night unlit than lit, and unchanged by
  day.
- **The books**: mass and energy close with baskets burning and the dynamo turning; a snapshot
  replays.

## 5. Questions

1. **Lift `Mine::Lighting` into `Nodes::Lighting`**, the colliery configured onto it?
2. **Two areas, pit and bank**, a slot and a lever each? Or one slot for the site, or a slot a place?
3. **Three tiers — fire baskets, Wells lights, arc lamps** — with fire baskets as a `FuelBed`?
4. **An oil store** for the Wells lights, a new sized holder at bank? Or the lamps draw on a fixed
   allowance with no store?
5. **A lamp man for each area**, whose absence fails each tier its own way?
6. **Darkness underfoot** (`underfoot: { dark: }`) now, or later?
7. **The levers default off**, so lighting up at dusk is the player's standing order? Or on, burning
   fuel by day?

## 6. Review decisions (2026-11-02)

1. **The lift, yes**: reusable later.
2. **Two areas.**
3. **The three tiers**, fire baskets as a `FuelBed`.
4. **A new oil store.**
5. **A lamp man for each area.**
6. **Darkness underfoot now**, retrofitted onto the colliery correctly as well.
7. **Default off.**

## 7. Settled while building

- **One light, three sources.** `Nodes::Lighting` gives `illumination` × lever × a dynamo's speed
  share × the lit share of a fire it names × its carbons. A fire's light *reads* the fire (`fire:`,
  its lit kilograms against `fire_full_kg`) and burns nothing itself, so the baskets stay a
  `FuelBed` and the Wells lights an oil burner — the stock-shape rule.
- **A light reaches the places it `lights:`**, not only its own (`Tick#ambient_tags`), so one node
  lights an area. A light naming a place that does not exist refuses the build.
- **The area lever is what burns, in every tier**: coal fed into the baskets, oil fed to the
  burners, the arcs on. The same lever is each fire's igniter, so lighting up needs nothing else.
  The lamp man keeps it supplied: coal from the yard to the baskets' heap, oil from the store to
  the tank, carbons trimmed.
- **The lamp man is gated on light**, at bank. Unlit at night with no lamp he does nothing, which is
  why **the baskets' coal (60 kg, an hour) and the lamps' tank (50 kg, two hours) start stocked** by
  the shift before.
- **The tiers in a night run**:
  - **Fire baskets** catch as coal does: about half alight after ten minutes, 91% by forty, settling
    at about 710 K with no monoxide. Light them before dusk.
  - **Wells lights** come up within seconds and hold about 755 K, 0.007 kg/s of oil.
  - **Arc lamps** are lit as soon as the dynamo turns, about 10 kW off the shaft, their carbons a
    night's (28,800 s) and drawn part spent (0–90%) at the start, so some matches need a trimmer.
- **`Mine::Lighting` became `Nodes::Lighting`**, the colliery's four tiers configured onto it
  (`Mine.sconces`, the gauze given `OPEN_FLAME` and the intake road). Its lighting specs pass
  unchanged; the colliery's sconces now also write a board.
- **Darkness underfoot is judged against a lamp's worth, not daylight.** `Peril::FOOTING_LIGHT` is
  0.5, the light of the colliery's proper `miners_tools`: at or above it footing is as sure as by
  day, below it `unseen` rises to 1 in the dark. So a colliery crew in proper kit is unchanged
  underground, and a crew with a candle or no lamp is worse. Every `dark:` weight is 4.0: five times
  as likely unseen.
- **Carried along a way, a person sees by their own lamp only** (`Blunder.sight`). A man-engine
  rider keeps the place he set out from until he arrives, so without this he read his step down the
  shaft by bank daylight.
- **Retrofitted**: the colliery's deck (`slipped_on_the_deck`, `tub_into_shaft` through
  `BANK_FOOTING`) and the man engine's `misstep`; the pit's ramps, the water's edge and the shaft
  kiln's mouth. Perils of seeing something coming — a tub, a train, a dipper — are not footing and
  are left alone.
