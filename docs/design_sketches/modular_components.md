# Modular components: slots, parts, and an operation that can be built wrong

> **Status: AGREED 2026-09-13; STAGE 1 BUILT.** All six junctures were reviewed and agreed.
> Two moved under review and the doc below is updated: part authorship stays in-house
> permanently (§3), and the slot *shape* taxonomy was dropped for a single `when_empty:` axis
> (§5). §15 records where the build departed from the sketch, and it departed in one place that
> matters — the acceptance test, because the engine turned out to be sensitive to link order at
> the last bit.
>
> Original framing: *"properly modularize our various components, reifying them into a real
> model… things like the blastpipe, relief valves, fuse plug are all optional improvements and
> our design needs to be able to function without."*

The brief: make the machine's parts things a player can swap, upgrade and go without. Some
parts are genuinely optional — the blastpipe, the safety valves, the fusible plug — and the
operation must run without them, badly and dangerously. That means the operation has to know
what slots it has, which are load-bearing, and there has to be something that refuses a build
that cannot run at all while permitting one that is merely suicidal.

---

## 1. The finding that shapes everything else

**`VARIANTS` is already a loadout, spelled badly.** Here is the high-pressure entry, regrouped
by the part each number actually belongs to:

| Belongs to | Keys in `VARIANTS[:high_pressure]` |
|---|---|
| the boiler | `shell_radius_m`, `wall_thickness_m`, `relief_pa`*, `burst_pa`* |
| the safety valve | `relief_pa`, `max_relief_pa` |
| the cylinder | `bore_m`, `stroke_m`, `cylinder_heat_capacity` |
| the cylinder relief valve | `cylinder_relief_pa`, `cylinder_relief_max_pa` |
| the flywheel | `flywheel: {mass_kg, radius_m, friction}`, `wheel_safety_factor` |
| the mill | `load_inertia`, `load_torque`, `load_rated_omega` |
| the damper | `damper_conductance` |
| **genuinely the machine's shape** | `exhausts_to`, `condenser`, `blastpipe` |

Three of twenty keys describe the *machine*. The other seventeen describe **six parts**, and
two of them (`relief_pa`, `burst_pa`) are read by more than one consumer only because the parts
they belong to are not separate objects yet.

So the bulk of this work is not new machinery. It is **redistributing a flat hash onto the
parts that own its numbers**, and the new machinery is the small amount needed to let a slot be
empty. That reframing matters for staging (§8): most of it is a refactor with a bit-identical
digest as its acceptance test, and only a small core is new behaviour that needs specs.

A second, luckier finding: **the property that makes swapping cheap already exists.** RNG
streams are keyed by component *name*, never by position —

```ruby
# operation.rb — build_rngs
.to_h { |id| [ id, Rng.stream(seed, "#{@id}/#{id}") ] }
```

— so adding a part perturbs no stream that was already there, and swapping a part that keeps
its id keeps its stream. That is already documented as the reason it was safe to give the
engine a crew without re-tuning it. It is the same reason it will be safe to bolt a blastpipe
on. Nothing here has to be invented for determinism's sake; it has to be *not broken*.

---

## 2. The shape

Four new objects, all pure config, all resolved once at build time.

```ruby
Part            # a thing you can fit: kind, label, description, stats, and a builder
Parts           # the registry, exactly like Operations
Slot            # a mounting point on a chassis: what it accepts, whether it is required,
                #   and how the graph closes up when it is empty
Assembly        # slots + loadout -> nodes, links, controls, instruments, and a verdict
```

and one change of spelling on the operation: `variant:` becomes `chassis:`, joined by
`loadout:` in `options:`.

```ruby
SteamEngine.build(id:, seed:, chassis: :high_pressure,
                  loadout: { boiler: :locomotive, safety_valve: :ramsbottom,
                             blastpipe: :none, fusible_plug: :none })
```

A part builds a **fragment** rather than a node, because a part is almost never one node. The
condenser is a condenser *and* a hotwell return *and* two links. The safety valve is a node,
two links, two levers and two gauges.

```ruby
Fragment = Struct.new(:nodes, :links, :thermal_links, :drive_links,
                      :control_points, :instruments, keyword_init: true)
```

`instruments` is a list of *ids*, not `Diagnostic` objects — see J2.

This is the part of the design that pays for itself immediately. Today, deleting the safety
valve means editing `nodes`, `links`, `control_points` and `diagnostics` in two files and
hoping you found all four. With fragments it means not fitting a part.

---

## 3. Juncture 1 — where does a part definition live?

### Option A: content YAML, `content/parts/*.yml`

Parts become data alongside materials and reactions, with `content.rb`'s existing eager
validation.

**Pros.** One place to see every part's numbers side by side, which is what a balance pass
wants and what a progression tree will want. Diffable. Eventually player- or designer-authored
without a deploy. Costs, tiers and prerequisites have an obvious home.

**Cons, and they are heavy.** A part has to choose a node **class** and pass it constructor
keywords, so the YAML is a serialised constructor call — a class name string plus an untyped
argument bag, validated by nothing that Ruby can check. The engine's best asset is that **the
number and the measurement that produced it live together**: `damper_conductance: 0.35` ships
with the seven-point sweep that chose it and the record of the wrong claim it replaced. That
commentary has no home in YAML and would be orphaned from the value it explains. It also cannot
express derivation (`heat_capacity: spec.fetch(:cylinder_heat_capacity)`), and `content.rb` is
the sim's *one* filesystem exception — widening it to cover machine configuration weakens a
boundary that is currently absolute and cheaply checkable.

### Option B: a Ruby registry, mirroring `Operations` — **recommended**

```ruby
Parts.register(:locomotive_boiler, kind: :boiler, label: "Locomotive Boiler",
               provides: %i[boiler]) do |ctx|
  Fragment.new(nodes: [ Nodes::Boiler.new(id: :boiler, ...) ], ...)
end
```

**Pros.** The comments stay welded to the numbers. Full constructor power, checked by Ruby's
own keyword arguments — a typo in a part is a `NoMethodError` at build, not a silent default.
No new serialisation surface, and the sim's filesystem boundary is untouched. It is the pattern
already in the codebase (`Operations.register`), so it needs no new idiom explained.

**Cons, stated honestly.** A new part is a code change and a deploy; player-authored parts are
impossible; and comparing eight boilers means reading eight methods rather than one table. The
last is the one that will actually bite, and it bites later rather than now.

### Option C: hybrid — builder in Ruby, numbers in YAML keyed by part id

**Pros.** Balance becomes a YAML diff; structure stays typed.

**Cons.** It splits one part across two files and puts the measurement note on the far side of
that split from the number — which is precisely the property Option A was rejected for
destroying, achieved by a different route.

### Recommendation

**Option B, permanently.** Not as a waypoint to Option C.

The reason is a design decision, not a technical one: **authorship of parts stays in-house.**
Once that is settled, Option A's headline advantage evaporates — its real pull was never
diffability, it was letting someone outside the repository add a part, and nobody is going to.
What is left of A and C is a split between a number and the measurement that produced it, paid
for nothing.

That leaves one live cost: **comparing eight boilers means reading eight methods.** The answer
when it starts to hurt is not YAML, it is to *derive* the table — §11 already requires every
part to declare a `stats` hash so the outfitting screen can render alternatives without
instantiating them, so a rake task can print the same hash as a balance table. Generated from
the registry it cannot drift from the constructor, which is exactly the failure mode a
hand-maintained YAML table would have.

**Tradeoff accepted:** a new part is a code change and a deploy, forever. Given that every
balance sweep so far has been driven from a scratch script against the real sim rather than
from a table, and that a part's numbers are meaningless without the sweep that chose them, that
is the cheaper side of the trade.

### Rejected outright: let the Rails tier assemble the graph

Tempting — the web tier knows the player's inventory, so let it compose a node list and hand it
to `Operation.new`. It cannot work. `Operation.from_h` rebuilds the machine from `options:`
alone, in the runner, with no database in reach, and a snapshot restored against a different
part list is the silent total divergence that `options:` exists to prevent. **Parts must be a
simulation concept**; the Rails tier may only choose among them and store the choice.

---

## 4. Juncture 2 — what does a part own?

Nodes, links and control points are uncontroversial: they are small, they are already written
next to the node they belong to, and moving them is a cut and paste.

Instruments are the question, because `panel.rb` is 355 lines of which perhaps 250 are the
explanations of *why each gauge lies the way it does* — the water glass reading swell, the
safety valve deliberately carrying no lag or noise, the prose display withholding its phrase
list.

### Option A: parts own `Diagnostic` objects outright

**Pros.** A gauge cannot dangle over a missing node, because it arrives with the node. It makes
"a better gauge" a straightforward upgrade, which is the stated progression axis.
**Cons.** `panel.rb` is dismembered; the property that you can read the entire instrument
philosophy in one sitting is lost, and that property is load-bearing for the game's design.

### Option B: parts name instrument ids; `panel.rb` keeps the definitions — **recommended**

```ruby
Parts.register(:ramsbottom, kind: :safety_valve, provides: %i[relief],
               instruments: %i[safety_valve valve_setting]) { |ctx| ... }
```

The assembler pulls those ids from the operation's panel module and raises on an unknown one.

**Pros.** Chrome stays in one readable file with its commentary intact; ownership becomes
explicit and checkable; a gauge for an unfitted part cannot be included, and a gauge naming a
part that does not exist fails **loudly at build** rather than reading nil forever.
**Cons.** "Which gauges exist" and "what they look like" live in different files, and there is
one more registry lookup to understand. Upgradable *instruments* (a better pressure gauge as a
part in its own right) need a small extension — an `instrument` kind whose fragment contributes
`Diagnostic` objects directly, which is Option A applied only where it is the point.

### Recommendation

Option B, with Option A available for parts that genuinely *are* instruments. The tradeoff: two
files instead of one for a part's full story, bought for keeping `panel.rb` legible.

---

## 5. Juncture 3 — how is absence expressed?

> **This section was rewritten after review.** The first draft named three *shapes* —
> `:core`, `:branch`, `:inline` — and the objection was that `:branch` says nothing useful.
> Checking why turned up something worse than a bad name: **the taxonomy was describing
> topology when the thing that matters is consequence**, and it did not even describe topology
> correctly. Of the four parts filed under `:branch`, only two terminate: the fusible plug
> discharges *onto the fire*, which is the entire function of the part, and the condenser runs
> on to a hotwell and back to the water supply, closing a loop. Renaming it `:terminator`
> would have made it confidently wrong rather than vaguely unhelpful. The taxonomy is dropped.

A slot needs to answer exactly one question that the graph cares about: **when nothing is
fitted here, what happens to the wiring?** There are two answers, and they are the whole
design.

```ruby
# The part sits in a run that must survive without it. Empty -> the ends are joined.
Slot.new(id: :blastpipe, accepts: :blastpipe, required: false,
         run: [ [ :boiler_tubes, :outlet ], [ :flue, :inlet ] ],
         when_empty: :bypass)

# The part IS the run. Empty -> the run does not exist and nothing flows.
Slot.new(id: :safety_valve, accepts: :safety_valve, required: false,
         run: [ [ :boiler, :relief_out ], [ :atmosphere, :exhaust ] ],
         when_empty: :omit)

# A run that must exist. `when_empty` is meaningless, and declaring it is an error.
Slot.new(id: :throttle, accepts: :regulator, required: true,
         run: [ [ :boiler, :steam_out ], [ :steam_chest, :in ] ])

# No run at all: the part contributes holders the chassis links to by id.
Slot.new(id: :boiler, accepts: :boiler, required: true, provides: %i[boiler])
```

`:core` disappears as a concept — it is just **a slot with no `run:`**, whose part contributes
holders that the chassis's own links reference. `provides:` is what guarantees those ids exist,
and it is already needed for §7's validator. Two fewer names, and each remaining one is named
after its effect rather than after a shape.

| Every optional part today | `when_empty:` | Why |
|---|---|---|
| blastpipe, boiler tubes | `:bypass` | The flue gas still has to reach the chimney |
| safety valve, fusible plug, cylinder cocks | `:omit` | Nothing should flow through a fitting that isn't there |
| condenser + hotwell | *(neither)* | Its absence means a **different destination**, not a missing one — which is why it stays a chassis decision (§6) |

The condenser is the useful edge case and it earns its place in §6 rather than here: removing it
does not join two ends or delete a run, it sends the exhaust somewhere else entirely. A slot
system that tried to express "absent means rerouted" would be expressing a chassis.

**Mounting ports stay on the host, and an empty mount is inert.** The boiler keeps
`:relief_out` whether or not a safety valve is fitted. The purist alternative — the part
contributes the port to its host — means parts reaching into other parts' constructors, and
buys nothing: `validate_graph!` validates links, not ports, so an unconnected port is already
harmless. It is also honest, since a real casting has a blanked-off boss where the fitting
isn't.

Two facts make a `:bypass` run cheaper than it looks, and both were checked:

- **A conduit costs no tick.** `Path` resolves straight through transport nodes, so fitting a
  blastpipe in series adds no delay. **A holder costs one tick per hop**, so a part fitted into
  a bypassable run silently changes the machine's timing if it holds anything. That gives a rule
  worth writing into `nodes/CLAUDE.md`: *a part in a `:bypass` run should be a conduit unless it
  genuinely holds material* — otherwise fitting an upgrade re-times the engine and every balance
  number moves.
- **Head composes additively along a path already.** `Arbiter.path_head` sums `head_pa` and
  `stack_height_m` over every conduit on the path, so a blastpipe as its own conduit needs no
  new machinery — where today it is a `blast_from:` attribute on the flue, which is exactly the
  spelling that makes it un-slottable.

That last point generalises: **several of today's "optional" features are attributes on another
node, and they have to become nodes to become parts.** The blastpipe (`blast_from:` on `flue`),
the blower (`head_pa:`/`head_control_id:` on `damper`), and the stack height (`stack_height_m:`
on `flue`) are all in this position. Converting them is the one place this work touches physics
rather than structure, and it is the usual trade in this codebase: modelling the thing as the
separate object it really is makes the code simpler, not more complex. A blower genuinely is a
fan bolted to the ashpan; a blastpipe genuinely is a nozzle in the smokebox.

---

## 6. Juncture 4 — does modularisation replace variants, or sit under them?

The awkward case is the condenser, because fitting it does not add a branch — it **reroutes**
the cylinder's exhaust from the chimney to the condenser, and that reroute is the difference
between Watt's engine and Trevithick's.

### Option A: chassis + slots — **recommended**

`variant:` becomes `chassis:`. A chassis owns the fixed topology (where the exhaust goes, which
runs exist) and declares the slots mounted on it. Atmospheric and high-pressure stay two
chassis.

**Pros.** The two-machine story survives intact and remains the architecture's demonstration
case. Validation stays tractable: a chassis's required routes are fixed and can be asserted
once. The exhaust reroute is expressed where it is true — it is a different frame, not a
different fitting.
**Cons.** A player cannot bolt a condenser onto a high-pressure engine, and historically that
is a real machine (and the direct ancestor of the compound). The chassis becomes a second axis
of progression that needs its own design.

### Option B: everything is a slot, including the exhaust destination

An `:exhaust` slot accepting `:condenser` or `:stack_exhaust`, with the chassis reduced to a
bare frame.

**Pros.** Maximum freedom; hybrids fall out for free; one concept instead of two.
**Cons.** The validator's job becomes much harder — it must prove an arbitrary graph is
functional rather than check a known frame's slots are filled. Every combination is a balance
surface nobody has measured, and the engine's tuning is currently a set of numbers measured
against *one* topology. It also invites builds that are legal, assemblable, and physically
absurd.

### Recommendation

**Option A, with the exhaust slot kept explicitly in mind as the first thing to promote.**
Chassis first because it bounds the validation and balance problem to something measurable now;
the exhaust becomes a slot when there is a reason to want the hybrid and an appetite to measure
it. The tradeoff accepted: less freedom in the first version, and a later migration that will
move one concept from chassis to slot. That migration is small — a chassis declaring
`exhausts_to:` becomes a chassis declaring an `:exhaust` slot with a default.

---

## 7. Juncture 5 — how strict is the validator?

The design thesis says explicitly that going without a safety device is a legal, interesting
choice: *"the hazard sits underneath the safety, which is what makes choosing to go without it
a real decision rather than a strictly-worse one."* A validator that refuses an unsafe build
would delete the game's risk/reward axis in the name of helping.

So: **two tiers, and they are different verdicts, not different severities.**

```ruby
Assembly::Verdict = Struct.new(:errors, :warnings)   # errors refuse; warnings are shown and ignored
```

**Errors — the build cannot run, refuse it.** Four checks, in increasing cost:

1. **Slot integrity.** Every `required:` slot filled; every fitted part's `kind` matches its
   slot's `accepts`; every part's declared `provides:` ids actually present in its fragment.
2. **Id uniqueness.** Already enforced — `validate_graph!` refuses duplicate component ids
   across nodes, levers, gauges and crew, because they key one RNG table. Assembly makes
   collisions *likely* for the first time (two parts both naming a node `:pump`), so this check
   graduates from a safety net to a working part of the system, and its error message should
   name the two slots rather than only the id.
3. **Graph integrity.** `Operation#validate_graph!`, unchanged, catches links to absent nodes
   or ports, links into an outlet, a transport node without exactly one inlet and one outlet.
   Most assembly mistakes will surface here, which is the right answer — **reuse the existing
   validator rather than writing a second model of the graph.**
4. **Reachability.** The new one, and the only one that catches "nonfunctional". A chassis
   declares required routes; the assembler checks them against the **resolved `Path` list**,
   which already exists at construction:

   ```ruby
   requires_route: [
     { from: :bunker,  to: :firebox,  carrying: :fuel   },   # fuel can reach the grate
     { from: :supply,  to: :boiler,   carrying: :liquid },   # water can reach the drum
     { from: :boiler,  to: :cylinder, carrying: :gas    },   # steam can reach the piston
     { from: :firebox, to: :atmosphere, carrying: :gas  }    # the fire can breathe out
   ]
   ```

   Checked against `Path.resolve`'s output and each hop's `accepts:` tags, so it uses the real
   router rather than a parallel one — the same reason `validate_graph!` is reused above. This
   is what catches a build with no regulator, no damper, or a chimney deleted.

**Warnings — the build is legal and probably lethal.** No safety valve; no fusible plug; no
water glass; a relief setting above the shell's derived rating. Surfaced in the outfitting UI
in the part's own voice, never blocking. These are the progression's whole point.

**Tradeoff of permissiveness:** a player can build something that assembles, passes every
check, and destroys itself in ninety seconds. That is intended, and it is why the warnings have
to be *good* — the warning copy is game design, not error handling.

---

## 8. Juncture 6 — the loadout, the panel, and the two processes

This is where modularisation collects a debt that is already recorded. `DevMatch.panel`
rebuilds a throwaway match in the **web** process to get the chrome, and that is sound today
for one checkable reason — `Operation#panel` reads only configuration, and both processes read
the variant through `DevMatch.variant` so they cannot disagree. `dev_match.rb` already carries
the TODO: *"this stops being sound the moment a match's configuration is chosen at creation
rather than read from the environment."* A player-chosen loadout is exactly that moment.

Three ways to pay it:

### Option A: a minimal ActiveRecord `Loadout`, read by both processes — **recommended**

The web tier writes it; the runner reads it when it builds or resets the match; `DevMatch.panel`
takes the loadout as an argument and memoises per loadout key.

**Pros.** Smallest change that is actually correct — the soundness argument is the one already
written down, with a row in a table standing in for an env var. It is the path to player
inventory, which is where this is going anyway. The reset path exists already: runner-addressed
commands (`reset_match`) ride the same Kafka topic as lever commands precisely so they stay
ordered, and the loadout can ride with one.
**Cons.** The first migration and the first model in a prototype that has deliberately had
none, which means the test database starts mattering for specs that currently do not need it.
A stale read is possible if the web process reads before the runner has rebuilt — mitigated by
the loadout being carried *in* the reset command rather than only referenced by it.

### Option B: the runner publishes the panel on a compacted topic

**Pros.** Architecturally the right answer long-term; no shared store; the runner is the single
source of truth for what the machine actually is.
**Cons.** A new topic, a new consumer in the web process, and a cold-start ordering problem
(what does the console render before the first panel arrives?) — for a rough-in outfitting
screen that is a great deal of machinery to prove a point already proven.

### Option C: no persistence; the loadout lives in the URL / session

**Pros.** Zero infrastructure; genuinely fine for a single-player dev harness.
**Cons.** The runner has to learn it from somewhere anyway, so this only moves the problem to
the reset command — and it cannot survive a runner restart, which is the thing the fixed dev
seed exists to make reproducible.

### Recommendation

**Option A, with the loadout carried inside the reset command as well as stored**, so the runner
never has to read the table at a moment when it might be stale. Option B stays the documented
destination for when matches are created on demand — the same TODO, one step nearer.

---

## 9. Performance: the tick path must never learn that slots exist

This is the constraint that decides whether the design is any good, and it is satisfiable
completely, because the engine is already built for it: **an operation's configuration is code,
resolved once; only state is serialised.** Assembly is configuration.

The rules, to be written into `operations/CLAUDE.md`:

1. **Assembly happens once, in `build`.** After it, `Operation` receives the same flat
   `nodes:`/`links:`/`control_points:`/`diagnostics:` lists it receives today. `Slot`, `Part`
   and `Fragment` are not reachable from `Tick`, `Arbiter` or any node, and no `Context` method
   may take a slot id. A node must never ask "what is fitted in slot X" — if it needs to know,
   the answer belongs in its own config, decided at build.
2. **No slot indirection in `ctx`.** Adding `ctx.part(:boiler)` would put a hash lookup on the
   hot path and, worse, would make the tick depend on assembly structure — which is how the
   double buffer's guarantees get quietly weakened.
3. **`Path.resolve` still runs once.** Removing a part reroutes paths automatically and costs
   nothing per tick; this is free and is the strongest argument for doing topology at build.
4. **Watch node *count*, not slot count.** `performance_spec` budgets ~55 ms/tick at 100 nodes
   against 250 ms. The engine is ~21 nodes; promoting the blower, blastpipe and stack to real
   conduits plus a handful of optional parts puts a fully-loaded engine somewhere near 30. That
   is comfortable, but it is the number to watch, and a **many-operation match multiplies it** —
   eight players at 30 nodes is the real budget question, and it is worth measuring once before
   the part list grows rather than discovering it at eight.
5. **Assembly cost is a build-time cost and it is paid more than once** — `DevMatch.panel`
   builds a whole engine per web process. Memoise per loadout, as it memoises per process now.

---

## 10. Determinism and the snapshot traps

Three, and the first is a repeat offender.

- **The loadout is symbols as *values*, and JSON does not preserve those.** `options:`
  round-trips through `JSON.generate`; `deep_symbolize` converts **keys only**. So
  `{ boiler: :locomotive }` returns as `{ boiler: "locomotive" }` and every `Parts.fetch` misses.
  This is the fourth instance of this exact trap (parcel resource ids, instrument flags, a
  minion's `station`) and the most dangerous, because a missing part is not a nil — it is a
  *different machine*. `SteamEngine.build` must symbolise the loadout the way it already
  symbolises `variant`, and `Operation#restore`'s comment block should gain a line. **The
  digest cannot catch it**: `canonical` runs through JSON, where `:locomotive` and
  `"locomotive"` are the same string, so a round-trip spec passes with the bug present. Only an
  identity assertion finds it.
- **The registered builder whitelists its keywords.** `register(SteamEngine::TYPE) do |id:,
  seed:, time_scale:, state:, rngs:, variant:|` — an unlisted `loadout:` is an `ArgumentError`
  at restore, not a silent default. Loud, which is right, but it must be remembered.
- **The crew roster must move into `options:` at the same time.** It is already TODO'd in
  `definition.rb` for exactly this reason, and a crew is a loadout by another name. Doing it
  with this work costs almost nothing; doing it later means a second migration of restored
  snapshots.

Acceptance test for the whole of §8 and §10: **the stock loadout's digest is bit-identical to
today's engine**, and a snapshot round-trip preserves the loadout by identity, not equality.

---

## 11. The UI rough-in

An `operations/components` controller, as suggested. Nested under the existing route shape so
it re-paths nothing:

```
GET  /matches/:match_id/operations/:operation_id/components   # the outfitting screen
POST /matches/:match_id/operations/:operation_id/components   # fit parts, reset, test drive
```

The screen, in the order it should be read:

- **Slots down the page**, grouped by system (fire / water / steam / drive) rather than
  alphabetically, each showing the fitted part, its stats, and the alternatives with theirs.
- **Empty optional slots shown as empty**, not hidden. Seeing the hole where a fusible plug
  would go is the point.
- **A verdict panel**: errors that refuse the build, warnings that do not, each in the part's
  own voice ("Nothing will stop this boiler if the water gets away from you.").
- **"Test drive"**, which POSTs the loadout, resets the match through the existing
  runner-addressed reset command, and redirects to the console.

Two requirements this places on §3's `Part`:

1. **A part must be describable without building it.** `label`, `description`, and a `stats`
   hash for display, declared on `Parts.register` rather than computed from the fragment.
   Otherwise the screen has to instantiate every alternative to render a list.
2. **Stats are presentation, not truth.** They are a display hash, and nothing in the sim may
   read them — the moment a `stats` value and a constructor argument can disagree, they will.
   Derive them from the same constant where possible.

Rendered with ViewComponents in the existing panel idiom, so it inherits the Tailwind
constraints already recorded in `app/CLAUDE.md` (map symbols to classes in Ruby; never
interpolate a runtime string into a class attribute).

**This screen is the eventual player-facing outfitting screen**, which is the argument for
putting the verdict and the warning copy in properly now rather than dumping a validation array
on the page.

---

## 12. Staging, with an acceptance test per stage

Each stage ends somewhere shippable, and the first three have a hard, cheap acceptance test.

| # | Stage | Acceptance |
|---|---|---|
| 1 | `Part`, `Parts`, `Slot`, `Fragment`, `Assembly` + validator. Every existing node function becomes a part; one slot each; stock loadout = today's engine. No part is optional yet. | **Digest bit-identical** to the current engine; `steam_engine_spec` power figures unmoved; rubocop clean. |
| 2 | Make the genuinely optional ones optional. Both `when_empty:` behaviours. **Done 2026-09-14 — see §17.** | Stock unchanged. Seven optional slots, each removed on its own and measured; four of them change the machine and three correctly do not. |
| 3 | Redistribute `VARIANTS` onto part variants; chassis keeps only topology. **Done 2026-09-14 — see §18.** | **Bit-identical, literally** — the only line that moved in the whole comparison was the loadout itself. |
| 4 | Rails: `Loadout` model, components controller, outfitting screen, test drive. **Done 2026-09-14.** | A loadout chosen in the browser produces a matching panel and a matching machine; a restored snapshot rebuilds the same parts. |
| 5 | ~~Costs, inventory, progression, part condition and wear carried between matches.~~ **Superseded — see [`blueprints.md`](blueprints.md).** Progression is *blueprints*: a player unlocks the right to mint a **fresh** instance, and nothing a part accumulates survives its match. There is no inventory of objects and no carried wear, so this stage needs no change to `lib/reactor_sim` at all. | — |
| 6 | **Minion-powered parts.** Moved to last: they cannot preserve identicality, and they are adjacent to the modularisation goal rather than on it. Nothing above waits on them. | — |

Stage 3 is the one to be careful in. Stages 1 and 2 are structural and a digest proves them;
stage 3 changes where head is applied and could move the draught, so it wants the damper sweep
re-run rather than assumed — the note in `definition.rb` already says to re-measure
`damper_conductance` if the stack height or blastpipe rating changes, and this moves both.

---

## 13. Open questions, deliberately not guessed

- ~~**Does part condition persist between matches?**~~ **Answered 2026-09-14: no.** A part is
  minted fresh from its blueprint every match, so `integrity` never round-trips out of the sim
  and `Concerns::Wearing` keeps rolling durability from the seeded rng exactly as it does today.
  The cost of wrecking something is paid *inside* the match, by every player sharing its reward.
  Pre-match wear arrives later as a maintenance mechanic, and it is rolled from the match seed
  rather than carried — see [`blueprints.md`](blueprints.md) §9.
- **Are instruments parts?** §4 leaves room for it but does not commit. "A better pressure
  gauge" is an obvious upgrade and the panel is explicitly designed around imperfect
  instruments, so this is likely yes — but it is a game-design call about whether information
  is a purchasable axis.
- **How does a chassis get chosen or unlocked?** §6 makes chassis a second progression axis and
  then says nothing about it.
- **Does the blower's cost land here?** `current_progress.md` wants the blower to cost crew time
  and then a consumable, under a black-start constraint. Promoting it to a real node (§5) is a
  prerequisite and may as well be done here; the *cost* is a separate mechanic that depends on
  minions and on finite lever `stiffness:`, so it should not be smuggled in.

---

## 14. Docs this will make wrong

Per the root `CLAUDE.md` table, to be updated in the same commits:

- `docs/reference/nodes.md` — the blastpipe/blower/stack moving from attributes to nodes; the
  rule that an optional inline part should be a conduit.
- `docs/guides/build-an-operation.md` — slots and parts become the way an operation is built;
  the "Design decisions, in order" list gains a step.
- `lib/reactor_sim/operations/CLAUDE.md` — "configuration is code" gains the loadout rule, and
  the variants section becomes the chassis section.
- `lib/reactor_sim/CLAUDE.md` — the symbols-as-values trap list gains the loadout.
- `docs/reference/settlement.md` — only if promoting the blastpipe changes how `path_head`
  composes, which it should not.
- `docs/current_progress.md` — the direction note, the gaps table, and the crew-roster TODO.
- `app/CLAUDE.md` — the panel problem, which this either closes or moves.
- `spec/CLAUDE.md` — a row for the assembly spec.

---

## 15. Where stage 1 departed from this sketch

Built 2026-09-13. Three departures, one of which matters.

### The acceptance test could not be "bit-identical", and the reason is a real finding

§12 promised a bit-identical digest for stage 1. That is **unachievable for any change that
reorders links**, and parts owning their links necessarily reorders them — in the old list the
regulator's two links sat either side of the safety valve's and the plug's, which no slot
ordering can reproduce.

Measured, on the real engine, changing nothing but link declaration order:

```
as declared         608.183 kPa   173.9129 rpm
reversed            608.046 kPa   173.9256 rpm
shuffled            607.866 kPa   173.9815 rpm

node order reversed — bit-identical
```

The divergence appears on **tick 1** at `1e-16` relative — one ulp of a double, in float
summation order. `graph_spec` asserts link-order independence and passes, because it asserts it
on `LoopRig`: four nodes, 60 ticks, nothing to amplify.

**The two chassis turned out to be a controlled experiment for what amplifies it.** Over the
same 3600-tick startup, the high-pressure engine diverges and keeps diverging, while the
atmospheric one diverges transiently around tick 2700 and returns to a **byte-identical digest
by 3600**, with total mass bit-identical the whole way. The difference between them is the
blastpipe: Trevithick's engine exhausts up its own chimney, closing a draught loop — blastpipe
→ draught → fire → pressure → speed → blastpipe — that multiplies a perturbation, where Watt's
exhausts into a condenser and has no such loop. The last bit is not the problem; the loop gain
is. Which also means a future operation with weaker feedback may well be bitwise reproducible
under reordering, and one with stronger feedback will be worse.

**Invariant 2 is untouched** — `seed + command log` still replays bit for bit, because link
order changes only when the code does. What is not true is the weaker claim that two
declaration orders of the same graph agree bitwise, and that claim matters exactly once: during
a refactor like this one.

What was proved instead, all of it exactly:

| | |
|---|---|
| node set and every node's configuration | identical |
| link **set** (sorted) | byte-identical, both chassis |
| control points, in order | byte-identical |
| instruments, in order | byte-identical |
| `panel` digest | byte-identical |
| cold state digest | byte-identical, both chassis |
| atmospheric running state at t3600 | **byte-identical**, mass bit-identical |
| high-pressure running state | agrees to ~1e-15/tick; 174.84 → 174.77 rpm at t3600 |

Making it bitwise means order-independent accumulation in `Arbiter` — sorting contributions by
a stable key before summing. That is a real change with its own risk and it is **not done**;
it is recorded in `current_progress.md` as a live decision.

### `Slot` came out smaller than §5 drew it

§5 gave slots a `run:` with endpoints. In the build they have none, because **`:omit` needs no
machinery at all** — an unfitted part contributes no fragment, so its links leave with it for
free. Only `:bypass` has to know where the two ends are, and only it declares them. A part's
links live in its own fragment and may name nodes it does not own, exactly as the old central
list did, with `validate_graph!` catching a missing neighbour.

`Slot` therefore validates three things and does one: `when_empty: :bypass` needs a `bypass:`,
`:omit` forbids one, and a `required:` slot cannot declare one at all — because a statement that
can never be checked is how a silent off switch gets written, and this engine has paid for five
of those.

### The crew did not move into `options:`

§10 said it should happen at the same time. It did not: the roster is still rebuilt from code.
The risk it names is real but not yet live — a crew only diverges on restore once it can be
hired, injured or dismissed, and it cannot. The `TODO` in `definition.rb` stands.

---

## 16. The blower, pulled forward out of stage 3

Done 2026-09-13, ahead of the rest of stage 3, as the first real exercise of the machinery.

`head_pa: 600.0, head_control_id: :blower` on the damper became **`:blower_fan`, its own conduit
in series** on the air path — and with it the engine's **first optional part** and first
`when_empty: :bypass` slot. Unfitted, the atmosphere joins straight to the damper and the fire
draws on stack buoyancy alone. That is a real machine (every naturally-drawn boiler is one) and
a real decision, because a cold stack has no draught: an engine built without a blower cannot
raise its own first steam. No extra power, and you find out it is missing at the worst moment —
exactly the shape §7 wanted from the safety tier.

### It is physics-neutral, and the atmospheric engine proves it to the joule

| | |
|---|---|
| total mass | **bit-identical** |
| boiler, fire, rpm, cylinder at t900 / 1800 / 2700 / 3600 | unchanged |
| `total_joules` | **+586,300 J exactly** |

586,300 J is `2000 J/K × 293.15 K` — the new casing's own heat content appearing on the books,
and nothing else. The high-pressure engine shows the usual ulp-level drift, for the link-order
reason in §15.

### It cost one bug, and the bug is worth more than the part

The first attempt gave the fan **no conductance**, reasoning that a fan is a pressure source
rather than a restriction. Physically true; fatal here. `Arbiter.gas_coupling` requires *every*
conduit on a path to declare a conductance and returns nil otherwise — so one nil turned the
whole air path rate-driven, and **a rate-driven path has no head at all.** The draught, the
chimney and the blower stopped existing together: 296 K firebox, 3 kPa boiler, dead on both
chassis, and **no error of any kind.**

The fix is `conductance: Float::INFINITY`, which is the faithful spelling of what the attribute
did: series conductances combine reciprocally, so `1/∞` contributes exactly zero and the
damper's measured rating comes through untouched. A finite value re-rates the path — 1000 moves
it 0.03%, enough to invalidate the seven-point sweep that chose `damper_conductance`.

**This is the one place in the engine where `Float::INFINITY` is a statement rather than a
silent off switch** — it says "not the restriction" — and it is only safe because the
restriction it defers to is next door and measured.

### WIP, and flagged

`Parts.register(:stock_blower, ..., wip: true)`. The blower is still free and should not be;
`Part#wip` exists so the outfitting screen can say so rather than presenting an unfinished part
as a finished one. The cost is crew time first and a consumable second, under the **black-start**
constraint — a player may be the only one generating power in a match, so nothing may depend on
electrical supply. A fuel-oil reserve bolts on here when minions land, which is now stage 6.

---

## 17. Stage 2: what can be left off

Done 2026-09-14. **Seven optional slots of twenty**, each removed *on its own* — removing all
seven at once would only tell you the result is bad, not what any one part is for. Measured at
2400 ticks through the spec's own startup, high-pressure chassis:

| Left out | | Drum | Speed | What it means |
|---|---|---|---|---|
| *(stock)* | | 608.0 kPa | 174.5 rpm | pinned on its valve |
| **safety valve** | `:omit` | **687.0 kPa** | **196.6 rpm** | **more power** — the shell's derived rating is the only limit left |
| **cylinder relief** | `:omit` | 608.5 kPa | 0.9 rpm | **`cylinder_failure` on an ordinary startup** |
| **blower** | `:bypass` | 8.8 kPa | 0 rpm | never lights — a cold stack has no buoyancy |
| **boiler tubes** | `:bypass` | 101.7 kPa | 0 rpm | plain shell boiler; radiant path only |
| ashpan | `:omit` | 608.0 kPa | 174.5 rpm | no effect *yet* — ash takes thousands of ticks |
| cylinder cocks | `:omit` | 608.0 kPa | 174.5 rpm | no effect here; the hazard is warming through |
| fusible plug | `:omit` | 608.0 kPa | 174.5 rpm | no effect here; only matters below the crown |

Each takes **exactly its own pieces** — one node, one or two links, its levers, its gauges — with
no edit anywhere else. That is the entire return on §2's decision to have parts contribute
fragments.

### The result the design needed

**The safety valve costs power.** Taking it off is +13% pressure and +13% speed. That makes
going without a *decision* rather than a strictly-worse choice, which is the claim §7's
error/warning split was built on and which was untestable while the valve was welded in.

### The finding that corrected a comment

**The cylinder relief valve is load-bearing during an ordinary start**, and its own note said
the opposite. The note was about the valve's *setting* — genuinely inert in steady running, and
that half was right — but its *presence* is not: warming through fills a cold cylinder with
condensate (peak occupancy 0.859, "knocking badly"), the valve lifts, and the engine survives a
scare that teaches the procedure. Remove it and the same startup wrecks the cylinder. The
comment in `definition.rb` now distinguishes the two claims.

### Three parts that change nothing, correctly

The ashpan, the cocks and the fusible plug show **no effect at all** over a normal run, because
their hazards are slow (ash takes thousands of ticks to bank up) or conditional (the plug only
matters once the water is below the crown sheet). They are covered where those conditions are
reached — `the grate silts up` at 7200 ticks, `water in the cylinder`, `crown_sheet_spec`. A
"stripped build behaves identically" result is alarming only if you expected every part to
matter in every scenario.

### Two departures from the sketch's list

- **`boiler_tubes` was added**, and it is the biggest single upgrade on the machine. A tubeless
  boiler is a real historical object rather than a broken one, and `:bypass` expresses it
  exactly: the flue gas goes straight from firebox to chimney and only the radiant path is left.
- **The condenser was not made optional.** §6 already concluded it is a chassis decision, and
  stage 2 confirmed it: on Watt's engine the vacuum *is* the prime mover and the cylinder
  exhausts into it, so an atmospheric engine without one is not a machine with a part missing —
  it is one whose exhaust has nowhere to go. `assembly_spec` pins this so nobody finishes the
  job later.

---

## 18. Stage 3: the chassis gives up its numbers

Done 2026-09-14. This is §1's observation carried out: `VARIANTS` was twenty keys of which
**seventeen belonged to six parts that were not separate objects yet.**

Eight kinds gained a second variant, and the loadout now genuinely identifies a machine — where
before `:stock_boiler` named two different ones, which is a lie the outfitting screen could not
have worked around:

| Kind | High-pressure | Atmospheric |
|---|---|---|
| boiler | `:locomotive_boiler` | `:beam_boiler` |
| chimney | `:blastpipe_chimney` | `:plain_chimney` |
| damper | `:wide_damper` | `:narrow_damper` |
| safety valve | `:ramsbottom_safety_valve` | `:low_pressure_safety_valve` |
| cylinder | `:high_pressure_cylinder` | `:atmospheric_cylinder` |
| cylinder relief | `:high_pressure_cylinder_relief` | `:low_pressure_cylinder_relief` |
| flywheel | `:light_flywheel` | `:beam_flywheel` |
| mill | `:mill_drive` | `:slow_mill_drive` |

`CHASSIS` keeps `exhausts_to`, `condenser`, a `parts:` map of the eight that vary, and
`burst_pa`. **`burst_pa` is the one entry still in the wrong place** — it is the pressure gauge's
full-scale reading rather than a physical limit, and it stays because the panel catalogue is
built from the chassis and does not know which boiler is fitted. Moving it needs parts to own
their `Diagnostic`s, which is §4's Option A.

### Acceptance: bit-identical, and this time literally

Every node, link, path, control point, instrument, panel digest, cold-state digest, all four
running digests, mass, joules and per-node digest matched on **both** chassis. The only line that
moved in the entire comparison was the loadout. Unlike stage 1 this was achievable, because
nothing here reordered the link list — see §15 for why that is the thing that decides it.

### The blastpipe did not want promoting, and §5 was wrong about it

§5 listed the blastpipe with the blower and the stack as an attribute that had to become its own
node to become a part. The blower genuinely did — it is a fan bolted to the ashpan, and §16
records what that cost. The blastpipe is different on two counts, and both point the same way.

*Physically*, a blastpipe and the chimney above it are one assembly: their proportions were tuned
together, and getting that ratio right was the central art of locomotive draughting. A nozzle
without the stack it points up is not a thing.

*Mechanically*, splitting them could not have worked. The blast head has to reach **both** paths
through the chimney — the draught path from the firebox and the cylinder's own exhaust — and
today it does, because the flue sits on both. A separate blastpipe node between the tubes and the
flue would sit on the draught path only; one placed to catch both would have to own the chassis's
exhaust link, which is not a fitting's to own.

So it is a chimney **variant**, `stack_height_m` stays a chimney property, and a taller stack is
now a straightforward future variant rather than another promotion. The general lesson: *an
attribute becomes a node when it is a separate object in the machine, and a variant when it is a
different version of the same object.* The blower was the first; the blastpipe was the second.

### One pattern worth copying

**Where two parts of a kind differ only in numbers, the wiring is written once.** Eight
`*_fragment` helpers in `parts.rb` hold the shape; the sixteen registrations hold only the
figures and the sweeps that chose them. Duplicating the fragment would have been sixteen chances
for two variants to drift apart on something that is not supposed to vary at all.
