# Reactor — Simulation Architecture

How an Operation is modelled, evaluated, and observed. This document defines the
simulation paradigm; [architecture.md](architecture.md) defines the systems around it
(process topology, Kafka, realtime protocol, persistence), and remains correct as written
except where noted below.

**Supersedes** [architecture.md §4](architecture.md) (Simulation model) in full.
**Amends** §5 (adds resource content data) and §11 (adds five invariant specs).
**Unaffected:** §1–3, §6–10, §12.

Origin: the trace in [mechanism_pipeline_thoughts.md](mechanism_pipeline_thoughts.md),
the counter-proposal at the bottom of it, and the review in
[architecture_proposal_review.md](architecture_proposal_review.md).

---

## 1. What this paradigm is for

The v0 sim worked but had a shape problem: `Buffer` carried four unrelated jobs, delay was
configured in three places that stacked invisibly, and every mechanism had to re-implement
its own physics. That road ends with a hundred bespoke monoliths and no way to swap parts.

The design goal is **complexity absorbed by shared abstractions, not by mechanisms.** A
player should be able to swap a pipe for a wider one, or a coolant for a different fluid,
and have it mean something — which requires compatibility and physics to be *declarative*.

Five decisions frame everything below:

| Decision | Rationale |
|---|---|
| **Closed loops are first-class** | Recirculation, condensate return, backup lines. Rules out topological resolution ([review §1](architecture_proposal_review.md)). |
| **Time compression is a tunable dial** | A mining operation isn't interesting until the first ore lands. Sim-time is decoupled from wall-clock. |
| **Approximation is welcome; silence is not** | Any mass or energy leaving the system is *declared in a ledger*, never dropped. |
| **~100 nodes is the upper bound** | RBMK-scale, modelled as clusters, not channels. Budgeted in §9. |
| **Only interesting joins are nodes** | A join earns a node by having a control point, a failure mode, or a flow restriction. A weld is an edge. |

Four invariants from v0 are **load-bearing and non-negotiable**. Everything here is
designed around keeping them:

1. **Purity** — no clock, no ambient entropy, no Rails inside `lib/reactor_sim`.
2. **Determinism** — seed + command log reproduces a match exactly.
3. **Order-independence** — evaluation order cannot affect the result.
4. **Command idempotence** — commands carry absolute values; redelivery is a no-op.

---

## 2. Units

SI internally, without exception. Conversion happens in `Displays`, at the very edge.

| Quantity | Unit | Notes |
|---|---|---|
| Mass | kg | |
| Energy | J | **stored**; temperature is derived |
| Temperature | K | never stored — `joules / heat_capacity` |
| Pressure | Pa | never stored — derived from contents, volume, temperature |
| Time | s | simulated seconds |
| Volume | m³ | |
| Conductance | W/K | geometry and material lumped into one coefficient |

Two of these are load-bearing rather than stylistic.

**Energy, not temperature, is the stored state.** Mixing two parcels becomes addition
rather than a weighted average, so it conserves energy exactly instead of approximately.
Phase change becomes a subtraction. And conservation becomes checkable, which is the whole
basis of §8.

**Pressure is derived, never accumulated.** The v0 vessel already did this and it was the
best thing about it — a stored pressure drifts away from the state that causes it, and
nothing tells you.

---

## 3. The cast

Nine concepts. Three hold state; the rest are behaviour and config.

| Concept | State? | Role |
|---|---|---|
| **Node** | via concerns | Anything in the graph. `Mechanism` and `Conduit` are both nodes. |
| **Port** | no | A tagged inlet or outlet on a node, with a flow limit. |
| **Link** | no | An edge: one outlet → one inlet. Also, separately, thermal links. |
| **Parcel** | **yes** | `{resource:, kg:, joules:}` — a quantity of a substance with its own energy. |
| **Resource** | no | Pure physics module + YAML data. Owns phase change and chemistry. |
| **Concern** | **yes** | `Thermal`, `Holds`, `Wearing`, `Pressurized`. Composable state+behaviour fragments. |
| **ControlPoint** | **yes** | `{target:, actual:}`. Commands set target; minions move actual. |
| **Minion** | **yes** | Operates a control point or reads a gauge. Source of lag and hijinks. |
| **Diagnostic** | **yes** | `Source → Filters → Display`. |

`Buffer` is gone. Its four jobs are redistributed:

| v0 `Buffer` job | New owner |
|---|---|
| Storage (`contents`/`capacity`) | `Holds` concern on a node |
| Transport delay (`transit`) | **deleted** — emergent from hop count (§5) |
| Throughput limit | `Port#max_kg_per_s` on a `Conduit` |
| Back-pressure (`room`) | Rejection at settlement (§6) |

### Nodes hold no mutable state

Unchanged from v0 and still the most valuable structural rule in the codebase. A node is
configuration and behaviour; all state lives in the Operation's frozen hash and is passed
in. A node physically cannot write to the tick it is reading from.

A node author writes exactly two methods:

```ruby
def plan(state, ctx)         → Intent   # what I want to draw and push
def apply(state, ctx, grant) → state    # what I actually got, and what that does to me
```

Everything else — heat transfer, phase change, wear, failure, observation — is driven by
the concerns the node includes. That is the whole point: **the surface area of a new
mechanism is two methods and some config.**

### Concerns

```ruby
module Concerns
  module Thermal
    # config: heat_capacity (J/K), ambient_conductance (W/K)
    # state:  joules
    def temperature_k(s) = s.fetch(:joules) / heat_capacity
  end

  module Holds
    # config: volume (m³)
    # state:  parcels [{resource:, kg:, joules:}]
  end

  module Wearing
    # config: stress_model
    # state:  durability (seeded, depletes to 0), broken
  end

  module Pressurized
    # derived only — no state. Ideal gas over the free volume, plus liquid displacement.
  end
end

class Conduit < Mechanism
  include Concerns::Thermal, Concerns::Holds, Concerns::Wearing
end

class IndicatorLamp < Mechanism; end   # includes nothing, carries nothing
```

`initial_state` merges the fragments of whichever concerns are included. Deliberately
**not** one composed-in interface: that gives a lamp a specific heat, and it blurs the
config/state split that makes the double buffer enforceable
([review §3](architecture_proposal_review.md)).

**Durability replaces wear.** Same seeded-hidden-threshold model, sign flipped. It is worth
the change because `wear: 0.13` against a *hidden* max of `1.0352` is undisplayable —
you cannot draw a readout when the maximum is a secret — whereas a depleting durability is.
See §7 for how it gets read without becoming a health bar.

---

## 4. Resources: physics as data

A `Resource` is a **pure module plus a YAML record.** It never mutates anything; it takes
a parcel and returns a new one. (The alternative — resources mutating their container —
would cost determinism, snapshot/restore, and replay, for no modelling gain.)

```yaml
# content/resources/water.yml
water:
  tags: [liquid, coolant, moderator]
  specific_heat_j_per_kg_k: 4181
  density_kg_per_m3:        997
  phase:
    model:             saturation      # names a code module
    vapour:            steam
    latent_heat_j_per_kg: 2257000
```

```ruby
module Resources::Saturation
  # pure: parcels in, parcels out. no clock, no entropy, no mutation.
  def self.equilibrate(parcels, pressure_pa:, volume_m3:)
    # => [{resource: :water, kg:, joules:}, {resource: :steam, kg:, joules:}]
  end
end
```

**Data in YAML, physics models in code, tags select which model applies.** Adding a coolant
is a file. Adding a new *kind* of physics is a module. This is what makes "try a different
mix of chemicals" a data change rather than a code change, and it follows the content-data
rule already in [architecture.md §5](architecture.md).

### Phase change

One shared saturation model, adopted now rather than deferred — the void coefficient is the
most interesting feedback loop in the whole game concept, and it is *positive* feedback,
which is where real tension lives. A general "given pressure and enthalpy, split the
parcel" is one function; two bespoke implementations would be more work than one shared one.

A node holding a boiling mixture simply has two parcels, `water` and `steam`, tagged
`liquid` and `gas`. Tag routing (§6) then separates them for free — which is exactly what a
drum separator is.

### Reactions have rates

Phase change snaps to equilibrium; **chemistry does not**. An instantaneous reaction has no
transient, and the transient is the game — a vat that reacts the moment reagents meet gives
the overseer nothing to steer.

```yaml
# content/reactions/neutralisation.yml
neutralisation:
  consumes:  { vitriol: 1.0, quicklime: 1.1 }     # kg ratios
  produces:  { brine: 2.1 }
  enthalpy_j_per_unit: -1.85e6                     # per unit of extent; negative = exothermic
  rate_per_s:        0.35                          # first-order approach to completion
  min_temperature_k: 310
```

`Δextent = (1 − extent) · rate_per_s · dt`, optionally scaled by temperature. Crude by
design. Because reactions are content records rather than mechanism code, tag-driven
chemistry — catalysts, inhibitors, competing pathways — is an additive upgrade.

**Deferred:** multi-component distillation, non-equilibrium kinetics, dissolved-species
chemistry beyond threshold reactions.

---

## 5. Delay comes from hop count

There is no `delay:` parameter anywhere, and no `transit` shift register. **Delay is a
consequence of graph shape.**

Every node reads the frozen tick N−1 state, so a producer's output cannot reach a consumer
until the following tick. That is one tick per hop, automatically. Verified against the v0
engine with all delays zeroed:

```
tick | feed.delivered | vessel.slurry_a | turbine.rpm
   1 |           1.80 |          0.0000 |      0.0000   ← feed acts
   2 |           1.80 |          0.8100 |      0.0000   ← vessel, 1 hop downstream
   3 |           1.80 |          1.1745 |     12.4831   ← turbine, 2 hops downstream
```

**This is why closed loops work.** No topological sort exists to be undefined on a cycle;
a recirculation loop is just a graph where following the edges returns you to the start,
and every node still reads N−1. Confirmed by running a `turbine → vessel` condensate loop
on the current engine: five ticks, no sort, no special case, no error.

### The latency budget is a design surface

Because delay is hop count, topology *is* game feel. This must be budgeted deliberately
rather than emerging as the sum of three reasonable-looking decisions:

```
lever → gauge  =  minion actuation ticks          (§7)
               +  hops from control point to effect
               +  hops from effect to gauge source
               +  gauge filter lag                (§7)
```

The RBMK feedwater line — main pump → regenerative heaters → drum separators → reactor —
is four nodes and three interfaces, so ~7 hops from pump lever to reactor effect. At 4 Hz
that is **1.75 s, and that is the intended feel, not a cost to be minimised**: for a plant
of that size a few seconds of lag reads as appropriate weight, and instant response would
read as toy-like. §11 asserts the number so it cannot drift in either direction — a later
refactor that "optimises" a hop away would be a game-design regression, not a win.

**Interfaces earn their node.** A join becomes a node when it has a control point, can fail,
or restricts flow. Otherwise it is an edge and costs nothing.

---

## 6. The tick

Eight phases. Every one is either order-independent by construction or a single pure
function over the whole graph.

```
┌ 0  ACTUATE ─────────────────────────────────────────────────────────┐
│  commands (already applied at the barrier) have set control targets  │
│  minions converge actual → target; mishaps roll from named streams   │
│  ALL minion entropy is drawn HERE, inside the tick, never in apply() │
├ 1  READ ────────────────────────────────────────────────────────────┤
│  freeze tick N-1 state; cache derived scalars (temperature_k,        │
│  pressure_pa, port availability) once for the whole tick             │
├ 2  PLAN ────────────────────────────────────────────────────────────┤
│  every node → Intent(wants: {port => kg}, offers: {port => parcels}) │
│  pure, order-independent, reads N-1 only                             │
├ 3  SETTLE ──────────────────────────────────────────────────────────┤
│  ONE pure function over ALL claims — mass AND heat alike             │
│  mass: capped by port capacity; heat: capped by overshoot bound      │
│  oversubscription split deterministically (proportional or priority) │
│  whatever is not granted STAYS WITH THE SENDER — this is back-pressure│
├ 4  TRANSFER ────────────────────────────────────────────────────────┤
│  a) advection: granted parcels move, carrying their joules with them │
│  b) conduction: granted joules move across thermal links             │
│  c) ambient:    each node leaks to environment → ledger              │
├ 5  REACT ───────────────────────────────────────────────────────────┤
│  per node: phase split snaps to saturation equilibrium (fast)        │
│            chemistry advances by rate · dt toward completion (slow)  │
│  local only; no cross-node effects, so order cannot matter           │
├ 6  STRESS ──────────────────────────────────────────────────────────┤
│  derived T/P vs limits → durability depletion → failure events       │
├ 7  OBSERVE ─────────────────────────────────────────────────────────┤
│  diagnostics sample their Source, advance their Filters              │
├ 8  PUBLISH ─────────────────────────────────────────────────────────┤
│  freeze the new state, emit events                                   │
└─────────────────────────────────────────────────────────────────────┘
```

Nodes only implement phases 2 and 4a (`plan` / `apply`). Phases 0, 4b, 4c, 5, 6, and 7 are
driven by concerns and engine machinery — a mechanism author writes none of them.

### Settlement: back-pressure without ordering

Rejection ("excess remains in the pushing mechanism") is correct and fixes two real v0
defects — silently annihilated matter, and two consumers jointly over-drawing a buffer. But
the naive form requires a node to learn mid-evaluation what another node accepted, which is
a write during the evaluation phase.

Two-phase settlement gets the same behaviour without giving up order-independence:

```ruby
# PHASE 2 — every node, independently, against N-1 state
Intent(wants:  { inlet  => 2.5 },
       offers: { outlet => [{resource: :steam, kg: 4.0, joules: 1.1e7}] })

# PHASE 3 — one pure function over the whole intent set
Grant(drawn:    { inlet  => 2.5 },
      pushed:   { outlet => 3.1 },
      rejected: { outlet => 0.9 })     # ← the sender keeps this. it backs up.

# PHASE 4a — every node, independently, knowing what it actually got
apply(state, ctx, grant)
```

Because `settle` sees every claim at once, oversubscription is **explicit and tunable**
rather than an accident of `clamp` — "the relief line gets capacity before the production
line" becomes expressible, which is real game-design surface. And rejection is observable,
so a backing-up system can drive a gauge and emit an event instead of vanishing.

Tie-breaks must never depend on hash order. Proportional-to-request is the default;
declared priority overrides it.

### Heat transfer: closed form, so time compression is free

Explicit Euler (`ΔQ = k·ΔT·dt`) goes unstable when `k·dt` approaches the heat capacity —
which is exactly what a large `time_scale` causes. Since compression is a dial the player
or designer turns, an integrator whose stability depends on that dial is unacceptable.

Every thermal link uses the **exact two-body relaxation solution** instead:

```
T_eq = (C_i·T_i + C_j·T_j) / (C_i + C_j)
τ    = 1 / (k · (1/C_i + 1/C_j))
f    = 1 − exp(−dt / τ)                    # f ∈ (0, 1) for ALL dt
q    = C_i · (T_i − T_eq) · f              # joules: leaves i, enters j
```

Ambient loss is the same shape against a fixed environment temperature:

```
f = 1 − exp(−k_ambient · dt / C)
q = C · (T − T_ambient) · f                # joules → environment ledger
```

**Unconditionally stable for a pair at any `dt`,** because `f` can never exceed 1 — a link
cannot overshoot equilibrium no matter how long the timestep. Measured against explicit
Euler on two bodies (C=1000 at 500 K, C=2000 at 300 K, k=50 W/K):

```
  dt   | EULER after 1 step        | CLOSED FORM        | closed-form energy error
   1.0 | T1= 490.00  T2= 305.00    | T1=490.37 T2=304.82 | 0.00e+00
  20.0 | T1= 300.00  T2= 400.00 ✗  | T1=396.42 T2=351.79 | 0.00e+00
 100.0 | T1=-500.00  T2= 800.00 ✗  | T1=366.74 T2=366.63 | 0.00e+00
1000.0 | T1=-9500.0  T2=5300.00 ✗  | T1=366.67 T2=366.67 | 0.00e+00
```

Euler is unusable past `dt≈20` and produces negative Kelvin at `dt=100`. The closed form
converges cleanly to `T_eq = 366.67` and conserves energy to the bit at every timestep.

### Heat is arbitrated, exactly like mass

> **Historical from here to the end of this section.** The diagnosis below is right and the
> remedy is not: the conductance-weighted bound it describes was deleted in September 2026.
> It was correct only where one body's capacity dwarfs the other's, and wrong by a factor of
> two otherwise — it moves a sender to the receiver's *current* potential without allowing for
> the receiver rising, so two equal bodies **swap**. Heat, rotation and mass now go through one
> implicit solve of the whole network. See
> [`reference/settlement.md`](reference/settlement.md).

Pairwise closed form alone is **not** sufficient in a network. Each link independently
computes "I will move most of the way to *my* pairwise equilibrium," so several hot
neighbours converging on one small-heat-capacity node each contribute nearly a full
relaxation and the sums stack. Three 600 K bodies feeding one small 300 K node drive it to
**1067 K at `dt=1`** — energy is still conserved exactly, but the node is hotter than
anything feeding it, which would boil coolant that has no business boiling.

The fix is not substepping. **Route heat claims through the same settlement phase as mass.**
Each thermal link declares a `q` intent; the arbiter caps the total into each node at the
point where it would pass the conductance-weighted mean of its own neighbours; whatever is
not granted simply is not moved, and stays as sender enthalpy.

```
bound_i  = C_i · (T_ref_i − T_i)     where T_ref_i = Σ(k_ij · T_j) / Σ(k_ij)
```

Same case, arbitrated:

```
  dt   | cold body T | hottest source | energy error
   0.1 |      462.83 |         598.91 | 0.00e+00     ← bound doesn't bind
   1.0 |      600.00 |         598.00 | 0.00e+00     ← capped at neighbour mean
 100.0 |      600.00 |         598.00 | 0.00e+00     ← still capped, still exact
```

No overshoot at any timestep, energy conserved to the bit, and the two-body case is
bit-identical to the unarbitrated closed form — the bound only binds when it needs to.
Left to run, it converges to the true multi-body equilibrium (598.01 K after 40 ticks,
zero accumulated energy error).

This is a genuine simplification rather than an extra mechanism: **mass and heat are the
same problem** — claims against a shared limit, settled once, with the remainder staying
put. One arbiter, one set of guarantees, and back-pressure works identically for both.

Together this is what makes `time_scale` genuinely tunable, and it means **no substepping
is needed for thermal** — the single biggest factor in the performance budget (§9).

### Thermal structure is declared, not sequenced

The proposal worried about specifying a thermal *sequence* per mechanism
(`inlets → vessel → fuel rods → water → vessel`). That concern dissolves: because every
link resolves from N−1 state simultaneously, you **declare links, not order.**

```ruby
thermal_link :fuel_cluster, :coolant,     conductance: 4.0e5
thermal_link :coolant,      :vessel_wall, conductance: 1.2e5
# vessel_wall's ambient_conductance handles the leak to the room
```

If two things need different temperatures, they are two nodes. One thermal mass per node
keeps the model comprehensible, and a 100-node budget affords it.

---

## 7. Control and observation

### Time compression

```ruby
TICK_WALL_SECONDS = 0.25          # 4 Hz. Fixed. Non-negotiable per the brief.
time_scale        = 20.0          # tunable per operation
sim_dt            = 5.0           # simulated seconds advanced per tick
```

Wall-clock rate and simulated-time rate are independent. Commands, telemetry, and
projection all still happen once per wall tick, so nothing in
[architecture.md §6–7](architecture.md) changes. Only the physics sees `sim_dt`.

Because §6's heat transfer is closed-form, `time_scale` can be 1 or 1000 without
destabilising anything. Genuinely nonlinear terms (reaction kinetics, runaway feedback) may
declare a substep count; default is 1.

### Minions

A minion stands at a control point or reads a gauge. Attributes: strength, intelligence,
health, tags (`undead`, `covetous`, `licensed`), and skills.

**The constraint that keeps Kafka working.** Commands must remain absolute and idempotent —
offset-after-snapshot, replay, and crash recovery all rest on it:

```ruby
# COMMAND — absolute, idempotent, applied at the barrier. Sets a target only.
{ type: "set_control", control_point_id: "relief_valve", value: 85 }
#   => controls[:relief_valve][:target] = 85.0

# PHASE 0 — the minion converges the actual. Deterministic, seeded, inside the tick.
#   actual += clamp(target − actual, −rate, +rate)   rate = f(strength, stiffness, health)
#   mishaps roll from the minion's own named RNG stream
```

Delivering `target = 85` twice is still a no-op. **All minion entropy is drawn in phase 0,
never during command application** — otherwise replaying the log would consume RNG
differently and determinism would break.

Minion actuation is a *second* latency layer on top of hop count. A stiff valve at
15%/tick is ~6 ticks to traverse its range. Budget it (§5), don't discover it.

### Diagnostics: source → filters → display

The v0 base class was too fat — `pegged?` had no callers, every gauge paid for a history
array at `delay: 0`, and an indicator lamp would inherit noise it could never use. But a
subclass tree is the wrong fix, because the properties *compose*: noisy, lagged, quantised,
sticky, misread. That is `NoisyLaggedStickyGauge` and 2ⁿ siblings.

```ruby
Diagnostic.new(
  id:      :vessel_temp,
  source:  Sources::Derived.new(:vessel, :temperature_k),
  filters: [ Filters::Lag.new(2), Filters::Noise.new(1.5), Filters::Range.new(273, 873) ],
  display: Displays::Needle.new(unit: "°C")
)

# durability, read by an untrained underling — same base class, no ceremony
Diagnostic.new(
  id:      :fitting_condition,
  source:  Sources::Durability.new(:steam_fitting),
  observer: :grubwick,                          # ← minion quality drives the filters
  filters: [ Filters::Lag.new(12), Filters::Misread.new, Filters::Bands.new(5) ],
  display: Displays::Prose.new(%w[
    pristine  fine  showing\ some\ cracks  weeping\ badly  about\ to\ go
  ])
)
```

This closes three trace findings at once and answers the durability question directly:
**durability is readable but never numeric.** Bands plus prose plus an unreliable observer
gives "the fitting is showing some cracks" rather than a health bar — and a cruder
diagnostic is literally a longer `Lag` and a `Misread` filter, not a different class.

`Sources` decouples gauges from mechanism fields, so a buffer level, a flow rate, a derived
scalar, or an aggregate all become observable — the v0 engine could only read one scalar off
one mechanism, which is why the steam line that killed the player was structurally invisible.

`Filters::Noise` holds its offset until the underlying value moves past a deadband, so an
idle gauge stops reporting changes. In v0, 3–5 of 8 gauges "changed" every tick on a
completely idle machine, which made delta compression meaningless.

**"Upgrade your instrument" is now literally "remove a filter from the list."**

---

## 8. Conservation: lossy is fine, silent is not

The v0 engine destroyed ten units of steam across two ticks with nothing recording it. That
is the failure mode to design out — not loss itself, which is often correct, but *unrecorded*
loss.

**Policy: approximate freely, but every gram and joule that leaves is declared in a ledger.**

```ruby
environment: {
  ambient_k:        293.15,
  joules_to_ambient:  0.0,   # waste heat — radiation and convection
  mass_vented:        0.0,   # relief valves, deliberate discharge
  mass_spilled:       0.0,   # overflow, leaks, failure
  joules_advected_out: 0.0   # energy carried out with vented mass
}
```

This turns two real specs on:

```
total_mass(state)   + environment.mass_out   == constant
total_joules(state) + environment.joules_out == constant
```

Your observation about ambient exchange is what makes this work rather than complicating it.
Without a per-node ambient term, energy could only leave at pipeline ends, which is both
physically wrong and makes every long chain a heat accumulator. **Adding the environment as
an explicit sink gives waste heat *and* makes exact conservation cheap** — the two goals
turned out to be the same goal. Every `Thermal` node carries an `ambient_conductance`, and
what it sheds is added to the ledger rather than discarded.

Cost of strict conservation, honestly: one addition per transfer and one summation per spec
run. Effectively free — so we take it. Where an approximation is genuinely simpler *and*
observably equivalent, take the approximation and record the difference in the ledger.

---

## 9. Performance budget

Measured, not estimated — 100 nodes, 100 mass links, 25 thermal links, 4 Hz, on the dev
machine. An earlier draft of this section guessed "~5 ms, comfortable with room to spare"
and was wrong by an order of magnitude, which is why the numbers below come from
`spec/reactor_sim/performance_spec.rb` rather than from arithmetic.

| Phase | ms/tick | Share |
|---|---|---|
| 5 REACT (phase solve) | 20.5 | 37% |
| 4a TRANSFER (advection) | 9.3 | 17% |
| 3 SETTLE (mass) | 9.2 | 17% |
| 4 APPLY (node effects) | 4.8 | 9% |
| 3 SETTLE (grants) | 3.8 | 7% |
| 4c AMBIENT | 5.8 | 11% |
| 3 SETTLE (heat) + 4b CONDUCT | 3.6 | 7% |
| 6 STRESS, 0 ACTUATE | 0.4 | 1% |
| **Total** | **≈55 ms** | **22% of the 250 ms budget** |

**Comfortable, but not free.** One RBMK-scale operation costs about a fifth of a tick. That
is fine — an operation this size is the stated ceiling, most are far smaller (the Chemical
Vats are ~8 nodes), and a runner hosting several of them at once would still fit. It is not
so much headroom that the cost can be ignored.

Two things dominate, and both are worth knowing:

- **The saturation solve is half the tick.** It bisects for the self-consistent pressure
  once per phase-changing node (§6). `Saturation::ITERATIONS` is the first dial to turn if a
  large operation ever needs to be cheaper; dropping it costs precision nothing observes.
- **Closed-form heat transfer is what makes the rest affordable.** At 40 substeps the
  thermal phases alone would exceed the entire budget. This is the concrete payoff for §6
  using the exponential rather than Euler.

Two optimisations already applied, both worth not undoing: the bisection's inner loop runs
on captured locals rather than a context hash (that alone was ~64% of the tick), and the
arbiter indexes its adjacency and parcel lookups instead of rescanning per link, which was
quietly O(n²).

### File layout

The library is outside Zeitwerk's reach by design, so the require chain in `reactor_sim.rb`
is also the dependency graph — and the folders follow it:

```
physics/      substances, energy bookkeeping, the relaxation solver — no graph awareness
graph/        nodes, ports, links, and the arbiter that settles claims between them
concerns/     composable state+behaviour fragments a node opts into
nodes/        generic machinery, reusable across operations
diagnostics/  the instrument chain and the only thing that leaves the simulation
operations/   specific machines, built from everything above
tick.rb       the eight phases, in order
```

Two rules keep it honest:

- **`nodes/` is generic.** A node that belongs in there must make sense outside the
  operation it was written for, in its code *and* in its comments. `Cylinder` is a gas
  expander that happens to suit a steam engine, not a steam engine part — its working fluid
  is configuration, not a hardcoded `:steam`.
- **Anything genuinely specific lives under its operation.** `operations/steam_engine/`
  holds the definition and the panel; nothing else knows those exist.

`Parcel` and `Ledger` are modules over plain hashes rather than classes, deliberately.
Parcels are the hot path — allocation there was once 64% of a hundred-node tick — and both
are snapshotted every tick, so a class would add a `to_h`/`from_h` round trip to maintain
and buy nothing. Behaviour lives in the module instead.

**Materials are resources.** Cast iron, steel and babbitt are content records carrying
`tensile_strength_pa` alongside the density they already had, so a part is configured with
`material: :cast_iron` and reads both from content. Safety factors stay on the part, since
how far below the ideal figure a real casting fails is a property of the casting rather than
of the metal. A foundry operation could one day produce these and nothing would change.

---

## 10. State layout

```ruby
{
  tick: 412,
  seed: 20260822,
  time_scale: 20.0,
  operations: {
    vats: {
      nodes: {
        vessel: { joules: 1.4e8, parcels: [...], durability: 8_470.0, broken: false },
        steam_line: { joules: 2.1e6, parcels: [...], durability: 12_000.0, broken: false }
      },
      controls:    { coolant: { target: 85.0, actual: 62.5 } },
      minions:     { grubwick: { health: 0.8, fatigue: 0.2, station: :coolant } },
      diagnostics: { vessel_temp: { filters: [{history: [...]}, {offset: 1.1}, {}] } },
      environment: { ambient_k: 293.15, joules_to_ambient: 4.2e7, mass_spilled: 0.0 }
    }
  },
  rngs: { "vats/vessel" => 12345678901234, "vats/grubwick" => 98765432109876 }
}
```

Serialisation rules from v0 carry over unchanged: JSON round-trip must be exact, RNG state
lives inside match state, events are excluded (they are output, not state), and per-component
RNG streams are named so nothing depends on evaluation order.

---

## 11. Specs

Four v0 specs carry over unchanged and **must stay green through every step of the
migration**. If a step requires disabling one, that step is the one to think hardest about.

| Spec | Asserts |
|---|---|
| Purity | Sim loads with no Rails; no `Time.now`/`SecureRandom`/`rand`/`ENV` in `lib/` |
| Determinism | Same seed + same commands → identical digest |
| Order-independence | Command order irrelevant; **now also**: shuffling node evaluation order changes nothing |
| Idempotence | Duplicate delivery is a no-op; last-write-wins |

Five new ones define the new invariants. Each exists because it guards something that would
otherwise fail silently:

| Spec | Asserts | Guards against |
|---|---|---|
| **Mass conservation** | `Σ parcels + ledger.mass_out` constant across N ticks | v0's silent annihilation |
| **Energy conservation** | `Σ joules + ledger.joules_out` constant across N ticks | heat vanishing in transfer or phase change |
| **Thermal stability** | At `time_scale` 1 and 1000: no NaN, no node exceeds the conductance-weighted mean of its neighbours, nothing falls below ambient | Euler instability and multi-link overshoot read as physics |
| **Cycle tolerance** | A graph with a recirculation loop runs N ticks and stays finite | any accidental reintroduction of ordering assumptions |
| **Latency budget** | Per operation: lever → gauge is exactly K ticks | game feel drifting as topology grows |

The last one is unusual and deliberate. Because delay is now emergent, adding one interface
silently changes how the game feels. Asserting the number makes that a decision instead of
an accident.

---

## 12. Build order

Each step is independently valuable and leaves the suite green.

| # | Step | Status | Why here |
|---|---|---|---|
| 1 | SI units: joules and Kelvin throughout; pressure derived | **done** | Everything else assumes it |
| 2 | Delete `delay:` and `transit` | **done** | Pure deletion; delay becomes hop count |
| 3 | Durability replaces wear | **done** | Small, unblocks readable diagnostics |
| 4 | `Concerns`: Thermal, Holds, Wearing, Pressurized | **done** | The composition substrate |
| 5 | `Node` / `Port` / `Link`; `Conduit`, `Vessel`; retire `Buffer` | **done** | Graph model |
| 6 | `plan` / `settle` / `apply` + conservation ledger | **done** | Landed with 5, as intended |
| 7 | Closed-form thermal links, arbitrated, + ambient sink | **done** | Reuses 6's arbiter; makes `time_scale` safe |
| 8 | `Resources` modules + YAML content + saturation model | **done** | Phase change, swappable fluids |
| 9 | Tag-routed ports | **done** | The port contract; enables branching topologies |
| 10 | Diagnostics: source → filters → display | **done** | Closes three trace findings |
| 11 | Rotation, combustion, and the steam engine | **done** | First real operation; see below |
| 12 | Minions at control points and at gauges | next | Needs 10 for the observer path |

### The steam engine increment

`Concerns::Rotating` (angular momentum stored, ω derived), `DriveLink`, `Nodes::Flywheel`,
`Load`, `Cylinder`, `Atmosphere`, `ReliefValve`, and combustion content. The relaxation
mathematics is now shared: `Relaxation` is parameterised on `(capacity, potential)` and
both heat `(C, T)` and rotation `(I, ω)` run through it, bound and all.

Two rules changed as a result, and they have to stay in step:

- **Gases are limited by pressure, not volume.** A gas expands to fill what it is given;
  charging it against a fixed volume at a nominal density capped a high-pressure cylinder
  at 1.2 atm. `Holds#room_m3` and `Arbiter#volume_of` both now exempt gases, and
  `Pressurized#gas_headroom_kg` provides the pressure limit instead.
- **An active sink is authoritative about its own intake.** Flow used to be
  `max(push, draw)`, which meant a sink could not refuse — a valve shoving its contents at
  a cylinder overrode the cylinder's own limit. A node that declares a draw now gets
  exactly that; a passive tank declares nothing and still accepts whatever arrives.

Also: an empty vessel reports a **vacuum**, not one atmosphere. Reporting 101 kPa for a
node holding nothing meant a low-pressure boiler could never fill a cylinder, and a
condenser could not present the vacuum an atmospheric engine works against.

**Energy conservation needed two new declarations**, both found by the drift check rather
than by reasoning:

- `joules_from_reactions` — parcel enthalpy does not carry chemical bond energy, so
  combustion is genuinely a source and has to be declared like a burner is.
- Stoichiometry conserves enthalpy, not temperature. Building products at the reactants'
  temperature minted ~780 kJ per firing, because eleven kilograms of air and twelve of flue
  gas are different amounts of energy at the same temperature. `enthalpy_j_per_unit` is now
  defined to absorb any formation-enthalpy difference, making it the single line where a
  reaction may change the system's energy.

Steps 1–10 are complete and the suite is green: purity, determinism, order-independence and
idempotence carried over unbroken, and mass/energy conservation, thermal stability, cycle
tolerance, the instrument chain and the performance guard are new.

All three v0 diagnostic findings are closed. `Sources` can read levels, contents, rates and
derived scalars, so a backing-up line is observable at last. `Filters::Range` ships a
`:pegged_high` flag, so "600 °C" and "at least 600 °C" are finally distinguishable.
`Filters::Noise` holds its offset until the signal moves past a deadband, so an idle gauge
stops reporting a change every tick and the delta protocol compresses something real.

One design point that only appeared once it was built: a god-view must skip the filters that
make a reading *worse* but keep the ones that change what it *means*. `Filters::Base#distortion?`
draws that line — without it, a `Rate` instrument reported the raw temperature in a box
labelled K/s.

The old `Mechanism`, `Buffer`, `Diagnostic` and `PlayerView` are deleted, along with the v0
Chemical Vats. `spec/support/loop_rig.rb` is the fixture the engine is exercised against —
a boiler → steam line → condenser → return line **closed loop**, which is the topology the
old paradigm could not have run at all.

The Chemical Vats rebuild comes after step 10, with design input on the operation itself
before it starts.

---

## 13. Settled, and still open

### Settled — start here, upgrade in stages

1. **Pressure: simple.** Ideal gas over the free volume, plus liquid displacement. No pump
   head, no hydrostatic term, no flow-induced pressure drop. Because the physics is
   encapsulated in `Concerns::Pressurized` and `Resources`, each of those is an additive
   change later rather than a rework.
2. **Settlement: proportional-to-request.** Declared priority is not built. Changing the
   split rule later is a change to one pure function, so this is cheap to revisit.
3. **Reaction rates are modelled, crudely.** Rates are fundamentally important — an
   instantaneous-equilibrium reaction has no transient to manage, and the transient *is* the
   game. So the REACT phase splits in two:
   - **Phase change is instantaneous.** Evaporation and condensation are fast relative to
     any sane `time_scale`; snapping to saturation equilibrium is both simpler and more
     accurate than rate-limiting it.
   - **Chemistry is rate-limited.** First-order approach to completion:
     `Δextent = (1 − extent) · rate · dt`, with `rate` optionally scaled by temperature.
     Crude on purpose. Tag-driven chemistry — catalysts, inhibitors, competing pathways —
     is the upgrade path and needs no structural change to reach.
4. **One thermal mass per node.** Things that need distinct temperatures are distinct nodes.
   Sub-masses within a node remain the fallback if the ~100-node budget starts to bind.
5. **Lever-to-effect latency of ~1.75 s is a target, not a tolerance.** For a large slow
   plant a few seconds of lag reads as appropriate weight rather than as lag. §11's latency
   spec exists to stop it drifting in *either* direction.

### Still open

- **Condensate has no way out of a gas-only line.** Tags govern what may be *transported*,
  not what may *exist*, so steam that condenses inside a cooling pipe becomes liquid water
  in a conduit whose ports accept only gas — and it can never leave. This is exactly why
  real plants fit steam traps, so the behaviour is right; what is undecided is whether the
  answer is a `SteamTrap` node, a port that accepts a phase pair, or simply letting
  condensate accumulate as a hazard the overseer has to manage. Surfaced by the engine, not
  predicted — worth deciding when designing the Vats.
- **Non-condensable gases do not contribute to the saturation solve.** `implied_pressure`
  accounts only for the pair being solved, so air or a reaction product sharing a vessel
  with boiling water would not raise its boiling point. Correct for everything planned;
  wrong the first time a vessel holds steam and something else gaseous at once.
- **Minion progression.** Licences, fatigue, injury, and how they map to filter parameters.
  Deferred deliberately: the specifics would slow the engine work down, but the seams
  (`observer:` on diagnostics, `station:` on minions) are reserved so it lands additively.
- **Tag-driven chemistry.** Catalysis, competing reactions, dissolved-species behaviour.
- **Multi-component distillation and non-equilibrium kinetics.** Not needed by any planned
  operation.
