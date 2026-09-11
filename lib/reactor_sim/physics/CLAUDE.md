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

## Never use an integrator that is only stable for small `dt`

`time_scale` is a design dial, so nothing may assume the step is short. `Reaction` stays
closed form; `Relaxation` solves the whole coupling network **implicitly**, and both are
unconditionally stable at any `dt`. Explicit Euler returns **negative Kelvin at `dt = 100 s`**;
these converge cleanly at `dt = 10⁶`.

```
(C/dt + K) · p′ = (C/dt) · p + b                          # heat, rotation AND gas
extent          = limiting_reagent · (1 − e^(−rate_per_s · dt))   # reactions
```

**One solver, three quantities** — heat capacity ↔ moment of inertia ↔ `dn/dP`, temperature ↔
angular velocity ↔ pressure. Heat conserves **energy** exactly; gas conserves **mass**
exactly; rotation conserves **momentum** exactly and kinetic energy deliberately not — a
slipping coupling loses energy, and `Tick#drive` measures the difference and ledgers it as
`joules_to_friction`.

> **The pairwise closed form was not enough and its replacement was worse.** Per-coupling
> exactness does not compose in a network, and it cannot express flow *through* a body — so
> mass used `k·ΔP·dt`, which is explicit Euler, with a per-node bound standing in for
> stability. Every gas coupling in the steam engine ran 400–600× past that limit, and the
> bound moved a sender to the receiver's *current* potential without allowing for the receiver
> rising — a 2× overshoot that made two joined vessels **swap contents permanently**. The
> firebox showed it as a 5.9× tick-to-tick swing in the fire's heat output, and doubling the
> draught conductance *cut engine power to a fifth*. Backward Euler over the network is first
> order rather than exact, and that is the right trade: it closes `x/(1+x)` of the gap where
> the exponential closes `1 − e⁻ˣ`, reaches the same equilibrium, and cannot pass it.

`limits` are constraints inside the solve (a check valve is `[0, ∞]`), never a clamp applied
afterwards — clamping leaves every other coupling settled against a transfer that did not
happen. A pinned coupling may be released once, or it holds a flow the network has already
moved past: pinning the flue at its throat drove the firebox to an **80 kPa vacuum**.

**Cost scales with the largest connected component, not the node count.** The elimination is
cubic in one component, so `settle` splits the link list into components first. Measured: one
100-node network is 13.2 ms against 3.0 ms for the same nodes as 50 pairs. Real operations are
the second shape — the steam engine's largest gas component is three nodes — but
`performance_spec` guards both.

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

**Non-condensables are handled, and the way they are handled looks like a bug until you check
it.** The pair is solved against its own **partial** pressure — which is what vapour–liquid
equilibrium depends on — so adding air leaves the steam's partial pressure untouched; the air
then adds its own share to the vessel total in `Pressurized#pressure_pa`. Measured: 10 kg of
water at 380 K in 1 m³ holds 62.1 kPa of steam with or without air, and 1 kg of air takes the
vessel from 62.1 to 166.7 kPa. A condenser losing its vacuum to inleakage is already modelled.

The genuine limitation is narrower: there is no distinction between evaporative equilibrium and
**bulk boiling**, which requires the vapour pressure to reach the *total* pressure before
bubbles can form.

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
- **The fire keeps a short memory of the draught.** This was a workaround for a standing
  inventory that oscillated to zero every other tick; that oscillation was an unstable mass
  solver and is gone, and **disabling the memory now leaves the steam engine bit-identical**.
  It stays as deliberate fuel-bed inertia, not as a prop.

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
