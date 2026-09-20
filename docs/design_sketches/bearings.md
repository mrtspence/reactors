# Bearings, friction and the hot box

Status: **agreed, not built.** Design input, not a description of the system.

The one-line version: **mechanical loss is currently spread across three unrelated mechanisms,
none of which produces heat, and the largest of them is a bug.** This replaces all three with one
modelled friction interface that gets hot, wears out, needs oiling, and can seize.

---

## 1. The problem, measured

### 1.1 The friction you notice is not the friction that is configured

The complaint that started this was "excessive friction in the crankshaft/flywheel". The
`friction:` constants are not where it lives.

The light flywheel is `I = ½ · 3200 · 1.5² = 3600 kg·m²`. At 174.6 rpm (ω ≈ 18.3 rad/s) its
`friction: 8.0` costs `8.0 × 18.3 ≈ 146 N·m`, which is **2.7 kW**. The `Load`'s `friction: 3.0`
costs about **1.0 kW**. Against ~499 kW of shaft power those are **sub-1% terms**. They could be
set to zero and nothing observable would change.

`link.rb` has blamed the drive coupling since it was written:

> **MUST ADDRESS — the steam engine's coupling dissipates 60% of its shaft power.** At full
> controls the cylinder delivers ~499 kW, the mill receives **199.7 kW** and `joules_to_friction`
> takes **297.5 kW**. The books balance, and a slipping coupling genuinely does dissipate, but a
> real belt drive loses single-digit percent.
>
> The suspect is `stiffness:` (9 000 on `flywheel=load`) held against a fan-law load at a large
> steady speed difference: a soft coupling that never stops slipping is a brake.

**That diagnosis is wrong, and so is the coupling's reputation.** Measured on a reference run —
seed 7, high-pressure, a crewed engine at throttle 60 — the numbers are:

```
flywheel        18.24 rad/s  (174.5 rpm)
load             0.13 rad/s  (  1.2 rpm)        slip 99.4%
load extracted  40.0 kJ per tick (160 kW)
```

Those last two cannot both describe a steady state. A body of `I = 400 kg·m²` holding 40 kJ of
kinetic energy is turning at **14.1 rad/s**, not 0.13. So the load is not sitting slowly — it is
**spun up to 14 rad/s by the coupling and slammed back to a standstill, every single tick,
forever.** Traced over 20 consecutive ticks it never once holds speed.

The cause is in `Load#apply`:

```ruby
slowed = state.merge(
  angular_momentum: [ state.fetch(:angular_momentum) - (torque * ctx.dt), 0.0 ].max
)
```

That is **explicit Euler on a fan-law brake**, and it is stable only while
`dt < 2I / (dT/dω)`. For this load:

| ω (rad/s) | absorbed torque | `dT/dω` | stable below | at `dt = 0.25` |
|---|---|---|---|---|
| 5.0 | 3 500 N·m | 1 400 | 0.571 s | ok |
| 10.0 | 14 000 N·m | 2 800 | 0.286 s | ok |
| 12.5 | 21 875 N·m | 3 500 | 0.229 s | **unstable** |
| 18.3 | 46 885 N·m | 5 124 | **0.156 s** | **unstable** |

At the engine's working speed the scheme is past its stability limit by a comfortable margin. It
does not oscillate visibly only because it saturates into the `max(…, 0.0)` clamp — which is why
it reads as a steady state instead of as the divergence it is.

**So the coupling is a symptom.** It slips ~100% because the load is stationary at the start of
every tick. Stiffening it would transmit more torque into a ratchet and dissipate more, not less.

This is the same failure `graph/CLAUDE.md` already records for the old per-node bound —
*"papering over an explicit integrator running 400–600× past its stability limit"* — and
`Concerns::Rotating#friction_loss` is written in closed form specifically to avoid it: *"A
spinning wheel must coast to a stop, never through it into running backwards."* `Load#apply` does
the thing that comment forbids, and its clamp is standing in for the stability the integrator does
not have.

**The fix is `Load#apply`, not `DriveLink#stiffness`.** A brake is a coupling to a reservoir at
rest and belongs in `Relaxation` with heat, momentum and friction.

### 1.2 Three mechanisms, one phenomenon

| Where | What it does | On the ledger? |
|---|---|---|
| `Cylinder#efficiency = 0.85` | multiplies torque by 0.85 | **No.** See below — the 15% is never claimed at all |
| `DriveLink stiffness: 9_000.0` | coupling slip | yes — 60% of shaft power, but as a **symptom** of §1.1 |
| `Rotating#friction`, four constants | linear `f·ω` drag | yes, same ledger line, under 1% |

The four friction constants (8.0, 40.0, 3.0, and a 0.0 default) are **the only tuned numbers in
the rotation model with no comment and no measured sweep behind them.** Every other constant in
this codebase carries its derivation. That is the tell that they were placeholders nobody came
back to.

### 1.3 `Cylinder#efficiency` is stranger than it looks

It is not a loss. `Tick#transmit_torque` bills the cylinder for the kinetic energy the shaft
*measurably gained*, so multiplying torque by 0.85 does not remove 15% of the charge and dump it
somewhere — **it means 15% is never claimed from the cylinder at all.** Conservation holds because
nothing ever asked for the energy, not because it went anywhere.

So the engine's single largest named mechanical loss is a number that makes the machine weaker
while leaving the energy sitting in the steam chest.

### 1.4 And cylinders never wear

The only route to a worn bore today is hydraulic lock — priming badly enough to slug the cylinder
with water. A piston is an enormous reciprocating friction interface running under gas load for
every stroke of its life, and none of that touches its durability. An engine worked hard for a
full match comes out of it as new.

### 1.5 The calibration target

**Steam engine mechanical efficiency is 80–90%, so friction is around 10% of indicated power.**
That single number is what the whole pass is measured against, and all three mechanisms above are
wrong relative to it in different directions.

---

## 2. What the engineering says

### 2.1 Friction is three regimes, not one number

The **Stribeck curve** plots friction coefficient against the *Hersey number* `ηN/P` —
viscosity × speed ÷ load.

| Regime | μ | When |
|---|---|---|
| **Boundary** | 0.05–0.20 | slow, heavily loaded, or starved of oil; asperities touching |
| **Mixed** | between | the steep transition |
| **Hydrodynamic** | 0.001–0.005 | a full film carries the load; no metal contact at all |

**A 40–100× swing in friction**, and that swing is the entire mechanic. A well-oiled interface at
speed is nearly free. The same interface dry, or stopped, is a brake that destroys itself.

**Petroff's law** gives the hydrodynamic branch, `f = 2π²·(μN/P)·(R/c)`. The property worth
stealing is that the two branches scale differently:

- the **hydrodynamic** term is **load-independent** — pure viscous shear of the oil film;
- the **boundary** term is **load-proportional** — ordinary Coulomb friction.

Two terms with different physics, and the film fraction is the blend between them.

**This is regime physics, not bearing physics.** It applies unchanged to a journal in its brasses,
a piston ring on a bore, a crosshead in its guides, and a rope over a pulley. That generality is
what makes it worth building once, properly.

### 2.2 The hot box, which is the failure we want

Railway axle boxes were plain journals packed with oil-soaked waste. When "the oil leaked or dried
out, the bearings overheated, often starting a fire that could destroy the entire railroad car."
Left alone, "it would heat to a temperature where the babbitt bearing alloy would melt away,
leaving the brass carrier riding on the steel axle" — and then the axle fractured, or the journal
box dropped below the rails, "either of which could cause a major derailment of the train."

**The runaway is the point.** Less oil → boundary contact → heat → oil thins and burns off → less
oil. Positive feedback, which is why hot boxes went from fine to catastrophic quickly, and why
crews watched for them continuously.

Detection was **sensory**. Crews looked for smoke and flame and called "All Black" when a train
showed none; bearings were felt by hand and smelled. Packing "had to be regularly inspected by
yard crews, and packing was often added at major stops."

That is a `Displays::Prose` gauge, not a needle — and it is exactly what this codebase already
does for `flywheel_condition`.

### 2.3 Failure modes worth modelling

| Mode | Cause | Speed | Take it? |
|---|---|---|---|
| **Wiping** | lost film, starvation, overload, sustained overheating | **rapid** | **Yes — this is the hot box** |
| **Fatigue cracking** | misalignment, cyclic load, imbalance | gradual | Yes — maps cleanly onto `stress_per_second` |
| **Pitting** | dirty oil, water ingress, electrical discharge, cavitation | gradual | **No** — needs an oil-quality axis we do not have |

Wiping's causes are listed in the failure literature as "loss of oil film during startup/shutdown,
starved lubrication, blocked oil ports, low oil viscosity, high bearing load, incorrect running
clearance, prolonged overheating." Every one of those is representable here.

### 2.4 Temperatures — and the content file is already waiting

Tin babbitt melts at **235–370 °C**, lead babbitt at **175–290 °C**. Maximum *operating*
temperature is around **150 °C**, with industry practice alarming near 85 °C and tripping near
96 °C.

`content/resources/materials.yml` already carries both bearing metals, with the mechanism written
into a comment and **nothing implementing it**:

```yaml
# Softer still, and low-melting — which is the whole reason a hot box destroys itself so
# quickly once the oil stops arriving.
babbitt:
  tags: [solid, metal, bearing]
  specific_heat_j_per_kg_k: 230
  tensile_strength_pa: 70.0e6
  # It melts at about this temperature, and that is the point of it.
  max_temperature_k: 520
```

`bronze` sits beside it at 700 K. Both are tagged `bearing`, and **both are already billed in
`config/blueprints.yml`** against every rotating part — `light_flywheel` costs 12 kg of babbitt,
`mill_drive` 18 kg. The economy has assumed these bearings exist since blueprints landed. Nothing
in `lib/` has ever referenced either material.

### 2.5 Lubrication was a job, and history supplies the difficulty ladder

| Method | What it is | Crew burden |
|---|---|---|
| **Hand oiling** | a man with an oil can, round the engine every few minutes | constant |
| **Drip cups / siphon trimmings** | worsted wool wicks oil down a tube; needs setting and refilling | periodic |
| **Ring oiler** | a ring rides on the shaft and lifts oil from a sump beneath | top up the sump |
| **Splash / oil pan** | dippers on the rod big-ends fling oil up from a sump | top up the sump |
| **Forced feed** | a pump | a pump that can fail |
| **Roller bearings** | sealed, greased for life | **none** |

Splash lubrication brings a constraint worth keeping: it "can work only on very low-revving
engines, as otherwise the sump oil would become a frothy mousse," and "plain bearings require
pressure-fed oil to prevent overheating and seizure." So the oil pan is the cheap option *with a
speed ceiling* — a real trade rather than a strictly worse choice.

Roller bearings ended the job. Railroads adopted them partly so they could "lay off people whose
job it was to keep plain bearing journal boxes oiled," and they gave "30% or so less friction when
starting from a dead stop."

---

## 3. The model

### 3.1 A bearing is a modelled friction interface

Not "a thing a shaft spins in" — **a place where enough rubbing happens that we want the heat and
the wear to be real.** Most interfaces in a machine will never earn a node. A main journal does. A
piston in a bore very much does. A rope over a pulley will, when there are ropes.

One class, `Nodes::Bearing`:

```
Concerns::Thermal   its own joules; heat capacity from mass × the material's specific heat;
                    ambient_conductance, so it sheds heat and reaches an equilibrium
Concerns::Wearing   durability, and the wipe → seize ladder
Concerns::Holds     the oil actually in it
```

**Always a separate node, never a property of the thing it serves.** `concerns/CLAUDE.md` settles
this: *"Things that need genuinely distinct temperatures are distinct nodes."* A journal running
red hot inside a cool housing on a cool shaft is precisely that case, and the boiler's crown sheet
is the worked precedent for a hot spot that is not the node's bulk temperature.

It is **not** `Rotating`. The shaft turns; the bearing is the stationary half it turns *in*.

### 3.2 One law, two duties

Every friction interface needs the same two numbers — **sliding speed** and **normal load** — and
differs only in how they are derived. So a bearing declares what it serves, mirroring
`Cylinder#drives`:

```ruby
Nodes::Bearing.new(id: :main_bearings, duty: :journal, supports: :flywheel, material: :babbitt)
Nodes::Bearing.new(id: :piston_rings,  duty: :slide,   supports: :cylinder, material: :bronze)
```

`duty:` is the adapter, and it is the only thing that differs:

| | sliding speed | normal load |
|---|---|---|
| `:journal` | `ω × journal_radius` | static weight + `\|transmitted torque\| / crank_radius` |
| `:slide` | mean piston speed, `2 × stroke × rev/s` | ring tension + **gas pressure behind the rings** + connecting-rod obliquity side-thrust |

The law itself is shared, and it is a coarse Stribeck:

```ruby
# Fraction of the load carried by an oil film. 1.0 is hydrodynamic, 0.0 is metal on metal.
film  = [ oil_supply_fraction * speed_factor, 1.0 ].min
mu    = MU_FILM * film + MU_BOUNDARY * (1.0 - film)     # roughly 0.002 .. 0.12

power = mu * load_n * sliding_speed_m_s                 # boundary — load-proportional
      + viscous_c * sliding_speed_m_s                   # Petroff — load-independent
```

`speed_factor` encodes the other half of the failure literature: below a threshold speed no film
forms however much oil is present.

> **Measured, and it does not bite on an ordinary start.** The film goes 0.000 to 1.000 inside
> ten simulated seconds of the regulator opening, because a full wedge forms by 78 rpm and the
> engine passes that almost immediately — which is what real bearings do. The gate is live for a
> machine **barred over, stalling, or dragging a load it cannot turn**, not for starting one.
> Keep the term; do not claim it as the startup hazard, because it is not one. **Starvation is
> what matters in normal running**, through `wetness`, and that is stage F.

Two consequences fall straight out of the load column, and both are the reason to do it this way:

- **A journal works harder when the engine pulls harder**, because its load carries transmitted
  torque.
- **A piston works harder at high boiler pressure**, because gas gets behind the rings and presses
  them into the bore. *"I ran her hard all day"* therefore wears the cylinder, with no separate
  mechanism invented for it.

`power` is drained from whatever the bearing serves — negative torque on a shaft, a deduction from
delivered work on a cylinder — and **deposited as joules in the bearing itself.**

### 3.3 Friction heat stops being an exit

This is the keystone, and the ledger has been holding the door open for it:

```ruby
# Friction is counted as an exit rather than folded back in as heat. Belt slip really
# does warm the belt, but attributing it to a particular node is a modelling choice we
# have not made yet — and an explicit line nobody can miss beats a silent one.
```

Bearing dissipation now lands in the bearing's own `joules` rather than on `joules_to_friction`.
It warms, sheds to ambient through its `ambient_conductance`, and settles at an equilibrium
temperature set by how hard the machine is working and how well it is oiled.

Coupling slip **stays** an exit. A belt is genuinely not a node we model, and the same paragraph
applies to it unchanged.

That one change is what turns friction from bookkeeping into a mechanic: the temperature becomes a
state variable a player can watch, a gauge can lie about, and a failure can key off.

### 3.4 `Cylinder#efficiency` is deleted

The 0.85 goes, and a `:slide` bearing carrying rings, crosshead and gland takes its place. The 15%
stops being energy that is never claimed and becomes a real, measured, ledgered loss that heats a
part which can be too hot and can wear out.

> **This is the largest balance move in the release**, because it is the biggest of the three loss
> terms and the only one that was previously free. `light_and_run`'s figures will shift. It gets
> its own stage so it is attributable.

### 3.5 The ladder

`Thermal#rated_temperature_k` already resolves `material: :babbitt` to 520 K with no new code, and
`stress_per_second` copies `Conduit#stress_per_second` directly.

| | Trigger | Consequence |
|---|---|---|
| *(running hot)* | — | **Not a failure mode.** A gauge reading and nothing else. `break_part` zeroes durability, so anything in `failure_modes` is already damage. |
| `:wiped` | fatigue — time spent over rated temperature | `derates:` opens the clearance, which **raises the boundary fraction**, so it runs hotter still |
| `:seized` | overload — past melting, or running on wiped metal | the interface stops |

`:wiped → :seized` is a **deliberate runaway**: the damage worsens the friction, which worsens the
damage. That is the hot box, and it is the one place in this design where a positive feedback loop
is the feature rather than a bug to be damped.

`Severity.escalate` gives the forward-only rule for free, and `Cylinder`'s
`scored_bore → blown_head` is the proven precedent for a fatigue mode escalating through a
condition-driven `overload?`.

> **Seizing does not stop anything by itself, and two mechanisms look like they would.**
> `Tick#stress` zeroes `angular_momentum` only on the *failing* node, and a bearing does not
> rotate. `Arbiter.settle_drive` severs a `DriveLink` whose *end* has failed, and a bearing is not
> an end of one. So seizure has to act through the drag term — a seized interface declares
> enormous friction — and a spec has to assert the shaft actually stops.

### 3.6 Oil is a resource, not a scalar

A `:bearing_oil` resource and a `Vessel` reservoir, following the existing
`bunker → stoker → firebox` shape exactly: a passive holder, an effort conduit carrying the
`control_id:`, and a consumer.

```
oil_store ──[ oiling conduit, effort: ]──> bearings ──> burnt off, ledgered out
```

The tempting alternative is a bare scalar that decays and a lever that pushes it back up. It
invents a second, unaudited store outside the conservation ledger, which is exactly the class of
thing the conservation specs exist to catch — and the bunker precedent is already working,
measured and specced.

**The film is derived, never stored.** That is `Pressurized`'s rule and it applies here for the
same reason: a stored film is a second state variable that can silently disagree with the oil
supply that is supposed to determine it.

### 3.7 Oiling is an effort station

```ruby
ControlPoint.new(id: :oiling, label: "Oil Round", node: :oil_feed,
                 effort: { dexterity: 0.6, intelligence: 0.4 },
                 aided_by: :oiling)
```

Weights sum to 1.0, which `validate_effort!` enforces at build.

**Dexterity-led rather than strength-led**, because oiling is fiddly and attentive rather than
heavy. That makes it the first station that is not a strength check, and gives a different kind of
minion somewhere to be good. The `intelligence` share is deliberate too: the stat is defined today
and read by nothing, and knowing which bearing needs attention is exactly what it should mean.

An oil can as a `:tool` with `tags: { oiling: 0.5 }` mirrors `:stokers_shovel` precisely.

**The mechanic needs no new engine concept.** There is no discrete-action, cooldown or scheduling
machinery in the simulation, and this does not need any: the fireman has to *leave the shovel* to
go and oil, which is an `assign_minion` command that already works — and the fire dies while he is
away. That is the decision the mechanic is made of, and it costs nothing to build.

> **This is where `fatigue` would finally bite.** `state[:fatigue]` exists, multiplies into
> `capability`, and nothing advances it. A second job competing for the same person's time is the
> natural place for it — but it is a separate change and must not be smuggled in here.

### 3.8 The panel should be sensory

| Gauge | Source | Display |
|---|---|---|
| Bearing temperature | `Derived(:main_bearings, :temperature_k)` | `Needle`, lagged — the slow one that gives warning |
| Oil in reservoir | `Contents(:oil_reservoir, :bearing_oil)` | `Digital`, kg |
| Bearing condition | `Derived(:main_bearings, :integrity)` | `Prose` + `Bands` + `Misread` — *"the brasses are warm"*, *"smells hot"*, *"knocking"* |

Never a number for condition, for the same reason the flywheel has none: the machine should not
tell the player more than the machine itself would.

### 3.9 Hazards

`endangers:` on `:seized`, naming the oiling station — whoever is at the crank when it goes. Tags
`%i[burn crush]`. `Injury#resistance` resolves `burn_resistance` from a minion's gear tags by
naming convention, so protective kit works with no engine change at all. `scales_with:` the rim
speed the failure event reports.

### 3.10 Wear is rubbing, not heat

> **Decided 2026-09-17, lands in stage G** — beside the parts catalogue, because it is what makes
> a replacement bearing something a player actually buys. Stage E shipped the thermal law below
> and measured it falling short; this is the correction, not a second mechanism.

Stage E spends durability on **time above a temperature**, copied from `Conduit#stress_per_second`.
Measured, that reaches a starved journal and nothing else: the rings sit 100 K under their limit
at full throttle (§6.5), so the one interface that rubs hardest never wears at all.

The reason is that the law describes the wrong thing. **A bearing does not wear because it is hot.
It wears because it is rubbing, and it is hot for the same reason.** Heat is a symptom sitting
beside the cause, which is why it correlates for a journal cooking itself and fails completely for
rings that shed their heat into a tonne of iron casting.

**Archard's law** is the standard statement and the one to use: volume removed ∝ load × sliding
distance ÷ hardness. Per unit time that is load × sliding speed — which, multiplied by the
boundary friction coefficient, is exactly the **boundary** term the friction law already computes:

```ruby
# durability units per second: what is actually rubbing, metal on metal
def stress_per_second(state, ctx)
  omega = ctx.node_omega(@supports).to_f
  return 0.0 unless omega.positive?

  boundary_conductance(state, ctx, omega) * omega * omega * @wear_rate
end
```

`boundary_conductance × ω²` is the boundary friction power in watts, and the hydrodynamic term is
deliberately absent: **an oil film does not wear anything.** That is the whole point of the
Stribeck curve and it falls straight out — a flooded journal wears essentially not at all, a
starved one wears fast, and rings wear steadily forever because a reciprocating seal never gets a
full wedge.

What it buys, in order of how much it matters:

- **Stage D's claim is finally delivered.** Working an engine hard puts gas behind the rings,
  which raises the load, which wears them — and a wiped ring scores the bore through
  `failure_damages`. A worn cylinder stops requiring criminal mishandling of priming.
- **It is a second mechanism, not a replacement.** The thermal term stays, and the reason is
  measured below.

#### Archard does NOT subsume the hot box, and the measurement says so

This sketch claimed it would, on the reasoning that starvation raises the boundary fraction
forty-fold. **That reasoning is wrong**, and one table settles it — boundary friction power on the
reference engine:

| scenario | bearing | film | boundary power |
|---|---|---|---|
| reference | journals | 0.837 | 3.99 kW |
| reference | rings | 0.312 | **76.12 kW** |
| flat out | rings | 0.190 | **93.16 kW** |
| starved | journals | 0.559 | 9.82 kW |

**A starved journal rubs less hard than healthy piston rings** — 10 kW against 76, and fully dry
it still only reaches about 22 kW. One coefficient therefore gives the wrong *ordering*: any rate
fast enough to wipe a starved journal in the two minutes §6.5 measured would destroy a perfectly
oiled set of rings in about a minute.

The error was treating the mu swing as the whole story. It is 48× on a journal, but the rings
carry an order of magnitude more load over three times the sliding speed, and that product dwarfs
it.

So the model keeps **two damage mechanisms, because they are two things**:

| | driver | timescale | what it is |
|---|---|---|---|
| **Archard** | boundary friction power | tens of hours | metal rubbed away — a service life |
| **thermal** | time above the service limit | minutes | metal softening, oxidising, losing temper |

That is also what §2.3's own research table says: wiping is *rapid* and comes from lost film or
overheating; fatigue is *gradual*. They were never one mechanism, and collapsing them was the
mistake.

> **`SERVICE_FRACTION` stays load-bearing**, for the thermal term it was derived for.

Two consequences to build for rather than discover:

> **Bearings now consume themselves in ordinary running**, which is correct and is why this waits
> for G. A part that wears out needs somewhere to be bought — and a `bearing_condition` gauge
> whose needle only ever moves in a disaster is a different instrument from one that creeps across
> a long shift.

> **`wear_rate` is per part and must be swept, not guessed.** The figure that matters is how many
> hours of ordinary running a set of rings lasts, and it is the first number in this design that
> has no physical anchor — Archard's coefficient is a material property nobody tabulates usefully.
> Pick it from the intended service life and record the sweep, the way the minions gradient was.

**Starting point, from the table above**: `7.3 × 10⁻⁷` durability per joule of boundary friction
puts rings at roughly **5 hours** of reference running and **4.1 hours** flat out, and journals at
**95 hours**. So rings are a consumable replaced every several sessions and a well-oiled journal
effectively is not — which is the right shape. The hard-running gradient is only 1.2×, and if a
sweep says that is too weak the answer is the **load** term, not the coefficient: gas pressure
behind the rings is what should make working her hard expensive.

### 3.11 The metal melts and runs, which is what a hot box actually does

> **Decided 2026-09-18, lands in stage G** with §3.10. Cheap to build and deliberately general:
> **melting out is a failure mode many parts will want**, so it is worth getting right once
> rather than reinventing per part.

Stage E's seizure is honest about its trigger and exact about its energy (§6.6), and **unbounded
about its temperature**. Nothing takes heat away except ambient conduction, so a locked bearing
climbs until the loss matches the power going in — 1652 K on this engine, and 15,563 K on a rig
with a heavier flywheel.

This section was written expecting the melt to fix that. **It does not** — see the measurement
below, which is kept because the reasoning that produced the wrong answer is the reusable part.
What melting *is* good for is the failure's own story, and for the fusible plug, which is warmed
gently enough for a phase change to mean something.

**The white metal melts and leaves.** It is the defining event of a hot box, and the whole reason
a bearing destroys itself rather than merely getting hot:

> "it would heat to a temperature where the babbitt bearing alloy would melt away, leaving the
> brass carrier riding on the steel axle"

So the bearing loses its lining as mass, carrying enthalpy with it, exactly the way it already
loses oil:

```ruby
# Above the melting point, the lining goes — and takes its latent heat with it.
def melt_kg(state, ctx)
  over = temperature_k(state, ctx.content) - rated_temperature_k(ctx.content)
  return 0.0 unless over.positive?

  [ over * @heat_capacity / latent_heat_j_per_kg, remaining_lining_kg(state) ].min
end
```

#### It does not bound the seizure temperature, and this sketch said it would

Measured on the reference engine, a dry journal seizing with and without 6 kg of lining:

| | the tick after seizing | settled, 1000 s later |
|---|---|---|
| no lining | 565.1 K | 1652.4 K |
| 6 kg babbitt | 533.6 K | **1652.1 K** |

**31 K off the spike and nothing off the equilibrium.** The whole 360 kJ of latent heat is spent
within a tick or two, because a seizure does not deliver its energy gently — the shaft dumps
480 kJ of kinetic energy in the first tick alone, which is more than the entire lining can absorb.
A melt that buys less than a second of plateau is not a temperature bound.

The arithmetic that made the claim look right used the *steady* 57 kW and got six seconds; the
actual transient is two orders of magnitude sharper. **A phase change caps a temperature only
when the heat arrives slower than the latent heat can absorb it**, which is true of a plug warmed
through a crown sheet and false of a bearing absorbing a flywheel.

> **What would actually bound it is radiation.** `ambient_conductance` is linear, and a bearing at
> 1650 K radiates as T⁴ — the real reason nothing in a workshop reaches the equilibrium this model
> computes. That is a separate change to `settle_ambient`, affecting every hot node, and it is not
> in this release.

So the honest list of what melting buys is shorter, and still worth having:

- **`:seized` acquires a reason.** The lining runs out, the carrier rides the shaft, and the
  interface is metal-on-metal with no white metal left. Today `:wiped → :seized` is a temperature
  threshold; this makes it an inventory running out, which a player can be told about.
- **It is a repairable consumable.** Re-babbitting is the obvious first in-match repair job, and
  `failure_model.md` §10 has specified repair since before there was anything to repair.
- **It is reusable.** A crown sheet, a furnace lining, a solder joint and a bearing are the same
  event: *a part made of something with a melting point, given more heat than it can shed.*

**What it needs from `content/`**: a latent heat of fusion per material. `materials.yml` already
carries `max_temperature_k`, which for `babbitt` is documented as the melting point, and
`water.yml` already establishes the convention for encoding latent heat — the gap between two
`formation_enthalpy_j_per_kg` entries. So this is one field and an existing convention.

> **`Nodes::FusiblePlug` is the bespoke version of this**, and worth reading before building the
> general one. It reaches the same outcome by a **proxy**: it senses the crown sheet's recorded
> temperature, compares it to a configured threshold, and latches. It carries no mass of its own,
> no latent heat, and no self-heating — so the melting is asserted rather than modelled, and the
> reading arrives a tick late. Its own comment says why: *"`Boiler#crown_temperature_k` needs the
> tick context and has the wrong arity entirely. So the boiler records the value in its own state
> and this reads the key."*
>
> A plug built on the real thing would carry its own fusible mass, sit on a thermal link, and melt
> when **its own** temperature passed **its own** material's melting point — no sensed key, no
> configured threshold, no lag. That is strictly better physics and it deletes three pieces of
> configuration.

**Build it as a concern** — `Concerns::Fusible`, "this part is made of something with a melting
point, and given more heat than it can shed it goes." The bearing is the first caller; the plug
and the crown sheet are the obvious next two.

> **Do not rebuild the plug in G.** It is safety-critical, specced, and working, and the
> conversion is a separate change with its own risk — `crown_sheet_spec` is the most expensive
> file in the suite precisely because it drives that hazard end to end. Land the concern on the
> bearing, then convert the plug deliberately.

---

## 4. Decisions, and what was rejected

### 4.1 Granularity — one lumped node per duty

`:main_bearings` and `:piston_rings`, named so that splitting into per-journal siblings later
reads as addition rather than a rename.

- **One per journal** (main, crank pin, crosshead) makes the oiling round a *route*, and lets a
  player neglect one specific bearing — which is how the job actually worked. But it is three
  nodes, three gauges, three rng streams and triple the tuning for one narrative beat.
- Volumes are the next release, and they are what would make a route mean anything. Until then a
  route is three gauges showing the same story.

### 4.2 Who owns the drag — `supports:`, asked in phase 4d

Mirrors `Cylinder#drives`. The bearing owns its own physics and its own heat, and a shaft with no
bearing simply has no drag.

- **Making `Rotating#friction` stateful** so it consults a bearing is the smallest diff, and wrong:
  every rotating node would have to know a bearing exists, `friction` is config today, and it puts
  a cross-node read on the hot path while inverting who owns the number.
- **Duck-typing a brake as a prime mover** would need no new plumbing at all — `transmit_torque`
  already selects on `respond_to?(:drives) && respond_to?(:extractable_joules)`. But
  `extractable_joules` and its budget clamp are written assuming a thermal *charge being spent*. A
  brake is not a prime mover, and pretending otherwise would badly mislead the next reader.

### 4.3 Oil — flows as mass, film derived

Covered in §3.6. The store is conservation-audited and gauged for free; the film is a pure
function of supply and speed; nothing is stored twice.

### 4.4 Cylinder efficiency — folded in and deleted

This is the decision that generalises the whole abstraction. Keeping `efficiency` beside a real
friction model would leave two mechanisms for one phenomenon, one of them honest and one of them a
derate that never costs anything.

The objection worth recording: reciprocating friction — rings, crosshead, gland packing — is
genuinely *not* journal friction, and folding it into a thing called a bearing could be read as
overstating what bearings do. The answer is that a bearing here is **a friction interface**, not a
journal, and `duty:` is precisely where that distinction lives. Frictional failures are among the
most common in any industrial setting — hot ropes on pulleys, pistons in bores, belts on drums —
and one extensible model for all of them beats a special case each.

### 4.5 Roller bearings — an upgrade, with a different failure

They are largely just better: less friction, sealed, no oiling job. That is fine. Progression is
gated by unlocks, and an upgrade the player has earned is allowed to be better; it does not need
an artificial drawback to justify itself.

It does get its **own failure mode**, because that part is both interesting and true: a plain
bearing telegraphs distress for a long time — heat, smell, knocking — and can be caught by
somebody paying attention. A roller bearing fails **suddenly**. The choice that remains is
therefore cheap-and-attentive versus expensive-and-blind, which is a real one without needing to
be a sidegrade.

---

## 5. What this must not foreclose

- **Ropes, belts and pulleys.** The `duty:` split is what makes those a third adapter rather than
  a new subsystem. Do not collapse it back into journal-specific code.
- **Volumes.** Hazards resolve through stations, as they already do. Per-journal nodes are what
  make an oiling route meaningful, and that wants places.
- **`DriveLink#max_torque`.** Declared, stored, and never read — `Arbiter.settle_drive` never
  passes `limits:` to `Relaxation.settle`, though the solver supports it. A stiffer coupling makes
  "the belt snaps" expressible for the first time. Do not spend it on something else.
- **In-match repair.** `failure_model.md` §10 specifies it as clearing `failure` back to `nil` and
  restoring durability, and nothing implements it. Re-babbitting a wiped bearing is the obvious
  first repair job — build nothing that makes a failure irreversible in principle.
- **Fatigue accrual.** Named in §3.7; belongs to whoever does it.
- **Oil quality.** Pitting, water ingress and dirty oil are real and deliberately out of scope. Do
  not build the oil resource assuming it has only one grade.

---

## 6. Staging

| | |
|---|---|
| **A** | ~~Fix the load's integrator and re-measure.~~ **Done 2026-09-17 — see §6.1.** Drag is now solved inside the drivetrain network; 85% mechanical efficiency, `stiffness:` untouched. |
| **B** | ~~`:bearing_oil`, the store, the gauge.~~ **Done 2026-09-17.** A `lubricant` tag, `content/resources/lubricants.yml`, `:oil_store` as a required slot with `:stock_oil_store` in it (180 kg), and an `oil_remaining` gauge quantised to 5 kg. Priced in `blueprints.yml` with its first fill. Nothing on the tick path yet — the store is a passive holder nothing draws on. |
| **C** | ~~`Nodes::Bearing`, `duty: :journal`.~~ **Done 2026-09-17.** `Thermal` + `Holds`, `supports:`, `loaded_by:`, the two-term law, heat into its own joules. `Wearing` deferred to E, so no mode is declared that nothing can reach. |
| **D** | ~~`duty: :slide`; delete `Cylinder#efficiency`.~~ **Done 2026-09-17** — see §6.3. |
| **E** | ~~The ladder.~~ **Done 2026-09-17 — see §6.5.** `Wearing`, both rungs, the seizure drag, and the two instruments that make it visible. `endangers:` moved to F, where the station it must name is created. |
| **F** | ~~The oiling station.~~ **Done 2026-09-18 — see §6.6.** Oil is drawn, spent and ledgered; `:lubrication` is a required slot with `:hand_oiling` in it; `:oiling` is an effort station with **no crew role**, which is the point. Panel gauges landed in E. |
| **G** | ~~The parts catalogue, Archard, and melting.~~ **Done 2026-09-18 — see §6.7.** Three bearing tiers and two lubrication methods, priced and gated; Archard wear **alongside** the thermal term rather than replacing it (§3.10 was wrong about that, and the measurement is there); and `Concerns::Fusible`, which `Nodes::FusiblePlug` was converted onto. |
| **H** | **The balance sweep**, recorded as a table the way the minions gradient was. |

### 6.1 Stage A, as built

Landed 2026-09-17. It took two steps, and the first one was not enough.

**Integrating the brake exactly was necessary and insufficient.** All three torque curves have
closed forms — `:constant` steps linearly and clamps, `:viscous` is `Relaxation.to_reservoir`,
`:fan` is `ω₀ / (1 + kω₀·dt/I)` — and with them the mill held speed instead of being slammed to a
standstill. Friction fell 58.6% → 38.7%. But it settled at **8.5 rad/s against a true equilibrium
of 19.6**, because phases 4d and 4e were each exact while the *split between them* was
first-order in `dt`. Halving `dt` halved the gap, monotonically, which is the signature of a
split rather than a bad law:

```
dt      load ω    slip %    gap to equilibrium
0.250    8.468     65.3           -11.151
0.125   11.195     48.6            -6.644
0.050   13.532     31.9            -2.955
0.025   14.461     24.6            -1.531
0.010   15.059     19.7            -0.627
```

**So drag moved into the solve.** `Relaxation.settle` takes `drags:` — `{ node_id => conductance }`
against a reservoir at potential zero, which is a diagonal term and no right-hand side.
`Concerns::Rotating#drag_conductances` declares them keyed by ledger destination, `settle_drive`
gathers them, and a nonlinear brake is linearised as `τ(ω)/ω` capped at `I/dt`. A body dragged
but coupled to nothing is solved as its own one-node component.

**Result: 85% mechanical efficiency** — 184.8 MJ of work against 32.2 MJ of friction — with the
flywheel at 174 rpm and the mill at 135. `stiffness:` was never touched, which is the point: the
9 000 that three documents blamed was innocent.

> **The trap, and it stayed green the whole time.** Kinetic energy is quadratic, so no
> intermediate state between two settled ticks means anything. Applying the couplings, measuring,
> then applying the drags charges each for a state the machine was never in — it inflated the
> mill's output past its own engine's and drove `joules_to_friction` **negative**, while the
> conservation specs passed throughout because the *total* was still right. Measure the total;
> estimate only the split, at the speeds the network settled to.

### 6.3 Stages C and D, as built — and the sweep

#### Measure against shaft power, never against the indicator diagram

The first sweep read 79–86% and every figure in it was about five points pessimistic, for a
reason that has nothing to do with bearings. A steady-state audit closes to **0.01%** and shows
where:

```
cylinder declared (indicated)      501.9 kW
cylinder actually billed (shaft)   474.9 kW
--> declared but never claimed      27.1 kW   (5.4%)

of what reached the shaft:
  delivered to the mill            427.3 kW
  bearings, into their metal        40.0 kW
  belt slip + windage                7.6 kW
  change in stored rotating KE       0.0 kW
  sum                              474.8 kW      unaccounted 0.01%
```

That 27.1 kW is **not** the `extractable_joules` clamp, which was the first suspect and is
**dormant** — checked at throttle 10, 20, 60 and 100, the impulse lands unscaled every time. It
is a discretisation term, and it is exactly `ΔL²/2I`:

> `indicated_power_w` is `torque × ω` at the speed the shaft ended the *previous* tick, which is
> the top of an intra-tick sawtooth — phase 4d slows the shaft by 11% before the cylinder pushes
> on it in 4e, and 4e hands it straight back. At steady state the net is zero, so
> `ω_prev − ω_impulse = ΔL/I` exactly, and the gap reduces to `ΔL²/2I` — half the kinetic energy
> of the impulse itself. Measured at four throttle settings, the ratio is **exactly** ½ every
> time.

Nothing is lost or created: `transmit_torque` bills the measured kinetic energy gain, which is
why the audit closes to 0.01%. The consequence is only that **`indicated_power_w` reads about 5%
high and is not a safe denominator** — the `engine_power` gauge already avoids it and shows
`shaft_power_w` instead.

It scales as `torque·dt / (2·I·ω)`, so it grows with `time_scale` and shrinks with flywheel
inertia. That affects the reported figure, never the physics.

#### The sweep, against shaft power

Seed 7, high-pressure, crewed. Each row is a full cold start to steady state.

| regime | rpm | shaft | `ΔL²/2I` | rings | journals | belt | mech. eff. |
|---|---|---|---|---|---|---|---|
| thr 20, load 80 | 122.3 | 205.3 kW | 4.6% | 10.2% | 0.3% | 1.5% | 88.2% |
| thr 40, load 80 | 150.4 | 360.2 kW | 5.3% | 8.6% | 0.2% | 1.6% | 89.1% |
| thr 60, load 80 | 171.4 | 474.9 kW | 5.4% | 8.1% | 0.2% | 1.6% | 89.6% |
| thr 100, load 80 | 196.5 | 622.4 kW | 5.3% | 7.7% | 0.2% | 1.6% | 89.9% |
| thr 60, load 30 | 235.4 | 578.2 kW | 3.4% | 8.6% | 0.4% | 1.6% | 89.4% |
| thr 60, load 100, damper 60 | 171.6 | 474.3 kW | 5.4% | 8.1% | 0.2% | 1.6% | 90.0% |

**88.2–90.0% across 3× power and 2× speed** — a 1.8-point spread, at the top of the 80–90% band
real stationary engines sit in.

Four things this settled:

- **The split holds across regimes, and not by luck.** Ring loss declines gently with pressure
  (10.2% → 7.7%) because the static ring tension matters less as gas load grows, which is what
  `μ·(static + p·A)·v` predicts. Journals and belt are flat.
- **A flooded journal is genuinely almost free**, and that is not a modelling failure. Plain
  bearings run μ ≈ 0.002 on a full film; a steam engine's mechanical loss lives in the **rings,
  gland and crosshead**, which reverse twice a revolution and never build a full wedge. So
  `:journal` sits at 0.2% and `:slide` carries eight — which is what makes deleting
  `Cylinder#efficiency` the load-bearing half of this work rather than a tidy-up.
- **The first reading, 79.2%, was two errors cancelling** — journals at 1.6% where a real engine
  loses ten, and a belt at 19.5% where a real one loses three. A plausible total over two wrong
  halves, which is why the decomposition matters more than the figure.
- **`stiffness` must never be tuned to hit a loss target again.** See below.

Running temperatures, which is what stage E's ladder keys off:

```
main_bearings   320.1 K   (+27 over ambient, babbitt rated 520)
piston_rings    440.9 K   (+148 over ambient, bronze rated 700)
```

Starved — the oil taken out of the journal mid-run — it reaches **640.9 K**, well past babbitt's
520 K, while dragging the engine from 174.2 to 170.8 rpm. The hot box is reachable before
anything in stage E is written.

Peak temperature over a whole run is the **steady-state** figure, not a startup transient: 320.1 K
for the journals and 440.9 K for the rings, both reached at the end. Margins to their ratings are
+200 K and +259 K, so nothing is near its limit in ordinary service — which is correct, and means
stage E's ladder will be reached through starvation rather than through hard running alone.

#### Why the belt may not carry balance, however convenient it is

A viscous coupling dissipates `Δω/ω` of what crosses it, so its loss fraction goes as
`P/(k·ω²)` — that is a **fluid coupling**, not a belt. A real belt loses a roughly fixed
percentage of transmitted torque, near-independent of speed. The law has the wrong *shape*, so
no value of `stiffness` is defensible across every regime; the sweep above is flat at 1.6% only
because 150 000 makes the term small enough that its shape cannot distort anything.

> **Make the ill-formed term negligible, and let the well-formed term carry the physics.** The
> bearing law is Stribeck-blended Coulomb friction and transfers across regimes on its own
> merits; the coupling should be stiff enough to be a connection rather than a loss mechanism.
> If a real belt loss is ever wanted it needs a torque-proportional model, which is what
> `DriveLink#max_torque` is sitting there unused for.

### 6.4 A lever we have not pulled: the prime mover's torque belongs in the drive solve

**Not needed now. Written down because it is a small change that would be easy to re-derive
badly under pressure.**

Phase 4d settles the drivetrain — couplings and drag together, implicitly. Phase 4e then applies
the prime mover's torque *afterwards*, as a separate step. That is the same operator split this
release removed for the load brake, and it leaves a measurable residue: the shaft loses **11% of
its speed** in 4d and gets it back in 4e, every tick, forever.

It is benign where the brake's was not, and the reason is worth keeping: **a brake is stiff
feedback and a prime mover is a near-constant source.** Splitting a source term is first order in
`dt` with a small constant; splitting stiff feedback diverges. So this one costs a sawtooth and a
reported figure that reads ~5% high, rather than a mill pinned at a standstill.

What it would take, if the sawtooth ever bites something:

- **`Relaxation.settle` already accepts current sources.** A pinned coupling contributes
  `rhs[i] -= rate; rhs[j] += rate` and no conductance — which is exactly what a torque applied to
  one node is. A `sources:` keyword shaped like `drags:` would need the same handful of lines.
- `Arbiter.settle_drive` gathers them from nodes that declare `drives`, the way it already
  gathers `drag_conductances`.
- `Tick#transmit_torque` stops applying the impulse and keeps only its **billing** —
  `extractable_joules` and the charge accounting — reading the settled transfer instead of
  creating it.

Two things to be careful of, both of which the brake taught us:

- **Keep the billing exact and the split estimated.** `transmit_torque` bills the measured
  kinetic energy gain, which is what makes conservation hold at any `dt`; solving the impulse in
  the network must not become an excuse to bill `torque × ω × dt` instead.
- **`extractable_joules` is a constraint, not a clamp**, and `Relaxation` already has the
  machinery for that — `limits:` with its active-set pass. A starved cylinder is a coupling that
  has run past a bound, which is the same problem as a choked flue.

The payoff is not the 5%: it is that **`indicated_power_w` would become honest**, the intra-tick
sawtooth would go, and every prime mover afterwards would get the same treatment for free.

> **Seizure is the first mechanic that makes this bite** — see §6.5. A locked bearing is exactly
> the stiff drag this splitting is benign *against a near-constant source* only. Measured: a
> seized journal cannot quite stop the engine, which limps at 26.9 rpm against 167.7, because
> phase 4e puts the cylinder's impulse back every tick after 4d has taken it out.

### 6.5 Stage E, as built — the ladder

Landed 2026-09-17. Three things came out of the measurement rather than the design, and two of
them were wrong first.

#### The thresholds come from the material, through one fraction

`Thermal#rated_temperature_k` already resolves `material:` to `max_temperature_k` — 520 K for
babbitt, 700 K for bronze. The ladder needs *two* temperatures, so `SERVICE_FRACTION = 0.8` gives
the service limit from the same figure rather than adding a second that can drift from the first.

That fraction is not a taste: babbitt melts at 235–370 °C and is run to about 150 °C, and
423/520 = **0.81**. The research picked it.

#### A threshold that slides with durability collapses the ladder

The first cut had `overload?` slide from the melting point down to the service limit as integrity
drained — the concern's own advice, that a worn part should fail sooner. Measured, the starved
journal went **straight to `:seized` at 481.7 K on a 0.63 integrity**, having never wiped. The
part crosses a falling threshold before fatigue can finish, so the warning rung never happens.

**The threshold is flat, at the melting point, for a sound bearing and a wiped one alike.** What
"running on wiped metal is worse" means is the `film:` derate — a mechanism, not a second
threshold — and it leaves the two rungs genuinely separate. Measured after the fix, on a journal
starved at running temperature:

```
wiped   +119 s   487.9 K       <- the warning
seized  +150 s   520.1 K       <- babbitt's own figure
```

**A 31-second window** between the rungs, with a prose gauge saying "smells hot, knocking badly"
the whole way. That is the hot box, and it is the shape the failure literature describes.

> The derate does nothing to a bearing that is *already* dry, because `film` is 0.0 the moment
> the charge is. The runaway is a mechanic for a partly-wet bearing; a dry one is simply at the
> bottom of the Stribeck curve already.

#### `I/dt` is not a stop, and the docs said it was

Seizure has to act through the drag term — neither `Tick#stress` nor `settle_drive` will stop a
shaft for a part that does not rotate and is not a link end. So a seized bearing declares the
shaft's stall conductance. **At `I/dt` that left the engine limping at 45 rpm**, and chasing it
turned up a wrong comment in three places: `(I/dt + c)·ω′ = (I/dt)·ω` at `c = I/dt` gives
`ω′ = ω/2`, so the cap **halves a body per tick** rather than bringing it to rest. It bounds how
far a linearised brake is trusted; it stops nothing.

`SEIZED_CONDUCTANCE_MULTIPLE = 40.0` keeps 2.4% of the speed per tick instead. Measured:

```
167.7 rpm  ->  23.2  ->  19.4  ->  ...  ->  26.9 rpm stable
shaft power 400 kW -> 57 kW          bearing 520 K -> 694 K and climbing
```

**It does not stop dead, and that is the §6.4 splitting artefact rather than the bearing.** The
limp speed is set by 4e putting the cylinder's impulse back after 4d has taken it out. An 84%
speed collapse on a glowing, wrecked engine is a fair outcome, so the lever stays unpulled — but
this is the first evidence that it costs something real.

#### What it cannot yet reach

**The rings' rung is unreachable by working the engine hard.** Measured at 3000 ticks:

| | rings | limit | journal | limit |
|---|---|---|---|---|
| throttle 60 / load 80 | 443.5 K | 560 K | 325.1 K | 416 K |
| throttle 100 / load 100 | 459.3 K | 560 K | 329.1 K | 416 K |

A hundred Kelvin of headroom flat out. So **stage D's claim that folding in `Cylinder#efficiency`
makes cylinders wear from ordinary hard running is not yet delivered** — the route to a worn bore
is still hydraulic lock.

That is a model gap rather than a tuning one, and the fix is that **wear is rubbing, not heat** —
Archard against the boundary friction power the interface already computes. **Decided and
scheduled for stage G; the design is §3.10.** It waits for G rather than landing here because it
makes bearings consume themselves in ordinary running, and a part that wears out needs a
catalogue to be replaced from.

### 6.6 Stage F, as built — the oil round

Landed 2026-09-18. The physics was the easy half; both real mistakes were about who does the
work and who decides how much.

#### A station with no role, which is the whole mechanic

The first cut added an `:oiler` crew role. **That silently deleted the feature.** An unfilled
role gets `Crew::STANDIN`, so a posted oiler is somebody permanently on the round for free —
and the measurement showed it: the run with "no oiler" still filled its bearings, just more
slowly, because a day-labourer was doing it.

`:oiling` is therefore a station **no role is posted to**. Nobody is there until the player sends
somebody, which means pulling the fireman off the shovel while the fire dies. That is the
decision §3.7 describes, and a third role hands it back for nothing.

> **Generalises past this release: adding a role to a station is how you accidentally un-design a
> mechanic**, because the standin makes every role self-filling. A station that is meant to
> compete for somebody's time must have no role of its own.

#### `Intent.none` is not "I want nothing"

The bearing asks for exactly what it is short of, and the first cut returned `Intent.none` once
full. **A path with nothing declared at either end is driven by the path**, so oil kept arriving
until the *housing* was full: a journal meant to hold 1.2 kg sat at **8.9 kg**, which is its
0.01 m³ of volume, and nothing could ever run short of oil again.

`rate_desired` tests `draws.key?`, not `positive?`, so the fix is to declare the draw even when
it is zero. The regression is now a spec, because it fails in the safe direction — an engine that
cannot run dry looks exactly like one that is being well maintained.

#### What it measures

Oil is spent by **sliding distance**, not by time, with a multiplier that roughly doubles it at
the service limit — so a faster engine drinks more, and a bearing getting low runs hot and then
drinks faster still. That is the second half of the hot box.

| | journal | rings |
|---|---|---|
| charge | 1.2 kg | 0.8 kg |
| `oil_loss_kg_per_m` | 2.0 × 10⁻⁴ | 1.4 × 10⁻⁴ |

With the fireman walking the machine every five simulated minutes, both bearings fill and drain
back to roughly two thirds before the next round, the store falls about **3.2 kg per hour**, and
nothing ever fails. With nobody ever sent:

```
main_bearings  wiped  at 524 s   447.2 K   oil 0.651 kg   159.7 rpm
main_bearings  seized at 632 s   520.1 K   oil 0.551 kg   157.8 rpm
```

**A 108-second warning window**, reached in play rather than on a rig. Conservation holds exactly
throughout — mass drift 2.1 × 10⁻¹⁵, energy drift zero — through a new `mass_consumed` ledger
line, which is neither a vent nor a spill because an engine working properly would otherwise read
as one that is leaking.

> **The enthalpy has to go with the mass.** Oil leaving carries `joules_discarded`, or the energy
> balance drifts by the heat content of every drop ever burnt off.

#### Two figures that are not physics

`oil_line`'s rating is 0.06 kg/s, raised from 0.02 because a round is meant to be a **visit, not
a vigil**: at the lower figure a competent hand needed minutes at the lever and the rings never
once reached their charge, so an attentive player got a permanently under-oiled engine. What
costs the player is being *away from the shovel*, and that is already the whole price. The
drum's tap went 0.05 → 0.2 for the same reason — at 0.05 it throttled both lines at once and made
the second bearing wait for the first.

> **A seized bearing settles near 1650 K**, which is the honest equilibrium of 57 kW into 42 W/K.
> Audited: conservation holds exactly through the failure — worst single-tick drift 3.0 × 10⁻⁸ J
> against a 1.65 × 10⁸ J system, total relative drift 2.3 × 10⁻¹⁵ — and every joule the shaft
> loses lands in the bearing and leaves through `joules_to_ambient`. The trigger and the
> accounting are honest.
>
> **What is not bounded is the temperature.** Nothing limits it, so it only lands somewhere
> defensible because this flywheel is small: the same bearing under a 162 MJ rig flywheel reaches
> **15,563 K**. Melting the lining does not fix it (§3.11); **radiation would**, and that is a
> change to `settle_ambient` affecting every hot node rather than anything about bearings.

### 6.7 Stage G, as built — the catalogue, Archard, and melting

Landed 2026-09-18. Both model changes in this stage turned out differently from how §3 described
them, and both corrections are recorded where the original claim was, rather than here.

#### Two wear mechanisms, not one

§3.10 claimed Archard would subsume the thermal path. It does not, and the boundary-power table
in that section is why: a starved journal rubs at 10 kW while healthy piston rings rub at 76, so
any coefficient fast enough to wipe the first destroys the second. The model carries both terms,
which is also what §2.3's research table said in the first place.

#### Melting gives a reason, not a bound

§3.11 claimed the melt would cap the seizure temperature. Measured: 31 K off the spike, nothing
off the 1652 K equilibrium, because a seizure delivers more energy in one tick than the whole
lining can absorb. **Radiation is what bounds it**, and that is the release after this one.

What melting *did* earn is the plug: `Nodes::FusiblePlug` was a boolean latched against a
configured `melts_above:`, and is now `Concerns::Fusible` — real alloy, real latent heat, opening
as it runs. The conversion **deleted** configuration rather than adding it, which is the sign it
was the right generalisation:

| before | after |
|---|---|
| `melts_above: 620.0` | the alloy's own melting point |
| `melted: true/false` | an inventory of metal |
| opens all at once | opens as it runs |

#### The catalogue

| slot | part | what makes it different |
|---|---|---|
| bearings | **Babbitt Journals** | soft and sacrificial — it melts out so the crank does not |
| | **Bronze Journals** | 560 K service against 416, so it takes neglect — and scores the crank when it finally goes |
| | **Roller Bearings** | flat friction, no oil at all, barely wears, and **no warning** |
| lubrication | **Hand Oiling** | an effort station: somebody leaves the shovel |
| | **Ring Oilers** | a valve, not a station — but delivers nothing on a stopped shaft |

Two of those needed a model change to be expressible rather than approximated:

- **`mu_film:`/`mu_boundary:` per fitting.** A roller needs no oil film, so its friction is flat
  across the Stribeck curve instead of swinging forty-fold, and no combination of oil charge and
  `film_speed_m_s` expresses "does not care about oil". `MU` stays the default for a plain
  bearing of that duty.
- **The roller's no-warning failure falls out rather than being declared.** Its wear rates are an
  order down, so durability barely moves and `bearing_condition` reads "cold and quiet" — then
  `overload?` fires on temperature with the gauge never having drifted. Nothing anywhere says
  "this one is sneaky"; it is sneaky because of what it is.

> **Each tier is a trade, not a ladder**, and the prices are gated on achievements rather than
> ordered by cost. Bronze is tougher *and* less forgiving; a ring oiler buys back a person *and*
> cannot oil a stalled engine, which is exactly when a journal is most at risk.

### 6.2 If the slip ever needs attention

**It does not, yet.** The coupling still runs about 22% slip, which is a lot for a belt — but the
*loss* it costs is inside the target band, and bearings are about to put a second dissipation
term on the same shafts. Stiffening it now would overshoot and then have to be undone.

The diagnostic if it comes up again: for a viscous coupling at steady state `T = k·Δω`, so the
dissipated fraction is exactly `Δω / ω_driver` — one number — and `k ≥ T / (target_slip × ω)`
sizes it. At the present duty point a 5% slip target wants `k ≈ 40 000` against the 9 000 fitted.

> **The mill may also simply be too big for this engine.** At 18.3 rad/s its fan curve demands
> 46.9 kN·m where the engine makes about 21.8. That is a balance question rather than a bug — a
> mill you cannot pull up to speed is a legitimate thing to own — but it is worth knowing before
> reading any of these figures as a physics result.

---

## 7. Verification

- **Conservation first, and throughout.** Friction heat moving from a ledger exit into a node's
  joules is exactly the class of change `conservation_spec` exists to catch, and deleting
  `Cylinder#efficiency` changes what the cylinder is billed. Write it before the friction law, not
  after.
- **Determinism.** The film is a pure function of oil and speed and there is no new entropy
  anywhere, so a bearing that fails must fail identically on replay.
- **Snapshot round-trip.** The failure mode comes back as a **Symbol**, asserted with `be` and
  never `eq`. Sixth instance of that trap; the digest cannot catch it, because `canonical` runs
  through `JSON.generate` where `:wiped` and `"wiped"` are one string.
- **`failure_spec` walks every catalogued machine** and rejects a part left on `GENERIC_FAILURE`,
  so `failure_modes` is required rather than optional.
- **The Stribeck swing as a table spec**: same load and speed at full oil versus none, asserting
  the *ratio* rather than pinned figures, for the reason the ashpan example records.
- **The runaway, end to end**: post a crew, stop oiling, and assert the bearing heats, wipes, then
  seizes — and that the seizure actually stops the shaft, which §3.5 says neither existing
  mechanism will do for you.
- **Cylinder wear from ordinary running**: a long hard run at high pressure measurably consumes
  bore durability, with no priming and no hydraulic lock anywhere. This is the assertion that says
  stage D worked.
- **`endangers:` reachability**, mirroring `failure_spec`'s inverse check: no mode endangering a
  station that does not exist.
- **The efficiency target**: assert `delivered / shaft`, **never `delivered / indicated`** — a
  `ΔL²/2I` discretisation term puts 3.4–5.4% between the two and it is not a loss at all.
  Assert the range across several regimes rather than one pinned figure, for the reason the
  ashpan example records; 88–90% today.
- Full suite in the background at each stage boundary — **check the example count, not just the
  failures.**

---

## 8. Sources

- [Failures in babbitt bearings — Turbomachinery](https://www.turbomachinerymag.com/view/failures-in-babbit-bearings)
- [A visual guide to babbitt failure](https://fusionbabbitting.com/babbitt-bearing-failure-analysis/)
- [Survey of damage investigation of babbitted industrial bearings — MDPI](https://www.mdpi.com/2075-4442/3/2/91)
- [Hot box (rail) — Wikipedia](https://en.wikipedia.org/wiki/Hot_box_(rail))
- [The Stribeck curve — STLE](https://www.stle.org/files/TLTArchives/2022/07_July/Lubrication_Fundamentals.aspx)
- [Hydrodynamic lubrication regime — Tribonet](https://www.tribonet.org/wiki/hydrodynamic-lubrication-regime/)
- [Petroff's hydrodynamic lubrication formula](https://www.engineersedge.com/calculators/petroffs_hydrodynamic_lubrication_15764.htm)
- [Sommerfeld number — Wikipedia](https://en.wikipedia.org/wiki/Sommerfeld_number)
- [Archard wear equation — Tribonet](https://www.tribonet.org/wiki/archard-wear-equation/)
- [Ring oiler — Wikipedia](https://en.wikipedia.org/wiki/Ring_oiler)
- [Splash lubrication — Wikipedia](https://en.wikipedia.org/wiki/Splash_lubrication)
- [Worsted wool trimming instructions — Heritage Steam Supplies](https://www.heritagesteamsupplies.co.uk/lubricators-accessories/worsted-wool/worsted-wool-instructions)
- [Freight car basics: roller bearings — Trains](https://www.trains.com/trn/railroads/history/freight-car-basics-roller-bearings/)
- [Efficiency of a steam engine — The Engineer's Post](https://www.theengineerspost.com/efficiency-of-steam-engine/)
