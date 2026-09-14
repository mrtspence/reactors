# Obstruction: incompressible matter where it should not be

> **Status update, 2026-09-08: §6 is built, except step 4.** `Concerns::Obstructs` (B2),
> `Cylinder#compression_pressure_pa` (A2), `ReliefValve#senses_quantity:`, the speed-graded
> failure (A4) and a firebox choked by its own ash — with an ashpan and a lever, because a
> deposit with no remedy is a dead end rather than a mechanic. **Step 4, entrainment (A5a), is
> built as `Node#transport_affinity` (see
> [`tag_based_transport_overrides.md`](tag_based_transport_overrides.md)), and **hydraulic lock
> is now demonstrated**: a primed boiler feeding a standing cylinder reaches occupancy 2.87
> against the 1.0 that locks it, the cocks hold it at 0.0003, and opening them halfway to lock
> recovers it. Reachable, preventable, recoverable.
>
> **Two explanations for why it would not fill were confidently wrong before the right one was
> measured**, and both are recorded in [`../current_progress.md`](../current_progress.md)
> because the pattern matters more than the answer: it was never a resolution limit and never
> condensation — it was two ordinary bugs (a clearance priced as a gas mass, and a standing
> cylinder that admitted only a static top-up), found by measuring the water budget instead of
> reasoning about it.
>
> ~~Still true: a locked cylinder can stall this engine but cannot break it.~~
>
> **Correction, 2026-09-09.** That was diagnosed as structural — filling needs a standstill,
> destruction needs speed, the two cannot coexist — and the *symptom* was real but the cause was
> not. **The piston never asked for a slug.** `displacement_kg` priced the swept volume at the
> working fluid's *gas* density, so a cylinder sweeping 0.0496 m³ a tick (49.6 kg if that volume
> is water) demanded 0.126 kg, and a steam chest full of primed water handed it a few hundred
> grams. Positive displacement means the machine swallows a **volume** and gets whatever is in
> it — `Holds#bulk_density_kg_m3`.
>
> §2.2's "graded by speed" also did not survive. Speed was a proxy for the thing that matters,
> which is whether the driveline carries enough **energy** to compress the trapped charge to top
> dead centre — so `lock_omega` is gone and `overload?` compares
> `node_kinetic_joules(drives)` against `compression_work_joules`. Both terms were already in
> state, and it makes the *flywheel* the danger, which is what §2.2's own sources describe.
>
> §2.6's void fraction turned out to belong in two places, not one: the firebox uses it as a
> static packing figure, and **the boiler uses it as a transient** — swell, driven by the rate of
> pressure fall, which is what lifts a high water level into the steam offtake. See
> [`tag_based_transport_overrides.md`](tag_based_transport_overrides.md) for the carryover half.

**Status: design sketch.** Input to a decision.

Written because a tuning fix was about to be applied to a modelling gap. The specific problem is
hydraulic lock in a steam cylinder; the general one is that **this simulation has no way to say
that an accumulated deposit is obstructing a mechanism**, and it is going to need one repeatedly
— ash and clinker on a grate, tar in a line, scale in a boiler tube, slag in a furnace.

Related: [`cylinder_solutions.md`](cylinder_solutions.md) built the cylinder this sits on;
[`transport_model.md`](transport_model.md) §5 designed the entrainment seam §6.3 depends on.

---

## 1. What already exists, exactly

### 1.1 The one rule that is already right

`Holds#room_m3` charges **condensed phases** for volume and charges gases nothing:

```ruby
condensed = parcels(state).reject { |p| content.tags(p.fetch(:resource)).include?(:gas) }
[ volume_m3 - Parcel.total_volume(condensed, content), 0.0 ].max
```

`Pressurized#free_volume` does the same and floors the result at
`MINIMUM_FREE_VOLUME_FRACTION` (0.001) so the ideal gas law cannot run away. This is the correct
foundation and none of the proposals below disturb it: **a gas expands to fill what it is given
and raises the pressure; a liquid or a solid takes the room away.**

### 1.2 The gap, stated precisely

Volume occupancy has exactly **two** consequences in the codebase today:

| Consequence | Where | Effect |
|---|---|---|
| Less room to accept condensed matter | `Holds#room_m3` → `Arbiter.scale_by_sink_room` | intake is capped |
| Higher pressure for the same gas | `Pressurized#free_volume` | pressure rises |

There is no third. **Nothing anywhere can say that a deposit obstructs a flow, a mechanism or a
reaction.** That is the whole of the missing concept, and both the specific and the general
problem below are instances of it.

### 1.3 What the cylinder has now

`Cylinder#liquid_fraction` is the only place in the codebase that measures occupancy against a
**characteristic** volume rather than against the whole node:

```ruby
Parcel.total_volume(liquid, content) / (@volume_m3 * @clearance_fraction)
```

For the high-pressure engine: swept 0.174927 m³, clearance 0.013994 m³, total 0.188921 m³. The
clearance space holds **14.0 kg of water** at 1000 kg/m³, and that is the number the whole
hazard is scaled against.

Just built (landing 3 of `cylinder_solutions.md`): a `:drain` port, cylinder cocks as a
`Conduit` with a lever, a prose `cylinder_water` gauge, and `overload?` firing at
`liquid_fraction >= integrity` but only while the shaft turns.

### 1.4 Measured, on the engine as it stands

```
A:  running, cocks shut       water=0.038 kg  liq=0.003  rpm=182.4  kW=436.11
A2: running, cocks OPEN       water=0.001 kg  liq=0.000  rpm= 53.9  kW= 16.37
B:  flywheel burst at 2400,
    regulator left open       water=0.285 kg  liq=0.019  rpm=  0.0  never locks
C:  as B, cocks opened later  water=0.000 kg  liq=0.000
```

**Three separate defects, and only one of them is a tuning problem.**

1. **The hazard is unreachable.** Reaching lock needs 14.0 kg; the worst case reached 0.285 kg
   and stalled there. A stopped cylinder admits only `clearance_fill_kg` — a one-off top-up to
   chest density — so accumulation has no engine behind it. **The consequence is built and the
   cause is not.**
2. **The consequence is a step where reality is a ramp.** `overload?` is a threshold at
   `liquid_fraction` 1.0 and nothing whatever happens below it. §2.2 says that is wrong.
3. **The cocks are a cliff, not a trade-off.** 436 kW → 16 kW. Most of that is not the steam
   lost — it is the `extractable_joules` bound in `Tick#transmit_torque` running out of charge
   to bill. Re-sizing the cocks moves the cliff; it does not make it a slope.

### 1.5 What the general case has now: nothing

`ash` is `tags: [solid, waste]`, 700 kg/m³, produced by both combustion reactions, and
**accumulates in the firebox forever** — nothing consumes it and no operation removes it.
Measured at 10.839 kg in normal running, which is 0.0155 m³ against a 6 m³ firebox: **0.26%**.
Its only effects today are thermal mass and that 0.26% of lost room.

So the fire cannot be smothered by its own ash, a pipe cannot cake up, and a tube cannot scale.
Each would currently need its own bespoke rule.

---

## 2. What the literature says

### 2.1 The threshold is the clearance volume, and that part we have right

Hydrolock is "a volume of liquid greater than the volume of the cylinder at its minimum (end of
the piston's stroke)". So `liquid_fraction >= 1.0` measured against the clearance volume is the
correct criterion, and `Cylinder#liquid_fraction` is already the right quantity.

Steam engines get there two ways, and the sources name both: **condensation on cold walls**, and
**water carried over from the boiler**. The mitigation is cylinder drain cocks.

### 2.2 The damage is graded by speed, not binary

This contradicts what was just built:

| Engine state | Outcome |
|---|---|
| At speed | "a mechanical failure is likely" — bent or broken connecting rods, fractured crank, head or block |
| Idling / low power | the engine "may stop with minimal damage" |
| Stopped | the starter burns out; "the engine typically survives" |

The current `overload?` gets the stopped case right by accident (it returns `false` at ω = 0)
and collapses the other two into one. **Momentum is what does the damage**, which is a quantity
the cylinder can already read.

> **CORRECTION (2026-09-10).** "Graded by speed" was built as `omega > lock_omega` and that was
> the wrong reading of this table. Speed is a *proxy*. What decides whether the piston reaches
> top dead centre is whether the driveline carries enough **energy** to compress the trapped
> charge — which is why the sources talk about rods and cranks rather than rpm, and why a
> starter motor burns out where a flywheel bends a rod. Built as
> `node_kinetic_joules(drives) > compression_work_joules`; `lock_omega` is gone.
>
> The proxy was not merely imprecise, it was **unreachable**: filling needed a standstill and
> destruction needed speed, and a locked cylinder makes negative torque so it can never
> accelerate from one into the other. The energy form has no such gap, because the same slug at
> the same speed breaks a heavy wheel and stalls a light one — asserted in `obstruction_spec`.

### 2.3 The pressure rise is smooth, steep, and starts long before the threshold

This is the finding that supplies the missing derived quantity. From reciprocating-compressor
practice, where liquid slugging is the same failure:

- "Even with a moderate volume of liquid present inside the cylinder, the pressure could reach
  values as high as **four to five times its normal value**, with a correspondingly higher rod
  load."
- Slugging takes cylinder pressures from ~400 psi to **~3000 psi** — 7.5×.
- "A slug of liquid will bend a rod, blow a head gasket, or destroy a cylinder **in one
  revolution**."

So there *is* a continuous, physically-defined quantity between "dry" and "destroyed": the
pressure the charge reaches at top dead centre when the clearance space is partly full of
liquid. That is what over-loads the rod, what a relief valve senses, and what fatigues the
metal — and it is a derivation, not a stored number, which is exactly the convention this
codebase is built on.

Bulk modulus is what bounds it in reality — "assuming the cylinder and lines to be rigid, the
fluid's bulk modulus will determine peak pressure" — so the divergence is steep but finite.

### 2.4 Real drain cocks discriminate

A ball-type automatic cylinder cock "allows water to pass, but blocks the flow of steam". The
steam-wasting trade-off is therefore a property of **simple** cocks, not of cocks in general —
which makes the automatic type a real upgrade with a real behavioural difference, rather than a
strictly-better part.

### 2.5 The general accumulation model: deposition minus shear removal

Kern and Seaton, and fifty years of work after it:

```
dR/dt = ṁ_deposition − ṁ_removal        →       R = R∞ · (1 − e^(−kt))
```

Konak generalises to `dR/dt = k₀(R∞ − R)ⁿ`, which reduces to Kern–Seaton at n = 1. Removal is by
"the action of turbulent eddies" and **rises with flow**: "as the deposit builds up, the flow
area is reduced, and the velocity increases, allowing the foulant removal by shear forces."

That is why real fouling reaches an asymptote instead of growing without bound, and it is the
same closed-form shape `Resources::Ignition` and `Reaction` already use. **We would not be
importing a new kind of mathematics.**

### 2.6 The general consequence model: void fraction

Pressure drop through a packed bed is governed by its **void fraction**, via Ergun. Blockage is
modelled as reduced voidage: "a decrease in void space is an indication that the catalyst bed is
plugged... the pressure-drop change due to plugging is calculated by the Ergun equation." And
usefully for a firebox: "a bed of ash particles has the highest voidage, followed by the char
bed and then the coal bed with the lowest voidage."

---

## 3. The problem, restated in this codebase's terms

### 3.1 The specific problem

The cylinder is a **cycle averaged over a revolution**. It has no crank angle, so every
crank-angle-dependent phenomenon has to be *reconstructed* from the averaged state as a derived
quantity. `mean_effective_pressure` already does exactly this for the work: it reconstructs the
area of an indicator diagram the model never traces.

Hydraulic lock is the same kind of reconstruction and has simply not been done. `pressure_pa`
reports the charge spread over the **whole** cylinder volume, so filling the clearance space
with 14 kg of water — enough to destroy the engine — moves it by about 7%, because 0.014 m³ out
of 0.189 m³ is all that is lost. **The pressure that matters is one the lumped body never
experiences**, and that is why a relief valve cannot currently sense the thing it exists to
catch.

### 3.2 The general problem

> Condensed matter accumulates somewhere it is not wanted, and past some fraction of a
> **characteristic volume** — which is usually *not* the node's total volume — it obstructs the
> mechanism rather than merely taking up room.

The characteristic volume and the consequence differ by mechanism, and that is the whole of the
variation:

| Mechanism | Characteristic volume | What occupancy does | Example |
|---|---|---|---|
| Swept-volume machine | clearance volume | compression pressure ↑, then lock | water in a cylinder |
| Conduit | bore | conductance ↓, then plug | tar, scale, coke |
| Reacting bed | void space between fuel | air cannot reach fuel; reaction chokes | ash, clinker |
| Vessel | total volume | free volume ↓, pressure ↑ | **already modelled** |

The fourth row is the one we have, and it is the special case where the characteristic volume
happens to be the whole node. That is why the existing machinery looks sufficient until you meet
one of the other three.

---

## 4. Options for the specific problem — hydraulic lock

### A1 — Keep the threshold, tune the cocks

Leave `overload?` as a step at 1.0 and re-size the drain cocks so open cocks cost perhaps 20%
rather than 96%.

**Pros.** One number. Zero risk. Half an hour.

**Cons.** It does not touch any of the three defects in §1.4. The hazard stays unreachable, so
the failure mode is dead code that no player will ever meet; the consequence stays binary; and
the cliff is caused by the `extractable_joules` bound, not by the cock rating, so re-sizing
moves it rather than removing it. **This is the change that was about to be made and it is a
tuning fix applied to a missing concept.**

### A2 — Derive the compression pressure at top dead centre *(recommended)*

Add one derived quantity to `Cylinder`:

```
V_start = clearance + compression_fraction × swept      # volume at exhaust closure
V_tdc   = clearance − liquid_volume                     # what is left for gas at TDC
P_tdc   = P_back × (V_start / V_tdc)^n
```

floored the way `free_volume` already is, so it is steep but finite — which is what bulk modulus
does in reality (§2.3). Worked for the high-pressure engine at `compression_fraction` 0.15,
n = 1.135, back pressure 101 kPa:

| clearance full of liquid | V_tdc (m³) | P_tdc | vs dry |
|---|---|---|---|
| 0% (dry) | 0.01399 | 336 kPa | 1.0× |
| 50% | 0.00700 | 738 kPa | 2.2× |
| 90% | 0.00140 | 4.58 MPa | 13.6× |
| 100% | floored | destructive | — |

**Pros.**
- It is the quantity the literature actually describes, and it lands in the 4–5× band the
  compressor sources give for "a moderate volume of liquid" (§2.3).
- **It is a derivation, not stored state** — exactly the convention in `physics/CLAUDE.md`, and
  it cannot drift from the contents causing it.
- It makes a cylinder relief valve *work*. `Nodes::ReliefValve` senses a pressure; give it this
  one and the safety device catches the hazard it is named for, with no new machinery. That was
  the thing I had to report as impossible last time.
- It makes hydraulic lock **graded**: `stress_per_second` can fatigue on the over-pressure long
  before `overload?` fires, so a cylinder that is regularly run wet wears out, which is both
  real and a better teacher than a sudden death.
- It supplies the **compression event** the indicator diagram is currently missing, so
  `mean_effective_pressure` can eventually subtract the compression work it should already be
  subtracting. One derivation, two payoffs.
- `compression_fraction` is a real valve-gear property, so it is configuration rather than a
  fudge factor.

**Cons.**
- One more config number per cylinder, and a reader has to understand what it means.
- It reconstructs a crank-angle quantity from an averaged state, so it is a *model* of the
  compression stroke rather than the stroke itself — a fair criticism, and the same one that
  applies to `mean_effective_pressure`, which has earned its keep.
- Needs a `SIGNATURES` entry and a new gauge if the player is to see it.

### A3 — Model the compression stroke explicitly in the diagram

Extend `mean_effective_pressure` to trace all six events including exhaust closure and
compression, and take the lock condition out of the resulting curve.

**Pros.** The most physically complete. Fixes the diagram's missing negative work properly.

**Cons.** Considerably more arithmetic for a diagram whose other five events are already
adequate, and the lock criterion still reduces to A2's `V_tdc` at the end of it. A2 is the
useful half of this; do A3 later if the diagram needs it for its own sake.

### A4 — Grade the failure by stored momentum

Replace the boolean `overload?` with a rule that reads the shaft: no damage stopped, a stall at
low speed, destruction at speed (§2.2).

**Pros.** Matches the sources exactly. Cheap. Makes the stopped-and-flooded state a *recoverable
predicament* — drain it and you are fine — which is far better play than an invisible timer.

**Cons.** "Stall" is not currently expressible; the closest thing is dumping the shaft's angular
momentum, which is what `Tick#stress` already does to a burst rotor. Needs a decision about what
a stalled engine *is*.

**Should be taken together with A2**, not instead of it: A2 supplies the ramp, A4 the endpoint.

### A5 — Make the hazard reachable

Neither A2 nor A4 matters while §1.4's defect 1 stands. Two candidate causes:

- **A5a — boiler priming / carryover.** The violent case, and the one the sources single out:
  "the problem with serious priming is that the water volume is far greater than that from
  condensation." Needs the `entrainment(state, ctx, phase)` hook from
  [`transport_model.md`](transport_model.md) §5. **Note the constraint the measurements add:
  this cannot be done with port tags.** Making the boiler's `steam_out` permissive lets
  `Parcel.draw` take resources proportionally, and the boiler holds 2600 kg of water against a
  few kg of steam — it would carry over essentially everything. The fraction has to be small and
  set by the source, which is precisely why a hook is needed rather than a tag change.
- **A5b — cyclic wall temperature.** Our cylinder condenses far less than a real one (measured
  3.5% of throughput before the steam chest, and 0.3% after) where the literature says a
  saturated engine loses **40–50% of admitted steam** to the walls. The reason is the same
  averaging as §3.1: a real cylinder wall is cooled to near back-pressure saturation by the
  exhaust and reheated by admission every revolution, and a lumped body at one temperature
  cannot swing. Modelling the swing would make condensation realistic and lock reachable without
  priming — but it is a second reconstruction and a bigger one.

A5a is the better first move: it is already designed, it is needed for its own sake, and it
makes priming a hazard that travels between nodes rather than one confined to the cylinder.

---

## 5. Options for the general problem — obstruction

### B1 — Nothing generic; each node solves it its own way

**Pros.** No new abstraction. Each rule can be exactly right for its own case.

**Cons.** Guarantees three or four incompatible spellings of the same idea, which is how
`max_kg_per_s` and `conductance` came to be two laws for one restriction. The pattern is
*already* three-for-one — cylinder, grate, pipe — so this is choosing the known-bad option with
the evidence in hand.

### B2 — An `Obstructs` concern

A concern a node opts into, providing `characteristic_volume_m3` and getting `occupancy` (0..1)
plus a hook for what it means.

```ruby
module Concerns::Obstructs
  def occupancy(state, content)
    condensed = parcels(state).reject { |p| content.tags(p.fetch(:resource)).include?(:gas) }
    Parcel.total_volume(condensed, content) / characteristic_volume_m3
  end
end
```

**Pros.**
- Matches how everything else in this codebase composes — `Thermal`, `Holds`, `Pressurized`,
  `Wearing` are all exactly this shape, opt-in with config as readers.
- Names the concept once. `Cylinder#liquid_fraction` becomes `occupancy` against the clearance
  volume and stops being a one-off.
- **The consequence stays with the node**, which is right, because it genuinely differs: a
  conduit scales its conductance, a bed scales its reaction rate, a cylinder derives `P_tdc`.
- Zero cost to nodes that do not include it.

**Cons.**
- A thin concern — it is one derived fraction. Worth asking whether it earns a file.
- "Condensed" is not always the right filter: a cylinder cares only about *liquid*, a grate
  about *solid* ash, and a coked pipe about a solid too. Needs a declared tag filter, which is
  one more config knob.

### B3 — Fold it into `Holds` as an optional second volume

Give `Holds` an optional `obstruction_volume_m3` defaulting to `volume_m3`, and add
`occupancy` beside `room_m3`.

**Pros.** No new file; sits exactly beside `room_m3`, which is the same computation with a
different denominator. Every holder gets it free.

**Cons.** Puts a mechanism-specific idea into the most general concern in the codebase, and
`Holds` is deliberately minimal — its docstring makes a point of having been cut down from the
old `Buffer`'s four jobs. A vessel has no characteristic volume other than its own, so most
nodes would carry a meaningless default.

### B4 — A full deposit model: Kern–Seaton state per node

Track a deposit thickness as state, with deposition and shear-driven removal terms, per §2.5.

**Pros.** The real model, and it produces the asymptote for the right reason.

**Cons.** **We do not need it yet, and we may never.** The material is already tracked — ash and
condensate are ordinary parcels with ordinary volumes — so the accumulation half is *already
solved by the parcel system*. Kern–Seaton would be a second, parallel accounting of the same
matter, which is exactly the kind of duplicate bookkeeping that produced the net-vs-gross ledger
bug. What we lack is the *consequence*, not the accumulation.

The one genuinely useful idea to take from it: **removal should scale with flow.** That is
already the shape of `Cylinder#exhaust_demand_kg` (swept mass rises with revolutions) and would
be the shape of ash removal by draught. Take the insight, leave the state.

---

## 6. Recommendation

**A2 + A4 for the cylinder, B2 for the pattern, and A5a to make any of it reachable.** In that
order, because each is useful before the next lands.

1. **`Concerns::Obstructs`** (B2) — one derived fraction against a declared characteristic
   volume and a declared tag filter. `Cylinder#liquid_fraction` becomes its first caller and
   loses its bespoke arithmetic.
2. **`Cylinder#compression_pressure_pa`** (A2) — the derived quantity. Then a cylinder relief
   valve that senses it, `stress_per_second` fatiguing on it, and `SIGNATURES` plus a gauge so
   the player can be warned before it is fatal.
3. **Grade the failure** (A4) — stopped is safe, slow is a stall, fast is destruction.
4. **Entrainment** (A5a) — the transport hook, which makes priming real and hydraulic lock
   reachable. Also the point at which the drain-cock trade-off becomes worth tuning, because
   only then does it protect against something.

The cock re-sizing (A1) should happen inside step 4 and not before: **there is no way to judge
what open cocks should cost until there is something they are protecting against**, and its
present 96% cliff is mostly the `extractable_joules` bound, which is a separate known artifact.

What this buys beyond the cylinder: ash smothering a fire and tar plugging a line both become
`Obstructs` plus three lines of consequence in the node that owns the mechanism, rather than
three unrelated inventions. That is the test the abstraction has to pass, and it is the same
test `Variants` passed for operations.

---

## 7. Verification

- **The clearance volume is the threshold.** 14.0 kg of water in the high-pressure cylinder must
  read `occupancy` 1.0; half of it, 0.5.
- **Compression pressure is monotone in occupancy and steep near the limit**, and equals the
  ordinary compression cushion when dry. A unit rig, not an engine run.
- **A relief valve set below the destructive pressure lifts before `overload?` fires.** This is
  the test that the safety device is actually a safety device.
- **Running normally never locks**, on both variants, over a long run.
- **Standing with the regulator open does lock**, and the same run with the cocks open does not.
  Fails today — the hazard is unreachable — and this is the acceptance test for A5a.
- **Damage is graded**: stopped and flooded must be recoverable by draining, with no event.
- **`Obstructs` is generic**: a second node type uses it with a different tag filter and a
  different consequence, ideally in the same commit, or the abstraction has not been tested.
- Conservation and determinism re-baselined; `performance_spec` unaffected (all derivations, no
  new state).

---

## 8. Sources

- [Hydrolock — Wikipedia](https://en.wikipedia.org/wiki/Hydrolock)
- [EFRC Guidelines on how to avoid liquid problems (reciprocating compressors)](https://www.recip.org/wp-content/uploads/2020/04/EFRC-Guidelines-for-Liquids-Version-3-August-2018.pdf)
- [Bulk Modulus: What is it? When is it Important? — Power & Motion](https://www.powermotiontech.com/hydraulics/hydraulic-fluids/article/21885008/bulk-modulus-what-is-it-when-is-it-important)
- [Fouling and Mechanism — IntechOpen](https://cdn.intechopen.com/pdfs/82713.pdf)
- [Models of fouling in heat exchangers — Heat Exchanger World](https://heat-exchanger-world.com/models-of-fouling-in-heat-exchangers/)
- [A Review of Crystallization Fouling in Heat Exchangers](https://psecommunity.org/wp-content/plugins/wpor/includes/file/2302/LAPSE-2023.5350-1v1.pdf)
- [Flow Through Packed and Fluidized Beds — R. Shankar Subramanian, Clarkson](https://people.clarkson.edu/projects/subramanian/ch330/notes/Flow%20Through%20Packed%20and%20Fluidized%20Beds.pdf)
- [Extending the Ergun equation for large particles (coal, char, ash beds)](https://www.sciencedirect.com/science/article/abs/pii/S0016236115005323)
- [Condensation / Wall Effects — Advanced Steam Traction](http://advanced-steam.org/ufaqs/condensationwall-effects/)
