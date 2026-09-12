# Reactor

A multiplayer game about overseeing deep industrial simulations through narrow controls and
imperfect instruments. `lib/reactor_sim` is the simulation — pure Ruby, no Rails,
deterministic. Everything else is delivery.

## Before you write code in `lib/reactor_sim`

Read [`docs/reference/invariants.md`](docs/reference/invariants.md). It is 120 lines and
breaking any of its rules does not crash — it produces a match that quietly cannot be
recovered, replayed or reproduced.

The four, in one line each:

1. **Purity** — no clock, no ambient entropy, no Rails, no I/O on the tick path.
2. **Determinism** — `seed + command log` reproduces a match bit for bit.
3. **Order-independence** — every node reads the frozen tick N−1 and writes N.
4. **Idempotence** — commands carry absolute values and set `target` only.

Plus, enforced just as hard: **conservation**. Lossy is fine, silent is not — everything
crossing the boundary goes on the ledger.

## The boundary

```
lib/reactor_sim/   PURE RUBY. No Rails, no ActiveRecord, no Kafka, no I/O. Not autoloaded.
content/           YAML data the sim reads once, at boot.
app/               Rails delivery tier. May call into the sim; the sim never calls back.
spec/              Sim specs are Rails-free (spec_helper); web specs use rails_helper.
docs/              See docs/README.md for the map.
```

The sim is **deliberately outside Zeitwerk** (`config/application.rb` ignores it). Its load
order is the explicit `require_relative` chain in `lib/reactor_sim.rb`, which doubles as the
dependency graph. A new file needs a line added there, in dependency order.

## Where to look

Each working directory has its own `CLAUDE.md` with the local rules. The full reference lives
in `docs/`:

| Task | Read |
|---|---|
| Understand one tick | [`docs/reference/tick.md`](docs/reference/tick.md) |
| Follow how material, heat and momentum move | [`docs/reference/settlement.md`](docs/reference/settlement.md) |
| Energy, mass, temperature, pressure, rotation | [`docs/reference/physics.md`](docs/reference/physics.md) |
| Write or modify a node | [`docs/reference/nodes.md`](docs/reference/nodes.md) |
| Add or change a gauge | [`docs/reference/diagnostics.md`](docs/reference/diagnostics.md) |
| Build a new operation | [`docs/guides/build-an-operation.md`](docs/guides/build-an-operation.md) |
| Add a substance, reaction or material | [`docs/guides/add-content.md`](docs/guides/add-content.md) |
| What is done, what is next, what has already cost time | [`docs/current_progress.md`](docs/current_progress.md) |

`docs/concepts.md`, `docs/mechanism_pipeline_thoughts.md` and
`docs/architecture_proposal_review.md` are **historical**. They describe code that in places
no longer exists. Read them for why a decision was made, never as a description of the system.

## Commands

```sh
bundle exec rspec                          # full suite (~2.5 min, dominated by steam engine runs)
bundle exec rspec spec/reactor_sim/conservation_spec.rb   # one file
bin/rubocop                                # style + the bug-catching cops
bin/ci                                     # setup, rubocop, bundler-audit, brakeman
ruby -Ilib -e 'require "reactor_sim"'      # boot the sim with no Rails at all
```

The sim needs no database and no services. `bin/dev` boots the Rails side.

> **A change under `lib/reactor_sim` needs BOTH dev processes restarted.** The sim is outside
> Zeitwerk and is required once at boot, so Rails' development reloader never picks it up — and
> `bin/match_runner` loads it once too. Restart the runner and you get new physics with an old
> panel; restart neither and you get neither. This cost a round trip: four new instruments were
> written, specced and confirmed present in `op.panel`, and were invisible in the browser for two
> days because the web process had been up for 56 hours. If a sim change appears to have no effect
> in the UI, check process age before debugging anything else.

## Documentation is part of the change, not follow-up work

**A change that makes a doc wrong is not finished until that doc is fixed, in the same
commit.** These docs are load-bearing — they are the reason a rule like "an active sink is
authoritative about its own intake" survives the person who found it. A doc that is wrong once
teaches the next reader to distrust all of them, and the whole set stops being worth reading.

So: before you call a piece of work done, check this table and update what your change touched.

| If you changed | Update in the same commit |
|---|---|
| A tick phase, or the order of phases | [`docs/reference/tick.md`](docs/reference/tick.md), [`lib/reactor_sim/CLAUDE.md`](lib/reactor_sim/CLAUDE.md) |
| A settlement stage or arbiter rule | [`docs/reference/settlement.md`](docs/reference/settlement.md), [`graph/CLAUDE.md`](lib/reactor_sim/graph/CLAUDE.md) |
| A physics model, unit, or solver | [`docs/reference/physics.md`](docs/reference/physics.md), [`physics/CLAUDE.md`](lib/reactor_sim/physics/CLAUDE.md) |
| A ledger line | [`docs/reference/settlement.md`](docs/reference/settlement.md) (ledger + state-key tables) |
| A concern's config, state or methods | [`docs/reference/nodes.md`](docs/reference/nodes.md), [`concerns/CLAUDE.md`](lib/reactor_sim/concerns/CLAUDE.md) |
| A stock node added or removed | [`docs/reference/nodes.md`](docs/reference/nodes.md), [`nodes/CLAUDE.md`](lib/reactor_sim/nodes/CLAUDE.md) |
| A Source, Filter, Display, or `SIGNATURES` entry | [`docs/reference/diagnostics.md`](docs/reference/diagnostics.md), [`diagnostics/CLAUDE.md`](lib/reactor_sim/diagnostics/CLAUDE.md) |
| A resource tag, reaction key, or material field | [`docs/guides/add-content.md`](docs/guides/add-content.md), [`content/CLAUDE.md`](content/CLAUDE.md) |
| An operation or variant | [`docs/guides/build-an-operation.md`](docs/guides/build-an-operation.md), [`operations/CLAUDE.md`](lib/reactor_sim/operations/CLAUDE.md) |
| A spec file, or the helper split | [`spec/CLAUDE.md`](spec/CLAUDE.md) |
| An invariant, or how one is enforced | [`docs/reference/invariants.md`](docs/reference/invariants.md) — **and say so loudly** |
| Anything on the "What to do next" list | [`docs/current_progress.md`](docs/current_progress.md) |

Two more habits that keep the set honest:

- **A bug worth a rule gets written down where the rule lives.** If you fix something subtle,
  add the *why* — the failure it produced — not just the *what*. That is what makes these docs
  worth reading twice, and it is the existing convention throughout.
- **If you notice a doc is already wrong, fix it then**, even if your change did not cause it.
  Drift is cheap to fix on sight and expensive to fix in a batch.

### Inventory lists vs contract rules

Two kinds of statement live in these files, and they age differently.

**Contract rules** — the four invariants, the phase order, the four `settle_mass` stages —
change rarely and deliberately. They are written out in full on purpose.

**Inventory lists** — tags in use, stock nodes, filters, specs — grow incidentally, so they
drift the moment someone adds one without looking. Every such list in these files is marked as
a snapshot and carries the one-line command that derives the current truth. **Run the command
rather than trusting the list, and when you add an entry, update the list in the same commit.**
Do not add a new inventory list without a derivation command next to it.

## Working style

- **Design before implementation.** Non-trivial features get a design doc reviewed and
  iterated before code. `docs/design_sketches/` is input to that, not a description of what
  exists.
- **Comments explain why, not what.** This codebase's comments record the bug that produced
  the rule. Match that: if you fix something subtle, write down what it was.
- **Conservation specs catch real physics bugs.** Write them early, not last.
- `docs/current_progress.md` §"Traps that have already cost time" is a list of bugs a fresh
  reader repeats. Read it once.
