# `operations/` — specific machines

An **operation** is one overseer's machine: a graph of nodes, the levers they pull, and the
instruments they read. Built from everything above it in the require chain, so these files
load last. `steam_engine/` is the worked example. Guide:
[`docs/guides/build-an-operation.md`](../../../docs/guides/build-an-operation.md).

## Operation configuration is code, not data

Only **state** is serialised; the graph is rebuilt identically every time from the registered
builder. That is what lets a snapshot be a bag of floats rather than an object graph.

**Anything that changes the graph's shape must be in `options:`** so it is snapshotted and
handed back on restore. The steam engine's `chassis:` and `loadout:` both do this. Miss it and
an atmospheric engine restores as a high-pressure one — a total, silent divergence.

Three ways that goes wrong, all of them silent:

- **Symbols as VALUES do not survive JSON.** `deep_symbolize` converts keys only, so a loadout
  arrives back as `{ boiler: "locomotive_boiler" }` and misses every `Parts.fetch`. That is not a
  nil, it is a different machine. Symbolise on the way in, and assert with `be`, never `eq` —
  `canonical` runs through `JSON.generate`, where the two are the same string.
- **A partial loadout re-defaults on restore.** `Assembly#loadout` names *every* slot, empty
  ones included, because a slot left deliberately empty and a slot nobody mentioned must not
  look the same to the builder.
- **The registered builder whitelists its keywords.** An option it does not name is an
  `ArgumentError` at restore. Loud, which is right — but `options:` and that signature have to
  move together.

## Assembled from parts

An operation is built from a **chassis** (the frame: fixed topology, which slots exist) and a
**loadout** (what is fitted in them). See
[`docs/design_sketches/modular_components.md`](../../../docs/design_sketches/modular_components.md).

```ruby
Parts.register(:id, kind:, provides: [], instruments: []) { |spec| Fragment.new(...) }
Slot.new(id:, accepts:, required:, default:, when_empty: :omit | :bypass, bypass: [...])
Assembly.new(slots:, loadout:, spec:, fixtures:, instruments:, routes:, advisories:)
```

- **A part contributes a `Fragment`** — nodes, links, thermal/drive links, control points —
  because a part is almost never one node. Its gauges are named by id and come from the
  operation's panel catalogue.
- **`provides:` is the id contract.** The id belongs to the **role**, not the part: every
  boiler names its drum `:boiler`, so the wiring, the gauges and the rng stream all survive a
  swap.
- **`when_empty:` is the only topology a slot declares.** `:omit` needs no machinery at all —
  an unfitted part contributes no fragment, so its links leave with it. Only `:bypass` has to
  know where the two ends are.
- **Slot declaration order is the panel's lever order.** Order it by the cab, not the graph.
  Instrument order comes from the panel catalogue instead, so reordering slots cannot move the
  dials.
- **Errors refuse a build; warnings do not.** An engine with no fusible plug is legal and is
  meant to be — the hazard under the safety is what makes going without one a decision.

> **Assembly runs once, at build, and must leave no trace in the tick.** No `Context` method
> may take a slot id; no node may ask what is fitted elsewhere. If it needs to know, the answer
> belongs in its own config, decided at build.

```ruby
Operation.new(
  id:, type:, seed:,
  nodes:, links:, thermal_links:, drive_links:,
  control_points:, diagnostics:,
  time_scale: 1.0,   # simulated seconds per wall tick ÷ 0.25
  options: {},       # builder config that must survive a snapshot
  content: nil, state:, rngs:   # last two only on restore
)
```

Register with `Operations.register(TYPE, chassis: CHASSIS.keys) { |id:, seed:, ...| ... }`, then
require it from
`lib/reactor_sim.rb` **last**. Extra keys in a `Match.create` operation spec are passed through
to the builder.

> **A spec rig registering an operation must pass `harness: true`.** It has to register globally
> or `Match.create` cannot resolve it — but something outside this library *derives a list of
> machines from this registry*, so an unmarked rig becomes a machine. `spec/support/loop_rig.rb`
> did, and it took the delivery tier's whole blueprint catalogue down with it — **only in a
> full-suite run**, because nothing else loads that file, so every targeted re-run of the failing
> specs passed. `Operations.known` is everything; `Operations.catalogued` is the machines.

## Design decisions, in order

1. **What are the nodes?** A join earns a node only when it is *interesting* — it carries a
   control point, it can fail, or it restricts flow. A plain weld is an edge and costs nothing.
   This matters because **delay is one tick per hop**, where a hop is a `Path` from one
   *holder* to the next — a conduit is resolved through and costs nothing. Every holder adds
   250 ms of lag at
   `time_scale` 1. Reach for stock nodes first.
2. **How are they wired?** Tag ports so incompatible things cannot flow. Tags govern
   *transport*, not existence — steam condensing inside a gas-only pipe is correct and
   expected. Closed loops are fine and need no special handling.
3. **Heat and torque.** Every `Thermal` node needs an `ambient_conductance` or the operation
   becomes a perfect heat accumulator.
4. **What can the player touch?** Nodes read `ctx.controls.fetch(:id)` — the lever's **actual**
   position. `stiffness:` makes a lever travel over several ticks. Work stations (shovelling,
   stoking) are ordinary control points today; minions will drive `actual` later without
   anything else changing.
5. **What can the player see?** The interesting design work. Give the two things that will
   kill the player the best instruments — and even those late.

## Chassis: one definition, several machines

The steam engine is deliberately two machines — Watt's atmospheric and Trevithick's
high-pressure — differing only in what the cylinder exhausts into and a few sizes. `slots(spec)`
and `fixtures(spec)` branch on the `CHASSIS` hash. (It was `VARIANTS`, and the keyword was
`variant:`; the concept did not change when the engine became assembled from parts, only what
it is now one axis of.)

**A chassis owns what a slot cannot express.** Fitting the condenser does not add a branch, it
*reroutes* the cylinder's exhaust — and "absent means rerouted" is a frame decision, not a
fitting. That link lives in `fixtures(spec)`.

**Pass `chassis: CHASSIS.keys` to `Operations.register`.** That is the *enumeration* — a second,
unrelated `chassis:` from the one the builder block takes, which is the frame that was chosen.
`Operations.chassis_for(type)` reads it back, and it exists because the delivery tier has to be
able to list what a machine can be built on: every chassis is separately unlockable
([`design_sketches/blueprints.md`](../../../docs/design_sketches/blueprints.md)). Derive it from
the hash, never write the list out — a copy drifts the first time somebody adds a frame, and it
drifts silently, because the new frame is simply unreachable. Nothing on the tick path reads it.

**A chassis owns topology and a default loadout, not numbers.** It used to be a flat bag of
twenty keys, seventeen of which belonged to six parts. Those live on the parts now, with the
sweeps that chose them; what is left is `exhausts_to`, `condenser` and a `parts:` map of the kinds
that differ between the two machines. **Topology and nothing else** — `burst_pa` was the last
holdout and it left on 2026-09-14, when the pressure gauge became a fitting of its own.

**An instrument can be a part, and `Fragment#diagnostics` is how.** Most parts *name* their
gauges by id and the panel holds the definitions, because the reasoning about why each gauge lies
is worth keeping in one readable file. A part that **is** an instrument has nowhere else to put
its full-scale reading or its lag — those are properties of the dial, not of the drum it is
screwed to — so it builds its own `Diagnostic`. The definition still lives in `panel.rb`; the
part passes it figures, exactly as a boiler part passes its shell thickness.

> **`PANEL_ORDER` decides where a gauge sits, and neither source may.** A player learns a panel by
> where things are, so fitting a better pressure gauge must not move the water glass.
> `Assembly` sorts by it and refuses a gauge it does not name, so the list cannot drift by
> omission.
>
> And the rule that governs instrument upgrades: **an upgrade may reduce a filter, never remove a
> class of one.** Less lag, less noise, a finer band — never zero lag, and never a number where
> the design chose prose. `safety_valve`, `crown_sheet` and `flywheel_condition` are exempt
> outright. The instruments are the game, not an obstacle in front of it.

> **An attribute becomes a node when it is a separate object in the machine, and a variant when
> it is a different version of the same object.** The blower was the first — a fan bolted to the
> ashpan, now `:blower_fan`. The blastpipe was the second and went the other way: it is part of
> the chimney, because the two were proportioned together and because the blast head has to
> reach both paths through the stack, which only the flue sits on. Getting this wrong costs a
> node that cannot be wired without stealing a link from the chassis.

**Where two parts of a kind differ only in numbers, write the wiring once.** `parts.rb` keeps a
`*_fragment` helper per kind holding the shape; the registrations hold only the figures. Sixteen
copies of one link list is sixteen chances to drift on something that is not supposed to vary.

This is the test the architecture was built to pass: if two machines that look nothing alike
are the same definition with parts swapped, the abstractions are right. Prefer a variant to a
second definition.

## Getting a new operation to run

Expect several rounds. Drive it from a **scratch script, not a spec**, until it behaves, using
`op.telemetry` for raw truth.

Symptom → cause table (a node that fills forever, something that drains its source, pressure
exceeding its supply, a reaction that never fires, a part that bursts in one tick) is in the
guide. Read it before debugging by inspection — every row was a real bug.

**Balance is a sweep, not a guess.** Sweep the two or three levers that matter and look for a
skill gradient: settings that survive indefinitely, settings that make far more output and then
destroy the machine, and a band between them. If every setting survives there is no game; if
none do, something is missing — usually a safety device.

## Specs an operation should have

Copy the shape of `spec/reactor_sim/steam_engine_spec.rb`: it starts from cold following the
real procedure; it makes more output when driven harder; it fails the way it should with the
right event type; moderate settings survive a long run; **conservation holds to < 1e-9
relative**; snapshot round-trip preserves the variant and the digest.

The conservation spec is the one that catches real physics bugs. Write it early.

## Machine-specific code lives here

If a behaviour is genuinely specific to one machine, it belongs under `operations/<name>/`,
not in `nodes/`. `panel.rb` alongside `definition.rb` is the pattern for presentation chrome.
