# Reactor — documentation index

Reactor is a multiplayer game about overseeing deep industrial simulations through narrow
controls and imperfect instruments. `lib/reactor_sim` is the simulation: pure Ruby, no
Rails, deterministic. Everything else is delivery.

**If you are an AI instance picking this codebase up, read
[`reference/invariants.md`](reference/invariants.md) first.** It is short, and breaking any
of those four rules silently destroys crash recovery, replay and reproducibility.

## Which file do you need?

| I want to… | Read |
|---|---|
| Not break anything | [`reference/invariants.md`](reference/invariants.md) |
| Understand what happens in one tick | [`reference/tick.md`](reference/tick.md) |
| Follow how material, heat and momentum move | [`reference/settlement.md`](reference/settlement.md) |
| Understand energy, mass, temperature, pressure, rotation | [`reference/physics.md`](reference/physics.md) |
| Write or modify a node | [`reference/nodes.md`](reference/nodes.md) |
| Add or change a gauge | [`reference/diagnostics.md`](reference/diagnostics.md) |
| **Build a new operation from scratch** | [`guides/build-an-operation.md`](guides/build-an-operation.md) |
| Add a substance, reaction or material | [`guides/add-content.md`](guides/add-content.md) |
| Know what is done and what is next | [`current_progress.md`](current_progress.md) |

## Reference vs rationale

The files above are **operational**: contracts, signatures, orderings, and the mistakes that
are easy to make. They tell you *what is true*.

These two are **design rationale** — longer, historical, and explaining *why*:

- [`architecture.md`](architecture.md) — process topology, Kafka, realtime protocol,
  persistence. Everything around the simulation.
- [`simulation_architecture.md`](simulation_architecture.md) — why the simulation is shaped
  the way it is, including the alternatives that were rejected and the bugs that shaped it.

Design sketches and working notes live in [`design_sketches/`](design_sketches/) and are
input to design, not a description of what exists.

## `CLAUDE.md`

Each working directory carries a `CLAUDE.md` summarising the local non-negotiables and
pointing back here for detail — root, `lib/reactor_sim/` and each of its subdirectories,
`content/`, `spec/`, `app/`, and this folder. AI instances load them automatically when they
touch that directory. They are summaries, deliberately: **when a rule changes, update the
reference doc here first**, then the summary if it has gone stale.

Three further files are **historical** — they record how the design got here and describe
code that in places no longer exists. Read them for context on *why* a decision was made, and
never as a description of the current system:
[`concepts.md`](concepts.md) (the original game sketch),
[`mechanism_pipeline_thoughts.md`](mechanism_pipeline_thoughts.md) (a trace of the deleted v0
engine, plus the counter-proposal that replaced it), and
[`architecture_proposal_review.md`](architecture_proposal_review.md) (the review of that
counter-proposal).

## Orientation in 30 seconds

```
lib/reactor_sim/
  physics/      units, parcel, ledger, relaxation, resources/{saturation,reaction}
  graph/        node, port, link, intent, arbiter
  concerns/     thermal, holds, wearing, pressurized, rotating
  nodes/        atmosphere, conduit, vessel, flywheel, load, cylinder, relief_valve
  diagnostics/  sources, filters, displays, diagnostic, player_view
  operations/   steam_engine/{definition,panel}
  tick.rb       the eight phases, in order
  operation.rb  config, commands, projection, serialisation
  match.rb      many operations advanced in lockstep
  minion.rb     who stands at a lever — peer to control_point
```

The require chain in `lib/reactor_sim.rb` is deliberately explicit and doubles as the
dependency graph — this library is outside Zeitwerk's reach on purpose.
