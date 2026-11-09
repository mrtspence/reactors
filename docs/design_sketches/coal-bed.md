# The coal bed (for review)

> Input to a decision, not a description of the system. A pass over how coal burns, for every
> grate in the game: the stationary engine's, the mobile engines', the colliery's ventilating
> furnace, the open pit's kiln, and the colliery's waste.

## 1. What is wrong, measured

**A coal fire in the game holds a few seconds of fuel**, so it cannot survive an interruption a
real one would not notice.

| Fire | At work | Unstoked | Damper shut |
|---|---|---|---|
| The stationary engine | 0.46 kg on the grate, 0.11 kg alight: three seconds' feed at 0.15 kg/s | out in about 5 s; the drum is down 270 kPa in two minutes | out in about 20 s, green coal piling up unburnt |
| A mobile engine | 0.04 kg alight | a row of 30 s puts it out, and it lies cold two minutes | — |

**A real hand-fired grate** [gk — general knowledge, not checked this session]:
- **The bed is four to eight inches of coal**, burning at 10–20 lb a square foot of grate an hour under
  natural draught (50–100 kg/m²·h), and several times that under a blastpipe. A bed holds tens of
  minutes of burning.
- **Unstoked, it burns down over those tens of minutes**, its heat falling as it thins.
- **Banked**, with the damper shut and fresh coal on, it stays in overnight.
- **Fired too heavily for its draught, it smokes**: green coal, carbon monoxide and soot up the
  chimney, and coal wasted.

**Why** (the note at the top of `content/reactions/combustion.yml` records it):
- `rate_per_s` became "how fast **lit** coal is consumed" when ignition landed, and was tuned to a
  plateau of 1.5–2.0. That means a lit lump burns out in under a second, so lit coal can never
  accumulate into a bed.
- **And starvation puts a fire out at `quench_per_s`**, 0.45/s, so a fire short of air dies in
  seconds instead of smouldering.

## 2. The change (first draft)

> Superseded by §9 for the bed and the starvation rule; the burn rate and the pathway stand.

**Two numbers and one rule, no new node.** The bed is the coal the grate already holds; it only has
to be allowed to build.

1. **Coal burns at a realistic rate a kilogram**: `rate_per_s` of the order of 10⁻³/s, so a lit lump
   lasts about a quarter of an hour at full air.
   - The bed then builds until it burns what is stoked: about 150 kg at the stationary engine's
     working rate, and 30 kg at a mobile engine's.
   - **What the fire burns is then set by its air**, the damper and the draught, as a real fire's is,
     and no longer by a rate constant on a plateau.
2. **Starved, a fire smoulders instead of going out** — a new ignition key, `smoulder_per_s`, taking
   the place of `quench_per_s` for starvation.
   - A banked fire's lit coal then decays over hours.
   - A cold box and no fuel still put a fire out at `quench_per_s`.
   - Opt-in: a fuel that does not declare it is unchanged, so wood, oil, belting and the gases keep
     today's behaviour.
3. **Short of air, a deep bed burns to monoxide**: the existing `limited_by: air` pathway, unchanged.
   A fire fired harder than its draught smokes, wastes coal and runs cooler, which makes firing a
   matter of matching the shovel to the damper.

**Feasibility, probed on the stationary engine** (§5) with both changes made in a scratch copy of the
content and the rule patched in the script:
- On a 150 kg bed it holds its 608 kPa and about 990 K, the bed steady.
- Unstoked, it burns down over half an hour.
- Banked, the fire stays in only as a small core (§5, questions 6 and 7).

## 3. What it changes, consumer by consumer

| Consumer | Today | With the bed |
|---|---|---|
| **Stationary engine** | A grate of seconds; the damper sweep in `steam_engine/definition.rb` and the rate plateau in `combustion.yml` were measured on it | A bed of minutes; the fire follows the damper. The working state (`EngineRig::FIRE`) and the damper sweep are re-measured |
| **Cold start** | Alight at tick 11 and 1,013 K by tick 100 | Slower: the bed has to be built and heated, and it holds far more heat (150 kg of coal at 1,260 J/kg·K, against the firebox's 3×10⁴ J/K). Question 4 |
| **Mobile engines** | A row puts the fire out | A row is a dip in steam. `AT_WORK` and `HEAVY_AT_WORK` are re-measured |
| **The colliery's ventilating furnace** | Stoked by its furnaceman, a grate of seconds | A bed; its draught follows its fire more slowly |
| **The open pit's kiln** | 0.14 kg of coal in it at work | The coal in the charge builds to tens of kilograms. The kiln's `working:` figures are re-measured |
| **The colliery's waste** (`Mine::Gob`) | Once alight, its tonnes of coal burn at 1.5/s of what is lit | Burning far slower for what is lit, while the lit share spreads through the tonnes. Sealing starves it to a smoulder, not to nothing. Question 2 |
| **The belt drive head's spillage** (`coal_layer_combustion`) | A layer fire, its own reaction | Unchanged unless question 5 says otherwise |
| **Firedamp, coal dust** | Prompt deflagrations | Unchanged |

## 4. What the player sees

- **The fire is steadier and slower.** It answers the damper over minutes, and a gap in the stoking is
  a dip, not a dead fire.
- **Stoking keeps the bed and the damper sets the burn.** Too much coal for the air smokes and wastes;
  too little thins the bed.
- **Banking keeps the fire in**: the damper at a crack with the bed made up, and the fire is still in
  when it is wanted — fully once §5's fix is in.
- **Unstoked, a fire runs down over a quarter of an hour or more**, so a fireman who leaves his
  shovel costs steam gradually rather than all at once.

## 5. Probes (scratch, on the stationary engine at work)

**Made in a scratch copy of the content**, with coal at `rate_per_s` 10⁻³ and `smoulder_per_s` 10⁻⁴.
The ignition rule was patched in the probe script only, and each run was seeded with a 150 kg bed,
95% alight, at the fire's working heat.

| Run | What happened |
|---|---|
| **Working**, the usual levers | 608 kPa held, the fire at 987–995 K and the bed steady at about 150 kg for ten minutes, burning clean |
| **Unstoked** | the bed burns down over half an hour — 130 kg at 2½ min, 84 kg at 10 min, 27 kg at 30 min — the fire still 636 K and the engine still turning at 30 min, the drum falling from 608 to 228 kPa |
| **Damper fully shut** | nothing burns, the bed gives its heat to the water legs in a minute or two, and past coal's 500 K the chill quench puts it out in about seven minutes |
| **Banked: damper at 3%, engine stopped** | a core stays alight: 115 kg at 5 min, 5 kg at 10, 2.4 kg at 30, under 146 kg of green coal; the box near 390 K, the drum 608 → 135 kPa |
| **Banked: damper at 6%** | the same with more alight: 12 kg at 10 min, 5.5 kg at 30 |

**So the two changes do what they are for, and banking is half there.**
- **Unstoked, the fire behaves like a bed**: a row is nothing, and a fireman who walks away costs
  steam over a quarter of an hour.
- **Banked with the damper cracked, the fire is still in** after half an hour, as a small core under
  green coal. Opening the damper again should bring the bed back; the probe did not open it.
- **What is wrong is the core's heat.** The firebox is one body at one temperature, bed and gas
  together, and once the box falls under coal's 500 K the chill quench takes most of the bed. A real
  banked bed stays hot under its covering of green coal while the gas over it cools.
  - **Fix (a): the bed as a body of its own**, a node at its own temperature that hosts the coal and
    its reaction, with the box's gas over it and a weaker path from the bed to the water legs.
    *For*: true, and it makes the fire's heat and the box's gas two readings. *Against*: a new node
    in every grate, a new heat path to measure, and the largest change here.
  - **Fix (b): chill read through smoulder when the bed is starved.** A cooling bed short of air
    decays at `smoulder_per_s` and not `quench_per_s`, because what is putting it out is the shut
    damper and not a cold box. *For*: one line in the same rule, and banking then holds. *Against*:
    a bed that is genuinely cold and short of air dies only slowly — a fire smothered under too much
    green coal would hang on longer than it should.
  - **Recommended: (b) now**, and (a) only if (b) is measured to hold a fire nobody could have kept.
- **A fully shut damper sealing perfectly** is the other half. A real damper never quite shuts. Either
  the damper's travel stops short of fully shut, or a banked fire is a lever at a few percent, a
  decision the fireman makes (question 6).

## 6. Specs (relational)

- **The bed**: a working fire holds minutes of burning on its grate, and an unstoked one burns down
  over minutes, not seconds.
- **The air**: the same bed burns more with the damper open than shut; short of air it makes monoxide.
- **Banked**: shut, a fire stays alight far longer than it does unstoked with the damper open.
- **Opt-in**: a fuel that does not declare `smoulder_per_s` is untouched (`ignition_spec`).
- **Every consumer re-measured**: the seeded working states carry on with no transient, and the books
  close.

## 7. Questions

1. **The two numbers and one rule**: coal at about 10⁻³/s a kilogram, and starvation smouldering
   through an opt-in `smoulder_per_s` — rather than a bed node of its own?
2. **The colliery's waste on the same coal**, its fire re-measured and re-tuned, rather than a reaction
   of its own kept as it is?
3. **A thick bed choking its own draught** — depth resisting the air, so a fireman has to keep the
   fire thin enough — now, or later?
4. **The cold start**: let it take as long as building and heating a real bed takes, or start the
   engine on a fire already laid (as the mobile engines start at work)?
5. **The drive head's layer fire** on the same rules, or left as it is?
6. **A banked fire's air**: the damper never quite shuts (a few percent at lever zero), or banking is a
   lever the fireman sets to a crack?
7. **Holding a banked core hot**: chill read through smoulder while starved (§5, fix b), or the bed as
   a body of its own (fix a)?

## 8. Review decisions

1. **The bed is a body of its own (fix a)**, not an opt-in `smoulder_per_s`. Every furnace after this
   one reuses the pattern, so it is worth the larger change. Realistic burn rates and bed sizes stand.
2. **The colliery's waste is the same reaction**, rebased onto the bed and re-measured.
3. **A thick bed chokes its own draught now.**
4. **Engines start cold and are measured.** If raising steam from cold is egregious, they start from
   a bed banked the day before or brought up by the shift before.
5. **The belt drive head's layer fire is left alone.** It is its own reaction, a little coal and
   grease, there to light rubber at real frictional temperatures.
6. **A damper set to zero leaks a little**, as a real one does.
7. **Fix (a), then measure how a banked core holds.**

## 9. The bed as a body (for review)

**The fire becomes two bodies**: the bed on the grate, and the space over it.

```
damper (leaks shut) ─➤ grate ─➤ fire bed ─➤ over the fire ─➤ firebox ─➤ tubes ─➤ chimney
fire bed ═radiant, by its lit share═➤ boiler          firebox ═convective═➤ boiler
```

### 9.1 The pieces

1. **`Nodes::FuelBed`, a `Vessel`.** It holds the fuel on the grate, its ash and the gas among it,
   all at the bed's own temperature.
   - It hosts the fuel's reactions.
   - It takes the stoking, the igniter, the air from below and a blown plug's water. Ash goes out
     below and gas goes out over the fire.
   - It declares `grate_area_m2:` and records its **depth** in state: its solids at their content
     density, spread over the grate.
   - **It radiates by its lit share.** It answers `radiant_share(state, content)`, the share of its
     fuel alight, and a radiant `ThermalLink` scales its T⁴ term by the share at each end that
     answers one.
     - A fresh charge darkens the fire until it catches.
     - A banked bed under green coal barely radiates, which is what holds its core hot.
     - A link with no such end is unchanged.
   - **Its volume holds a tick's air.** A holder reacts with what it holds, so a bed whose volume
     was only the gaps between the lumps would starve on any draught. The volume is the bed and
     the flame just over it. The stationary engine's 6 m³ splits into 2 m³ of bed and 4 m³ of
     firebox.
2. **The firebox is the space over the fire**: a `Vessel` with no reactions. The water legs cool
   it by convection, and the stack draws on it. Its id and its link to the tubes are unchanged.
3. **`Nodes::Grate`, a `Conduit`: the bars and the bed on them**, between the damper and the bed.
   - Its conductance is `k_bars / (1 + depth / choke_depth_m)`, read from the bed's depth last tick,
     so a thick bed chokes its own draught (question 3). Ash counts in the depth.
   - The fireman keeps the fire thin enough, and raking out the ash opens the grate again.
4. **Over the fire, a conduit between the bed and the firebox.** It is needed because a path with
   no conduit on it is rate-driven and carries no gradient (`Arbiter.gas_coupling`). It has a
   conductance well above the grate's, so it is never the restriction.
5. **A damper leaks shut** (question 6): `leak_fraction:` on `Conduit`, the share of its bore a
   lever at zero still passes.
   - The colliery's `Mine::Leak` already declares the same field for its doors and brattice. It
     moves up to `Conduit`, and `Leak` keeps only its own reading, of a state-driven opening
     rather than a lever.
6. **Coal at `rate_per_s` 10⁻³**, with the existing short-of-air pathway. **No `smoulder_per_s`.**
   - A banked bed's lit mass settles where its leak's air can burn it, because starvation already
     scales spread down and quench up. That lit core stays hot because the bed is its own body.
   - The ignition rule is unchanged.

**Ids.**
- The bed is `:fire_bed`. Everything that reads *the fire* moves to it: the stoker, the igniter,
  the plug, the ashpan, `fired_by:` on the crown sheet, the fire gauges, the engine boards, and a
  mobile engine's `raised` figures.
- `:firebox` stays the box, so the tubes, the chimney and the gas routes are untouched.

### 9.2 Probed on the stationary engine (scratch, the pieces above patched in)

These figures are the probe's, not a sweep:
- **Bed**: 2 m³, 2×10⁴ J/K of bars, 20 W/K to the ashpit.
- **Firebox**: 4 m³, 300 W/K to the water legs.
- **Radiant path**: the bed's 24 m² at ε 0.9, plus 50 W/K.
- **Grate**: 2 m², bars 3.0, `choke_depth_m` 0.15.
- **Over the fire**: 20.
- **Damper**: leaks 3%.

Seeded with a 150 kg bed, 95% alight:

| Run | What happened |
|---|---|
| **Working** (the usual levers) | 608 kPa held at 167–172 rpm. The bed is at about 1,055 K, the firebox at 1,000 K. The bed takes 3.1 kg/s of air, about 85% excess, and builds slowly (150 → 153 kg in five minutes). |
| **Fired hard** (stoking 100) | The bed thickens to 204 kg in ten minutes and runs hotter (1,168 K). Its draught falls off with the depth (3.1 → 2.9 kg/s). |
| **Over-fired** (stoking 100, damper 25) | **It smokes.** The bed piles up from 150 to 226 kg in 15 minutes on 1.44 kg/s of air, and CO in the firebox climbs from 3% to 13% by volume. The engine stopped at about 16 minutes because the main bearings wiped and seized; nobody was oiling them, and the fire played no part. |
| **Unstoked** | Burns down over half an hour: 131 kg at 2½ min, 87 kg at 10, 30 kg at 30. The engine is still turning at 70 rpm at 30 min. |
| **Banked** (damper to zero, engine stopped) | **The core holds.** The bed falls only from 970 K to 766 K in thirty minutes, with 1.25 kg alight under 147 kg of green coal, on 0.008 kg/s of leaked air. It smokes, at 21% CO by volume in the firebox. At about 7 K a minute it is above coal's 500 K for another half hour or more. |
| **Banked 20 min, then opened up** | The bed comes back. 126 of 159 kg are alight 3⅓ minutes after the damper opens, and all of it by 6⅔. The drum is back from 191 to 608 kPa about ten minutes after. |
| **Cold start** (igniter, blower, stoking 60) | 608 kPa at about **22 minutes**. The bed is alight at once, at 500 K at 2½ min and 800 K at 10, and the drum lifts from 13 to 608 kPa between minutes 7 and 22. |

### 9.3 Every other fire

| Fire | With the bed |
|---|---|
| **Mobile engines** | The same builders, so the same two bodies, with grate areas to their fires. `AT_WORK` and `HEAVY_AT_WORK` are re-measured: a working bed is about 30 kg on the vertical engine and 60 kg on the heavy one. |
| **The ventilating furnace** | **Already a bed.** It is one holder of coal whose gas goes up its flue to the upcast foot, which is the space over it. It becomes a `FuelBed`, and its draught conduit a `Grate`. It has no water to radiate to. |
| **The kiln** | **Its charge is its bed**, ore and coal together, so it stays one body and is re-measured: its coal builds to tens of kilograms. A burden choking its own draught is a `TODO:` on the kiln, naming the gas-fired kiln as its first caller. |
| **The colliery's waste** | **Already a bed**: coal lying in the waste at the waste's own temperature. Rebased onto the new rate. The start-temperature solve (`DESIGN_HEAT_W`) and the fire's timing are re-measured, and sealing starves it to a smoulder on the leak. |
| **The drive head's layer** | Unchanged (question 5). |

### 9.4 What changes for the player

- **Raising steam takes about twenty minutes from cold** where it took about two. That is the one
  figure question 4 asked to see.
- **The draught gauge is re-banded.** It reads the air in the bed, which is a third the old box.
- **The fire gauges read the bed**, which is what the fireman sees through the door.

### 9.5 Specs

- **The bed**: a working fire holds minutes of burning, and unstoked it burns down over minutes.
- **The air**: open, the same bed burns more; short of air, it makes monoxide; thicker, it draws
  less.
- **Banked**: with the damper at zero the core stays alight and above its ignition point far longer
  than an unstoked open fire lasts, and opening up brings it back.
- **The radiant share**: a link to a node that answers none is bit-identical.
- **The leak**: a shut damper passes its leak and no more.
- **Every consumer seeded again**: no transient, and the books close.
- **Specs that raise steam from cold** grow about tenfold in ticks, so they move onto seeded states
  where the claim allows.

### 9.6 Questions

1. **Twenty minutes to raise steam from cold**: keep it as the stationary engine's opening, or start
   it from a bed banked overnight (§8, decision 4)?
2. **The ids**: the bed as `:fire_bed` with `:firebox` left as the space over it, or the other way
   round?

### 9.7 Review decisions

1. **The engines start from a banked fire.** Twenty minutes is far too long; the relight probed in
   §9.2, the bed through in about three minutes, is about right, and three to five is ideal.
2. **`:fire_bed` for the bed, `:firebox` for the space over it.**

## 10. Settled while building

- **The start is the banked state from §9.2**, twenty minutes on: the bed 826 K, 147.8 kg of coal
  with 1.4 kg alight (`SteamEngine::BANKED_BED`, the fire bed's `laid:`), and the drum warm below
  its valve (`BANKED_DRUM_K`, 392 K for the locomotive boiler and 368 K for the beam boiler). A laid
  bed starts `alight`, so a match opens on no `fire_lit`.
- **The bellows bring it through, with the regulator shut**: the whole bed alight in under forty
  seconds, working pressure at about two and a half minutes, the valve lifting at three.
  - On natural draught alone a banked fire only smokes, taking 0.25 kg/s of air with the drum
    falling.
  - Opening the regulator first starves the blast of steam and the bed burns through slowly,
    smoking. The procedure matters, as it should.
- **At work** (bellows off, the usual levers): a 154 kg bed at 1,089 K, the firebox at 1,026 K,
  608 kPa at 160 rpm and 455 kW, about 3 kg/s of air. That is `EngineRig`'s seed.
- **The mobile engines make more from the same fire**: 104 kW against 81 on the vertical engine,
  from about the same 900 kW of coal on a 30 kg bed, and 167 kW against 122 on the heavy one, on
  60 kg. Not separated further: the hotter bed and the radiant share both move the split of heat
  to the water.
- **The draught gauge keeps its bands.** It reads the bed's unburnt air, 0 / 0 / 0.11 / 0.25 /
  0.35 / 0.43 kg at damper 0 to 100, and the old bands still fall in the right places: choked at 20,
  where the bed already makes monoxide.
- **The fire runs hotter than the lumped one** (1,089 K against 1,010), so the crown sheet's "plug
  first" water level moves from 800 kg to 850.
- **Lighting a bare cold grate is slow**: the igniter takes and the fire spreads on its own, 0.23 kg
  alight when it comes out at tick 30 and 1.31 kg at tick 100, but the bed is still near 304 K at
  25 seconds. `EngineRig.cold` builds that grate for the claim.
- **The furnace is a `FuelBed` drawn through a `Grate`.** The upcast foot is the space over it,
  with grates of 0.5, 3 and 6 m² by tier. Its specs pass unchanged.
- **The waste needed one example re-fitted.** A starved gob fire now wants a tonne alight in blackdamp
  at the roads' pressure. A near-empty waste is a vacuum, and the leak fills it with air, which
  burns clean.
- **The kiln's working figures are re-measured** off an hour at work: the clamp at 940 K on 62 kg of
  coal, the shaft kiln at 930 K on 127. Both hold within a percent over twenty minutes.
  - **Its eyes leak 3% shut** (`EYES_LEAK`): shut tight, a kiln's fire went out in twelve seconds,
    and partly open it smokes at 16–20% CO by volume, so stopped up it now smoulders.
  - More coal in the charge builds the bed over minutes; over twenty ticks the cold coal first cools
    it slightly.
- **"A Clean Cold Start"** opens on `fire_lit`, which a banked start never sends. It can only be
  earned on a relight now.

## 11. Found in the open-pit lookover (2026-11-01)

- **The kiln had copied `FuelBed#laid:` instead of being one.** It seeded its own lit coal and air,
  missed the `alight` latch, and sent `fire_lit` on tick 1 of every match. In the dev match that
  opened "A Clean Cold Start" for the stationary engine to close on its banked bring-up, so §10's
  last line was wrong in practice. The kiln is now a `FuelBed` subclass, `laid:` from its tier's
  working figures, with a `grate_area_m2` (4 m² the clamp, 1.5 the shaft kiln) that nothing reads
  until its eyes become a `Grate`.
- **A raised mobile engine sent `steam_raised` on tick 1** for the same reason, which awarded "A Full
  Head of Steam" the moment a shovel was fitted. `MobileEngine.raised` seeds `full_head`.
- **Achievements are now scoped by machine** (`operation_type:`), so even an unseeded latch could
  only mislead its own machine's record.
