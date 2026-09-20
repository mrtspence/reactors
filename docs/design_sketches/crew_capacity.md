# Crew capacity: more jobs than hands

> **Status: draft for review.** Nothing here is built.
>
> Prompted by a defect found while building the oil round: adding a crew role to a station
> silently deleted the mechanic it was meant to create. The fix for that was local. The reason it
> was possible is not.

---

## 1. The defect, and why it is structural

`Crew.normalise` fills **every** role the machine declares, defaulting to `STANDIN`:

```ruby
def normalise(crew, roles:)
  roles.to_h do |role|
    given = (crew[role.id] || {}).to_h { |k, v| [ k.to_sym, v ] }
    [ role.id, normalise_posting(given).freeze ]
  end.freeze
end
```

So **roles and people are 1:1, and every role is always filled.** A machine that declares three
jobs gets three bodies whether the player has hired anybody or not. Adding `:oiling` as a role
meant somebody was permanently on the oil round for free, and the measurement showed the
"nobody oiling" run still filling its bearings.

The local fix was to give `:oiling` no role, so manning it costs the fireman his place at the
shovel. **That is the right mechanic and the wrong way to get it**, because it is a convention
rather than a rule: the next station somebody adds gets a role, because adding a role is the
obvious thing to do, and the competition quietly disappears again.

> **The deeper problem: nothing in this model can express scarcity of people.** A machine cannot
> say "there are four jobs here and you have two hands". Every job is staffed, so every station
> runs at once, and an operation with enough stations to be interesting is on autopilot.

It also contradicts a noun correction this codebase already made and wrote down:

> **An archetype is a kind of person; a minion is a person; a role is a job.** What a player
> unlocks is Jim, not the fireman's post.

A player hires *people*. The roster is keyed by *job*. Those cannot both be right.

---

## 2. The model

Two declarations, independent, and the gap between them is the game.

```ruby
# what the machine NEEDS doing — derived, not declared
stations = control_points.select(&:effort?)      # :stoking, :damper_open, :oiling, ...

# what the player can BRING — declared, and upgradeable
crew_capacity 2
```

**Jobs come from the machine; hands come from the player.** When `stations > capacity`, somebody
has to decide what is not being done right now, which is the whole point.

### 2.1 The roster becomes positional

A posting is a **seat**, not a job:

```ruby
crew: {
  crew_1: { minion: :jim,      tool: :stokers_shovel },
  crew_2: { minion: :elowynne, tool: :oil_can }
}
```

- **Seats, not jobs.** `crew_1` is "the first person you brought", and where they stand is state,
  not configuration.
- **No `station:` in the posting at all.** Everybody starts in the crew quarters (§2.3) and is
  *sent* somewhere. Deploying the shift is the opening move of a match rather than a line on a
  form.
- Standins fill seats up to capacity **at resolve time**, which is where they already are. The
  change is only that there are `capacity` of them, not `roles.length`.

### 2.2 `Minion#id` becomes the seat

Today `Minion#id` is the role — `:fireman` — and it keys the flat id namespace and the RNG
table. It becomes `:crew_1`. Nothing about the flat namespace or the RNG changes; the ids are
still stable per match and still collide-checked.

**The labels go.** "Fireman" and "Yardhand" are job titles on a roster keyed by job, and the
roster is no longer keyed by job. What the panel shows beside a lever is **who is standing
there** — which it already reads from `station`, not from the role.

> This is the part most likely to feel like a loss, and it is worth being deliberate about. The
> flavour those titles carried was real. It moves to the **station**, which is where it belongs:
> `:stoking` is labelled "Stoking Effort" and the person at it is Jim. "Jim is firing her" is a
> better sentence than "the fireman is Jim", and it is the one the model can now say.

### 2.3 The crew quarters is a place, and that is the load-bearing part

Capacity wants to be upgradeable, and this codebase has exactly one way to make something
upgradeable: put it in a slot. But the quarters is not merely a number in a slot — **it is a
station**, and that is what stops the model quietly giving away the thing it was built to charge
for.

```ruby
Parts.register(:basic_quarters, kind: :crew_quarters, label: "Crew Quarters",
               provides: %i[quarters],
               stats: { crew_capacity: 2, recovery_rate: 1.0 }) do |_spec|
  Fragment.new(
    control_points: [ ControlPoint.new(id: :quarters, label: "Crew Quarters", node: :quarters) ]
  )
end
```

Three jobs, and each is a blueprint chain of its own:

| | what it is | what upgrading it buys |
|---|---|---|
| **capacity** | how many seats the operation has | more hands |
| **origin** | the station every seat starts at | — fixed, and the point |
| **recovery** | fatigue falls faster while somebody is here | better amenities, shorter rests |

> **Crew start here, never at a working station.** An effort station that can be a starting post
> hands the player a shift already at the face for free — and for a mine that is most of the
> operation given away, because **getting people in and out is a large part of what a mine
> actually does.** The rule has to be structural rather than a convention somebody remembers,
> for exactly the reason §1 gives: the convenient default is the one that gets taken.

**Recommended: capacity and recovery read from the fitted part's `stats:`**, which `Assembly`
already resolves, so `Fragment` needs no new field. The station comes through `control_points:`
like any other.

**Alternative: capacity as a plain builder argument.** Simpler, but not purchasable, not gated,
not on the outfitting screen — and it gives the quarters no place to *be*, which throws away both
the transport problem and the recovery mechanic.

**Sized per operation, deliberately.** A steam engine's quarters is a mess room off the engine
house; a mine's is a surface building with a cage under it. Making it an ordinary part means each
operation is balanced against the gang it should support, rather than against a global constant.

> **`recovery_rate` is declared now and consumed by the fatigue release.** Naming it here costs a
> line and means the quarters does not have to be reopened later; nothing reads it until fatigue
> exists, and the sketch for that says so.
>
> **Fatigue landed first, 2026-09-18**, against the argument in §3 that it should come after this.
> It is self-contained — a valve is somewhere to stand down to — so it works today and this
> release makes it *scarce* rather than enabling it. The seam it left is exactly this one:
> `ControlPoint#recovery` defaults to `Fatigue::BASE_RECOVERY` for any non-effort station, and the
> quarters is a larger number in that same field. **Nothing new is needed here.**
>
> One measured figure to size it against: `BASE_RECOVERY` takes a spent worker back to fresh in
> **455 s**, against roughly **300 s** to spend one at a heavy station — so a post worked flat out
> needs a little under two people to keep it running. That ratio is what better amenities buy
> down, and it is the number to tune rather than capacity alone.

---

## 3. What this makes possible

- **Stations can outnumber hands on purpose.** The steam engine has three today — stoking, damper,
  oiling — against a starting capacity of two. Something is always unattended.
- **Reassignment becomes the core verb.** `assign_minion` already exists and already works; it
  becomes the thing a player does constantly rather than once.
- **An upgrade that is unambiguously good is still a real decision**, because it costs money that
  could have bought a better boiler.
- **Fatigue lands into a model that can use it.** A tired fireman is a reason to swap seats, and
  swapping is only meaningful when there are fewer people than posts. The fatigue release should
  come *after* this, not before.
- **A mine can be staffed badly.** Hewing, hauling, pumping and ventilating are four jobs; two
  hands makes the whole operation a triage problem, which is the game.

---

## 4. Decisions, alternatives and costs

### 4.1 Positional seats vs keeping named roles

**Recommended: positional seats.**

- **Pros.** Expresses scarcity, matches the noun correction already made, makes `station:` a
  decision, and lets capacity change without the role list changing.
- **Cons.** Loses the job titles (§2.2). Touches the delivery tier's crew screen, which is
  currently a list of jobs to fill.

**Alternative: keep roles, fill only `capacity` of them.** Rejected: which roles get filled is
then either arbitrary or another declaration, and a player who wants their two hands on stoking
and oiling rather than stoking and damper cannot say so.

### 4.2 Where a seat starts

**Recommended: always the quarters, and the roster cannot say otherwise.**

- **Pros.** Deploying the shift becomes the opening move of a match instead of a form field.
  Transport is expressible later without anything being taken back — a mine can put real distance
  between the quarters and the face, and the model already says everyone begins at one end of it.
  It also gives fatigue somewhere to recover *to*.
- **Cons.** A player who wants the same opening every match has to perform it every match. That is
  a real cost and it is worth paying: the alternative is the whole of §1 again, one layer out.

**Alternative: a starting station in the posting.** Rejected. It reads as convenience and is
actually the same defect as `Crew.normalise` filling every role — the machine handing over, for
free, the resource it was supposed to make scarce. A mine would begin with the entire shift
already underground.

**Alternative: start unassigned, at no station.** Rejected for a smaller reason: "nowhere" is not
a place, so it cannot be upgraded, cannot recover fatigue, and cannot be somewhere transport
starts from.

### 4.3 What happens to an over-full roster

A roster naming more seats than the fitted capacity — because the player downgraded, or a
snapshot predates a change.

**Recommended: refuse the build**, the way `Assembly` refuses an impossible loadout.

- **Pros.** Loud, and consistent with how every other over-specified configuration is handled.
- **Cons.** A snapshot taken before a capacity change cannot be restored.

**Alternative: truncate to capacity.** Rejected — it silently discards a person the player
chose, which is the class of failure this codebase keeps writing rules against.

### 4.4 Does an unmanned station do nothing, or something?

**Recommended: nothing, unchanged.** `Tick#worked` already returns `0.0` for an unmanned effort
station and that is correct — an unattended shovel moves no coal.

> **Check before building: does anything currently depend on every station being manned?** The
> engine has never run with an unmanned station in a shipped configuration, so "nobody is stoking"
> is a path the balance has not been measured against. Expect the cold-start gradient to move.

---

## 5. What this must not foreclose

- **Fatigue.** Seats are what fatigue makes interesting. Do not bake "one person, one station for
  the whole match" into the delivery tier's UI.
- **More than one person at a station.** Still last-writer-wins (`tick.rb:153`), still a `TODO`,
  and a capacity model makes gang work expressible for the first time. Do not make `station_index`
  harder to invert.
- **Roles as *training*, not as posts.** If job titles come back, they should be something a
  person **is** — a qualification that makes them better at a station — not a slot on a roster.
  `Training` already exists for exactly that.
- **Operations with wildly different headcounts.** A mine is not a steam engine. Capacity belongs
  to the operation, not to a global constant.
- **More than one quarters, in different places.** A large works might have several, and which one
  somebody is nearest to would then matter. Keep the quarters' station id coming from the *part*
  rather than hard-coded, so a second one is another fitting rather than a new concept.
- **Transport as a real cost.** Today a reassignment is instantaneous. A mine wants the cage to
  take time, and that is the difference between a shift of four and a shift of four *where two of
  them are in the shaft*. Do not build anything that assumes a minion is always at the station
  their state names — the seam for that is `assign_minion`, not `station_index`.

---

## 6. Staging

| | |
|---|---|
| **A** | **`:crew_quarters` as a required slot**, carrying `crew_capacity`, `recovery_rate` and the origin station. Capacity comes from the fitted part; everybody starts at its station. |
| **B** | Seats in `Crew.normalise`, `Minion#id` becomes the seat, the roster loses `station:`. Sim only — the steam engine gets two seats against three working stations, and the balance is measured. |
| **C** | The delivery tier: the crew screen becomes seats rather than jobs; `Crewing`, `Roster`, the views. |
| **D** | The balance sweep: what two hands can actually keep up with, and where the third is worth buying. |

**A goes first**, because the quarters is where seats come *from* — building seats without a place
for them to start is what produces the "everybody begins at a lever" default this sketch exists to
prevent. B is the one that changes behaviour; C is plumbing.

> **A and B shipped together, deliberately.** Both rewrite the same seam — `Crew.normalise`,
> `crew_for` and the role list — so staging them apart meant writing an intermediate roles-with-a-
> quarters-station API and then deleting it. The attributability the split was for is worth less
> than the churn it costs when the two changes touch the same three methods.

---

## 7. Verification

- **A station nobody is at does nothing** — already true, and now reachable, so assert it.
- **Nobody starts at a working station.** Every seat's initial `station` is the quarters', on
  every catalogued machine. This is the assertion that keeps §2.3's rule structural rather than
  remembered — and it fails the moment somebody adds a convenient default.
- **Capacity comes from the fitted part**, so swapping the quarters changes the number of seats.
- **Capacity is respected**: a roster naming three seats against a capacity of two refuses.
- **Seats round-trip**, ids and stations both, as Symbols asserted with `be` — the roster already
  broke this way once and `Crew.normalise` is where it was fixed.
- **Reassignment survives a snapshot**, which `station` in state already guarantees and which now
  matters far more.
- **The reference crew still reproduces the tuned machine**, or every balance figure recorded in
  `bearings.md` and `minions.md` is invalidated at once. This is the assertion that says A landed
  without moving the ground under everything else.
- **`Operations.catalogued` all declare a capacity**, the way `failure_spec` walks every machine —
  a missing one must not default to "everybody".

---

## 8. As built

Landed 2026-09-18, stages A–C. **D, the balance sweep, is skipped** — it folds into the larger
sweep that comes with the mine and the tech tree.

### The measurement that says it landed without moving the ground

| | fire | boiler | rpm | shaft |
|---|---|---|---|---|
| nobody deployed | 322.8 K | 3.5 kPa | 0.0 | **0.0 kW** |
| deployed to the shovel | 1022.0 K | 547.9 kPa | 173.5 | **495.5 kW** |

The second row reproduces the pre-release reference exactly (547.8 kPa). **Nothing is wired to
make an undeployed engine do nothing** — an unmanned effort station already delivered zero, and
now there is no way to start manned.

The scarcity is real and arithmetic: **three effort stations — `:stoking`, `:ash_raking`,
`:oiling` — against two seats.** `:damper_open` is a valve and costs nobody, which is why it was
miscounted as a station in §3.

### Two things the sketch got wrong

> **`provides: %i[quarters]` in §2.3 is a build error.** `provides:` names **node** ids a part
> must build, and node, lever, instrument and minion ids share one flat namespace — so a node
> `:quarters` alongside a control point `:quarters` is a duplicate. The quarters needs **no node
> at all**: it is a place, a place is a `ControlPoint`, and `ControlPoint#lever?` (derived from
> having no `node:`) keeps it off the lever strip while leaving it on the crew screen.

> **`panel[:controls]` fed both the lever strip and the crew station dropdown.** They are
> different lists the moment a station is not a lever, so `panel` gained `stations:`. Left alone,
> the quarters would have rendered as a slider that does nothing *and* been unreachable as a
> posting — the one place crew start.

### What came with it

**Gap 3 is closed.** `Operations.register` now takes an `assembler:`, and
`Operations.assembly_for(type, chassis:, loadout:)` answers what a build would be — so `Crewing`
and `DevMatch` stopped naming `Operations::SteamEngine` out loud. `Assembly#crew_capacity` and
`#crew_origin` find the quarters by **what its slot accepts**, not by a slot id, so a mine gets
both for free.

**`Naming/VariableNumber` is off**, documented in `.rubocop.yml`: `normalcase` wants `volume_m3`
and `snake_case` wants `volume_m_3`, so whichever is picked half this codebase's unit suffixes are
wrong. Seats are `crew_1` for the same reason those names are what they are.
