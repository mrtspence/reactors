# Stage 5 — blueprints, and what a player actually owns

> Input to a decision, not a description of the system. Nothing here is built.
> Continues [`modular_components.md`](modular_components.md), whose staging table calls this
> *"costs, inventory, progression, part condition and wear carried between matches"* — **and
> that line is wrong.** §1 replaces it.

---

## 1. The model

Progression is **blueprints**. A player unlocks the blueprint for an operation, a chassis, a
part, or a minion; from then on they may mint a **fresh instance** of that thing into any match
they play. The blueprint is the permanent thing. The instance is not.

Four consequences, and all four are load-bearing:

- **Nothing a part accumulates survives the match it accumulated it in.** A flywheel is minted
  new at every build. There is no worn boiler sitting in a shed between sessions, no inventory
  of objects, no repair queue, no serial numbers.
- **A blueprint is not consumed by using it.** Two matches may mint the same boiler at the same
  time. Whether a player *should* be in two matches at once is a question for whatever starts
  matches; it is emphatically not a question for this system, and building a reservation
  mechanism to answer it would be building the wrong thing.
- **The cost of a failure is paid inside the match, by everyone.** A match is multiplayer and
  the reward is shared: burst a flywheel and the mine floods, so the ore is not lifted, so the
  refinery that was expecting it runs empty. That is an **opportunity cost** — the match is
  simply worth less — and it settles at the end of the match rather than following anyone home.
- **Unlocking is gated by resources and, later, by achievements.** A boiler blueprint wants a
  few tons of copper, bronze, iron or steel depending on which boiler it is. Both gates are
  stubbed for now. (**Note as built:** `content/` has cast iron, wrought iron, steel, bronze,
  babbitt and fusible alloy, and no copper — a bill naming one that does not exist is refused, so
  copper wants adding as a material before it can be charged for. See §16.)

Later, and deliberately not now: **pre-match wear**. Certain parts arrive with a random amount
of wear on them, and the player is handed a maintenance report to read — or to skip, if they
would rather get to the resources sooner and take their chances. §10 shows why the model above
already has room for this and costs nothing to leave it.

Also later, and a bigger piece than it looks: **in-match repair**, which becomes a key minion
job. §3 is what it needs to be true first.

### Every component is unlockable, chassis included

There is no special case. An operation, a chassis, a part and a minion template are four kinds
of blueprint and nothing more; a chassis is not folded into the operation that uses it.

**A player starts with one operation of each kind, fitted with the lowest tier of every
component** — simpler machines, and conspicuously without instrumentation or safety devices.
Everything above that is the tech tree, which is later work and is not designed here.

> **The bottom tier does not exist yet, and the atmospheric engine is not it.** Both chassis in
> the registry today are fairly upgraded machines. The atmospheric one reads as the humble
> option — it is slower, weaker and older — but it has a **separate condenser**, which was the
> Watt patent and the single most sophisticated thing on any engine of its era. A true starting
> engine condenses in the cylinder and has no condenser at all.
>
> This matters now rather than later because every part currently registered is a mid-tier
> part, so *nothing* in `Parts.known` is a candidate for a starting loadout. **The first job of
> the tech tree is not adding better parts. It is adding worse ones** — and the enforcement
> stage below cannot be exercised properly until there is something to revoke *down to*.

### Blueprints of a kind coexist; they do not supersede

Unlocking the beam boiler does not retire the locomotive boiler. Parts of a kind trade against
each other rather than forming a ladder — that is the premise the whole modularisation design
rests on, and it is why `Slot#accepts` names a kind rather than a minimum tier.

Two consequences worth stating before something implies otherwise:

- **No tier or rank field on a blueprint.** There is no ordering to store, and a column for one
  would be filled in by somebody eventually.
- **The outfitting screen must not imply a ladder by ordering.** `Parts.of_kind` returns
  registration order, which is arbitrary with respect to quality and must stay that way — a
  dropdown sorted "best last" teaches a ranking the design does not have.

---

## 2. What this model buys, which is most of the work

**The simulation boundary is untouched by progression.** That is not a small tidiness win, it
is the thing that makes this stage cheap, and it falls out of "instances live only in the
match":

| | Crosses into the sim? | Crosses out? |
|---|---|---|
| Which blueprints a player owns | **no** — it filters what the outfitting screen offers | — |
| A chosen chassis and loadout | already does, in `options:` | — |
| Part condition | **no** — minted fresh, rolled from the match seed | **no** |
| Match reward | — | eventually, as one figure at the end |

Compare the alternative that was on the table an hour ago — durable part instances whose wear
carried between matches — which required condition to round-trip through `options:`, a fifth
instance of the symbols-as-values trap, and a new way for a mid-match snapshot restore to
silently heal a worn part. **None of that exists in this model.** `Concerns::Wearing` keeps
rolling durability from the seeded rng exactly as it does today, and its comment about hiding
the roll stays true for free.

So **progression** needs no change to `lib/reactor_sim` at all, with one exception named in §8.
Everything else here is delivery tier, and cannot break a tick, determinism, or conservation
because it never enters the library. §3 is the separate piece of work that does, and the
distinction between the two is worth keeping sharp.

### The one place progression does reach in

`Assembly`'s validator must not learn about blueprints. It answers *"will this build run?"* —
a question about the machine — and the standing instruction on it is that it stays simple.
*"Are you allowed this part?"* is a different question with a different answer shape, it belongs
to the delivery tier, and it is checked before a loadout is ever handed to the sim. Two
validators, deliberately: one refuses a machine that cannot work, the other refuses a machine
that is not yours.

---

## 3. When a part breaks

This began as an open question about what happens to a destroyed part, and the answer turned out
to be a failure-model decision that is **not stage 5's work** — it is the thing
`current_progress.md`'s second playtest item has been blocked on since 2026-09-05. Recorded here
because it was decided here, and because stage 5 must not quietly assume otherwise.

### A broken part stays in the graph and behaves worse

> **Broken is not absent.** A failed part is never removed from a running simulation. It stays
> wired where it was and performs differently, and **how** differently is a property of that
> specific part's failure mode: a small rupture in a pipe leaks and lets the machine limp on;
> a boiler letting go is very likely the end of the run.

This closes the design decision that `current_progress.md` names as blocking item 2 — *"a
ruptured vessel should spill and a ruptured conduit should leak rather than plug, both with
`mass_spilled` finally having a writer and `Atmosphere` as the universal sink. Both need a
rupture size, which is a failure-model design decision rather than a physics one."* The rule
above is that decision: **the severity is per-part, declared where the part is, and it is a
spectrum rather than a switch.**

Two things it rules out, both of which are the obvious shortcut:

- **A broken part must not be dropped from the node list.** Removing it mid-match would change
  the graph's shape underneath a running tick, which `options:` and the snapshot contract both
  assume cannot happen. It would also be wrong on its own terms — a ruptured pipe is still a
  pipe, and it is still in the way.
- **A broken holder must not simply plug.** That is today's behaviour by omission and it is
  backwards: it turns a rupture into a *stronger* seal than the part had when it worked.

### Failure is unrelated to `when_empty:`

Worth writing down before the two get conflated, because they look alike and are not:

| | Question | When | Declared by |
|---|---|---|---|
| `when_empty: :omit \| :bypass` | what the topology is if this is **never fitted** | build | `Slot` |
| failure mode | what this part **does once broken** | tick | the part |

A slot's `:bypass` says a missing blower leaves a plain duct behind. It says nothing whatever
about a *fitted* blower that has seized, which is still there, still on the path, and now an
obstruction. Reusing the bypass link for a failure would silently repair the machine at the
moment it broke.

### Why repair makes the spill model load-bearing

Repair becomes a minion job, and that is what turns the leak model from bookkeeping into a
mechanic: **what a broken part spills can prevent the crew from reaching it.** Steam, hot
water, toxic product — an operational area you have flooded is an area nobody can work in, so a
small failure handled late becomes an unfixable one.

That is a strong argument for the spill going somewhere specific rather than to a universal
sink, and it is worth knowing before `Atmosphere` is built as one. It also needs a notion of
*place* that this simulation does not currently have in any form — nodes have no location — so
it is further out than the leak model itself.

**None of this is stage 5.** It is its own sketch, it touches nodes, `Wearing` and the arbiter,
and it wants the same measurement-first treatment the transport model got.

> **That sketch now exists: [`failure_model.md`](failure_model.md) (2026-09-14).** It keeps every
> rule above and adds three the design here did not reach: `broken:` widens to a `failure:` mode
> symbol, failures **escalate** along an ordered mode table (so a mild failure can never immunise
> a part against a catastrophic one), and a spill leaves through a **breach** — a dormant
> `Conduit` that opens on the sensed failure, which is the only way to change topology without
> changing the graph under a running tick.

---

## 4. What is missing, and what to stub

Three things this needs and the prototype does not have. Each has a cheap stub in the shape
`DevMatch` already established, so none of them blocks.

| Missing | Why it is needed | Stub |
|---|---|---|
| **A player** | An unlock has to belong to someone | `DevPlayer`, one id, the way `DevMatch::ID` is one match |
| **A match that ends** | Rewards settle at the end | none needed yet — §11's dev affordance grants unlocks directly |
| **Multiple operations in a match** | The mine/refinery chain *is* the reward model | none — there is one operation, and the reward stays stubbed until there are several |

The third is worth being honest about: the shared-reward mechanic cannot be designed properly
against a single steam engine, because the whole mechanic is one operation's failure starving
another's input. **So stage 5 should not try to build the reward side at all.** Build the
unlock side, grant unlocks with a dev affordance, and let the earning mechanism wait for the
match that can express it.

---

## 5. Juncture 1 — one blueprint mechanism, or four?

Four kinds of thing are unlockable: **operations** (a machine type — the steam engine, later a
mine), **chassis** (high-pressure vs atmospheric), **parts**, and **minion templates**. They
are unlocked the same way and spent the same way, but they live in four different registries
and mean four different things at build time.

### Option A: four separate tables, one per kind

**Pros.** Each is typed, each can carry the columns it actually needs.
**Cons.** Four tables that differ in no way that matters, four controllers, four UIs, and an
achievement system that eventually has to query "how many things has this player unlocked"
across all of them. Every future kind is a migration.

### Option B: one `unlocks` table, typed by `(kind, blueprint_id)` — **recommended**

```
unlocks   owner_id   kind        blueprint_id          unlocked_at
          dev        part        locomotive_boiler     …
          dev        chassis     high_pressure         …
          dev        minion      fireman               …
```

**Pros.** One mechanism, one UI, one query. A new kind of unlockable is a new value in a column,
not a migration. The row carries *when*, which is exactly what an achievement system wants later
and is free here. Unlock history is auditable rather than being a bitfield nobody can explain.
**Cons.** `blueprint_id` is only meaningful alongside its `kind`, so nothing at the database
level stops `("chassis", "locomotive_boiler")`. That has to be checked in code.

### Option C: a jsonb array of ids on the owner

**Pros.** One column.
**Cons.** No timestamps, no per-unlock provenance, and the moment an unlock needs a second fact
about itself it is a migration anyway.

### Recommendation

**B**, with the check Option B's con names made loud:

> **A blueprint naming something that is not in its registry must fail at boot, not at fit
> time.** `Parts.fetch` raises on an unknown id, `CHASSIS.fetch` raises, `Operations` raises —
> so a single startup sweep over every distinct `(kind, blueprint_id)` catches a typo'd or
> deleted blueprint immediately. This is the same rule that makes a part naming a nonexistent
> gauge fail at build rather than reading nil forever, and it is the same reason `content_spec`
> refuses a structural material with no temperature rating: **a lookup that silently misses is a
> feature silently switched off.**

The tradeoff bought: one `kind` column's worth of looseness, in exchange for a progression
system that does not need a migration every time something becomes unlockable.

---

## 6. Juncture 2 — where is an unlock enforced?

Three points in the chain could check it. They are not alternatives; the question is which of
them is *authoritative* and which are courtesies.

1. **The outfitting screen's dropdowns** — offer only what is unlocked.
2. **The controller that accepts the form** — refuse a submitted loadout naming a locked part.
3. **`Assembly`** — refuse the build.

### Option A: the screen only

**Pros.** Nothing to build beyond a filter on `Parts.of_kind`.
**Cons.** The screen posts a plain form. Anyone can post any part id, and the current controller
would happily store it. A client-side-only gate is not a gate.

### Option B: the screen filters, the controller enforces — **recommended**

**Pros.** The dropdown becomes a courtesy and the controller becomes the authority, which is the
normal shape and the one every other Rails permission check in the world has. The refusal has
somewhere sensible to render — the screen already has a verdict panel with an errors list built
for exactly this, and *"you have not unlocked the Ramsbottom safety valve"* is the same shape of
message as *"the chimney is required"*, even though it comes from somewhere else entirely.
**Cons.** Two places know about unlocks. That is correct and unavoidable: one decides what to
show, the other decides what to accept.

### Option C: push it into `Assembly`

**Pros.** One place.
**Cons.** Puts ownership into the pure simulation, which has no business knowing who a player is
— and it conflates *"this machine cannot work"* with *"this machine is not yours"*, which are
different failures with different fixes. It also makes every existing sim spec need a player.

### Recommendation

**B.** Note the ordering that follows from it, which matches what stage 4 already established:
**check ownership first, then assemble.** A loadout naming a locked part should be refused
before `Assembly` ever sees it, so the player gets *"you do not have that"* rather than a
confusing structural error about a slot — and so a refused build still never reaches the
database or the runner.

---

## 7. Juncture 3 — the gates, stubbed but shaped

Two gates were named: **resources** and **achievements**. Neither is a priority, but the shape
of the stub decides how much rework the real thing costs.

**Resources.** A blueprint's cost is a bill of materials — *this boiler is a few tons of
wrought iron; that one is bronze*. The interesting property is that **it is denominated in the
same substances the simulation already models.** `content/resources/` has materials with real
properties, and `materials.yml` already knows what wrought iron is, because
`Concerns::Thermal#rated_temperature_k` resolves ratings from it. A blueprint costing "3 t
wrought iron" is therefore not a new currency — it is the same material the part is made of,
which is why the bronze boiler costs bronze.

That is a strong argument against a single abstract currency, and the recommendation is to
**stub the bill of materials as a real map from the start** — `{ wrought_iron: 3000.0 }` —
even while nothing can pay it. A stub shaped like the real thing costs nothing now; a stub
shaped like `cost: 500` has to be replaced.

**Where it lives:** delivery tier, not `content/`. `content/` is the simulation's own YAML,
read by `content.rb` at boot, and the sim must not learn what anything costs. It may *name* a
material the sim knows, and that reference should be checked at boot by the same sweep as §5.

**Achievements.** Rough in only: an unlock may name a prerequisite achievement id, and the
achievement system is a stub that reports everything as unearned or everything as earned. The
one decision worth making now is that the prerequisite lives **on the blueprint**, not in a
separate unlock-rules engine — so a blueprint carries everything needed to answer "may I have
this yet?" in one place.

---

## 8. Juncture 4 — minions, and the one thing that does reach the sim

Minion templates unlock like everything else, and their state is minted per-match like
everything else. But there is an asymmetry worth naming now, because it lands on stage 6:

**Three of the four blueprint kinds are already expressible as builder options. The fourth is
not.** Operation type, chassis and loadout all ride in `options:` and survive a snapshot.
Minions do not — the roster is built inside the operation's builder from a fixed list, and
`DevMatch.crew` reads it back as frozen configuration.

So a player who has unlocked an upgraded fireman needs that choice to arrive the way the loadout
does: **in `options:`, snapshotted, whitelisted in the registered builder's keyword list.** The
existing trap applies in full — an option the builder does not name is an `ArgumentError` at
restore, and a roster option that failed to arrive would restore a snapshot with the wrong crew,
silently.

This is not stage 5's work. It is stage 6's, and the point of writing it here is that stage 5
should **not** invent a second, different way for minion templates to reach the sim in the
meantime. Unlock them, filter them, and leave the plumbing to the stage that needs it.

---

## 9. Juncture 5 — instruments as blueprints, and the `burst_pa` loose end

`modular_components.md` §18 flagged `burst_pa` as the last entry on the chassis that belongs to
something else: it is the pressure gauge's full-scale reading, and it stays on the chassis only
because `catalogue(spec)` does not know which boiler is fitted. Making instruments parts
resolves it — a 0–14 atm gauge and a 0–4 atm gauge genuinely *are* different instruments you
would fit to suit the boiler — and under this model an upgraded gauge is simply another
blueprint.

**And that is the risk.** The instruments are not an obstacle between the player and the game;
they *are* the game — narrow controls and imperfect instruments is the entire thesis. Sell
perfect information and there is nothing left to oversee. So if this proceeds, it should
proceed under a rule:

> **An instrument blueprint may reduce a filter. It may never remove a class of one.** Less lag,
> less noise, a finer band — never zero lag, and never a number where the design deliberately
> chose prose. Three gauges are exempt outright: `safety_valve`, which is *true* by design
> because the player is not reading a dial at all; and `crown_sheet` and `flywheel_condition`,
> whose vagueness is the hazard they name.

**Recommendation: yes, and not in stage 5's first cut.** It is content for a progression system
that exists rather than a prerequisite for building one, and `burst_pa` has been harmlessly in
the wrong place for a week. It is the natural first *use* of the finished system.

---

## 10. The maintenance mechanic, and why it is already free

Not being built now. Recorded because the model above has exactly the right shape for it, and it
would be easy to spend that shape on something else by accident.

Pre-match wear is **rolled inside the match, from the match seed** — not carried in from
anywhere. `wearing_initial_state` already draws durability from a seeded range; a maintenance
mechanic is that same roll, biased by a flag that arrives in `options:` like every other
build-shaping choice. Three properties fall out of that, all of them good:

- **It is deterministic and reproducible.** Same seed, same wear. The match replays.
- **Nothing crosses the boundary.** No condition round-trip, no fifth symbols-as-values trap, no
  way for a snapshot restore to heal a part.
- **The maintenance report is not a new feature.** It is `integrity` read at tick 0 — a
  projection of state that already exists, through instruments that already exist. The gauges
  written for a slow condition variable (`flywheel_condition`, twelve ticks stale and misread
  12% of the time) finally have something to say.

The thing that makes it a *decision* rather than a chore is the cost of looking: reviewing the
report takes match time, and skipping it gets the player to the resources sooner with an engine
they have not inspected. That is the same risk/reward axis the safety devices sit on, which is
a good sign.

---

## 11. Staging

| # | Stage | Acceptance |
|---|---|---|
| 5a | The blueprint registry and `unlocks`, typed by `(kind, blueprint_id)`, with a boot-time sweep that refuses an unlock naming something no registry has. `DevPlayer` owns everything. **Built 2026-09-14 — see §14, and note the sweep moved.** | Boot fails loudly on a typo'd blueprint id. Existing behaviour unchanged — everything is unlocked, so the screen looks the same. |
| 5b | Enforcement. The outfitting screen offers only unlocked parts; fitting refuses a locked one and says so in its own panel. A dev affordance grants and revokes. **Built 2026-09-14 — see §15.** | Revoke a part, and it disappears from the dropdown *and* is refused when posted directly. `Assembly` is unchanged and still knows nothing about players. |
| 5c | Gates, stubbed in their real shape: a bill of materials naming substances the sim knows, and an achievement prerequisite that always reports earned. **Built 2026-09-14 — see §16.** | A blueprint naming a material `content/` does not have fails the same boot sweep. |
| 5d | Chassis, operation and minion blueprints on the same mechanism. **Chassis built 2026-09-14; operations have nothing to enforce yet; minions re-pointed at individuals 2026-09-16, with `:equipment` and `:training` alongside — see §17.** | Unlocking is one code path for all six kinds; the roster is not yet plumbed into `options:` — that is the next stage of the minion work. |
| 5e | Instruments become parts under §9's rule; `burst_pa` leaves the chassis with them. **Built 2026-09-14 — see §19.** | `CHASSIS` holds `exhausts_to`, `condenser` and `parts:` — topology and nothing else. |

5a is deliberately a no-op from the player's side. The whole of it is a table, a registry sweep
and a stub owner, and at the end of it the game plays exactly as it does today — which is the
point: it is the stage where a mistake is cheapest to find.

**Not in this stage, and not blocked by it:** the reward side. It cannot be designed against a
single steam engine, because the mechanic *is* one operation's failure starving another's input.
It waits for a match with a mine and a refinery in it.

---

## 12. Questions asked and answered

Kept rather than deleted, because each answer rules something out and the ruling-out is the
part that gets forgotten.

- ~~**Is a chassis unlocked, or is it part of the operation's blueprint?**~~ **Unlocked, like
  everything else.** There is no special case anywhere: every component is a blueprint. See §1.
- ~~**Is there a starting set?**~~ **Yes — one operation of each kind, fitted with the lowest
  tier of every component**, simpler and without instrumentation or safety devices. And the
  finding that came out of it: the bottom tier *does not exist yet*, and the atmospheric engine
  is not it. See §1.
- ~~**Do blueprints of a kind supersede each other?**~~ **No, they coexist.** So: no tier field,
  and the outfitting screen must not imply a ladder by ordering. See §1.
- ~~**What happens to a part destroyed mid-match?**~~ **It stays in the graph and behaves
  worse**, by a rule specific to that part's failure mode. That answer is larger than the
  question and has its own section — §3 — along with why it is not stage 5's work.

## 13. Still open

- **What can a repair crew actually reach, and how is that expressed?** §3 makes a spill able to
  deny access to a part, which is the mechanic that makes handling a small failure promptly
  matter. It needs a notion of *place*, and nodes have no location today in any form. This is
  the question that decides whether `Atmosphere` is one universal sink or several local ones,
  and it should be answered before that node is built rather than after.
- **What does a match pay out, and how is a shared reward divided?** Deliberately not guessed
  here (§4), because it cannot be designed against one steam engine — the mechanic is one
  operation's failure starving another's input. It wants a match with a mine and a refinery in
  it.
- **Does a minion template's upgrade path look like a part's?** §8 puts minion templates on the
  same unlock mechanism, but "unlock a better fireman" and "unlock an upgrade *to* your fireman
  template" are different shapes, and only the first is what §5's table describes.

---

## 14. Where stage 5a departed from this sketch

Built 2026-09-14. Four departures, two of which matter.

`Blueprint` (the derived catalogue), `Unlock` (the rows), `DevPlayer` (the stub owner),
`rake blueprints:{catalogue,audit,grant_all}`, and one change inside `lib/reactor_sim`. 34
blueprints at the time: 1 operation, 2 chassis, 29 parts, 2 minions.

> A snapshot, and it has moved twice since — derive it with `rake blueprints:catalogue` rather
> than trusting the line above. **80** as of 2026-09-16: 1 operation, 2 chassis, 35 parts,
> 3 minions, 27 equipment and 12 training, the last two being the cross product of the kit
> catalogue with the hireable roster.

### The boot sweep moved, and the reason is that it was guarding the wrong thing

§5 and §11 both asked for a sweep at boot that refuses an unlock naming something no registry
has. Writing it exposed that "at boot" and "over the unlocks table" cannot both be had, and that
neither was where the bug lives.

- **Sweeping the table at boot means a database read in an initializer** — during asset
  precompile, in CI before `db:prepare`, with migrations pending. That is a boot failure caused
  by the guard rather than by the thing it guards.
- **Building the catalogue at boot forces the content YAML read** that
  `config/initializers/reactor_sim.rb` deliberately keeps lazy so a `rails console` or a rake
  task pays nothing. Undoing a documented decision to move an error a few seconds earlier is a
  poor trade.
- **And validation cannot catch the real failure anyway.** The drift that actually happens is a
  **rename** — stage 3 renamed `:stock_boiler` to `:locomotive_boiler` — and nothing revalidates
  rows already in the table when a constant changes in Ruby.

So it split in two, along the line the failures actually fall on:

> **`Unlock` validates on write**, so a typo, a real id filed under the wrong kind, and a kind
> that is not a kind are all refused before a row exists. **`rake blueprints:audit` finds rows a
> rename stranded**, exits non-zero, and names them. A stranded row is not a crash — it is a
> player quietly missing something they earned, which is exactly the class of bug that survives
> for months, so the guard has to be findable rather than preventive.

The acceptance test is met in substance and not in letter: a typo'd blueprint id fails loudly,
just not at boot. That is a better guard, and it is worth recording that the sketch's version
would have been a worse one.

### Chassis ids are scoped to their operation

§5's table drew `(chassis, high_pressure)`. Built as `(chassis, "steam_engine/high_pressure")`,
because a chassis has no standalone existence — it is a frame *for* a machine — and two
operations could each name a frame `standard`. Unscoped, unlocking one would silently unlock the
other. Part ids need no scoping: `Parts` is one flat registry that refuses a duplicate outright.

### §2's "no change to `lib/reactor_sim` at all" was not quite true

One change was needed, and it is worth being precise about what kind. `Operations.register` now
takes `chassis:` — the *enumeration* of frames a type offers — and `Operations.chassis_for(type)`
reads it back. The delivery tier has to list chassis because each is separately unlockable, and
the alternative was a hand-written map from operation type to `SomeOperation::CHASSIS` sitting in
Rails, which is an inventory list and drifts the first time somebody adds a frame.

**It is introspection, not progression.** Nothing in a tick reads it, no node can ask it
anything, and a builder still takes `chassis:` as an ordinary option and still raises on a frame
it does not know. The claim §2 makes is intact in spirit — the simulation still knows nothing
about players, ownership or cost — but "no change at all" was too strong, and a sketch that
overstates its own cheapness is how a stage quietly runs over.

### No `STARTING_SET` constant was written

§1 says a player starts with one operation of each kind at the lowest tier. Stage 5a grants
`DevPlayer` the whole catalogue, so a starting-set constant would have been written, validated,
and read by nothing. This codebase has already paid for one dead constant kept "for later"
(`LEGACY_KEYS_MOVED_TO_PARTS`), and the answer then was the same: **a misleading appendix costs
more than it saves.** The starting set is stage 5b's, where something reads it — and it wants
the bottom tier to exist first, which it does not.

---

## 15. Where stage 5b departed from this sketch

Built 2026-09-14. The enforcement itself landed as §6 recommended — the screen filters, the
controller enforces, `Assembly` never learns what a player is. What changed was everything
around it.

### It was refused for being in a controller, and the rule that came out of it is the lasting part

The first version put the ownership check, the workshop query and the per-slot candidate list
straight into `ComponentsController#fit`, on top of the validate/store/reset sequence already
there. That was rejected, and the rule written down in `app/CLAUDE.md` is worth restating because
it now binds everything after this:

> **Every action is one of the seven.** An action named for a domain verb — `fit`, `preview`,
> `reset` — means either that a resource is missing or that the work belongs elsewhere. A
> controller may express routing, authorisation, parameter permitting, and which template or
> redirect follows. Nothing else.

Applying it retired three non-standard actions and moved one piece of domain logic:

| Was | Is | Why |
|---|---|---|
| `components#show` | `loadouts#edit` | The screen is a form for editing a loadout |
| `components#show` (POST preview) | `loadout_drafts#create` | **A draft is a resource.** Asking what a build *would* be produces a rendering, not a record, and `create` is the honest verb for "evaluate this one" |
| `components#fit` | `loadouts#update` | "Fit these parts" is an update to the loadout |
| `matches#reset` | `match_resets#create` | What it creates is a request that the runner start again |
| `MatchesController.reset_command` | `DevMatch.reset_command` | Domain work that had no business on a controller |

The work went to **`Outfitting`**, a service object taking an owner id and a parts hash — never
`params`, never `session` — which is what lets a rake task and a spec drive the same path.

### The preview's original justification was wrong

The old routes file said the preview had to be a POST because *"a GET form would carry the CSRF
token in the query string on every dropdown change"*. **It would not.** Rails emits an
authenticity token only for non-GET forms, so a GET preview carries no token at all.

The real reason to keep it a POST is duller and still sufficient: a twenty-slot loadout in a query
string on every change is noise in history and logs. Recorded because a wrong reason defended in a
comment is worse than no comment — it is exactly the sort of thing that gets cited later as
settled.

### The form's default action flipped, and that is a real improvement

Before, the form posted to the *preview* and the Fit button overrode it with `formaction`. Now the
form is a `PATCH` to the loadout — Fit is the default — and the Stimulus controller borrows it for
previews, clearing Rails' `_method` override so the draft posts rather than patches.

The direction matters: **with JavaScript broken, the old form could preview but not fit; the new
one fits but does not preview.** Previewing is inherently scripted — it fires on `change` — so
that is the right way round. The global-token workaround from stage 4 survives unchanged and for
the same reason, since the form still submits to two different actions.

### A security scan found what the specs could not

Brakeman, run after a GitHub scan flagged it, refused `params.fetch(:loadout, {}).permit!`. The
mass assignment was the lesser half. **`permit!` also admits non-scalars**, so `loadout[boiler][]=x`
arrived as an Array, reached `Assembly#normalise_part_id`, and `Array#to_sym` raised — a **500 on
the draft action**, which has no rescue, reachable by anyone who could open the page. A JSON body
carrying `{"boiler": 1}` did the same through `Integer#to_sym`.

`permit(*slot_ids)` fixes both, because `permit` admits only scalars. Two habits go with it:
coerce a permitted value with `to_s` before treating it as an id, and check the parameter really
is an `ActionController::Parameters` before calling `permit` on it — `?loadout=x` makes it a
String. Five specs now cover those shapes; **none existed before, which is why it survived.**

### The dev affordance is rake, not a screen

`blueprints:grant[kind,id]`, `blueprints:revoke[kind,id]` and `blueprints:owned`. A workshop
screen is the obvious next thing and was deliberately not built: it is a progression UI, it wants
the tech tree to exist, and stage 5b's job was the enforcement underneath it.

### One rule the acceptance test did not anticipate

"Revoke a part and it disappears from the dropdown" is only true of a part that is **not fitted**.
The stored machine may already be wearing something the player no longer owns — that is exactly
what revocation produces — and a screen that hid it would report an error about a part the player
can neither see nor change. So a locked part that is already fitted stays in its dropdown, flagged
`(locked)`, and the two rules are not in tension: what is fitted is a fact about the machine, what
is offered is a fact about the workshop.

---

## 16. Where stage 5c departed from this sketch

Built 2026-09-14. `config/blueprints.yml` (34 entries), `Achievement` (a stub), and the checks
that make both refusable. Three things worth recording.

### The sketch's own worked example named a material that does not exist

§7 proposed stubbing a bill of materials as `{ wrought_iron: 3000.0 }` and the artifact showed a
boiler costing **copper**. There is no copper in `content/resources/materials.yml` — the six
metals are cast iron, wrought iron, steel, bronze, babbitt and fusible alloy.

That is a small thing and it is exactly the argument for the check. A bill is written by hand,
the names in it look obviously right, and nothing about `copper: 420` announces itself as wrong
until a foundry mechanic tries to charge for it years later. `Blueprint.gates_for` resolves every
material through `Content#resource`, which raises, so the catalogue refuses to build — and
`rake blueprints:audit` builds the catalogue, so the existing guard covers this one too without a
new command.

### "A part with no price is an error" needed a way to say *free*

§7's rule was right and incomplete. Taken literally it makes the starting operation impossible:
something has to be free, or a new player has no opening screen. But a default of zero is a
silent off switch, which is the failure this codebase has paid for repeatedly.

> **A missing entry raises; `materials: {}` is how a blueprint is free.** The difference between
> "decided to be free" and "nobody filled it in" has to survive in the file, because six months
> later they are indistinguishable from the outside.

Free today: the steam engine itself, and both minion archetypes — a crew is not built out of
metal, and what a minion should actually cost is a question for whenever minions do real work.

### The achievement gate needed a live call site, so acquisition split in two

A check that only ever runs in a spec rots. `Achievement.earned?` returns true unconditionally —
nothing awards an achievement, and gating on one would lock every blueprint that names a
prerequisite, permanently and with no way to earn it — so a gate wired only into a test would be
indistinguishable from a method that returns true.

So acquiring a blueprint became two verbs:

- **`DevPlayer.earn`** goes through the gates and returns nil, changing nothing, when a
  prerequisite is unmet. `rake blueprints:grant[kind,id]` uses it.
- **`DevPlayer.grant`** / `grant_everything!` bypass them, and say so by being a different word.
  That is the stage 5a baseline where the dev player owns the catalogue.

The specs prove the gate is real by stubbing `earned?` **false** and watching an ungated part
still earn while a gated one does not. Three blueprints carry a prerequisite today — the
Ramsbottom valve, the high-pressure cylinder and the blastpipe chimney — so the mechanism has
something to exercise.

### What is still stubbed, and is meant to look it

**Nothing can pay a bill.** There is no resource ledger, because a match reward cannot be
designed against a single steam engine — the mechanic is one operation's failure starving
another's input (§4). The quantities are plausible masses for the thing described, not balanced
prices; the whole tree currently comes to 35.6 t of cast iron, 18.2 t of wrought iron and well
under a tonne of everything else. The **shape** is what stage 5c was for, and the shape is now
impossible to get wrong quietly.

---

## 17. Stage 5d: the frame becomes a choice — and a correction to §1 and §8

Built 2026-09-14. Two of the three remaining kinds landed; the third turned out to be modelling
the wrong noun.

### Chassis

The chassis had never been *choosable* — it came from a stored row or an environment variable.
It is now a select at the top of the outfitting screen, offering the frames the player owns, and
an unowned one is refused on its own line rather than folded in with the parts (it is the larger
purchase, and every part on the page is fitted to it).

**Switching frames exposed a real bug in the loadout resolver.** The rule from stage 4 —
*"an unfitted slot is an explicit empty, never a missing key"* — exists so that taking the fusible
plug off and saving does not silently put it back. Applied to a frame change it is wrong: the
form that submitted was drawn for the **old** frame, so a slot only the new frame has was never
on it. Naming it anyway sends an explicit empty for a question the player was never asked, and
switching to the atmospheric frame refused itself with *"Condenser is required and nothing is
fitted."*

> **Carry through only the keys the submission actually contains.** A same-frame save names every
> slot, because the form renders every slot, and nothing re-defaults. A frame change names the
> slots that existed before, and the genuinely new ones arrive with their defaults.

Cross-frame fitting stays legal, and is meant to: a locomotive boiler on a beam engine is a
decision, not an error.

### Operations

There is one operation, no lobby, and no point at which a player chooses between machines, so
there is nothing to enforce yet. What the stage *did* produce here is a trap worth more than the
feature would have been — §18.

### Minions: this is the wrong noun, and §1 and §8 are wrong with it

Both this sketch and the code treat a **minion blueprint** as a content archetype — `fireman`,
`yardhand`. Those are **jobs**, not minions.

> A minion is an **individual**. You unlock Jim, who is human and starts with particular stats and
> tags, or Elowynne, who is an elf with her own. Each is a template in its own right, upgradable
> by further blueprints — certification courses granting stat bumps or new tags. "Fireman" is
> merely what one of them is doing in your operation this match.

Three consequences this sketch had not allowed for:

- **Equipment is a separate abstraction** with its own blueprints, unlocked **per minion** — Jim
  and Elowynne each own their own. Three slots, one item each: **tool set** (what they carry),
  **gear** (what they wear — heat protection, rebreathers, a powered exoskeleton), and
  **utility** (the niche slot: a lucky amulet, a rebreather on someone you would rather not put
  in a full hazmat suit).
- **Tags carry values and are read by the simulation.** `{ mining_effectiveness: 0.25,
  darkvision: 0.1, open_flame: true }` — a mining node multiplies its output by the minion's
  effectiveness *and* by whatever light they have, so a crude pick and a candle is a punishing
  ×0.25 ×0.1. Tags come from the minion (a dwarf has their own darkvision) and from equipment,
  combined. `open_flame` in a gassy mine is a hazard rather than a bonus.
- **A pre-match screen** to assign minions, swap their equipment, and post them to starting roles
  before commencing.

**Fixed 2026-09-16.** The catalogue enumerates individuals — Jim Ashfield, Elowynne, Galathas —
and `content/` is split in two: `archetypes/` holds kinds of person and `minions/` holds people.
`Blueprint::KINDS` gained `:equipment` and `:training`, both **scoped per minion**
(`jim/leather_apron`) by the same compound-id mechanism a chassis already used, so per-minion
ownership needed no migration to `unlocks`. A minion's sheet is four layers — archetype,
individual, training, equipment — each offsetting the last.

Two things this section did not anticipate, both found on the way:

- **The price is the item's, not the pairing's.** Pricing every (minion × item) combination meant
  39 identical lines in `config/blueprints.yml` today and a fresh one whenever anybody hires a
  minion — the inventory list that drifts silently. `Blueprint.build(priced_as:)` looks the bill
  up by the bare id, so an apron costs what an apron costs.
- **The last-resort standin is an individual too, and must never be for sale.** It lives in
  content like anybody else with `hireable: false`, which keeps one resolution path through the
  stat arithmetic rather than a constant the engine has to fold differently. Everything deriving
  a catalogue reads `Content.hireable`, never `Content.minions`.

The full model is in [`minions.md`](minions.md).

The sketch also flags what comes after: **minion position and transit**, probably the next thing
after this modularisation pass. Injuries depend on where somebody is standing relative to a
failing machine, and in a mine, moving people is the logistical problem — model it away and lifts,
man-engines, repairs and shift rotation all become trivial. The proposal is local environment
volumes reusing the conductance and node machinery already here, with tagged transport for
*minions* deciding who can go where and how fast.

---

## 18. The trap stage 5d actually produced

**A derived catalogue derives from whatever is in the registry, including things that are not
machines.**

`spec/support/loop_rig.rb` registers an operation type globally — it has to, or `Match.create`
cannot resolve it. The blueprint catalogue is derived from that same registry, so the rig arrived
as an operation nobody had priced, `gates_for` raised `Ungated`, and **the entire catalogue
refused to build**: all seventeen blueprint examples failed at once.

Three things about how it presented are worth keeping:

- **It only failed in a full-suite run.** Nothing else loads the rig, so every targeted run of the
  specs that were failing passed. Re-running the failures is exactly the wrong instinct here.
- **It was nearly invisible.** The background command piped rspec through `tail -20`, which
  truncated the evidence *and* masked the exit code — `tail` exits 0. The run reported success
  while listing failures. **Do not pipe a suite through `tail`.**
- **The obvious fixes are both wrong.** Pricing the rig ships test data in application config;
  skipping unpriced operations reinstates exactly the silent default the whole design refuses.

The fix keeps the derivation and corrects the set it derives from:

> `Operations.register(type, harness: true)` marks a registration that exists only to exercise
> the engine. `Operations.known` is everything, and is what `Match.create` resolves against;
> `Operations.catalogued` is the machines, and is what anything counting machines for a player
> must use. **The default is `harness: false`** — forgetting to mark a real machine does nothing,
> and forgetting to mark a rig fails loudly and points straight at it.

The guard lives in `assembly_spec`, on the simulation side, because the rule belongs to whoever
registers: if you register a rig, say so.

---

## 19. Stage 5e: the dial becomes a fitting, and `burst_pa` finally leaves

Built 2026-09-14. **`CHASSIS` now holds `exhausts_to`, `condenser` and `parts:` — topology and
nothing else**, which is what §6 of the modularisation sketch asked for and the first time it has
been true.

### The fix was not the one this sketch expected

§8 assumed moving `burst_pa` meant *"parts own their `Diagnostic`s, which is §4's Option A"* — and
the obvious reading of that is to hand the fitted boiler to the panel catalogue so it can read the
boiler's scale. That is still wrong, and for the same reason the original arrangement was wrong:

> **A gauge's range is not a property of the drum.** A 0–14 atm dial and a 0–4 atm dial are
> different brass instruments, chosen to suit the boiler they are screwed to. Asking the boiler
> what its gauge reads to is the same category error as asking the chassis, one object closer.

So the dial became a **part**: a `:boiler_gauge` slot, three registered gauges, and the scale on
the gauge. Same rule that moved the blower and kept the blastpipe — *an attribute becomes a node
when it is a separate object, and a variant when it is a different version of the same object* —
applied to an instrument for the first time.

### `Fragment#diagnostics`, and the ordering problem it creates

An instrument part builds its own `Diagnostic` rather than naming one. The definitions stay in
`panel.rb` with the two hundred lines explaining why each gauge lies; the part passes figures,
exactly as a boiler part passes its shell thickness. §4's objection — *"`panel.rb` is dismembered
and the property that you can read the whole instrument philosophy in one sitting is lost"* — does
not apply, because nothing moved out of it.

What did have to move is **who decides the order**. Selection used to run over the catalogue,
whose insertion order *was* the panel order. Supplied gauges have no place in that hash, and
appending them would have put the most important dial on the engine at the end of the panel.

> **`PANEL_ORDER` is now explicit and covers both sources**, and `Assembly` refuses a gauge it
> does not name rather than silently appending one. A player learns a panel by where things are;
> a gauge quietly landing at the end is the kind of drift nobody notices until they are looking
> for it in an emergency.

### Two checks earned their keep immediately

- **The id-collision check caught the boiler.** Both boilers still listed `boiler_pressure` in
  their `instruments:`, so the drum and the dial both claimed the same gauge. It failed at build
  naming both slots, which is exactly what it was written for.
- **A spec encoded an assumption that stopped being true.** *"Takes its own pieces with it"*
  measured `fragment.nodes.length`, and an instrument part brings **no nodes at all**. Widened to
  count every list plus the diagnostics.

### The gauge is optional, and that is the point

An engine with no pressure gauge assembles, runs, and is a genuinely frightening way to work. It
is the eighth optional part and the odd one out — every other one is machinery, and this is
information. *"The safety valve is now the first thing that will tell you how hard you are pushing
her, and by then it is telling everyone."*

`:compensated_pressure_gauge` is the upgrade and the shape every instrument upgrade must take: one
tick of lag instead of two, ±3 kPa instead of ±8. **It removes neither filter, and none ever may.**

### What this does not answer

**Instruments cost almost nothing to make.** A Bourdon gauge is a curled brass tube and a pointer,
so a bill of materials cannot be what makes a better one expensive — the three gauges are priced
at 6 kg of bronze and under. Whatever eventually gates an instrument upgrade, it will not be
tonnage: an achievement, a craftsman, a certification. The compensated gauge carries an
achievement prerequisite today precisely because that is the gate with any weight behind it.
