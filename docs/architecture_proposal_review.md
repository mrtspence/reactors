# Review: The Composed-Properties Rearchitecture

A critique of the counter-proposal in
[`mechanism_pipeline_thoughts.md`](mechanism_pipeline_thoughts.md), and of the current
architecture it replaces. Where a fair comparison needs an implementation sketch, one is
given.

**Headline:** most of the proposal is right, and one part of it is a downgrade that I can
demonstrate empirically rather than argue about. The core diagnosis — *`Buffer` is
overloaded and mechanisms will become bespoke monoliths without abstractions to absorb
complexity* — is correct and worth acting on now. The proposed fix for **resolution
order** is the one piece to drop, because the property you want from it already exists in
the current engine and the proposed mechanism costs more than it gives.

---

## 0. Scorecard

| # | Proposal | Verdict | Why |
|---|---|---|---|
| P1 | `Buffer` is overloaded, decompose it | **Adopt** | It conflates four concerns. Correct diagnosis. |
| P2 | Shared property mixin (temp/pressure/mass/…) | **Adopt in part** | Right instinct, wrong granularity. Several small concerns, not one interface. |
| P3 | Interface as a first-class node | **Adopt, drop the flag** | Correct, and control-points-on-valves is a genuinely good idea. Costs latency — quantified in §5. |
| P4 | `Resource` owns its own physics | **Adopt, with one correction** | Strong. But "mutates the state inside" would break determinism; make it a pure module. |
| P5 | 1 tick = 5–10 simulated seconds | **Reject as stated** | Numerically unstable with explicit Euler, and it conflates sim-time with wall-clock. Substep instead. |
| P6 | Mechanism declares its thermal sequence | **Adopt** | Necessary once heat transfer is real. Separate chains is the right call. |
| P7 | Reverse-topological resolution order | **Reject** | You already have 1-tick-per-hop for free. This buys nothing and forbids cycles. §1. |
| P8 | Push with rejection; excess stays with sender | **Adopt the goal, sketch needed** | Fixes findings #2 and #6. Naive version breaks order-independence; two-phase version doesn't. §4. |
| P9 | Tag-based outlet routing | **Adopt — best idea here** | This is the deferred port contract, and it generalizes. |
| P10 | Minions mediate control points | **Adopt, with a hard constraint** | Threatens command idempotence unless commands set *targets*. §7. |
| P11 | Thin `Diagnostic` base class | **Adopt, but subclasses are the wrong shape** | Filter pipeline, not subclass tree — otherwise combinatorial explosion. §6. |

---

## 1. Resolution order: you already have what you're asking for

This is the most consequential item, so it goes first.

### What you proposed

> Instead of having a complex delay system where each mechanism is given some sort of god
> offset that determines what part of the pipeline it 'sees', we could just resolve each
> interface and mechanism in reverse order, so that each object with 10 parents goes
> first […] the delay system I think is better suited as an emergent property of a
> sequence of mechanisms rather than something we have to hardcode in from the start.

### The goal is right, and the current code already delivers it

The desired property — **delay emerges from chain depth rather than being configured** —
is already a property of double-buffered evaluation. It does not need a topological sort.
You get it by deleting the `delay:` parameter, not by adding a scheduler.

Evidence. Same four mechanisms, same wiring, every `Buffer` set to `delay: 0`:

```
tick | feed.delivered | line_a | vessel.slurry_a | vessel.vented | steam_line | turbine.rpm
   1 |           1.80 |   1.80 |          0.0000 |        0.0000 |     0.0000 |      0.0000
   2 |           1.80 |   1.80 |          0.8100 |        0.1541 |     0.1541 |      0.0000
   3 |           1.80 |   1.80 |          1.1745 |        0.3219 |     0.3219 |     12.4831
   4 |           1.80 |   1.80 |          1.3385 |        0.4928 |     0.4928 |     35.7522
```

The feed acts at tick 1. The vessel — one hop downstream — first reacts at tick 2. The
turbine — two hops downstream — first spins at tick 3. **Exactly one tick per hop,
emergent, with no configured delay anywhere.**

The mechanism is the staleness rule already documented in
[§2 of the trace](mechanism_pipeline_thoughts.md): every mechanism reads tick N−1 state,
so a producer's output cannot reach a consumer until the following tick. That *is*
"one tick per hop." The `delay: 2` on the feed lines is **additional** delay stacked on
top of the inherent one — which is precisely the mental-juggling problem you identified.

So your instinct was correct and your target is correct. The fix is one line per buffer:
`delay: 0`. The `transit` shift register in
[`buffer.rb:37-43`](../lib/reactor_sim/buffer.rb#L37-L43) can be deleted outright.

### Why the reverse-topological version is worse than what you have

Both schemes produce 1 tick/hop. They differ in what they cost.

**Pros of reverse-topological resolution:**
- Delay is visibly a consequence of graph shape. Reads naturally.
- Lets a mechanism learn *within its own tick* whether a downstream push was accepted,
  which is what P8's rejection semantics wants (see §4).
- Matches how a person mentally simulates a plant: "work backwards from the turbine."

**Cons — and the first one is disqualifying:**

1. **It requires the graph to be a DAG. Thermal plants are full of cycles.** A BWR
   recirculation loop is a cycle. Condenser → feedwater → boiler → turbine → condenser is
   a cycle. Any closed coolant loop is a cycle. "Number of parents" is undefined in a
   cycle and topological sort has no answer. You would have to detect cycles and break
   them at an arbitrary edge — reintroducing a hidden ordering dependence, but now
   implicit and undocumented instead of the current explicit "everybody reads N−1."

   The current engine has no such constraint. I added a `turbine → vessel` condensate
   loop to the vats and ran it:

   ```
   5 ticks with a cyclic graph: OK (no sort needed, no error)
   ```

   No sort, no cycle detection, no special case. Closed loops are the *normal* topology
   for the operations you want to build, and double-buffering handles them for free.

2. **It reintroduces evaluation-order dependence**, which is the exact class of bug the
   original design brief called out. Right now order-independence is a *proven* property
   — the determinism spec asserts it. Under topological resolution, correctness depends
   on the sort being right, and a wrong sort produces subtly wrong physics rather than an
   error.

3. **It forecloses parallel evaluation.** Not needed now. But an RBMK modelled per-channel
   is hundreds of nodes at 4 Hz, and "evaluate all mechanisms independently" is the
   property that makes that tractable.

4. **The sort has to be maintained.** Every graph edit re-sorts. Hot-swapping a part
   mid-match — which your modularity goal explicitly wants — becomes a re-sort plus a
   question about what happens to nodes whose depth changed.

### Recommendation

Keep double-buffered, order-independent evaluation. Set all delays to zero and let hop
count be the only delay. **You get your proposal's stated benefit by deleting code**, and
you keep cycles, order-independence, and parallelism.

**Tradeoff you accept:** a mechanism cannot learn within its own tick whether a push was
accepted. That is real, and it is what §4 has to solve.

**Tradeoff you avoid:** having to answer "what is the topological order of a
recirculation loop?"

---

## 2. `Buffer` is overloaded — agreed, and here is the decomposition

You are right. `Buffer` currently carries four unrelated jobs:

| Job | Field | Where it should live |
|---|---|---|
| Storage | `contents` / `capacity` | a `Holds` concern on mechanisms (tanks, vessels) |
| Transport delay | `transit` | **delete** — emergent from hop count (§1) |
| Throughput limit | *implicit, absent* | an `Interface`/`Conduit` node's rate limit |
| Back-pressure signal | `room` | rejection at push time (§4) |

This is a clean four-way split and every piece has an owner. Notably it makes your
distinction — "interface capacity is how much can *transit*, not how much it can
*contain*" — physically correct in a way the current code is not. A pipe passes flow; a
tank stores. `Buffer` pretends to be both, which is why `room` is off by a transit slot
([finding #2](mechanism_pipeline_thoughts.md)) and why `spilled` has nowhere to go
([finding #3](mechanism_pipeline_thoughts.md)).

**Pro:** three of the seven trace findings dissolve rather than needing fixes.
**Con:** node count rises (see §5), and `Holds` becomes a shared concern that needs to be
got right once rather than per-mechanism.

---

## 3. Shared properties: right instinct, wrong granularity

### What you proposed

> The properties of Temperature, Pressure, Mass, Specific Heat, Capacity, Resource State,
> Durability, and the ability to fail/break are pretty well universal […] so we may want
> some sort of composed-in interface.

### Pros
- Uniformity enables generic tooling: anything `Thermal` can be heat-transferred with,
  gauged, or made to fail from overheat, without per-mechanism code.
- It is the correct response to "mechanisms will become bespoke monoliths."
- Kelvin internally: **yes, unreservedly.** Ratios and radiative terms need an absolute
  scale, and °C in the current vessel already forces the `AMBIENT` fudge into three
  separate formulas. Convert at the display boundary only.
- Durability as a depleting resource rather than accumulating wear: **yes**, and it is
  more than cosmetic. Today `wear: 0.13` against a *hidden* threshold of `1.0352` is
  literally undisplayable — you cannot draw a bar when the maximum is a secret.
  `durability: 8470 → 0` is displayable, and hiding the starting value hides exactly as
  much.

### Cons of one composed-in interface
- **Everything gets every property.** An indicator lamp acquires a temperature and a
  specific heat. That is a god object assembled by composition instead of inheritance —
  same failure, later.
- **It conflates config with state.** Temperature, mass, and durability are *state* and
  must live in the Operation's frozen hash. Specific heat and capacity are *config* and
  must live on the mechanism. The current design's single most valuable property — a
  mechanism physically cannot write to the tick it reads from — depends on that split
  staying crisp. One mixin holding both is how it gets blurred.
- **Pressure is usually derived, not stored.** The current vessel gets this right:
  `pressure = f(trapped, temperature)`, recomputed each tick, never accumulated. Making
  pressure a stored property invites drift between it and the state that causes it.

### Sketch: several small concerns instead

```ruby
module Concerns
  # Each concern contributes a state fragment and a behaviour, nothing else.
  module Thermal
    # config:  heat_capacity (J/K), conductance (W/K, geometry+material lumped)
    # state:   joules
    def thermal_initial_state = { joules: heat_capacity * AMBIENT_K }
    def temperature_k(state) = state.fetch(:joules) / heat_capacity
  end

  module Wearing
    # config:  wear_model
    # state:   durability  (seeded at construction, depletes to 0)
    def wearing_initial_state(rng) = { durability: rolled_durability(rng), broken: false }
  end

  module Holds
    # config:  volume
    # state:   parcels  [{resource:, kg:, ...}]
    def holds_initial_state = { parcels: [] }
  end
end

class Pipe < Mechanism
  include Concerns::Thermal, Concerns::Wearing, Concerns::Holds
end

class IndicatorLamp < Mechanism   # gets none of them
end
```

`Mechanism#initial_state` merges the fragments of whichever concerns are included.
Pressure stays a method, not a field.

**Tradeoff:** four small modules instead of one, and a merge step in `initial_state`. In
exchange, a lamp stays a lamp and the config/state boundary stays enforceable.

---

## 4. Push-with-rejection: adopt the goal, but the naive version costs order-independence

### What you proposed

> When a resource is pushed to a given interface, that interface knows its capacity. It
> attempts to transit up to that amount of resource — any excess is rejected and remains
> in the 'pushing' mechanism.

This is **correct and it fixes two real defects**. Today, excess is silently annihilated
(finding #2: ten units of steam destroyed across two ticks, with the vessel having already
subtracted them from `trapped`) and two consumers on one buffer could jointly draw more
than exists (finding #6). Rejection conserves matter and makes back-pressure propagate all
the way to the source, which is what real plants do and what makes a blocked system
*interesting* rather than lossy.

### The problem

"Remains in the pushing mechanism" requires the pusher to know, **during its own
evaluation**, how much was accepted. That is a synchronous call into another node's state
mid-tick. Under double-buffering it is not available; under topological order it is, which
is why P7 and P8 arrived together in your proposal. They are a package, and I am
recommending you keep one and drop the other — so P8 needs a different implementation.

Ordering also does not actually solve arbitration. If two mechanisms push into one
interface, whoever the sort happens to run first gets the capacity. That is the same
unfairness as today's silent clamp, just relocated and harder to see.

### Sketch: two-phase settlement

Split `step` into `plan` and `apply`, with a pure arbitration step between them.

```
  PHASE 2a — PLAN     (all mechanisms, order-independent, reads tick N-1)
    intent = mechanism.plan(state, ctx)
    #  => Intent(wants:  { inlet_valve  => 2.5 },      # I would like to draw
    #            offers: { relief_valve => 4.0 })      # I would like to push

  PHASE 2b — SETTLE   (one pure function over ALL intents + node states)
    grants = Arbiter.settle(intents, nodes)
    #  oversubscribed? split deterministically: proportional to request,
    #  or by declared priority. Either is fine; it must not depend on hash order.
    #  => { vessel: Grant(drawn: {inlet_valve => 2.5},
    #                     pushed: {relief_valve => 3.1},
    #                     rejected: {relief_valve => 0.9}) }

  PHASE 2c — APPLY    (all mechanisms, order-independent)
    result = mechanism.apply(state, ctx, grant)
    #  the vessel keeps the 0.9 it could not push. Matter is conserved.
    #  the vessel KNOWS it was rejected -> can emit an event, drive a gauge.
```

**Pros:**
- Conservation is exact and auditable — you can write a spec asserting total mass is
  invariant, which is the strongest possible guard against this whole class of bug.
- Order-independence survives: `settle` is a pure function of the full intent set.
- Arbitration becomes **explicit and tunable** rather than an accident of `clamp`.
  Priority — "the relief valve gets capacity before the production line" — becomes
  expressible, which is real game design surface.
- Rejection is a first-class, observable event. Findings #2 and #3 both close.

**Cons:**
- Mechanisms gain a second entry point. `plan`/`apply` is more ceremony than `step`, and
  a mechanism whose plan depends on its own would-be result gets awkward.
- The arbiter is new shared machinery that must be got right once.
- Two passes over all mechanisms per tick instead of one. Irrelevant at this scale.

**Tradeoff:** you pay one extra concept (the arbiter) to keep order-independence *and*
gain conservation. The alternative — sequential push — is simpler to write and gives up
both order-independence and fair arbitration.

I think the arbiter is worth it, chiefly because "total mass in = total mass out" is a
test you can actually write, and no amount of careful sequential code gives you that.

---

## 5. Interfaces as nodes: adopt, drop the flag, and watch the latency

### The good part

> If they are just another mechanism, then THEY get to be a really common place for
> control points […] it also makes intuitive sense — the fitting / pipe between your
> chemical tank is where you would want to put a control valve.

This is right, and it is more than ergonomics. Today `ControlPoint` has a `mechanism:`
field that is *never read* — control values are looked up by control-point id, not routed
to a mechanism. Levers are effectively global to the operation. Putting them on interfaces
gives them a real, local home, and "joins are where systems fail" is true of actual plants.

**Drop the flag, though.** `"just another mechanism with a flag set"` describes two types
wearing one class. You do not need the flag: an interface *is* a mechanism with one inlet,
one outlet, and a throughput limit. That is a subclass — `Conduit < Mechanism` — and it
needs no discriminator. Anything that wants to ask "is this an edge?" is asking the wrong
question; it should ask "what are your inlets and outlets?"

### The cost you have not accounted for

Under §1's rule — one tick per hop — inserting interfaces as nodes **multiplies latency by
the number of nodes inserted**.

| Topology | Nodes, feed → turbine | Hops | Latency @ 4 Hz |
|---|---|---|---|
| Current (delay 2,1 configured) | 3 | 2 + configured 3 | 1.25 s to gauge |
| Delays deleted, no interfaces | 3 | 2 | 0.50 s |
| + one interface per join | 5 | 4 | 1.00 s |
| + inlet *and* outlet valve per mechanism | 8 | 7 | 1.75 s |

The last row is the version your text implies — a mechanism with an outlet interface for
gas and another for liquid, an inlet fitting on the receiver, and so on. Nearly two
seconds from lever to visible effect, before minion lag (§7) and gauge lag are added. In a
game whose premise is decisions under time pressure, that is a design decision, not an
implementation detail.

**Mitigation, and I think this is the right rule:** a join becomes a node only when it is
*interesting* — it carries a control point, it can fail, or it restricts flow. A plain
weld is an edge, not a node. That keeps the graph honest without paying a tick for every
fitting. It does mean "is this join a node?" becomes a per-operation authoring decision,
which is a small ongoing cost and a large latency saving.

---

## 6. `Resource` owning its physics: adopt, with one correction and one relocation

### The correction: no mutation

> They tell the resource to run the temperature calcs and passes in pressure and they
> respond back by **mutating the state inside** the mechanism.

This one word would cost you determinism, snapshot/restore, and replay. All three rest on
state being frozen and functionally transformed. A `Resource` that mutates its container
is a write during the evaluation phase, which is exactly what the double buffer exists to
prevent.

The fix is free — make `Resource` what `Mechanism` already is: **behaviour and config, no
mutable state**, taking a state and returning a new one.

```ruby
module Resources::Water
  # pure. parcel in, parcel out. no mutation, no clock, no entropy.
  def self.equilibrate(parcel, pressure_pa:, joules:, dt:)
    # => { liquid_kg:, vapour_kg:, joules:, temperature_k: }
  end
end
```

Identical modelling power. You keep the invariant. The mechanism does
`state.merge(parcels: Resources.equilibrate(...))` and the phase boundary stays inside
`Resources`, exactly as you want.

### The relocation: substance properties are content, not code

Specific heat, molar mass, latent heat, phase boundaries, corrosivity coefficients, tags —
these are **per-substance data**, and [architecture.md §4e](architecture.md) already argues
that content data belongs in versioned YAML rather than in classes: diffable, rebalanceable
without a migration, validatable at boot.

```yaml
# content/resources/water.yml
water:
  tags: [liquid, coolant, moderator, corrosive_when_hot]
  specific_heat_j_per_kg_k: 4181
  latent_heat_j_per_kg:     2257000
  phase:
    model:  antoine          # ← names a code module
    vapour: steam
```

So: **data in YAML, one shared phase/chemistry model in code, tags select which model
applies.** Adding a new coolant is a YAML file. Adding a new *kind of physics* is a module.
That is the modularity you asked for — "players tinker by trying a different mix of
chemicals" becomes a data change.

### On phase transitions specifically

You offered to skip a general phase system if it can be handled in the mechanisms that care.
I would take the opposite side, narrowly: **a single shared saturation model is less work
than two bespoke ones**, and you have already named two systems that need it (BWR void
coefficient, chemical decomposition points). The general version is roughly "given
pressure and enthalpy, split the parcel," which is one function. What I would *defer* is
everything beyond it — no multi-component distillation, no non-equilibrium kinetics.

**Pro:** void coefficient becomes expressible, which is the single most interesting
feedback loop in the whole game concept — and it is a *positive* feedback loop, which is
where genuine tension lives.
**Con:** saturation tables are real work to get right, and wrong ones produce unstable
feedback that reads as a bug rather than as danger.

### On the heat-transfer maths

Your description — mass × specific heat weighted averaging toward equilibrium, scaled by a
lumped coefficient and dwell time — is the standard lumped-capacitance model and it is the
right level of fidelity. Two notes:

- Track **joules**, not temperature, as the stored state. Temperature becomes derived
  (`joules / heat_capacity`). Mixing two parcels is then addition rather than a weighted
  average, phase change is a subtraction, and conservation is checkable. Weighted-averaging
  temperatures directly loses energy whenever heat capacities differ.
- "Get partway to equilibrium based on the timescale" is exponential relaxation:
  `ΔQ = conductance × ΔT × dt`. Stable only while `conductance × dt < heat_capacity`.
  Which brings us to the tick length.

---

## 7. Tick length: the one place the proposal is numerically dangerous

> we could simply do a 1:1 or, more likely, some modification like saying each tick
> represents 5 or 10 seconds

Three separate problems, and they are worth separating:

1. **It conflates simulated time with wall-clock time.** The architecture is 4 Hz
   wall-clock. If a tick is 10 simulated seconds, the game runs at 40× real time. That may
   well be what you want — thermal transients take minutes and nobody wants to watch them
   — but it should be a stated design decision, not a consequence of a constant.

2. **Explicit Euler goes unstable at large `dt`.** Every rate in the sim is currently
   `rate × dt`. At `dt = 10`, the vessel's coolant term removes `64 × 10 = 640 K` in a
   single step — it will overshoot, oscillate, and can go negative. Stiff thermal systems
   with feedback (a void coefficient is feedback) are exactly where this bites hardest. You
   would be tuning coefficients to suppress numerical artefacts and mistaking them for
   physics.

3. **Every existing constant is calibrated to `dt = 0.25`** and would need rescaling by 40×.

### Sketch: decouple the two, and substep

```ruby
TICK_WALL_SECONDS = 0.25    # unchanged: 4 Hz, non-negotiable per the brief
TICK_SIM_SECONDS  = 10.0    # time compression, a game-design dial
SUBSTEPS          = 40      # integration steps per tick
SUBSTEP_DT        = TICK_SIM_SECONDS / SUBSTEPS   # 0.25 s — numerically safe

def step!(dt: TICK_SIM_SECONDS)
  SUBSTEPS.times { integrate(SUBSTEP_DT) }   # physics
  publish                                     # once per tick — I/O unchanged
end
```

**Pros:** any time compression you like, with an integrator that stays stable; commands and
telemetry still land once per wall-clock tick; `SUBSTEPS` becomes the single knob trading
CPU for stability.
**Cons:** 40× the physics work per tick (still trivial for four mechanisms; **not** trivial
for a per-channel RBMK — measure before committing), and "one tick" stops being one
integration step, which is a small conceptual cost when reading traces.

**Alternative if substepping proves too slow:** switch the thermal terms from explicit
Euler to their closed-form exponential (`T → T_eq + (T − T_eq)·e^(−k·dt)`), which is
unconditionally stable at any `dt` and costs one `exp` per term. It only works for terms
that are genuinely first-order relaxation, which most heat transfer is. Worth knowing as
the escape hatch.

---

## 8. Tag routing is the best idea in the proposal

> a pressure relief mechanism might have an outlet interface for liquid resources and a
> different one for gas […] a centrifuge might have one outlet for denser materials and one
> for lighter […] it would let us describe any complex system as a series of much simpler
> pipelines.

Adopt this without modification. It is the resource/port contract that
[architecture.md §7](architecture.md) deliberately deferred, and it arrived from exactly
where the plan predicted it would — from trying to build a second and third mechanism.

It is load-bearing for the modularity goal in a way nothing else here is: swapping parts
only works if compatibility is *declarative*. Tags make "will this pipe accept my output?"
a data question.

```ruby
class Separator < Mechanism
  outlet :vapour_line, accepts: %i[gas]
  outlet :drain,       accepts: %i[liquid]
  outlet :blowdown,    accepts: %i[solid dissolved]     # first match wins
end
```

**One caution:** a parcel that matches several outlets needs a deterministic tie-break.
Ordered rules with first-match-wins is the simple answer and it is the one to take —
"most specific wins" is a rabbit hole and hash-order-dependent matching would break
determinism outright.

---

## 9. Minions: adopt, but they threaten command idempotence

> if you tell that pixie to open their valve that was set to 0% open to 85% open, they may
> only be strong enough to move it by 15% per turn

This is good design and it fits naturally. But it collides with the invariant the entire
Kafka ingress rests on, and the collision is avoidable only if you know about it in advance.

Today `set_control(85)` writes an absolute value. Redelivery is a no-op — which is why the
runner can commit offsets *after* snapshotting, why replay works, and why there is no dedup
table anywhere. [Scenario D](mechanism_pipeline_thoughts.md) verifies this by digest.

The failure mode: if a command means *"the minion attempts a move"*, then applying it twice
attempts two moves, and if the attempt consumes RNG then replay diverges. Idempotence dies,
and with it offset-after-snapshot, replay, and crash recovery.

**The constraint that keeps everything working:**

```ruby
# COMMAND — absolute, idempotent, applied at the barrier. Touches only the target.
{ type: "set_control", control_point_id: "relief_valve", value: 85 }
#   => state[:controls][:relief_valve][:target] = 85.0

# TICK — the minion converges toward target. Deterministic, seeded, inside step!.
#   actual += clamp(target - actual, -rate, +rate)   where rate = f(minion, valve)
#   mishaps roll from the minion's own named RNG stream, DURING the tick
```

Commands set **targets**; minions move **actuals**; all minion entropy is drawn inside
`step!` from a named stream, never during `apply`. Delivering "target = 85" twice remains a
no-op. Every existing guarantee survives.

**Second-order cost:** minions add another latency layer on top of hop count (§5) and gauge
delay. A stiff valve at 15%/tick is ~6 ticks to traverse its range — 1.5 s at 4 Hz, or far
more in compressed sim-time. Combined with a 7-hop topology, lever-to-gauge could reach
3–4 seconds. That is very possibly the game you want, but it needs a deliberate latency
budget rather than being the sum of three independently-reasonable decisions.

---

## 10. `Diagnostic` is too fat — agreed, but subclasses are the wrong shape

You are right that the base class is doing too much, and the trace proves it: `pegged?`
has no callers, every gauge pays for a `history` array even at `delay: 0`, and an
indicator lamp would inherit noise and delay it can never use.

**But a subclass tree is the wrong decomposition.** The properties compose:
noisy, lagged, quantised, peggable, sticky, broken. A subclass per combination is
`NoisyLaggedPeggableGauge` and there are 2ⁿ of them.

### Sketch: source + filter pipeline

```ruby
Diagnostic.new(
  id:      :vessel_temp,
  source:  Sources::Field.new(:vessel, :temperature_k),
  filters: [ Filters::Lag.new(2),
             Filters::Noise.new(1.5),
             Filters::Range.new(273, 873) ],   # reports :pegged alongside the value
  display: Displays::Needle.new(unit: "°C", precision: 1)
)

# an indicator lamp, same base class, no ceremony:
Diagnostic.new(
  id:      :coolant_low,
  source:  Sources::Field.new(:vessel, :coolant_kg),
  filters: [ Filters::Threshold.new(below: 50) ],
  display: Displays::Lamp.new(colour: :amber)
)
```

Base class shrinks to exactly your specification: take input from somewhere, produce a
display. Each filter is a tiny stateful transform with its own `initial_state`.

This closes three trace findings at once, which is why I would prioritise it:

- **Finding #5** (gauges can only read one scalar off one mechanism) → `Sources::BufferLevel`,
  `Sources::Rate`, `Sources::Derived` become possible. The steam line that silently kills
  the player in Scenario B becomes observable.
- **Finding #3** (`pegged?` unreachable) → `Filters::Range` emits it as part of the reading,
  so the display can show "≥600" instead of "600".
- **Finding #4** (noise defeats delta compression) → `Filters::Noise` can hold its offset
  until the underlying value moves by more than a deadband, so an idle gauge stops
  reporting changes. Currently 3–5 of 8 gauges "change" every tick on a completely idle
  machine.

**Con:** a filter chain is indirection, and a stack trace through five filters is less
obvious than one method. **Tradeoff:** worth it, because "upgrade your instrument" becomes
literally "remove a filter from the list," which is exactly the upgrade mechanic the
concepts document wants.

---

## 11. What the current architecture is actually good at

To be fair to what exists, since most of the above replaces it. Four properties are load-
bearing and **must survive any rewrite**, because everything in
[architecture.md §6 and §8](architecture.md) rests on them:

1. **Purity** — no clock, no ambient entropy, no Rails. Enforced by a spec that fails when
   violated (verified by deliberately breaking it three ways).
2. **Determinism** — seed + command log reproduces a match exactly. This is what makes
   crash recovery exact, replay nearly free, and spectating trivial.
3. **Order-independence** — proven, not assumed. §1 is an argument about protecting this.
4. **Command idempotence** — absolute values only. §9 is an argument about protecting this.

The proposal endangers 2 (mutation in `Resources`), 3 (topological order), and 4 (minions).
All three are avoidable at essentially no cost *if addressed now*, and expensive to retrofit
later. That is the main reason this review pushes back where it does — not because the
proposal's direction is wrong, but because these four properties are cheap to keep and
brutal to recover.

---

## 12. Recommended synthesis

Ordered by dependency, not by value.

1. **Delete `delay:` and the `transit` shift register.** Delay becomes hop count. (§1 —
   pure deletion, immediate mental-overhead win.)
2. **Kelvin and joules throughout.** Temperature derived from joules; display converts. (§3, §6)
3. **Durability replaces wear.** Sign flip, plus it becomes displayable. (§3)
4. **Split `Buffer` four ways:** `Holds` concern, `Conduit` node, rejection, delete transit. (§2)
5. **`plan` / `settle` / `apply`.** Conservation becomes a spec you can write. (§4)
6. **Diagnostic → source + filters + display.** Closes findings #3, #4, #5. (§10)
7. **Tag-routed inlets/outlets.** The port contract. (§8)
8. **`Resources` as pure modules + YAML content**, with one shared saturation model. (§6)
9. **Substepping**, once thermal fidelity actually needs a longer tick. (§7)
10. **Minions**, with commands constrained to setting targets. (§9)

Steps 1–3 are nearly free and independently valuable. Steps 4–5 are the real work and
should land together — half of that change is worse than either end of it. Steps 6–8 are
where the modularity payoff arrives. 9–10 can wait.

**One process note.** The determinism, purity, and order-independence specs are the only
reason this rewrite is safe to attempt at all. Keep them green at every step; if a step
requires turning one off, that step is the one to think hardest about.

---

## 13. Questions I need answered before going further

Rather than guess at your intent:

1. **Closed loops — confirm or deny.** Will operations have recirculating loops (condenser
   → feedwater → boiler → turbine → condenser)? My §1 argument leans hard on "yes." If
   every operation is genuinely a DAG, topological resolution becomes defensible and I
   would soften that section considerably.

2. **Time compression.** Is 1 tick = 5–10 simulated seconds meant to coexist with the 4 Hz
   wall clock — i.e. the game runs at 20–40× real time? Or did you mean slowing the tick
   rate, which would contradict the realtime requirement?

3. **Conservation strictness.** Must mass and energy balance exactly (making "total in =
   total out" a spec), or is approximate conservation acceptable where the player cannot
   audit it? This is the whole justification for the arbiter in §4 — if approximate is
   fine, sequential push is meaningfully simpler.

4. **Is durability visible?** A displayable integrity readout changes the game a lot: it
   converts "the machine failed and I didn't see it coming" into a managed resource. Both
   are defensible; they are different games.

5. **Target operation size.** Roughly how many nodes should the largest operation have —
   ten, or an RBMK modelled per-channel at several hundred? This decides whether
   substepping and per-tick projection are free or need budgeting, and it is the one number
   that would change my performance advice.

6. **Interfaces: every join, or only interesting ones?** §5 shows this is worth ~1 second
   of lever-to-gauge latency. I have assumed "only interesting ones" — joins with a control
   point, a failure mode, or a flow restriction. Confirm, because it changes the topology
   of every operation.
