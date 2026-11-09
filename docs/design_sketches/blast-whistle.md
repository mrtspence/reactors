# The blast whistle (for review)

> Input to a decision, not a description of the system. The second of three units decided in the
> open-pit lookover (2026-11-01): lighting (built), the blast whistle, then the UI overhaul. This
> draft covers the whistle only.

## 1. What there is now

- **A shot is held for its face's fire lever** (`Nodes::ShotHole#fire_control`): charged, it waits
  at "charged — ready to fire" until the lever says fire; left at fire, it goes as soon as it is
  charged.
- **Flyrock is perils of places** for the two seconds after a shot (`:flying`): very hard at the
  face fired at, across the pit less, at the bank, the dump and the dams least. It reaches whoever
  is in those places, posted or resting — the huts are in their benches' places.
- **So clearing the range is re-posting everybody**: send each gang out of reach, wait for them to
  walk, fire, and send each back. With twenty or forty people that is the player's whole minute,
  and it is click-work rather than a decision.

## 2. The period [gk; to check before figures are fixed]

- Before a blast the shotfirer or the powder foreman **gave warning** — a whistle, a horn, a bugle,
  a bell, a red flag, a shout of "Fire!" — and the men **took cover**: behind the shovel or the
  cars, in a cutting's side, or in **blast shelters** built for it (timber or steel huts, the
  "bomb-proofs" of railway and canal work). Sentries kept the approaches.
- **A fixed interval** passed between the warning and the shot, so nobody could be caught by
  surprise, and an **all clear** was given when the shot was down and the holes looked at.
- The cost was the stoppage: every gang within reach stood idle through the warning and the shot,
  which is why shots were fired at set times — the dinner hour, the change of shift.

## 3. The proposal

### 3.1 Taking cover is a state of a person, as a fight is

**Proposed: a warning makes everybody within its reach take cover where they are.**

- **Under cover they man nothing.** `Tick#crews` leaves them out, as it leaves out a fighter, so
  every post in reach stops for as long as the warning lasts.
- **Under cover, flyrock reaches them far less.** A person's `cover` scales the perils that are
  `sheltered:` (flyrock): crouched behind what is there, about half; in a blast shelter, nearly
  none.
- **When the all clear goes they are back at their posts** — no walking, no re-posting.
- **What reaches them is a place list** on the warning, as flyrock's is: the face, across the pit,
  and the far places by tier.

**Alternatives:**

- **(a) A recall order**: everybody in reach walks out of range and back to their post after.
  - *For*: the walk is real time lost, and a gang far from shelter loses more.
  - *Against*: it needs a "come back to where you were" memory per person, which nothing has, and
    it puts the whole pit on the ramp road at once. It is a general evacuation mechanic — worth
    having for the colliery's gas and water one day — rather than a blasting one.
- **(b) Nothing generic**: the shot hole simply makes its own perils weaker while its gang has
  shouted.
  - *For*: no new state.
  - *Against*: nobody stops work, so a warning would cost nothing and protect everybody — a free
    safety.

**Recommended: take cover in place.** It is what the period did, its cost is the stoppage the
period paid, and it is one person-state shaped like `fighting`, which the tick already knows how
to leave out.

### 3.2 The whistle is the powder gang's, and the shot waits on it

With a warning fitted, **the shot's sequence becomes**:

1. The hole is charged and waits ("charged — ready to fire"), as now.
2. The fire lever goes to fire: the powder gang **sounds the warning**, and everybody in its reach
   takes cover.
3. After the warning's interval (`warning_s`, the tier's), **the shot fires**.
4. After the flyrock is down, **the all clear**, and everybody is back at work.

**With no warning fitted, nothing changes**: the shot fires on the lever and the player clears
the range by hand. A warning is a purchase that turns click-work into one lever.

### 3.3 Not everybody heeds it

**Proposed: somebody may fail to take cover**, so the warning is a large safety and not a perfect
one:
- **Who**: a die per person per warning, thrown in phase 0, against `Minion#misjudges` (the
  boneheaded and the distracted) — the same reading that decides a misjudged misfire.
- **What happens**: they keep working through the shot, exposed as today.
- **An opening for a feud** (`Animosity::Opening`): somebody who hates a man can keep him from
  cover, as the shotfirer can leave a charge live.

*Against*: a die per person per warning is a new draw, and the draws are fixed in count — so it
has to be thrown for everybody every tick, used or not, as `draw_fates` does.

### 3.4 The tiers

**A `blast_warning` slot**, empty to start (today's behaviour):

| Tier | Reaches | Interval | Note |
|---|---|---|---|
| **A shout** | the face fired at | 15 s | the powder gang's own voice; across the pit is still at risk |
| **A horn** | the whole pit — both benches, the haul road | 30 s | the usual warning |
| **Horn and sentries** | the pit and the bank, dump and dams | 45 s | a sentry post on the approaches; unmanned, as a horn |

**A `blast_shelters` slot**, empty to start:

| Tier | Cover | Note |
|---|---|---|
| none | crouched behind what is there, about half | |
| **Timber shelters** at each bench | nearly all, for the seats it has | more people than seats crouch |
| **Steel shelters** | all, for more seats | |

### 3.5 The panel

- **Each face's shot board gains** "warning sounded — taking cover" and "all clear".
- **The crew list shows** who is under cover.

## 4. Specs (relational)

- **The sequence**: with a warning fitted the shot fires `warning_s` after the lever, not on it;
  without one, on it.
- **Cover**: everybody in the warning's reach stops work for the warning and the shot and is back
  at their post after; nobody outside its reach stops.
- **Protection**: flyrock reaches somebody under cover less than somebody working, and a shelter
  less again; a shout leaves across the pit exposed where a horn does not.
- **Heeding**: across many warnings a boneheaded hand fails to take cover more often than a sound
  one; somebody who fails keeps working.
- **The books**: unchanged physics; a snapshot replays through a warning.

## 5. Questions

1. **Take cover in place** (a person-state that mans nothing, as a fight), rather than a recall
   order or no stoppage at all?
2. **The shot waits on the warning**: the fire lever sounds it and the shot follows after the
   tier's interval?
3. **Not everybody heeds it**, by a phase-0 die against `misjudges` — and a feud's opening to keep
   somebody from cover?
4. **The three warning tiers** (shout, horn, horn and sentries) and **the shelters as their own
   slot**?
5. **Engine crews** (driver, fireman) stay at their posts in the cab through a warning, the cab
   being their cover? Their outdoor crews — pitmen, craneman, dumpmen — take cover with everybody.

## 6. Review decisions (2026-11-02)

1. **Cover in place**: a lot cleaner.
2. **The shot waits on the warning.**
3. **Not everybody heeds it**, and the feud's opening.
4. **The three warning tiers, and the shelters as their own slot.**
5. **Engine crews stay at their posts, and the cab is its own blueprint with tiers**: an open
   platform, as the earliest engines had, marginally better than crouching in a bare pit; a wooden
   cab, as a timber shelter; a steel cab, as a steel shelter.

## 7. Settled while building

- **Cover is generic** (`Cover`, `Nodes::Shelter`, `sheltered:` on a peril, `take_cover(state)` on
  a node). The shot hole is the first caller; the tick knows nothing of shots.
- **A person decides once a call** (`state[:cover]`: the share they are under, 0.0 for not
  heeding), from a die drawn every tick from their own cover stream (`Cover.stream`), so adding it
  moved none of their other draws. The decision is phase 6c′, from last tick's calls; under cover
  they man nothing and do not walk from the next tick. **A snapshot taken before this change does
  not restore**: its rng table has no cover streams.
- **The call holds through the tick the shot fires** (`firing`), or the decisions lapsed for a
  tick and were thrown again for the flyrock. It ends when the flyrock is down, and the cover with
  it.
- **The kinds of cover** are `Nodes::Shelter`'s, shared by a hut and a cab: crouching 0.5, an open
  platform 0.6, timber 0.9, steel 0.98. Timber shelters seat six at each bench, steel ten.
- **The opening is `fired_unwarned`** on the powder gang's post, an `:unwarned` mishap on the hole:
  its next shot fires on the lever with no warning and calls nobody.
- **The sentries are a post at bank** (two), node-less as the quarters are; the horn and sentries'
  call reaches the bank, the dump, the dams and the kiln only while somebody is posted there.
- **In a horn's half-minute on the rig**, nine of the eleven at both faces took cover and two kept
  working; six of the stripping bench's seven had a timber shelter's seat.
