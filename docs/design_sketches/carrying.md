# Carrying somebody out, and the weight of everything

> **Built.** Kept as written, including the parts that turned out to be wrong — §5's worked table
> was reproduced exactly by the implementation, and §6's warning about the accrual term was the
> thing that most needed saying. What changed in the building is recorded in §14.

Design input for the rescue loop. Shape **(b)** from
[`mine-follow-ups.md`](mine-follow-ups.md) Part 6 is settled; this is the detail, the arithmetic,
and the places it touches state.

The loop itself is small: **a carrier is posted to a person instead of to a station, picks them up
on arrival, walks slower for it, and sets them down wherever they happen to be standing.** No
rescue node, no release lever, no second command shape for the pickup.

The larger half is that carrying forces **mass** into the sheet, and once mass exists the thing
somebody is wearing is a burden by exactly the same arithmetic as the person they are carrying. One
concept, two sources, and a new upgrade axis — *lighter* gear — for the price of a field.

---

## 1. Why (b) needs no new command for the pickup

`assign_minion(minion_id, station_id)` refuses a station it cannot find in `@control_points`.
Allowing a **person** there is safe for a reason that already exists and is already enforced:

> **Ids are one flat namespace** across nodes, control points, diagnostics and minions, because
> they key one RNG table. `validate_graph!` refuses duplicates.
> — [`lib/reactor_sim/CLAUDE.md`](../../lib/reactor_sim/CLAUDE.md)

So `:crew_4` can never also be a lever, and a posting naming `:crew_4` is unambiguous. The command
keeps its wire shape, its arity and its idempotence; `Command::Parsed` needs no new field; the
console's existing `<select>` per crew row gains entries for people.

**The wire field stays `control_point_id`, deliberately, despite now sometimes carrying a person.**
Renaming it would make every command already in the Kafka log unparseable, and invariant 2 says
`seed + command log` reproduces a match bit for bit. A slightly narrow field name is the cheaper of
those two costs; the schema comment should say what it actually holds.

### What `posting` means afterwards

`posting` is already *"where somebody has been SENT"* and `station` is *"what they are actually
working"*. A posting naming a person is a **fetch order**, consumed on arrival:

| | `posting` | `station` | `carrying` |
|---|---|---|---|
| Sent to fetch Jim | `:crew_4` | `nil` | `[]` |
| Arrived, has Jim | `nil` | `nil` | `[:crew_4]` |
| Then sent to bank | `:quarters` | `nil` → `:quarters` on arrival | `[:crew_4]` |
| Set Jim down | `:quarters` | `:quarters` | `[]` |

**Carrying is not a station**, and that matters: `Tick#tire` does
`control_points[minion_state[:station]]`, so a minion id left in `station` would read as "working
Jim" in the UI and as off-post to the engine — wrong twice, silently. Clearing both on pickup says
the true thing: holding somebody is not a job, it is a state you are in while awaiting orders.

---

## 2. Setting down is its own command, and the protocol choice is not cosmetic

The carrier needs *"put Jim down, here"*. Three forms, and the obvious one is the worst:

**(i) An absolute list — `carry(carrier, [ids])`.** Looks the most invariant-friendly: a value, not
a step. **It is the one that breaks.** The ingress is at-least-once and unordered, so two taps
producing `[B, C]` then `[C]` can arrive reversed and put B back in the carrier's arms. An absolute
list is only safe when one writer owns the whole value, and here the writer is a human pressing
buttons.

**(ii) `set_down(carrier)` — drop everything.** Idempotent, commutative, trivial. But an ogre
holding six kobolds wants to leave five in the refuge and carry one further.

**(iii) `set_down(minion_id)`, naming the person being put down. ★ Recommended.** Removal of a
named element is **idempotent *and* commutative** — replay it, reorder it, duplicate it, the end
state is the same. It also hangs on a UI row that already exists: the carried person's own crew row
gets a *Set down* button, so there is no new control and no second list to render.

> The lesson generalises and belongs in the invariants doc: **"absolute" means the end state is
> determined, not that the payload is a whole value.** A set-removal keyed by id is absolute in the
> way that matters and survives reordering, which a whole-list assignment does not.

---

## 3. `mass_kg` is a required sheet field — no default, ever

It cannot be a stat or a tag, for reasons the code already states:

- **Not a stat.** `Sheet::STATS` is six and
  [`races.yml`](../../content/archetypes/races.yml) calls that fixed. Worse, stats pass through
  `Minion#effective`, which multiplies by `Injury.derating` — so a broken arm would make somebody
  *lighter*. Mass is a property of the body; nothing about being hurt changes it.
- **Not a tag.** `Sheet::TAG_RANGE` is `0.0..1.0`. An ogre heavier than the reference cannot be
  expressed at all.

So: a third kind of sheet entry, in kilograms, which is the house unit everywhere else (`Parcel` is
kg, the ledger is kg, `lift_m` is metres).

**Absent is an error, not a default.** A defaulted mass is the worst of both worlds — it cannot be
seen in the content, and the number it quietly supplies is load-bearing in two formulas. The
enforcement points already exist or are one keyword away:

| Layer | Declared in | Absent ⇒ |
|---|---|---|
| 1. archetype | `content/archetypes/races.yml` | `build_sheet` does `base.fetch(stat)` with no default for stats already — `mass_kg` joins that, so a race without one **raises at boot** |
| 2. individual | `content/minions/` | Optional *offset*, because it is an offset — absent means "weighs what their race weighs" |
| 3. training | `kit.rb` via `Training.register` | Required kwarg ⇒ **ArgumentError at load**. Courses pass `mass_kg: 0` explicitly, because "learning weighs nothing" is a claim worth making rather than assuming |
| 4. equipment | `kit.rb` via `Equipment.register` | Required kwarg ⇒ **ArgumentError at load** |

Load-time failure is better than build-time here: `ruby -Ilib -e 'require "reactor_sim"'` catches
it, which is already a documented command and already in `bin/ci`.

### General → specific, through the fold that exists

`Sheet.add_stats` is *"merge adds; use multiplies"*, and for mass the adding is not an analogy — it
is literally correct. Archetype 70, this individual +8 because she is a big woman, −6 for a slight
one. So mass folds through the same four-layer machinery as everything else, and
**`Sheet.settle` gains a floor**: `MIN_MASS_KG`, because a stacked set of negative offsets must not
reach zero. The floor exists to catch a *runaway offset*, never to cover an absent declaration —
those are different failures and only one of them is allowed to be quiet.

Three archetypes exist, so the content change is three lines:

| Archetype | `strength` | `mass_kg` | Why |
|---|---|---|---|
| `human` | 1.0 | 70 | The reference, by definition |
| `elf` | 0.75 | 60 | *"Sharper eyes, sharper mind, less back"* — already the written character |
| `kobold` | 0.35 | 25 | Small enough that an ogre can stack several |
| `ogre` | 5.0 | 500 | **Now content.** Half a tonne is the interesting figure, not the strength: nothing can carry an ogre, which falls out of a real number rather than a rule |

> **`hulking` and `mass_kg` stay separate and must not be derived from each other.** `hulking`
> gates the `wedged` peril, and that is about *dimensions* — too big for the roadway side. Mass is
> about weight. A tall thin thing and a dense small thing are different problems.

---

## 4. Two accumulators: your frame, and your load

This is the one modelling decision that must not be got wrong. If equipment mass folded into
`mass_kg`, **gear would make you better at carrying** — a bigger frame rather than a heavier one.
So the fold splits by layer:

| | Field | Fed by | Means |
|---|---|---|---|
| Frame | `mass_kg` | layers 1–3 | the body doing the work. Floored above zero |
| Load | `worn_kg` | layer 4 only | what is hanging off it. Floored at zero |

The item's YAML/registry key is `mass_kg` in both cases — a pick's mass is its mass — and the
*fold* is what knows that a worn thing is load and a body is frame.

```
load_kg = worn_kg + Σ over carried (their mass_kg + their worn_kg)
burden  = load_kg / mass_kg
```

A carried person brings their own kit with them, which is both obviously right and the reason a
casualty in a diving set is harder to move than one in a shirt.

---

## 5. What a burden costs: two questions, two different inputs

The brief names strength **and** the mass ratio, and they do different work. Blending them loses
that; splitting them is simpler and more legible.

### Can you lift it at all? — strength and gear

```
lift_kg = LIFT_KG × effective(:strength) × (1 + aid)        # aid from stretcher, strong_back…
```

`effective` rather than the raw stat, so an injured arm reduces what you can pick up, free. The
check is against **total `load_kg`**, so your own gear eats into your lifting allowance — an
armoured rescuer carries less, which is correct and needs no extra rule.

A pickup that does not fit is **refused**, not slowed — the same shape as `assign_minion`'s
existing `can_reach?` and `room_at?` refusals. A refusal with a reason reads far better than a
carrier who crawls at 0.07 pace for twenty minutes.

### How much does it slow you? — the mass ratio

```
pace ×= 1 / (1 + DRAG × burden)
```

Carrier mass belongs *here* rather than in the lift limit, because shifting a load relative to your
own frame is what makes you slow — and because mass in the limit would make a fat weak minion a
good stretcher-bearer.

**Every minion now has a burden, always**, because gear has mass. Pace stops being a property of
the person alone, which is the point: *lighter gear that is otherwise equivalent becomes a real
upgrade*, and there was no axis for that before.

### Worked, at `LIFT_KG = 90`, `DRAG = 1.0` — shapes to measure, not figures to pin

| Carrier | Load | Limit | Fits? | Pace |
|---|---|---|---|---|
| Human (70, str 1.0), ordinary kit (6.5) | — | 90 | — | ×0.91 — kit is felt but not punishing |
| Human, heavy armour (25) | — | 90 | — | ×0.74 |
| **Kobold (25), the same ordinary kit (6.5)** | — | 31.5 | — | **×0.79** — the identical kit costs a kobold three times the pace |
| **Kobold, a small pick (1.5 + 2.5)** | — | 31.5 | — | **×0.86** — worse at hewing, better on its feet |
| Human + kit | one human + kit (76.5) | 90 | yes | ×0.44 — a fireman's carry, slow and worth it |
| Ogre (500, str 5.0) | six kobolds + kit (189) | 459 | yes | ×0.72 — *swoops in and gets them out* |
| Kobold | one ogre (400+) | 31.5 | **no** | refused — *basically unable to move the ogre* |
| Human **with a stretcher** (aid 0.5) | one human + kit | 135 | yes | ×0.44, and now an elf manages it too |

Three things fall out of that table that no rule had to state: small races want small gear, heavy
armour is a genuine trade against mobility, and the stretcher is **gear rather than a fitting** — a
tag and a mass in `kit.rb`, competing for one of three slots against a lamp and a respirator.

### Capacity is checked at pickup only

A tiring carrier's `effective(:strength)` falls, so a limit re-checked every tick would eventually
force a drop. **Rejected:** that is a second way to lose somebody, arriving without warning, in a
mechanic whose whole point is a clock the player can see. Fatigue instead shows up where it is
legible — pace collapsing toward zero strands the pair where they stand.

---

## 6. Fatigue: a fourth term, and the bug it fixes

`Fatigue.advance(minion, state, control:, dt:, demand:, suffocation:)` already has the precedent,
and its own comment explains why `suffocation:` sits outside `accrual`:

> **`suffocation:` is a third term rather than part of `accrual`**, because everything in `accrual`
> is about the work — station, lever, capability — and bad air is about *where you are*.

A burden is the same shape: it is about **what is on your back**, not about a station. So it is a
fourth term, netting with the others, and it applies whenever there is a burden — which now
includes just standing about in armour.

**This is not tidiness. Without it, carrying somebody is currently rest.** `Fatigue.recovery`
returns `BASE_RECOVERY` when `control` is nil, and a carrier has no station — so a rescuer hauling
a body across a district *recovers* fatigue the whole way.

### The accrual term is not enough on its own, and that is the trap

Accrual and recovery **net**, deliberately — it is what makes "light work is sustainable, hard work
is not" fall out of the arithmetic. But netting is exactly wrong here: a light casualty would
produce a small accrual that `BASE_RECOVERY` still beats, so carrying a kobold would read as a
*rest*. Shipping only the accrual term would leave the bug in place for every load under some
threshold and look fixed.

So there are two changes, doing two different jobs:

```ruby
# A hard gate, not a bigger number.
def recovery(control, state)
  return 0.0 if Array(state[:carrying]).any?   # you are not standing down, you are holding somebody
  return BASE_RECOVERY if control.nil?

  control.recovery
end
```

`state` is already in scope at the one call site — `advance` has it and simply does not pass it on
— so this costs a parameter and nothing else.

**The gate keys on carrying a *person*, never on `burden`.** Standing about in armour is still
resting; you are merely tired from wearing it. A body on your back is not rest at any weight. That
split is the same one `ControlPoint#recovery` already draws and says so:

> *an effort station recovers nothing, because you are still at the fire; a valve is somewhere to
> stand down to.*

So: **armour you can rest off, a casualty you cannot.** Which also means a rescue has a hard floor
on how long a carrier can keep going, and putting somebody down in a refuge to recover is a real
decision rather than a formality.

Accrual shape: proportional to `burden`, divided by `endurance` like every other accrual, and
applying whenever there is a burden — gear included. `EXPONENT` is probably wrong here: it exists
because a mismatch between demand and capability should compound, and burden is already a ratio.
Start linear and measure.

---

## 7. Order-independence, the one real hazard

Part 6 flagged this against shape (a) and it does not vanish in (b): two minions' states become
coupled inside a phase that treats each independently. `Tick#travel` is a `to_h` over
`minions_state`; if a carrier writes their casualty's place inside that map, the casualty's own
iteration overwrites it and which wins depends on hash order.

**Fix: phase 6e becomes two passes.**

1. **Walk.** Everybody not being carried takes their step, exactly as now. A carried minion is
   skipped — they have no journey of their own.
2. **Stow.** Each carried minion's `place` is written from their carrier's *post-pass-1* place.

Pass 2 is a pure function of pass 1's output, so the result cannot depend on visit order. It is
correct only if the carry graph is acyclic, which one rule guarantees:

> **A minion who is being carried may not carry.** Depth is exactly one: carriers and cargo, never
> a chain. Enforced at command time — refuse if the carrier is themselves carried, or if the target
> is holding somebody.

That rule also stops "stack six kobolds" becoming a conga line, and makes pass 2 a lookup rather
than a traversal.

### What a carried minion still gets, free and correctly

Because their `place` is real and rewritten every tick, a casualty **keeps taking the place they are
in**: `Breath`'s asphyxia clock runs, `Scorch` burns them, `Blunder`'s perils still reach them.
Carrying somebody out through a burning district is a race they can lose, with no new code — the
drama falls straight out of the spatial model.

---

## 8. What else falls out for nothing

- **A spent minion can be rescued.** `pace` runs through `capability`, which contains
  `(1 - fatigue)`, so a minion at `fatigue 1.0` has pace zero and **cannot walk out at all**. Today
  that is an immobilised worker with no counterplay but waiting. This was not the case the mechanic
  was designed for and it is the one that will come up most.
- **A seam, named and not built:** `mass_kg` is also what a cage's weight limit would read, and
  `manriding` already has capacity in it. *TODO: first caller is the cage's weight limit; not this
  release.* Flagged per the `CLAUDE.md` rule so it is neither deleted as dead nor re-invented
  beside itself.

---

## 9. The edits, with the trap on each

| Edit | Trap |
|---|---|
| `Minion#initial_state` gains `carrying: []` | — |
| `Tick#call`'s phase-8 return hash | **A key not named there is silently dropped.** `carrying` must be listed or the mechanic resets every tick |
| `Operation#restore` | **Symbols as values do not survive JSON** — `carrying` is an *array of id Symbols*, the **seventh** instance. A String id matches no minion, so a restored carrier holds a ghost. Assert with `be`, never `eq` |
| `Operation#crew_view` + delta protocol | `player_view_spec` guards that merged deltas equal a full view. A carried minion's travel bar should show **their carrier's** journey, or it reads as stuck |
| `Minion.new` gains `mass_kg:`/`worn_kg:` | Required, so **every spec fixture that builds a minion or an archetype fails until it declares one.** That is the intended noise. The rig consolidation just cut it from ~20 sites to `PitRig`, `ReferenceCrew`, `MineTech`, `PerilCrew`, `SlipCrew`, `LeverCrew`, `PassageRig` and two unit specs |

**The calibration risk, stated plainly:** every *equipped* minion gets slower, so any measured
figure taken with real kit moves. The reference fixtures carry no equipment (`worn_kg` 0, burden 0,
pace unchanged), so the engine and mine baselines should hold — but that is a prediction and the
first run after this is the one that checks it, not a thing to assume.

---

## 10. Rules worth settling before code

| Question | Recommendation | Why |
|---|---|---|
| Can a healthy minion be carried? | **Yes** | The restriction buys nothing — carrying is strictly slower, so there is no exploit — and ferrying a kobold past a hazard is legitimate. Pickup clears their station, as `Injury.apply_mode` already does |
| Pickup on arrival: automatic? | **Yes** | You went there to get them. A confirmation is a button that is always pressed |
| Casualty taken by somebody else mid-walk? | Pickup silently fails, posting clears | Rare, not worth an event type |
| Does set-down need an event? | **No**; pickup gets `minion_carried` at `:info` | The player pressed the button and knows where they stood. The pickup is the engine acting on its own, so it goes on the durable record — `:info`, so it does not crowd the incident feed |
| Two carriers for one casualty? | **Not now** | Nothing above needs it, and it wants a capacity-sharing rule that is real work |
| Does `worn_kg` affect anything but pace and fatigue? | **Not yet** | The cage limit is the named seam. Resist making it a `Blunder` or `Scorch` input until something asks |

---

## 11. What this supersedes in Part 6

Two claims there are now wrong and should be corrected when this lands:

- *"Nothing here works until the steam engine has places."* **Done** — the engine declares
  `:engine_house` with `air: :atmosphere` and places its levers.
- *"Nothing else. Resist adding a stretcher fitting, a two-carrier rule, or a fatigue cost until
  the basic loop is playable."* The fatigue cost is **in**, because without it carrying is rest
  (§6) — that was not a nicety being resisted, it was a bug being deferred. Mass is **in**, and
  went further than Part 6 imagined: it is what makes gear weight an upgrade axis. The
  two-carrier rule stays out.

---

## 12. Specs owed

- **A rescue end to end**, on `PitRig`: hurt somebody in the district, post a carrier, assert the
  casualty reaches the bank and the asphyxia clock stops rising.
- **Idempotence under replay**: the same fetch order twice mid-walk, and the same `set_down` twice,
  for an identical digest. This is the invariant §2's protocol choice exists to protect, so it is
  asserted rather than reasoned about.
- **Order-independence**: a carried minion's place equals their carrier's after a tick, with a crew
  large enough that hash order would otherwise show.
- **The asymmetries, as relationships and never figures**: a kobold is refused an ogre; an ogre
  carries several kobolds; a stretcher raises the limit; the same kit costs a kobold more pace than
  a human; a lighter tool is faster and worse.
- **Carrying is not rest** — fatigue rises while carrying, **and specifically with the lightest
  casualty the fixtures can produce**, because that is the case the accrual term alone gets wrong
  (§6). Asserting it with a heavy load would pass with the gate missing.
- **Mass is required** — an archetype or an item without one raises at load. Positive controls, or
  a typo'd key makes the check pass while proving nothing.
- **Snapshot**: `carrying` round-trips as Symbols, asserted with `be`.

## 14. What the building changed

Six things the sketch did not have right, kept here because the sketch is the reasoning and this
is where it was wrong:

1. **`set_down` became `drop_minion`.** Rubocop's `Naming/AccessorMethodName` is correct that
   `set_x(one_arg)` reads as a writer. `drop_minion` is parallel to `assign_minion`, which is the
   right company for it to keep.
2. **A carried minion keeps their station unless somebody takes it away.** The sketch said pickup
   clears it; the implementation has to clear it in `Tick#stow` *every tick*, not once at pickup,
   because `stow` is the single writer of a carried minion's state and a lone write would be
   undone by their own `assign`. Measured before the fix: a casualty hewed all the way to the pit
   bank.
3. **`Minion#worn_kg` is not required while `mass_kg` is.** Mass is *declared* by content, so an
   absent one is an authoring mistake. `worn_kg` is *summed* by `Crew#fold`, so zero is the honest
   answer for somebody carrying nothing.
4. **`liftable?` had to be told which `state` it meant.** The tick's whole previous state and a
   single minion's state hash are both called `state` in that file, and only one has a `:minions`
   key — the first draft read the wrong one and would have raised.
5. **The fetch order is never "already standing there".** `standing_at?` returns false for a
   posting that names a person even when the two are in the same room, because arriving sets
   `station`, and a minion id in `station` reads as a lever to `tire` and as a job to the panel.
6. **`minion_carried` exists after all.** §10 proposed it and this confirms it earns its place: the
   pickup is the engine acting on an order given minutes earlier and somewhere else, which is
   exactly what the durable record is for.

Everything in §5's table reproduced exactly, and §6's prediction held: with the accrual term alone
a kobold on a half-tired human came to **−0.068 fatigue per minute** — still a rest — against
**+0.064** with the recovery gate.

## 13. Docs owed, in the same commit

Per the root `CLAUDE.md` table: `reference/tick.md` (phase 6e becomes two passes),
`minion.rb`'s state list, `guides/add-content.md` + `content/CLAUDE.md` (**`mass_kg` is a new
required sheet field** — a schema statement, so both, and the `races.yml` header that says "the six
stats are fixed" now has a seventh thing to mention), `kit.rb`'s own header (every item declares a
mass), `reference/invariants.md` (**loudly**, if §2's "absolute means determined end state" is not
already written there), `spec/CLAUDE.md` (a row per new spec), and `current_progress.md` (the last
mine follow-up closes, and mass joins the traps list as a required-not-defaulted field).
