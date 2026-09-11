# The cylinder: what it should be, what it is, and four ways out

> **Status update, 2026-09-08: landings 1 and 2 of §5 are built.** Option B was taken. The
> cylinder works an indicator diagram from a **steam chest**'s pressure, its intake is positive
> displacement at supply density, and condensate can leave. What remains is landing 3 —
> hydro-lock, drain cocks and the entrainment rule of §4.2 — plus the atmospheric decay noted in
> §2.3. Everything below is left as it was written, because the reasoning is what made the
> decision; **four things in it did not survive contact and are corrected in the boxes marked
> CORRECTION.** See [`../current_progress.md`](../current_progress.md) for what is true now.

**Status: design sketch.** Input to a decision, not a description of the system. Written when the
working tree held a half-applied attempt (§2.2) that was not verified.

> Written after the transport rebuild of 2026-09-05 closed every other item in the physics
> autopsy. The cylinder is the one that did not fall out, and the reason it did not is
> structural rather than numerical: **one node is being asked to be three different things at
> once, and the three contradict each other.** No amount of retuning fixes that, which is why
> the first attempt measured as inert.

Related: [`transport_model.md`](transport_model.md) §5 designed the entrainment seam this
depends on and predicted the flooding in §2.3 below, three days before it happened.

---

## 1. What a steam cylinder actually is

Researched rather than assumed, because the previous attempt was built from half-remembered
thermodynamics and got the *diagram* right while getting everything around it wrong.

### 1.1 Six events, not one state

The indicator diagram is the machine. It plots cylinder pressure against piston position, and
**the area inside it is the work per cycle**. Its events, in order:

| Event | What happens |
|---|---|
| **Admission** | The valve opens; pressure rises to steam-chest pressure |
| **Cut-off** | The valve shuts, at fraction ρ of the stroke |
| **Expansion** | The trapped charge goes on pushing, pressure falling along `pVⁿ` |
| **Release** | The exhaust valve opens, before the end of the stroke |
| **Exhaust** | The return stroke sweeps the charge out against back pressure |
| **Compression** | The exhaust valve shuts early, so the piston recompresses the residue |

The critical structural point: **a cylinder has no single pressure.** It has an admission
pressure, a cut-off pressure, a release pressure, a back pressure and a compression pressure,
and they differ by more than an order of magnitude within one revolution. A lumped-body node
holding one charge at one pressure cannot express that, and the number it reports is
approximately the *release* pressure — the least useful of the five.

### 1.2 Cut-off does two things at once, and the ratio is the whole game

Per unit of swept volume, with cut-off ρ, clearance c, admission pressure P₁, back pressure P₂
and polytropic index n:

```
mass admitted per cycle  ∝  (ρ + c) · ρ_steam(P₁, T₁)          <- linear in ρ
work per cycle           =  MEP · V_swept
MEP                      =  P₁ · (ρ + ρ·(1 − ρ^(n−1))/(n−1))  −  P₂
```

At ρ = 1 the expansion term vanishes and MEP is just `P₁ − P₂` — the flat-pressure formula the
node used before. At ρ = 0.25 with n = 1.135 the bracket is 0.566, so it is **57% of the work on
25% of the steam**. That is expansive working, and it is the entire reason the machine has a
reverser as well as a regulator.

> Late cut-off gives maximum starting force and poor economy; early cut-off gives greater
> thermodynamic efficiency and lower mean effective pressure. A driver opens the regulator wide
> and controls the engine on the cut-off.

Our model has to make **one lever move two quantities in opposite directions.** Today it moves
them in the same direction, which is why it reads as a second, worse throttle.

### 1.3 The steam chest is where admission pressure is decided

Open Rails — the closest thing to a reference implementation, a simulator that has been modelling
steam locomotives against real indicator cards for a decade — structures the calculation as a
chain of *pressures*, not as a container:

```
boiler pressure
  → steam chest pressure          (drop through the regulator and pipework, speed-dependent)
    → initial pressure, point a   (drop through the port into the cylinder — "wire-drawing")
      → cut-off pressure, point b (port restriction and condensation)
        → MEP                     (the diagram)
          − back pressure         (exhaust restriction)
```

Two of those drops rise with speed, and that is what limits a steam engine's power at the top
end: not the boiler, but the cylinder's ability to breathe. Open Rails calls this out explicitly
— IHP climbs with speed to a peak, then falls, limited by "the cylinder's ability to maintain an
efficient throughput of steam."

**We have none of this chain.** Our throttle is a conduit, and a conduit holds nothing and has no
pressure, so there is no node anywhere between the boiler and the cylinder that a pressure can be
read from. That absence is why the diagram had nothing sensible to use as P₁.

### 1.4 Cylinder condensation is the largest single loss, and it is what stops you notching to zero

This is the finding that changes the design, and it was not in the previous attempt at all.

When the cylinder wall is below the saturation temperature of the incoming steam, the incoming
steam condenses on it — giving up its latent heat to the metal and disappearing from the diagram
before it does any work. It re-evaporates later in the stroke at a lower pressure, where it is
worth much less. The gap between the steam the indicator diagram accounts for and the steam
actually measured going in is called the **missing quantity**.

Magnitudes, from Porta via Advanced Steam Traction:

- **40–50% of the steam admitted** in a saturated engine fed at 8–12 bar, and more in a badly
  lagged one. This is not a rounding error; it is the dominant loss in the machine.
- The wall temperature swing is "roughly inversely proportional to the cut-off and to rotational
  velocity to the power of −0.3." **Shorter cut-off makes it worse. Slower running makes it
  worse.**
- In a typical locomotive with 400 °C steam, walls exceed 210 °C only above roughly 20% cut-off.
- Superheat is the cure: every 7 K of superheat is worth about 1% of steam consumption. Open
  Rails encodes the whole effect as a flat correction — **+20% steam for saturated, −40% for
  superheated** — rather than modelling it.

The game consequence is large and it is the missing half of the cut-off mechanic:

> **The reason a driver cannot simply notch to 5% and run on nothing is that the efficiency the
> diagram promises is eaten by condensation before it arrives.** There is an optimum cut-off,
> it moves with speed and with how hot the cylinder is, and finding it is skill.

Our simulation can produce that emergently rather than by a correction factor — but *only* if the
cylinder keeps a wall with a heat capacity and a charge that can condense against it. Every
option below that deletes the held charge deletes this too.

### 1.5 Water in the cylinder is a routine hazard with routine remedies

Water is not compressible. If enough of it collects in the clearance space the piston has
nowhere to go, and something gives — usually a cylinder cover. It arrives two ways:

- **Condensation**, on a cold or standing engine. Normal, expected, continuous.
- **Priming**, when the boiler carries liquid water over with its steam. Violent, and the reason
  the failure is worth fearing.

And it is dealt with two ways, both of which map onto parts we already have:

- **Drain cocks** (cylinder cocks) — opened by the driver when warming through and when
  starting, shut once the cylinder is hot. On some designs they open automatically under a
  hydraulic lock. *This is a `Conduit` with a `control_id` and a liquid tag. We have that.*
- **Spring-loaded relief valves**, one at each end of the cylinder, set near boiler pressure, as
  the last chance before massive damage. *This is `Nodes::ReliefValve`. We have that too.*

So the user's instinct is right: the relief valves are close to free. What is **not** free is the
part that makes hydro-lock a *hazard* rather than a *certainty* — see §4.

---

## 2. What the code does today

### 2.1 The node is asked to be three things

`Nodes::Cylinder` includes `Thermal`, `Holds`, `Pressurized` and `Wearing`, and is therefore
simultaneously:

1. **A pressure vessel.** It has a volume, it holds parcels, and `Pressurized#pressure_pa`
   derives a pressure from them. The panel has a `cylinder_pressure` gauge pointed at it.
2. **A positive-displacement machine.** It should swallow `(ρ + c) × V_swept` of steam per
   revolution, which is a function of geometry, speed and cut-off — and of *nothing it holds*.
3. **A cycle.** Its work is an area on a diagram between an admission pressure and a back
   pressure, neither of which is the pressure of a settled lumped charge.

These are not merely three responsibilities in one class; they are **mutually inconsistent
physics**. (1) says the node's pressure is what its contents imply. (3) needs P₁ to be the
*supply* pressure. (2) needs a demand rule that ignores what is held. Every defect below is one
of the three fighting another.

### 2.2 The working tree state

`git diff --stat lib/reactor_sim/nodes/cylinder.rb` → **94 insertions, 9 deletions, unverified.**
The applied part is the indicator diagram of §1.2:

- `mean_effective_pressure(supply_pa, back_pa, cutoff)` — verified correct standalone, exactly
  backwards-compatible at ρ = 1, peak efficiency 1.91× at ρ = 0.25.
- `displacement_kg` and a `cutoff_fraction`, with `MINIMUM_CUTOFF = 0.05`.
- `breathing_fraction` scaled by cut-off.
- `plan` drawing `min(port_capacity, max(displacement_kg, headroom))`.

**The diagram is right and it is inert.** All four measurements below were taken with it applied.

### 2.3 Four measured defects

#### D1 — the demand rule is self-referential, and the wrong term wins anyway

`plan` draws `max(displacement_kg, headroom)`. Measured at t = 3600, throttle 100, stoking 80,
load 80, high-pressure variant, all figures kg per 0.25 s tick:

| cut-off | held gas | water | ρ_held | ρ_supply | disp @ρ_held | disp @ρ_supply | **headroom** | boiler kPa | rpm | kW |
|---|---|---|---|---|---|---|---|---|---|---|
| 100 | 0.2071 | 13.975 | 1.096 | 2.291 | 0.1213 | 0.2534 | **0.2187** | 444.7 | 151.8 | 145.00 |
| 60 | 0.2198 | 8.173 | 1.163 | 2.328 | 0.0694 | 0.1389 | **0.2271** | 452.7 | 136.4 | 107.48 |
| 25 | 0.2701 | 2.213 | 1.429 | 2.500 | 0.0240 | 0.0420 | **0.2209** | 489.2 | 92.1 | 35.39 |

Two separate faults, visible side by side:

**The headroom term is flat and always wins.** It is `ρ(P_supply, T_cyl)·V_free − held_gas`,
which contains no cut-off term at all — 0.219 to 0.227 kg across the whole range. It exceeds the
displacement at every setting, so the `max` selects it every time and cut-off never reaches the
demand. Measured consequence, steam consumption against cut-off:

```
   cutoff      rpm        kW     boilP  steam_kg/s  kW_per_kg/s
      100    160.2     168.5    467431      0.8896        189.5
       80    156.2     157.1    468157      0.8908        176.4
       60    142.7     122.0    470409      0.8947        136.4
       40    114.5      65.6    473995      0.9009         72.8
       25     72.4      17.9    476980      0.9059         19.8
       15     27.5       1.2    486711      0.8191          1.4
```

**Steam consumption is flat to three significant figures while power falls 140-fold.** Notching
up costs everything and saves nothing — the exact inverse of the real machine. (0.889 kg/s is
0.2224 kg/tick, i.e. the headroom term, confirming it is what binds. The throttle's 0.25 kg/tick
sits 12% above it and never binds.)

**The displacement term uses the charge's own density, which is a collapsing feedback loop.**
`ρ_held` is consistently *half* `ρ_supply`, because the charge has already expanded and partly
exhausted. Demand computed from it is self-referential — less held means less demanded means
less held — and it can only ever settle below the correct value.

Fixing the density alone changes the picture completely: `disp @ρ_supply` runs 0.253 → 0.042
across the range. At full gear it **exceeds** both the headroom and the throttle's 0.25 kg/tick
cap; at 25% it is a fifth of it. So with the right density, cut-off binds across nearly the whole
of its travel and the throttle binds only at full gear — which is the correct division of labour
between the two levers, and it says the existing geometry and throttle rating are already in
roughly the right place.

#### D2 — P₁ is the tank's own pressure, so the diagram runs on the release condition

`apply` passes `pressure_pa(state, ctx.content)` — the settled lumped charge — as the diagram's
admission pressure. That charge is post-expansion and mid-exhaust, so it sits near the *release*
condition, and it is held down on the saturation line by its own condensate.

> **A stale number is corrected here.** The original autopsy reported that a throttle sweep moved
> boiler pressure 25 kPa and cylinder pressure **1.7 kPa** — "boiler pressure does not reach the
> diagram at all." That was measured on the old explicit mass solver and it no longer holds.
> Re-measured on the current tree, throttle sweep at cut-off 100, t = 3600:
>
> ```
>   throttle | boiler kPa | cylinder kPa |   rpm |      kW | water kg
>         20 |      427.8 |        128.7 |  65.9 |   13.55 |    0.058
>         40 |      485.7 |        146.8 |  86.6 |   29.62 |    0.143
>         60 |      498.1 |        159.8 |  99.2 |   43.59 |    0.223
>         80 |      455.2 |        197.7 | 135.5 |  105.37 |   11.735
>         100 |      444.7 |        216.3 | 151.8 |  145.00 |   13.975
> ```
>
> Cylinder pressure now does move — but note the last column. Over the dry part of the sweep
> (20→60) it moves 31 kPa while the boiler moves 70 kPa, so it tracks supply at well under half
> rate and sits at roughly 30% of boiler pressure. Over the wet part (80→100) it moves another
> 57 kPa, and **that rise is the flooding, not the supply** — boiler pressure is *falling* across
> those same rows. So the defect is not "the boiler never reaches the diagram"; it is that P₁ is
> a release-condition pressure whose variation is dominated by how much water is trapped in the
> cylinder. Which is worse, and is the point of the next paragraph.

The pathological consequence is worth stating on its own, because it is the clearest possible
demonstration that the model is wired backwards:

```
t=1200   steam=0.1974  water= 0.019   P=141.8 kPa   liqfrac=0.001   rpm=  2.6   kW=  0.00
t=1800   steam=0.1635  water= 2.158   P=155.7 kPa   liqfrac=0.143   rpm= 95.9   kW= 40.30
t=2400   steam=0.1854  water= 4.074   P=180.5 kPa   liqfrac=0.270   rpm=120.3   kW= 75.78
t=3000   steam=0.1997  water= 7.992   P=200.4 kPa   liqfrac=0.530   rpm=138.1   kW=111.32
t=3600   steam=0.2071  water=13.975   P=216.3 kPa   liqfrac=0.927   rpm=151.8   kW=145.00
t=4200   steam=0.2080  water=21.933   P=228.7 kPa   liqfrac=1.455   rpm=162.5   kW=175.31
```

As the cylinder floods, its free volume shrinks, so the same held steam implies a higher
pressure, so MEP rises, so **the engine makes more power the closer it gets to destroying
itself** — 175 kW at a liquid fraction of 1.455, which is a hydraulically locked cylinder. Every
one of those numbers is the model rewarding the failure it should be punishing.

#### D3 — condensate has no route out of the high-pressure cylinder, and the cause is one port tag

This is not a cylinder defect at all. It is topology.

```
high_pressure  cylinder.exhaust -> flue.inlet        dest_port_accepts = [:gas]
atmospheric    cylinder.exhaust -> condenser.in      dest_port_accepts = []
```

`Arbiter` requires **every** port on a path to accept a resource (`ports.all? { |port|
port.accepts?(resource, content) }`). `Conduit` applies its `accepts:` to both of its ports, and
`flue` is declared `accepts: [:gas]`. Water is not tagged `:gas`. Therefore, in the high-pressure
engine, **liquid water cannot leave the cylinder by any route whatsoever.**

The atmospheric variant's condenser inlet has an empty tag list, which is permissive, and it
proves the diagnosis by contrast — same node class, same code, same tick:

```
                     high_pressure                atmospheric
t=1200   water=  0.019 kg                     water = 0.005 kg
t=2400   water=  4.074 kg                     water = 0.014 kg
t=3600   water= 13.975 kg                     water = 0.010 kg
t=4200   water= 21.933 kg  (liqfrac 1.455)    water = 0.009 kg  (liqfrac 0.000)
```

One floods monotonically and without limit; the other never accumulates anything at all.

**The condensation rate itself is fine.** Over ticks 2001–3600 the cylinder passed 309.867 kg and
retained 11.388 kg — **3.54% of throughput**. That is a plausible net retention for a cylinder
whose wall is being held below saturation; the real figure for how much *condenses* is far higher
(§1.4), but nearly all of it re-evaporates and leaves with the exhaust. Ours cannot leave, so a
small, correct rate integrates without bound.

[`transport_model.md`](transport_model.md) §5 called this exactly, before it was observed:

> Today `apportion` splits a flow across the resources present, proportionally, filtered by both
> ports' tags. A steam line tagged `:gas` would therefore refuse water outright — **which is why
> wet steam is currently impossible.**

#### Noticed in passing, and not part of this design: the atmospheric engine is slowly dying

The variant used as the control above has a separate problem, recorded here so the measurement
is not lost. Over the same run it decays monotonically rather than settling:

```
          t=1800   t=2400   t=3000   t=3600   t=4200
  rpm       18.3     15.0     12.6     11.0      9.8
  kW       17.27    10.89     7.24     5.25     3.99
  cyl kPa   80.1     56.1     41.6     33.1     27.7
  cyl K    365.7    356.4    348.8    343.2    339.0
```

This is probably the condenser saturation already noted in `current_progress.md` — Watt's engine
makes more steam than its condenser can lay down and the vacuum it exists to pull collapses — but
it has not been diagnosed and it is not a cylinder defect. **It should be measured on its own
before either engine is re-tuned**, because a decaying baseline makes every balance number taken
from the atmospheric variant meaningless.

#### D4 — held enthalpy is the only thing stopping the diagram inventing energy

`Tick#transmit_torque` measures the kinetic energy the shaft actually gained and bills the
cylinder for precisely that, scaling the impulse back if it exceeds `driver.extractable_joules`
— the enthalpy of the held charge above ambient.

That bound is load-bearing. **The diagram is a function of two pressures and knows nothing about
whether any steam arrived.** Shut the throttle completely and MEP is unchanged: the boiler is
still up, the exhaust is still at atmosphere, so the formula still returns full torque. The only
reason a starved cylinder does not accelerate the flywheel on nothing is that its charge runs out
of extractable joules.

**Any option that stops the cylinder holding a charge must replace this bound**, or it breaks
conservation — the one thing this simulation refuses to approximate. This is the single most
important constraint on the option space below and it is why Option A is not the obvious winner
it first appears to be.

---

## 3. The options

### Option A — the cylinder becomes a transport node

Drop `Holds` and `Pressurized`; `transport? == true`. The path becomes
`boiler → throttle → cylinder → flue` in one settlement. The cylinder contributes a
positive-displacement throughput cap `(ρ + c) · V_swept · rev · ρ_steam(P_supply)` and, in
`apply`, a torque from `MEP(P_supply, P_back, ρ)`. This is the Open Rails shape: the cylinder is a
*function*, not a container.

**Pros**

- The structural conflation is gone by construction — nothing to hold means nothing to be
  inconsistent about.
- Flooding is impossible; `liquid_fraction` and the whole flooding failure mode disappear.
- Cut-off sets consumption and MEP from one number, so the trade is exact.
- Boiler pressure reaches the diagram directly. D2 is fixed outright.
- Removes a tick of lag between boiler and exhaust.
- Removes `breathing_fraction` — the ω-dependent self-limiting hack, which existed to give the
  engine a stable operating point back when `Load` was a constant-torque brake. `Load` has a fan
  curve now, so the hack is redundant.
- Smallest node, fewest concerns, least state. On the "closer to real life is cleaner" test this
  scores best on the code.

**Cons**

- **It breaks D4 and there is no cheap repair.** With no held charge there is no
  `extractable_joules`, so the work has to be billed against the *stream* crossing the node —
  new machinery on the transport path, in a place where nothing currently extracts energy from a
  flow. This is the real cost of the option and it is not small.
- **It deletes hydro-lock**, which the brief explicitly wants. There is nowhere for water to
  collect. It could be faked with a drain pot downstream, but that is a prop, not physics.
- **It deletes cylinder condensation** — the largest real loss in the machine (§1.4) and the
  physical reason short cut-off has a limit. A transport node has no `volume_m3`, and
  `run_phase_change` needs one, so a conduit cannot host a phase change by design. We would be
  back to Open Rails' flat +20% correction factor, which is exactly the kind of tuned constant
  this codebase has spent a fortnight deleting.
- Full torque on no steam until the energy bound is rebuilt. Silent, and only conservation specs
  would catch it.

### Option B — split the steam chest from the cylinder

Add a small `Vessel` between throttle and cylinder:
`boiler → throttle → steam_chest → cylinder → exhaust`. The chest holds steam and has a real
pressure. The cylinder keeps `Holds` but holds only its clearance charge plus what was admitted
this tick; it draws positive displacement **at chest density**, and its diagram runs from chest
pressure to exhaust-node pressure.

**Pros**

- **It is the true decomposition.** Every real engine has a steam chest, and §1.3 says the
  admission-pressure chain is where the interesting behaviour lives.
- **It repairs D4 structurally rather than by adding a bound.** If the throttle cannot supply
  what the cylinder is swallowing, the chest depletes, its pressure falls, and *both* the demand
  (through density) and the MEP (through P₁) fall with it, on the next tick, automatically. That
  is wire-drawing, it is the real speed limit of a steam engine, and it means the engine
  physically cannot make work from steam that did not arrive — no artificial energy bound
  required. **This is the strongest argument in the document.**
- Boiler pressure reaches the diagram, via a node that genuinely has one. D2 fixed.
- The cylinder keeps a wall and a charge, so **condensation stays emergent** and the §1.4
  cut-off optimum can appear on its own rather than as a correction factor.
- **Hydro-lock stays natural** — condensate collects in the clearance space, which is exactly
  where it collects in reality.
- The chest is the right place for boiler priming to arrive, and the right place for a drain.
- No new machinery whatsoever. A `Vessel` and the existing `Cylinder`, rewired.
- `cylinder_pressure` on the panel becomes meaningful again: chest pressure is what a driver
  actually reads, and the difference between it and boiler pressure *is* the wire-drawing.

**Cons**

- One more holder on the steam path = one more tick of lag (250 ms at `time_scale` 1). Almost
  certainly irrelevant for a machine whose flywheel has a multi-second time constant, but it is
  a real cost and should be measured, not assumed.
- Still needs the demand rule fixed (D1) — the chest does not fix that by itself, it only makes
  the right density available to fix it with.
- Still needs condensate to be able to leave (D3), or the cylinder floods regardless of
  everything else. See §4 — this is a prerequisite, not an extra.
- A rebalance: chest volume, throttle rating and the whole operating point move. Expect the same
  measure-and-retune round the transport work needed.
- One more node in the graph to explain in the operation's docstring.

### Option C — one node, two roles separated internally

Keep `Holds` + `Pressurized`, but stop the held charge from doing a job it cannot do:
demand becomes displacement at *supply* density (headroom kept only as a start-up term at
ω = 0), and the diagram's P₁ comes from `ctx.node_pressure(@supplied_by)`.

**Pros**

- The smallest change. No graph change, no new node, no extra hop, no re-plumbing.
- Fixes D1 and D2 directly.
- Keeps hydro-lock and keeps condensation.
- Probably one evening plus a retune.

**Cons**

- **It does not fix D4 and arguably makes it worse.** P₁ becomes boiler pressure regardless of
  what the throttle is doing, so a nearly-shut regulator gives full MEP on almost no steam. The
  `extractable_joules` bound is then doing *all* the work of representing throttling, which is a
  clamp standing in for a mechanism — precisely the shape of the `flow_bounds` mistake the
  transport rebuild just finished deleting.
- **The throttle stops being a throttle in any interesting sense.** With no chest, opening the
  regulator changes only how much steam arrives, never the pressure it arrives at, so
  wire-drawing is unrepresentable and the engine has no speed limit of its own.
- The node still reports a `pressure_pa` that no longer drives anything, while the panel points a
  gauge at it. A derived quantity that no longer describes the thing causing it is exactly what
  `physics/CLAUDE.md` warns about.
- It leaves the conflation in place and merely stops it hurting at one operating point. The next
  person to touch this node meets the same three-jobs problem.

### Option D — minimal repair: demand rule and port tag only

Fix `ρ_held → ρ_supply` in `displacement_kg`, drop the `max(…, headroom)` in favour of a
displacement-only draw with a start-up term, and widen `flue`'s `accepts:` so condensate can
leave. Leave P₁ as the held pressure.

**Pros**

- Two or three lines. Lowest risk by a wide margin.
- Makes cut-off a real lever for the first time (D1 fixed, and the `disp @ρ_supply` column says
  it will bind across most of its travel).
- Unfloods the cylinder (D3 fixed), which removes the "more power as it floods" absurdity.
- Nothing structural to regret later; it is a strict subset of B and C.

**Cons**

- Leaves D2: P₁ remains a release-condition pressure at roughly 30% of the boiler's, tracking
  supply at under half rate, so raising steam pressure still buys far less than it should. With
  the flooding fixed, the *distortion* from trapped water goes away, which makes what remains
  cleaner but no larger.
- Leaves D4.
- Leaves the conflation, so this is a stopgap that has to be revisited.
- Widening a chimney's tag list to `[:gas, :liquid]` is defensible (real exhaust *is* wet steam
  and the blastpipe genuinely throws water) but it is a tag change standing in for the
  entrainment rule, and it applies to everything on that path, not just condensate.

### Comparison

| | **A** transport | **B** chest + cylinder | **C** one node, split roles | **D** minimal |
|---|---|---|---|---|
| D1 demand rule | fixed | fixed | fixed | fixed |
| D2 boiler reaches diagram | fixed | fixed | fixed | **open** |
| D3 condensate can leave | n/a — no liquid at all | needs §4 | needs §4 | fixed by tag |
| D4 work bounded by supply | **broken, needs new machinery** | **fixed structurally** | worse | open |
| Hydro-lock | **impossible** | natural | natural | natural |
| Cylinder condensation | **impossible** | emergent | emergent | emergent |
| Wire-drawing / speed limit | needs the chest anyway | yes | no | no |
| New machinery | stream work extraction | none | none | none |
| Graph change | yes | +1 node | none | none |
| Retune needed | full | full | moderate | small |

---

## 4. Hydro-lock, and the thing that has to exist first

The brief is right that the parts are nearly free. The mechanic is not, and the reason is worth
being precise about.

### 4.1 The pieces we already have

| Piece | What it is | Status |
|---|---|---|
| Accumulation | condensation on a cold wall, `run_phase_change` on held parcels | **works** — measured 3.54% retention |
| Detection | `Cylinder#liquid_fraction`, liquid volume ÷ clearance volume | **exists**, unused, reads 1.455 today |
| Consequence | `stress_per_second` / `overload?` above some fraction | one method |
| Drain cocks | `Conduit`, `accepts: [:liquid]`, `control_id: :drain_cocks`, cylinder → atmosphere | stock parts; needs a `:drain` port on the cylinder |
| Relief valve | `Nodes::ReliefValve`, `senses: :cylinder` | stock part |

The relief valve is more elegant than it first looks. As liquid fills the clearance space,
`Pressurized#free_volume` shrinks, so the derived pressure rises steeply — that *is* the
hydraulic lock, expressed in the quantity the existing part already senses. A relief valve set
near boiler pressure lifts on its own, and whether the cylinder survives depends on whether the
valve can pass water faster than the piston is compressing it. That is the real device, modelled
with the real mechanism and no special case.

### 4.2 The prerequisite: how much condensate does the exhaust carry away?

**Without an answer to this, hydro-lock is not a failure mode — it is a certainty.** D3 shows
the high-pressure engine reaching a locked cylinder in under an hour of play from ordinary
operation, with nothing done wrong. A hazard everyone hits is not a hazard, it is a bug.

There are three possible rules and the choice matters:

1. **Carry everything (proportional by mass).** `Parcel.draw` already splits proportionally, so
   simply widening the tag gives this. Result: with 14 kg of water against 0.2 kg of steam, the
   exhaust stroke takes overwhelmingly water and the cylinder drains in a few ticks. **Hydro-lock
   becomes nearly impossible.** It is also backwards physically — water is a thousand times
   denser than the steam, so a volume-sweeping piston carries away proportionally *less* of it,
   not more.
2. **Carry nothing (today).** Certain flooding. Already rejected by measurement.
3. **Carry a fraction that rises with exhaust violence** — i.e. with ω. This is the
   `entrainment(state, ctx, phase)` source-side hook that
   [`transport_model.md`](transport_model.md) §5 already designed, applied to the cylinder:

   > A port's `accepts:` filter gates what may flow *independently*. Material entrained in a
   > carrier phase rides with it regardless.

Option 3 is the one that produces the real behaviour, and it produces it for the real reason:

> A **fast** engine blows its own condensate out and stays clear. A **slow or standing** engine
> accumulates it. So water piles up exactly when a real engine's water piles up — on starting,
> after standing, when warming through — which is exactly when a real driver opens the drain
> cocks. The remedy and the hazard land on the same part of the operating envelope, which is
> what makes it a skill rather than a die roll.

It also generalises: the same hook is what boiler priming needs, and priming is the violent case
that makes hydro-lock genuinely dangerous rather than merely tedious.

**Recommendation: build entrainment as the general seam, not the tag widening.** It is barely
more work, it is the designed answer, and the tag widening would have to be undone to get here.

---

## 5. Recommendation

> ### CORRECTION — four things here did not survive implementation
>
> 1. **D cannot be split from the P₁ fix; landing 1 was C, not D.** With P₁ read from the held
>    charge, the demand rule *is* the torque rule: cut admission to displacement-only and the
>    charge falls ~5× at 25% cut-off, so held pressure falls ~5×, so MEP falls ~5× **on top of**
>    the diagram's own cut-off factor. Cut-off gets counted twice and power collapses harder
>    than before. The headroom term was not only a bug — it was load-bearing, because with
>    P₁ = held pressure the cylinder must be refilled to supply pressure every tick or it makes
>    no torque at all.
> 2. **The verification criterion in §6 was wrong.** "`kW per kg/s` must rise" as cut-off
>    shortens describes an engine with no back pressure and no clearance. The real curve has an
>    **interior optimum** — measured at 40% — because the fixed `− P₂` subtraction eats a
>    growing share of a shrinking MEP. A monotone rise would have meant a *missing* loss.
> 3. **Admission is `cutoff × V_swept`, not the textbook `(cutoff + clearance)`.** That form is
>    the gross fill and is paired with a credit for the residue the compression stroke keeps.
>    This model keeps the residue directly, so charging admission for it bills the engine twice
>    — a **53% surcharge at 15% cut-off**, which on its own inverts the efficiency curve.
> 4. **§3's option table understated the work.** Two defects it did not predict had to be fixed
>    for the mechanic to function at all: `Arbiter.cap_gas_by_pressure` capping the cylinder's
>    displacement claim against a gradient (400 ticks out of 400, scale 0.81), and
>    `indicated_power_w` becoming **anti-correlated** with actual output once P₁ left the held
>    charge — 566 kW at 167 rpm against 479 kW at 187 rpm. The panel now reads `shaft_power_w`.

**Option B, in three landings, with D as the first of them.**

1. **Land D first, on its own.** Fix the density in `displacement_kg`, replace
   `max(displacement, headroom)` with displacement plus an explicit at-rest starting term, and
   let condensate leave. This is small, it is a strict subset of B, and it turns cut-off into a
   working lever immediately — so the retune for step 2 can be measured on a machine whose
   levers already behave. Re-measure the cut-off sweep; the acceptance test is that steam
   consumption falls with cut-off while `kW per kg/s` **rises**.
2. **Add the steam chest.** This is where D2 and D4 both close, and it closes D4 the right way —
   by making the engine physically unable to work steam it did not receive, rather than by
   clamping it afterwards. Expect a full rebalance; the chest volume is the new dial.
3. **Then hydro-lock**, on the entrainment rule of §4.2 — carryover fraction rising with ω, drain
   cocks as a control point, `liquid_fraction` wired to `stress_per_second`, and a cylinder
   relief valve.

Option A is the tempting one and it should be rejected deliberately rather than by default. It
produces the smallest, cleanest node — and it does so by deleting the two most interesting pieces
of physics in the machine (condensation and hydro-lock) and by moving the conservation bound onto
new machinery that does not exist. The Open Rails shape is right for a simulator whose cylinder is
a black box between a boiler and a drawbar. Ours is a machine the player is supposed to be able to
break.

The guiding principle from the brief holds up under this analysis, and B is the option it points
at: **the steam chest is not extra complexity, it is the missing part.** Adding it removes an
artificial energy clamp, makes an existing gauge honest, gives the throttle a real physical
meaning, and produces the engine's high-speed power limit for free. Four things get simpler
because one real component was put back.

---

## 6. Verification

Rigs, kept as specs:

- **Cut-off trades steam for efficiency.** Sweeping cut-off at fixed throttle, steam kg/s must
  fall monotonically and `kW per kg/s` must rise. This is the test that fails today at every
  setting.
- **Boiler pressure moves engine power**, *isolated from the throttle*. At fixed cut-off,
  throttle and load, a higher relief setting must give proportionally more power. The current
  throttle sweep cannot answer this — it moves supply and mass flow together — so this rig has to
  be built before the claim can be tested either way.
- **The diagram is backwards-compatible.** At ρ = 1, MEP must equal `P₁ − P₂` exactly.
- **No work without steam.** With the throttle shut and the boiler at pressure, indicated power
  must go to zero and the flywheel must decelerate. This is D4's regression test and it should be
  written *before* the chest, so it can be seen to fail and then pass.
- **The cylinder does not flood in normal operation.** Liquid fraction must stay bounded over a
  long run on both variants — the test D3 fails today on one variant and passes on the other,
  which is precisely why it is worth asserting rather than assuming.
- **Hydro-lock is reachable and avoidable.** Standing with the regulator cracked open and the
  drain cocks shut must reach a locked cylinder; the same run with the cocks open must not.
- **Conservation and determinism**, re-baselined at each landing.
- `performance_spec` re-measured after the chest lands — one more holder is one more path.

Docs to update, per the CLAUDE.md table: `reference/nodes.md`, `nodes/CLAUDE.md`,
`reference/physics.md` (condensation, if it becomes emergent), `reference/settlement.md` (if
entrainment lands), `operations/CLAUDE.md` and `build-an-operation.md` (the chest as a pattern),
`current_progress.md` — the "cylinder is a tank, not a cycle" row, and the hydro-locking line
under failure modes.

---

## 7. Sources

- [Cutoff (steam engine) — Wikipedia](https://en.wikipedia.org/wiki/Cutoff_(steam_engine))
- [Steam Indicator Diagram — glue-it.com](https://www.glue-it.com/knowledge/steam-indicator-diagram/)
- [Indicated Power and Indicator Diagrams — Advanced Steam Traction](https://advanced-steam.org/ufaqs/indicated-power/)
- [Condensation / Wall Effects — Advanced Steam Traction](http://advanced-steam.org/ufaqs/condensationwall-effects/)
- [OR Steam Model — Coals to Newcastle](https://www.coalstonewcastle.com.au/physics/or-steam-model/)
- [Open Rails Physics manual](https://open-rails.readthedocs.io/en/latest/physics.html)
- [Priming (steam locomotive) — Wikipedia](https://en.wikipedia.org/wiki/Priming_(steam_locomotive))
- [Automatic cylinder cock with relief valve — US Patent 2,004,097](https://www.freepatentsonline.com/2004097.html)
- [Steam Engine Specifications / Indicator Diagrams — Open Source Ecology](https://wiki.opensourceecology.org/wiki/Steam_Engine_Specifications/Indicator_Diagrams)
