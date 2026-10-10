# Mine follow-ups — minion-caused accidents, and the crew ceiling

Input to design. Not a description of anything that exists.

Follows [`mine.md`](mine.md). Everything here is sequenced *after* the mine is playable, because
every one of these mechanics is only legible against a machine somebody is already running.

---

# Part 0 — The crew ceiling, and why it shapes everything below

The first mine runs a full crew of **12–20**, not the ~100 a real colliery shift carried. Nothing
else scales down: geometry, power draws, districts, hazards and the tech tree are all full size.
The mine is simply undermanned, and is correspondingly less productive. More crew quarters is the
upgrade that lifts it.

That ceiling is not a simplification of the simulation — it is a limit on the **crew management
UI**, which today is one `<select>` per minion in
[`crew_component.html.erb`](../../app/components/crew_component.html.erb). Twenty dropdowns is
already the edge of usable. Going past it needs a proper design pass on minion management, not more
`crew_capacity`.

**This matters for everything below**, because each mechanic in this document adds something the
player must know about each individual: who is competent at what, who is tired, who is somewhere
dangerous, and whose readings are worth believing. Twenty people × four new facts is a UI problem
before it is a simulation problem.

> **Recommendation.** Treat "crew management that works past 20" as a **prerequisite for enjoying**
> these mechanics, though not for building them. Build the mechanics against 12–20, where the
> existing UI holds. Do not raise `crew_capacity` past ~20 until the management pass lands.

## The rate trap this creates

**Tune accident frequency per *shift*, not per *person*.** With twenty independent minions, the
rate the player experiences is twenty times the rate any individual carries. A figure that reads
"reasonable" per-person produces an accident every few minutes at the shift level.

This is the headcount version of the trap already in
[`current_progress.md`](../current_progress.md): *"check which clock a rate is against before
calibrating it"* — the one that shipped fatigue 40× too slow. Same error, different denominator.
Pick the shift-level frequency first and divide.

---

# Part 1 — The problem

Today there is exactly one route into harm: a part breaks, and `failure_hazards` on that part
endangers the stations beside it (phase 6b). Every injury in the game originates in machinery
failing.

The mine wants a second route — **the minion was the cause.** Three modalities:

1. **Misreading a gauge.** An untrained ogre in charge of the flame readings sends the wrong
   number, and the player acts on it.
2. **Doing the wrong thing.** You command X; they do Y. Gated on `boneheaded`, or on being put in
   charge of something complicated without the wit or the training for it.
3. **A basic mistake.** Falling down a shaft with no railings. Getting caught in machinery.

These are genuinely different problems and want genuinely different mechanisms. Lumping them into
one "mistake system" is the main trap here.

## The constraint everything must satisfy

From [`lib/reactor_sim/CLAUDE.md`](../../lib/reactor_sim/CLAUDE.md):

> **Entropy may only be drawn in three places:** `initial_state`, phase 0 (`actuate`), and phase 7
> (`observe` / `Diagnostic#record`).

And the house doctrine from [`concerns/CLAUDE.md`](../../lib/reactor_sim/concerns/CLAUDE.md):

> **Incidents are never a per-tick dice roll.** Stress accumulates deterministically from operating
> conditions, so a player can learn "I ran it too hot for too long" rather than being told the dice
> disliked them.

These look contradictory — accidents need to be uncertain, but uncertainty is rationed and
per-tick dice are forbidden. They are not contradictory, and the resolution is the organising
principle for this whole document:

> ### Roll per episode for what undoes itself. Roll per stretch of work for what does not.
>
> A gauge that reads wrong is self-correcting — the next reading, or the one after the observer
> changes their mind, is right. That is cheap, reversible, and a draw in phase 7 is honest;
> `Filters::Misread` and `Filters::Stick` already work this way and nobody considers them a
> problem.
>
> A person maimed is not reversible. That needs the `durability_range` / `resilience` pattern: a
> **hidden threshold**, rolled from a wide spread, crossed by accumulated exposure rather than by a
> die. The player learns *"I worked them too long in a bad place"* rather than *"the dice disliked
> them."*

Everything below follows from that split. The one place it is not enough — and the amendment that
matters most in Part 4 — is that a threshold *crossed once and never reset* still produces a
deterministic, learnable, farmable budget. **The margin has to come back**, and it has to be
re-rolled when it does, or the player eventually maps the risk exactly and stops taking any.

## Two pieces of luck already in place

Both of these were found in the code rather than designed here, and both make this much cheaper
than expected.

**Every minion already has its own RNG stream.** `Operation#build_rngs` keys a stream by component
id, and *ids are one flat namespace across nodes, control points, diagnostics and minions*. So
`rngs.fetch(:crew_3)` already exists and is already snapshot-safe. It is currently drawn from
exactly once, at `initial_state`.

**Phase 0 is already reserved for this.** `ControlPoint#actuate`:

```ruby
# Phase 0. Converge the actual toward the target at whatever rate the operator can
# manage. Deterministic; any mishap entropy belongs to the minion, drawn here.
```

The comment reserves the phase. The method just does not take an `rng` yet.

---

# Part 2 — Misreading a gauge

## What exists

`Filters::Misread` is already written, and its comment says what it is waiting for:

```ruby
# Someone who cannot really tell, reporting anyway.
#
# Not an instrument fault — an observer fault. An untrained underling eyeballing a
# fitting is occasionally and confidently wrong, which is a different and funnier
# failure than a gauge being noisy. Intended to be driven by whoever is on that
# station once minions land.
class Misread < Base
  def initialize(chance:, magnitude:)
```

`Filters::Stick` is the same shape. And `Diagnostic#observer` is the declared seam:

```ruby
# Reserved for minions: whoever is watching this instrument will drive the parameters
# of the filters above. Carried now so the seam exists before there is anything to put in it.
@observer = observer&.to_sym
```

So the mechanism exists, the seam exists, and neither is wired. The only real question is **how
competence reaches a frozen filter.**

## The problem

A filter is frozen configuration built at assembly time. `@chance` and `@magnitude` are baked in.
Competence is runtime state belonging to whichever minion is posted where.

### Option A — the filter reads competence off `Context`

Add the observing minion's competence to `Tick::Context`, and let `Misread#apply` read it.

**Pros.** No signature changes; `ctx` is already threaded everywhere.
**Cons.** Puts crew state on the diagnostic hot path for every filter, including the ones that
could never care. `Context` is deliberately a narrow window onto nodes — *"it is not a licence to
reach anywhere"* — and crew state does not belong in it.

### Option B — `Diagnostic#record` resolves one scalar and passes it down the chain ★

The diagnostic resolves its `observer:` to a posted minion, computes a single **reading
competence** scalar, and passes it alongside `rng` into `run_chain`. Filters that care use it;
the rest ignore the argument.

**Pros.**
- One new argument, one new resolution, contained entirely in `Diagnostic`.
- The `distortion?` split already separates filters that make a reading *worse* from those that
  change what it *means*, and **the ones competence should modulate are exactly the distorting
  ones.** The existing taxonomy is already the right taxonomy.
- The spectator's undistorted pass skips them and therefore skips competence too — which is
  correct: a god-view should not see the deputy's mistake.

**Cons.** Changes `Filter#apply`'s arity, which touches every filter class and every filter spec.
**Mitigation:** pass it inside `ctx` — no, see Option A. Pass it as a keyword with a default of
`1.0` and only the three distorting filters that care will read it.

### Option C — swap the diagnostic based on who is posted

Build several diagnostics and select by observer.

**Pros.** No plumbing at all.
**Cons.** Combinatorial; the instrument changes identity under the player, which breaks the delta
protocol and `PANEL_ORDER`'s promise that a gauge stays where it is. **Reject.**

> **Recommendation: B.** One scalar, defaulted, read by the filters that already declare themselves
> distortions.

## What competence means here

A blend, in the shape `effort:` already uses — `intelligence` weighted heavily, `dexterity`
lightly — multiplied by condition (health × (1 − fatigue), same as `Minion#capability`), and
modified by tags. The tags already exist and were written for this:

| Tag | Where it lives now | Effect on reading |
|---|---|---|
| `keen_eyed` | Elowynne | Better |
| `practised` | Jim, and the `steady_hands` training | Better |
| `green` | the day-labourer | Worse |
| `unlicensed` | the day-labourer | Worse, on anything certificated |
| `darkvision` | elf, kobold, `hand_lamp` | **Gates reading at all, underground** |

`darkvision` is the interesting one. In a mine, a reading taken in the dark is not a reading. The
mining sketch already reads `mining_effectiveness × darkvision` for output; the same product
should gate observation. **A gauge nobody can see is not misread — it is `:offline`.**

## Who is the observer, and what if nobody is?

`observer:` should name a **station**, not a minion — the same rule `endangers:` follows, and for
the same reason: *a station is fixed by the machine and a roster is the player's.* Resolve it
through `station_index`, which already exists.

**When nobody is posted there**, two rules are defensible and the difference matters:

| Rule | Reads as |
|---|---|
| Unobserved gauge reads true | It is a dial on a wall; the player can see it themselves |
| Unobserved gauge is `:offline` | The reading *is* somebody's report, and nobody reported |

> **Recommendation: let the declaration decide.** An instrument with **no `observer:`** is a dial —
> it reads true, as every gauge does today. An instrument that **declares `observer:`** is somebody's
> report, so with nobody posted it goes `:offline` and shows "—".
>
> This makes "post a deputy to the district" a real decision with a visible consequence, and it
> costs nothing: `Sources` already report unavailable and diagnostics already flag `:offline`
> rather than fabricating a zero.

## The counterplay is knowing who you posted

**The counterplay is upstream of the reading, not in it.** A player who knows their minion's stats
and tags, *and* knows what the station demands, is already fully equipped to judge how much to
trust the number. Send a low-intelligence, `boneheaded`, uncertified ogre to take the flame
readings and you should already be on your guard — that is the decision, and it was made when the
minion was posted.

That puts one requirement on the design, and it is a **declaration**, not a UI pass:

> **A station must say what it demands.** `complexity:` (Part 3) plus the observer requirement is
> enough for a panel to eventually render *"this post wants: intelligence, a deputy's ticket"*.
> The declaration has to exist now so the surface can read it later; nothing has to be rendered
> yet.

Given that, the reading itself does **not** need to advertise its own unreliability, and should not.

### A bad observer must be able to be confidently wrong, and stay wrong

`Filters::Misread` as written redraws every tick and holds a wrong value for exactly one tick, so
an incompetent observer produces a *jittery* reading. Jitter is fine and worth keeping — it is a
real tell for a player who is watching — but **it must not be the only failure.** Somebody who
cannot really tell is not merely imprecise; they form a wrong belief and report it steadily. A gas
reading that sits confidently at 2% while the district climbs through 6% is the failure that
matters, and it is the one that kills a shift.

Three ways to get a held wrong reading:

1. **Reuse `Stick`.** ✗ Stick holds the last *true* value. A stale-but-true reading is a different
   and lesser failure — the player is behind, not deceived.
2. **A new `Conviction` filter.** Workable, but a second filter overlapping `Misread` invites the
   two to be chained and disagree about who owns the error.
3. **Give `Misread` a hold, on `Noise`'s deadband pattern.** ★ Once wrong, stay wrong — until the
   underlying value has moved further than a deadband, at which point re-decide.

> **Recommendation: 3.** The precedent is already in the codebase with the rationale written out:
> `Noise` holds its offset because *"a miscalibrated gauge reads consistently wrong, it does not
> reroll its error every quarter second"* — which is exactly the claim here, applied to a person
> rather than an instrument. It also inherits the protocol benefit that change of design bought:
> a held value does not report a change every tick, so "send only what changed" keeps compressing.
>
> A bad observer then has **two** failure modes off one filter: frequent small errors that read as
> jitter, and occasional large ones that hold. Competence drives `chance`; the hold duration or
> deadband can be a second dial or simply reuse the magnitude.

### Still declare `observer:` on very few instruments

The flame-cap gas reading, and perhaps roof condition. If every gauge becomes a person's opinion
the panel stops being trustworthy at all and the player disengages from instruments entirely,
which is the opposite of the intent. **A second opinion** — post a checkweighman, or fit a second
instrument, and disagreement is the tell — stays available as a later fitting, and is historically
exact (two deputies, or a deputy and the overman). It is not needed for the mechanic to be fair.

## What this costs

Small. `Diagnostic#record` resolves an observer; `run_chain` carries one scalar; three filters read
it; `Misread` and `Stick` get specs against a competent and an incompetent observer. No new phase,
no new entropy point, no invariant change. **`Filters::Misread` already draws in phase 7, which is
already permitted.**

---

# Part 3 — Doing the wrong thing

Phase 0, where the comment already says mishap entropy lives.

## The gate

Per the requirement, a slip is possible only when the minion has the **`boneheaded`** tag, *or*
they are at a control that is genuinely complicated and they lack the wit or training for it.

That second clause needs something a control point does not have: a declaration that it is
**tricky**. This is the natural parallel to `effort:`:

| Declaration | Says |
|---|---|
| `effort:` | This is work, so **how fast** it happens depends on who does it |
| `complexity:` | This is tricky, so **whether it happens correctly** depends on who does it |

The two are orthogonal and should stay so. A strong idiot stokes perfectly well and sets the
cut-off wrong. A brilliant weakling is the reverse. Today `effort:` alone would make the strong
idiot good at everything.

```
ControlPoint.new(id: :ventilation_doors, complexity: 0.6, requires: :deputies_ticket, ...)
```

Read against `intelligence`, the relevant training tag, and `boneheaded`.

**`boneheaded` is a new tag** and belongs beside `clumsy` in
[`races.yml`](../../content/archetypes/races.yml) — `clumsy` makes the *bite* worse, `boneheaded`
makes the *mistake* likelier. Same family, opposite ends of the causal chain, which is a useful
thing for the two names to signal.

## What "wrong" means — four candidates

| | What happens | Visible to player? | Drama | Cost |
|---|---|---|---|---|
| **a. Wrong magnitude** | Overshoots or undershoots the target | Barely | Low | Trivial |
| **b. Wrong direction** ★ | Moves the lever the wrong way | **Yes — the lever visibly goes wrong** | Good | Trivial |
| **c. Wrong lever** ★★ | Operates a *different* control entirely | Yes | **Best** | Needs the spatial model |
| **d. Nothing at all** ★ | Freezes, or acts late | Yes — the lever sits still | Good | Trivial |

**(a) is weak.** It is indistinguishable from a slow lever and from ordinary incompetence, both of
which `rate_multiplier` already models. It adds a mechanic the player cannot perceive.

**(b) and (d) are cheap and legible.** Both are visible in `actual` diverging from `target`, which
the panel already renders — `controls` reports `{ target:, actual: }` per lever precisely so a
client can show a valve still travelling. The player sees it, swears, and re-commands. Reversible,
which is why a per-tick draw is acceptable.

**(c) is the funniest and is the explicit ask** — *"you give a command to perform X and they do Y"*
— but "which other levers could they have grabbed instead" is a question about **where they are**.
Once volumes land, the answer is free: the other levers in this volume. Before that, it needs a
hand-written adjacency table, which is the abstract place graph
[`mine.md`](mine.md) §4.2 deliberately rejected.

> **Recommendation: ship (b) and (d) with the mine; add (c) immediately after the spatial model,
> where it costs almost nothing.** Skip (a) entirely.

## The trap that would make this ship dead

**Every steam engine lever has `stiffness: Float::INFINITY`.** So `actuate` returns
`state.merge(actual: target)` on its second line and **throws `rate_multiplier` away before reading
it.** Phase 0 is currently inert on every shipped machine — `spec/reactor_sim/minion_spec.rb` says
so outright, and builds its own rig because the engine's specs *"pass whether or not a minion is
ever consulted."*

So a mine that wants fumbling must ship **finite `stiffness`** on every control that can be
fumbled, or the entire mechanic is unreachable and every spec still passes.

This is precisely the trap the progress doc names as *"a tier nothing can reach is a tier that does
not exist"*. **Verify by driving the real machine**, not by reading the arithmetic.

> **Closed.** `Mine::Travel` gives the seven valves figures in percent of range per second — the
> fan is forty seconds hard over — and `lever_travel_spec` drives the real machine rather than
> the arithmetic. Effort stations stay infinite deliberately. Three findings worth carrying into
> the work below:
>
> - **The whole path was already built and only the value was missing.** `crew_multiplier`,
>   `settling?`, `target`/`actual` in the projection and a ghost marker in the console all
>   existed and were unreachable. Check for that before building anything here.
> - **An unattended lever travels at its rated speed**, decided rather than defaulted: the fan,
>   pump and winder are at bank where nobody is posted, so freezing them would be a pit whose
>   fan could never be started. A body makes a lever faster or slower, never possible at all.
> - **Nothing in the mine's 123 hazard examples moved.** A forty-second travel is invisible to a
>   spec that sets a lever and runs for thousands of ticks, which is all of them.

## Idempotence is not threatened, and it is worth saying why

A slip changes `actual`, never `target`. The command log still carries absolute destinations, still
replays identically, and still needs no dedup table. **The mistake is in the execution, not in the
instruction** — which is both the correct model of a real mistake and the only version that does
not break the Kafka ingress (invariant 4).

---

# Part 4 — Basic mistakes: the accident model

The irreversible one, and the real work. This is also the piece that overlaps what
[`current_progress.md`](../current_progress.md) item 6 reserves as **"Probabilistic injury — Tim is
designing this one"**, so what follows is a proposed shape rather than a settled design.

It respects the one rule that item already fixes:

> A tired worker gets their hand caught in the belt; **the belt does not then care how tired they
> are.** So fatigue belongs on the *incidence* of an injury and never on its severity.

## The shape: `Wearing` for people, a second time — but renewable

`Injury` is already *"`Concerns::Wearing`, for minions"* — `durability`/`failure` became
`resilience`/`injury`. The accident model is the **other half** of the same borrowing: `Wearing`
has two routes into failure, and `Injury` today implements only one.

It departs from `Wearing` in one decisive way. **A part's durability only ever goes down. A
person's margin comes back.**

| `Wearing` | `Injury` today | Accidents |
|---|---|---|
| `durability`, rolled from `durability_range` | `resilience`, rolled from `RESILIENCE_SPREAD` | **`margin`, rolled from a WIDE spread** |
| `stress_per_second` grinds it down | — nothing accrues | **`peril` spends it, in jagged bursts** |
| — never recovers | — never recovers | **recovers fast when the work is safe** |
| Crossing zero → `part_failed` | — | **Crossing zero → an accident** |
| `overload?` — one blow, immediately | `MORTAL_BITE` | unchanged |

So: **a minion carries a hidden margin of safety. Dangerous work spends it in bursts; safe work
and rest restore it; when it runs out, something happens to them.** It is closer to a stamina bar
than to a durability bar, and that is the point — a worker who has had a bad hour on the haulage
road is not condemned, they need taking off it.

Every property the codebase cares about still falls out:

- **No new entropy point.** The roll is at `initial_state`; re-rolls happen in phase 0.
- **No per-tick dice.** Accrual and recovery are deterministic from conditions.
- **Replay, snapshot and order-independence** hold unchanged.
- **The player can learn it.** *"I left the green one on the haulage road while he was exhausted
  and never rotated him off"* is a sentence the player can say.
- **`Injury` itself needs no change at all.** The accident produces a hazard in the shape phase 6b
  already consumes, and `Injury.check` runs unmodified. **The Danger Check still throws no dice** —
  the dice were thrown for *incidence*, not for *severity*.

That last point is what makes this worth doing this way rather than any other.

## Determinism versus the *appearance* of randomness

These are not in tension, but the distinction has to be stated precisely because a careless reading
of "it should feel random" breaks invariant 2.

- **Within one match, replay is bit-identical.** Same seed, same command log, same accidents, in
  the same order, forever. That is non-negotiable and nothing here threatens it.
- **Across matches, the seed differs**, so the same minion at the same post has a genuinely
  different margin and therefore a different outcome. That is where the randomness lives.

> **Trap, and it will bite during development.** `DevMatch` runs **one hardcoded match with a fixed
> seed** and is *reset* rather than ended. So in dev, two runs produce the identical roll and the
> mechanic will look rigidly deterministic — the same worker dying at the same moment every time —
> which is exactly the symptom this design is trying to avoid and exactly what you would conclude
> the design had failed to fix. **Vary the seed by hand when evaluating this.** Real per-match
> seeds arrive with match lifecycle.

## The spread has to be wide, and the tails matter more than the middle

`RESILIENCE_SPREAD` is `(0.85..1.35)` — deliberately narrow, because it modifies a threshold the
player is meant to be able to reason about. **The margin spread is the opposite and should be
wide**, because its whole job is to stop the player ever being *sure*.

Two outcomes have to be reachable, and they are the design targets:

| Case | Should happen | Why it matters |
|---|---|---|
| A genuinely poor worker, exposed to only **modest** risk, goes a whole match unharmed | **Often** | Otherwise bad minions are unusable rather than risky, and the last-resort standin stops being a real option |
| A well-suited, competent worker at **hazardous** work is hurt anyway | **Rarely — order 1 in 10 to 1 in 100 matches** | Enough that the player must account for it; rare enough that trust in a good worker is still worth having |

Without a wide spread the player eventually learns *"eight minutes on the haulage road is safe"*
exactly, and then farms it: unsuited workers doing a metered amount of dangerous work at no real
risk. **The variance is what makes the risk a risk** rather than a budget to spend down.

### The information leak, and the fix

A renewable bar plus a threshold rolled once has a flaw worth naming: **a worker who has survived a
long exposure has revealed a high roll.** After twenty minutes on the haulage road the player knows
this one is lucky, and with a regenerating bar they become a known-safe worker forever.

> **Fix: re-roll the margin whenever it refills.** The roll is not a permanent property of the
> person, it is a property of *this stretch of work*. Refilling to capacity ends the episode and
> draws a new one; so does an accident. Between transitions everything stays deterministic, and the
> draws happen in phase 0 where they are permitted.
>
> This also stops a rested worker inheriting a bad roll indefinitely, which would be the mirror-image
> unfairness.

## Jagged, not a smooth drip

**Peril must arrive in bursts tied to what the machine is doing, not as a per-second trickle.**
This is the single most important shape decision in the model, and it does three jobs at once.

A smooth rate creates a hard steady state: if recovery exceeds accrual the worker is *perfectly*
safe forever, and if it does not they are *certainly* hurt eventually. Both halves of that are bad
— the first is a farmable exploit, the second is a countdown. A binary cliff, and the player can
feel exactly where it is.

Bursts remove the cliff. The danger of a haulage road is not "being on it", it is **the tub going
past**. The danger of the shaft bottom is the cage arriving. So:

> **Peril accrues in proportion to activity at that place** — tubs passing, winds per minute, shots
> fired, props being set — rather than to time spent there.

What that buys:

1. **Running the mine harder makes it more dangerous.** Production and safety become the same dial,
   which is the central tension of the whole operation and is historically exact. The player is not
   choosing "safe or unsafe", they are choosing a rate.
2. **A low average can still kill.** A worker whose recovery comfortably exceeds their *average*
   accrual can still be caught by a burst arriving while the bar is low — which is precisely the
   1-in-100 tail the table above asks for, obtained without a single die roll.
3. **A badly-suited worker burns through in minutes.** Because the multipliers below are
   superlinear, a burst that costs a competent hand a sliver costs a `clumsy`, exhausted,
   `unlicensed` one a large fraction of everything they have. The user-facing claim — *a really bad
   worker in a really bad place is in trouble within minutes* — falls straight out of that, with no
   special case.

Fatigue's own accrual is already squared for the analogous reason (*"half effort costs a
quarter"*). **Use the same shape here and for the same argument**: mismatch between what the work
demands and what the worker brings should compound, not add.

## Where severity comes from: the place, not the person

An accident's severity is declared by **where it happened**, mirroring `failure_hazards` exactly:

```
perils: {
  fall:              { tags: %i[fall],   severity: 3.0, absent_when: :railings },
  caught_in_haulage: { tags: %i[crush],  severity: 2.2, scales_with: :tubs_per_minute },
  struck_by_tub:     { tags: %i[impact], severity: 1.1, scales_with: :tubs_per_minute }
}
```

Declared on the volume node (once space lands) or on the station. `scales_with:` names the activity
figure that both drives the burst and sizes it — the same mechanism `failure_hazards` already uses
to read a magnitude off a failure event, pointed at a running quantity instead.

This gives three things at once:

1. **Fatigue never touches severity.** It scales accrual — incidence — and nothing else.
2. **Safety fittings become real.** `absent_when: :railings` means fitting railings deletes the
   peril outright. An expensive, boring purchase that does nothing visible until the day it saves
   someone — the same shape as stone dusting in the mine's tech tree, and the same satisfaction.
3. **Hazard tags need no engine change.** `%i[fall crush impact]` resist against `fall_resistance`
   etc. through the existing naming convention in `Injury.resistance`.

### `absent_when:` was dropped; there are two mechanisms instead

A fitting that deletes a peril needs no key of its own — **a part that is fitted contributes a
fragment without the fall in it**, which is how every other purchase in the engine works. So
railings are a variant of the gantry, not a flag on the hazard.

That only covers perils you can design out. You cannot run a haulage road without tubs on it, so
the second mechanism buys the remaining risk down rather than removing it: a node answers
`safety_equipment` with `{ place => effectiveness }` and an accident in that place may resolve as
a near miss instead. Three rules make it a purchase rather than a discount:

- **Gated on `Minion#wits`**, so it is worth far less to somebody who never saw the tub coming —
  and because `wits` is itself gated on seeing, an unlit roadway takes the refuge's value with it.
  Manholes limewashed white are a real tier for exactly this reason.
- **Capped**, at `MOST_EQUIPMENT_SAVES`. Buying safety must never buy immunity.
- **It emits.** `:minion_near_miss`, at `warning`. A fitting whose entire value is accidents that
  did not happen is indistinguishable from money wasted unless the engine says so, and the near
  miss doubles as the clearest possible warning about where the next casualty comes from.

## Tags select the accident, not just its likelihood

A tag should be able to unlock **a kind of accident that would not otherwise exist at that place**,
not merely make the common one likelier. A `hulking` minion in a narrow roadway can get wedged;
nobody else can. A small one can be missed by a driver and struck; a big one cannot.

So a peril declares who it applies to:

```
wedged:  { tags: %i[crush], severity: 2.6, when_tagged: :hulking }
struck:  { tags: %i[impact], severity: 1.4, unless_tagged: :hulking, worse_with: :skittish }
```

**Pros.** Race and kit selection for a post becomes meaningful in *both* directions rather than
being a single competence ranking — the ogre is not simply "better" or "worse" in the haulage road,
they are exposed to a different hazard than the kobold is. That is far more interesting than a
scalar, and it gives every archetype somewhere it is genuinely wrong to put them.

**Cons.** The peril table grows combinatorially if every tag gets a bespoke accident, and a peril
that only one archetype can trigger is content that most players never see. **Mitigation:** keep
tag-gated perils rare and reserve them for tags that are already load-bearing elsewhere
(`hulking`, `clumsy`, `skittish`), so each one is a payoff for a trait the player already knows
about rather than a new thing to learn.

### One margin or one per peril?

- **One per peril** gives each hazard its own luck, but multiplies state and rolls, and makes the
  crew panel unreadable if it is ever surfaced.
- **One margin, and the peril that fires is whichever contributed most accrual at the moment it
  crossed** ★ keeps state to a single number and needs no extra accumulators — recompute this
  tick's contributions and take the max. The accident kind then follows the dominant risk, which
  is also the legible answer: a man who has spent the shift beside the haulage gets caught in the
  haulage.

> **Recommendation: one margin.**

## What modulates accrual and recovery

| Input | Accrual | Recovery | Already exists? |
|---|---|---|---|
| The place's peril, × its activity | base burst | — | new |
| `fatigue` | **worse, heavily and superlinearly** | **suppressed** | yes |
| `clumsy` | worse | — | yes (kobold, Galathas) |
| `boneheaded` | worse | — | new (Part 3) |
| `green` | worse | — | yes (day-labourer) |
| `skittish` | worse, situationally | — | yes (kobold) |
| `hulking` | selects a different peril | — | new |
| `hazard_sense` (`pit_sense`) | **better** | — | yes |
| `practised` | better | — | yes |
| `darkvision` / lighting | better | — | yes |
| Standing somewhere **safe** | — | **fast** | needs the spatial model |
| Standing in the **quarters** | — | fastest | yes (`recovery_rate`) |

Almost all of it is already written. `pit_sense` — *"Knows when a working is about to go, and moves
first"* — currently only feeds `Injury.resistance`. It should feed accrual too, and arguably
*mostly* accrual: pit sense is about not being there, not about absorbing it better.

### Recovery is the interesting half

**Fatigue is very heavily weighted, but it must not be the only input**, or the mechanic collapses
into a second fatigue bar and the crew quarters becomes the only answer.

> **A change of work restores the margin, not only a rest.** Recovery is a property of *where
> somebody is standing right now* — the same rule `ControlPoint#recovery` already follows for
> fatigue, where *"an effort station recovers nothing, because you are still at the fire; a valve
> is somewhere to stand down to."* A safe post recovers margin while still being productive.

That makes **rotating the shift through dangerous and safe posts** a real strategy, which is
exactly the game a shift manager is playing, and it is a strategy that costs the player attention
rather than money. It also means the margin recovers on a timescale of minutes rather than a
match — fast enough that the answer to a low bar is a decision, not a write-off.

Two interactions to get right:

- **Fatigue already has a pole.** `capability` contains `(1 - fatigue)` and accrual has a
  singularity at 1.0, which is why `LOAD_CEILING` exists. A margin accrual that also divides by
  something fatigue-derived would stack two poles. **Multiply by a bounded fatigue term; never
  divide.**
- **A spent minion mans nothing**, so they stop accruing work-driven peril the moment they are
  spent — but they are still *standing there*, and a place's peril is not conditional on working.
  Decide deliberately whether being spent at a dangerous post is safer than working at one. It
  should not be.

## Where the re-rolls happen

Two transitions end an episode and draw a new margin: **the bar hits zero** (an accident) and
**the bar refills to capacity** (the stretch of work is over). Both are transitions, not per-tick
events, so the accrual between them stays deterministic.

The draw belongs in **phase 0**, which is already sanctioned for mishap entropy, already holds the
minion's own RNG stream, and whose own comment anticipates exactly this. That separates **when the
dice are thrown** (phase 0, permitted) from **what happens** (a later, wholly pure phase) — which
is the same separation that makes the existing `Injury` design defensible, reused.

The alternative of pre-rolling a queue of margins at `initial_state` avoids touching phase 0 at
all, but the queue length is an arbitrary cap, a long match exhausts it, and the snapshot carries a
mostly-unused list. Not worth it when phase 0 is already open.

> ### The trap that comes with it
>
> Phase 0 now advances the minion's RNG stream, so **any change to how often it is drawn shifts
> every later draw** and a snapshot taken mid-match replays differently.
>
> **Draw exactly once per minion per tick, unconditionally, and discard it if unused.** A
> conditional draw makes the RNG stream depend on the condition, which is how replay diverges —
> and it diverges silently, days later, on a restore.
>
> This belongs in the traps list the moment the code lands.

## Where the check runs

A new phase. The ordering question is load-bearing and should be decided deliberately, as every
other phase ordering was.

```
6  STRESS   a stress    durability, overload, failure events
            b endanger  what a failure does to the people near it
            c tire      what the work does to the people doing it
            d blunder   what the people do to themselves        <- new
7  OBSERVE
```

**`blunder` after `tire`**, so it reads this tick's fatigue rather than last tick's. The argument
against — that everything should read the frozen N−1 — does not apply here, because this is
sequential within one minion's own state rather than a cross-node read. Order-independence
constrains what *nodes* may see of each other; a minion's fatigue and their margin are the same
object being advanced twice in a fixed order.

Note this also means **`endanger` runs before `blunder`**, so a minion hurt by an exploding boiler
this tick is already carried out and `station: nil` before their own margin is evaluated. That is
correct and worth keeping.

> **The phase lettering in `tick.rb`'s header was wrong** — it labelled these `6a`/`6b` while its
> own inline comments and [`tick.md`](../reference/tick.md) both said `6b`/`6c`. Corrected on
> sight to match phase 4's `a b c` style. Adding `blunder` makes it **6d**.

## The new event

`Event::TYPES` is closed and enumerated, and `event_spec` scans for `type: :name` spelled
literally. An accident needs a type.

**Reuse `minion_hurt`, or add `minion_blundered`?**

- **Reuse.** The consequence is identical — a Danger Check, an injury tier, a station possibly
  cleared. `detail:` already carries `by:` (the source nodes), which could carry the peril instead.
  Nothing downstream needs to distinguish them.
- **Add.** The *cause* is categorically different, and the delivery tier composes meaning from
  types. "Three men hurt by machinery" and "three men hurt by their own mistakes" are different
  sentences, and progression/achievements may well want to tell them apart.

> **Recommendation: reuse `minion_hurt`, and put the cause in `detail:`.** The event vocabulary is
> deliberately small and the rule is that *the engine reports transitions; the delivery tier
> composes meaning*. A `cause: :peril` field in `detail:` lets the delivery tier write both
> sentences without the engine growing a second type for the same transition. Revisit only if a
> consumer genuinely needs to subscribe to one and not the other.

## The risk: accidents that feel arbitrary

The margin is hidden on purpose, so the player can never reconstruct the *moment*. They must always
be able to reconstruct the **exposure** — what they chose, not what was rolled. That needs the
inputs visible before the fact:

- Fatigue is already a bar in the crew panel. Good.
- Where somebody is standing will be visible once space lands. Good.
- **Whether a place is dangerous must be legible**, and so must how hard it is being worked. A
  roadway with no railings has to look different from one with railings, before anyone falls down
  it; a haulage road running at full rate has to look different from an idle one. Since peril
  accrues with activity, **the production dial is also the danger dial**, and the player must be
  able to see that.
- **The minion's own suitability must be legible.** `green`, `clumsy`, `boneheaded`, `hulking`
  against what the post demands — Part 0's UI problem again, and Part 2's counterplay.

> The player should never be able to say *"why did that happen?"* — but they must always be able to
> say *"I knew that was a risk."* Those are different claims, and only the second one has to be
> guaranteed.

**A margin bar should probably never be shown, even later.** Showing it turns a judgement about
exposure into a resource-management readout, and the player starts running people down to 10% on
purpose. The fatigue bar is shown because fatigue is a *cost*; the margin is a *risk*, and risks
stop being risks the moment they have a number.

---

# Part 5 — Summary of recommendations

| # | Mechanic | Mechanism | Entropy | New concepts | Effort |
|---|---|---|---|---|---|
| 1 | Misreading a gauge | Existing `Misread`, given a **hold** on `Noise`'s deadband pattern, driven by a competence scalar `Diagnostic#record` resolves from `observer:` | Phase 7 — **already permitted and already drawn** | reading competence; the hold; `:offline` when unobserved | **Small** |
| 2 | Doing the wrong thing | `actuate` gains an rng; wrong-direction and freeze | Phase 0 — **already reserved by its own comment** | `complexity:` on `ControlPoint`; `boneheaded` tag; **finite `stiffness`** | **Small–medium** |
| 3 | Wrong *lever* | As above, over the levers in the same volume | Phase 0 | none beyond the spatial model | **Small, after space** |
| 4 | Basic mistakes | A hidden **renewable margin**: wide initial roll, spent in **activity-driven bursts**, recovered by safe work and rest, re-rolled on refill. Produces a hazard phase 6b already understands | `initial_state` + phase 0 re-rolls | `perils:` on a place (tag-gated); phase **6d** `blunder`; safety fittings | **Medium — the real work** |

---

# Part 6 — Carrying somebody out

**Not a mine mechanic, and that is the point.** Every operation can hurt somebody where they
stand, and the engine's answer today is the same in all of them: `Injury.apply_mode` clears the
station and the posting and leaves the body exactly where it fell. In the steam engine that was
invisible — the footplate has no geometry, so "carried out" and "standing there hurt" were the
same state. The mine made it visible, and bad air made it lethal: a minion collapsed in a
district keeps taking the hazard that collapsed them, and the only counterplay is a lever at
bank.

That is a real gap rather than a missing convenience. **Rescue is the oldest mechanic in
mining** — the reason apparatus, rescue stations and trained teams exist at all — and the mine
currently has the danger with none of the answer.

## What exists to build on

| Need | Exists | Where |
|---|---|---|
| A place a person is, and a route between places | `Layout`, `Passage`, phase 6d | `graph/passage.rb`, `tick.rb` |
| Somebody walking somewhere on an absolute order | `assign_minion` → `posting`, advanced in 6d | `minion.rb`, `operation.rb` |
| Speed as a property of the person | `Minion::PACE`, through `capability` | `minion.rb` |
| A reason to hurry | `Breath`'s `asphyxia` clock, already a 0..1 rescue timer | `breath.rb` |
| Gear that makes the trip survivable | `rescue_apparatus`, metered in ticks | `kit.rb` |
| A stood-down minion who cannot walk | `apply_mode` clears `posting` — deliberately | `injury.rb` |

**The clock is the part already finished.** `asphyxia` fills while somebody is down in bad air
and drains when the air comes back, so the window a rescue has to fit inside is a number the
simulation already keeps and the UI can already show.

## The shape, and the one hard question

A rescue is: somebody walks to where the casualty is, picks them up, and walks somewhere safe.
Mechanically that is **one minion's movement becoming two minions' movement**, and the hard
question is what a carrier *is*:

**(a) A carried minion's `place` is slaved to the carrier's.** Cheapest. Phase 6d already moves
everybody; a carried person just copies a place instead of computing one. *Cons:* two minions'
states become coupled inside a phase that currently treats each independently, which is a real
order-independence hazard — the carrier must be advanced before the carried, and "before" is
not a thing phase 6d has.

**(b) Carrying is a posting.** `assign_minion(:crew_2, casualty: :crew_1)` — the carrier is
*posted to the casualty* rather than to a station, and the travel phase resolves that posting to
wherever the casualty is. The casualty moves as cargo when the carrier arrives somewhere.
*Pros:* it stays an absolute, idempotent order, which is the invariant that matters most; it
needs no new command shape. *Cons:* `posting` currently means a station id, and this overloads
it.

**(c) The casualty is a load, not a person, while carried** — removed from the place graph and
held in the carrier's state until set down. *Pros:* no coupling, no ordering problem. *Cons:* a
minion that is temporarily not anywhere will surprise every consumer that iterates places,
including the crew screen and any future peril sweep.

> **Lean: (b), with the carried minion's place written by the carrier's own step.** It keeps
> the command protocol unchanged, which is worth more than the tidiness of (c) — and the
> ordering hazard in (a) is avoidable if exactly one of the pair writes both places.

## What it costs the carrier

The interesting half, and the reason this is a mechanic rather than a button:

- **Pace.** Carrying a body is not walking. A `carrying` penalty on `Minion#pace` is the whole
  of it, and it should be heavy enough that a strong minion is meaningfully the better choice.
- **A second person out of production.** The real cost, and it is already expressible: the
  rescuer is not at their station, so whatever they were doing stops.
- **Their own air.** The rescuer walks *into* the thing that dropped the casualty, so the run
  is bounded by `respirator_air` — which is exactly what apparatus was for and needs no new
  mechanism.
- **Nothing else.** Resist adding a stretcher fitting, a two-carrier rule, or a fatigue cost
  until the basic loop is playable.

## Why it is not a mine feature

Written here because the mine is where it became visible, but **the implementation belongs in
the engine**, beside `Injury` and phase 6d, with no mine-specific code at all. A boiler house
with places will want it on the day the steam engine is retrofitted; so will every operation
after. Treat "carrying" as a peer of "travel", not as something a colliery has.

## The prerequisite

**Nothing here works until the steam engine has places**, or at least until `Layout` is no
longer the only thing that knows where anybody is. It is not urgent for the mine — a collapsed
minion there is a real, legible loss and the fan is a real, legible answer — so this is
sequenced after the mine's own follow-ups rather than in front of them.

---

# Part 7 — The advance shift becomes something you buy

`Mine::ADVANCE_SHIFT` puts the last three seats in the district at build, because a pit whose
every hand starts at bank spends the opening five minutes of a match on a walk. It is declared
on the chassis and given away free, which is the wrong end state for two reasons: a head start
is exactly the kind of thing a player should be *buying*, and a frame that offers only one
arrangement cannot express the choice between them.

The fitted version is a `crew_quarters`-adjacent part — a night shift, a lodging house, an
underground stable — declaring how many seats begin elsewhere and where. `Assembly` already
finds capacity and origin by what a slot **accepts**, so the same route works here and no
operation has to reimplement it.

Two questions it should settle, neither of which the constant answers:

- **Which seats.** Positional today (the last ones), so a player has no say in who is already
  down. Once it is a purchase, the crew screen should probably let them choose — which makes it
  a field on the roster rather than a property of the seat, and `Crewing#starts_in` becomes a
  read of the posting instead.
- **What it costs beyond money.** Men who started underground have not been through the lamp
  cabin, which is where the tally is taken. A head start that quietly breaks the roll-call is a
  better mechanic than a free one.

---

## Sequencing

Everything here comes **after** the mine is playable. Within that:

1. **Misreading (1)** first. Smallest, self-contained, and it immediately makes the flame-cap
   gauge — the mine's signature instrument — do the thing the whole design promised.
2. ~~**Finite stiffness**, on its own, as a prerequisite.~~ **Done** — see the box in Part 3.

> ### Parts 1–4 are built. What the measurements said
>
> - **Misreading (2).** The flame cap is the one mine instrument that names an observer, and
>   `:timbering` reads it — the post that is in the district and wins no coal, which now has a
>   second reason to be manned. Wrong on **8.5%** of looks for a deputy, **17.2%** for an
>   ordinary collier, **62.7%** for a day-labourer. Getting that spread needed competence to
>   scale *all three* dials rather than only the frequency; scaling frequency alone gave 13%
>   against 21%, which is no mechanic at all.
> - **Doing the wrong thing (3).** `winding` is the one certificated post, because overwinding
>   puts a cage through the headgear. A ticketed engineman **never slips**; the same man
>   without the ticket slips on 663 of 8,000 ticks and grabs the clutch, the pump, the
>   ventilation or **the naked flame**; a boneheaded kobold on 1,118.
> - **The accident model (4).** `Peril` beside `failure_hazards`, spending a hidden renewable
>   `margin`. Perils scale with the traffic, so the haulage lever is the production dial and
>   the danger dial at once.
>
> Two things the design did not anticipate and both are now rules elsewhere: **`observer:` had
> already been declared decoratively** on five steam-engine gauges naming posts that were never
> stations, which turning the seam on made permanently offline; and **phase 0 becoming a live
> draw** makes the unconditional-draw discipline load-bearing rather than theoretical.
3. **Doing the wrong thing (2)**.
4. **The accident model (4)**. Largest, overlaps the reserved probabilistic-injury design, and
   wants its own sketch and review before code.
5. **Wrong lever (3)**, folded in once volumes exist.
6. **Carrying somebody out (6)**, last of these and **not a mine feature** — it belongs beside
   phase 6d in the engine and wants the steam engine to have places first.
7. **The advance shift as a fitting (7)**, whenever the blueprint tree is next opened. Small,
   independent of all of the above, and the constant works until then.

## What this does not touch

- `Injury` itself — unchanged, and deliberately so. The Danger Check still throws no dice.
- The command protocol — a slip changes `actual`, never `target`.
- The four invariants — no amendment needed by any of the four mechanics.
- `Event::TYPES` — reused rather than extended, pending a consumer that needs the distinction.

## Documentation owed

Per the change→file table in the root [`CLAUDE.md`](../../CLAUDE.md):

- [`reference/tick.md`](../reference/tick.md) + `lib/reactor_sim/CLAUDE.md` — the new phase 6d,
  and phase 0 becoming a real entropy draw
- [`reference/diagnostics.md`](../reference/diagnostics.md) + `diagnostics/CLAUDE.md` — the
  competence scalar, the `observer:` path going live, the `:offline`-when-unobserved rule
- [`reference/nodes.md`](../reference/nodes.md) + `concerns/CLAUDE.md` — `perils:`, beside
  `failure_hazards`
- [`guides/add-content.md`](../guides/add-content.md) + `content/CLAUDE.md` — `boneheaded`, and
  the new hazard tags (`fall`, `crush`, `impact`) with their `_resistance` counterparts
- [`current_progress.md`](../current_progress.md) — the traps list gains **two** entries: the
  headcount rate trap (Part 0) and the unconditional-draw rule (Part 4)
- `spec/CLAUDE.md` — a row per new spec file
