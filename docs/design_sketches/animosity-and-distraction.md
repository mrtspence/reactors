# Animosity and distraction

Status: **built.** The review answers, and what was settled while building, are in §6. Unit 3 of
the open-pit sequence (see [`open-pit-iron-research.md`](open-pit-iron-research.md),
[`crewed-posts.md`](crewed-posts.md), [`conditions.md`](conditions.md)). It is general, so it lands on
the colliery and the steam engine first. Each of the pit's posts declares its own openings as it is
built.

**Decisions already taken:**
- **Grudges:**
  - Race grudges live in YAML, and individuals can hold authored ones.
  - Grudges also form in play, from a brawl or from being harmed.
  - Grudges persist across matches and fade.
- **Temperament tags,** each with an opposite: `short_tempered`, `callous`, `violent_nature`.
  `boneheaded` misjudges the danger.
- **Three ways to do harm:** abusing a station, seizing an opportunity, a brawl. Side effects are
  emergent.
- **Combat** is a reusable pair of derived figures: `attack` and `defend`. Swarms of bats and
  wandering zombies will use them later.
  - Weapons add to `attack` and decide the wound.
  - Defensive gear adds to `defend`.
  - Bonuses sum across gear.
- **`avoid`** is perceiving a hazard *and* being agile enough to get out of its way. It replaces
  wits alone wherever a hazard is being avoided.
- **A pit boss** reduces conflict, by intimidation or by persuasion. The boss may also be the
  distraction.
- **Distraction:** from a distracting person, from conditions, and from workplace modifiers.
  Modifiers are deferred.
- **New races this pass:** dwarves, orcs and the succubus, with your figures in §2.9.
- **Grudges are not shown this pass.** They belong in a future report and on a recruitment screen.

---

## 1. What exists

| Piece | What it gives this unit |
|---|---|
| `Blunder` margin | Hidden and rolled wide. Spent by exposure, mended only somewhere safe, renewed at the ends of an episode. **Patience copies this shape** |
| Mishaps | `{ node:, kind:, share: }` goes to `state[:mishaps]`, and the part suffers it next tick. The colliery already has three that make deliberate acts: the shaft's `obstruction`, the haulage rope's `breakaway` (a `RUNAWAY` down the road), and the shot hole's `set_off` and `struck` |
| The false ready | A slipping marshal rings the cage away while somebody is still getting in, and `Tick#boarding` catches them between cage and shaft side (`caught_boarding`). **The marshal's opening is this, done on purpose** |
| Perils | `struck_by_tub`, `caught_in_haulage`, `caught_in_the_belt`, `slipped_on_the_deck` and `misstep` are all places somebody could be pushed |
| `Injury.check` | The Danger Check. A hazard tag `x` is resisted by `x_resistance`, so a new wound tag needs no lookup table |
| `Minion#swing` | `√force`: a tool at the end of an arm. The base of `attack` |
| `Minion#wits` | Read by slips, lateness, misjudging, gauge reading, and two hazard-avoidance sites (§2.5) |
| `charisma` | Declared on every race and read by nothing. This unit is its first reader |
| `Blunder.accident_avoided?` | Safety equipment saving someone, capped at 85 %. The pattern for a boss stepping in |
| `InjuryList` → `MinionCondition` | An event carried across matches, idempotent per run. The pattern for grudges |
| Shaft `suffer` | Carries a TODO: a tub landing on the cage should be a falling-object hazard to its riders. **The banksman's spite is its first caller** |
| Kit tools | Stoker's shovel, oil can, gauge spanner, crude and proper miner's tools, stretcher. No knife |
| Steam engine | One place and no perils. It gets rows, brawls and distraction, but no shoves and no openings |

---

## 2. The design

### 2.1 Grudges

A grudge runs one way, from a **holder** to a **target**, and is valued 0..1. The target is either a
race or a person. Four sources **add, then clamp**, by the same rule tags follow:

1. **Race:** `grudges: { elf: 0.4 }` on an archetype.
2. **Individual:** `grudges:` on an entry in `content/minions/`, keyed by race or by person.
   - `resented_by:` declares a grudge others hold against *this* person, which is how the
     necromancer is written down. It folds into the holders at build.
3. **Account:** grudges formed in earlier matches, passed in through `options:` with the roster
   (§2.10).
4. **Match:** formed in play, kept on the holder's state as `grudges: { seat => amount }` and added
   to the built table.

At build, `Animosity.table` resolves the first three into a frozen holder → target table over the
operation's seats, in sorted order. **A standin is subject to race grudges like anyone, and nothing
about a standin persists.**

### 2.2 Temperament

Each axis is a pair of tags read net (`a − b`), on a convex curve as `daftness` is:

| Pair | Governs |
|---|---|
| `short_tempered` / `even_tempered` | How fast resentment wears through patience |
| `callous` / `kindly` | How much harm to the **target** they will do. Half the grudge itself counts as callousness towards the one it is held against (`GRUDGE_HARDENS`), so a kind elf makes an exception for orcs |
| `reckless` / `conscientious` | How much harm to **bystanders** they will accept |
| `spiteful` / `forgiving` | How deep a grudge a wrong leaves, and how fast it fades between matches |
| `violent_nature` / `gentle` | Adds to temper, and to hostility: a grudge against everybody (`VIOLENCE_HOSTILITY`), so it raises both how often they run out and how far they go, grudge or none |
| `annoying` / `calming` | How much the holder's mere presence costs everybody else's patience: scales `IRRITATION`, never a grudge |
| `boneheaded` (exists) | Misjudges how harmful the act is (§2.4) |

### 2.3 Patience: how resentment becomes an act

- **Rolled and renewed like `Blunder`'s margin.** `patience` is rolled wide at `initial_state`, and
  each time it runs out the next one is drawn.
- **Spent** each second while the holder shares a place with anybody.
  - The rate is the deepest grudge held against anybody present, plus `IRRITATION` for each person
    present, scaled by temper and by fatigue. Two people one hates wear no faster than the worse of
    them; a crowd wears by its size.
  - `IRRITATION` is a small baseline towards anyone, so a crowded gang of short-tempered orcs rows
    with no grudge at all, and crew size becomes a temper cost. Each person's share of it is
    scaled by their own `annoying` − `calming`, so one grating hand wears down a room and one
    calming one settles it.
  - An operation with no geometry is one place.
- **Mended only while nobody it is spent on is present.**
- **Runs out:** an act aimed at somebody present who is not already in a row or a brawl, chosen by
  the `target:` die weighted by how much each is resented (`Animosity.pick`), so the most resented
  is the likeliest and never the only one. With the one they hate most busy, they turn on somebody
  else; with nobody free, they seethe.
- **The act releases it.** The act restores some of the new patience: a little for a row, more for
  a shove or sabotage that lands, and a share per exchange in a brawl (§2.6). Release is what
  stops one grudge from setting off the next act at once, and what stops a brawl lasting forever.

### 2.4 The act

The holder chooses among the acts open to them and drops any they are unwilling to do:

| Act | Open when | Believed harm | Resolved by |
|---|---|---|---|
| **A row** | Always | None | Both stop working briefly. No contest |
| **A brawl** | The target shares their place | A blow, or a weapon's if they would kill | Exchanges every few seconds until it ends (§2.6) |
| **A shove** | A peril declared `opportunity: true` reaches the target in their shared place | That peril's severity | **Binary contest**, with unarmed `attack` against `defend`. If it lands, the target suffers the peril now, with its own Danger Check and its mishap if it has one. A near miss is still a miss |
| **Sabotage** | The holder's post declares an **opening** that reaches where the target is | The opening's declared `harm:` | **Binary contest**, with unarmed `attack` against `defend`. If it lands, the opening's deed is done, and **the physics does the rest** to whoever is there. If it fails, the target saw it coming: nothing happens, and the target now knows who did it |

**Willingness:**
- **To the target:** believed harm must be at most `hostility × CEILING`, scaled by callous −
  kindly + half the grudge. Hostility is the grudge plus violent − gentle, so a violent nature
  brawls with somebody it holds nothing against. Mild dislike gets a row; hatred can kill.
- **To bystanders:** believed harm × the number of others it reaches must be within a tolerance,
  scaled by reckless − conscientious.
- **Boneheaded:** on the existing `misjudges` chance, the holder takes the act for harmless.
- **The pick:** one die chooses among the acts they will do, weighted evenly. With nothing
  acceptable, it is a row.

**An opening** is declared on a post, `ControlPoint openings:`:
- an `id`;
- a deed;
- a `reaches:` in the Peril shape (`places:`, `stations:`, `riders:`, plus `boarding:` a hoist);
- a `harm:`.

A deed is one of two kinds:
- **a mishap**, through `state[:mishaps]`;
- **a deliberate slip** at the holder's own lever, through a new pending `state[:spite]` that next
  tick's `slips_for` begins in place of a die. As always, it changes `actual` and never `target`.

**The first openings, all colliery:**

| Post | Opening | Deed | Reaches |
|---|---|---|---|
| Banksman | A tub let into the shaft with the target below | Shaft `obstruction`, plus the falling-tub hazard its TODO names | Cage riders, pit bottom |
| Banksman, onsetter | The all-clear rung while the target is still getting in | Deliberate `false_ready` slip at their marshal post | Whoever is boarding at their landing |
| Haulage (rope) | Knocking the tubs off the rope | Haulage rope `breakaway` | The road and pit bottom, along the `RUNAWAY` |
| Shotfirer | Firing with the target still at the face | The shot hole's firing mishap, settled while building | The district |

**In the tick:** a new phase **6d′, provoke**, after blunder and before travel.
1. Every decision, and every exchange, reads the state as the phase begins.
2. Blows, shoves and pending deeds are then applied in sorted holder order, so two people acting on
   each other in one tick cannot depend on visit order.

**After the act:**
- **The target forms or deepens a grudge** against the holder after a row, a brawl, a shove or a
  foiled sabotage. Its size is harm × spiteful − forgiving.
- **A brawl's blows leave no grudge of their own.** Its start leaves the target a minor one, and
  once it is over, either fighter carried out by it (severe) or sent briefly to the afterlife
  (mortal) holds `WOUND_GRUDGE` against the other, by spite. Two who blow off steam without
  dropping each other part no worse than they started, so a long fight does not ferment into
  loathing.
- **Sabotage that lands is anonymous** to the people it hurts. The event names the saboteur to the
  player.

### 2.5 Combat: `attack`, `defend` and `avoid`

These are derived figures, like `swing`, on `Minion`. They are not stats, and they are built for
reuse: a swarm of bats or a wandering zombie attacks through the same contest.

- **Two new stock stats**, on every archetype. Both join `Sheet::STATS`, so an archetype that omits
  either is refused at boot (`REQUIRED_ARCHETYPE_KEYS` is the label plus every stat). An absent one
  can't quietly zero `attack`, `defend` or `avoid`.
  - **`combat_prowess`**, a ratio where a human is 1.0 and a trained fighter 2 or 3. It enters
    both `attack` and `defend`, so it cuts both ways: a seasoned scrapper is harder to hurt and
    does more harm once roused. Kit and training offset it like any stat.
  - **`agility`**, a ratio where a human is 1.0. It is getting your body out of the way, and moving
    it.
    - **Injury:** a minor injury derates it as it does strength, and a severe one zeroes it.
    - **Walking:** it enters `Minion::PACE` beside strength and toughness, so elves walk faster
      and ogres slower. A human paces 1.0 as before, so every human-crewed spec keeps its walk
      times.
    - **Burden:** pace is already `capability(PACE) × Burden.pace_factor`, so a load slows an agile
      walker exactly as it slows anyone.
- **`attack(state, armed:)`** = `combat_prowess × the weapon's handling × condition`: the
  weapon's `handling:` blend read off this body, as a station's `effort:` is. Bare hands are a
  profile of their own (`Equipment::UNARMED`); `armed:` takes whichever fitted weapon does this
  hand the most damage (`Minion#wielding`).
  - Shoves and sabotage are always unarmed.
- **`defend(state)`** = `avoid × combat_prowess × (1 + defence)`.
  - `defence` is a valued tag, so gear sums it through the ordinary fold: a shield, a ring.
  - No current item declares it. `TODO: first caller is combat gear`; specced with a constructed
    item.
- **`avoid(state, ambient:, burden:)`** = `√(wits × agility)`.
  - Here `agility` is the effective stat, slowed by what they carry (`Burden.pace_factor`), so
    an orc in full kit dodges badly.
  - The geometric mean keeps a competent human at 1.0. It is zero if either figure is zero, since
    you must both see it coming and get clear. It also counts condition once, because both factors
    already carry it.
  - Distraction reaches `avoid` through `wits`.
- **The avoid retrofit.** Wits stays where the question is perception or judgment: slips, lateness,
  misjudging, gauge reading. It moves to `avoid` where a hazard is being avoided:

  | Site | Today | After |
  |---|---|---|
  | `Tick#guarding`, safety equipment saving someone | `wits` | `avoid` |
  | `Tick#refuge_reached`, a refuge hole on the road | `wits` | `avoid` |
  | `Tick#caught?`, crushed by a runaway | No stat, chance only | Chance ÷ `avoid` |
  | `Blunder.susceptibility`, how much of a peril reaches you | Tags only | `avoid` in its wary term |

  A human stays at 1.0, so human baselines hold. What moves is any crew that isn't human, which is
  measured at build: kobolds get worse, and so does an ogre in heavy kit.

- **`precision`** is a derived figure beside `force` and `swing` (`Sheet::DERIVED`): agility 0.6
  and dexterity 0.4, a human 1.0. Any `effort:` blend or weapon `handling:` may name it.
- **`strike(state)`** = `combat_prowess × (swing + precision) ÷ 2`. It is whether a blow, a shove or
  a deed lands; `attack` is how hard a blow hits once it has. Bulk tells half on landing, so a
  clumsy giant lands about as often as an elf. A weapon changes damage only.
- **The contest is `Combat`**, its own module. Each side's figure is multiplied by its own
  phase-0 die on a bell in log space — `exp(CONTEST_SPREAD × z)`, `z` the die's standard normal
  deviate, so most rolls sit near the figure and the far ends are rare — and the ratio is
  `r = strike ÷ defend`.
  - **A blow** lands only if `r > 1`. It lands in full from `r ≥ FULL_AT` (1.5) and scales linearly
    in between, so a glancing blow hurts less than one that catches clean. Its severity is
    `BLOW × (attack × damage stretch + edge) × landed share`, and its Danger Check carries the
    weapon's wound tags. **From `r ≥ CRITICAL_AT` (3.0) it is a
    critical, which finds the gap**: the Danger Check meets no resistance kit and only
    `CRITICAL_TOUGHNESS` (½) of the body's toughness (`pierces:`), and nothing is added.
  - **A shove or sabotage** succeeds if `r > 1`, and nothing scales.
- **Weapons.** An item may carry `weapon: { handling:, edge:, wounds: }` (`Equipment.weapon_profile`):
  - `handling:` is a blend, like a station's `effort:`, whose weights may sum past one for a good
    weapon or short of it for a poor one;
  - `edge:` is severity the weapon adds to a landed blow whoever holds it, a point or a blade;
  - `wounds:` are the hazard tags it leaves, and its weight is the item's own `mass_kg`.

  `Crew` lists the profiles one by one (`Minion#weapons`): a hand swings one at a time. A new
  hazard tag `puncture` is resisted by `puncture_resistance` through the existing naming convention.

  | Item | Handling: swing / precision | Edge | Wounds |
  |---|---|---|---|
  | Bare hands (`UNARMED`) | 0.42 / 0.18 | 0 | `impact` |
  | Miner's tools (steel pick) | 0.8 / 0.2 | 0.3 | `puncture`, `impact` |
  | Crude miner's tools (stone pick) | 0.7 / 0.2 | 0.2 | `puncture`, `impact` |
  | Stoker's shovel | 0.75 / 0.15 | 0.1 | `impact` |
  | Gauge spanner | 0.6 / 0.3 | 0.05 | `impact` |
  | Clasp knife (utility) | 0.2 / 0.8 | 0.3 | `puncture` |
  | Oil can, stretcher | not weapons | — | — |

  - **The clasp knife** also carries a `cutting` aid, through `aided_by:`, on the posts where a
    knife helps:
    - re-roping and recapping;
    - the haulage rope splice;
    - shotfiring, for fuses.

    It competes with the lamps for the utility slot.

### 2.6 The brawl

- **Exchanges.** Every `BOUT_S` (a few seconds), each fighter makes an `attack` on the other,
  contested by the other's `defend` as in §2.5. Both happen in the same exchange, from the state at
  its start.
- **Escalation is a chance each exchange** (`Animosity.escalation`): `ESCALATION`, times the
  square of how deep the hostility is against a grudge that would kill at a neutral temperament,
  times callousness once, on its own `escalate:` die. Once drawn, a weapon stays drawn for the fight, and
  a `quarrel` with `mode: :armed` says so. Each fighter decides with their own grudge, so the target
  can escalate too, and a kindly one with no grudge stays on fists.
- **A weapon drawn on you is answered.** Once the other has drawn, at an earlier exchange, a fighter
  also draws on a flat `ANSWER` chance each exchange on top of their own, whatever their temper:
  somebody swinging a pick at you is met with yours within an exchange or two.
- **Neither works.** While `brawl_s` runs, both have a condition of zero, like a spent minion, so
  they man nothing. Fighting is exertion and tires them (`Animosity.exertion`): a flat rate, and
  armed, more by the weapon's weight against their `force` — the measure the lift limit reads. A
  three-kilo pick costs a man half again; a kobold several times over; an ogre next to nothing.
- **Orders wait.** A brawler's posting is still written, since the command is absolute and
  idempotent, but travel does not move them until the brawl ends. Then they go.
- **Any number can be in it**, and it lasts while anybody in it is willing: §7.2. Every exchange
  restores some patience to everybody standing in it, more when a blow lands, twice as much once
  the fight has given them a minor injury and four times a significant one (`HURT_RELIEF`), and some
  for every injury they see (`WITNESSED`). A tooth out makes anybody think twice without stopping a
  determined attacker, and the one set upon walks away calmer, not angrier. Patience comes back
  every exchange, landed or not, so a brawl ends even between two people who can never hit each
  other.
- **Pile-ons are emergent.** Fighting spends everybody else's patience in the place faster while it
  lasts, and anybody who runs out on somebody fighting joins in or heckles.

### 2.7 The pit boss

- **A post with `oversees:`,** a patrol of places. The part's tier sets the patrol.
- **Authority** is the better of:
  - **intimidation:** force, toughness and some charisma;
  - **persuasion:** charisma and intelligence.

  It is multiplied by condition, and counts only while the boss is at their post.
- **Stepping in.** When someone's patience runs out in an overseen place, the boss may step in, by
  the `accident_avoided?` shape: authority × the boss's wits against a die, **capped at 85 %**.
  - **Stepped in:** a `quarrel_averted` event names the boss, and some patience is restored.
  - **Brawls:** the same check runs at each exchange in an overseen place, and on success breaks the
    brawl up.
- **Intimidation breeds resentment.** An act averted by intimidation leaves the holder a small
  grudge against the boss. Persuasion leaves none.
- **The boss does not cut distraction, and may be it.** A succubus boss settles the most bitter crew
  and has them blundering for it.
- **The colliery part** is an **overman**, in a new optional `supervision` slot that is empty by
  default. Posted in the district, patrolling the district and the pit bottom.

### 2.8 Distraction

- **How distracting someone is:** `Minion#allure(state)`. It combines the `distracting` tag (on a
  convex curve) with effective charisma.
  - Both fold in kit, positive or negative: a skimpy uniform raises it and blinkers on others resist
    it.
  - Race-restricted skimpy uniforms are content for the succubus's later outfitting pass. The read
    already supports them.
- **What someone takes from it:**
  - the allure of everybody else in their place, reduced by their own `focused`;
  - plus the room's `distracting` offer;
  - plus their own `distracted` tag.

  Nobody is distracted by themselves.
- **What it does:** a divisor on `wits`, beside `green`, and an addend in `Blunder`'s careless term.
  - Through `wits`, it reaches slips, lateness, misjudging and gauge reading.
  - Through `avoid`, it reaches safety saves, refuges and `defend`. A distracted man is easier to
    shove.
- **Worked out** from the previous tick's positions and memoised per tick. It needs no state.
- **Seams:**
  - **The room offer:** `TODO: first caller is an enchanted weather kind`.
  - **The person's own tag:** `TODO: first caller is match modifiers (no morning coffee)`.

### 2.9 Content

Your figures:

| | Dwarf | Orc | Succubus |
|---|---|---|---|
| `mass_kg` | 75 | 150 | 60 |
| strength / toughness / endurance | 1.2 / 1.5 / 1.2 | 1.3 / 1.25 / 1.2 | 1.5 / 1.5 / 1.5 |
| intelligence / dexterity / charisma | 1.0 / 1.0 / 0.7 | 0.8 / 0.8 / 0.4 | 1.5 / 1.5 / 1.8 |
| agility / combat_prowess | 0.7 / 1.1 | 0.9 / 1.3 | 1.5 / 2.0 |
| Tags | darkvision 0.7, short_tempered 0.1, spiteful 0.3 | darkvision 0.4, short_tempered 0.3, violent_nature 0.3, callous 0.2 | darkvision 0.5, heat_hardened 0.5, distracting 0.7 |
| Grudges | elf 0.2, orc 0.4, kobold 0.4, ogre 0.1, succubus 0.1 | elf 0.4, dwarf 0.4 | none |

**Existing races:**

| Race | agility / combat_prowess | Adds |
|---|---|---|
| Human | 1.0 / 1.0 | — |
| Elf | 1.3 / 1.3 | conscientious 0.2; grudges: dwarf 0.2, orc 0.4 |
| Ogre | 0.5 / 1.0 | short_tempered 0.4, callous 0.3 |
| Kobold | 0.7 / 0.5 | grudge: dwarf 0.2 |

**Individuals,** all on their race's defaults: Urist Glazecanyons (dwarf), Dalthu Splintertusk (orc),
Arunessa (succubus). Galathas holds an authored grudge against Throg.

**Kit:** blinkers (`focused +`, a little `intelligence −`), the clasp knife, and the weapon
profiles in §2.5.

**Spec archetypes.** Every in-memory archetype in the spec rigs gains both stats, because a missing
one is now refused at boot. `reference_crew` is the one to watch: it declares them at a human's
figures, so it keeps its baselines.

### 2.10 Across matches

- **The `grudge_formed` event** carries the holder and target as person ids and the amount.
- **The Rails side:**
  - A `Grudge` row per owner, holder and target, idempotent per run as `MinionCondition` is.
  - Each match start fades every row, faster for `forgiving` and slower for `spiteful`, and removes
    it at zero.
  - A `GrudgeList` service is called beside `InjuryList` in `ProgressionConsumer`.
  - `DevMatch` passes the grudges among the fielded roster in through `options:`, normalised by
    `Crew.normalise`.
- **Nothing is shown in the UI this pass.** Rows, brawls, shoves, sabotage and averted quarrels
  reach the incident feed as events.

### 2.11 Determinism and state

- **A second stream per person** draws eight figures every tick, unconditionally:
  - patience renewal;
  - which act;
  - the bonehead's misjudgement;
  - the boss stepping in;
  - the attack die;
  - the defence die;
  - the escalation die;
  - who they go for.

  The existing per-person draws are untouched, **so every existing seeded spec keeps its numbers**.
  The stream's id joins the flat namespace and `validate_graph!` checks it.
- **New minion state:**
  - `patience` and `patience_full`;
  - `grudges`, keyed by seat;
  - `brawl_s`;
  - `brawling`, a seat id held as a value, so it is **normalised on restore**.
- **New operation state:** `spite`, the pending deliberate slips, named in phase 8. Its control and
  slip ids are values, so they are normalised on restore.
- **New event types:**
  - `quarrel`: `mode:` row, brawl, shove or sabotage, with `foiled:` on a sabotage that failed;
  - `quarrel_averted`;
  - `grudge_formed`.

---

## 3. Specs (relational only)

- **Patience:** spent only while the target is present and mended apart. Faster for a
  short-tempered holder and for a deeper grudge. An act restores some of it.
- **Willingness:**
  - a callous holder takes an opening a kindly one declines;
  - a conscientious one declines with a bystander present and takes it without;
  - a bonehead takes one they would otherwise decline.
- **Combat:**
  - more prowess raises both `attack` and `defend`;
  - a weapon raises `attack` only when armed;
  - defensive gear sums;
  - a clean blow bites harder than a glancing one;
  - a pick wounds `puncture` and `impact`;
  - a shove either lands in full or not at all.
- **`avoid`:** zero when either wits or agility is zero. Lower when burdened or distracted. Every
  retrofitted site reads it.
- **The new stats:**
  - an archetype missing `agility` or `combat_prowess` is refused at boot;
  - a more agile race walks faster than a less agile one under the same load;
  - a load slows both.
- **The clasp knife:** it speeds a post that names `cutting`.
- **The brawl:**
  - repeats exchanges until it ends;
  - holds a move order until it ends, then the brawler goes;
  - ends when the initiator is sated, even if no blow ever lands;
  - leaves the target holding a grudge;
  - draws a weapon on a chance that climbs steeply with willingness to kill.
- **Sabotage:**
  - a landed deed reaches its node on the next tick;
  - a foiled one does nothing and leaves the target a grudge;
  - a false ready catches a boarder.
- **The boss:**
  - averts some acts in overseen places and none elsewhere, and never all of them;
  - breaks up brawls;
  - intimidation leaves a grudge against the boss, persuasion does not.
- **Distraction:** a succubus lowers others' wits and `avoid` but not her own. Gear that raises
  allure raises it. Blinkers resist it.
- **Content:** race, individual, `resented_by` and account grudges add and then clamp.
- **Determinism:** a snapshot mid-brawl replays bit for bit, and the existing per-person draw count
  is unchanged.
- **Rails:** `grudge_formed` becomes one row per run, rows fade per match, and the roster carries
  grudges into `options:`.
- **Events:** each new type is emitted somewhere (`event_spec`).

## 4. Docs touched in the same change

- [`tick.md`](../reference/tick.md) and `lib/reactor_sim/CLAUDE.md`: phase 6d′, the second stream,
  and `avoid` at the safety-equipment, refuge and runaway sites.
- [`add-content.md`](../guides/add-content.md) and `content/CLAUDE.md`: the stats become eight
  (`agility`, `combat_prowess`), `grudges:`, `resented_by:`, temperament, `distracting`,
  `focused`, `defence`, `cutting`, `puncture`, and the new races. `races.yml`'s header and
  `sheet.rb`'s stat table say what each new stat drives.
- [`build-an-operation.md`](../guides/build-an-operation.md) and `operations/CLAUDE.md`:
  `openings:`, `opportunity:` on perils, `oversees:`, and the supervision slot.
- [`settlement.md`](../reference/settlement.md): the new minion and operation state keys.
- [`invariants.md`](../reference/invariants.md): none. The second stream is still seeded and drawn
  in phase 0.
- `spec/CLAUDE.md`, `app/CLAUDE.md` (grudges across matches), `current_progress.md`.

---

## 5. Questions

None open. The build reports what the retunes measure (§2.5) and any figure that won't hold.

---

## 6. Review decisions

### First review

1. **Crowding irritation:** yes.
2. **Intimidation breeds resentment against the boss:** yes.
3. **The boss covers a declared patch per tier,** fiated as a patrol.
4. **Grudges persist across matches and fade.**
5. **Sabotage is anonymous to its victims and named to the player.**
6. **The coffee modifier is deferred** until match modifiers exist. The read sides are seams.
7. **The boss does not cut distraction,** and may be the distraction.
8. **Openings:** the three colliery mishaps, plus the marshal's false all-clear while the victim is
   still boarding.
9. **Race figures:** your content pass, in §2.9.

**Added in review:**
- **Combat:** `combat_prowess`, `attack` from `swing`, `defend` from `avoid`.
  - A blow scales from glancing to full, landing in full at 1.5× the defence.
  - Shoves and sabotage are binary and unarmed.
  - Weapons decide the wound, and gear bonuses sum.
- **`avoid`** replaces wits for hazard avoidance.
- **Brawls** are repeated exchanges. Brawlers refuse to move. Every release of ire restores some
  patience.
- **Allure** takes positive gear modifiers.
- **Blinkers** in. The smock out.

### Second review

1. **`combat_prowess`** is **validated like the other stats**, so a missing one can't zero attack
   and defence. Rebased while building: it is a plain ratio, human 1.0, multiplying straight in
   (elf 1.3, dwarf 1.1, kobold 0.5, ogre 1.0, orc 1.3, succubus 2.0; a trained individual 2–3).
2. **`avoid` reaches the runaway and the accident margin too**, beside the two wits sites.
3. **The clasp knife comes in with this unit.** It aids the jobs where a knife helps: rope work,
   the splice, and fuses.
4. **`agility` is a stock stat on every race** rather than a blend, and it drives walking speed.
   Burden already scales pace, which I checked: `Minion#pace` multiplies by
   `Burden.pace_factor`. The figures are in §2.9.

### Settled while building

- **`Minion::PACE` is strength 0.4, agility 0.4, toughness 0.2**, so a human still paces 1.0.
- **The shotfirer's opening is a charge left live** (the shot hole's `misjudged` mishap), for the
  hewers' existing `struck_live_charge` peril to finish. Nothing in the shot hole hurts the district
  on firing, so "firing with the target at the face" had no physics to land on.
- **The hauling hands' loosed set runs down onto the pit bottom, where they stand** — `RUNAWAY`
  reaches whoever is at its foot, saboteur included.
- **The falling tub** is a `tub_fell` event from the shaft's `suffer`, keyed in its
  `failure_hazards` and named in `mishap_modes`, so the injury walk accepts a hazard that is a
  mishap's consequence rather than a failure.
- **A shove needs the peril live**: in front of a tub only while tubs are running
  (`Tick#opportunities`, from `perils_in_reach`).
- **Grudges held in state are capped at a whole grudge**, as the built table is.
- **First figures, measured once**: an orc among two elves and a dwarf at bank brawled first at
  about 3½ minutes and every few minutes after, and a clean blow from him puts an elf into severe.
  `SPEND_PER_S` was halved and `BLOW` cut to 1.0 to get there; the first draft had him through three
  people in five minutes.
- **The persisted grudge is idempotent per run and tick**, because a run deepens the same pair more
  than once legitimately.
- **The phase costs about 6 % of a mine tick**, and the temper dice about 3 %.

### Tuning pass: nobody is safe in a fight

Asked for: an orc or an ogre should face some risk even brawling a kobold, hit at least 5 % of the
time. The first contest stretched each figure uniformly over 0.5–1.5×, so the best ratio was 3:1 and
a kobold (attack 0.25) never beat an orc's guard (1.10) at all. And a blow's severity used the
unrolled attack, so even a landed kobold blow could never get past an orc's toughness.

**Whether a blow lands** now uses a log-logistic stretch, `CONTEST_SPREAD` 0.4: a median of one and
no ceiling. A kobold lands 7.0 % of blows on an orc (0.35 gave 4.8 %, 0.45 gave 9.3 %). Two equal
humans land under half the time, because `defend` carries `avoid` and `attack` does not.

**How hard it hits was the harder half.**
- Reading the rolled attack for severity let a lucky blow get through somebody tough, but it made
  fists deadly: an orc killed an elf or a human with about 24 % of exchanges, and two humans each
  other with 4.5 %.
- A cap stopping fists just short of mortal was rejected in review. A big fist may kill a kobold
  now and then; what must not happen is a brawl with an orc being a death sentence for an elf.
- **What stayed:** a separate, tight damage stretch on the same attack die
  (`(u ÷ (1 − u))^DAMAGE_SPREAD`, 0.2, so a good swing is good both ways and freak blows are rare),
  and bare hands at `UNARMED` of it — first 0.8, then **0.6**, so somebody swinging a pick to kill
  is far deadlier than somebody beating the brakes off a rival after a shouting match.
- **Elves to toughness 0.9** from 0.7, in the same pass.

Per exchange at `UNARMED` 0.8, over a 240 × 240 grid of dice, in the light:

| | Lands | Hurts | Kills |
|---|---|---|---|
| orc → elf, fists | 55 % | 45 % | 3.2 % |
| ogre → elf, fists | 58 % | 49 % | 4.4 % |
| orc → human, fists | 68 % | 57 % | 2.9 % |
| orc → kobold, fists | 99 % | 99 % | 11.7 % |
| human → human, fists | 39 % | 18 % | 0 % |
| human → orc, fists | 49 % | 11 % | 0 % |
| kobold → orc, fists | 7 % | 0 % | 0 % |
| orc → elf, pick | 68 % | 62 % | 31 % |

Per whole brawl, simulated 4,000 times each, where a brawl runs about three exchanges:

| `UNARMED` | Orc → elf: severe | Orc → elf: dead | Human → human: hurt | Human → human: dead |
|---|---|---|---|---|
| 0.8 | 78 % | 8 % | 25 % | 0.3 % |
| 0.7 | 73 % | 4.7 % | 16 % | 0.2 % |
| 0.6 (shipped) | 57 % | 2.2 % | 8 % | 0.1 % |

**A kobold lands on an orc but cannot hurt one bare-handed.** Its attack is 0.25 against an orc's
toughness of 1.25, and the tight damage stretch keeps it there.

**Weapons were a switch, and that read as rival gangs.** An orc's standing dislike of elves already
reaches lethal willingness, so an orc carrying miner's tools drew the pick on an elf at the first
blow and killed in about half those brawls. Drawing is now a chance each exchange
(`ESCALATION` 0.02 at exactly lethal, times the fourth power past it):

| Orc's grudge against the elf | Draws, per exchange |
|---|---|
| 0.4 (the race's) | 2.7 % |
| 0.6 | 14 % |
| 0.8 | 44 % |
| 1.0 | certain |

At `UNARMED` 0.8, a tooled orc with the race's grudge drew in about 8 % of brawls with an elf, and
the elf died in 12 % of them against 8 % bare-handed — figures from a simulation that held the
grudge fixed.

### The brawl matrix

**`script/tuning/brawls.rb` is the instrument for every pass from here**: every character against
every other, themselves included, 100 brawls a pairing, through the real tick and phase 6d′, all
carrying picks, written to [`docs/tuning/brawls.md`](../tuning/brawls.md). It is deterministic, so a
pass is a diff of that file. It records who landed, how cleanly, by what margin and how hard; when a
weapon came out; how each brawl ended; and who was hurt, carried out or killed, with killings split
between fists and a drawn weapon. First run at `UNARMED` 0.6:

- **Orc → elf:** the elf is carried out in about three brawls in four and dies in about one in ten.
  About 3 % of brawls end in a death by fists and 8–9 % once the orc has drawn, which he does in
  14 %, his grudge deepening as the elf hits back.
- **Elves, humans and dwarves among themselves** rarely carry each other out (1–8 %) and never kill.
- **Anybody who picks a fight with an orc, an ogre or the succubus** is carried out more often than
  not, and dies in 2–10 % of those fights.
- **A kobold is carried out by anybody**, and killed by the big three in 6–8 % of brawls.
- **The succubus is nearly untouchable** (defence 3.0): starting a fight with her is carried out in
  92–96 % of brawls.
- **A dwarf is rarely taken off the shift** by anybody short of the big three, on toughness 1.5.

### Strike, and criticals

**Landing now reads `strike`**, half swing and half accuracy, so bulk tells in full only on
damage. Stats moved in the same pass, by hand: elves to agility and prowess 1.35, ogres to
toughness 1.6, orcs to agility 0.8 and prowess 1.1, and `ESCALATION` to 0.03.

**A critical (`CRITICAL_AT` 3×, double damage) is not rare under this contest.** The heavy-tailed
landing roll reaches 3× on 8 % of blows between two humans and 26 % between two orcs. Measured with
`--set` on a five-strong cast (Jim, Elowynne, Dalthu, Throg, Arunessa), killed by the starter:

| | No criticals | 3× | 5× | 8× |
|---|---|---|---|---|
| Jim → anybody | 0 % | 0–2 % | 0–2 % | 0–2 % |
| Elowynne → anybody | 0 % | 1–9 % | 0–6 % | 0–4 % |
| Throg → Jim | 7 % | 45 % | 21 % | 15 % |
| Arunessa → anybody | 1–4 % | 27–48 % | 16–44 % | 7–37 % |

Doubling damage turns the heavy hitters' landed blows into killing ones at any threshold, while an
elf's doubled fist (0.82 × 2) barely clears an ogre's toughness of 1.6.

**Reviewed, and three changes.**
1. **Combat is its own module** (`Combat`): the dice, landing, damage and criticals, which
   anything that ever comes to blows will reuse. `Animosity` keeps grudges, temper, willingness
   and escalation.
2. **The landing roll is a bell, not a tail**: `exp(spread × z)` on the die's standard normal
   deviate. A high roll becomes an event, so a critical comes mostly from a real mismatch of strike
   against defence.
3. **A critical finds the gap**: no toughness and no resistance, nothing added. A precision bonus
   (the striker's strike added on a critical) was tried on top and dropped: with the gap already
   ignoring toughness, adding half the strike let an ogre's fists kill a third to a half of
   whoever he fought.

Measured on the core cast (no succubus, who is a deliberate outlier), 100 brawls a pairing, pierce
only:

| | Bell 0.3 | **Bell 0.4 (shipped)** | Bell 0.5 |
|---|---|---|---|
| Criticals, human on human | 0 % | 4 % | 9 % |
| Criticals, elf on ogre | 67 % | 64 % | 63 % |
| A kobold lands on an orc | 0 % | 2 % | 3 % |
| Humans, elves and dwarves kill each other | ~0–1 % | ~1 % | ~1 % |
| Orc kills elf: by fists / once drawn | 1 % / 8 % | 1 % / 6 % | 1 % / 5 % |
| Ogre's fists kill, by target | 10–18 % | 5–18 % | 8–19 % |
| An elf starts it, the ogre is carried out | 60 % | 55 % | 50 % |

**Still open, all of them stat questions rather than combat ones:**
- **Ogres are easy to hit and to crit** (defence 0.50 from agility and wits of 0.5), so an elf lands
  a critical on nearly two blows in three and carries an ogre out in more than half the brawls she
  starts. And an ogre's fists, piercing on a critical, kill 5–18 % of whoever he fights.
- **A kobold barely lands on an orc any more** (2 %). Strike now counts its accuracy (0.66), and the
  bell has no long tail to rescue it. The first tuning pass's 5 % is not met.
- **An orc draws on an elf in nearly half their brawls** at `ESCALATION` 0.03, as the elf hits back
  and his grudge deepens.

### A critical meets part of the toughness

Asked for: let the big races take more of a beating and stay vulnerable. A critical still slips
past the armour, but now meets `CRITICAL_TOUGHNESS` of the body's toughness instead of none. Carried
out, the row starting it:

| | Ignored (0) | Quarter | **Half (shipped)** |
|---|---|---|---|
| Elowynne → Throg | 55 % | 10 % | 1 % |
| Elowynne → Dalthu | 33 % | 22 % | 6 % |
| Urist → Throg | 31 % | 5 % | 0 % |
| Arunessa → Throg | 100 % | — | 62 % |

**At a half, the big races are close to immune to the light precise fighters**: an elf's fist (0.82
bare-handed) has almost nothing left against half an ogre's 1.6. And because an elf cannot drop an
orc, their fights run longer and he draws more: Dalthu draws on Elowynne in 71 % of brawls and
kills her in 15 %, against 46 % and 6 % with toughness ignored. A quarter sits where the request
pointed — an elf takes an ogre off the shift in about one brawl in ten.

### Escalation on a square, a grudge as callousness, and answering a weapon

Asked for: elves hardly ever drew on orcs despite a 0.75 grudge, and goblins hardly ever drew at
all. The draw chance was `ESCALATION × (willingness ÷ LETHAL)⁴`. That fourth power flattened
everything short of lethal willingness, and a neutral temperament could not reach lethal at all
(a full grudge came to 0.8 of it). On top of the cubic callousness curve, drawing ran roughly as
grudge⁴ × (1 + callousness)¹², so a small tag change moved it by orders of magnitude.

Changed:
- **A square, not a fourth power.**
- **Half the grudge counts as callousness towards its target** (`GRUDGE_HARDENS`). A kind elf makes
  an exception for orcs. This reads everywhere callousness does, so it raises the harm somebody is
  willing to do by a shove or sabotage too, against that target only.
- **A weapon drawn on you is answered** (`ANSWER` 0.5 each exchange on top of your own chance, from
  the exchange after it was drawn).

With both of the first two at `ESCALATION` 0.1, Elowynne drew on Dalthu 24 % of exchanges before he
answered. At 0.05, the per-exchange chance before anything is hit:

| Holder → target | Grudge | Written | Callous 0 / violent 0 | Callous 0.4 / violent 0.3 |
|---|---|---|---|---|
| Elowynne → Dalthu | 0.75 | 12 % | 12 % | 100 % |
| Galathas → Throg | 0.6 | 6 % | 6 % | 74 % |
| Dalthu → Elowynne | 0.4 | 12 % | 1.5 % | 24 % |
| Rijgazh → Elowynne | 0.2 | 4 % | 0.2 % | 4 % |
| Somebody neutral, grudge earned in play | 0.4 | 1.5 % | 1.5 % | 24 % |

Through the tick, a subset at 100 brawls a pairing, the starter drawing / the target drawing by the
end:

| Starter → target | As written | Everyone callous 0 / violent 0 | Dalthu violent 0.6, Rijgazh callous 0.6 / violent 0.5 |
|---|---|---|---|
| Elowynne → Dalthu | 43 % / 67 % | 31 % / 21 % | 55 % / 89 % |
| Dalthu → Elowynne | 78 % / 77 % | 33 % / 68 % | 85 % / 77 % |
| Rijgazh → Elowynne | 52 % / 76 % | 31 % / 70 % | 58 % / 78 % |
| Urist → Dalthu | 56 % / 76 % | 52 % / 30 % | 74 % / 94 % |
| Urist → Elowynne | 65 % / 44 % | 65 % / 44 % | 65 % / 44 % |
| Jim → anybody | 1–6 % | 0–6 % | 1–8 % |

Deaths stayed at 0–4 % of brawls in every cell, because a weapon comes out late in a fight.

**What decides drawing now is the grudge a fight builds, more than the grudge it starts with.**
Rijgazh opens at 4 % an exchange against an elf, and still draws in half the brawls he starts with
one, because the elf hits him often and every blow deepens his grudge, which now also hardens his
callousness. Urist is the clearest case: 0.2 % at the outset, 0.2 grudge, but spiteful, and in a
seven-exchange fight he mostly loses to an elf, so he draws in 65 % of them. Losing makes you
reach for the pick.

### Grudges from wounds, not blows; callousness cubed once

Asked for: a fight between two who do not drop each other should blow off steam, not ferment into
loathing; and temperament should move drawing less violently. So:
- **Blows leave no grudge.** The start of a brawl leaves the target its minor one, and once the
  fight is over, a fighter carried out holds `WOUND_GRUDGE` severe (0.15) and one killed holds
  mortal (0.3) against the other, by spite.
- **Escalation is `ESCALATION × (grudge × CEILING ÷ LETHAL)² × callousness`**: the square on the
  grudge alone, callousness entering once. Neutral to the most callous now moves the chance about
  4–5×, against orders of magnitude before. `ESCALATION` went to 0.1 to put an elf's 0.75 grudge
  at about 9 % an exchange.
- **`annoying` / `calming`** scale what each person's presence costs everyone's patience.

Through the tick at 100 brawls a pairing, the starter drawing / the target drawing by the end:

| Starter → target | As written | Everyone callous 0 / violent 0 |
|---|---|---|
| Elowynne → Dalthu | 26 % / 26 % | 23 % / 17 % |
| Dalthu → Elowynne | 33 % / 52 % | 24 % / 47 % |
| Rijgazh → Elowynne | 22 % / 51 % | 20 % / 51 % |
| Urist → Dalthu | 25 % / 29 % | 20 % / 18 % |
| Urist → Elowynne | 4 % / 6 % | 4 % / 6 % |
| Galathas → Throg | 14 % / 6 % | 14 % / 6 % |
| No grudge either way (Jim, Arunessa, the kobold, any same-race pair) | 0 % | 0 % |

Deaths are 0–3 % of brawls everywhere. **Who draws is now decided by the grudges in content**, and a
pair with none never draws. **Rijgazh barely draws of his own accord**: his 0.2 grudges, squared,
come to 1.5 % an exchange, and most of his draws answer an elf's 0.75. His callous, violent nature
shows in how often he starts trouble, not in how armed it gets, unless his grudges are raised.

### Violence as hostility

Asked for: goblins more stabby without making them hate everyone. `violent_nature` − `gentle` moved
out of callousness and into **hostility**, the grudge plus violence × `VIOLENCE_HOSTILITY` (1.0),
which feeds both the harm somebody will do (so a violent nature brawls rather than rows with
somebody it holds nothing against) and the squared term in escalation. It still feeds temper.

| Starter → target | Before | Violence as hostility | Rijgazh at violent 0.6 |
|---|---|---|---|
| Rijgazh → Elowynne | 22 % / 51 % | 33 % / 58 % | 46 % / 63 % |
| Rijgazh → Jim | 0 % | 8 % / 6 % | 30 % / 19 % |
| Rijgazh → Throg | 0 % | 4 % / 2 % | 18 % / 8 % |
| Dalthu → Elowynne | 33 % / 52 % | 38 % / 53 % | — |
| Dalthu → Jim | 0 % | 7 % / 4 % | — |
| Elowynne → Dalthu | 26 % / 26 % | 29 % / 34 % | — |

Per exchange against a stranger: Rijgazh 1.6 %, Dalthu 1.0 %, everybody else nothing. Deaths stay at
0–1 % of brawls even for the more violent goblin. The matrix starts every brawl, so it does not
measure the other half of the change, how often a violent nature picks a brawl over a row.

### Crowds: the first look

`script/tuning/crowds.rb` puts 2–32 people in one lit room for an hour, three seeds each. Nobody
works, everybody carries miner's tools, and nobody is revived. Figures from
[`tuning/crowds.md`](../tuning/crowds.md):

| Room | First quarrel | Rows / brawls an hour | Half the room down |
|---|---|---|---|
| 2 or 4 humans, any temperament | never | 0 / 0 | never |
| 8 humans | 35 min | 3 / 0 | never |
| 8 humans, 2 annoying 0.6 | 20 min | 11 / 0 | never |
| 16 humans | 14 min | 26 / 1 | never |
| 16 humans, all calming 0.3 | 40 min | 2 / 0 | never |
| 32 humans | 6 min | 76 / 1 | never |
| 4 of the gang | 4.5 min | 0 / 2 | 13 min |
| 8 of the gang | 1.8 min | 10 / 9 | 16 min |
| 16 of the gang | 0.7 min | 19 / 12 | 6 min |
| 32 of the gang | 0.2 min | 41 / 27 | 5 min |

With a boss over 16 of the gang, half the room was down at:

| Boss | Style | Averted an hour | Half down |
|---|---|---|---|
| None | — | 0 | 6 min |
| Throg (ogre) | stares | 24 | 10 min |
| Dalthu (orc) | stares | 6 | 7 min |
| Rijgazh (goblin) | talks | 3 | 7 min |
| Elowynne (elf) | talks | 77 | 26 min |
| Arunessa (succubus) | talks | 427 | never (7 of 17 down) |

What it shows:
- **A brawl is never more than two.** Somebody whose most resented is already in a row or a brawl
  only ever seethes: 100 % of such running-outs without a boss. Nobody joins, turns on somebody
  else, or waits for them. A fight spreads only through `RUMPUS` speeding everybody else's spend,
  and through the seething, which hands back a fifth of a patience and so runs out again soon.
- **The most resented is a tie broken by seat id**, so where nobody holds a grudge, everybody picks
  on the same person: in 16 humans over half an hour, every quarrel was aimed at `p00` (or at `p01`
  by `p00`).
- **Patience is spent on the sum of everybody present**, so each person runs out in proportion to
  the room, and the room's quarrels grow faster than its size: 3 → 35 → 290 running-outs an hour at
  8, 16 and 32 humans.
- **A brawl takes somebody off the shift often**: carried out or killed in 18–62 % of brawls between
  the gang's grudge-holders, and 18–28 % between two elves on fists, since a long fight grinds the
  loser's resilience to nothing. With nobody revived, a mixed room is half down inside a quarter of
  an hour.
- **A boss's chance is authority × wits**, and on paper Elowynne and Arunessa tie (0.95), well
  ahead of Throg (0.45), Dalthu (0.47) and Rijgazh (0.52). What separates them in a room is
  **whether the boss stays on their feet**: a boss in a fight or carried out oversees nothing. Nobody
  much resents Arunessa, so she averts six times what Elowynne does, whom the orcs and goblins
  resent. Over 16 of the gang, on one seed, the boss was carried out at: Rijgazh 1.5 min, Dalthu
  3.4, Elowynne 7, Throg 11, Arunessa never.

### Crowds: the second pass

Changed, from the first look:
- **The target is picked by a die weighted by resentment**, from everybody not already in a row or
  a brawl. Waiting for the busy one and going for them when their fight ended was considered and
  dropped: it would keep a resented boss in fights without end.
- **Patience wears by the deepest grudge present**, plus `IRRITATION` for each person there.
- **Both fighters are relieved each exchange**, and a hurt fighter more: twice at a minor injury,
  four times at a significant one (`HURT_RELIEF`), instead of yielding.
- **A new `minor` tier** (a knock: a tooth, a finger, a rib, a ringing head) at under 80 % of
  resilience, derating by a tenth or so. The old walking wounded is **`significant`**, its derates
  unchanged, moved to under 45 % from 60 %.

| Room | Half down: before → after | Brawls an hour | Ran out / seethed an hour |
|---|---|---|---|
| 4 of the gang | 13 → 18 min (2 of 3 shifts) | 2.3 → 2.3 | 2 / 0 → 4 / 0 |
| 8 of the gang | 16 → 19 min | 9 → 7 | 20 / 2 → 13 / 0 |
| 16 of the gang | 6 → 25 min | 12 → 18 | 60 / 28 → 49 / 0 |
| 32 of the gang | 5 → 14 min | 27 → 31 | 302 / 234 → 124 / 0 |
| 32 humans | never → never | 1 → 6 | 290 / 213 → 198 / 0 |

| Over 16 of the gang | Half down: before → after |
|---|---|
| No boss | 6 → 25 min |
| Throg | 10 → 24 min |
| Dalthu | 7 → 35 min |
| Rijgazh | 7 → 24 min |
| Elowynne | 26 → 28 min (2 of 3 shifts) |
| Arunessa | never → never (6 of 17 down) |

Over 8 of the gang, Throg and Arunessa now keep half the room up for the whole shift.

What it shows:
- **The seething is gone and the riots slowed by a factor of two to four**, and the fighting
  spread: 32 humans row 192 times an hour against 76, because they are no longer all queuing for
  `p00`.
- **The engine of attrition is still one brawl's carry-out rate**: 16 of the gang has 18 brawls
  and 9 severe injuries an hour. Nothing but the starter's relief ends a fight, so a victim takes
  blows until the starter is satisfied; the matrix carries somebody out in 20–37 % of the gang's
  grudge pairings, and the kobold in nearly all of them.
- **Irritation still sums**, so a big room still quarrels more per head: each of 32 humans starts
  six rows an hour, each of 16 about two. Harmless in itself, since a row stops two people for `ROW_S`, but it
  is work lost and it scales with the room.

## 7. Melee: a design pass

**Status: built (§7.14 for what changed in the building).**

A brawl today is a pair. The starter runs the exchanges, holds the clock, and is the only one
whose relief can end the fight; anybody whose patience runs out on somebody already fighting picks
somebody else. This section replaces the pair with a **melee**: any number of people in one place,
each swinging at whoever they most want to hit, ending when nobody left wants to.

### 7.1 What was asked, and what this pass keeps of it

| Asked | Kept? |
|---|---|
| Each exchange, every fighter picks who to hit by the grudge-weighted die | Yes, with one change to the weights (§7.3) |
| A stacking defence penalty for each attacker in the same exchange, flat 0.25 | Yes, as a divisor rather than a subtraction (§7.4) |
| Running out on somebody already fighting joins their fight | Yes, replacing "pick somebody else"; the row-only heckle instead (§7.7) |
| One person going down does not end it | Yes |
| Relief when anybody in your fight is hurt, by your grudge and their injury | Yes, stacking with your own (§7.5) |
| Mortally wounded leave the fight; seriously wounded fight on, worse | Yes; already true of `significant`, and the carried-out stay pickable by those who would kill them (§7.6) |
| A truce once nobody has anybody left to hate, violence counting | Yes, folded into one ending rule (§7.2) |
| It lasts while anybody is still willing, not until the starter is sated | Yes (§7.2) |

### 7.2 Who is in it, and when it ends

Two words do all the work:

- **Willing:** still angry (patience under `SATED` of full) **and** holding hostility — grudge plus
  violence, as escalation reads it — against somebody still in the fight.
- **Wanted:** somebody still in the fight is willing and holds hostility against them.

Each exchange:

1. A **willing** fighter picks who to hit, by the weighted die, from everybody in the fight they
   hold any hostility against.
2. An **unwilling but wanted** fighter defends themselves: they hit back at somebody who wants
   them, weighted by how much each wants them. Their own anger is spent; they are not walking away
   from somebody still swinging at them.
3. An **unwilling, unwanted** fighter steps out. Their fight is over even if others' is not.
4. The fight ends when **nobody in it is willing**. Everybody left steps out at once.

That one rule covers every ending in the request, without a separate truce check:

| Ending asked for | Why it falls out |
|---|---|
| Everybody has run out of ire | Nobody is under `SATED`, so nobody is willing |
| A truce: nobody has a grudge left against anybody still in it | Nobody holds hostility against anybody present, so nobody is willing |
| Nobody left standing | Nobody present at all |
| 100 % snaps at 99 %; the starter is sated first | The 99 % is still willing, so it goes on; the sated starter, wanted, defends |
| Two orcs, having beaten a dwarf, keep going at each other | Violence is hostility towards everybody, so each stays willing until sated |
| Four dwarves, having beaten a hated goblin boss, stop | With the boss gone, no dwarf holds hostility against another, so none is willing |

**The starter stops being special.** Nobody leads; the exchange is the fight's, not anybody's.

### 7.3 Who they hit

The pick that starts a fight weighs **grudge + irritation**, so that anybody can quarrel with
anybody. Inside a fight it should weigh **hostility only — grudge + violence, no irritation.**
Irritation is what starts a row in a crowded shed; it is not a reason to punch a fellow dwarf in the
middle of beating a goblin. With irritation in the weights, every melee would leak blows onto allies
at about `IRRITATION` ÷ grudge of the time, and the uprising would turn on itself.

**Violence against grudge, mid-fight.** Two goblins (violent 0.7, grudge 0.2 against dwarves) beating
a dwarf weigh the dwarf at 0.9 and each other at 0.7, so with plain weights each goblin's blow goes at
his mate 44 % of the time **while the dwarf is still standing**. That reads as chaos rather than
"goblins turn on each other once the dwarf is down". A focus exponent on the weights sharpens it:

| Weights raised to | Goblin hits the dwarf | Goblin hits his mate |
|---|---|---|
| 1 (plain) | 56 % | 44 % |
| 2 | 62 % | 38 % |
| **2.5 (chosen)** | 65 % | 35 % |
| 3 | 68 % | 32 % |

**Weights are raised to a `FOCUS` of 2.5**, a dial beside the others and a first target of tuning.
The alternative, violence counting only once nobody with a grudge is left, is a special case of
exactly the kind this pass is removing.

### 7.4 Defending against several at once

Everybody picks first, from the state the exchange starts in; then each person's attackers are
counted. **Every attack on somebody hit by n people this exchange meets their defence ÷ (1 +
`GANGED` × (n − 1))**, `GANGED` 0.25 to start.

- **The same penalty for all of them, by count, not by order.** "Each time you are attacked" in a
  simultaneous exchange needs an order to number the attacks, and any order is an order-dependence.
  The count gives the same total and needs none.
- **A divisor, not a subtraction.** A flat 0.25 off the figure takes a kobold's defence (about 0.6)
  to nothing at three attackers and barely dents Arunessa's. Off a multiplier it never goes below
  zero, and a ring of attackers keeps getting worse without a cliff:

| Attackers | Subtracting 0.25 each | ÷ (1 + 0.25 × extra) |
|---|---|---|
| 1 | 1.00 | 1.00 |
| 2 | 0.75 | 0.80 |
| 3 | 0.50 | 0.67 |
| 5 | 0.00 | 0.50 |
| 8 | — | 0.36 |

- **Criticals come for free.** A critical needs a margin of `CRITICAL_AT` (3.4); at three attackers
  each of them needs only 2.25 of their unpenalised margin, so the cheap shot from behind is the
  same arithmetic.
- **Each attack meets its own defence roll**: the fractional part of the defender's `defend:` die
  plus the attacker's `attack:` die. Uniform, independent per attacker, and nothing new drawn. One
  die per exchange would have let one bad moment land every attacker at once, coupling the attacks
  by more than the penalty and making the penalty hard to tune.
- **No state is kept.** The count is made fresh each exchange; nothing needs clearing.

### 7.5 Relief

Per exchange, each fighter has their own relief: `BOUT_RELEASE`, `LANDED_RELEASE` for what they
landed, and the `HURT_RELIEF` multiplier for their own injury. Added to it:

**Seeing somebody in the fight hurt**: on each injury anybody in the fight suffers, everybody else in
it gets `WITNESSED[mode]` × (`WITNESS_BASE` + their grudge against the one hurt) × full patience. It
stacks with the rest; it does not replace landing, which is a different satisfaction. Inflicting it
yourself counts for both.

A start, as napkin figures. Unhurt, a fighter's own relief is about 0.075 of full an exchange, so
eight exchanges from nothing to sated:

| Injury | `WITNESSED` | Grudge 0 (base 0.2) | Grudge 0.5 | Grudge 0.75 |
|---|---|---|---|---|
| Minor | 0.025 | 0.005 | 0.018 | 0.024 |
| Significant | 0.05 | 0.01 | 0.035 | 0.048 |
| Severe | 0.15 | 0.03 | 0.105 | 0.14 |
| Mortal | 0.30 | 0.06 | 0.21 | 0.29 |

So watching a hated man go from minor to severe is worth about two exchanges of your own, a
stranger's knock is next to nothing, and a huge brawl does not fizzle the moment the first two people
lose a tooth: the knocks are cheap and the carrying-out is what tells.
- **Converting rather than stacking** would mean taking `LANDED_RELEASE` down to pay for it. Don't:
  landing is what lets two people who never injure each other wear themselves out.
- **Should violence count in the witness weight?** Proposed no: an orc's love of a scrap keeps him in
  it (§7.2), but a stranger's broken finger is not a satisfaction to him. That makes violent races
  slower to sate, which is in character.

**Numbers to check with the tools, not by argument:** how long a 12-person mutual scrum lasts, and
how much `WITNESSED` shortens it. The request is that it still happens with a poor boss.

### 7.6 Injuries in the fight

What the ladder already does, for a human at each tier:

| Tier | Strike | Defence | In the fight? |
|---|---|---|---|
| Minor | ~0.9 | ~0.92 | Yes |
| Significant | ~0.71 | ~0.70 | Yes |
| Severe | 0 | — | Stood down: neither fights nor can be picked |
| Mortal | 0 | — | Stood down |

- **"Seriously wounded fight on, worse" is already true of `significant`.** Its derates of agility,
  strength, dexterity and intelligence reach strike and defence through swing, precision, wits and
  nimbleness. At three attackers a significantly hurt man defends at 0.47.
- **`combat_prowess` is derated by nothing.** A broken arm leaves the prowess untouched. Worth adding
  to the `significant` derates (0.8?) if fighting hurt should cost more than working hurt.
- **The real gap is `severe`.** Severe stands somebody down, so they leave the fight and nobody can
  pick them, and a beating ends at severe. **A gang beating therefore carries people out faster, but
  it does not kill more**, unless a single blow bites past `MORTAL_BITE` (in practice, a drawn
  weapon). If the gang beating is meant to be deadlier, it needs one of:
  - (a) **Putting the boot in.** A downed fighter stays pickable by anybody willing to kill them
    (`ceiling` at least `LETHAL` towards them), and defends at nothing. Only hatred kills somebody
    on the ground; a scrap does not.
  - (b) **Severe stays in the fight**, as a figure who can still be hit but not swing. Simpler, and
    lethal for everybody: a casual brawl kicks people to death.
  - (c) **Leave it**: gang beatings carry out; weapons kill.

  **Chosen: (a), putting the boot in**, on a dial of its own, `KICKING` (§7.14). A fighter carried
  out stays in the fight as somebody who can be picked, by those who hate them enough to kick them
  and by nobody else, and defends at nothing; they throw no blows and are neither willing nor wanted
  for the ending rule.

### 7.7 Joining

The pick that starts a fight no longer passes over somebody already in one. Whoever runs out of
patience picks, by grudge + irritation, from everybody present:

- **Their pick is free:** they start a new fight with them, as today.
- **Their pick is in a fight:** they join it, if they are willing to brawl that person (`ceiling` at
  least `BRAWL_HARM`). The one they went for holds the onset grievance against them, as a brawl's
  target does now.
- **Their pick is in a fight, and they would only row:** they **heckle from the sidelines**. It is a
  row on their side only: they stop work for `ROW_S` and the one they picked takes the row's
  grievance, but stays in the fight and is not stopped by it. A heckler can be drawn into a row of
  their own. A neutral human is never dragged into a fist fight this way.
- **Their pick is in a row:** a brawl on somebody rowing ends the row for them and starts a fight.

**Two fights in one room stay two fights.** Joining is what merges them: whoever joins goes into the
fight of the person they picked. One fight per room would make every scuffle in a crowded pit one
riot, and turn the uprising's dwarves on the orc in the corner who has nothing to do with it.

**The runaway to watch: rumpus.** `RUMPUS` speeds everybody's spend by the number of brawls in the
room. With melees, counted per fight it undercounts a scrum of twelve; counted per fighter it is a
feedback loop, where a bigger scrum makes the room snap faster and the scrum grows. **Recommendation:
by the square root of half the number fighting** (two fighters 1, eight 2, eighteen 3), so a scrum
is worse than a scuffle and still saturates.

### 7.8 Everything else it touches

- **Weapons.** Escalation is read against whoever they picked this exchange. **Answering** fires if
  anybody in the fight who holds hostility against them had a weapon out at the start of the
  exchange, not only "the other one".
- **The boss.** A boss overseeing the place may pull **one** fighter out each exchange, on their avert
  die against the boss's authority, with the averted release and, by intimidation, the grudge
  against the boss. A big scrum takes a good boss many exchanges and outlasts a poor one, which is
  the request. A boss in the fight oversees nothing, so the uprising goes unchecked.
- **Wound grudges** are owed against whoever dealt the blow that carried them out, so `owed` becomes
  a map by attacker, formed when that person's fight ends.
- **Fatigue, orders and work** are unchanged: a fighter mans nothing, does not walk, and tires.
- **Events.** A `quarrel` with `mode: :joined` when somebody joins; `brawl` and `armed` as now. A
  whole fight's summary is the deferred brawl report, which a melee makes more worth having.

### 7.9 Scenarios to walk through, and check with the tools

| Scenario | What should happen | What would be wrong |
|---|---|---|
| Four dwarves hate a goblin boss | They join one by one, hit only him (no dwarf hates a dwarf), he goes down, nobody is willing, it ends | The dwarves turning on each other |
| Two goblins on a dwarf | Mostly at the dwarf, now and then at each other; once he is down, at each other until sated | Goblins ignoring the dwarf to fight each other from the start |
| Five who all hate each other | A shifting melee; everybody's defence falls as the hits spread; ends by relief and attrition | Ending as soon as the first one goes down |
| 100 % snaps at 99 % | Goes on until the 99 % is sated | Ending when the starter is |
| Two who cannot hurt each other | Ends by `BOUT_RELEASE` after a few exchanges, as now | Lasting forever |
| A calm man set upon | Hits back while wanted, then steps out as soon as nobody wants him | Joining the fight's other quarrels |
| Twelve who hate each other, poor boss | A large scrap, for a while, many carried out | Never happening, or never ending |
| A brawl in a room of neutral humans | They row each other and heckle the fighters; nobody joins it | Neutral bystanders pulled into a fist fight |
| A hated boss carried out by the uprising | Those willing to kill him put the boot in; the rest stop | The whole uprising kicking him, or nobody |

### 7.10 Alternatives considered

- **Sides.** Grouping people into factions by who they hate, and fighting faction against faction.
  Rejected: a faction is a summary of the grudges, and the weighted pick already acts on the
  grudges themselves. Sides would also need breaking when allies fall out, which is §7.2 again.
- **Pairs that overlap.** Keeping the pairwise fight and letting a person be in several. Rejected:
  the defence penalty, the clock, the ending and the boss all need to know who is in the fight
  together, which a set of overlapping pairs does not record.
- **A shared fight record at the top of the state** (`state[:melees]`). Viable. **Recommendation: per
  person, as now**: each fighter's `fight` names the fight (`melee:`, the founder's seat and the tick
  it began, so it is unique) and carries its clock. The lowest seat id still able runs the exchange.
  It keeps one place to normalise on restore, and nothing new at the top of the state.

### 7.11 Determinism and state

- Every pick, willingness and count is read from the state the phase begins with; blows and
  injuries are applied in sorted attacker order. **Somebody downed early in an exchange still takes
  the rest of that exchange's blows and still throws their own**, because everybody chose at once.
  That is simultaneity, not an order-dependence, and it is part of why a ring is deadly.
- No new die. The `target:` die that picks a fight's first target is free inside a fight, since
  patience does not run while fighting.
- **Restore** normalises `fight[:melee]` and every key of `owed` as symbols, beside `with:` today.

### 7.12 Review decisions

1. **`FOCUS` 2.5** to start, and a first target of tuning: the figure is arbitrary.
2. **The ganged penalty is a divisor, by count.**
3. **Each attack rolls its own defence**, from the defender's and the attacker's dice summed.
4. **Witness relief stacks, without violence**, at half the proposed minor and significant figures
   and 0.15 for severe, so a genuinely huge brawl does not fizzle the moment somebody loses a tooth
   (§7.5).
5. **Putting the boot in** (§7.6 (a)). Whether `significant` should also derate `combat_prowess`
   was not decided, and stays a tuning question.
6. **The row-only heckle from the sidelines** instead of re-picking (§7.7): they row at the
   fighter, the fighter takes the row's grievance and fights on, and the heckler can be drawn into
   rows of their own.
7. **Rumpus by the square root of half those fighting**, and expected to be the biggest lever on
   how fights spread.
8. **The boss pulls out one fighter an exchange.**

### 7.14 Settled while building

- **Kicking is not killing.** The first cut let a downed fighter be picked by anybody willing to
  kill them (`ceiling` at `LETHAL`) and counted the bites on them until `MORTAL_BITE` of them killed.
  Both went. Stacking blows on a severe injury into a mortal one was undesirable, and wanting a few
  cheap shots at a man on the ground is not wanting him dead; an attacker that hateful is also likely
  armed, which would make every kicking a murder. **`KICKING`, 0.6 of `LETHAL`**, is the threshold
  for picking the downed.
- **Kicks did nothing at first.** A blow on somebody already at `severe` ground a resilience
  already at nothing and proposed `severe` again, which `Severity.escalate` will not announce. That
  was the injury model's flaw — **a second injury of the same tier or lower never stacked** — and
  wounds fixed it ([`wounds.md`](wounds.md)): every kick wounds and comes off the pool, and far
  enough past empty kills.
- **Willingness is checked every tick**, not only when an exchange falls due, so a fight ends the
  moment nobody in it wants it.
- **Rows run on each person's own clock** (`fight: { with:, clock_s: }`), which is what makes a heckle
  one row instead of a special case.
- **A brawl's state is per person**: `fight: { melee:, clock_s:, owed: { attacker => grudge }, armed: }`.
  The melee is named for its founder and the tick it began (`:"a@1204"`).

### 7.15 The first melee measurements

From `script/tuning/crowds.rb`, three seeds of an hour each:

| Room | Brawls / joined an hour | Largest fight | Half down |
|---|---|---|---|
| 4 dwarves, a goblin boss | 1.7 / 0 | 2 | never |
| 5 of the feuding races | 4.7 / 0 | 2 | 16 min |
| 12 of the feuding races, no boss | 11.7 / 0.7 | 4 | 9 min |
| 12 of the feuding races, Throg | 26 / 0.3 | 3 | 33 min |
| 12 of the feuding races, Arunessa | 26 / 0 | 2 | never |
| 16 of the gang | 16 / 0.3 | 3 | 30 min (25 before the melee) |

`RUMPUS` raised to 3 and to 8 moves joining to 2–4 an hour and the largest fight to 4, no more.

**Melees barely form, and rumpus is not the lever for it.** Joining needs somebody's patience to
run out *during* a fight, which lasts half a minute; patience runs out on independent clocks
minutes apart. Shortening everybody's fuse while a fight lasts hardly ever makes another one
burn down in time. The uprising of §7.9 comes one dwarf at a time: the boss is set upon, carried
out, and the others have nothing left to rise against.

**Candidates for the next pass, for review:**
- **Opportunity.** Somebody you resent being in a fight wears your patience against them far
  faster: the man you hate is busy, his back is turned. Targeted: only those holding a grudge
  against a fighter are pulled in, so a quiet room stays quiet and the uprising rises.
- **Rumpus by grudge.** The same, broader: a fight speeds the patience of those who resent anybody
  in it, not of everybody in the room.
- **Longer fights.** Less relief per exchange, so fights last long enough to be joined. It also
  makes every fight bloodier, which the carry-out rate does not need.

When the target is the busy one, the pick now goes: averted by the boss 36 %, a new brawl with
somebody else 28 %, a heckle 21 %, a row 12 %, joined 3 %.

### 7.13 Measuring it

The crowd tool gains melee scenarios beside the rooms it has: four dwarves and a goblin boss, two
goblins and a dwarf, five mutual haters, twelve mutual haters with each boss, and the existing gang
rooms. Its report gains each fight's size (largest and mean), its length, the fighters each
person-on-person blow went to (a check that no ally is hit where §7.2 says none should be), and deaths
by fists, by weapons and on the ground. The brawl matrix stays the one-on-one reference.

