# Settlement: the arbiter and the ledger

`lib/reactor_sim/graph/arbiter.rb` and `lib/reactor_sim/physics/ledger.rb`.

The arbiter is the piece that lets every node be evaluated in any order while mass and
energy still balance exactly. Nodes declare what they *want* against the previous tick; the
arbiter sees every claim at once and decides what actually moves.

**Mass, heat and momentum all go through it, because they are the same problem:** claims
against a shared limit, settled once, with the remainder staying put. Nothing granted is
ever created; nothing ungranted is ever destroyed — it stays where it was, which is what
back-pressure *is*.

```ruby
Arbiter.settle(nodes:, states:, paths:, thermal_links:, drive_links:, intents:, content:, dt:, ctx:)
#=> Settlement(flows:, heat:, ambient:, drive:)
```

Nothing in here reads a clock, draws entropy, or depends on hash order.

---

## Mass settles over **paths**, not links

A `Path` runs from one holder's outlet to the next holder's inlet, through zero or more
**transport** nodes (`Node#transport?` — in practice `Conduit` and its subclasses).

```
   boiler ────[throttle]────► cylinder      one path, one tick
                  │
                  └── contributes a rate limit, a lever, a wall and the ability to fail
```

Paths are resolved once at construction by `Path.resolve` — the graph is configuration, not
state — so there is no per-tick traversal. Order follows the operation's own link list rather
than any hash, which is what keeps it order-independent.

> **Why a conduit may not hold material.** It used to hold what passed through it for one
> tick. An intermediate node has to size its intake from tick N−1, before it can know what it
> will discharge this tick, so the only bounded rule — `draws = throughput − held` — gives the
> map `h ↦ T − h`. That is an involution with eigenvalue exactly **−1**: it oscillates forever
> and cannot damp. Removing the `− held` term gives steady flow and an unbounded duct instead.
> **Steady inventory and steady throughput are mutually exclusive for a stateful intermediate
> node**, so the fix was to stop it being one.
>
> It cost a damper alternating 0.84 kg / 0.000 kg indefinitely, a firebox with *no air at all*
> every other tick, and a cylinder swinging 16.4/78.2 kW at operating speed. See
> [`../design_sketches/flow_through_issue_draft.md`](../design_sketches/flow_through_issue_draft.md).

`Path.resolve` refuses a conduit whose outlet goes nowhere (it would swallow mass rather than
back up) and a ring of conduits with no holder in it. `validate_graph!` refuses a transport
node that does not have exactly one inlet and one outlet.

---

## Mass: `settle_mass`

Four stages, in order. Each may only *reduce* a claim.

### 1. Desired flow per path

```ruby
if sink declares a draw       -> that draw
elsif source declares a push  -> that push
else                          -> the path itself drives it
```
then capped by the narrowest port anywhere along the path, and by every conduit's
`throughput_kg(state, ctx)` (its rating × its lever, or zero if it has broken).

> **An active sink is authoritative about its own intake.** This used to be
> `max(push, draw)`, which meant a sink could not refuse — a valve shoving its contents at a
> cylinder overrode the cylinder's own careful limit and packed it to eight times its supply
> pressure. A node that declares a draw gets exactly that.
>
> **With nothing declared at either end, the path drives the flow.** Holders are passive —
> `Vessel#plan` and `Atmosphere#plan` both return `Intent.none` — so if the route itself did
> not drive flow, nothing in the graph would move at all. This replaced the conduit's
> `pushes: held`.

Material must satisfy **every** port's tag filter along the path, not just the two ends. A
gas outlet wired to a liquid inlet moves nothing, and so does a gas-only valve halfway down a
water line — wiring mistakes the graph is allowed to make.

The desired mass is then split across the resources actually present, proportional to what is
there, so a drawn mixture has the same composition as the mixture it left behind — **unless a
part on the path has an opinion about the mix.**

### Transport affinity: what crosses, not how much

`Node#transport_affinity(port_id, state, ctx)` returns `{tag_or_resource => multiplier}`, and
`apportion` weights by `kg × affinity` instead of `kg`. Below 1.0 holds a substance back; above
1.0 carries more of it than its share. Empty for almost every node, and a path where nothing has
an opinion takes an untouched code path — the steam engine's digest is **bit-identical** with a
neutral affinity declared on every vessel.

Four rules, and each of them is load-bearing:

- **On a rate-driven path it changes the mix and never the total.** The weights are renormalised
  against the mass the path was already going to move. Letting an affinity change the total would
  make it a second throughput control, and two numbers describing one restriction is a mistake
  this engine has made twice already (see `max_kg_per_s` against `conductance` above, and the
  `extractable_joules` clamp that silently became a throttle).
  **On a pressure-driven path it is additive, and that is not an exception to the rule but a
  different rule** — see `Arbiter.entrained` below. A pressure solve rates the *gas*; condensate
  rides on top of it.
- **Product across ports, max within a port**, mirroring the tag gate exactly — `accepts?` is OR
  within a port and `ports.all?` is AND across them. Keep the shapes the same and the boolean
  gate stays the limiting case of the weighted rule instead of drifting away from it.
- **An exact resource key beats a tag key**, so a rule about one substance is always reachable.
- **Clamped to 10⁻⁶..10⁶ and never zero.** Hard exclusion belongs in `accepts:`, where it is
  structural and visible in the operation definition; a zero here is a deadlock that looks like
  a tuning value. It also means a separator always misplaces something, which is what a real one
  does.

> **The band has to be that wide.** An affinity works against the mass ratio actually held, and
> a boiler drum holds 2620 kg of water against 6.2 kg of steam — 424 to 1. Delivering the
> 99.5%-dry steam a real drum delivers needs a liquid weight near **1.2 × 10⁻⁵**; a 10⁻³ floor
> silently rounds that up into violent priming. `Nodes::Boiler` therefore declares the *steam
> quality* it achieves and solves for the multiplier, because nobody would have guessed the
> multiplier and it would stop meaning the same thing the moment the level moved.

> **`accepts:` runs first and will repeal the mechanic if you let it.** A tag filter is checked
> at **every** port on a path, so one `[:gas]` tag anywhere between a drum and a cylinder makes
> carryover impossible however hard the drum is boiling. That is the trap the chimney fell into:
> `accepts: [:gas]` stranded condensate in the cylinder until it flooded to 21.9 kg.

### `Arbiter.entrained`: the pressure-driven case

A pressure solve settles **moles of gas** down a gradient. It has no opinion about the droplets
travelling with them, so a pressure-driven path splits into three streams rated three ways:

| stream | rated against | rule |
|---|---|---|
| gas | the settled figure | **preserved exactly.** Reweighting it would break the mole bookkeeping the relaxation solved for |
| liquid | `min(what the weights imply, the path's rate)` | additive — it rides *on top* of the gas |
| solid | the path's rate | renormalised within the solid group; a lump of coal does not ride on steam |

Two rules here were each a live bug:

- **Liquid is bounded by the bore, and gas by the conductance.** The entrainment term is
  `desired × (1 − gas_share)/gas_share`, which grows without limit as a stream approaches pure
  liquid — a drum on the point of priming claimed its whole inventory in one tick. The only thing
  behind it was `scale_by_sink_room`, which scales a claim *uniformly* and so trimmed the **gas**
  figure below what the solve settled, silently breaking the one invariant this stage protects.
  So `Port#max_kg_per_s` does bound a pressure-driven path after all — for liquid only, because
  conductance rates a gas and says nothing about how fast water moves through a pipe.
- **A line with no declared opinion still passes what is in it.** `weights.empty?` used to drop
  liquid outright, and because membership in the pressure regime is *structural* — any
  conductance-bearing path whose ends declare no intent — that quietly applied to most of the
  graph. **It is why the steam engine's cylinder relief valve passed water in exactly zero
  states**: lifted, its conductance made the path pressure-driven and the cylinder declares no
  affinity for `:relief`; shut, its throughput was zero. Liquid now falls to the same
  proportional rate term solids take, which is the honest default — a flooded line flows as a
  liquid, not as steam's passenger.

> `Flow#requested_kg` is the **gas-only** figure while `granted_kg` sums every parcel, so
> `granted > requested` is normal on these paths and `rejected_kg` can read 0 while liquid was in
> fact short. Anything reading back-pressure off those two (`Tick#carry_through`) is reading the
> gas story only.

`spec/reactor_sim/entrainment_spec.rb` covers this; it exists because the method had none, which
is exactly how the relief valve shipped broken.

### 2. `scale_by_source_availability`

Several paths drawing on one node compete for its contents, per resource. Oversubscription
splits **proportionally to request**.

### 3. `cap_gas_by_pressure`

No path may deliver more gas in one tick than would bring the destination up to the pressure
of its own source.

> **Gas cannot be limited by volume** — it expands to fill whatever it is given and raises
> the pressure instead. Without this cap a small vessel over-packs and ends up at higher
> pressure than the thing feeding it.

`Atmosphere` reports `gas_headroom_kg` as `Infinity` and is unaffected — the sky takes
anything. This is a **cap only**; it never blocks flow outright, so a chimney cannot deadlock
waiting for a pressure difference to appear.

> **Both ends of a path are now real holders**, which is the only reason this rule is safe. It
> used to compare against a *conduit's* pressure — a number with no physical meaning, since a
> duct that is momentarily full or momentarily empty reports 0 → 84 kPa with nothing changing.
> Sampled against a destination the delay had put in antiphase, the cap turned a bounded
> oscillation into a locked full/empty orbit. `Cylinder#supplied_by:` used to have to reach
> *past* its own supply duct for exactly this reason; it now points at a steam chest, which is
> a real holder directly linked to it, so the reach is gone and the declaration is ordinary.
>
> This stage is **scheduled for deletion**. `gas_headroom_kg` is identically
> `(V_free·M/RT) × ΔP` — the relaxation transfer without its time constant — so it is an
> instantaneous equaliser where it should be a rate. See
> [`../design_sketches/transport_model.md`](../design_sketches/transport_model.md).
>
> **It is also applied to claims it has no business capping**, and that is the sharper reason
> to be rid of it. `gas_coupling` refuses to pressure-settle a path whose destination declared
> a draw, on the correct grounds that *"a node that asks for a specific amount — a cylinder
> filling its charge — is making a positive-displacement claim, not riding a gradient."* This
> stage then caps that same claim against a gradient anyway. A piston genuinely does draw its
> cylinder below chest pressure — that is what wire-drawing at the port is — and a displacement
> claim is already self-bounding, since geometry × supply density cannot exceed what the source
> holds. Until the stage goes, **a positive-displacement node's intake is limited by a rule
> that does not describe it**, and whether that rule bites depends on the temperature
> difference between the two ends rather than on anything physical.

### 4. `scale_by_sink_room`

Volume is the currency, because that is what a vessel actually runs out of. **Only condensed
phases are charged for volume** — `volume_of` skips gases, matching `Holds#room_m3`.

> These two rules must agree. Fixing one without the other made a damper deliver 1.2 kg of
> air a tick when the grate wanted seven.

### Result

```ruby
Flow(path:, parcels:, requested_kg:, reversed:)
  #.granted_kg, #.rejected_kg
  #.source_node, #.source_port, #.sink_node, #.sink_port, #.conduits
```

**Ask a flow for its ends by role, never by name.** A path has a nominal direction but gas may
run the other way down it, so `reversed` is the only place the distinction lives and
everything downstream reads `source_node` / `sink_node`. Backflow used to be structurally
impossible — `moles_to_kg` discarded negatives before anything could act on them, which made
the `one_way:` flag unreachable dead code and meant a single overshoot latched forever.

Energy follows mass proportionally when parcels are extracted, which is exact because a
node's contents are all at one temperature.

---

## Heat and rotation: `settle_heat`, `settle_drive`

Both delegate to `Physics::Relaxation` — and so does gas, because the mathematics is
identical for all three:

|  | capacity | potential | conductance |
|---|---|---|---|
| heat | heat capacity (J/K) | temperature (K) | W/K |
| rotation | moment of inertia (kg·m²) | angular velocity (rad/s) | N·m·s/rad |
| gas | `dn/dP = V_free/(R·T)` (mol/Pa) | pressure (Pa) | mol/(Pa·s) |

**The whole network is solved at once, implicitly.** Each body stores `q = c·p` and each
coupling carries `k·Δp`, which over a step is one linear system:

```
(C/dt + K) · p′ = (C/dt) · p + b      K = the conductance Laplacian
                                      b = the head terms
transfer_ab     = k · (p′ₐ + head − p′_b) · dt
```

Solved per connected component by Gaussian elimination — the matrix is symmetric and
diagonally dominant, so no pivoting is needed and the arithmetic cannot depend on row order.

**Unconditionally stable at any `dt`.** Backward Euler is L-stable: every eigenvalue of the
step operator is in (0, 1] however stiff the network, so nothing overshoots and nothing
rings. Explicit Euler returns negative Kelvin at `dt = 100 s`; this converges cleanly at
`dt = 10⁶`. That is what makes `time_scale` a safe dial rather than a hazard.

It is first order rather than exact, so a coupling closes `x/(1+x)` of the gap in a step
where the true exponential closes `1 − e⁻ˣ`, for `x = dt/τ`. Both reach the same equilibrium
and neither can pass it.

### Why it is a network solve and not a pairwise one

Two failures, and the second is the expensive one.

**A pairwise closed form does not compose.** Each link independently moves most of the way to
*its own* two-body equilibrium and the contributions stack: three 600 K bodies feeding one
small 300 K body drove it to **1067 K**. Energy was conserved perfectly — the node was simply
hotter than anything touching it.

**And it cannot express flow THROUGH a body**, which is what a firebox with a damper at one
end and a chimney at the other is. A pairwise law caps a transfer at what would equalise the
pair, and a through-flow has nothing to do with that. So mass used the linear law `k·ΔP·dt`
instead — which is explicit Euler, stable only while `dt < τ` — with a per-node bound
standing in for stability. **Every gas coupling in the steam engine ran 400–600× past that
limit**, and the bound was itself wrong: it capped a sender at the amount that would bring it
to the receiver's *current* potential, ignoring that the receiver rises as it fills. For two
equal bodies that overshoots by exactly 2× and swaps them.

> Measured, on two 2 m³ vessels holding 6 kg and 1 kg of air joined by one pipe: at
> `k = 0.001` (dt/τ = 0.6) both settled correctly to 147 287 Pa; at `k ≥ 0.01` they **swapped
> contents on tick 1 and stayed swapped forever**. The engine survived only because every gas
> coupling in it has `Atmosphere` on one end, whose capacity is ~10⁸× a vessel's, so the
> receiver never rose and the 2× error vanished. In the firebox the damage appeared instead
> as a relaxation oscillation — the flue asked for 1972 mol and the bound granted 1.8, the
> fire's heat output swung by a factor of 5.9 every few ticks, and doubling the draught
> conductance *cut engine power to a fifth*.

Solving the network implicitly fixes both at once, and the per-node bound, `flow_bounds` and
`node_headroom` were all deleted rather than corrected.

### Limits: direction, and nothing else

`Relaxation.settle` takes an optional `{ link_id => [low, high] }`. A check valve is
`[0, ∞]`. Limits are **constraints inside the solve** — a breached coupling is pinned to its
bound and the network re-solved, so every other flow settles against the transfer that
actually crossed. Clamping afterwards is wrong: capping the flue after the fact let the
firebox be pumped to 25 kPa, because the damper had been solved against an exhaust four times
larger than the one allowed to cross.

A pinned coupling may be **released once**, and that is not optional either. Pinning the flue
at a throat it had outgrown drove the firebox pressure down — which is the state in which it
would no longer be choked — and with no way back it kept extracting a fixed amount from a box
the damper could not fill. Measured: an 80 kPa vacuum in a firebox open to the sky.

> **`Port#max_kg_per_s` does not restrict a pressure-driven path — conductance is the whole
> restriction.** Applying both was tried and is wrong: the damper's rating (4 kg/s) and its
> conductance (2.0 mol/Pa·s) describe restrictions differing about fourfold, so the throat was
> choked at essentially every pressure the firebox could reach, and a permanently choked
> coupling carries a *fixed* flow — leaving the pressure at either end with no feedback at
> all. A real orifice does choke, but on a pressure ratio near 2:1, which furnace draught
> never approaches.

### What each conserves

- **Heat:** energy exactly. What one body loses the other gains, to the bit.
- **Rotation:** *momentum* exactly. Kinetic energy is **not** conserved, and should not be —
  a slipping coupling loses energy. `Tick#drive` measures the difference before and after
  and writes it to `joules_to_friction`.

### Ambient: `settle_ambient`

Each thermal node relaxes toward a fixed reservoir via `Relaxation.to_reservoir`. Not
arbitrated — a fixed-potential sink cannot be overshot. This is what stops a long chain being
a perfect heat accumulator.

---

## The ledger

`Physics::Ledger` — a hash of named floats living inside operation state, snapshotted every
tick. The policy is **lossy is fine, silent is not**: approximate freely, but everything
crossing the boundary is declared.

| Key | Direction | Meaning |
|---|---|---|
| `joules_added` | in | Burners, heaters, fission |
| `joules_from_reactions` | in | Chemical energy released by combustion etc. |
| `mass_added` | in | Feedstock arriving from outside |
| `joules_to_ambient` | out | Waste heat through the walls |
| `joules_to_friction` | out | Bearing drag, belt slip |
| `joules_to_work` | out | Useful shaft work delivered |
| `joules_advected_out` | out | Energy carried out with departing mass |
| `mass_vented` | out | Deliberate discharge |
| `mass_spilled` | out | Overflow, leak, failure. **Reserved — nothing writes it yet.** |

The hash also carries `ambient_k` — the environment's temperature, config rather than a flow.
It is what `settle_ambient` relaxes toward.

```ruby
Ledger.mass_balance(op.total_mass, op.ledger)     # constant
Ledger.energy_balance(op.total_joules, op.ledger) # constant
```

`mass_spilled` is unused on purpose rather than by omission: the arbiter scales a flow down
when a sink has no room, so the material simply stays with the sender. Nothing overflows by
construction. The line exists for a future node that models a genuine leak.

### `joules_from_reactions` is separate on purpose

Parcel enthalpy does **not** carry chemical bond energy, so a fire is genuinely an energy
source as far as this model is concerned. Declaring it keeps the books checkable without
pretending we track bonds. Folding it into `joules_added` would hide the distinction.

### How a node reports a crossing

A node **cannot** write the ledger directly — that would be a cross-node effect during
evaluation. Instead it records the amount in its own state, and `Tick#record_injections`
sums those into the ledger after phase 5:

| State key a node sets | Ledger line |
|---|---|
| `joules_injected` | `joules_added` |
| `joules_from_reactions` | `joules_from_reactions` (set by `run_reactions`) |
| `joules_extracted` | `joules_to_work` |
| `joules_discarded` | `joules_advected_out` |
| `mass_injected` | `mass_added` |
| `mass_vented` | `mass_vented` |

`Nodes::Vessel` (heater), `Nodes::Load` (work) and `Nodes::Atmosphere` (boundary crossings)
are the examples to copy.

> **Report gross crossings, never a before/after delta.** A delta is the NET of everything
> that happened in the tick, and at a boundary the two directions cancel: `Atmosphere` used to
> derive its lines this way, and 68.06 kg of air drawn in against 103.12 kg of flue gas pushed
> out was booked as `mass_added` **0.00**, `mass_vented` 35.06. Every conservation spec passed
> throughout — the net is exactly what they constrain — while nothing built on the ledger
> could measure anything. Read `grant.sent` and `grant.received`, which are gross and carry
> their own enthalpy.

### Total energy includes rotation

`Operation#total_joules` sums thermal energy, parcel energy **and** rotational kinetic
energy. A spinning flywheel holds real energy; leaving it out would make every acceleration
read as drift.

---

## Debugging a conservation failure

Both bugs found this way, both invisible by inspection:

1. Step the operation one tick at a time, recording
   `Ledger.energy_balance(op.total_joules, op.ledger)` before and after.
2. Any tick where the balance moves by more than float noise is the culprit.
3. Diff **per-node** energy (`state[:joules] + Parcel.total_joules(state[:parcels])`) across
   that tick, alongside the ledger deltas, to see which node gained or lost unaccounted.

Watch for: a node with a huge `heat_capacity` absorbing energy in its structure that nothing
resets; and reactions, which conserve *enthalpy* rather than temperature — see
[`physics.md`](physics.md#reactions).
