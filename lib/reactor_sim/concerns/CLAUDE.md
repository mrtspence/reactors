# `concerns/` — composable state + behaviour a node opts into

Each concern contributes a **state fragment** merged by `Node#initial_state`, plus methods
over it. A node that includes nothing carries nothing — an indicator lamp should not have a
specific heat. Reference:
[`docs/reference/nodes.md`](../../../docs/reference/nodes.md#concerns).

| Concern | Config (as reader methods) | State it adds | Key methods |
|---|---|---|---|
| `Thermal` | `heat_capacity`, `ambient_conductance`, `ambient_k`, `initial_temperature_k`; optional `material`, `max_temperature_k`, `emissivity`, `radiating_area_m2` | `joules` | `temperature_k`, `add_joules`, `rebalance`, `total_heat_capacity`, `rated_temperature_k`, `radiative_conductance` |
| `Holds` | `volume_m3` | `parcels` | `contents_kg`, `room_m3`, `contents_volume`, `bulk_density_kg_m3` |
| `Wearing` | `durability_range`, `stress_per_second`, `overload?`, `failure_modes`, `failure_mode`, `failure_damages` | `durability`, `initial_durability`, `failure` | `apply_wear`, `integrity`, `break_part`, `escalate_to`, `derating` |
| `Pressurized` | needs `Holds` + `Thermal`; optional `material`, `shell_radius_m`, `wall_thickness_m`, `safety_factor`, `max_pressure_pa` | none — derived | `pressure_pa`, `gas_headroom_kg`, `rated_pressure_pa` |
| `Obstructs` | `obstruction_volume_m3`, `obstruction_tags` (needs `Holds`) | none — derived | `occupancy`, `obstructing_volume_m3` |
| `Rotating` | `moment_of_inertia`, `radius_m`, `friction`, `initial_omega` | `angular_momentum` | `omega`, `rpm`, `kinetic_joules`, `apply_torque`, `drag_conductances` |
| `Fusible` | `fusible_kg`; needs `Thermal` and a `material:` declaring `latent_heat_of_fusion_j_per_kg` | `fusible_remaining_kg` | `run_melt`, `melt_kg`, `melted_fraction`, `melted_out?`, `fusible_temperature_k` |

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

### Radiation, which is a conductance rather than a special case

`emissivity` and `radiating_area_m2` add a radiant path alongside conduction. Both default to
zero, so a node that has not been given a surface is **bit-identical** to one from before
radiation existed — that is what let the feature land without touching anything.

It works because `T⁴ − T_amb⁴` factors *exactly* into `(T² + T_amb²)(T + T_amb)·(T − T_amb)`, so
`radiative_conductance` returns real W/K and radiation is summed with `ambient_conductance` before
the existing closed form runs. An explicit `T⁴` would be the one integrator this library forbids.

- **Emissivity is the part's, not the material's**, the same call `safety_factor` makes. What
  separates oxidised iron from polished steel is a wire brush, not a different metal.
- **`ThermalLink` takes the same two keys** for body-to-body exchange, and `settle_heat`
  recomputes that conductance every tick from both end temperatures.
- **`settle_ambient` guards on the TOTAL conductance**, not on `ambient_conductance` — guarding on
  conduction alone skips everything that radiates and barely conducts, which is most hot things in
  a machine.

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

Not modelled: hydrostatic pressure, flow-induced pressure drop. **Pump and fan head are modelled
and are no longer free** — a `Conduit` naming a shaft with `driven_by:` is billed
`(head_pa + ρ·g·lift_m)·Q ÷ efficiency` as a drag conductance. Depth is therefore a torque bill
rather than a pressure gradient.

### What the shell can stand comes from the shell

`rated_pressure_pa(content)` derives the damage threshold by hoop stress — `σ = p·r/t`, so
`p = σ·t/r·safety_factor` — from the part's `material:`, `shell_radius_m:` and
`wall_thickness_m:`. Same shape as `Flywheel#burst_speed_m_s`, and for the same reason: a
vessel's strength is what it is built from and how thick it is, not a number somebody picks.

> **It was `relief_pa × 1.5` on the steam engine, and that is circular.** What a boiler survives
> cannot depend on where its safety valve was set — and it made the two inseparable, so the gap
> between blowing off and bursting could never be deliberately changed.

`safety_factor` is the **part's**, not the metal's, exactly as on the flywheel: how far below the
plate figure a real vessel fails depends on its seams. An explicit `max_pressure_pa:` still wins.

## Obstructs: the deposit is in the way, not merely taking up room

`Holds#room_m3` and `Pressurized#free_volume` both already charge condensed phases for volume,
and between them that gives occupancy two consequences — less room to accept, higher pressure
for the gas that is left. **Neither says a deposit is obstructing anything**, and water in a
cylinder, ash on a grate and scale in a tube are all that missing third consequence.

**Measure against the characteristic volume, never the node's.** The 14 kg of water that
destroys the steam engine's cylinder is 7% of its volume and 100% of its clearance space; a
firebox is choked by ash filling the gaps between the fuel, not by filling six cubic metres.
Getting the denominator wrong makes the hazard invisible rather than merely mis-scaled.

This concern gives you `occupancy` and stops. **What it means is the node's business**, because
it genuinely differs — a cylinder derives a compression pressure from it, a bed throttles its
reactions, and a vessel does nothing at all. `obstruction_tags` is part of the mechanism too:
tag `:solid` on a firebox and the *fuel* becomes an obstruction alongside the ash.

Needs `Holds`, and that is a real constraint: **a conduit cannot foul**, because it holds
nothing by design. Put the deposit in a holder and the restriction on a conduit beside it.

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
Override `failure_detail(state, ctx)` to describe it.

> **There is no `failure_type` hook, and there must not be one.** Every part failure is
> `type: :part_failed`; the part identifies itself through `node`, `mode` and `failure_detail`.
> A per-part type derived from the node id makes a rename silently rename an event type, and no
> list of types can exist at all; a per-class override is a worse copy of `mode:`, and any class
> that forgets to override collapses two distinct failures into one type. One vocabulary, in
> `failure_modes`. See `ReactorSim::Event::TYPES`.

The rolled starting durability is hidden from the player — that is where the uncertainty
lives, rather than in the system being arbitrary.

### `failure` is a mode, not a boolean

State carries `failure: nil | <mode symbol>`, and `Node#broken?` derives from it — so a node
that never included `Wearing` answers false without carrying a key it has no use for, which
`Arbiter.settle_drive` relies on when it checks both ends of a link to a `Load`.

**"Broken" cannot distinguish a seam weeping steam from a drum letting go**, and that is the
only interesting axis a failure has. Two methods carry it:

- `failure_modes` — the modes this part can enter, **in ascending severity**, as a plain hash
  whose values are the consequences each carries. The order is the hash's own insertion order,
  so the escalation ordering needs no second declaration to disagree with the first. *Nothing
  consumes the values yet* — they are staged in
  [`failure_model.md`](../../../docs/design_sketches/failure_model.md) §8.
- `failure_mode(state, ctx, cause)` — what it became, from the conditions at that instant.
  **Not derivable from `cause`**, and `Nodes::Boiler` is why: over-pressure and a dry crown
  sheet both end as a hole in the shell, and what separates a split from an explosion is how
  much pressure was behind the metal. `Nodes::Cylinder` is the case where the cause *does*
  separate them cleanly, which is why both hooks exist.

`break_part` is the one place a failure changes — sound → failed **and** failed → worse — so
naming the mode stays a single decision. It emits an event only on a transition.

### A broken part keeps being evaluated, and can get worse

`apply_wear` must not return early on a failed node, however much it looks like an optimisation:
**an early, mild failure must never immunise a part against a catastrophic one.** A cracked pipe
that goes on being fed should be able to tear open; a reactor that has lost a seal must still be
able to melt down. Returning early makes the first failure a part suffers the last thing that can
ever happen to it — a *safe harbour* on exactly the machines where that is most wrong.

- **Fatigue cannot escalate; overload can.** Durability is spent once a part has failed, so
  `stress_per_second` has nothing left to consume. That is the right story anyway: a split drum
  that keeps being fired reaches bursting conditions; one that has been shut down does not.
- **`escalate_to` only moves forward.** Otherwise a drum that has exploded is re-described as
  merely split the moment its own hole takes the pressure away — the conditions that destroyed
  it are gone precisely *because* it was destroyed.
- A mode the table does not name sorts last, rather than being discarded quietly.

**`Nodes::Cylinder` is the part that actually escalates**, and the shape is worth copying: its
`overload?` is hydraulic lock, which is *condition*-driven rather than durability-driven, so it
still fires on a part whose durability is long gone. A cylinder worn to `scored_bore` that then
takes a slug of water blows its head off, and the event carries `escalated_from:`. A part whose
only failure route is fatigue can never escalate, by construction.

The **boiler** deliberately cannot, and that is physics rather than an omission: a split drum
loses pressure through its own hole, so the severity that would name a worse mode is falling
exactly when it would be re-read. The hole is the relief.

### What a mode actually does

Three consumers, and where each declaration lives is the line between what a class knows about
itself and what only the machine knows:

- **`Nodes::Breach`** reads the mode to size the hole a failed holder spills through. Sizes live
  on the breach (`opens_by:`), not in the mode table, so **a mode a breach does not name opens
  nothing** — which is how one part carries several holes of different sizes, and how a
  cylinder's `scored_bore` correctly opens none at all (worn rings leak *past the piston*, inside
  the machine).
- **`derates:`** in the mode table, read by the node's own code via `derating(state, key)`. What
  a derating means is the node's business. `0.0` is how a mode says "no longer does that thing at
  all", in the same vocabulary rather than a second flag beside it.
- **`failure_damages`** — `{ mode => { node_id => share } }` — is what the part takes with it,
  spent by `Tick#spread_damage` as a share of each bystander's *starting* durability.

**`failure_hazards` is `failure_damages` pointed at people**, declared the same way and for the
same reason, and spent in phase 6b immediately after `spread_damage`. It names **stations**, never
minions: a station is fixed by the machine and a roster is the player's, so a part naming a minion
would be naming something it cannot know. That also makes it a coarse notion of *place* with no
geometry at all — the machine knows which levers sit beside which parts — and it upgrades cleanly
when volumes arrive. A station's figure is a **weight**; `scales_with:` names a key in the failure
event's own `detail:` so the size of the event comes from the part rather than from a constant.

**`failure_damages` is deliberately not an entry in `failure_modes`**, and the reason is the
rule that everything under `nodes/` is generic: `Nodes::Boiler` cannot name a `:cylinder`,
because a boiler in another machine has none near it. Which modes exist belongs to the class;
who is standing next to it belongs to the machine, so it is configured per instance
(`Vessel.new(damages: …)`).

It is spent **on the transition only** — otherwise a failed part grinds its neighbours down at
the tick rate — and **after** all wear is settled rather than inside the map, so two parts
failing together and damaging each other give the same answer whatever order they are visited
in. Phase 6 obeys order-independence like everything else.

Everything else a failure does is still generic (a part that has let go stops turning, leaves
the drivetrain, drives nothing), so **a part with no breach, no derating and no casualties fails
without visible consequence unless it spins.** `failure_spec` walks every catalogued machine and
also checks the inverse — that no breach is wired to a mode its part can never enter, which
would leave a hole inert and indistinguishable from a part meant to fail sealed.

> **The mode is a Symbol held as a VALUE, so JSON hands it back as a String** — the fifth
> instance of that trap here. `Operation#restore` normalises it. The failure is *partial*, which
> is what makes it nasty: `broken?` is truthy either way, so the part stays broken in a mode
> nothing matches. **The digest cannot catch it** — `canonical` goes through `JSON.generate`,
> where `:explosion` and `"explosion"` are the same string. Only an identity assertion finds it;
> `spec/reactor_sim/failure_spec.rb` has one.

## Fusible: a part made of something with a melting point

Energy that would take the part past its melting point melts its substance instead, and the melt
runs out carrying that energy — the same trick `Resources::Saturation` uses for the boiling
plateau. `Nodes::Bearing` loses its white metal; `Nodes::FusiblePlug` **is** this concern rather
than a threshold latch, so a plug's melting point is its alloy's rather than a configured number
that could disagree with it.

Three rules, each of which is a bug if broken:

- **Latent heat only, and mass is NOT booked.** A part's substance is its `heat_capacity`, and
  structure mass has never been part of `Operation#total_mass` — only parcels are. Reporting
  `mass_consumed` for melted metal declares mass leaving that was never counted as present, and
  every conservation spec fails with the ledger blaming the wrong thing. The energy *is* tracked,
  so that is what leaves, through `joules_discarded`.
- **The melt is bounded by the energy the part actually holds.** A part melted by somebody
  else's heat — a plug reads the crown sheet, not itself — would otherwise spend joules it does
  not have and go below absolute zero.
- **No latent heat declared means it does not melt**, because `Content` returns `Float::INFINITY`.
  Zero would mean the opposite and vaporise a part's whole substance in one tick.

> **It does not cap a runaway temperature, and the bearings sketch expected it to.** A phase change
> caps a temperature only when heat arrives *slower* than the latent heat can absorb it. That is
> true of a plug warmed through a crown sheet and false of a bearing absorbing a flywheel: 6 kg of
> babbitt took 31 K off the spike of a seizure and nothing off the 1652 K equilibrium. What bounds
> that is radiation, which is a change to `settle_ambient`.

## Rotating

Stores `angular_momentum`; `omega`, `rpm`, `kinetic_joules` and `rim_speed` all derive.
`rim_speed` (ω × radius) is what actually tears a spinning mass apart.

Coupling is a `DriveLink`, settled by the same relaxation as heat. `stiffness` is how hard the
ends are held to a common speed — a keyed shaft is stiff, a leather belt is not, and the
difference is one number rather than one class.

### Drag is declared, never applied

`drag_conductances(state, ctx)` returns what pulls this body toward rest, in N·m·s/rad, keyed by
where the energy it removes belongs — `:friction` for windage, `:work` for a load's brake, and **a
node id to heat that node**, which is how a bearing cooks itself. `Arbiter.settle_drive` gathers
them and `Relaxation.settle` puts them on the diagonal, so a drag is solved **inside** the
drivetrain network rather than after it.

> **Whether a broken part still drags is the part's own answer, not the arbiter's.** `drive_drags`
> skips a drag whose *shaft* has failed — that body has left the drivetrain and `Tick#stress` has
> taken its momentum — but it asks every declarer regardless of the declarer's own state.
> `Rotating` declines for itself when broken; `Nodes::Bearing` does the opposite and drags
> **harder**, which is the only mechanism by which a seizure stops anything. Filtering failed
> declarers centrally reads as tidy and silently disables that.

> **Applying a drag after the coupling is operator splitting, and it dominates once the drag is
> stiff.** Each half can be integrated exactly and the composition is still first order in `dt`:
> a fan-law mill whose brake time constant is 0.18 s against a 250 ms tick settled at 8.5 rad/s
> against a true equilibrium of 19.6, and the coupling above it then slipped 65% and burned 39%
> of shaft power. Halving `dt` halved the gap, which is the signature. A nonlinear brake is
> linearised as `τ(ω)/ω` at the tick's speed — a far smaller error than the split it replaces —
> and capped at `I/dt`, which **halves a body per tick and no more**. That cap bounds how far the
> linearisation is trusted; it is not a stop, and a drag meaning "this has locked" declares a
> large multiple of it.

**Kinetic energy is quadratic, so no intermediate state between two settled ticks means
anything.** `Tick#drive` measures the total energy lost and *estimates* only the split, at the
speeds the network settled to: a drag did `momentum × ω`, a coupling dissipated
`transferred × Δω`. Measuring the halves separately instead charges each for a state the machine
was never in — it inflated a mill's output past its own engine's and drove `joules_to_friction`
negative while the totals still balanced.
