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

**Deferred:** multi-component distillation, non-equilibrium kinetics, dissolved-species
chemistry beyond simple threshold reactions.

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
that is 1.75 s before minion and gauge lag. That is a legitimate design choice for a large
slow system, and a bad one for a small twitchy one. §11 makes it a spec so it cannot drift
silently.

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
│  per node, per concern: Resources.equilibrate — phase split,         │
│  threshold chemistry. Local only; no cross-node effects.             │
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

100 nodes, ~150 mass links, ~150 thermal links, ~40 diagnostics, 4 Hz.

| Phase | Work per tick |
|---|---|
| 0 ACTUATE | ~20 control points |
| 1 READ | 100 derived scalar computations, cached |
| 2 PLAN | 100 node calls |
| 3 SETTLE | two passes over ~300 mass + thermal links (claim, then bound-and-scale) |
| 4 TRANSFER | ~150 advections + ~150 conductions + 100 ambient |
| 5 REACT | 100 equilibrations |
| 6 STRESS | 100 checks |
| 7 OBSERVE | ~40 sample + filter chains |
| **Total** | **~1,000 operations/tick → ~4,000/second/match** |

Comfortable in Ruby with room to spare. **The decisive factor is closed-form heat transfer:**
at 40 substeps this would be ~40,000 operations per tick and the budget would be gone. That
is the entire reason §6 uses the exponential rather than Euler.

Measure before assuming — a `Match#step!` benchmark at 100 nodes belongs in the spec suite
as a guard, not as a one-off.

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

| # | Step | Why here |
|---|---|---|
| 1 | SI units: joules and Kelvin throughout; pressure derived | Everything else assumes it |
| 2 | Delete `delay:` and `transit` | Pure deletion; delay becomes hop count |
| 3 | Durability replaces wear | Small, unblocks readable diagnostics |
| 4 | `Concerns`: Thermal, Holds, Wearing, Pressurized | The composition substrate |
| 5 | `Node` / `Port` / `Link`; `Conduit`; retire `Buffer` | Graph model |
| 6 | `plan` / `settle` / `apply` + conservation ledger | **Land with 5** — half of this is worse than either end |
| 7 | Closed-form thermal links, arbitrated, + ambient sink | Reuses 6's arbiter; makes `time_scale` safe |
| 8 | `Resources` modules + YAML content + saturation model | Phase change, swappable fluids |
| 9 | Tag-routed ports | The port contract; enables branching topologies |
| 10 | Diagnostics: source → filters → display | Closes three trace findings |
| 11 | Minions at control points and at gauges | Needs 10 for the observer path |

Steps 1–3 are nearly free. **Steps 5 and 6 are the real work and must land together.**
Steps 8–10 are where the modularity payoff actually arrives.

The Chemical Vats rebuild comes after step 10, with design input on the operation itself
before it starts.

---

## 13. Still open

Deliberately unresolved, to be settled by building rather than by guessing:

1. **Pressure model fidelity.** Ideal gas over free volume plus liquid displacement is the
   plan. Pump head, hydrostatic pressure, and flow-induced pressure drop are not modelled.
   That is probably fine for a fantasy plant, but the feedwater line is where it would first
   look wrong.
2. **Settlement priority.** Proportional-to-request is the default. Whether declared
   priority is needed — and whether it is per-port or per-resource — should come from a real
   operation that needs it.
3. **Minion progression.** Licences, fatigue, injury, and how they map to filter parameters.
   Deferred until the operations exist to be staffed.
4. **Node internal substructure.** Currently one thermal mass per node, split into more nodes
   when more temperatures are needed. If a 100-node budget starts to bind, sub-masses within
   a node become the alternative.
5. **Chemistry beyond thresholds.** Reaction *rates* rather than instantaneous equilibrium.
   The vats may or may not need this; the RBMK does not.
