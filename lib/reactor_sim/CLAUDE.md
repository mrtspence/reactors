# `lib/reactor_sim` — the simulation

Pure Ruby. This library stands alone: `ruby -Ilib -e 'require "reactor_sim"'` must work, and
`spec/reactor_sim/purity_spec.rb` boots it in a bare subprocess to prove it.

## Hard rules

**Forbidden anywhere under this directory:** `Time.now`, `Time.current`, `Date.today`,
`SecureRandom`, `Random.new`, `Kernel#rand`, `Rails`, `ENV`, `String#hash`.

- Time arrives as `dt` — *simulated* seconds, passed in. Never measured.
- Randomness comes from `ReactorSim::Rng`, seeded, with state stored **inside** match state
  so it snapshots and restores. `String#hash` is randomised per process — use
  `Rng.stream(seed, name)`.
- `content.rb` is the **one** filesystem exception, and only at boot. Nothing else touches
  `File`, `IO`, `Dir` or `YAML`; nothing reads a file during a tick.

**Entropy may only be drawn in three places:** `initial_state`, phase 0 (`actuate`), and
phase 7 (`observe` / `Diagnostic#record`). Anywhere else and projection stops being pure —
how many people happened to be watching would change the match.

**Nothing here is autoloaded.** Add new files to the `require_relative` chain in
`lib/reactor_sim.rb`, in dependency order. That chain is the dependency graph, on purpose.

## Layout, in dependency order

```
physics/      substances, energy bookkeeping, the relaxation solver — no graph awareness
graph/        nodes, ports, links, and the arbiter that settles every claim between them
concerns/     composable state+behaviour fragments a node opts into
nodes/        generic machinery, reusable across operations
diagnostics/  the instrument chain — the only thing that leaves the simulation
operations/   specific machines, built from everything above
```

Top-level files: `tick.rb` (the eight phases, in order), `operation.rb` (config, commands,
projection, serialisation), `match.rb` (many operations in lockstep), `content.rb`,
`control_point.rb`, `minion.rb` (who stands at a lever), `command.rb`, `rng.rb`.

## The tick

`Operation#step!` delegates to `Tick`, which reads the frozen previous state and returns the
next one; the operation installs it atomically. A half-finished tick is never observable.

Full phase table and the orderings that are load-bearing:
[`docs/reference/tick.md`](../../docs/reference/tick.md). The short version of what breaks if
you rearrange:

- **Mass moves before heat** (4a before 4b) — a parcel carries its own energy.
- **Torque is transmitted after node effects** (4e after `apply_nodes`) — a prime mover is
  charged the KE the shaft *measurably* gained, not a first-order prediction.
- **`record_injections` runs after `react`** — combustion releases energy in phase 5.
  Ledgering earlier missed ~1.8 MJ/tick.
- **`observe` runs last** — instruments must see the settled tick.

## Serialisation traps

- **Symbols as *values* do not survive JSON.** `deep_symbolize` converts keys only. Resource
  ids inside parcels, flags inside instrument state, and a minion's `station` all broke this
  way. `Operation#restore` normalises all three — if you add state holding symbols as values,
  normalise it there too.
  **The digest cannot catch this**: `canonical` runs through `JSON.generate`, where `:stoking`
  and `"stoking"` are the same string, so a round-trip spec passes with the bug present. Only
  an identity assertion (`be(:stoking)`, never `eq`) finds it.
- **A sparse hash cannot express a removal by diffing.** `PlayerView#flags` omits instruments
  with nothing to say, so rejecting unchanged entries never mentioned a flag that *cleared*.
  `delta_from` emits an explicit empty list instead.
- **Ids are one flat namespace** across nodes, control points, diagnostics and minions,
  because they key one RNG table. `validate_graph!` refuses duplicates — a collision would
  hand two components the same stream, silently and through a snapshot.
- **Builder options that change the graph's shape must be in `options:`**, or a restored
  snapshot rebuilds a different machine. Silent, total divergence.

## Style

Comments here record the bug that produced the rule, and `Metrics/*` cops are deliberately
off because the ordering in `Arbiter#settle_mass` and `Tick#call` is the thing a reader most
needs to see in one place. Keep both conventions.
