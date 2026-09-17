# Minions: individuals, equipment, and getting hurt

**Status:** design sketch, agreed at review. Nothing here is built yet.

Supersedes [`minion-sketch.md`](minion-sketch.md), which is the seed of it and stays as the record
of the original thinking. The correction in [`blueprints.md`](blueprints.md) §17 — that the system
models the wrong noun — is folded in here rather than restated there.

**Movement and the spatial model are NOT in this release.** They are the next one, and §10 says
what this must leave open for them.

---

## 1. What exists, measured

Minions are **structurally complete and functionally inert**. The whole chain is wired:

```
content/minions/crew.yml  →  Minion (frozen config)  →  per-minion Rng stream
  →  state { health, fatigue, station }  →  assign_minion over Kafka
  →  Tick#station_index  →  Tick#crew_multiplier  →  ControlPoint#actuate(rate_multiplier:)
```

Two things neutralise all of it:

- **Every lever ships `stiffness: Float::INFINITY`**, so `control_point.rb:50` returns before the
  multiplier is ever read. `steam_engine_spec.rb:783` *pins* that inertness deliberately, so the
  day somebody changes it the spec inverts loudly instead of the skill gradient shifting in
  silence.
- **Nothing mutates minion state inside a tick.** `tick.rb:127` carries it through with a TODO
  saying fatigue accrual belongs in phase 0. And `Minion#initial_state` **ignores the rng it is
  handed**, with a TODO asking for "a hidden aptitude" — so every minion is permanently identical
  and permanently fresh.

### Three seams reserved and dead

| Seam | State |
|---|---|
| `Minion#initial_state(_rng)` | Receives a stream, ignores it. §5.1 is what it was reserved for. |
| `Diagnostic#observer` | Stored and frozen, read by nothing. Two instruments declare one. |
| Minion state in the projection | `PlayerView` carries **no minion data at all**. |

That last one is a live bug, not merely an absence: `crew_component.html.erb` renders a station
dropdown that can *send* an assignment but has no source of truth to *display* one, so it always
shows the first option regardless of the real posting. `CrewComponent`'s comment claims the station
"arrives on the projection". It does not.

### And the noun is wrong

`blueprint.rb:154` says so itself: the catalogue enumerates `fireman` and `yardhand`, which are
**jobs performed in an operation**, not minions. What a player unlocks is an individual — Jim, who
is human, or Elowynne, who is an elf. The dead `tags:` in `crew.yml` are aimed at the same missing
model: nothing reads `practised` or `green` anywhere in the repository.

---

## 2. The boundary, first, because everything follows from it

| Owns | What |
|---|---|
| **Postgres** | Who exists, what they have learnt, what gear they own, who is on the IL |
| **`options:`** | The resolved crew for *this* match — the loadout's exact shape |
| **The simulation** | Stats, tags, stations, exposure, injury. Nothing about ownership. |

The sim must not learn what a player is, exactly as it has never learnt what a blueprint is. A
minion arrives already resolved, the way a chassis does.

> ### The roster moves into `options:`, and that is the load-bearing change
>
> `definition.rb:1316` has carried the warning since the crew was written:
>
> > *"this roster is fixed, so it stays out of `options:` and is rebuilt from code like the node
> > list. **The moment a crew can be hired, injured or dismissed it must move into `options:`**, or
> > a restored snapshot rebuilds a different crew. Exactly the trap `variant:` is in `options:` to
> > avoid."*
>
> This is the release that makes all three of those true at once.
> [`blueprints.md`](blueprints.md) §8 calls it "the one thing that does reach the sim", and
> [`modular_components.md`](modular_components.md) §15 records that it was deferred once already.
>
> Two consequences, both of which have bitten this codebase before:
>
> - **The registered builder's keyword list moves with it.** An option the builder does not name is
>   an `ArgumentError` at restore — loud, which is right, but the two have to travel together.
> - **A crew is a symbol-as-value minefield.** Archetype ids, tag keys, station ids, equipment ids
>   and injury modes are all Symbols living as *values*, so JSON hands every one of them back as a
>   String. `Operation#restore` already normalises `station` for exactly this reason and will have
>   to normalise the rest. The digest **cannot** catch it: `canonical` runs through
>   `JSON.generate`, where `:human` and `"human"` are the same string. Only identity assertions
>   find it.

---

## 3. Nouns

```
Minion      an individual. Jim.        kind: :minion     id: "jim"
Archetype   their race. Human, kobold.  content data: base stats + tags
Training    a permanent upgrade to ONE minion.  kind: :training   id: "jim/hot_work_ticket"
Equipment   a fitted item, one per slot.        kind: :equipment  id: "jim/crude_miners_tools"
Station     a control point a minion is posted to — and, this release, their PLACE
Crew slot   a role an operation declares (:stoking), filled before the match
```

**Scoped ids follow `Blueprint.chassis_id`'s existing precedent exactly.** A chassis is already
`"steam_engine/high_pressure"`, scoped because a frame has no standalone existence and two machines
could each call one `standard`. Equipment unlocked *per minion* is the same shape, so per-minion
ownership needs **no migration to `unlocks`** — the triple `(owner_id, kind, blueprint_id)` already
expresses it.

`Blueprint::KINDS` gains `:equipment` and `:training`; `:minion` is re-pointed from archetypes to
individuals, which retires the §17 note.

---

## 4. Stats and tags

**A small fixed core plus an open valued-tag bag** — the same split `Content` already makes between
`REQUIRED_RESOURCE_KEYS` and free-form `tags:`.

```ruby
STATS = %i[strength toughness intelligence].freeze   # every minion has all three
tags:  { heat_resistance: 0.6, darkvision: 0.1, clumsy: true, open_flame: true }
```

- **Fixed**, because the sim's own machinery reads them and needs a guaranteed number with a
  meaningful default: `strength` drives `rate_multiplier` (built), `toughness` drives the Danger
  Check (§5), `intelligence` drives the dead `observer:` seam (not this release).
- **Open**, because `mining_effectiveness` and `darkvision` are content-specific and must never
  need a schema change to add.

**Minion tags have to be indexed the way resource tags are and currently are not.** `content.rb:76`
precomputes and freezes `@tags` for resources because `tags(id)` is called once per parcel per port
per link per tick and the naive version allocated an array every time. `content.rb:74` stores minion
specs raw, so their tags are never symbolised, never indexed and never queried. A `Registry`
accessor for minion tags, built the same way, is part of stage B.

### Merging a minion's tags with three items'

**Numbers add; booleans OR; the total is clamped. Consumers multiply.**

Gear reads as "+0.25 mining_effectiveness", which is how every example in the original sketch is
written, so addition is what the content means. The clamp is what stops three stacking items running
away.

The *use* is multiplicative and belongs to whoever is asking: the sketch's mine node wants
`mining_effectiveness × darkvision`, which is a punishing `0.25 × 0.1` and is meant to be. Saying
this once, loudly, is what stops the two being confused — **merge adds, use multiplies.**

> The considered alternative was **max wins**, matching `Arbiter#port_affinity` (`arbiter.rb:465` —
> an exact key beats a tag, max of the matches, clamped). It was rejected because it flattens kit
> choice: a second source of a tag would never help, so there would be no reason to fit a better
> tool alongside better gear.

---

## 5. Injury is `Wearing` for people

### 5.1 The Danger Check needs no dice, and that is what makes it work

The instinct is to roll when the hazard lands. **Do not** — and the reason is not merely that
[`invariants.md`](../reference/invariants.md) permits entropy in only three places. The older house
rule is the real one:

> *"Incidents are never a per-tick dice roll. Stress accumulates deterministically from operating
> conditions, so a player can learn 'I ran it too hot for too long' rather than being told the dice
> disliked them. The player's uncertainty comes from the hidden threshold and sensor noise, not
> from the system being arbitrary."*

So **roll a hidden `resilience` at `initial_state`** — from the stream `Minion#initial_state`
already receives and throws away, whose TODO asks for exactly this — and make the check a
deterministic comparison against it. Structurally identical to `durability_range` +
`stress_per_second` + `overload?`.

That buys, at no cost whatever: determinism, order-independence, replay, snapshot safety, **no
amendment to the entropy invariant**, and freedom to run the check anywhere on the tick path.

```ruby
# Pure. No entropy is drawn here.
bite = hazard.severity - resistance(minion, state, hazard)
return [ state, [] ] if bite <= 0.0                 # shrugged off entirely

remaining = state.fetch(:resilience) - bite
tier = if bite >= MORTAL_BITE          then :mortal   # nobody walks away from a drum letting go
       elsif remaining <= 0.0          then :severe
       elsif remaining < WALKING_WOUNDED then :minor
       end
```

Two routes into harm, and they are `Wearing`'s two exactly: **accumulation** (repeated small
exposure grinds `resilience` down, so a long shift in a hot firebox eventually tells) and
**overload** (one blow big enough that what is left does not matter). A worn minion is hurt sooner,
which is what keeps their history meaningful.

`resistance` is `toughness`, plus tag matches against the hazard's own tags (`heat_resistance`
against `[:scalding]`), minus penalties (`clumsy`). **The curve is a sweep, not a guess** — this
sketch names the shape and the measurement names the numbers, as with everything else here.

### 5.2 Where hazards come from — a station is a place, coarsely

There are no volumes this release, so "who was near it?" needs an answer that needs no geometry.
There is one: **the machine already knows which levers sit next to which parts.**

```ruby
# On the part INSTANCE, parallel to `damages:` and for the same reason: Nodes::Boiler cannot name
# a station, because a boiler in another machine has none near it. Which modes exist belongs to
# the class; who is standing next to it belongs to the machine.
endangers: {
  explosion: { tags: %i[blast scald],
               # How bad it was, not merely that it happened
               scales_with: :flash_expansion, reference: 22.0,
               stations: { stoking: 3.0, damper_open: 1.4 } }
}
```

### A station's figure is a weight; the magnitude comes from the part

**A small steam escape is not a large one**, and a drum with 600 kg behind the plate is not one
nearly empty. So the number beside a station says how *exposed that post is*, and the size of the
event is read off the part itself — `scales_with:` names a key in the failure event's own
`detail:` and `reference:` is the value at which a weight means its face value.

Reading the **event** rather than the node buys three things: the figure is exactly what the part
reported at the instant it failed rather than whatever its state has become since; it needs no
cross-node read, so phase 6b stays order-independent by construction; and the magnitude lands on
the durable record, so a consumer can see *why* an injury was as bad as it was.

A declaration with neither key is flat, which is the right answer for most hazards — a linkage
snapping is a linkage snapping. **This is the seam the chemical work needs**: a vessel that spills
reports how much got out, and the danger follows the quantity rather than a constant somebody
guessed.

Measured on the real rupture: 635 kg of water, flash expansion 23.18 against a reference of 22.0,
so the fireman's post sees 3.16 rather than a flat 3.0.

Spent in **phase 6, immediately after `spread_damage`**, which it deliberately mirrors — the same
"what a failure does to what is next to it", applied after all wear is settled so two failures on
one tick give the same answer whatever order they are visited in.

`tick.rb:586` predicted this feature precisely:

> *"a bursting drum throws its shell at the shop, and that matters in exactly two places — it
> breaks adjacent machinery and it injures nearby crew. Modelling the release properly would be a
> whole physics for one narrative beat, and it would need a notion of place before it could even
> name a neighbour."*

The second source is **a station that is dangerous to work**, declared on the control point
(`hazard: { severity: 0.02, tags: [ :heat ] }`, per second). That is where the unlit / no-safety-rails
/ cramped operation upgrades land later, as modifiers on a number that already exists — the
risk-reward dial, bought rather than assumed.

> **Naming stations rather than minions is what lets this upgrade cleanly.** A station is fixed by
> the machine; a roster is the player's, so a part naming a minion id would be naming something it
> cannot know. When volumes arrive, a station sits *in* a volume and the hazard resolves through it
> instead. Nothing here has to be unpicked.

### 5.3 The ladder

Ascending, like `failure_modes`, with `escalate_to`'s forward-only rule — a minion already
incapacitated can still be killed, and never relaxes back to a scratch.

| Mode | In the match | Afterwards |
|---|---|---|
| `:minor` | derates `{ strength: 0.6, intelligence: 0.8 }` — keeps working, badly | heals |
| `:severe` | `{ strength: 0.0 }`, stood down, station cleared | heals |
| `:mortal` | off the board | **IL for 1–3 matches** |

Minor and severe are match state and die with the match. Only `:mortal` writes to Postgres, which
keeps the whole of in-match injury inside the simulation where it can be replayed.

Emits `minion_hurt` **on the transition only** — the discipline `break_part` already follows, and
for the same reason: recomputing a mode every tick would announce the same injury at the tick rate
forever. Severity `:warning` for minor and `:critical` for severe and mortal, so the two that matter
reach the panel feed and the walking wounded do not bury them.

---

## 6. The standin

**A kobold day-labourer**, from *Sundry Temporary Assignments, Ltd.* Fills any unfilled crew slot,
in any number, forever, and can never be unlocked, upgraded or taken away.

```yaml
kobold_temp:
  label: Day-Labourer
  strength: 0.35
  toughness: 0.4
  intelligence: 0.3
  tags: [ green, clumsy, skittish, unlicensed ]
```

Named at draw time (Grib, Nack, Ettle…) so a panel full of them reads as a gang of people rather
than one entry repeated four times.

`clumsy` feeds the Danger Check penalty directly — they are not merely weak, they are **more likely
to get hurt**, which is the whole risk-reward point of being forced to field them. `unlicensed` is
the seam for work a ticketed minion may legally do and they may not.

> **A constant, not a blueprint everybody is granted.** A granted blueprint can be revoked, clutters
> the catalogue, and `grant_everything!` would make it indistinguishable from earned kit. The point
> of the last resort is that it is always there and never an achievement.

---

## 7. Equipment: three slots, one item each

`Slot`-shaped but deliberately **not** `ReactorSim::Slot`. That class exists to answer one question
— *when nothing is fitted here, what happens to the wiring?* — and a pair of gloves has no wiring.

```ruby
EQUIPMENT_SLOTS = %i[tool gear utility].freeze
```

An item contributes **stat modifiers and tags, and nothing else**. No nodes, no links, no fragment.

```ruby
Equipment.register(:crude_miners_tools, slot: :tool, label: "Crude Miner's Tools",
                   description: "A stone pick and a tallow candle.",
                   stats: { strength: 0.05 },
                   tags: { mining_effectiveness: 0.25, darkvision: 0.1, open_flame: true })
```

Registered in **code**, not YAML, for the reason `parts.rb:6` gives: the pull of data was never
diffability, it was letting someone outside this repository add one, and that is ruled out.

`open_flame` is the worked example of a tag that cuts both ways — it is what lets you see in a
drift, and it is what ignites the gas in one.

### Resolution happens at build, from ids

`options:` carries ids, not folded numbers:

```ruby
crew: { stoking: { minion: "jim", archetype: :human,
                   tool: :crude_miners_tools, gear: nil, utility: :lucky_amulet } }
```

and the registry merges them into frozen `Minion` config once, at build — the same place
`Assembly` resolves a loadout into the flat lists `Operation` has always taken.

> The alternative was for Postgres to fold everything and hand over flat numbers, which keeps the
> sim smaller. Rejected because the sim genuinely needs the parts: `open_flame` is a hazard tag the
> simulation must read, and gear that can be damaged or lost needs an identity to lose.

---

## 8. Pre-match selection

Copy `Outfitting` / `Loadout` / `loadouts#edit,update` / `loadout_drafts#create` /
`outfit_controller.js` **wholesale**. It is the same screen with different nouns, down to the Turbo
frame on the frame rather than the form, the draft-as-a-resource decision, and `permit(*slot_ids)`
rather than `permit!`.

- A `Roster` model, jsonb `{ station_id => { minion:, tool:, gear:, utility: } }`, mirroring
  `Loadout#to_sim`'s string-in / symbol-out discipline and its upsert-because-the-form-is-idempotent
  rule.
- The operation declares crew slots. An unfilled slot, or one whose minion is on the IL, falls back
  to the standin — which is the moment the player feels the loss.
- **The roster rides inside the reset command**, never referenced by it, for the race `dev_match.rb`
  documents: the web process writes the row and *then* produces the command, so a runner reading the
  table would read it at whatever moment the record happened to arrive.
- Stations stay reassignable during the match through the existing `ASSIGN_MINION` path. The
  pre-match screen sets the starting posting; it does not replace the in-match one.

**And the projection has to carry minion state**, or the crew panel goes on lying (§1).

---

## 9. Making it bite — and why `stiffness` was the wrong lever

The first plan was to give `:stoking` and `:feed` a finite `stiffness:`, so a weak minion took
longer to reach full effort. **That is a derivative, and the derivative is not the interesting
quantity.** A kobold with no shovel would take longer to reach the setting and then deliver
*exactly as much* as an ogre with a specialised tool and training. The comparison the game is
about — who can actually do this work — would not have been modelled at all.

So the lever is the player's **intent**, and what comes of it is the crew's **capability**:

```ruby
ControlPoint.new(id: :stoking, node: :stoker,
                 effort: { strength: 0.75, dexterity: 0.25 },   # weights sum to 1.0
                 aided_by: :shovelling)
```

- **`effort:` is a weighted blend**, because almost no real job draws on one stat: shovelling coal
  is mostly back and a little placement. The weights must sum to 1.0, which is what keeps *a fit,
  unaided human scores 1.0* true for every station — and therefore what lets a node's declared
  throughput mean "what a competent person achieves".
- **`aided_by:` is one tag**, so a shovel counts for shovelling and not for reading a gauge.
- `capability = blend × (1 + aid) × condition`, multiplicative so a specialised tool is worth more
  in capable hands. Measured: day-labourer **0.41**, a plain human **1.09**, a good fireman with a
  shovel **1.86**, with training **1.93**.
- Applied in `Tick#control_values`, the single line where a control becomes the number a node
  reads. Nothing else changes.

**A station's declared rate is what a competent human manages, and there is no clamp.** The
stoker's `0.25 kg/s` is a person, not a firehole, so somebody exceptional exceeds it rather than
merely reaching it sooner — which is what keeps training and tools worth buying forever.

**An unmanned effort station delivers nothing**, which finally settles `crew_multiplier`'s
long-standing TODO. It was too dangerous to act on while it would have frozen all seven of this
engine's levers; applied only to the two that are somebody's work, "an unmanned shovel moves no
coal" is simply true.

`stiffness` stays, unused by any shipped control, for a lever that should genuinely take time to
travel. The other five controls are valves and a valve goes where you put it.

> **Fatigue belongs here and is the next thing.** Effort is *subjective* exertion — the same lever
> position costs a day-labourer far more than it costs a strong fireman — so the natural rule is
> that fatigue accrues with `intent ÷ capability` rather than with the lever's position. Working
> somebody past what they can manage is what should tire them; a strong worker coasting at a
> setting that is killing a weak one should not tire at all. `state[:fatigue]` exists, multiplies
> into capability already, and nothing advances it.

---

## 10. What this must not foreclose

- **Volumes and transit**, which are the next release. Hazards resolve through *stations* precisely
  so that they can later resolve through the volume a station sits in.
- **Repair as a minion job** ([`blueprints.md`](blueprints.md) §3), including that what a broken
  part spills can stop the crew reaching it.
- **The `observer:` path.** `intelligence` is defined here and read by nothing; wiring the gauge
  path is its own change and must not be smuggled in.
- **Fatigue.** It exists in state and nothing accrues it. Do not invent a second condition axis:
  injury derates alongside fatigue and the two multiply, exactly as `condition` already does.

---

## 11. Staging

| | |
|---|---|
| **A** | Nouns: `Blueprint` kinds, individuals, scoped equipment/training ids, the standin. Catalogue only — nothing reaches the sim. **Built 2026-09-16 — see §13.** |
| **B** | Stats and tags: `STATS`, the equipment and training registries, the merge rule. Human, elf and kobold archetypes. **Built 2026-09-16 with A** — the two could not be usefully separated, because a `Blueprint` kind with no registry to enumerate has nothing to be a catalogue of. |
| **C** | **The roster into `options:`** — the load-bearing one. Builder keyword, snapshot round-trip, symbol normalisation, determinism spec. **Built 2026-09-16 — see §14.** |
| **D** | Injury: `resilience` rolled at `initial_state`, the Danger Check, the ladder, `endangers:` in phase 6b, `minion_hurt` events, derates. **Built 2026-09-16 — see §15.** |
| **E** | Pre-match screen, `Roster`, the projection carrying minion state, the crew panel telling the truth. **Built 2026-09-16 — see §16.** |
| **F** | Effort stations and crew capability, and the re-sweep. **Last**, so the balance change lands alone and is attributable. **Built 2026-09-16 — see §9 and §17.** |
| **G** | The IL: a consumer writes mortal injuries, the clock decrements at match start, the standin backfills. **Built 2026-09-16 — see §16.** |

**The IL clock decrements at match start** rather than naming an absolute match number, because
there is no per-owner match counter and nothing else needs one yet. It is farmable by starting and
abandoning matches; that costs a match each time and gains nothing today, and it should be revisited
when a match is worth something.

---

## 12. Verification

- **Determinism**: same seed and command log produces identical injuries. This is the spec that
  proves the no-dice design — it cannot pass if a roll has leaked onto the tick path.
- **Snapshot round-trip with a crew in `options:`**: archetype, tag keys, station, equipment ids and
  injury mode all return as **Symbols**, asserted with `be` and never `eq`. The digest cannot catch
  this class; it has already been paid for five times.
- **A Danger Check table**: one hazard against three toughnesses and two sets of gear, asserting the
  tier ladder rather than tuned numbers, so a balance change does not fail it.
- **Escalation on a real minion**: minor → severe → mortal, never backwards, event only on change.
- **`endangers:` reachability**, mirroring `failure_spec`'s inverse check: no mode endangers a
  station that does not exist, and no station is endangered by a mode its part can never enter.
- **A run-through**: burst the flywheel with the crew posted, and assert the fireman is hurt, the
  event reaches `match.events`, and a mortal injury writes an IL row.
- **The re-sweep** for stage F, recorded in `current_progress.md` as the original gradient was.

---

## 13. What stages A and B found

**The individual layer earned itself immediately.** The sketch had races carrying stats and
individuals carrying "offsets and tags", which read like a nicety until it was written down: an
elf is 0.75 strength and 1.2 dexterity, and Galathas is 1.1 and 0.95 — strong for an elf and
heavy-handed with it — where Elowynne is 0.75 and 1.35. Two members of one race who are not
remotely the same worker, which is the entire argument for four layers rather than two.

**Five stats, not three.** `dexterity` and `charisma` joined at review. `dexterity` explicitly does
**not** replace the `clumsy` tag: how finely somebody works and how often they drop things are two
different statements about one person, and a steady-handed worker who knocks things over is
somebody everybody has met.

**Pricing had to be split from ownership.** Equipment is unlocked per minion, so the blueprint id
is scoped — but a bill of materials keyed to the *pairing* meant 39 identical lines in
`config/blueprints.yml` today and a fresh one whenever anybody hires a minion. That is exactly the
inventory list that drifts silently. `Blueprint.build(priced_as:)` looks the bill up by the bare
item id: ownership is per minion, cost is per item.

**The standin is not a constant after all**, which the sketch got wrong in §6. It said a constant
outside the catalogue, on the grounds that a last resort must not be revocable. The revocability
argument holds; the *placement* did not. Made a constant, the engine would need a second way to
fold a sheet — a special case through the most safety-critical arithmetic in the feature. It lives
in `content/minions/` like anybody else with **`hireable: false`**, and everything deriving a
catalogue reads `Content.hireable` rather than `Content.minions`. One resolution path, one field
carrying the whole difference.

> That rename has a trap in it, and the specs caught it the moment it landed: four blueprint specs
> enumerated `Content.minions.keys` and started counting the standin as something to buy. Anything
> asking "what can a player own?" must read `hireable`. `minions` is "who exists".

---

## 14. What stage C found

**The layer arithmetic had to be extracted before the roster could use it.** `Content::Registry`
folds layers one and two; `Crew` folds three and four — a split forced by the boundary rather than
chosen, since content knows about people and only the delivery tier knows what a player owns. Two
copies of "stats add, tags add, `true` wins" would have drifted, and the drift would be silent: a
tag that sums in one path and overwrites in the other reads as a balance problem, not a bug.
`Sheet` is the one implementation.

**Clamping is once, at the end, never between layers.** Doing it per layer makes their *order*
matter — a penalty floored at zero before a bonus landed gives a different worker from the same
kit applied the other way round. `Sheet.settle` runs after all four.

**A `Minion` no longer looks anything up.** It held an archetype id and reached into content for
`strength` on every call to `rate_multiplier` — once per manned lever per tick, for a number that
cannot change during a match. Stats arrive folded. That also puts the whole of training and
equipment behind one boundary: `Crew.resolve` is the only thing that knows a player owns anything,
and nothing on the tick path can learn it.

**An item's slot has to be checked against the slot it is fitted in, not against the slot list.**
The first version validated that `item.slot` was one of the three — which is always true, since
`Equipment` checks it at construction. A pair of gloves posted as a tool would have granted its
bonus from the wrong place, and a pre-match screen offering the wrong list would have been wrong
in a way nothing complained about.

**Seventh instance of symbols-as-values**, and the widest yet: a roster carries a minion id, a
list of course ids and three equipment ids per role. `Crew.normalise` is its
`Assembly#resolve_loadout` — every role named including the unfilled ones, so a slot a player
emptied cannot quietly refill itself on restore.

---

## 15. What stage D found

**The gradient works, measured on the real machine.** Starve the boiler with the fusible plug
left out — this engine's one route to a genuine explosion — and at tick 4491, 635 kg of water
behind the plate:

| Crew | Fireman (under the barrel) | Yardhand (at the damper) |
|---|---|---|
| Day-labourers | **mortal** | severe |
| Jim + ticket + oilskin, Galathas + apron | severe | severe |

The crew you invested in *survives what kills the standins*. That is the risk-reward the whole
release is for, and it falls out of resistance being subtracted before the mortal threshold —
good people and good kit genuinely downgrade an outcome rather than merely delaying one.

**Severity scaling was added at review and it changed the shape of the declaration.** The first
version had a flat number per station. A small steam escape is not a large one, so the station
figure became a *weight* and the magnitude now comes from the part, read off the failure event's
`detail:`. That also meant `Nodes::Boiler` had to start reporting `flash_expansion` and
`contents_kg` when it fails, which is a good change on its own: the durable record now says how
big the event was, not merely that it happened.

**`WALKING_WOUNDED` was 0.35 and the tier was almost unreachable.** Bites large enough to get
through a minion's resistance at all are a decent fraction of what they have, so a worker went
from unmarked straight to carried-out in two hits and `:minor` fired only on a coincidence. 0.6
makes the band real. **A tier nothing can reach is a tier that does not exist** — the same defect
as the pressure-ratio rule that could never name an explosion, one release earlier.

**Three specs failed for reasons that had nothing to do with what they tested**, and all three
were the spec being wrong rather than the code:

- `Vessel` has **no `overload?`** — it depletes durability — so a rig built with a tiny
  `max_pressure_pa` and the default `stress_rate: 0.0` is a vessel that never breaks however far
  past its rating it goes. The zero default is the silent-off-switch shape again.
- The saturation solve settles the liquid/vapour split on the first tick, so **the pressure at
  rupture is not the pressure the vessel was built with**. Calibrating a scale against the latter
  made 2.0 come out as something else. The fix is to read the figure the part actually reported.
- Two hazards where one was enough: the ladder had already moved on by the second.

**Eighth instance of symbols-as-values**, and the nastiest since the failure mode: `injury` is a
Symbol held as a value, and a String is truthy — so a crew restored from a snapshot would read as
injured while every derating quietly fell back to 1.0. Completely healed and still limping.

---

## 16. What stages E and G found

**The roster is the player's INTENT; availability is applied when a machine is built.** This was
not in the sketch and it is the best thing in these two stages. A player who posted Jim and then
watched him carried out keeps Jim in the roster — the row is never rewritten — and the labour
exchange fills the job meanwhile. When his recovery runs out he is simply back, with no second
decision to make and nothing to remember. Rewriting the row would silently discard a choice the
player made and leave them to notice and redo it.

It has to be applied in **two** places, and missing either is silent: `DevMatch.build` and
`reset_command`. The runner rebuilds from the command payload rather than from the table, so a
command carrying the raw roster would field somebody the screen had just called unavailable.

**Refusal and substitution are different statements and should feel different.** Posting somebody
who is on the injury list is *refused* by the screen. Leaving a post *empty* substitutes the
standin silently, because that is a choice rather than a mistake.

**The hurt event had to learn the difference between a job and a person.** It carried `node:
:fireman`, which is the post — and the injury list belongs to Jim, whose job the fireman's post
still is for whoever stands in it next. A consumer given only the role could not write the record
at all. `minion:` and `lasting:` are on the event now, the second so the engine owns the ladder
and this side never keeps a second copy of which tier outlives a match.

**The recovery clock cannot live in `build`.** `DevMatch.build` is also called by the web process
to rebuild a `Match` for the panel and the roster, so decrementing there would tick somebody's
recovery down every time a page rendered — a player could heal their crew by refreshing.
`DevMatch.start!` is called from the two places a match actually starts, and the reset command is
built *before* the clock advances so that somebody whose last match this was is still out for the
machine being built now.

**A stale unlock crashed the crew screen**, which is `Unlock.stale`'s warning arriving for real
within a day of the rename: rows granted when `fireman` was a *minion* rather than a job outlived
the noun correction. A stale row leaving a player quietly short of somebody they earned is bad; a
stale row that stops the screen rendering is worse, so `Crewing#candidates` skips ids the
catalogue no longer knows and `rake blueprints:audit` is what finds them.

> **A test that pins a tier is pinning the balance pass.** The end-to-end injury example was
> first written as "the drum lets go and Jim is taken off the board" — which passes today and
> would fail the moment stage F moves a constant, for a reason having nothing to do with what it
> checks. It asserts the **wiring** instead: that a real injury on a real machine carries the
> person and the verdict. Shape does not move with balance; outcomes do.

---

## 17. What stage F found

The model itself is §9. This is what building it turned up.

### The re-sweep

The whole point of the change is that the crew is now load-bearing, and the sweep says so. A full
cold start, same seed, same procedure, only the crew differing:

| Crew | Boiler | Firebox | Speed | Power |
|---|---|---|---|---|
| Day-labourers | 56 kPa | 511 K | 0 rpm | 0 kW |
| One capable human | 608 kPa | 1008 K | 174.6 rpm | 398 kW |

**A locomotive cannot be run by day-labourers**, which is the result the release was for: they
never get the fire hot enough to make steam faster than the engine loses it, so the machine simply
never starts. And a competent human reproduces the previously tuned machine almost exactly, which
is the other half — the baseline held where it should, so the existing balance work was not
invalidated, it was re-based onto a crew of 1.0.

### The traps

**Content is global and is never snapshotted.** This cost the most time here and is the one to
remember. `Operation.from_h` resolves minions against `Content.default`, and it never sees a
`content:` argument — so a registry injected at build vanishes the moment a snapshot round-trips,
and restore raises `unknown minion` for any fixture. Passing `content:` covers a *build*; a spec
that **restores** must stub `Content.default`, which is what the `crew: :reference` tag does.

**`before(:all)` fires before `before(:each)`**, so a hook-installed stub is not in place yet for
an expensive setup block. The event pipeline spec raises steam once in `before(:all)` and therefore
cannot use the tag at all — it passes `content:` explicitly, which is safe there precisely because
nothing in that file restores a snapshot. Both halves of that reasoning are written at the top of
the file, because either one alone would look like an inconsistency worth "fixing".

**Do not pin a spec to a real minion.** Anything asserted against Jim's numbers is asserted against
a tuning pass that has not happened. `spec/support/reference_crew.rb` provides `test_hand_a` and
`test_hand_b`, flat 1.0 across every stat with no tags, so a spec that needs *a worker* gets one
whose numbers are a definition rather than a balance decision. The same rule as the injury example
above, arriving from the other direction.

**An unmanned effort station found a real gap in an existing spec.** The ashpan example had been
raking out a grate with nobody posted to `:ash_raking` — which passed while effort was inert and
became "ash 12.18 kg against an expected < 0.5" the moment it was not. The fix is what a driver
actually does: take the yardhand off the damper and put them on the ashpan. The spec is more
truthful than it was, and it only became visible because the rule made idle labour cost something.
