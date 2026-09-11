# `operations/` — specific machines

An **operation** is one overseer's machine: a graph of nodes, the levers they pull, and the
instruments they read. Built from everything above it in the require chain, so these files
load last. `steam_engine/` is the worked example. Guide:
[`docs/guides/build-an-operation.md`](../../../docs/guides/build-an-operation.md).

## Operation configuration is code, not data

Only **state** is serialised; the graph is rebuilt identically every time from the registered
builder. That is what lets a snapshot be a bag of floats rather than an object graph.

**Anything that changes the graph's shape must be in `options:`** so it is snapshotted and
handed back on restore. The steam engine's `variant:` does this. Miss it and an atmospheric
engine restores as a high-pressure one — a total, silent divergence.

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

Register with `Operations.register(TYPE) { |id:, seed:, ...| ... }`, then require it from
`lib/reactor_sim.rb` **last**. Extra keys in a `Match.create` operation spec are passed through
to the builder.

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

## Variants: one definition, several machines

The steam engine is deliberately two machines — Watt's atmospheric and Trevithick's
high-pressure — differing only in what the cylinder exhausts into and a few sizes. `nodes(spec)`
and `links(spec)` branch on the `VARIANTS` hash.

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
