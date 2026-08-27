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
Arbiter.settle(nodes:, states:, links:, thermal_links:, drive_links:, intents:, content:, dt:)
#=> Settlement(flows:, heat:, ambient:, drive:)
```

Nothing in here reads a clock, draws entropy, or depends on hash order.

---

## Mass: `settle_mass`

Four stages, in order. Each may only *reduce* a claim.

### 1. Desired flow per link

```ruby
sink_declared_a_draw? ? sink.draw(port) : source.push(port)
```
then capped by `min(out_port.capacity_kg(dt), in_port.capacity_kg(dt))`.

> **An active sink is authoritative about its own intake.** This used to be
> `max(push, draw)`, which meant a sink could not refuse — a valve shoving its contents at a
> cylinder overrode the cylinder's own careful limit and packed it to eight times its supply
> pressure. A node that declares a draw gets exactly that; a passive tank declares nothing
> and still accepts whatever arrives, which is what makes pump-into-tank work.

Material must satisfy **both** ports' tag filters. A gas outlet wired to a liquid inlet moves
nothing — a wiring mistake the graph is allowed to make.

The desired mass is then split across the resources actually present, proportional to what is
there, so a drawn mixture has the same composition as the mixture it left behind.

### 2. `scale_by_source_availability`

Several links drawing on one node compete for its contents, per resource. Oversubscription
splits **proportionally to request**.

### 3. `cap_gas_by_pressure`

No link may deliver more gas in one tick than would bring the destination up to the pressure
of its own source.

> **Gas cannot be limited by volume** — it expands to fill whatever it is given and raises
> the pressure instead. Without this cap a small vessel over-packs and ends up at higher
> pressure than the thing feeding it.

Nodes that report `gas_headroom_kg` as `Infinity` are unaffected: `Atmosphere` (the sky takes
anything) and `Conduit` (a duct is limited by flow rate, not containment). This is a **cap
only** — it never blocks flow outright, so a chimney cannot deadlock waiting for a pressure
difference to appear.

### 4. `scale_by_sink_room`

Volume is the currency, because that is what a vessel actually runs out of. **Only condensed
phases are charged for volume** — `volume_of` skips gases, matching `Holds#room_m3`.

> These two rules must agree. Fixing one without the other made a damper deliver 1.2 kg of
> air a tick when the grate wanted seven.

### Result

```ruby
Flow(link:, parcels:, requested_kg:)
  #.granted_kg, #.rejected_kg
```

Energy follows mass proportionally when parcels are extracted, which is exact because a
node's contents are all at one temperature.

---

## Heat and rotation: `settle_heat`, `settle_drive`

Both delegate to `Physics::Relaxation`, because the mathematics is identical:

|  | capacity | potential |
|---|---|---|
| heat | heat capacity (J/K) | temperature (K) |
| rotation | moment of inertia (kg·m²) | angular velocity (rad/s) |

```
equilibrium = (c₁p₁ + c₂p₂) / (c₁ + c₂)
τ           = 1 / (k · (1/c₁ + 1/c₂))
transfer    = c₁ · (p₁ − equilibrium) · (1 − e^(−dt/τ))
```

**Unconditionally stable at any `dt`.** The exponential factor is in (0, 1) for every
timestep, so a link can never overshoot equilibrium. Explicit Euler returns negative Kelvin
at `dt = 100 s`; this converges cleanly at `dt = 10⁶`. That is what makes `time_scale` a
safe dial rather than a hazard — **never replace these with Euler.**

### The per-node bound is not optional

Pairwise closed form alone is not enough in a network. Each link independently moves most of
the way to *its own* two-body equilibrium and the contributions stack: three 600 K bodies
feeding one small 300 K body drove it to **1067 K**. Energy was conserved perfectly — the
node was simply hotter than anything touching it.

So totals are capped at the point where a node would pass the conductance-weighted mean of
its own neighbours, and whatever is not granted stays with the sender.

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
