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
or it restricts flow. A plain weld is an edge and costs nothing.

*Delay is one tick per hop*, and **a hop is one `Path`: holder to holder.** A `Conduit` is a
transport node — it is resolved *through* rather than stopped at — so a valve or a length of
pipe costs no latency at all. Every node that actually **holds** material adds 250 ms at
`time_scale` 1, so that is the count to keep down.

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

**Jobs come from the machine; hands come from the player, and the gap between them is the game.**

```ruby
stations = control_points.select(&:effort?)   # what needs doing — DERIVED, never declared
assembly.crew_capacity                        # what you can bring — from the fitted quarters
```

Your operation declares **no roles at all**. It declares a slot that accepts `:crew_quarters`,
and the part fitted there says how many seats there are and where they start:

```ruby
Slot.new(id: :quarters, accepts: :crew_quarters, label: "Crew Quarters",
         required: true, default: :mess_room)

Parts.register(:mess_room, kind: :crew_quarters, label: "Mess Room",
               stats: { crew_capacity: 2, recovery_rate: 2.0 }) do |_spec|
  Fragment.new(control_points: [ ControlPoint.new(id: :quarters, label: "Crew Quarters",
                                                  recovery: Fatigue::BASE_RECOVERY * 2.0) ])
end
```

`Crew.seats(capacity)` then gives `[:crew_1, :crew_2]`, and `Assembly#crew_origin` gives the
station they all start at. Where they *are* lives in `state[:minions]`, because assignment is a
command (`assign_minion`, absolute and idempotent like `set_control`).

Five things to know:

- **Nobody starts at a working station, and it has to stay that way.** A machine that lets an
  effort station be a starting post hands the player a shift already at the face for free — which
  for a mine is most of the operation given away. Deploying the shift is the opening move.
- **A crew quarters builds no node.** It is a *place*, and a place is a `ControlPoint` with no
  `node:` — `ControlPoint#lever?` is what keeps it off the lever strip while leaving it on the
  crew screen. Do **not** write `provides: %i[quarters]`: `provides:` names NODE ids, and node,
  lever, instrument and minion ids share one namespace, so that is a duplicate-id build error.
- **Ids are one flat namespace** with nodes, control points and diagnostics, because they key one
  RNG table. `validate_graph!` refuses a duplicate. Seats are `crew_1`, `crew_2` precisely so
  they cannot collide with machinery — the natural name for a steam engine's fireman is `stoker`,
  which is already the conduit feeding the firebox.
- **An unmanned effort station delivers nothing**, and so does one manned by somebody spent —
  `capability` reaches exactly zero at `fatigue` 1.0. Neither is wired; both simply follow.
- **The roster rides in `options:`**, like the loadout, or a restored snapshot rebuilds a
  different crew. A roster naming more seats than the fitted quarters has is **refused**, never
  truncated.

---

## Registering it

```ruby
module ReactorSim
  module Operations
    module MyOperation
      TYPE = :my_operation

      module_function

      def build(id:, seed:, time_scale: 1.0, state: nil, rngs: nil, content: nil,
                chassis: :basic, loadout: {})
        spec = CHASSIS.fetch(chassis.to_sym)
        assembly = Assembly.new(slots: slots(spec), loadout:, spec:,
                                fixtures: fixtures(spec), instruments: catalogue(spec),
                                routes: ROUTES, advisories: ADVISORIES)
        fragment = assembly.build!

        Operation.new(id:, type: TYPE, seed:, time_scale:, state:, rngs:, content:,
                      # The RESOLVED loadout, not the one passed in — see below.
                      options: { chassis: chassis.to_sym, loadout: assembly.loadout },
                      nodes: fragment.nodes, links: fragment.links,
                      thermal_links: fragment.thermal_links,
                      drive_links: fragment.drive_links,
                      control_points: fragment.control_points,
                      diagnostics: assembly.diagnostics)
      end
    end

    # Two different `chassis:` here, deliberately. The one on `register` is the ENUMERATION —
    # which frames this type offers — and the one in the block is the frame that was chosen.
    # Pass `CHASSIS.keys`, never a literal list: the enumeration exists so the delivery tier can
    # ask what a machine can be built on (every chassis is separately unlockable), and a
    # hand-written copy drifts the first time somebody adds a frame.
    register(MyOperation::TYPE,
             chassis: MyOperation::CHASSIS.keys) do |id:, seed:, time_scale: 1.0, state: nil,
                                                     rngs: nil, content: nil,
                                                     chassis: :basic, loadout: {}|
      MyOperation.build(id:, seed:, chassis:, loadout:, time_scale:, state:, rngs:, content:)
    end
  end
end
```

`Operations.chassis_for(:my_operation)` reads it back. It is introspection and nothing on the
tick path touches it; a builder still takes `chassis:` as an ordinary option and still raises on
a frame it does not know. A type with only one frame may leave it out and the answer is an empty
list, which is a real answer rather than a missing one.

Then require it from `lib/reactor_sim.rb`, last (operations depend on everything) — the
definition, then the parts, then the panel.

```ruby
ReactorSim::Match.create(
  id: "m1", seed: 42,
  operations: [ { id: "op", type: :my_operation, chassis: :basic } ]
)
```

Extra keys in the spec hash are passed through to the builder. **Anything that changes the
graph's shape must also be in `options:`**, or a restored snapshot rebuilds the wrong machine.

Three ways that goes wrong, each of them silent, and all three have bitten:

- **Symbols as values do not survive JSON.** `deep_symbolize` converts keys only, so a loadout
  comes back as `{ boiler: "stock_boiler" }` and misses every `Parts.fetch`. Assert it with
  `be`, never `eq` — `canonical` runs through `JSON.generate`, where the two are the same
  string, so a digest round-trip spec passes with the bug present.
- **Store the resolved loadout, not the given one.** `Assembly#loadout` names every slot,
  including the empty ones, because a slot left deliberately empty and one nobody mentioned
  must not look the same on restore — otherwise the missing part quietly grows back.
- **The `register` block whitelists its keywords.** An option it does not name raises at
  restore. Loud, which is right, but `options:` and that signature have to move together.

---

## Chassis and loadout: one operation, several machines

The steam engine is deliberately two machines from one definition — Watt's atmospheric engine
and Trevithick's high-pressure engine — differing only in what the cylinder exhausts into and
a few sizes. Since 2026-09-13 that is one of **two** axes.

**A chassis is the frame**: the fixed topology, and which slots exist on it.

```ruby
CHASSIS = {
  atmospheric:   { exhausts_to: :condenser,  condenser: true,  relief_pa: 1.4 * ATM, ... },
  high_pressure: { exhausts_to: :atmosphere, condenser: false, relief_pa: 6.0 * ATM, ... }
}.freeze
```

`slots(spec)` and `fixtures(spec)` branch on `spec.fetch(:condenser)`. The exhaust link lives
in `fixtures` rather than in a slot deliberately: fitting a condenser does not add a branch, it
**reroutes** the exhaust, and "absent means rerouted" is a frame decision rather than a fitting.

**A loadout is what is bolted to it.** Each part registers a builder returning a `Fragment` —
its nodes, its links, its levers — plus the ids it promises and the gauges that arrive with it.

```ruby
Parts.register(:ramsbottom_safety_valve, kind: :safety_valve, provides: %i[relief],
               instruments: %i[safety_valve valve_setting_pa]) do |spec|
  Fragment.new(nodes: [ ... ], links: [ ... ], control_points: [ ... ])
end

Slot.new(id: :safety_valve, accepts: :safety_valve, required: false, when_empty: :omit,
         default: :ramsbottom_safety_valve)
```

Four rules that are easy to get wrong:

- **`provides:` names the ids the part must build, and the id belongs to the role.** Every
  boiler names its drum `:boiler`, so the wiring, the gauges and the rng stream survive a swap.
- **`when_empty: :omit` needs no machinery** — an unfitted part contributes no fragment, so its
  links leave with it. Only `:bypass` has to declare where the two ends are.
- **A part in a `:bypass` run should be a conduit**, not a holder. A conduit is resolved
  through and costs no tick; a holder costs one tick per hop, so fitting one silently re-times
  the machine and moves every balance number.
- **Slot order is the panel's lever order**, so order it by the cab. Instruments come from the
  panel catalogue in *its* order instead, so reordering slots cannot move the dials.

This is the test the architecture was built to pass: if two machines that look nothing alike
are the same definition with parts swapped, the abstractions are right.

Full design, including the options weighed and rejected:
[`../design_sketches/modular_components.md`](../design_sketches/modular_components.md).

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

**Read the lever in the units the physics uses, not in lever percent.** The steam engine's
stoking looked like a mysterious inversion — more coal, less power, everywhere — and as kg/s it
was a ratio anyone could check: the fire establishes at ~0.12 kg/s of coal and can usefully burn
~0.15, and the stoker was rated 0.6. The entire useful band sat below lever 25.

**Before tuning a constant, check it is on the path that decides the thing.** The cheapest
possible test is to set it to three different values and see whether anything moves. Four
constants in this engine turned out to be inert — the damper's and the cocks' rate caps sit
beside a `conductance` and never bound anything — and one of them had a comment above it
confidently explaining what it did. **Delete a dead constant rather than documenting it as
dead**; a number that looks tunable and is not will be cited as fact by the next reader.

**Check the system is not saturated before concluding a mechanic does nothing.** A boiler sitting
on its safety valve reports every upstream change as zero, which is indistinguishable from a
lever that is not wired up. The ash choke measured as a 0.23% *inversion* at one damper setting
and a genuine 4.4% recovery at another, with the mechanic unchanged.

**And check which part the safety device is actually protecting.** The steam engine's safety
valve was not protecting its boiler; it was capping power before the *flywheel* failed. Raising
it burst the wheel every time, with the drum never reaching the new setting.

---

## Specs an operation should have

Copy the shape of `spec/reactor_sim/steam_engine_spec.rb`:

1. **It starts** — from cold, following the real operating procedure.
2. **It makes output** — and more output when driven harder.
3. **It fails the way it should** — with the right event type and detail.
4. **Moderate settings survive** a long run with no events.
5. **Conservation holds** — mass and energy balance to `< 1e-9` relative.
6. **Snapshot round-trip** preserves the chassis, the loadout and the digest — and asserts the
   loadout's part ids with `be`, not `eq`.

The conservation spec is the one that catches real physics bugs. Write it early.
