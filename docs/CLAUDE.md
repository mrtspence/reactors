# `docs/`

[`README.md`](README.md) is the index and the routing table. Start there.

## The four categories, and why the distinction matters

**Operational reference** — contracts, signatures, orderings, and the mistakes that are easy to
make. These tell you *what is true* and should be kept accurate:

- `reference/invariants.md` — the four rules. Read first, always.
- `reference/tick.md`, `reference/settlement.md`, `reference/physics.md`,
  `reference/nodes.md`, `reference/diagnostics.md`
- `guides/build-an-operation.md`, `guides/add-content.md`
- `current_progress.md` — what is done, what is next, and the traps that have already cost time

**Design rationale** — longer, historical, explaining *why*. Still accurate, but not the place
to look up a signature:

- `architecture.md` — process topology, Kafka, realtime protocol, persistence
- `simulation_architecture.md` — why the simulation is shaped this way, including the
  alternatives that were rejected and the bugs that shaped it

**Design sketches** (`design_sketches/`) — input to design, **not** a description of what
exists. `boiler.md` includes failure modes that are designed but not built.

**Historical** — these describe code that in places **no longer exists**. Read them for why a
decision was made, never as a description of the current system:

- `concepts.md` — the original game sketch
- `mechanism_pipeline_thoughts.md` — a trace of the deleted v0 engine, plus the counter-proposal
  that replaced it
- `architecture_proposal_review.md` — the review of that counter-proposal

## Conventions

- **Updating these is part of the change, not follow-up work.** The change→file table is in the
  root [`CLAUDE.md`](../CLAUDE.md); check it before calling a piece of work done. A doc that is
  wrong once teaches the next reader to distrust all of them, and the whole set stops being
  worth reading — which would cost far more than it cost to write them.
- **Inventory lists carry a derivation command.** Tags in use, stock nodes, the filter palette,
  the spec table: these grow incidentally and drift the moment someone adds one without
  looking. Every one is marked as a snapshot with the one-line command that derives the truth.
  Do not add a new inventory list anywhere without one, and prefer a pointer to a list when the
  list has no explanatory value.
- **Contract rules are different** — the four invariants, the phase order, the `settle_mass`
  stages. They change rarely and deliberately, so they are written out in full and a change to
  one is a notable event, not a maintenance chore.
- **Reference docs record the bug that produced the rule.** Nearly every "do not do X" in here
  is a real defect that cost real time. When you fix something subtle, add the *why* rather
  than only the *what* — that is what makes these docs worth reading twice.
- Keep operational reference and rationale separate. When a rationale doc and a reference doc
  disagree, the reference doc is current and the rationale doc is history.
- The per-directory `CLAUDE.md` files summarise the local non-negotiables and **point here** for
  detail. If you change a rule, update the reference doc first, then the `CLAUDE.md` if the
  summary is now wrong. Do not let the summaries grow into a second copy of the docs.
- Update `current_progress.md` when you finish something on its "What to do next" list, and add
  to its trap list when a bug turns out to be the repeatable kind.
- `README.md`'s routing table is the entry point for a fresh reader. A new reference doc needs a
  row in it.
