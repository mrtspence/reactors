# `physics/` — substances, energy, the solvers

No graph awareness at all. Everything here is pure arithmetic over parcels, joules and
momentum. Reference: [`docs/reference/physics.md`](../../../docs/reference/physics.md).

## The convention everything rests on

**Store the conserved quantity; derive the rest.**

| Quantity | Stored or derived |
|---|---|
| Mass (kg), Energy (J), Angular momentum (kg·m²/s) | **stored** |
| Temperature (K) | derived — `joules / heat_capacity` |
| Pressure (Pa) | derived — contents, volume, temperature |
| Angular velocity (rad/s) | derived — `L / I` |

Energy rather than temperature makes mixing addition instead of a weighted average, so it
conserves exactly. Momentum rather than ω means two joined shafts have a conserved quantity
between them instead of a fudge. **A stored pressure drifts from the state causing it and
nothing tells you** — never store one.

**SI everywhere, no exceptions.** Unit conversion happens in `Diagnostics::Displays` and
nowhere else. `Units.k_to_c`, `Units.c_to_k`, `Units.kpa`, `Units.kilo` exist for that.

## Parcels are hashes on purpose

```ruby
{ resource: :water, kg: 12.0, joules: 5.0e7 }
```

They are the measured hot path — allocation here was once 64% of a hundred-node tick — and
they are snapshotted every tick, so a class would add a `to_h`/`from_h` round trip and buy
nothing. **Do not promote `Parcel` to a class.**

Enthalpy is relative to 0 K: `joules = kg × (specific_heat × T + formation_enthalpy)`. The
formation term is what makes phase change exact — condensing releases precisely what boiling
cost. See [`content/CLAUDE.md`](../../../content/CLAUDE.md) for why the YAML must encode it.

## Never replace a closed-form integrator with explicit Euler

`Relaxation` (heat and rotation) and `Reaction` (chemistry) are both closed form and
unconditionally stable at any `dt`. Explicit Euler returns **negative Kelvin at `dt = 100 s`**;
relaxation converges cleanly at `dt = 10⁶`. That is what makes `time_scale` a safe design dial
rather than a hazard.

```
transfer = c₁ · (p₁ − equilibrium) · (1 − e^(−dt/τ))     # heat, rotation
extent   = limiting_reagent · (1 − e^(−rate_per_s · dt))  # reactions
```

Heat conserves **energy** exactly. Rotation conserves **momentum** exactly and kinetic energy
deliberately not — a slipping coupling loses energy, and `Tick#drive` measures the difference
and ledgers it as `joules_to_friction`.

## Saturation: pressure and the phase split are coupled

`Resources::Saturation.solve` bisects in log space for a self-consistent pressure. Solving in
sequence — boil at last tick's pressure, which raises the pressure, which raises the
saturation temperature, which condenses it all again — makes a vessel flip between 0 kg and
51 kg of steam on alternating ticks.

- The split is decided by **total enthalpy**, not temperature. That is what makes the
  two-phase plateau work.
- The inner loop runs on **captured locals only**. Building parcels inside it was 64% of a
  hundred-node tick.
- `ITERATIONS = 20` is the first dial to turn if a large operation must be cheaper. The
  solve is currently ~50% of a 100-node step.
- Phase pairs are indexed **from both sides** — a condenser holding only vapour has no liquid
  parcel to discover the pair from, and used to never condense.

Known limitation: non-condensables are ignored, so air sharing a vessel with boiling water
does not raise its boiling point.

## Ignition

`Resources::Ignition`. A reaction declaring an `ignition:` block carries **how many kilograms
of its fuel are alight**, and only that mass reacts. Opt-in: without the block, the old
bulk-temperature gate stands.

Four things that were each got wrong first, and will be again:

- **The lit mass caps the FUEL term of `limit`**, never the finished extent. `limit` is usually
  set by the air already, so scaling the extent charges a fire for its draught twice.
- **Spread does not depend on bulk temperature.** Gate it there and a fire can never bootstrap:
  it cannot reach the threshold without spreading. Bulk temperature belongs on the quench side.
- **Starvation scales spread down as well as quench up**, or a fire cut off from air dies at
  only `quench − spread`.
- **The fire keeps a short memory of the draught**, because air passes *through* a node and its
  standing inventory oscillates to zero every other tick.

Spread is closed-form logistic — exact at any `dt`, cannot overshoot, and from exactly zero
stays at zero, which is what makes an igniter a match rather than a switch.

**It does not replace distinct nodes for distinct temperatures.** A reactor's fuel pin is
genuinely hundreds of kelvin above its coolant; no ignited fraction expresses that.

## Reactions

Chemistry has a **rate**; phase change does not. An instantaneous reaction has no transient,
and the transient is the game.

- **Stoichiometry conserves enthalpy, not temperature.** Products inherit the reactants'
  energy split by mass. Building products *at the reactants' temperature* minted ~780 kJ per
  firing.
- `enthalpy_j_per_unit` is the **only** place a reaction may change system energy, and it
  must absorb the formation-enthalpy difference between the two sides.
- Air starvation needs no special case — `limit` is whichever reagent runs out first.

## The ledger

`Ledger` is a hash of named floats inside operation state, snapshotted every tick. Policy:
**lossy is fine, silent is not.**

A node **cannot** write the ledger directly — that would be a cross-node effect during
evaluation. It records the amount in its own state and `Tick#record_injections` sums those
after phase 5. The state-key → ledger-line table is in
[`docs/reference/settlement.md`](../../../docs/reference/settlement.md#how-a-node-reports-a-crossing).

If you add anything that creates or destroys mass or energy, ledger it **in the same commit**.
Balance currently holds at zero drift over 1200 ticks.
