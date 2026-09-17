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

---

## Rotation

`Concerns::Rotating`. Stores `angular_momentum`; everything else derives.

```ruby
omega(state)          # L / I
rpm(state)
kinetic_joules(state) # L² / 2I
rim_speed(state)      # ω × radius — what actually tears a spinning mass apart
```

`friction_loss` relaxes toward rest in closed form, so a wheel coasts to a stop and never
through it into running backwards.

Coupling is `DriveLink(a:, b:, stiffness:, max_torque:)`, settled by the same network solve as
heat and gas. `stiffness` is how hard the two ends are held to a common speed — a keyed shaft
is stiff, a leather belt is not, and the difference is one number rather than one class.

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

Four rules, each of which was got wrong first:

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
