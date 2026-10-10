# Thermal injury, the splash vector, and why a district burns forever

Three things came out of one playthrough report: a mine that lit its sconces lost four fifths of
its district air in a couple of minutes, nothing on the panel said why, and the roadway then sat
at 1300 K for four and a half minutes with three men standing in it, unharmed, until the roof
came down on them.

The event half is fixed and shipped. This is the design for the rest, and it opens with two
measurements that change the brief.

---

# Part 0 — Two findings that reshape the brief

## The district was at 1% gas and should never have lit at all

Measured on ordinary ground, seed 1, fan at its default, at the moment the sconces are lit:

| | kg | m³ | by volume |
|---|---|---|---|
| air | 1654.6 | 1350.7 | **98.77%** |
| firedamp | 9.5 | 14.3 | **1.04%** |
| blackdamp | 2.1 | 1.5 | 0.11% |

Methane's lower explosive limit is about **5%**, and its upper about 15%. At 1.04% a naked light
burns calmly: that is the whole reason a flame lamp is an instrument — the cap is readable long
before the mixture will carry a flame. **The model has no flammability limit**, so any trace of
firedamp in a hot enough room ignites and keeps igniting.

This single gap produces everything that was reported:

1. A 1% mixture lights, which it must not.
2. Burning holds the district above `min_temperature_k`, so it keeps burning.
3. Every kilogram that seeps in afterwards burns on arrival, so firedamp reads **0.00 for the
   rest of the match** and the flame cap — the mine's signature instrument — says all clear
   while the roadway is an inferno.
4. The district settles at ~1300 K, and a fixed 1400 m³ volume at 1300 K holds 376 kg where at
   292 K it held 1667. That is the "disappearing air": it is **thermal expansion**, not
   consumption, and mass balance is constant across the whole run.
5. Four and a half minutes later the sustained over-temperature drains the roadway's durability
   and the roof comes down.

> **The specs already believe in the limit.** `dust_spec` asserts `gas_pct < 5.0` and then says
> *"whatever happens next is not the gas doing it"* — reasoning that is only valid if a 5% floor
> exists. It does not. The spec has been passing for the wrong reason.

## Raising the quench rate would not have worked

The obvious fix — make the dust fire quench hard so it flashes and subsides — cannot work as
stated, and it is worth saying why before anybody tries it.

```ruby
(rate(spec, :spread_per_s) * (1.0 - starved)) -
  (rate(spec, :quench_per_s) * [ chill, starved ].max)
```

`quench_per_s` is **multiplied by `max(chill, starved)`**. In a district at 1300 K with
`min_temperature_k: 600`, `chill` is zero; with the fan running, `starved` is zero. So the quench
term is zero whatever number is written there. A quench of 300.0 would behave exactly like the
current 0.30.

The instinct is right — *mines rarely stayed burning forever* — but the lever is the wrong one.
A real firedamp ignition stops because **the gas is used up and the mixture falls below the
limit**, not because the roadway cools and not because the air runs out.

---

# Part 1 — The flammability limit

## The model

A third gate beside `chill` and `starved`: how much of the volume is fuel.

```yaml
ignition:
  spread_per_s: 9.00
  quench_per_s: 0.20
  lean_fraction: 0.05   # below this the mixture will not carry a flame
  rich_fraction: 0.15   # above it there is not enough air in the mixture to burn
```

In `net_rate`, out-of-range is **total quench**, not reduced spread — a mixture below its limit
does not burn slowly, it does not burn:

```ruby
unlit = outside_limits?(spec, parcels, content) ? 1.0 : 0.0
(rate(spec, :spread_per_s) * (1.0 - starved) * (1.0 - unlit)) -
  (rate(spec, :quench_per_s) * [ chill, starved, unlit ].max)
```

**By volume, never by mass**, for the same reason `Breath` is: firedamp is 0.668 kg/m³ against
air's 1.225, so kilograms understate it by half. `Parcel.volume_m3` already exists and `Breath`
already does exactly this sum.

## What it buys

- **The flame cap becomes the instrument it was written to be.** The player watches a percentage
  climb toward a number that means something, and the fan is what holds it down.
- **A firedamp ignition flashes and goes out**, because burning the gas drops the mixture below
  the limit within seconds and the seep cannot hold it there.
- **Dust behaves differently from gas, correctly.** A dust cloud has no upper limit worth
  modelling and a much lower floor; it also *settles*, so a dust explosion runs out of suspended
  fuel rather than going lean. Dust wants `lean_fraction` only.
- `dust_spec`'s existing reasoning becomes sound.

## Alternatives considered

**(a) Raise `quench_per_s`.** Does nothing, for the reason in Part 0. Rejected on measurement.

**(b) Make the igniter self-extinguishing** — have `igniter_kg_per_s` stop once a fire is
established. Treats the symptom: the fire would still sustain on seeping gas at 1%, because
nothing says 1% cannot burn.

**(c) Raise `min_temperature_k` so a cooling district quenches.** Wrong direction — it would make
ignition *harder to start* and do nothing about sustaining, since a burning district is hot by
definition. It also breaks the one thing the current figure is for: a flame already present
carrying into gas that is below autoignition.

**(d) ★ A flammability range on the reaction.** The physics, the history, and the thing the specs
already assume. Costs one content key and one term in `net_rate`.

## Risk

Every mine hazard spec drives ignition, and several will now need the gas built up past 5% before
a flame does anything — which is a **more honest** setup for each of them, but it is real work:
`firedamp_spec`, `whitedamp_spec`, `afterdamp_spec`, `dust_spec` and `mine_tech_spec`'s lighting
block all ignite districts. Expect to re-time most of them.

---

# Part 2 — Ambient thermal injury

## The constraint

Same as every hazard here: **no per-tick dice.** `resilience` is rolled once at `initial_state`
and every check after is a deterministic comparison. Thermal exposure adds no entropy point.

## What the quantity is

Not temperature. **Heat delivered per second**, which is why 400 K air is a long shift's problem
and 373 K water is an emergency. The separation falls out of data `content/` already carries:

| | ρ (kg/m³) | c (J/kg·K) | **ρc (J/m³·K)** |
|---|---|---|---|
| air | 1.2 | 1005 | 1 231 |
| steam | 0.6 | 2010 | 1 206 |
| flue gas | 1.1 | 1100 | 1 210 |
| **water** | 997.0 | 4181 | **4 168 457** |
| coal dust | 800.0 | 1260 | 1 008 000 |

Water carries **3 386×** the heat of air per degree per cubic metre. No new content is needed for
the basic case, and a resource may override with an explicit `thermal_contact:` where the bulk
figure misleads.

```
flux ∝ Σ_parcels [ ρc(resource) × volume_share × (T − tolerated)^EXPONENT ]
```

**`EXPONENT ≈ 1.5.`** Linear in ΔT is not enough to separate the cases the brief asks for: 1300 K
air is only 12× the ΔT of 400 K air but should be roughly 60× as dangerous. 1.5 gives 41×, 1.6
gives 53×. It is also defensible as physics — convection runs about ΔT^1.25 and radiation adds a
steeply rising term on top.

`tolerated` is skin tolerance, ~318 K, **raised by toughness and by a `heat_resistance` tag**, so
a volcano suit is a shift in the threshold rather than a multiplier on the damage. A
`fire_elemental` tag is a gate — `unburning`, the exact shape of `Breath#unbreathing?`, which is
already the house pattern for "this does not apply to me at all".

## Where it runs, and what it grinds

A new step in phase 6 beside `endanger` and `tire` — the same *process*, its own hook:

```
6a stress   parts wear
6b endanger hazards from part failures
6b′ scorch  what the room is doing to people   ← new
6c tire     fatigue, and bad air
6d travel
```

**It grinds `resilience` directly, not fatigue.** That is the brief and it is right: heat is not
tiredness, and it does not recover by standing somewhere cooler for a minute.

> **It will need a dwell, exactly as `Breath` did.** Grinding resilience to zero proposes
> `:severe`, every bite after proposes `:severe` again, and `Severity.escalate` correctly refuses
> to announce the same injury twice — so nothing ever reaches `:mortal` without a bite of
> `Injury::MORTAL_BITE`, which a steady hazard never grows. `Breath` solved this with an
> `asphyxia` counter that delivers a bite that size at 1.0. Thermal wants a `burns` counter on
> the same pattern. **This is the single thing most likely to be missed**, and the symptom is a
> minion who is permanently `:severe` in a furnace and never dies.

Unlike asphyxia, **burns do not drain**. Walking out of the fire stops the accrual; it does not
undo it. That asymmetry is the difference between the two hazards and is worth keeping.

## Calibration targets

| exposure | intent |
|---|---|
| 1300 K gas | mortal in ~10 s, bare |
| 400 K gas | harmful over long exposure; minutes to a minor |
| 373 K water | very harmful in seconds |
| ≤ 318 K | nothing at all, ever |

The last row matters most: this must cost nothing in the overwhelming majority of every match,
the same discipline `Breath.rate` keeps by returning early above `SAFE`.

## Only the gas phase, and why

Ambient exposure reads **the gas in the room**, not everything in the volume. Otherwise a sump
with water in it cooks everybody at the pit bottom, which is absurd — you are standing beside
water, not in it. Liquids and melts reach people through Part 3.

---

# Part 3 — The splash vector

Burst steam from a pipe, slag slopping out of a ladle, a boiler letting go. The conventional
shape — **an event exposes whoever is in a place** — which is what `failure_hazards` and phase 6b
already do. The only new thing is that the damage is computed by Part 2's calculation instead of
being an arbitrary number on the hazard.

```ruby
failure_hazards: [
  { places: [ :boiler_house ], splash: { resource: :steam, kg: 40.0, temperature_k: 480.0 },
    tags: %i[scald] }
]
```

- **`kg` rather than a severity**, so the same mechanism answers "how bad" from the physics, and
  a bigger vessel is worse without anybody tuning a second number.
- **Resisted by the same `heat_resistance` and `unburning`** as ambient, so one suit protects
  against both and there is no second table to keep in step.
- **Tags still ride along** (`scald`, `burn`), because `Injury.resistance` already keys off tags
  and that is how gear gets specific.

This is deliberately the *smaller* half. It reuses phase 6b wholesale; the only genuinely new
code is the shared damage function, which Part 2 has to write anyway.

---

# Part 4 — Diagnostics

## Is the mine on fire

**Nobody could mistake a firedamp ignition** — the smoke, the heat, the noise. The event log is a
start and an event is a transition; a player who looks away for ten seconds needs the panel to
still be telling them.

A gauge off the district's `ignited_kg`, prose, four bands:

```
clear  ·  smoke in the return  ·  the district is alight  ·  the workings are burning
```

Needs a `SIGNATURES` entry (`ignited_kg`, or a fraction of fuel alight) and a slot in
`PANEL_ORDER`. Prose rather than a number, like the flame cap and for the same reason: nobody
underground reads their fire off a dial.

## The roof

Lower priority, and the brief says so. `roof_timber` already carries four prose bands off the
roadway's integrity. What it does not say is **why** it is deteriorating — a district that has
been on fire wears its roof far faster than one being cut too hard, and the gauge reads the same
either way. Explaining that belongs in the tutorial pass; the gauge itself probably only wants
its bands sharpening so the dangerous end is unmistakable.

---

# Sequencing

1. **The flammability limit.** Smallest, fixes the reported bug at its root, and changes what
   every later piece is calibrated against — so it goes first or everything is tuned twice.
   Expect to re-time the five mine hazard specs.
2. **The fire diagnostic.** Trivial once (1) lands, and it is what makes (1) legible.
3. **Ambient thermal injury.** The shared damage function, the `burns` dwell, phase 6b′, the
   `heat_resistance` and `unburning` tags, and heat-resistant gear in `content/`.
4. **The splash vector.** Reuses phase 6b and (3)'s calculation; mostly content and wiring.
5. **The roof bands**, whenever the panel is next open.

(1) and (2) are a release of their own and are worth shipping before (3) is started, because a
mine that no longer sits at 1300 K is a different thing to calibrate thermal injury against.

# Documentation owed

Per the change→file table in the root [`CLAUDE.md`](../../CLAUDE.md):

- [`reference/tick.md`](../reference/tick.md) + `lib/reactor_sim/CLAUDE.md` — phase 6b′
- [`reference/physics.md`](../reference/physics.md) — the flammability range and the thermal
  damage law
- [`reference/diagnostics.md`](../reference/diagnostics.md) + `diagnostics/CLAUDE.md` — the new
  `SIGNATURES` entry
- [`guides/add-content.md`](../guides/add-content.md) + `content/CLAUDE.md` — `lean_fraction`,
  `rich_fraction`, optional `thermal_contact:`, and the `heat_resistance` / `unburning` tags
- [`reference/nodes.md`](../reference/nodes.md) + `concerns/CLAUDE.md` — `splash:` on a hazard
- [`current_progress.md`](../current_progress.md) — the traps list gains the quench finding:
  **a rate multiplied by a gate is not a rate you can tune**
- `spec/CLAUDE.md` — a row per new spec file
