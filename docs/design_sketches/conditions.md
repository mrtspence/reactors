# Conditions: weather, day and night, and what comes later

Status: **reviewed; building.** Answers from the review are in §6 and supersede anything above
that disagrees. Unit 2 of the open-pit sequence (see
[`open-pit-iron-research.md`](open-pit-iron-research.md) and [`crewed-posts.md`](crewed-posts.md)).
It is general, so it lands on the colliery and the steam engine first. Weather and daylight are
its first two instances.

**Decisions already taken:**
- A general system for conditions. Weather comes first; magical weather and invasions come much
  later. Conditions are reported properly in the UI.
- Day and night are in.
- A match takes place in a single season. Which season, and how extreme it is, varies from match
  to match: an icy blizzard in one, a scorching summer day in another.
- A match lasts 30–60 minutes, at `time_scale` 1 for every operation.

---

## 1. What exists

| Piece | State |
|---|---|
| `Nodes::Atmosphere` | Fixed temperature (`ambient_k`, 288 K) and fixed pressure. Its baseline parcels are rebuilt every tick at that temperature |
| Ambient heat loss | `Arbiter#settle_ambient` reads each node's own **constant** `ambient_k`. Nothing anywhere varies with time or place |
| Buoyancy | `Arbiter.path_head` takes the source's `ambient_k` against the stream's temperature. So a stack draws harder the colder the outside is, and **natural ventilation would follow the weather for free** if the atmosphere's temperature moved |
| Per-match variation | `Mine::Ground` draws a figure in `initial_state` from the node's own stream. That's the pattern for anything drawn per match |
| Room effects | `Tick#ambient_tags` lets a node offer tags (`darkvision`) to everybody in its place. The better of person and room is taken, never the sum |
| Harm from the room | `scorch.rb` grinds resilience above 318 K of *gas*. There is no cold harm |
| Instruments | Sources, filters and displays, including `Prose` (phrases in place of numbers). Gauges may name an `observer:` |
| Events | `Event::TYPES` is enumerated. Events are emitted on transitions, with hysteresis |

**Historical anchors:**
- The Coal Mines Regulation Act 1872 required a **barometer and thermometer at the pit top**.
  Owners ordered extra firing in the upcast when the glass fell fast, because a falling barometer
  was widely held to bring firedamp out of the goaf. A 1917 report states it plainly: "with
  falling barometer there occurs an efflux of gas from goaf". Scientists disputed the mechanism
  for solid coal; it was accepted for the goaf. Sources: [Nature, 1877](https://www.nature.com/articles/017021a0.pdf);
  [NZ Mines report, 1917](https://slbrartest.natlib.govt.nz/imageserver/parliamentary/P29pZD1BSkhSMTkxNy1JLjEuODIyJmdldHBkZj10cnVl);
  [Woodhorn inquiry, 1916](https://nmrs.org.uk/mines-map/accidents-disasters/northumberland/woodhorn-colliery-explosion-ashington-1916/).
- **Natural ventilation is seasonal.** The bigger the temperature difference between shaft and
  outside, the stronger the natural draught. It weakens or reverses as the outside warms
  ([e3s-conferences, 2020](https://www.e3s-conferences.org/10.1051/e3sconf/202019201018)).

---

## 2. The design

### 2.1 One `Outdoors` node per operation, holding the conditions

The conditions live in a node, as the ground does, rather than in a new top-level system:
- Its **state** is the conditions, so they snapshot, restore and replay like everything else.
- Instruments read it through ordinary sources.
- It draws what it needs in `initial_state`, so no new place for entropy is needed.

**Every operation gets one as a fixture.** Its stream is keyed by the match seed and its own id,
so two operations in one match draw **the same sky**. Linked operations share a site without any
cross-operation channel.

Configuration rides in `options:`: `conditions: { climate:, season:, severity:, start_hour: }`.
`Match.create` puts the same value into every operation, so a restore rebuilds the same sky.
Anything left unset is drawn from the seed.

### 2.2 The weather is drawn once, as a schedule

The node draws a **schedule** of spells for the match's horizon, three hours to be safe, all in
`initial_state`. A spell is fair, unsettled, a storm, a cold snap or a heat spell, from the
season's mix in content. Each spell has:
- a duration;
- a temperature offset;
- a precipitation rate and form (rain, sleet or snow, decided by temperature);
- a wind speed;
- a pressure trend (a front falls ahead of a storm and rises behind it).

The conditions at any moment are a **pure function of the schedule and the clock**:
- spell values eased across a transition window;
- a **diurnal temperature curve** on top, from the season's daily range and the hour;
- the **season's mean and its drawn extreme** underneath. `severity` stretches the spell offsets,
  so a match's extremes vary as decided.

The node's `apply` advances its own `clock_s` by `dt` and writes the current readings into state.
**No die is thrown after `initial_state`.**

### 2.3 Day and night

The sun is a function of season, latitude (fixed per climate) and hour: sunrise, sunset and a
twilight ramp. `daylight` runs from 0 to 1.

**The clock runs at the physics' pace** (recommended; question 1). A match is one real hour of
the day, starting at a drawn `start_hour`:
- Most matches are day shifts.
- Some cross dusk or dawn.
- A few are night shifts: dark at bank all match, and lamps needed above ground.

### 2.4 Kinds of condition, and the effects they offer

Weather and daylight are the first two registered **kinds**: `Conditions.register(:weather)`,
`(:daylight)`. A kind draws its part of the schedule and answers its readings at any moment. All
readings go out through a fixed set of **channels**, so a later kind (enchanted fog, a magical
frost, much later an invasion) adds a kind and reuses the channels that already have consumers:

| Channel | Unit | Who reads it |
|---|---|---|
| `outdoor_k` | K | The atmosphere; exposed nodes' ambient (2.5); the cold and heat of outdoor work (2.6) |
| `pressure_pa` | Pa | The atmosphere's pressure reference |
| `precipitation` | kg/m²/s and form | Reported in this unit; rain into the pit's sump in unit 5 |
| `wind_m_s` | m/s | Reported and in wind chill now; ropeways and spoil dust later |
| `daylight` | 0–1 | `darkvision` offered to outdoor places |
| `offers` | tags | Anything else offered to outdoor places: `wet` underfoot, and later `distracting` (unit 3) or an enchantment |

**An invasion is not promised by this.** It brings agents, not readings. The registry and the UI
strip are what it would reuse; the agents are their own unit when the time comes.

### 2.5 Exposure: what the weather reaches

A **place** declares `exposure:` between 0 and 1. Bank is 1. A sheltered engine house is about
0.3. Underground is 0, which is also the default, so nothing that doesn't ask changes.

- **A node's ambient** becomes a blend of its own `ambient_k` and `outdoor_k` by its place's
  exposure. `settle_ambient` reads `node.ambient_k_now(ctx)` instead of the constant.
- **`Atmosphere` follows `outdoor_k` and `pressure_pa` outright.** Its baseline is rebuilt every
  tick at the current reading, and its `mole_capacity_per_pa` and ledger reset read the same
  value.
- **Air drawn down a downcast arrives at the day's temperature.** Every stack's buoyancy then
  answers to the weather through the path that already exists, so natural ventilation and furnace
  draught become seasonal without new code.
- **Barometric pressure moves the pressure reference** of everything vented to the sky. Whether a
  falling glass then draws gas out of the goaf **emerges** from the gob and goaf gas paths. If it
  doesn't, because those paths are rate-driven, that's a finding for the build, not a fiat to add
  (question 4).

### 2.6 What the weather does to people

| Effect | Mechanism | Built how |
|---|---|---|
| **Cold** | Below a tolerance, grinds resilience as `scorch` does above one, with `cold_resistance` and warm kit raising the tolerance. Wind chill lowers the effective temperature | A new `chill.rb`, shaped like `scorch.rb`, with its own dwell counter per the harm rule. Stiff cold hands also derate `dexterity` |
| **Heat** | Outdoor summer heat never reaches scorch's 318 K of gas. What it does to a labourer is **strain**: fatigue accrues faster | A heat factor on `Fatigue.accrual` past a comfort band, read from the place's temperature |
| **Dark** | No daylight at an outdoor place means no `darkvision` from the room | Through `ambient_tags`; no new mechanism |
| **Wet** | `wet` offered to outdoor places while it rains raises perils tagged slippery (planks, ladders, the bank) | A tag the peril system already understands how to read |

### 2.7 Telling the player

- **What anyone can see** goes on every panel, at no cost. It's a prose instrument with no
  observer: "Clear, mid-morning", "Heavy rain", "Snow, dusk". That is looking out of the window.
- **What takes an instrument** is the numbers:
  - A **thermometer** and a **barometer** as fitted parts. The barometer's display shows the
    trend, rising, steady or falling, because the trend is what a colliery read it for.
  - For the colliery, I'd make the pair the **starting fixture**, as the 1872 Act required (question 3).
  - A better tier, a recording barograph, shows the last hour.
- **Events**, on transitions with hysteresis:
  - `weather_turned`: spell band changed, for example fair to storm.
  - `nightfall` and `daybreak`.
  - `glass_falling`: a fast pressure fall begins, on the barometer's side.
  These reach the incident feed only where they matter, by severity.
- **The UI strip** is a panel row at the top of the console, built from the instruments above, so
  there's no new client machinery. A later kind adds its own instrument to the same row.

### 2.8 Content

`content/conditions/climates.yml` holds one climate to start, a northern English coalfield at
about 54°N. Four seasons, each with:
- mean temperature and daily range;
- a spell mix, with each spell's typical length;
- a pressure baseline;
- a `severity` range.

All first figures are **[gk]**, to tune:

| Season | Mean | Daily range | Extremes |
|---|---|---|---|
| Winter | about 3 °C | 5 K | Blizzard −10 °C, snow, wind 15 m/s |
| Spring | about 9 °C | 8 K | |
| Summer | about 16 °C | 9 K | Heat spell 28–32 °C |
| Autumn | about 10 °C | 7 K | |

Pressure runs 98–104 kPa, and a storm front falls about 1 kPa in three hours. The open pit's
Mesabi-like climate, with harder winters, is added with unit 5.

### 2.9 Determinism, state and the rules

- No draws after `initial_state`.
- The schedule lives in state, with its spell kinds as symbols normalised on restore.
- Readings are recomputed from state each tick.
- Every operation's `Outdoors` reads only its own state, so there is no cross-operation coupling.
- A spec pins the sky, as `Ground::ORDINARY` pins the ground. With
  `conditions: { pinned: :standard }`, a spec that doesn't care measures the machine at 288 K
  and standard pressure in daylight. **Every existing spec keeps its numbers**, because every
  rig passes the pin.

---

## 3. Specs (relational only)

- **Cold:** a colder outdoor reading cools an exposed node faster than a sheltered one, and the
  underground nodes not at all.
- **Draught:** a colder day draws the furnace or a stack harder than a warmer one, natural draught
  included.
- **Light:** at night an outdoor post's `darkvision` falls to what the worker carries; by day it
  is at least the daylight's.
- **Repeatability:** the same seed draws the same schedule, two operations in one match read the
  same sky, and a different seed draws a different one.
- **No hidden dice:** the conditions replay bit for bit through a snapshot taken mid-spell, with
  draw counts unchanged.
- **Cold harm:** grinds a worker below their tolerance and costs nothing above it, and kit raises
  the tolerance.
- **Heat:** tires a labourer faster than the comfort band does.
- **Events:** each fires once per transition, not every tick.
- **Panel:** every panel carries the sky prose; the barometer reads falling while a front comes
  in.

## 4. Docs touched in the same change

- [`physics.md`](../reference/physics.md): ambient as a function of exposure and conditions.
- [`settlement.md`](../reference/settlement.md): `settle_ambient` reads the current ambient.
- [`nodes.md`](../reference/nodes.md) and `nodes/CLAUDE.md`: `Outdoors`, and the atmosphere
  following the sky.
- [`tick.md`](../reference/tick.md) and `lib/reactor_sim/CLAUDE.md`: where the readings are
  advanced; the new harm module.
- [`diagnostics.md`](../reference/diagnostics.md): the sky, thermometer and barometer.
- [`add-content.md`](../guides/add-content.md) and `content/CLAUDE.md`: climates.
- [`build-an-operation.md`](../guides/build-an-operation.md): `exposure:` on places, and the
  fixture.
- [`invariants.md`](../reference/invariants.md): none. No new place for entropy, which is the
  point of drawing the schedule in `initial_state`.

---

## 5. Questions for review

1. **The clock's pace.** I recommend real time from a drawn start hour, so a match is an hour of
   the day and some cross dusk. The alternative is a compressed day, so every match sees dusk.
2. **One sky per match** for linked operations, as if on one site? Or a climate per operation
   (a colliery in Durham coupled to an ironworks elsewhere)?
3. **The pit-top thermometer and barometer:** a starting fixture for the colliery, as the 1872 Act
   required, with better tiers as upgrades? Or purchases from the start?
4. **Barometric gas:** let it emerge from the existing gas paths, and if it doesn't, report rather
   than add it? Or build the goaf's efflux in deliberately?
5. **Rain in the colliery:** reported only, plus `wet` at bank, until the pit consumes it? Or also
   wetter shafts feeding the sump now?
6. **Freezing** (water, feed pipes, a frozen sump) needs an ice phase in content. Defer it, with
   cold reaching things only through temperature, chill and tags for now?
7. **Heat as fatigue strain** rather than as scorch: agreed?
8. **The season:** drawn per match with extremes drawn, or chosen at match setup with only the
   extremes drawn?

---

## 6. Review decisions

1. **A real 1:1 clock** from a drawn start hour.
2. **One sky per match.**
3. **The thermometer and barometer are purchasable upgrades.** The starting reading is the
   banksman's best guess, in prose: "feels cold", "a bit hot", "my knee aches", "getting dark",
   "wind's howling". It is an observer gauge, so his wits and the light colour it. The steam
   engine's equivalent is whoever is at the fire.
4. **Barometric gas is left emergent.** Expected to need additions; report what the build finds.
5. **Rain feeds the sump.** A catchment at the pit top drains rain, and snowmelt once it warms,
   down the shaft. Snow lies on the ground (the `Outdoors` node tracks its depth) and runs off as
   it melts.
6. **Freezing proper is its own unit.** The scan of both operations found ice would reach:
   - **Steam engine:** the feed supply, feed pump and injector; condensate in the drain cocks and
     cylinder of a standing engine; the condenser; the oil store and feeds; the bearings.
   - **Colliery surface:** the sheave and its grease, the winding rope, the brake, the drum, the
     drainage main, the Cornish beam.
   - **Down the downcast:** shaft guides and the cage; in a hard winter, catch points and doors
     near the pit bottom.

   Doing it properly needs four pieces, which is a designed unit and not an add-on:
   - an ice phase for water in content, generalising phase change to solid and liquid with
     latent heat;
   - a freezing concern for conduits, which hold nothing and so need an ice-blockage state;
   - temperature-dependent oil viscosity in `Bearing`;
   - icing on friction surfaces: brakes, ropes, drums.

   **This unit takes only `icy`**: offered to outdoor places when below freezing and wet or
   snowy, and making slipping hazards much worse.
7. **Heat is fatigue strain.**
8. **The season is chosen at match setup**, so players can outfit their workers and rig for it.
   Only its extremes and the spells are drawn. It is stored as a match setup row, carried in the
   reset command beside the loadout and crew, and passed to every operation through `Match.create`.

### Details settled while building

- **Exposure shifts, rather than replaces, a node's ambient:**
  `ambient_k + exposure × (outdoor_k − standard)`. A node's configured ambient is its
  standard-day figure, and a standard sky leaves every node exactly as it was.
- **No `conditions:` means a standard sky:** 15 °C, standard pressure, still and dry, daylight.
  This is what every spec rig gets. A real match always passes the season from setup.
