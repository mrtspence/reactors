# Invariants

Four rules. Everything else in the simulation is designed around keeping them, and each has
a spec that fails loudly when it is broken. Violating one does not produce a crash — it
produces a match that quietly cannot be recovered, replayed or reproduced.

Read this before writing code in `lib/reactor_sim`.

---

## 1. Purity

`lib/reactor_sim` never reads a clock, draws ambient entropy, or touches Rails.

**Forbidden anywhere in `lib/reactor_sim`:** `Time.now`, `Time.current`, `Date.today`,
`SecureRandom`, `Random.new`, `Kernel#rand`, `Rails`, `ENV`, `String#hash`.

- Time arrives as `dt` (simulated seconds), passed in.
- Randomness comes from `ReactorSim::Rng`, seeded, with state stored *inside* match state.
- `String#hash` is randomised per process — use `Rng.stream(seed, name)`.

**The one filesystem exception** is `content.rb`, which loads YAML at boot. Nothing else may
touch `File`, `IO`, `Dir` or `YAML`, and nothing reads a file during a tick.

Guarded by `spec/reactor_sim/purity_spec.rb`, which boots the sim in a bare Ruby subprocess
and also sweeps the source statically.

---

## 2. Determinism

`seed + command log` reproduces a match exactly, bit for bit.

- Every node, control point and diagnostic gets its **own** RNG stream, named
  `"#{operation_id}/#{component_id}"`, so draws never depend on evaluation order.
- RNG state lives in match state, so it snapshots and restores.
- **Entropy may only be drawn in three places:** `initial_state`, phase 0 (`actuate`), and
  phase 7 (`observe`/`Diagnostic#record`). Nowhere else — see rule 4 for why.

### Symbols as values do not survive JSON

`deep_symbolize` converts **keys** only. A symbol stored as a *value* — a `resource:` inside
a parcel, a flag inside an instrument's `flags` array — comes back from a snapshot as a
`String` and then silently fails to match anything.

`Operation#restore` normalises both. If you add state holding symbols as values, normalise
it there too.

### Builder options must be persisted

Anything passed to an operation builder that changes its *shape* (which nodes exist, how they
are wired) must go in `options:` so it is snapshotted and handed back on restore. The steam
engine's `variant:` does this. Miss it and an atmospheric engine restores as a high-pressure
one — a total, silent divergence.

Guarded by `spec/reactor_sim/determinism_spec.rb`.

---

## 3. Order-independence

The order nodes and links are declared in cannot affect the result.

> **Measured 2026-09-13, and the two halves of that sentence are not equally true.**
>
> **Node order is bit-identical.** Reversing the steam engine's node list and running 1800
> ticks of a full startup gives a byte-identical state digest.
>
> **Link order is not.** The same test on the link list diverges on **tick 1**, and the
> divergence is `1e-16` relative — one unit in the last place of a double, in the order
> floats are summed. It reaches **0.3 kPa of boiler pressure and 0.07 rpm by tick 1800**:
> 608.183 / 608.046 / 607.866 kPa for the list as declared, reversed, and shuffled.
>
> **What decides whether an ulp grows or dies is feedback, and the two engines prove it.**
> Run the same comparison on both chassis: the high-pressure engine diverges and keeps
> diverging, while the **atmospheric engine diverges transiently around tick 2700 and comes
> back to a byte-identical digest by 3600, with its total mass bit-identical throughout.**
> The difference between them is the blastpipe. Trevithick's engine exhausts up its own
> chimney, so it carries a closed loop — blastpipe → draught → fire → pressure → speed →
> blastpipe — that multiplies a perturbation; Watt's exhausts into a condenser and has no
> such loop, so the same perturbation damps away. The last bit is not the problem. The
> **loop gain** is.
>
> **What this does and does not break.** Invariant 2 is untouched: `seed + command log`
> still reproduces a match bit for bit, because link order is a property of the *code*, and
> code that changed already changed the physics. What fails is the weaker claim that two
> different declaration orders of the *same* graph agree bitwise — which matters exactly
> once, during a refactor that reorders links. Modularisation was that refactor: parts own
> their links, so the order necessarily changed and the stage could not be accepted on a
> bit-identical digest. It was accepted on identical node set, identical link **set**,
> identical panel, identical cold state, and agreement to 1e-15 per tick.
>
> `graph_spec` asserts link-order independence and **passes**, because it asserts it on
> `LoopRig` — four nodes, 60 ticks, no feedback strong enough to amplify an ulp. The
> assertion is true there and does not generalise. Do not read it as a guarantee about a
> real operation.
>
> **Not yet fixed, and it is a live decision.** Making it bitwise means order-independent
> accumulation — sorting contributions by a stable key before summing them in `Arbiter` —
> which is a real change with its own risk. Recorded in `current_progress.md`.

Every node reads the **frozen previous tick** and writes the next. A node physically cannot
observe a half-finished tick, because nothing is installed until every phase has run.

Two consequences worth knowing:

- **Closed loops just work.** A recirculation loop needs no topological sort, no cycle
  detection and no special case. This is why topological resolution was rejected.
- A node may read another node's *previous-tick* state through `ctx.node_pressure(id)`,
  `ctx.node_omega(id)`, `ctx.node_state(id)`. That is safe — tick N−1 is settled and
  identical for everyone. Structural dependencies should still be **declared**
  (`drives:`, `exhausts_to:`, `supplied_by:`, `senses:`) so they stay visible.

Guarded by `spec/reactor_sim/graph_spec.rb`, which shuffles node and link order and compares
digests — **on `LoopRig`**. Read the note above before treating the link half as a guarantee.

---

## 4. Command idempotence

Commands carry absolute values and are safe to deliver twice.

```ruby
{ type: "set_control", operation_id: "eng", control_point_id: "throttle", value: 85 }
```

- Commands set `target` **only**. They never touch `actual`, and never draw entropy.
- `ControlPoint#actuate` moves `actual` toward `target` during phase 0 — that is where
  operator lag and (later) minion mishaps belong.
- Out-of-range values are clamped, not rejected.
- A malformed command is counted as rejected, never raised.
- **`value` is coerced to a number in `Command.parse`, or the command is rejected.** It was
  once the only field that reached the simulation uninspected, and it ends up at
  `ControlPoint#set_target`, which calls `.to_f` — so a `value` of `{"a": 1}` raised
  `NoMethodError` straight out of `Match#apply`, which does not rescue. In the runner that is
  the process and every match on it, killed by one line in a log that anything can produce to.
  A non-numeric value is now rejected and counted like any other malformed command.

This is what lets the runner commit Kafka offsets *after* snapshotting: redelivery is a
no-op, so at-least-once delivery needs no dedup table.

Guarded by `spec/reactor_sim/determinism_spec.rb`.

---

## 5. Conservation (the fifth rule, in practice)

Not one of the original four, but enforced just as hard: **lossy is fine, silent is not.**

Every gram and joule crossing the boundary is declared in the ledger. See
[`settlement.md`](settlement.md#the-ledger).

```
mass_balance   = total_mass   + mass_out   - mass_in     # constant
energy_balance = total_joules + joules_out - joules_in   # constant
```

Both hold to float precision — currently **zero drift** over 1200 ticks through combustion,
boiling, phase change and shaft work. If you add anything that creates or destroys mass or
energy, it must be ledgered in the same commit.

Guarded by `spec/reactor_sim/conservation_spec.rb` and `steam_engine_spec.rb`.
