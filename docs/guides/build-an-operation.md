# Building an operation

An **operation** is one overseer's machine: a graph of nodes, the levers they pull, and the
instruments they read. `Operations::SteamEngine` is the worked example — read
`lib/reactor_sim/operations/steam_engine/definition.rb` alongside this.

Prerequisites: [`../reference/invariants.md`](../reference/invariants.md) and
[`../reference/nodes.md`](../reference/nodes.md).

---

## What an operation is made of

```ruby
Operation.new(
  id:, type:, seed:,
  nodes:          [...],   # the machinery
  links:          [...],   # where material flows
  thermal_links:  [...],   # where heat conducts
  drive_links:    [...],   # where torque is transmitted
  control_points: [...],   # the levers
  diagnostics:    [...],   # the instruments
  minions:        [...],   # who stands at the levers
  time_scale:     1.0,     # simulated seconds per wall tick, ÷ 0.25
  options:        {},      # builder config that must survive a snapshot
  content:        nil,     # defaults to Content.default
  state:, rngs:            # only on restore
)
```

**Operation configuration is code, not data.** Only *state* is serialised; the graph is
rebuilt identically every time from the registered builder. That is what lets a snapshot be
a bag of floats rather than an object graph.

---

## The five decisions, in order

### 1. What are the nodes?

Work backwards from what the player is managing. Each node is something that holds material,
moves it, transforms it, or spins.

**A join earns a node only when it is interesting** — it carries a control point, it can fail,
or it restricts flow. A plain weld is an edge and costs nothing. This matters because *delay
is one tick per hop*: every node you insert adds 250 ms of lag at `time_scale` 1.

Reach for stock nodes first (`Vessel`, `Conduit`, `Atmosphere`, `Flywheel`, `Load`,
`ReliefValve`, `Cylinder`). Write a new one only when the behaviour genuinely does not exist.

### 2. How are they wired?

```ruby
Link.new(from: [ :boiler, :steam_out ], to: [ :throttle, :inlet ])
```

Give ports tags so incompatible things cannot flow: `accepts: [:gas]`, `[:liquid]`, `[:fuel]`.
Tags govern **transport**, not existence — steam condensing inside a gas-only pipe is correct
and expected.

Closed loops are fine and need no special handling. The steam engine's condenser → hotwell →
supply → boiler loop is exactly the topology a topological sort could not have ordered.

### 3. Where does heat go, and torque?

```ruby
ThermalLink.new(a: :firebox, b: :boiler, conductance: 9_000.0)   # W/K
DriveLink.new(a: :flywheel, b: :load, stiffness: 9_000.0)
```

Every `Thermal` node also needs an `ambient_conductance` or the operation becomes a perfect
heat accumulator. Waste heat is not optional — it is what makes conservation cheap *and*
physically sensible.

### 4. What can the player touch?

```ruby
ControlPoint.new(id: :throttle_open, label: "Throttle", node: :throttle, default: 0.0)
```

Nodes read `ctx.controls.fetch(:throttle_open)` — the lever's **actual** position. A control
point with `stiffness:` travels toward its target over several ticks; the default is
instantaneous. Work stations (shovelling, stoking) are ordinary control points today; minions
will drive `actual` later without anything else changing.

### 5. What can the player see?

The interesting design work. See [`../reference/diagnostics.md`](../reference/diagnostics.md).
Give the two things that will kill the player the best instruments — and even those late.

---

## Crew

```ruby
Minion.new(id: :fireman, archetype: :fireman, station: :stoking)
```

The archetype names an entry in `content/minions/`; `station:` is the lever they start at.
Where they *are* lives in `state[:minions]`, because assignment is a command
(`assign_minion`, absolute and idempotent like `set_control`).

Three things to know:

- **Ids are one flat namespace** with nodes, control points and diagnostics, because they key
  one RNG table. `validate_graph!` refuses a duplicate. The natural name for a steam engine's
  fireman is `stoker` — which is already the conduit feeding the firebox, so it is `:fireman`.
- **A crew only matters if a lever has finite `stiffness`.** The default is
  `Float::INFINITY`, which snaps `actual` to `target` and discards the minion's rate entirely.
  Giving a work station a finite stiffness is what makes minion condition felt — and it shifts
  the machine's skill gradient, so re-measure it.
- **A fixed roster stays out of `options:`**, because it is rebuilt from code like the node
  list. The moment a crew can be hired, injured or dismissed it must move into `options:`, or
  a restored snapshot rebuilds a different crew — the same trap `variant:` is there to avoid.

---

## Registering it

```ruby
module ReactorSim
  module Operations
    module MyOperation
      TYPE = :my_operation

      module_function

      def build(id:, seed:, time_scale: 1.0, state: nil, rngs: nil, content: nil, variant: :basic)
        Operation.new(id:, type: TYPE, seed:, time_scale:, state:, rngs:, content:,
                      options: { variant: variant },
                      nodes: nodes(variant), links: links(variant),
                      thermal_links:, drive_links:,
                      control_points:, diagnostics: diagnostics(variant))
      end
    end

    register(MyOperation::TYPE) do |id:, seed:, time_scale: 1.0, state: nil, rngs: nil, variant: :basic|
      MyOperation.build(id:, seed:, variant:, time_scale:, state:, rngs:)
    end
  end
end
```

Then require it from `lib/reactor_sim.rb`, last (operations depend on everything).

```ruby
ReactorSim::Match.create(
  id: "m1", seed: 42,
  operations: [ { id: "op", type: :my_operation, variant: :basic } ]
)
```

Extra keys in the spec hash are passed through to the builder. **Anything that changes the
graph's shape must also be in `options:`**, or a restored snapshot rebuilds the wrong machine.

---

## Variants: one operation, several machines

The steam engine is deliberately two machines from one definition — Watt's atmospheric engine
and Trevithick's high-pressure engine — differing only in what the cylinder exhausts into and
a few sizes.

```ruby
VARIANTS = {
  atmospheric:   { exhausts_to: :condenser,  condenser: true,  relief_pa: 1.4 * ATM, ... },
  high_pressure: { exhausts_to: :atmosphere, condenser: false, relief_pa: 6.0 * ATM, ... }
}.freeze
```

`nodes(spec)` and `links(spec)` then branch on `spec.fetch(:condenser)`. This is the test the
architecture was built to pass: if two machines that look nothing alike are the same
definition with parts swapped, the abstractions are right.

---

## Getting it to actually run

Expect several rounds. A new operation almost never works first time, and the failures are
informative. Drive it from a scratch script, not a spec, until it behaves.

```ruby
op = ReactorSim::Match.create(id: "t", seed: 42,
       operations: [{ id: "op", type: :my_operation }]).operation(:op)
{ lever: 60, other: 40 }.each { |k, v| op.set_control(k, v) }
(1..2000).each do |t|
  events = op.step!(tick: t)
  puts op.telemetry.inspect if (t % 100).zero?
  break unless events.empty?
end
```

`op.telemetry` is raw truth, bypassing instruments — for debugging only, never for a client.

### Symptoms and their usual causes

| Symptom | Look at |
|---|---|
| A node fills forever and never empties | Downstream port tags reject what it holds, or nothing draws from it |
| Something drains its source to nothing | A conduit drawing more than it can discharge |
| Pressure exceeds the thing supplying it | Missing gas headroom cap, or a sink that cannot refuse |
| A vessel never fills from a low-pressure source | The receiver reports 1 atm because it holds *something* — check for stale contents |
| A reaction never fires | `min_temperature_k` unreachable, or a reagent is being drained before it can react |
| Fire/heat source dies when the igniter stops | Excess air or a thermal link draining more than the source produces |
| A rotating part bursts in one tick | `time_scale` too high for the machine, or the driven inertia is too small |
| Everything ruptures eventually | No relief path — a source does not know how fast it is being emptied |

### Balance is a sweep, not a guess

Sweep the two or three levers that matter and look for a **skill gradient**: settings that
survive indefinitely, settings that make far more output and then destroy the machine, and a
band between them. If every setting survives, there is no game; if none do, something is
missing (usually a safety device).

---

## Specs an operation should have

Copy the shape of `spec/reactor_sim/steam_engine_spec.rb`:

1. **It starts** — from cold, following the real operating procedure.
2. **It makes output** — and more output when driven harder.
3. **It fails the way it should** — with the right event type and detail.
4. **Moderate settings survive** a long run with no events.
5. **Conservation holds** — mass and energy balance to `< 1e-9` relative.
6. **Snapshot round-trip** preserves the variant and the digest.

The conservation spec is the one that catches real physics bugs. Write it early.
