# Prompt reactions, and walls that cool

> **Status: agreed 2026-10-15, all four §6 recommendations taken. Both stages built — see §7 and
> §8 for where they departed from the draft.** Two parts
> that ship as two stages: a `PromptReaction` concern for
> anything that happens faster than a tick, and a `Wall` node so that what an explosion releases
> has somewhere to go. Found while replaying the first unit-3b playtest; the measurements are from
> that replay and from the whitedamp spec's own rig.

---

## 1. What is wrong

### 1.1 An explosion is integrated as if it were a fire

Firedamp burns at `rate_per_s: 18` and spreads at `9/s`, so from the moment it takes hold the
whole district burns in **about two ticks**. Each tick splits the burn between the clean pathway
and the CO pathway against the air left *that tick* (`Reaction.cascade`). So the products depend
on where the burn happens to fall on the tick grid.

Measured on `whitedamp_spec`'s starved ignition (8% by mass), changing nothing but the size of
the spark that lit it:

| Spark | Firedamp burnt | CO made |
|---|---|---|
| 4e-4 kg/s (the old candle) | 67.5 kg | 66.9 kg |
| 2e-5 kg/s (a real flame cap) | 69.0 kg | 22.5 kg |

The same fuel burnt makes three times the CO because of the tick boundary, not the
chemistry. The spark only shifts the phase of a logistic that is too fast to resolve.

### 1.2 Sub-stepping is the obvious fix and the wrong one

Sub-stepping phase 5 removes the dependence on the spark and converges, but slowly. The CO from
the same ignition was still falling at 64 sub-steps (8.6 → 7.0 → 4.9 → 4.0 kg at 8 / 16 / 32 / 64),
and the limit it converges to is wrong. A well-mixed reactor integrated finely burns clean until
the air is gone and then stops, so **a rich mixture makes almost no CO and leaves its fuel
unburnt**. A premixed flame does not do that. Each parcel of mixture burns with the air that is
in it, so a mixture richer than stoichiometric burns rich throughout and makes CO in proportion.
The products are set by the **mixture's own air-to-fuel ratio**, and no time integration of a
well-mixed node can recover that.

### 1.3 Nothing takes the heat away

The district is one lumped body: 1,400 m³ of gas plus `heat_capacity: 3.0e5` standing in for its
rock, at one temperature, losing 300 W/K to ambient. A 60 kg firedamp explosion releases
3.3 GJ. The replay holds the district at **2,500 K for more than five seconds at atmospheric
pressure** and it cools over minutes. A real roadway's gases cool within seconds against
thousands of square metres of rock. The rock barely warms, because it is a semi-infinite heat
sink, but it stays warm afterwards, which is its own hazard: hot strata re-light gas.

---

## 2. The principle

**A process whose own timescale is shorter than the tick is not integrated. It is resolved.**
Phase change already works this way: `Saturation.solve` snaps to equilibrium every tick because
evaporation is fast against 0.25 s. Integrating it was tried and made a vessel flip between 0 and
51 kg of steam on alternate ticks. Explosions are the second instance. The user has named more:
- flash heating, where molten iron atomised in water dumps its heat at once;
- water split by that heat, and the hydrogen consumed in the same instant;
- prompt-critical excursions in a reactor;
- viciously reactive chemistry generally.

Everything a prompt event needs is already on the node at phase 5. The mixture, its temperature,
what is alight and the heat it can release are all there. So a prompt event needs no rate. It
needs a **trigger** and a **resolver**.

---

## 3. Part A — `Concerns::PromptReaction`

### 3.1 Shape

```ruby
# phase 5, per node
state = if (event = node.prompt_event(state, ctx))
  node.resolve_prompt(event, state, ctx)      # may resolve a sequence; see 3.4
else
  run_reactions(node, state, ctx)              # as today
end
state = run_phase_change(node, state, ctx)     # always, after either
```

- **A node opts in by hosting a reaction that declares `prompt:`.** `Vessel` includes the
  concern, and it is inert unless a hosted reaction names a `prompt:` kind. Every node that hosts
  no such reaction takes today's branch bit for bit. That is the guard on the steam engine's
  digest, and a spec asserts it.
- **The trigger and the resolver are a pair, keyed by `kind:`**, registered in one small table
  (`PromptReaction::KINDS`). One kind ships, `:deflagration`. The table is the seam the later
  kinds slot into. It is marked `TODO:` with its named first callers (a fuel–coolant interaction
  for the foundry, prompt criticality for the reactor), and it says it is untested beyond the
  one kind.
- **It stays inside phase 5 and local to the node**, so order-independence holds by construction.
  No entropy. Nothing new in state except what the resolver writes into existing keys (`parcels`,
  `joules`, `ignition`, `joules_from_reactions`), so the ledger and snapshot need no change.

### 3.2 Content

```yaml
firedamp_combustion:
  # …everything it has today…
  prompt:
    kind: deflagration
```

`coal_dust_combustion` gets the same line. Nothing else in the game does. A fire bed stays a
rate-integrated fire, which is right: a grate is not premixed, and its air really does arrive
tick by tick.

Boot validation: a `prompt:` reaction must have an `ignition:` block with flammable limits (a
deflagration is a flame in a mixture), and `kind` must be registered.

### 3.3 `:deflagration`

**Trigger: the flame would finish within this tick.** The lit fraction grows logistically at
`spread_per_s`, so from lit fraction `f` the burn completes in about
`ln((1 − f)/f) / spread_per_s`. When that is less than `dt` the event is prompt. That means
`f ≥ 1 / (1 + e^(spread·dt))`, about 10% lit for firedamp at `dt` 0.25. Below that the
build-up stays rate-integrated as now. That is the flame accelerating from the candle, a second
or two, and it is what gives "the lamp flared, then the district went" its order. It also
scales with `time_scale` correctly: a longer tick makes more things prompt, as it should.

The mixture must also be within its flammable range. Outside it there is no front, and
`burn_down_ignition`'s one-for-one rule (already built) governs what a flame burns there.

**Resolution: the front passes through the whole mixture.** Every kilogram of fuel in the node
burns. Lean in-range mixtures burn to completion rather than "back down through the lean limit",
because a flame front consumes the mixture it runs through. A well-mixed node stopping at the
limit was a property of integrating it.

The pathway split uses **all the air in the node** against **all the fuel**, through the existing
`Reaction.allocate`: clean first, then the alternatives, spending exactly the air there is. That
gives the mass-balance answer, and it does not depend on the tick:

| Mixture | Outcome |
|---|---|
| at or leaner than stoichiometric | all fuel to CO₂; air left over |
| richer, but the CO pathway can afford it all | all fuel burns, split so the air is exactly spent; CO in proportion to how rich |
| richer than even the CO pathway can afford | the air caps it; unburnt fuel remains, now outside its range |

The released enthalpy goes into `joules` and `joules_from_reactions` exactly as
`run_reactions` does it. The node rebalances, so the temperature jumps by the whole release in
the tick. The lit mass of every fuel consumed resets. What remains is unlit and out of range.

### 3.4 Sequences

After a resolution, **re-check every prompt-capable reaction on the node** and resolve again,
until nothing triggers or `MAX_STEPS` (8) is reached. Two rules make the sequence chemistry
rather than declaration order:

1. **A front lights what it passes through.** Resolving a deflagration sets every other prompt
   fuel in the node fully lit, so a dust cloud in its own range is resolved in the next step with
   the air the gas left. That is Senghenydd, and it falls out without a special case: the gas
   flame raises the dust and the dust takes the explosion on.
2. **Candidates are walked in declaration order, one per step**, and the step re-reads the node.
   Determinism needs a fixed order, and re-reading means the second step sees the first's
   products, temperature and spent air.

`MAX_STEPS` is a safety net, not a mechanism. Hitting it emits nothing and logs nothing; a spec
asserts the shipped content never reaches it.

The chain the user named (molten metal into water → steam → dissociated hydrogen → hydrogen
burning) is three steps of this loop with two kinds that do not exist yet. Nothing in this design
blocks it.

### 3.5 An event

`:explosion`, emitted once per resolution with `{ reactions:, fuel_kg:, joules: }` in its
detail. A node's `endangers:` can then key on it, and severity can `scales_with:` the joules,
which is the established pattern for a failure's size. Today the district's blast is felt only
through its eventual rupture and the heat. This is a decision point (§6).

### 3.6 What changes in play

- **The explosion arrives a tick or two sooner and all at once.** The rate-integrated build-up
  to 10% lit is unchanged, so the time from "gas in range" to "explosion" barely moves.
- **Rich explosions make far more CO** — mass balance says the spec's 8% mixture (about 14% by
  volume) makes over 100 kg — and stoichiometric or lean ones make none. That is historically
  right: the afterdamp that killed most of the survivors came from rich burns and from dust.
  `whitedamp_spec`'s claim that "any ignition makes a little monoxide" was a tick artifact and
  will be rewritten as the mass-balance claim.
- **Seed size no longer matters**, which is what the realistic candle figures need.

### 3.7 Alternatives considered

- **Sub-stepping phase 5.** §1.2: slow to converge, costly, and converges to the wrong answer.
- **Only change the pathway split (supply = burnt × the mixture's air/fuel), keep the rate.**
  This was my first recommendation, and it fixes the products. It leaves the burn spread across
  ticks with venting between them, so how much fuel burns still depends on the phase (48 to
  61 kg across the sub-step runs). It has no sequence, so dust cannot take an explosion on in
  the same instant. And it does not generalise to flash heating or criticality at all. The
  concern is the same split plus a trigger and a loop.
- **Mark the reaction prompt with no trigger: lit and in range means resolve now.** Simpler, and
  it deletes the flame's acceleration. A candle meeting 5.1% gas would explode on the tick the
  gas crossed the line, with no flare first. The "would finish this tick" trigger costs one
  logarithm.

---

## 4. Part B — `Nodes::Wall`

### 4.1 Shape

A room's rock or brick becomes **its own node**, because it has its own temperature. That is the
lumped body's standing rule: distinct temperatures are distinct nodes.

```ruby
Nodes::Wall.new(id: :district_rock, material: :coal_measures, area_m2: 2_000.0, skin_m: 0.02)
ThermalLink.new(a: :district, b: :district_rock, conductance: FILM * 2_000.0,
                emissivity: GAS_EMISSIVITY, radiating_area_m2: 2_000.0)
```

- **`Wall`**: `Thermal` (and `Wearing`, so a later pass can spall or collapse it when hot).
  It has no ports and holds nothing.
  - Its heat capacity is derived: `area × skin × ρ × c`.
  - Its ambient conductance is derived: `area × k / skin`, conduction into the strata behind it.
    The ambient reservoir *is* the deep rock.
- **The link carries the gas-to-wall exchange**:
  - a convective film `h × area`, which is constant;
  - radiation from the hot products through the link's existing `emissivity:`. That is
    radiation's existing machinery, so it goes as T⁴ and is unconditionally stable.
- **Material gains `thermal_conductivity_w_per_m_k`**, and content gains a rock (`coal_measures`:
  sandstone and shale, ρ 2,400, c 850, k 2.0). Validation requires conductivity on any material a
  `Wall` names.

### 4.2 Why a single skin

Rock is a semi-infinite solid. Heat put into its face penetrates `√(αt)`: about 3 mm in ten
seconds, a centimetre in a couple of minutes, ten centimetres in a few hours. One lumped skin
of depth `skin_m`, backed by conduction into the strata, has the right two limits:
- at short times it absorbs a blast's heat at the face;
- at long times it passes heat on into the rock.

Its time constant is `ρ c skin² / k`, which is 400 s at 2 cm, about right for the minutes over
which a district matters. If one lump proves too crude, a second skin node behind the first is
the refinement, and it needs no new mechanism.

### 4.3 The district, sized

These are first figures, to be swept rather than trusted.

| | Value | Basis |
|---|---|---|
| Rock face | ~2,000 m² | 200 m of roadway, ~10 m perimeter |
| Film `h` | 15 W/m²K | forced convection in a ventilated road |
| Gas emissivity | 0.2 | hot CO₂/H₂O over a few metres |
| Gas→wall at 2,000 K | ~230 kW/K | film plus radiation |
| Gas heat capacity | ~1.8 MJ/K | 1,600 kg |
| **Gas cooling time** | **~8 s** | against hundreds of seconds today |
| Skin capacity (2 cm) | ~80 MJ/K | |
| Skin→strata | 200 kW/K | |
| A 3.3 GJ blast warms the skin | ~40 K | then soaks away over minutes |

The district's own `heat_capacity` drops to its gas and fittings. The `3.0e5` that stood in for
the rock moves to the wall, and is replaced by the real figure, which is 250 times larger.

The **pit bottom** gets a wall too, being the other air volume where fires and blasts happen.
The roads and the shaft stay as they are for now (§6).

### 4.4 What changes in play

- **A blast's heat lasts seconds, not minutes.** Burns become a flash at the moment of the
  explosion. What kills afterwards is the afterdamp, which is the history.
- **Hot rock is a re-ignition source.** The wall is a natural `hot_spot:` for the district's
  gas. After a fire, strata past firedamp's 870 K can light the next build-up with no flame
  present. That is historically real (the second explosion that caught rescuers), and it
  needs only `hot_spot:` to accept a list.
- **Ordinary heat sources barely move the district.** The candles, the gob and the crew heat
  80 MJ/K of rock rather than 0.3, so the bug that baked this playtest's district could not
  have happened even with the old candle figures.
- **The same node is every room's walls** in every later operation: the engine house, the
  furnace lining, a retort, the reactor's concrete.

### 4.5 Alternatives considered

- **Raise the district's `ambient_conductance` to ~230 kW/K.** One number, no new node. It makes
  the rock an infinite sink at 293 K, so a fire can never heat its roadway and hot strata
  cannot exist. It also cools a candle's district as hard as a blast's. It is wrong at both ends.
- **Keep the rock lumped with the gas, just much larger.** Then the gas cannot be 2,000 K while
  the rock is 330 K, which is the whole phenomenon.

---

## 5. Staging

**A — the concern and `:deflagration`.** The concern, the kind table, the content line on
firedamp and coal dust, and boot validation. Specs:
- a node hosting no prompt reaction is bit-identical to today (the steam engine's digest);
- **the products do not depend on the spark** (the two seeds above give the same CO to float
  precision);
- the three mixture rows of §3.3 by mass balance;
- dust in its range is taken on by a gas front in the same tick, and not without one;
- the trigger waits for the build-up;
- conservation through a resolution.

Then the three specs held in the last pass are re-measured on the new chemistry, not before.

**B — `Wall`.** The node, the conductivity field and rock, walls on the district and pit
bottom, and `hot_spot:` accepting a list. Specs:
- a blast's gas cools within seconds and the skin warms by the right order;
- hot strata light gas past autoignition and cold strata do not;
- conservation;
- a node with no wall is unchanged.

Then the district-thermal figures are re-measured (gob timing, scorch) and the docs are written.

The burn-down fix, the realistic flame seeds and the gob blowout fix from the playtest stay as
they are. They are correct whichever way this lands, and the burn-down rule is what governs a
flame in an out-of-range mixture after a deflagration has passed.

---

## 6. For review

1. **Trigger**: "the flame would finish within this tick" (keeps the flare before the blast),
   against "lit and in range" (instant). Recommend the first.
2. **`:explosion` event** carrying the joules, so a blast can hurt people by its size at the
   moment it happens, rather than only through the later rupture and the heat. Recommend yes.
   Which hazard tags it carries is a content decision for the mine pass.
3. **Which rooms get walls in stage B.** Recommend the district and the pit bottom. The roads
   are conduits and hold no gas of their own; the shaft and bank can follow when a fire there
   matters.
4. **Gas emissivity as a fixed figure on the link** for now, against deriving it from the CO₂
   and H₂O actually in the node. Recommend fixed, with the derivation as a named seam: it
   matters for furnaces, where luminous flame is the lever.

---

## 7. Stage A, as built

Four departures from §3, each forced by a measurement.

**The trigger is "alight and in range", not "would finish this tick"** — reversing §6.1, which
recommended the opposite. On the sealed ignition rig the "finish this tick" trigger let the
rate-integrated build-up burn up to half the fuel before it fired, and in a well-mixed node that
burning dilutes the mixture. A 9% district lit by the old candle never went off at all. It sat at
1,868 K, burning slowly, with 28 kg of gas left below its lean limit. A 6% district under a real
flame cap did the same. The flare §3.3 wanted is not real at room scale anyway: a flame is
self-propagating at a kernel of centimetres, and the seconds a front takes to cross a roadway are
what a lumped node cannot represent. So a flame laid this tick goes off on the next, the lit mass
being as of last tick. The spark's size then changes nothing: a candle and a flame cap leave the
same district to 1e-3 kg.

**A premixed fuel's lit share gets only its share of the air, in the rate path too**
(`Reaction.premixed_share`). Without it, the gram or so a flame burns before its front still
burnt clean against the whole room's air.

**The node's `reaction_throttle` is the share of the mixture a front can carry through.** Without
it, stone dusting stopped working: the prompt path never asked the district how inerted its dust
was. In the rate path the throttle scales `dt`; with no rate, it scales the fuel reached
(`Reaction.complete(share:)`), and a cloud that is two-thirds stone is never a candidate at all.

**Each reaction resolves at most once a tick, so there is no `MAX_STEPS`.** That bounds the
loop, and nothing shipped needs a second pass. The fuel–coolant chain the user named needs
different kinds in sequence, which this allows. A kind that genuinely needs to repeat within a
tick is the point to add the cap back.

Measured on the rig, every row of §3.3 lands on the mass-balance answer:

| Mix (by volume) | Outcome |
|---|---|
| 6% and 9% | all fuel burnt, no CO |
| 12% | all fuel burnt, air exactly spent, 193 kg CO |
| 14% | air spent, 19 kg of gas left |
| 9% gas over a 200 kg dust cloud | the gas burns first; the dust takes the 123 kg of air the gas left, 57 kg CO |

`whitedamp_spec` was rewritten on the chemistry. Its "clean" mixture had been 6% by mass, which is
slightly rich (15.7 kg of air to the kilogram against the 17.2 a clean burn takes), and its claim
that "any ignition makes a little monoxide" was a tick artifact. It is now 5% (19:1), and the claim
is that a lean ignition makes none.

---

## 8. Stage B, as built

**Rock is in the material catalogue**, as the user asked. `coal_measures` has density 2,400,
specific heat 850 and conductivity 2.0, and no strength or rating, because nothing is built of
it. Every existing material gained a real `thermal_conductivity_w_per_m_k`. `Wall` resolves its
figures from its `material:` at build, the way the engine's bearings resolve theirs.

**The cooling is slower than §4.3 estimated.** Sealed, a blast's gas falls from 2,400 K to
1,486 K in 5 s, 923 K in 20 s and 549 K in a minute, and the rock face peaks 36 K warm. The 8 s
figure assumed the radiation term at 2,000 K throughout, but it falls away as the gas cools, and
the film's 15 W/m²K is a ventilated road's, not a blast's wake. Both are tuning items, and the
order is right.

**The blast had to become the harm.** A walled district sheds its heat before it can wear
through its 480 K rating, so the rupture that used to carry the blast stopped happening. Measured,
its durability fell 35 of 1,129 and nobody was hurt by the blast at all. So:
- the `:explosion` carries `mode: :explosion`;
- phase 6b looks it up in `endangers:` the way a failure is looked up;
- phase 6 spends its `damages:`.

The district's blast scales with its joules (reference 3 GJ). It blows the door out, and it
spends half a sound roadway's durability, which is force rather than heat: timbering blown out,
the roof let down. A sound district stands one explosion and a worn one is wrecked, which keeps
`firedamp_spec`'s claim that an explosion wrecks a damaged district true by the right mechanism.
`injury_spec`'s walker accepts `:explosion` for a node hosting a prompt reaction
(`PromptReaction#prompt_modes`), and checks a scale against what the event reports.

**The district and pit bottom's own heat capacity is now their gear's** (2e4 each), and their
ambient conductance went to the rock. The pit bottom therefore heats when a blast's gas arrives,
to about 1,300 K, where its old lumped 2e5 J/K held it down. The putter there is burnt lightly
(0.17, against the face's 0.78). That is plausible for a big explosion, since flame ran hundreds
of metres in the real ones. But it exposes a gap: **gas is not cooled in transit**, because the
main road is a conduit with no residence.

Re-measured on the new physics, and rewritten to assert the mechanism, not a figure:
- `blackdamp_spec`'s "dispersed" became "outlives": against an unlit twin on the explosion tick.
- `blackdamp_spec`'s "starves" now reads the explosion's joules, 4.63 → 4.08 → 3.66 GJ.
- `afterdamp_spec`'s burns are the gradient face > pit bottom > bank.
- `dust_spec` and `firedamp_spec` still assert the rupture: the blast's damage to the roadway
  wrecks a worn one.

Replayed, the playtest that started all this holds the district at 291–293 K, burns nobody, and
gets crew_10 to the onsetter's post.

**Retuned after review: twenty seconds at over 900 K would roast the blast's survivors** before
the afterdamp ever reached them. The first figures were a smooth bore's face and a ventilated
road's film. Checked against the literature on fire gas in mine drifts, three things were low:
- rough rock stirs the gas and has more face to lose heat to;
- measured coefficients run 25–50 W/m²K;
- radiation is most of what an explosion's products lose to the walls, and a blast's cloud
  carries dust and soot.

So: a 30 W/m²K film, an emissivity of 0.4, and `ROCK_ROUGHNESS` 2. A district blast is now
2,700 K at the flash, 559 K five seconds on, 413 K at ten and 338 K at twenty; the pit bottom
reaches 343 K by ten. `afterdamp_spec`'s claims went back to the stark gradient: the face is burnt
in the flash, the pit bottom not at all, and the cause on record is the blast. **A cooling step
inside the prompt resolution was considered and not needed**: it would trim only the one-tick
adiabatic flash, which is real, and the walls already carry the rest on the existing machinery.
