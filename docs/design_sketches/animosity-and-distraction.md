# Animosity and distraction

Status: **draft for review.** Unit 3 of the open-pit sequence (see
[`open-pit-iron-research.md`](open-pit-iron-research.md), [`crewed-posts.md`](crewed-posts.md),
[`conditions.md`](conditions.md)). It is general, so it lands on the colliery and the steam engine
first. Each of the pit's posts declares its own openings as it is built.

**Decisions already taken:**
- **People can hate each other.**
  - Races hold default grudges, which live in YAML.
  - Individuals can hold authored grudges. A notorious necromancer, say, is hated by some
    specific people for something in his past.
  - Grudges can also be created by what happens in a match, such as a brawl or being harmed.
- **Temperament tags:**
  - `short_tempered`, `callous` and `violent_nature`.
  - Opposites for each, so a cheery sprite rarely fights and a spiteful but conscientious elf
    harms a dwarf only where nobody else is caught.
  - `boneheaded` feeds in: a dummy may not see the danger in pulling a lever that squashes a git
    they dislike.
- **Three ways to do harm:**
  - abusing a station;
  - seizing an opportunity, such as a shove off a catwalk;
  - a brawl.

  Side effects are emergent.
- **A pit boss reduces conflict.** An ogre intimidates; a charismatic elf persuades and
  de-escalates.
- **Distraction** is anything that makes people less attentive, so accidents become likelier.
  Sources: a distracting person (the succubus), conditions (fantasy weather), and workplace
  modifiers (no morning coffee). How distracting someone is comes from a method like `swing`,
  combining their `distracting` tag, their kit and their charisma.
- **New races this pass:** dwarves, orcs and the succubus. Their specifics get your detailed pass
  later.
- **Grudges are not shown this pass.** They belong in a future report and on a recruitment screen.

---

## 1. What exists

| Piece | What it gives this unit |
|---|---|
| `Blunder` margin | Hidden and rolled wide. Spent by exposure, mended only somewhere safe, renewed at both ends of an episode. When it runs out, a die picks which peril it was. **Animosity copies this shape exactly** |
| Mishaps | `{ node:, kind:, share: }` goes to `state[:mishaps]`, and the part suffers it next tick. The colliery already has three that make deliberate acts: the shaft's `obstruction` (a tub let in), the haulage rope's `breakaway` (tubs off the rope, which is a `RUNAWAY` down the road), and the shot hole's `set_off` and `struck` |
| Perils | Reach places and stations. `struck_by_tub`, `caught_in_haulage`, `caught_in_the_belt`, `slipped_on_the_deck` and `misstep` are all places somebody could be pushed |
| `Injury.check` | The Danger Check. `impact` is resisted by `impact_resistance` |
| `Minion#wits` | One figure read by slips, lateness, misjudging, safety-equipment saves and gauge reading |
| `charisma` | Declared on every race and read by nothing. This unit is its first reader |
| `Blunder.accident_avoided?` | Safety equipment saving someone, scaled by their attention and capped at 85 %. The pattern for a boss stepping in |
| `InjuryList` → `MinionCondition` | An event carried across matches, idempotent per run. The pattern for grudges that outlast a match |
| Shaft `suffer` | Carries a TODO: a tub landing on the cage should be a falling-object hazard to its riders. **The banksman's spite would be its first caller** |
| Steam engine | One place, the engine house, and no perils. It gets rows, brawls and distraction, but no shoves and no openings |

---

## 2. The design

### 2.1 Grudges

A grudge runs one way, from a **holder** to a **target**, and is valued 0..1. The target is either
a race or a person. Four sources **add, then clamp**, by the same rule tags follow:

1. **Race:** `grudges: { elf: 0.4 }` on an archetype.
2. **Individual:** `grudges:` on an entry in `content/minions/`, keyed by race or by person. The
   same entry may also declare `resented_by:`, a grudge others hold against *this* person, which
   is how the necromancer is written down. It folds into the holders at build.
3. **Account:** grudges formed in earlier matches. The delivery tier passes them in through
   `options:` with the roster (§2.8).
4. **Match:** grudges formed in play, kept on the holder's state as `grudges: { seat => amount }`
   and added to the built table.

At build, `Animosity.table` resolves the first three into a frozen holder → target table over
the operation's seats, in sorted order. **A standin is subject to race grudges like anyone, and
nothing about a standin persists**, as with the injury list.

### 2.2 Temperament

Each axis is a pair of tags, read net (`a − b`), so every axis has an opposite as decided:

| Pair | Governs |
|---|---|
| `short_tempered` / `even_tempered` | How fast resentment wears through their patience |
| `callous` / `kindly` | How much harm to the **target** they will do |
| `reckless` / `conscientious` | How much harm to **bystanders** they will accept |
| `spiteful` / `forgiving` | How deep a grudge a wrong leaves, and how long it lasts between matches |
| `violent_nature` / `gentle` | Adds to temper and callousness both, and to how hard they hit in a brawl |
| `boneheaded` (exists) | Misjudges how harmful the act is (§2.4) |

These are read through `Minion#temperament(axis)` on a convex curve, as `daftness` is, because a
1.0 trouble tag is extreme.

### 2.3 Patience: how resentment becomes an act

This is `Blunder` with a target.

- **`patience`** is rolled wide at `initial_state` and renewed at both ends of an episode. A
  worker who has kept their temper all match has revealed nothing.
- **Spent** each second, for each person the holder shares a place with, at `(IRRITATION + grudge)`
  scaled by temper and by fatigue. Tired people quarrel.
  - `IRRITATION` is a small baseline towards anyone, so a crowded gang of short-tempered orcs rows
    among itself with no grudge at all (question 1).
  - An operation with no geometry is one place.
- **Mended only while nobody it is spent on is present**, which is the `Blunder` rule: a lull
  while you're still standing beside him isn't a rest.
- **Runs out:** an act aimed at the most resented person present, with ties broken by id.

**Alternatives considered:**
- **A per-tick chance with a die.** Simpler, but there is no build-up, no seething and no mending,
  so separating two people gains the player nothing.
- **A deterministic threshold.** The player learns it and farms it, which is the failure the
  margin's wide spread exists to prevent.

### 2.4 The act

The holder chooses among the acts open to them and drops any they are unwilling to do:

| Act | Open when | Believed harm | What happens |
|---|---|---|---|
| **A row** | Always | None | Both stop working for a short while. A notice event |
| **A brawl** | The target is in the same place | A blow | Both stop working for the brawl's length, and each lands one blow on the other: a Danger Check tagged `impact`, from the hitter's `swing` and `violent_nature`. While it lasts, everybody else in the place spends patience faster, so pile-ons are emergent |
| **A shove** | A peril declared `opportunity: true` reaches the target in their shared place | That peril's severity | The target suffers that peril now, as though their margin had run out: the same Danger Check, and the same mishap if the peril has one |
| **Sabotage** | The holder's post declares an **opening** that reaches where the target is | The opening's declared `harm:` | A deliberate mishap, through the same `state[:mishaps]` the clumsy banksman's goes through. **The physics does the rest**, to whoever is there |

**Willingness:**
- **To the target:** believed harm must be at most `grudge × CEILING`, scaled by
  callous + violent − kindly. Mild dislike gets a row; hatred can kill.
- **To bystanders:** believed harm × the number of other people it reaches must be within a
  tolerance, scaled by reckless − conscientious. The conscientious elf harms the dwarf only
  where nobody else is caught.
- **Boneheaded:** on the existing `misjudges` chance, the holder takes the act for harmless. That
  covers both the target's harm and the bystanders.
- **The pick:** one die chooses among the acts they will do, weighted evenly. With nothing
  acceptable, it is a row, since anyone will shout.

**An opening** is declared on a post, `ControlPoint openings:`:
- an `id`;
- a `mishap:`;
- a `reaches:` in the Peril shape (`places:`, `stations:`, `riders:`);
- a `harm:`.

**The first openings, all colliery:**

| Post | Opening | Mishap it reuses | Reaches |
|---|---|---|---|
| Banksman | A tub let into the shaft with the target below | Shaft `obstruction`, plus the falling-tub hazard its TODO names | Cage riders, pit bottom |
| Haulage (rope) | Knocking the tubs off the rope | Haulage rope `breakaway` | The road and pit bottom, along the `RUNAWAY` |
| Shotfirer | Firing with the target still at the face | The shot hole's firing mishap, settled while building | The district |

Openings that act on a lever, such as the winder overwinding or the onsetter's false ready, wait
until a post needs one. The shovel in unit 4 will (question 8).

**In the tick:** a new phase **6d′, provoke**, after blunder and before travel.
1. Every holder's decision is made from the state as the phase begins.
2. Blows and shoves are then applied to their targets in sorted holder order, so two people
   acting on each other in one tick cannot depend on visit order.

A brawl is `brawl_s` plus a `brawling` partner in state. While it runs, the minion's condition is
zero, so they man nothing, exactly like a spent minion. It ends when the counter runs out, when
either is stood down, or when one is moved away.

**After the act:**
- **The target forms or deepens a grudge** against the holder, after a row, a brawl or a shove.
  Its size is harm × spiteful − forgiving. A brawl leaves a grudge in both directions.
- **Sabotage is anonymous.** Nobody it hurts knows who did it, but the event names the
  saboteur to the player (question 5).
- **The holder's patience renews.**

### 2.5 The pit boss

- **A post with `oversees:` places**, where the part's tier sets how far it reaches.
- **Authority** is the better of:
  - **intimidation:** force, toughness and some charisma;
  - **persuasion:** charisma and intelligence.

  It is multiplied by condition (fatigue and injury) and counts only while the boss is at their
  post. An ogre and an elf get there by different stats.
- **Stepping in.** When someone's patience runs out in an overseen place, the boss may step in.
  This is the `accident_avoided?` shape: authority × the boss's wits against a die, **capped at
  the same 85 %**, because buying safety never buys immunity.
  - **Stepped in:** a `quarrel_averted` event naming the boss, since the player has to be told
    the boss is earning their keep. The holder's patience renews.
- **Brawls are broken up sooner** in overseen places, in proportion to authority.
- **Intimidation breeds resentment.** An act averted by intimidation leaves the holder a small
  grudge against the boss; persuasion leaves none. The ogre works now and costs later
  (question 2).
- **The colliery part** is an **overman**, in a new optional `supervision` slot that is empty by
  default. It is posted in the district and oversees the district and the pit bottom: in a real
  pit, the official in charge underground.

### 2.6 Distraction

- **How distracting someone is:** `Minion#allure(state)`. It combines the `distracting` tag (on a
  convex curve) with effective charisma, and kit can lower either. It is derived, like `swing`,
  and is not a stat.
- **What someone takes from it:**
  - the allure of everybody else in their place, reduced by `focused`;
  - plus the room's `distracting` offer;
  - plus their own `distracted` tag.

  Nobody is distracted by themselves.
- **What it does,** in two places:
  - a divisor on `wits`, beside `green`;
  - an addend in `Blunder`'s careless term.

  Through `wits`, it reaches slips, lateness, misjudging, safety-equipment saves and gauge
  reading all at once. An otherwise excellent succubus makes her whole gang worse at everything
  that takes attention.
- **Worked out** from the previous tick's positions and memoised per tick like `ambient_before`.
  It needs no state.
- **Sources this pass:**
  - **People:** built, with the succubus as the first.
  - **The room:** the read side is built, but nothing offers it yet.
    `TODO: first caller is an enchanted weather kind`.
  - **Their own tag:** the read side is built.
    `TODO: first caller is match modifiers (no morning coffee)` (question 6).

### 2.7 Content (first figures, for your detailed pass)

| | Dwarf | Orc | Succubus |
|---|---|---|---|
| `mass_kg` | 75 | 95 | 60 |
| strength / toughness / endurance | 1.15 / 1.4 / 1.2 | 1.05 / 1.3 / 1.1 | 1.0 / 0.9 / 1.1 |
| intelligence / dexterity / charisma | 1.0 / 1.1 / 0.8 | 0.7 / 0.8 / 0.6 | 1.3 / 1.25 / 1.8 |
| Tags | darkvision 0.6, hazard_sense 0.15, spiteful 0.4 | darkvision 0.4, short_tempered 0.4, violent_nature 0.3, callous 0.2 | darkvision 0.5, distracting 0.6, heat_hardened 0.2 |
| Grudges | elf 0.4, orc 0.5 | elf 0.5, dwarf 0.4 | none |

**Existing races:**
- **Elf:** a grudge against dwarves (0.3) and orcs (0.4); `conscientious` 0.2.
- **Ogre:** `short_tempered` 0.3.
- **Kobold:** a grudge against dwarves (0.2).
- **Human:** nothing.

**Individuals:**
- One new individual for each new race.
- One authored individual grudge, so the path has content: Galathas holds one against Throg.

**Kit:**
- a sackcloth smock (`distracting −`, `charisma −`);
- blinkers (`focused +`, a little `intelligence −`).

All of these figures are first guesses.

### 2.8 Across matches

- **The `grudge_formed` event** carries the holder and target as person ids and the amount.
- **The Rails side:**
  - A `Grudge` row per owner, holder and target, idempotent per run, as `MinionCondition` is.
  - A `GrudgeList` service called beside `InjuryList` in `ProgressionConsumer`.
  - `DevMatch` passes the grudges among the fielded roster in through `options:`, normalised by
    `Crew.normalise`.
- **Nothing is shown in the UI this pass.** Rows, brawls, shoves, sabotage and averted quarrels
  reach the incident feed as events, and for now those are the player's only sign of a feud.

### 2.9 Determinism and state

- **Dice come from a second stream per person**, with a fixed set of draws every tick drawn
  unconditionally:
  - patience renewal;
  - which act;
  - the bonehead's misjudgement;
  - the boss stepping in.

  The existing per-person draws are untouched, **so every existing seeded spec keeps its
  numbers**. The new stream joins the flat id namespace, and `validate_graph!` checks it like any
  other.
- **New minion state:**
  - `patience` and `patience_full`;
  - `grudges`, keyed by seat;
  - `brawl_s`;
  - `brawling`, a seat id held as a value, so it is **normalised on restore**.
- **Sabotage pending** rides on `state[:mishaps]`.
- **New event types:** `quarrel` (`mode:` row, brawl, shove or sabotage), `quarrel_averted`,
  `grudge_formed`.

---

## 3. Specs (relational only)

- **Patience:** spent only while the target is present, and mended apart. A short-tempered holder
  spends faster than an even-tempered one, and a deeper grudge faster than a shallow one.
- **Willingness:**
  - a callous holder takes an opening a kindly one declines;
  - a conscientious one declines with a bystander present and takes it without;
  - a bonehead takes one they would otherwise decline.
- **The act:**
  - a brawl stops both people working and bites both, and the target comes out holding a grudge;
  - a shove gives the target the peril's Danger Check;
  - sabotage lands its mishap on the next tick.
- **The boss:**
  - averts some acts in places they oversee and none elsewhere;
  - never averts all of them;
  - intimidation leaves the holder a grudge against the boss, persuasion does not.
- **Distraction:**
  - a succubus in the place lowers others' wits and raises their slip chance;
  - she is unaffected herself;
  - the smock lowers her effect and `focused` resists it.
- **Content:** race, individual, `resented_by` and account grudges add and then clamp.
- **Determinism:** a snapshot taken mid-brawl replays bit for bit, and the existing per-person
  draw count is unchanged.
- **Rails:** `grudge_formed` becomes a row once per run, and the roster carries grudges into
  `options:`.
- **Events:** each new type is emitted somewhere (`event_spec` scans for it).

## 4. Docs touched in the same change

- [`tick.md`](../reference/tick.md) and `lib/reactor_sim/CLAUDE.md`: phase 6d′, and the second
  stream.
- [`add-content.md`](../guides/add-content.md) and `content/CLAUDE.md`: `grudges:`,
  `resented_by:`, the temperament tags, `distracting` and `focused`, and the new races.
- [`build-an-operation.md`](../guides/build-an-operation.md) and `operations/CLAUDE.md`:
  `openings:`, `opportunity:` on perils, `oversees:`, and the supervision slot.
- [`settlement.md`](../reference/settlement.md): the new minion state keys.
- [`invariants.md`](../reference/invariants.md): none. A second stream per person is still a
  seeded stream drawn in phase 0.
- `spec/CLAUDE.md`, `app/CLAUDE.md` (grudges across matches), `current_progress.md`.

---

## 5. Questions for review

1. **Crowding irritation.** I recommend a small baseline towards anyone. Then a big gang of
   short-tempered orcs fights among itself, and crew size becomes a temper cost as well as an
   accident cost.
   - **Pro:** strong texture in a pit full of gangs.
   - **Con:** another figure to tune.
   - **Alternative:** grudges only. Calm and short-tempered crews then differ only once someone
     is resented.
2. **Intimidation breeds resentment against the boss**, and persuasion doesn't. I recommend
   yes: it makes the two styles a choice rather than a ranking. The alternative is that
   authority is authority.
3. **The boss's reach.** I recommend a declared patch per tier, so an upgrade covers more. The
   alternative is only the place they stand in, which is truer but makes the boss one more
   person to walk around.
4. **Grudges across matches.** I recommend they persist and fade each match: forgiving speeds the
   fade and spiteful slows it. The alternatives are permanent grudges (a long feud is a real cost
   of keeping both), or only authored ones persisting.
5. **Sabotage is anonymous to the victims but named to the player.** I recommend yes, because
   the player needs to learn there is a feud. The alternative names nothing, and the player
   deduces it.
6. **Distraction seams.** I recommend building the read side for the room and for the person's
   own tag, with TODOs and no caller this pass, and leaving the coffee modifier until match
   modifiers exist. The alternative is a minimal modifier on `MatchSetup` now.
7. **Does the boss also cut distraction?** I recommend no: keep the two mechanics separate and
   leave focus to kit. The alternative is a "mind your work" share of authority.
8. **Openings this pass:** the three colliery mishaps only. Lever-shaped openings wait for the
   shovel.
9. **Race figures:** first guesses, kept until your detailed pass?
