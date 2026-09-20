# Radiation

> **Status: agreed in conversation 2026-09-18, building now.** The shape was settled before this
> was written; this records why, and the one identity that makes it cheap.
>
> **Balance is explicitly not a consideration.** This is pre-alpha and the point is to get the
> physics right — good physics means fewer special cases later and better emergent play. Expect
> the steam engine's figures to move, and do not tune them back.

---

## 1. What is missing

**Nothing in this engine radiates.** Heat leaves a node one way, `settle_ambient`, and that way is
linear:

```ruby
q = Relaxation.to_reservoir(node.total_heat_capacity(state, content),
                            node.temperature_k(state, content),
                            node.ambient_k, node.ambient_conductance, dt)
```

Two consequences, one small and one not.

**A seized bearing settles at 1652 K** — the honest equilibrium of 57 kW against 42 W/K, and
nonsense. A body that hot radiates far more than it conducts, and the model has no term for it. On
a heavier flywheel the same bearing reaches **15,563 K**, which is the tell that the behaviour is
unbounded rather than merely mis-scaled. `bearings.md` §3.11 tried to fix this with the melt and
measured that it does not: 31 K off the spike, nothing off the equilibrium.

**A firebox heats its boiler through a plain conductance.** This is the bigger one. The steam
engine's fire reaches 900–1300 K and the water sits near 450, and the path between them is
`radiant` in name only:

```ruby
ThermalLink.new(a: :firebox, b: :boiler, conductance: 3500.0)
```

A real firebox delivers most of its heat to the water legs by radiation, which goes as `T⁴`. A
linear term cannot express the thing every fireman knows — that a *bright* fire is worth far more
than a merely hot one — so the engine currently rewards fuel in the box rather than heat in the
fire.

---

## 2. The physics, and the identity that makes it cheap

```
Q = εσA (T⁴ − T_amb⁴)
```

`T⁴` is violently nonlinear, and this library forbids any integrator that is only stable for small
steps — `time_scale` 40 means `dt = 10 s`. Applied explicitly this would be exactly that mistake.

**It factors, exactly:**

```
T⁴ − T_amb⁴  ≡  (T² + T_amb²)(T + T_amb) · (T − T_amb)
                └──────── h_rad ────────┘
```

That is an identity, not an approximation. So

```ruby
h_rad = emissivity * STEFAN_BOLTZMANN * area * (t**2 + amb**2) * (t + amb)
```

is a genuine **conductance in W/K**, and radiation becomes an ordinary term in machinery that
already exists — `Relaxation.to_reservoir` for the ambient case, and a link conductance for the
body-to-body case. Both are backward Euler, unconditionally stable at any `dt`, and converge on
the sink rather than overshooting it.

**The only error is evaluating `h_rad` at the start-of-tick temperature.** That is first order in
`dt`, the same order as everything else here, and it errs in the safe direction: as a hot body
cools within a tick its true `h_rad` falls, so the fixed one **under**-states the cooling. It
cannot overshoot past the sink, and it cannot go negative.

> **Why not solve the quartic properly.** The closed form for radiative cooling to a fixed sink
> exists and involves `arctan` and `log`. It would be exact for the ambient case and **still
> wrong** for the link case, where both ends move — so it buys exactness in the easy half and
> nothing in the hard half, for a much worse-looking function. The linearised conductance is
> uniform across both.

---

## 3. Where it lands

### 3.1 To the environment

`Concerns::Thermal` gains two config readers, and radiation is added to whatever conduction the
node already declares. They are separate mechanisms and a part is entitled to differ in each: a
lagged drum conducts and radiates little, a bare hot pipe does both freely.

```ruby
def emissivity = 0.0          # opt-in: nothing radiates until it says so
def radiating_area_m2 = 0.0
```

> **`settle_ambient`'s guard has to change.** It currently skips any node whose
> `ambient_conductance` is not positive. A node that radiates but barely conducts — which is most
> hot things in a machine — would be skipped entirely.

### 3.2 Between two bodies

`ThermalLink` gains an optional emissivity and area. When present, `settle_heat` computes the
link's conductance from the two end temperatures instead of reading a constant.

`Arbiter` already has the right vehicle: `Coupling`, the struct the **gas** solve uses to hand
`Relaxation` a conductance computed per tick. Thermal links map onto it the same way, so
`Relaxation` needs no change at all.

### 3.3 Emissivity is the part's, not the material's

Same call as `Flywheel#safety_factor` and `Pressurized#safety_factor`, and for the same reason: a
surface property is not a bulk property. Oxidised iron runs near 0.8 and polished steel near 0.1,
and the difference between them is a wire brush, not a different metal. A lagged boiler and a bare
one are the same steel.

---

## 4. What it changes on purpose

**The boiler comes with this release, not after it.** It is the proof of concept and the reason
the work is worth doing:

- A bright fire becomes disproportionately better at raising steam, which is true and is the thing
  a linear conductance cannot say.
- The blower and the damper get sharper, because they change fire *temperature*, not just fuel
  burnt.
- A choked or banked fire falls off far faster than its temperature drop suggests, because the
  loss goes as the fourth power.

**Expect every steam-engine figure to move**, including the ones in `bearings.md` §6.3 and the
cold-start gradient. That is intended. Do not tune them back to where they were.

**The bearing is a side effect, not the goal.** At ε 0.8 and 0.2 m² a seized journal radiates
about 67 kW at 1652 K — more than the 57 kW going in — so the equilibrium falls to roughly 1200 K,
and the 15,563 K rig case collapses entirely. The unbounded behaviour stops existing rather than
being clamped.

---

## 5. What this must not foreclose

- **View factors and geometry.** Real radiant exchange depends on what can see what.
  `emissivity × area` is a lumped surrogate, and a future geometry model should be able to replace
  the product without changing the call sites.
- **Emissivity from the material.** Putting it on the part is right today; a future `materials.yml`
  default that a part overrides is a refinement, not a contradiction.
- **Radiation into a gas rather than past it.** Flue gas is genuinely participating — it absorbs
  and re-emits — and this models a transparent path. Do not build anything that assumes the only
  radiative link is body-to-body.
- **The ambient temperature being a constant.** It already is, everywhere; radiation does not make
  that worse, but a hot workshop is a real thing and `ambient_k` is per node for a reason.

---

## 6. Verification

- **A hot body cools faster than conduction alone**, and the gap grows with temperature — assert
  the ratio rather than pinned figures.
- **`h_rad` is exact at the factoring**: for any `T`, `h_rad × (T − T_amb)` equals
  `εσA(T⁴ − T_amb⁴)` to float precision. This is the one thing that can be tested as an identity,
  so test it as one.
- **Nothing overshoots ambient at any `dt`**, including `dt = 10⁶` — the standing test for every
  integrator here, and the reason the factoring was chosen over an explicit term.
- **The same interval settles the same at any `dt`**, to first order: one step of 10 s against
  forty of 0.25 s.
- **A node with no emissivity is bit-identical to today.** This is what makes the opt-in claim
  checkable rather than asserted, and it is the assertion that lets the release land without
  touching anything that has not opted in.
- **Conservation holds**, with radiated energy on `joules_to_ambient` exactly as conducted energy
  is — no new ledger line, because it is the same crossing by a different mechanism.
- **The firebox→boiler link moves more heat when the fire is brighter**, superlinearly: double the
  temperature difference and the transfer more than doubles.

---

## 7. As built

Landed 2026-09-18. `Relaxation` needed **no change at all** — the factoring meant every seam
already existed, which is the sign the approach was right.

### Calibrating the split, which took two goes

**The firebox link is `conductance: 1100.0, emissivity: 0.9, radiating_area_m2: 24.0`.** It
replaced a flat 3500 W/K, and **the total at the working point is what had to be preserved** —
the flat figure was standing in for radiation all along, so this release changes the *shape* of
the path rather than its size. At fire ~1020 K and water ~430 K the radiant term is about
2180 W/K and the sum is ~3280.

**The first split shipped was 900 W/K and 12 m², and it was wrong by 38%.** It summed to about
2200 W/K, and the failure mode is worth knowing because it reads backwards:

| | total h | firebox settles at | cold start at t=1700 |
|---|---|---|---|
| old, pure conduction | 3500 | 1008.6 K | 571.8 kPa |
| **first split, 900 + 12 m²** | **2205** | **1103.5 K** | **472.6 kPa** |
| as built, 1100 + 24 m² | 3281 | 1022.0 K | 547.8 kPa |

**An under-strength path makes the fire run hotter, not cooler**, because the heat cannot leave
it — so the instrument that looks like a better fire is the bottleneck. It cost four spec
failures: the reference cold start stopped reaching working pressure, so `steam_raised` never
fired and three achievement-pipeline examples went with it.

**The firebox, measured across the damper at throttle 100 / load 100 / stoking 100:**

| damper | firebox K | radiant kW | convective kW |
|---|---|---|---|
| 100 | 956.2 | 981.0 | 576.3 |
| 85 | 967.7 | 1031.2 | 588.9 |
| 60 | 990.5 | 1136.2 | 614.1 |
| 40 | 1009.6 | 1229.9 | 635.1 |

From damper 100 to 40 the firebox brightens by a factor of 1.056. **Convection rises 1.102×** —
exactly the ratio of the temperature differences, as a linear term must — and **radiation rises
1.254×**, exactly the ratio of `T⁴ − T_water⁴`. The T⁴ law is doing the work and it is checkable
rather than merely plausible. Radiation carries about **63%** of the path, which is a firebox.

> **The boiler sits at 432.3 K at every damper in that table — it is on its safety valve.** The
> link transfers are still honest, because they are computed from the two end temperatures, but
> **nothing about the engine's response to the damper can be read off this run.** In particular
> it does not demonstrate an optimum draught setting; both terms rise monotonically as the damper
> closes over the range measured. Demonstrating an optimum needs the boiler off its valve and a
> wider sweep, and has not been done.

**The bearing**, which was the original complaint:

| | seized bearing settles at |
|---|---|
| before | 1652.4 K |
| after | **1201.2 K** |

18.8 kW radiated against 38.1 kW conducted, summing to the 57 kW the engine supplies. The
unbounded behaviour is gone because the missing physics arrived, not because anything was clamped.

> Those two figures were taken **before** the firebox split was recalibrated, and what a seized
> journal is fed depends on what the engine makes. The *bound* is robust — a body that hot
> radiates far more than 42 W/K can conduct, whatever drives it — but the settling temperature
> will have moved and has not been re-measured.

### Two things to know

> **The cold-start gradient and every figure in `bearings.md` §6.3 are stale**, because the
> firebox path's temperature dependence changed even though its working-point magnitude did not.
> Re-measure rather than reading them.

> **The safety-valve trap was walked into twice, in two different disguises.** First as a damper
> sweep at throttle 60 that read 608.1 kPa at every setting — the valve, not the fire. Then again
> in the sweep above, where the *boiler* is pinned at 432.3 K at every damper, which is why no
> claim about the engine's response to draught can be made from it. `spec/CLAUDE.md` records the
> trap. **Measuring the heat a link moves is immune to it; measuring anything downstream of the
> drum is not**, and "I measured a link this time" is not the same as "the run was unconfounded".
