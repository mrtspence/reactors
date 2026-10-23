# Wounds: injuries that stack, by kind and by cause

**Status: built (§11 for what changed in the building). Tag effects come next.**

A person today has one injury, a tier on a ladder, and one pool of resilience it is read from. This
sketch replaces that with **wounds**: each harm leaves wounds of the kinds it does, each wound has a
tier and a name, wounds stack, and what a person can still do is what their wounds leave them.

It follows from the melee pass ([`animosity-and-distraction.md`](animosity-and-distraction.md) §7.14),
which found that kicking somebody already carried out does nothing, and why.

## 1. What exists

| Piece | What it does today |
|---|---|
| `Injury.check(minion, state, hazard)` | One bite: `severity` less one resistance (toughness, plus every tag's `_resistance`, plus `hazard_sense`, less `clumsy`). Grinds `resilience`, proposes a tier |
| `Injury.tier` | `mortal` if the one bite is past `MORTAL_BITE`; `severe` if resilience is gone; `significant` below `WALKING_WOUNDED` of what they started with; `minor` below `KNOCKED` |
| `Severity.escalate` | Shared with parts: the tier only ever worsens, and a transition is announced once |
| `state[:injury]` | The one tier. `stood_down` at severe and mortal; `lasting` at mortal, which the delivery tier's injury list records |
| `Injury::MODES[tier][:derates]` | A stat multiplier per tier, read by `Minion#effective` through `Injury.derating` |
| `Scorch`, `Chill` | Grind the same resilience, and count a dwell past zero to reach `mortal` |
| `Breath` | Its own `asphyxia` counter: collapse is `severe`, too long collapsed is `mortal` |
| Hazards | `{ severity:, tags: }`, from parts' `endangers:` and failure hazards, perils, the hoist's boarding hazard, a brawl's blow, a shove. `tags` mixes **causes** (`rockfall`, `fall`, `afterdamp`, `heat`) and **what the body suffers** (`crush`, `impact`, `burn`, `scald`, `puncture`, `blast`) |

## 2. What is wrong with it

1. **Nothing short of worse stacks.** A second harm proposes a tier no worse than the first and
   `Severity.escalate` says nothing. Somebody whose leg was broken in a haulage accident works on,
   immune to anything but a single catastrophic bite. A man carried out can be kicked for ever.
2. **Every harm is the same harm.** A crushed foot and a scalded arm are the same `significant`,
   with the same derates. The causes are already tagged; nothing reads them past resistance.
3. **A multi-kind harm is one bite.** Red-hot scrap falling on somebody is `burn crush`, resisted
   once by the sum of both resistances: a helmet's crush protection reduces the burn.
4. **The ladder is crowded.** With one injury, severe and mortal must come early or nothing ever
   happens, which leaves no room for somebody to wear down over a shift or a fight.

## 3. The design

### 3.1 Two words: a cause and a kind

- **A kind** is what the body suffers: `impact`, `crush`, `puncture`, `cut`, `burn`, `scald`,
  `blast`, and the continuous ones, `heat`, `cold` and `breath`. **A wound is always of a kind.**
- **A cause** is what did it: `rockfall`, `fall`, `tub`, `brawl`, `afterdamp`, a part. A cause selects
  protection (a helmet against `rockfall`, a belt against `fall`) and is what the feed says. It is
  never a wound.

A hazard declares both, and a severity **per kind**:

```ruby
{ wounds: { burn: 0.9, crush: 1.8 }, causes: %i[rockfall], severity_scale: … }
```

**Every kind is evaluated on its own.** Each has its own bite: its severity, less toughness, less
that kind's `_resistance`, less any `_resistance` of the hazard's causes, plus `clumsy`, less
`hazard_sense`. The helmet turns the crush and leaves the burn.

**Nothing is untyped.** A hazard with no `wounds:`, a kind nobody has declared, or a tag that is
neither a kind nor a known cause raises when the operation is built, not when somebody is hurt.
That is the sweep (§4): every hazard in the game says what it does, once.

### 3.2 A wound

```ruby
{ kind: :crush, depth: 1.9, tier: :severe, id: :broken_spine, cause: :rockfall, by: :roof, tick: 1204 }
```

- **Its tier is the size of its own bite, its `depth`**, in bands: under a first band a bite costs
  resilience and leaves nothing to show; then `minor`, `significant`, `severe`, and `mortal`. The
  bands are absolute, like `MORTAL_BITE` today, since resistance has already accounted for the body.
  The depth is kept on the wound, because healing (§3.8) wears it down and the tier is read from
  what is left.
- **Its name and effects come from a catalogue** (§3.4), by kind and tier: a severe crush is a
  broken spine, a minor burn a scald.
- **Wounds stack.** A person holds a list of them, and every one counts.

### 3.3 The pool, and what a body can take

**Resilience stays, as how much a body can take all told.** Every bite of every kind comes off it:

- **Run out, and they collapse**: stood down, as `severe` is today, whatever their wounds. This is
  how a pile of small injuries takes somebody out of a shift or a fight. A boot on a man already
  down now does something.
- **Far enough past empty, and they die**: a share of what they started with below zero. A beating
  that goes on is a killing; one that stops, with the victim sated over, is not.
- **The pool no longer decides `minor` and `significant`.** Wounds do. The pool decides only
  collapse and death by attrition, so the two never argue.

The person's **condition** is then derived, never stored separately:

| Condition | When |
|---|---|
| On their feet | No wound severe or worse, and the pool not run out |
| Carried out (`severe`) | Any severe wound, or the pool run out |
| Dying (`mortal`) | Any mortal wound, or the pool far past empty |

`state[:injury]` stays, as this summary, so everything that reads it now (standing down, the feed,
the injury list, the console, `HURT_RELIEF`) keeps working unchanged.

### 3.4 The catalogue

A wound type per kind and tier, each a name, a description, and what it does:

| Kind | Tier | Wound | Does |
|---|---|---|---|
| `crush` | minor | Crushed fingers | Dexterity a little |
| `crush` | significant | Broken leg | Agility hard, strength some |
| `crush` | severe | Broken spine | Strength and agility to almost nothing |
| `burn` | minor | Scalded skin | Intelligence a little: the pain steals their focus |
| `burn` | significant | Burned hands | Dexterity hard |
| `impact` | minor | A knocked-out tooth | Charisma a little |
| `impact` | significant | Concussion | Intelligence and dexterity |
| `puncture` | significant | A stab in the gut | Endurance and strength |
| … | | | |

- **Effects are stat multipliers, as today's derates are**, and several wounds' multiply together.
  Two broken fingers are worse than one.
- **The catalogue is content**: `content/wounds/*.yml`, data rather than code, validated at boot and
  read through the registry like the races are. `Injury.check` takes it from the tick's context,
  which already carries the content, so nothing reaches for it mid-tick.
- **Three variants per kind and tier**, each with a weight, picked by a new phase-0 die per person
  (`wound:`, drawn unconditionally in `draw_fates` like every other). A severe crush is a broken
  spine, a crushed pelvis or a shattered leg. The first file ships with examples, to be rewritten.
- **The catalogue is complete or the game does not boot**: every kind has every tier and every tier
  three variants, each naming only real stats, checked at load, so a wound never falls back to a
  generic one.
- **A wound may also reduce a tag**: the scald that takes the edge off `focused`. Tags are read off
  the minion without state today, so this needs a state-aware tag read. **It follows straight after
  the first pass**, and is named as a seam in it.

```yaml
# content/wounds/crush.yml — the shape, with examples to be rewritten
crush:
  severe:
    broken_spine:
      label: Broken spine
      weight: 1
      derates: { strength: 0.2, agility: 0.1 }
    crushed_pelvis:
      label: Crushed pelvis
      weight: 1
      derates: { agility: 0.15, strength: 0.4 }
    shattered_leg:
      label: Shattered leg
      weight: 1
      derates: { agility: 0.2, strength: 0.6 }
```

### 3.5 What happens across a harm

For each kind the hazard declares, in sorted kind order:

1. The bite, resisted by that kind's resistance and the causes' (§3.1).
2. The pool drops by it.
3. If the bite is past the first band, a wound of that tier is added.
4. The condition is re-derived, and **one `minion_hurt` reports the harm, with every wound it left
   past the first band**, each with its kind, tier and name: nobody's broken leg goes unmentioned
   because they were also badly burned. Its `mode:` is the worst of them (or the collapse), so a
   consumer keyed on `mode` today still reads it. **A collapse or a death from the pool alone is
   reported once**, with the cause of the bite that did it. A breakdown of every wound somebody
   carries belongs to a minion status screen, much later.

### 3.6 The continuous harms

Heat, cold and bad air harm a little every tick. A wound per tick would bury the feed, so **a
continuous harm deepens one standing wound of its kind** instead of adding new ones: heat
exhaustion, then heat stroke; chilblains, then frostbite. The dwell counters `Scorch`, `Chill` and
`Breath` keep today are exactly a dose; the wound's tier is read from it, and the pool still drops
by what it grinds. Their own death rules stay theirs.

### 3.7 Moving the ladder

With small injuries stacking, the large ones can be rarer. **`severe` and `mortal` bands move up**,
and the pool's attrition does the work in between: a long shift or a long fight wears a man down
through knocks and significant wounds before anything carries him out. The figures are a tuning
pass with the tools, not a decision here.

### 3.8 Healing between matches

**Wounds outlive the match and heal by a flat depth per match**: `HEAL_PER_MATCH`, 0.5 to start, off
every wound, and the tier is read again from what is left. A knock is gone by the next match; a
severe wound comes back as a significant one; a mortal one takes a few matches to become anything
but. **Gone below the first band, a wound is healed.**

**Two tags move the rate**, added straight to it:

| Tag | Example | Heals per match |
|---|---|---|
| none | | 0.5 |
| `regeneration` | 0.6 on a troll | 1.1 — even a devastating wound is soon nothing |
| `slow_healer` | 0.1 on an elf | 0.4 — a fine worker who mends slowly |

`regeneration` waits for its first race (a troll). `slow_healer` is a balancing lever for the
elves, who are strong across the board, and **ships on them at 0.1**. Both are named for exactly
what they do, as a tag should be.

**This replaces the injury list's dice.** Today a mortal injury keeps somebody out for one to three
matches, drawn from the run. With wounds healing, how long somebody is out is how long their worst
wound takes to heal below the tier that stands them down, which is deterministic and readable:
shown on the roster as "back in two matches". The standin carries nothing between matches, as now.

## 4. The sweep

Every hazard is rewritten from `{ severity:, tags: }` to `{ wounds:, causes: }`:

```sh
grep -rn "tags: %i\[" lib/reactor_sim/operations lib/reactor_sim/nodes lib/reactor_sim/peril.rb
```

| Today's tag | Becomes |
|---|---|
| `crush`, `impact`, `puncture`, `burn`, `scald`, `blast` | A kind, with its share of the severity |
| `rockfall`, `fall`, `afterdamp`, `heat` | A cause |
| A weapon's `wounds: %i[puncture impact]` | Shares of the blow: a pick `{ puncture: 0.6, impact: 0.4 }`, a knife `{ cut: 0.7, puncture: 0.3 }` |

**A single severity becomes shares that sum to it**, so a converted hazard does as much total harm
as before. Some will want rebalancing once each kind is resisted on its own; the sweep converts and
the tools tell.

The kit's `_resistance` tags are read by kind or by cause, as they are named now; `firedamp_resistance`
is the one to check, since firedamp is neither.

## 5. What it touches

- **The melee.** Kicking now matters (§3.3). A string of small wounds raises `HURT_RELIEF` and the
  witnesses' `WITNESSED` relief, so an attacker can be sated by a beating that never escalated,
  which is the point. Brawl damage becomes shares of kinds by the weapon.
- **Fatigue and capability** read derates through `Minion#effective`, unchanged in shape.
- **Rescue** keys on standing down, unchanged.
- **The delivery tier** keeps wounds between matches, as it keeps grudges: a `WoundList` beside
  `GrudgeList` writes each wound from `minion_hurt`, idempotent per run and tick; match start heals
  them (§3.8); `DevMatch` hands each crewed machine its people's wounds in `options:`, and the sim
  folds them into each person's starting state. `MinionCondition` and its one-to-three-match dice
  give way to it (§10).
- **The console** names the wounds a harm left, amber or red as now.
- **Events.** One `minion_hurt` per harm, listing its wounds. A melee can deal a few a minute; that
  is a discrete happening, not a per-tick quantity, so it is an event.

## 6. Determinism and state

- **No new entropy on the tick path.** The variant die, when it comes, is drawn in phase 0 with the
  rest. Everything else is a comparison, as the Danger Check is today.
- `state[:wounds]` is a list of hashes whose `kind`, `tier`, `id` and `cause` are symbols held as
  values: **normalised in `Operation#restore`**, beside `injury`. `injury` stays and is re-derived.
- Kinds are evaluated in sorted order, so a multi-kind harm cannot depend on the order a hazard was
  written in.

## 7. Specs (relational)

- A second harm of a lesser tier still wounds, and wounds stack.
- Two kinds in one harm are resisted separately: gear against one leaves the other.
- A run-out pool stands somebody down whatever their wounds; far past it, they die.
- Kicking somebody carried out wears them towards death; stopping spares them.
- A severe crush cripples strength and agility more than a minor burn does anything.
- Every kind has every tier and three variants in the catalogue, naming only real stats; a hazard
  naming an unknown kind or no kind is refused at build.
- The variant die picks among a tier's variants by weight, and the same seed picks the same one.
- A continuous harm deepens one wound and does not add one a tick.
- One harm's event names every wound it left.
- A wound heals by the flat rate a match, faster with `regeneration`, slower with
  `slow_healer`; a severe one comes back lesser, a knock not at all.
- Somebody is unavailable while any wound would stand them down, and back once it has healed below
  that; a carried wound lowers the next match's starting resilience, never below the floor.
- A snapshot taken with wounds replays bit for bit, every wound's symbols intact.
- Web: wounds are written once per run and tick however often the event is delivered, and healed
  once per match start.

## 8. Docs touched

`invariants.md` (none expected; say so), `tick.md` (6b, 6c, 6d′), `lib/reactor_sim/CLAUDE.md`
(the injury paragraphs), `nodes.md` (`endangers:` shape), `build-an-operation.md` and
`operations/CLAUDE.md` (hazard declarations), `add-content.md` and `content/CLAUDE.md` (kit
resistances), `spec/CLAUDE.md`, `current_progress.md`, and `minions.md` §5 as history.

## 9. Review decisions

1. **The ten kinds as proposed.** More when content needs them, not before.
2. **Bite bands are absolute.**
3. **The pool as proposed**: collapse at empty, death a share past it.
4. **The catalogue is content YAML** (§3.4): it is data.
5. **Three variants per kind and tier**, on a phase-0 `wound:` die, shipped with examples to rewrite.
6. **Tag effects straight after the first pass.**
7. **Wounds heal between matches** by a flat depth, moved by `regeneration` and
   `slow_healer` (§3.8).
8. **A harm's event names every wound it left** past the first band (§3.5).

## 10. Decisions on what the review raised

1. **A carried wound lowers the next match's starting resilience** by its depth, never below a
   floor, so a chain of bad shifts tells.
2. **Somebody is unavailable while any wound would stand them down** (severe or worse), and
   `MinionCondition`'s one-to-three-match dice retire in favour of healing.
3. **`slow_healer` 0.1 ships on the elves.** Named for what it does rather than
   `weak_constitution`, which says nothing specific.

## 11. Settled while building

- **The pool doubled** (`RESILIENCE_SPREAD` 1.7–2.7, times toughness). At its old size, about 1.1
  for a human, the pool was smaller than a severe wound bites (1.6), so every severe wound also
  killed by attrition and the bands meant nothing. Now a body takes more than one bad wound before
  it collapses. `DEATH_SHARE` is 0.5 past empty.
- **The body's share is apportioned.** Toughness, `hazard_sense` and `clumsy` are taken from each
  kind by its share of the harm, and so is protection against the cause; protection against a kind
  meets it whole. So somebody with no kit takes exactly the bite a single kind would have dealt,
  and a converted hazard does as much harm bare as it did before.
- **Heat and cold are calibrated to the wound.** Carried out is their standing wound reaching
  severe, so their reference rates grind `BANDS[:severe]` in the reference time: a fit hand is
  still carried off in ten seconds at 1,300 K.
- **A continuous harm keeps a dose** (`state[:doses]`), so a little heat for a long time adds up
  even while it is too little to be a wound.
- **The variant die has a stream of its own** (`Injury.stream`), so adding it moved none of the dice
  already thrown, and no seeded spec changed for it. Several wounds in a tick step it by the golden
  ratio.
- **A wound knows itself across the boundary**: its place among the person's this match (`slot`),
  and for one carried in, the delivery tier's row (`ref`). A deepening heat wound updates its row.
- **Wounds heal before the next match's command is built**, so the match after an injury is the one
  a severe wound comes back to lesser. The injury list built its command first; with healing that
  would have left every wound a match late.
- **Healing never stops altogether** (`LEAST_HEAL`), so nobody is out for ever whatever their tags.
- **`MORTAL_BITE` is now the mortal band, 3.0** (2.5 before), and `Animosity::LETHAL` reads it, so
  the willingness to kill, escalation and `KICKING` all moved up with it.
- **The injury list is gone**: `MinionCondition`, `InjuryList` and the `minion_conditions` table, for
  `Wound`, `WoundList` and the `wounds` table.
- **The shipped catalogue is examples**, to be rewritten; the specs run on a catalogue of their own.
