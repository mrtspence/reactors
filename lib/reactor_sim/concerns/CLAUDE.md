# `concerns/` — composable state + behaviour a node opts into

Each concern contributes a **state fragment** merged by `Node#initial_state`, plus methods
over it. A node that includes nothing carries nothing — an indicator lamp should not have a
specific heat. Reference:
[`docs/reference/nodes.md`](../../../docs/reference/nodes.md#concerns).

| Concern | Config (as reader methods) | State it adds | Key methods |
|---|---|---|---|
| `Thermal` | `heat_capacity`, `ambient_conductance`, `ambient_k`, `initial_temperature_k` | `joules` | `temperature_k`, `add_joules`, `rebalance`, `total_heat_capacity` |
| `Holds` | `volume_m3` | `parcels` | `contents_kg`, `room_m3`, `contents_volume` |
| `Wearing` | `durability_range`, `stress_per_second`, `overload?` | `durability`, `initial_durability`, `broken` | `apply_wear`, `integrity` |
| `Pressurized` | needs `Holds` + `Thermal` | none — derived | `pressure_pa`, `gas_headroom_kg` |
| `Rotating` | `moment_of_inertia`, `radius_m`, `friction`, `initial_omega` | `angular_momentum` | `omega`, `rpm`, `kinetic_joules`, `apply_torque` |

A snapshot — `ls lib/reactor_sim/concerns/` is the truth. This table drifts on a **column**, not
just a row: adding a config key or a state key to an existing concern makes it wrong just as
surely as adding a concern does. **Update it and the matching table in
[`docs/reference/nodes.md`](../../../docs/reference/nodes.md) in the same commit** — a node
author reads these to find out what config a concern demands, and a missing key surfaces as a
`NoMethodError` deep in a tick.

**Config is supplied as reader methods, not ivars.** `def volume_m3` or
`attr_reader :volume_m3` — concerns call them. Setting `@volume_m3` without a reader silently
does nothing.

## Thermal: one node, one temperature

A node's structure and its contents are **one lumped body at a single temperature**:

```
T = (joules + Σ parcel.joules − Σ formation) / (heat_capacity + Σ parcel heat capacity)
```

That approximation is what makes advection exactly correct — a parcel leaving carries
precisely the energy its temperature implies. **Things that need genuinely distinct
temperatures are distinct nodes.** It also means a node has no local hot spot, which is why
a reaction's `min_temperature_k` means "bulk temperature at which this sustains", not ignition.

`rebalance` restores the single-temperature invariant after the mix changes. `add_joules`
calls it; the engine calls it after advection, reactions and phase change. You rarely need to.

Every `Thermal` node in an operation needs an `ambient_conductance`, or the operation becomes
a perfect heat accumulator.

## Pressurized: derived only

Ideal gas over whatever volume the liquids are not occupying:

```
free = max(volume − liquid_volume, volume × 0.001)
P    = Σ(gas moles) × R × T / free
```

- **An empty vessel reports 0 Pa — a vacuum, not one atmosphere.** Reporting 101 kPa for a
  node holding nothing meant a low-pressure source could never fill a receiver. *If a node
  should contain air, give it air.*
- **Gases are not limited by volume.** `Holds#room_m3` counts only condensed phases;
  `gas_headroom_kg` supplies the pressure limit instead. These two **must agree** with
  `Arbiter#volume_of` — fixing one alone throttles every duct.

Not modelled: pump head, hydrostatic pressure, flow-induced pressure drop.

## Wearing: fatigue vs overload

**Incidents are never a per-tick dice roll.** Stress accumulates deterministically from
operating conditions, so a player can learn "I ran it too hot for too long" rather than being
told the dice disliked them. Durability is a *depleting* resource rather than accumulating
wear, because a depleting quantity can be shown through bands and prose without ever revealing
a number.

- `stress_per_second(state, ctx)` — durability units consumed per second. Gradual. The right
  default for most failures.
- `overload?(state, ctx, integrity)` — immediate failure this tick, bypassing durability. For
  brittle things that do not deteriorate but simply let go past a limit.

`integrity` (0..1) is passed to `overload?` so a worn part fails sooner than a fresh one,
keeping accumulated history meaningful. Events carry `cause: :fatigue` or `cause: :overload`.
Override `failure_type` and `failure_detail(state, ctx)` to describe it.

The rolled starting durability is hidden from the player — that is where the uncertainty
lives, rather than in the system being arbitrary.

## Rotating

Stores `angular_momentum`; `omega`, `rpm`, `kinetic_joules` and `rim_speed` all derive.
`rim_speed` (ω × radius) is what actually tears a spinning mass apart. `friction_loss` relaxes
toward rest in closed form, so a wheel coasts to a stop and never through it into running
backwards.

Coupling is a `DriveLink`, settled by the same relaxation as heat. `stiffness` is how hard the
ends are held to a common speed — a keyed shaft is stiff, a leather belt is not, and the
difference is one number rather than one class.
