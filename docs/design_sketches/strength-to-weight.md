# `strength` becomes a ratio, and absolute force is derived

> **Built.** §1's prediction held for every strength-1.0 fixture and was *not quite* right about
> the rest — see §9. One decision changed in review: **`strength` stays legal as an `effort:` key**
> rather than being superseded, because a more specific caller should win.

Design input. Small in code, large in meaning: it changes what the most widely-read stat in the
game *says*.

Today `strength` is an **absolute** figure calibrated against whatever constant happens to read
it, which is why an ogre needed `5.0` and still could not express the thing that makes an ogre an
ogre. The proposal: **`strength` is a strength-to-weight ratio, 1.0 being a human's**, and
anything that needs absolute output derives it from the ratio and the body.

---

## 1. Why this is safe to do now

**Every balance fixture in the repository is a 70 kg person.** Nine `mass_kg: 70.0` declarations
across `PitRig`, `ReferenceCrew`, `MineTech`, `PerilCrew`, `SlipCrew`, `LeverCrew` and
`PassageRig`, and no others. So with

```
force = strength × mass_kg ÷ REFERENCE_MASS_KG          # 70 kg
```

every fixture has `force == strength` exactly, and **not one measured figure in the repo moves** —
the steam engine's 608 kPa / 174.6 rpm / 398 kW, the mine's cutting rates, the walk times, the
misread gradient, the slip rates. Only real content changes, and real content is four races.

This window closes the moment a fixture needs a non-human. It is open today.

## 2. The two derived quantities, because mass pays off differently per job

One derived number is not enough, and the brief says why: an ogre swinging the same pick should be
**about twice** a trained human, but pushing a tub it should be far more, because "the extra
friction and leverage matters most" there.

| Quantity | Definition | Human | Ogre | Kobold | For |
|---|---|---|---|---|---|
| `strength` | the ratio itself | 1.00 | 0.65 | 0.70 | **pace** — how fast a body moves itself |
| `force` | `strength × mass ÷ 70` | 1.00 | 4.64 | 0.25 | pushing a tub, heaving rock, a heavy lever |
| `swing` | `√force` | 1.00 | **2.15** | 0.50 | a tool at the end of an arm |

`√force` is the whole of the "about twice" requirement, and it is not arbitrary: a pick can only
be swung so fast and bites only so deep, so bulk stops paying linearly. A scaled-up pick is then
the upgrade that unlocks the rest — content, not code.

**Each is 1.0 for a reference human**, which is what keeps `effort:` weights summing to 1.0
meaningful and every existing station's declared throughput true.

> **`PACE` needs no change and becomes *more* correct.** It reads `strength`, which now means
> strength-to-weight — exactly what decides how fast something moves its own body. An ogre does
> not walk 4.6× faster than a man, and under the old meaning it would have.

## 3. Race figures

Ratios, so **below 1.0 means worse pound-for-pound than a human**, which is the square-cube law
and is why big animals cannot carry their own kind.

| Race | `strength` was | now | `mass_kg` | `force` | Reading |
|---|---|---|---|---|---|
| human | 1.0 | **1.00** | 70 | 1.00 | the reference, unchanged |
| elf | 0.75 | **0.85** | 60 | 0.73 | light but not weak for its size — "less back" was always about size |
| kobold | 0.35 | **0.70** | 25 | **0.25** | small *and* scrawny. Weaker in absolute terms than before, which is the intent |
| ogre | 5.0 | **0.65** | 500 | **4.64** | pound-for-pound worse than a man; overwhelming anyway, because there is half a tonne of him |
| *(draught horse, later)* | — | 0.50 | 700 | 5.00 | pulls a sled, carries three people, **cannot carry another horse** |

The kobold moving from 0.35 absolute to 0.25 absolute is the one deliberate nerf. They get
*better* at swinging a pick (0.50 against 0.35) and worse at putting, which is the right
redistribution: a scrawny thing can still chip at a face, and cannot shift a loaded tub.

## 4. Station assignments — the part that wants your eye

`effort:` keys become stats **plus** `force` and `swing`. Proposed:

| Station | Today | Proposed | Why |
|---|---|---|---|
| `hewing` | `strength 0.7, dexterity 0.3` | `swing 0.7, dexterity 0.3` | a pick at the end of an arm |
| `haulage` (putting) | `strength 0.8, toughness 0.2` | **`force 0.8`**, toughness 0.2 | a loaded tub is friction and leverage |
| `timbering` | `strength 0.6, dexterity 0.4` | **`force 0.6`**, dexterity 0.4 | props and bars are heavy things lifted into place |
| `stoking` | `strength 0.75, dexterity 0.25` | `swing 0.75, dexterity 0.25` | a shovel is a tool |
| `ash_raking` | `strength 0.6, dexterity 0.4` | `swing 0.6`, dexterity 0.4 | likewise |
| `blower` (bellows) | `strength 0.8, toughness 0.2` | **`force 0.8`**, toughness 0.2 | heaving a handle against resistance |
| `oiling` | `dexterity 0.6, intelligence 0.4` | unchanged | no force in it |

Two other absolute-force readers move to `force`:

- **`Minion#rate_multiplier`** — how fast somebody shifts a stiff lever. A big lever wants a big
  body.
- **`Burden.lift_kg`** — picking a casualty up.

## 5. What `LIFT_KG` becomes

With `force` in the limit, `LIFT_KG = 130` hits every target in the brief. Computed against real
content, each casualty carrying an ordinary pick:

| Carrier | `force` | Limit | Carries | Margin | Two of its own kind |
|---|---|---|---|---|---|
| human | 1.00 | 130 | a human | **+78%** | **no** (146 > 130) |
| human | 1.00 | 130 | somebody half again their weight | +20% | — |
| elf | 0.73 | 95 | a human | **+30%** | no |
| kobold | 0.25 | 33 | one kobold | **+16%** | **no** (56 > 33) — and never an elf or a human |
| ogre | 4.64 | 604 | another ogre | **+20%**, and slowly | no |

Nobody can carry two of their own kind, which no requirement asked for and is the right answer.

## 6. The edits

| File | Change |
|---|---|
| `sheet.rb` | `REFERENCE_MASS_KG`; `DERIVED = %i[force swing]`; `STATS` doc rewritten — `strength` is a ratio |
| `minion.rb` | `#force`, `#swing`; `capability` resolves derived keys; `rate_multiplier` → `force`; `PACE` unchanged |
| `control_point.rb` | `effort:` validates against `STATS + DERIVED` (it already refuses weights that do not sum to 1.0) |
| `burden.rb` | `lift_kg` → `force`; `LIFT_KG` 118 → 130 |
| `races.yml`, `crew.yml` | the four ratios above |
| both `parts.rb` | the table in §4 |
| `add-content.md`, `content/CLAUDE.md`, `concerns/CLAUDE.md` | `strength` is a ratio, and what derives from it |

## 7. What this does not touch

- **`mass_kg` stays required and stays out of the lift limit directly.** It enters through `force`
  exactly once; adding a second mass term would double-count the body.
- **`Burden`'s pace penalty** is already `load ÷ own mass` and is unaffected.
- **The four invariants.** No new entropy, no new state, no command change.
- **Every measured balance figure**, per §1 — which is the whole reason to do it today.

## 9. Where §1 was over-confident

"Not one measured figure moves" is true of every fixture at `strength` **exactly 1.0**, which is
most of them — `ReferenceCrew`, `PitRig`, `MineTech`, `SlipCrew`, the passage walker. It is *not*
true of a fixture at any other strength that works a `swing` station, because `swing` is `√force`
and `√1.2 ≠ 1.2`: `peril_spec`'s 1.2-strength hand hews a little less than before, which can shift
an accident's timing by a few ticks.

`force` stations are genuinely unchanged at reference mass, and `strength` stations trivially so.
The claim should have been **"every figure measured with a reference human, and every `force`
station at reference mass"** — narrower, and still the reason to do this today.

Measured after the change: 147 examples across `carrying`, `minion`, `fatigue`, `passage`,
`lever_travel`, `content`, `crew` and `kit` — all passing.

## 8. The one risk

`effort:` keys are currently validated against `Sheet::STATS`, so a typo'd `swing` would be
refused at build — good. But a station left reading `strength` when it *meant* `force` is
**silent**: it still builds, still sums to 1.0, and simply makes a big worker no better at a
heavy job. There is no way for the engine to catch that, so §4's table is the record of the
decision and wants to be right rather than quick.
