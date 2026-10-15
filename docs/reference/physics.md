# Physics

`lib/reactor_sim/physics/`. What substances are, how energy is held, and how the three
physical models behave.

---

## Units — SI, no exceptions

Conversion happens in `Displays` and nowhere else.

| Quantity | Unit | Stored or derived? |
|---|---|---|
| Mass | kg | stored |
| Energy | J | **stored** |
| Temperature | K | **derived** — `joules / heat_capacity` |
| Pressure | Pa | **derived** — from contents, volume, temperature |
| Angular momentum | kg·m²/s | **stored** |
| Angular velocity | rad/s | **derived** — `L / I` |
| Time | s | simulated seconds |
| Volume | m³ | |
| Conductance | W/K | geometry and material lumped into one number |

**Store the conserved quantity; derive the rest.** This is the single most load-bearing
convention in the physics:

- Energy, not temperature — mixing two parcels becomes addition rather than a weighted
  average, so it conserves exactly instead of approximately.
- Angular momentum, not ω or KE — momentum is what a coupling conserves. Store ω and two
  joined shafts have no conserved quantity between them, so every join becomes a fudge.
- Pressure is never stored. A stored pressure drifts from the state causing it and nothing
  tells you.

`Units.k_to_c`, `Units.c_to_k`, `Units.kpa`, `Units.kilo`, `Units.percent` exist for display
conversion.

---

## Parcels

A quantity of one substance carrying its own energy. Plain hashes, deliberately:

```ruby
{ resource: :water, kg: 12.0, joules: 5.0e7 }
```

Enthalpy is relative to a 0 K reference:

```
joules = kg × (specific_heat × T + formation_enthalpy)
```

The **formation term is what makes phase change exact.** Water and steam at the same
temperature hold very different energy per kg, and the difference is precisely the latent
heat — so condensing releases exactly what boiling cost.

`Physics::Parcel` is the arithmetic, all pure. Useful entry points:

```ruby
Parcel.build(resource:, kg:, temperature_k:, content:)
Parcel.temperature_k(parcel, content)
Parcel.normalise(parcels)     # merge same-resource, drop empties, sort canonically
Parcel.draw(parcels, kg, content)  # proportional take -> [taken, remaining]
Parcel.subtract(held, taken)
Parcel.total_kg / total_joules / total_volume / total_heat_capacity
```

> **Why hashes and not a class:** parcels are the measured hot path (allocation here was once
> 64% of a hundred-node tick) and they are snapshotted every tick, so a class would add a
> `to_h`/`from_h` round trip to maintain and buy nothing.

---

## Thermal

`Concerns::Thermal`. A node's structure and its contents are one lumped body at a single
temperature.

```
T = (joules + Σ parcel.joules − Σ formation) / (heat_capacity + Σ parcel heat capacity)
```

That approximation buys a lot: advection becomes exactly correct, because a parcel leaving
carries precisely the energy its temperature implies. Things needing genuinely distinct
temperatures are **distinct nodes**.

`rebalance(state, content)` restores the single-temperature invariant after anything changes
the mix. `add_joules` calls it for you. The engine calls it after advection, reactions and
phase change — you rarely need to.

Heat transfer between nodes is an implicit solve over the whole thermal network; loss to
ambient stays closed form, because a fixed-potential reservoir cannot be overshot. See
[`settlement.md`](settlement.md#heat-and-rotation-settle_heat-settle_drive).

### Radiation is a conductance, because `T⁴ − T_amb⁴` factors

```
T⁴ − T_amb⁴  ≡  (T² + T_amb²)(T + T_amb) · (T − T_amb)
                └──────── h_rad ────────┘

h_rad = ε · σ · A · (T² + T_amb²)(T + T_amb)        W/K
```

**That is an identity, not a linearisation of one.** So radiation is an ordinary term in the
machinery that already exists — added to `ambient_conductance` for loss to the environment, and
added to a `ThermalLink`'s conductance for body-to-body exchange — and inherits backward Euler's
unconditional stability. An explicit `T⁴` term would be precisely the integrator this file
forbids: `time_scale` 40 means `dt = 10 s`.

`h_rad` is evaluated at the **start-of-tick** temperature, which is first order like everything
else here and errs in the safe direction: a cooling body's true coefficient falls as it cools, so
this one under-states the loss and cannot overshoot past the sink.

Both halves are **opt-in** — `emissivity` and `radiating_area_m2` default to zero — so a node
that has not been given a surface is bit-identical to one from before radiation existed.

> **Emissivity belongs to the part, not the material**, the same call `safety_factor` makes.
> Oxidised iron runs near 0.8 and polished steel near 0.1, and what separates them is a wire
> brush rather than a different metal.

> **This is what makes a bright fire worth more than a merely hot one.** Measured on the steam
> engine's firebox→water-legs link: raising the firebox from 860 K to 1083 K multiplies the
> convective transfer by **1.51** — exactly the ratio of the temperature differences, as a linear
> term must — and the radiant transfer by **2.60**, which is exactly
> `(1083⁴ − 432⁴)/(860⁴ − 428⁴)`. A flat conductance cannot say that, and the damper and blower
> now change how much heat *reaches the water* rather than only how much fuel is burnt.

---

## Pressure

`Concerns::Pressurized`. Derived only, deliberately simple: ideal gas over whatever volume
the liquids are not occupying.

```
free  = max(volume − liquid_volume, volume × 0.001)
P     = Σ(gas moles) × R × T / free
```

Two behaviours that will surprise you if you don't know them:

- **An empty vessel reports 0 Pa — a vacuum, not one atmosphere.** Reporting 101 kPa for a
  node holding nothing meant a low-pressure source could never fill a receiver, and nothing
  could present the vacuum some machinery works against. *If a node should contain air, give
  it air.*
- **Gases are not limited by volume.** `Holds#room_m3` counts only condensed phases;
  `gas_headroom_kg(state, target_pa, content, resource)` provides the pressure limit instead.

Gas **transport** is driven by this pressure through the same network solve as heat, with
`mole_capacity_per_pa` (`dn/dP = V_free/(R·T)`) as the capacity term. Conductance is the whole
restriction on such a path — a port's `max_kg_per_s` governs rate-driven paths only, and
applying both makes every throat permanently choked, which removes the pressure feedback
entirely. See [`settlement.md`](settlement.md#heat-and-rotation-settle_heat-settle_drive).

Not modelled: hydrostatic pressure, flow-induced pressure drop. Pump and fan head exist as a
conduit's `head_pa`; a chimney earns its own from buoyancy.

**A head is not free any more.** A conduit naming a shaft with `driven_by:` is charged for the
hydraulic power it delivered:

```
P_hydraulic = (head_pa + ρ·g·lift_m) · Q          # Q volumetric, from what the wall passed
P_shaft     = P_hydraulic / efficiency
c           = P_shaft / ω²                        # a drag conductance, not a torque
```

`head_pa` is what the fitting *supplies* and `lift_m` is static head it must *overcome*; they sit
in one term because they are the same physics with opposite signs. Declared as a **conductance**
so it lands on the diagonal of the backward-Euler drive solve and stays unconditionally stable —
and it is the right shape, since a centrifugal machine's head goes as ω² and flow as ω, making
`P ∝ ω³` and `c` linear in ω. Hydrostatic pressure is still not a modelled *quantity*: depth is
charged as torque, not expressed as a gradient.

> A real centrifugal machine still churns against a closed valve — perhaps half its rated power.
> This charges it nothing, which understates a throttled pump and is the deliberate trade: the
> game question is whether the shaft can carry the load, not where the pump curve's knee sits.

---

## Rotation

`Concerns::Rotating`. Stores `angular_momentum`; everything else derives.

```ruby
omega(state)          # L / I
rpm(state)
kinetic_joules(state) # L² / 2I
rim_speed(state)      # ω × radius — what actually tears a spinning mass apart
```

Coupling is `DriveLink(a:, b:, stiffness:, max_torque:)`, settled by the same network solve as
heat and gas. `stiffness` is how hard the two ends are held to a common speed — a keyed shaft
is stiff, a leather belt is not, and the difference is one number rather than one class.

**Drag rides in the same solve.** `drag_conductances(state, ctx)` declares what pulls a body
toward rest, in N·m·s/rad, keyed by where the energy belongs — `:friction` for bearings and
windage, `:work` for a load's brake. `Relaxation.settle` takes them as `drags:` and puts them on
the diagonal, because a reservoir at potential zero adds conductance and no right-hand side.

> **A drag applied after the coupling is operator splitting, and it dominates once the drag is
> stiff.** Integrating each half exactly still leaves a composition that is first order in `dt`.
> Measured: a fan-law mill whose brake time constant is 0.18 s against a 250 ms tick settled at
> **8.5 rad/s against a true equilibrium of 19.6**, the coupling above it slipped 65%, and 39% of
> shaft power went to friction. Halving `dt` halved the gap, which is the signature of a split
> rather than a bad law. In the solve, the same engine runs at **85% mechanical efficiency**.
>
> A nonlinear brake is linearised as `τ(ω)/ω` at the tick's speed, capped at `I/dt`. That cap
> **halves a body's speed in one tick and no more** — `(I/dt + c)·ω′ = (I/dt)·ω` — so it bounds
> how far the linearisation is trusted rather than stopping anything; backward Euler is stable at
> any conductance and cannot reverse a shaft. It only ever binds for constant torque. A drag that
> genuinely means "this has stopped turning" declares a large multiple of it instead, which is how
> `Nodes::Bearing` expresses seizure.

### Gears, clutches, sources and a brake that sticks

A `DriveLink` may be geared and clutched — what lets a drum be driven both ways off a line shaft
that turns one way. Across a gear `g`, `b` gains `τ·dt` and `a` loses `g·τ·dt`: momentum is not
conserved across a gear and is not meant to be; energy is, and the slip `τ·(g·ω_a − ω_b)` is never
negative. **A clutch carries torque only as stiffness × slip**, so its stiffness has to be sized for
the load: the mine's winding clutches are 3×10⁴ N·m·s/rad because a tonne of coal on the deck is
14 kN·m at the drum, and at 4×10³ the slip that needed was more than the drum's rated speed — the
laden cage ran backwards into the sump. `cut_by:` names a node that can throw a clutch out whatever
its lever says, which is how an overwind trip cuts the drive as well as braking.

**A constant torque on a body is a source inside the solve** (`drive_torque`, passed as
`sources:`), never an impulse applied after it. Applied afterwards, a brake's drag — solved
first, against a body at rest — can never hold the load: the next tick's drag removes the impulse
and gravity re-adds it, so a "held" cage creeps at one impulse per tick.

**A constant-torque brake sticks, then slips** (`Nodes::Brake`). Linearised as `τ/ω` it has no
torque at rest, so while the shaft is all but stopped and its capacity exceeds the torque it is
holding against it declares a lock conductance of `I/dt × LOCK_MULTIPLE`; past that it slips at
its capacity. The torque it holds against is read from the shaft it `supports:`, as of last tick.

### A winding rope's tension, and the snatch

A winding rope (`Nodes::Rope`) is not in the drive solve: the hoist's gravity source carries the
load, and the rope only **reads** what it is carrying, off the drum as of last tick. Riding, that is
`(cage + cargo)·(g + |a|)`. A cage **hung** on something in the shaft is off the rope, so it carries
nothing while the drum pays out slack; when the hang gives, the cage falls its slack `h` onto a
rope of stiffness `s`, and the peak is

```
T = mg + √((mg)² + 2·s·mg·h)
```

— exactly twice the static load at no slack and rising with its root. At 8×10⁵ N/m and a 1,650 kg
cage that is 32 kN with no slack, 90 kN at 0.2 m and 178 kN at a metre: a slack metre parts a new
140 kN rope. The rope parts when this passes `breaking_kn × integrity`; the energy of the fall is
not booked, since the drum never stored the cage's potential energy to begin with.

### A rope between operations

Two operations cannot share a drive solve, so a shaft in one is joined to a shaft in another by a
**rope** (`Concerns::Roped`, `Match::Coupling`): a viscous coupling of conductance `k`, each end
treating the other's speed **as of last tick** as a reservoir. Below it an end is a driver,
`k·(ω_far − ω)`, paid from what the far end sent; above it, a brake booked to `:rope` and sent.
`ratio:` gears it — speeds cross divided by it, and `k` is reflected by `ratio²` — and energy is
invariant under it.

**The lag makes the cross term explicit**, so a stiff rope rings. For equal inertias the gap
between the ends scales by `(I/dt − k)/(I/dt + k)` per tick, which changes sign past `k = I/dt`.
Measured on an engine roped to a pit: no reversal of the slip at the line shaft's `I/dt`, a
reversal every other tick at twice it. `Match` refuses a rope past either end's own `I/dt`, which
is conservative for an end drive-linked to a heavier wheel.

---

## Phase change

`Resources::Saturation`. Boiling point from Clausius–Clapeyron against the substance's
reference point, so dropping the pressure makes the same water boil colder — which is what
makes a void coefficient expressible.

**Pressure and the liquid/vapour split are COUPLED and must be solved together.** Solving in
sequence oscillates violently: boil at last tick's pressure, which raises the pressure, which
raises the saturation temperature, which condenses it all again — a vessel flipping between
0 kg and 51 kg of steam on alternating ticks.

`Saturation.solve(liquid, vapour, parcels, volume_m3:, content:)` bisects in log space for
the self-consistent pressure. The inner loop runs on **captured locals only** — building
parcels inside it made this solve 64% of a hundred-node tick. `ITERATIONS = 20` is the first
dial to turn if a large operation needs to be cheaper.

The split is decided by **total enthalpy**, not temperature — which is what makes the
two-phase plateau work, where adding energy boils more water without the temperature moving.

Phase pairs are indexed **from both sides** (`content.phase_pair(:steam)` works). Indexed one way
only, a condenser holding nothing but vapour has no liquid parcel to discover the pair from and
never condenses at all.

---

## Reactions

`Resources::Reaction`. Chemistry has a **rate**, unlike phase change — an instantaneous
reaction has no transient, and the transient is the game.

```
extent = limiting_reagent × (1 − e^(−rate_per_s × dt))
```

Closed-form first order: unconditionally stable, never overshoots, at any `dt`.

**Air starvation needs no special case.** `limit` is set by whichever reagent runs out first,
so choking a damper throttles a fire through exactly the same code path an empty bunker does.

### Ignition

`Resources::Ignition`. A reaction that declares an `ignition:` block carries, per node, **how
many kilograms of its fuel are alight** — `state[:ignition][reaction_id] = { kg:, oxidiser_kg: }`.
Only that lit mass reacts.

Gating combustion on a node's bulk temperature is something a lumped-temperature node cannot do
honestly: a match does not raise a firebox to 700 K, it raises a few grams. As a bulk threshold
the fire is all-or-nothing — above the line the whole grate burns, below it nothing does and
nothing ever can again, so the only winning move is to leave the igniter on permanently, turning
a match into a throttle.

Five rules, each of which was got wrong first:

- **Only the lit fuel counts, and it caps the FUEL term** — `limit` becomes
  `min(ignited_kg, air/ratio)`, not the finished extent scaled by a fraction. Scaling the
  extent charges the fire for its draught twice, because `limit` is usually air-set already.
- **Spread does not depend on bulk temperature.** A flame front is hot even when the room is
  cold. Gate spread on `min_temperature_k` and a fire can never bootstrap. Bulk temperature
  belongs on the quench side, where `min_temperature_k` sets the scale.
- **Starvation cuts both ways** — it scales spread down *and* quench up. Otherwise the net
  rate bottoms out at `quench − spread` and a fire cut off from air dies far too slowly.
- **The fire remembers the draught.** Air passes *through* a node, so its standing inventory
  is a poor instantaneous signal; see the oscillation note in
  [`../current_progress.md`](../current_progress.md).
- **A mixture outside its flammability range does not burn at all.** `lean_fraction` and
  `rich_fraction` are a share of the volume and force **total quench** — not reduced spread —
  so a fuel suspended in a room carries a flame only between two concentrations. Separately
  opt-in from the block itself, because a fuel bed on a grate is not a mixture.

  Note what `quench_per_s` alone cannot do: it is multiplied by `max(chill, starved, unlit)`,
  so in a hot room with air to spare the quench term is **zero whatever figure is written**.
  A fire that will not go out is almost never a quench that is too low.
- **A fuel hot enough lights itself.** `autoignition_k`, opt-in in the `ignition:` block, seeds
  the fire at `Ignition::AUTO_SEED_KG_PER_S` while the fuel is past it — read against the hotter
  of the node's bulk temperature and its `hot_spot:` node's, as of last tick, because a lumped body
  has no local hot spot and a timber frame is lit where it touches the bearing. Wood declares it
  (573 K), coal (700 K) and firedamp (870 K) — the last so a gob fire can fire the district's gas
  through the district's `hot_spot:`, the one surface in a pit that gets there.

Spread is **closed-form logistic**, so it is exact at any `dt` and cannot overshoot. Logistic
because a fire spreads from its *edges* — and because from exactly zero it stays at zero, which
is what makes an igniter a match rather than a switch.

Storing the lit **mass** and deriving the fraction is the same choice made everywhere else in
the physics, and it pays twice: shovelling cold fuel on dilutes the fire for free, and fuel
that burns away takes its share of the fire with it.

**This does not replace modelling genuinely distinct temperatures as distinct nodes.** A
reactor's fuel pin really is hundreds of kelvin above its coolant, and no ignited fraction can
express that. The two answer different questions and are meant to coexist.

### Two rules that keep the books straight

**Stoichiometry conserves enthalpy, not temperature.** Products inherit the reactants' energy,
split by mass. Building products *at the reactants' temperature* looks harmless and is not:
11 kg of air at 1005 J/kg·K becoming 12 kg of flue gas at 1100 J/kg·K is a different amount
of energy for the same temperature, and it minted ~780 kJ every time it fired.

**`enthalpy_j_per_unit` is the only place a reaction may change the system's energy**, and it
must absorb any formation-enthalpy difference between the two sides. It is per unit of
reaction *extent*, not per kilogram — one unit consumes the whole `consumes` set.

Released energy is written to the node's `joules_from_reactions` and ledgered after phase 5.

Mass must balance: `Content` refuses to load a reaction whose `consumes` and `produces`
ratios do not sum to the same number.
