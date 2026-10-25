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

### The sky over it

**Every operation with anything outdoors carries the sky as a fixture.** Three things, all
shared, so a new operation writes none of the weather itself:

1. A `Nodes::Outdoors` node (id `:outdoors`) built from `conditions:`. The builder and its
   `Operations.register` block take `conditions:` and put it in `options:`, so a restore rebuilds
   the same sky. Nil is the standard sky, which is what every spec gets.
2. `WeatherGauges.guesses(observer:)` among the fixture's diagnostics, observed by whoever works
   outdoors; `WeatherGauges.instruments` merged into the catalogue; `WeatherGauges::ORDER` at the
   end of `PANEL_ORDER`; `WeatherGauges.slot` in the slot list.
3. **`exposure:` on each place the weather reaches** — 1 for open ground, a fraction for a
   building, nothing underground. It shifts the ambient of every node in the place, offers the
   sky's light and its `wet`/`icy` footing to the people there, and lets the wind at them.

Rain reaches a holder through a `Nodes::Catchment` of the ground that drains to it.

### The people in it, and each other

**A crewed operation's builder and register block take `grudges:`** — who already hates whom from
earlier matches, by person — and put it in `options:` through `Animosity.carried_over`, beside
`crew:`. Then three declarations decide what a feud can do there:

1. **`openings:` on a post** (`Animosity::Opening`): what somebody stood there could do to
   somebody they hate — a mishap the part named can suffer, or a slip of their own lever — with
   who it `reaches:` and the `harm:` they believe it does. The colliery's banksman can send a tub
   down onto the cage or ring the cage away from a boarder; the hauling hands can loose a set; the
   shotfirer can leave a charge live for the hewers.
2. **`opportunity: true` on a peril**: somewhere a person can be pushed — in front of a tub, into a
   belt, off the deck — while it is live.
3. **`oversees:` on a post** makes it a boss's: whoever stands there may step into a quarrel in
   those places. The colliery sells one in a `supervision` slot that is empty by default.

A post with none of these still sees rows and brawls between whoever works it.

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

**Fixed plant is a load on the operation's line shaft; mobile plant carries its own engine.** A
shovel or a locomotive fits `MobileEngine.slots(engine, place:)` among the operation's slots and
gets a complete small steam engine under its own names, worked by a fireman and a driver
(`MobileEngine.driver(assembly, engine, place:)`, added to the control points after assembly). The
operation supplies the `Atmosphere`, the place the engine stands in — which breathes the atmosphere,
as its `air:` or as an `open_air:` place — and a drive link from `names.(:flywheel)` to whatever it
drives. Its routes are `MobileEngine.routes(engine, place:)`. A **steam shovel** is
`MobileEngine.shovel_slots` instead, and its host also gives it, by id, the bench it digs (a holder of
what is dug), the car it fills and the standpipe its tank is hosed from; `MobileEngine.board` is its
status in words for the panel. A **locomotive** is `MobileEngine.locomotive_slots(loco, place:,
track:, serves:, dump:)`: the host gives it a `Track` (sections with their places and grades, a
`loading` and a `dump` mark), the shovel it serves — whose `shovel_slots` then takes the train's cars
as its `car:` and its loading landing as `dumps_into:` — and the holder it is tipped into. Its driver
post is `MobileEngine.locomotive_driver(assembly, loco, place:, track:)` and its board
`MobileEngine.train_board`. `place:` is its footplate: the host puts the engine's nodes there, and the
train carries it. See `spec/support/mobile_rig.rb` for the smallest host of all three.

### 4. What can the player touch?

```ruby
ControlPoint.new(id: :throttle_open, label: "Throttle", node: :throttle, default: 0.0)
```

Nodes read `ctx.controls.fetch(:throttle_open)` — the lever's **actual** position. A control
point with `stiffness:` travels toward its target over several ticks; the default is
instantaneous. An **effort** station (`effort:`) reads as its position scaled by the crew posted
there, summed — **worker-equivalents**, 100 for one competent hand flat out — and nothing at all
with nobody there. Rate its node **per worker**, and declare a conduit it works `worked: true`
with `crew:` set to the post's capacity, or the build refuses it. A **governor** post (`governor:`) drives other,
`internal:` levers from its own — the mine's winding engineman works the clutches and brake to
send the cage where the player names. See [`operations/CLAUDE.md`](../../lib/reactor_sim/operations/CLAUDE.md).

### 5. What can the player see?

The interesting design work. See [`../reference/diagnostics.md`](../reference/diagnostics.md).
Give the two things that will kill the player the best instruments — and even those late.

---

## Crew

**Jobs come from the machine; hands come from the player, and the gap between them is the game.**

```ruby
stations = control_points.select(&:effort?)   # what needs doing — DERIVED, never declared
assembly.crew_capacity                        # what you can bring — from the fitted quarters
assembly.advance_shifts                       # who starts elsewhere — [{ seats:, place: }], slot order
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

Things to know:

- **Nobody starts at a working station, and it has to stay that way.** A machine that lets an
  effort station be a starting post hands the player a shift already at the face for free — which
  for a mine is most of the operation given away. Deploying the shift is the opening move.
- **A seat may start in a different PLACE, which is a different statement.** The mine's shift
  parts start the last seats in the district and at the pit bottom with **no station at all**:
  they are somewhere useful and still posted to nothing, so the opening move is still the
  player's. Without them a spatial operation's first five minutes are a walk. Build it the same
  way — a fitted part declaring `stats: { advance_seats:, advance_place: }`, read by
  `assembly.advance_shifts` in slot order and dealt onto `place:` on the `Minion` at build, never
  by the roster. Being a part is what lets a player buy a bigger head start.
- **A station has room for so many, and their work sums.** `capacity:` on a `ControlPoint` is how
  many people may be posted there, and `assign_minion` refuses past it exactly as it refuses a
  posting nobody can walk to. **A lever defaults to one**; a part with room for a gang says so —
  as a `crew:` stat, passed by its fragment to both the post and the node — and an upgrade raises
  it. A post with no `node:` (quarters, a rest post) defaults to no limit. **A governor post holds
  one**, refused at build. Counted over `posting`, so the refusal lands when the order is given
  rather than on arrival.
- **Size what is downstream of a gang, or don't.** A worked conduit caps nothing but its crew; if
  the next fitting cannot take what a strong gang moves, the work backs up there, which is the
  player's allocation problem and not a cap to add.
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

To sell one operation's work to another, rope a `Load` in one to an `Import` (or any rope end) in
the other:

```ruby
couplings: [ { from: [ :engine, :load ], to: [ :pit, :line_shaft ], ratio: 0.78 } ]
```

`ratio:` is the `from` end's speed per unit of the `to` end's. `stiffness:` is optional and
defaults to what the `to` end declares; past either end's own `I/dt` the rope rings and `Match`
refuses it. Both operations must share a `time_scale`. The rope is felt at both ends — see
[`physics.md`](../reference/physics.md#a-rope-between-operations).

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

**The first chassis in `CHASSIS` is the default**, so order the hash starting machine first. The
mine starts on `single_shaft` — one shaft carrying both halves of the air, split by a brattice
slot, so whatever chokes it traps the shift — and `two_shaft` is the upgrade that brings a second
way out.

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

Five rules that are easy to get wrong:

- **`provides:` names the ids the part must build, and the id belongs to the role.** Every
  boiler names its drum `:boiler`, so the wiring, the gauges and the rng stream survive a swap.
- **`when_empty: :omit` needs no machinery** — an unfitted part contributes no fragment, so its
  links leave with it. Only `:bypass` has to declare where the two ends are.
- **A part in a `:bypass` run should be a conduit**, not a holder. A conduit is resolved
  through and costs no tick; a holder costs one tick per hop, so fitting one silently re-times
  the machine and moves every balance number.
- **Slot order is the panel's lever order**, so order it by the cab. Instruments come from the
  panel catalogue in *its* order instead, so reordering slots cannot move the dials.
- **One fitting shapes another's wiring only through `informs:`.** A part builder sees the spec,
  never the loadout. A slot declares the spec keys its fitting may set
  (`Slot.new(id: :dumb_drift, …, informs: %i[furnace_fed_from])`), the part sets their values
  (`Parts.register(:dumb_drift, …, informs: { furnace_fed_from: :intake })`), and `Assembly` folds
  them into the spec before any slot builds, so build order cannot matter. A key a slot does not
  allow, or two slots informing one key, refuses the build. It reaches part builders and not the
  chassis fixtures. The mine's dumb drift telling its furnace where its air comes from is the
  first case.

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
