# Crewed posts: several workers at one post

Status: **reviewed; building.** Answers from the review are in §7 and supersede anything
above that disagrees. Unit 1 of the open-pit sequence (see
[`open-pit-iron-research.md`](open-pit-iron-research.md)). It is a blocker for the pit, and it
retrofits the steam engine and the colliery.

Decisions already taken:
- Output is rated **per worker**. Retuning is acceptable.
- Every post defaults to **one** worker.
- Upgrades raise the number, either as a stat of the fitted part or by the part itself.
- Hazards, effort and output all scale sensibly with the crew, and the UI shows it.

---

## 1. What exists today

| Piece | State |
|---|---|
| `ControlPoint#capacity` | Exists. `nil` means unlimited, and it is nil on every post except the two refuge holes (cap 1). `Operation#room_at?` already refuses a posting past it, counted over `posting`, so the refusal happens when the order is given |
| `Tick#station_index` | Maps a post to **one** minion: the last one in iteration order wins. It carries a TODO saying exactly this ([`tick.rb:429`](../../lib/reactor_sim/tick.rb)) |
| What reads `station_index` | Effort output (`worked`), stiff-lever speed (`crew_multiplier`), slips (`begin_slip`), the governor (`governed`, `lateness`), marshal and staffed checks (`signalled?`, `in_service?`, `room_aboard`), and the gauge reader (`reading_competence`) |
| Per-person mechanics | Already per person and keyed on each minion's own `station`: fatigue (`tire`), hazards (`endanger`), accident margin (`blunder`), breath, scorch |
| How nodes read effort | `ctx.controls[post]` carries the *worked* value, lever % × capability. Each node turns it into a fraction with an **ad-hoc clamp**: `Conduit#opening` at 1.0, `Vessel` heater 1.0, `Rope#worked` 1.0, goaf packing 1.0, gob sealing 1.0, trapping 1.5, shotfiring and hewing 2.0, the splice 2.0 |
| UI | One row per minion, each with a station dropdown. Nothing shows how many people a post holds or has room for |

**Consequences today:**
- A second hewer on the face is exposed to its hazards, tires and spends their accident margin, but **adds no coal**. That is the worst of both worlds.
- A single worker better than the reference (an ogre stoker) is **clipped to 100 %** at every conduit-based post. `Minion#capability`'s comment says a better worker "exceeds" the rating; at those posts they do not.

---

## 2. The design

### 2.1 Capacity

- **Every post with a `node:` defaults to `capacity: 1`.** Stand-down posts with no node keep what they declare: the quarters stay unlimited (`crew_capacity` already bounds them) and the refuge holes keep 1.
- **Capacity is a part stat**, `crew:` in the part's `stats:`, passed by the fragment builder to both the control point and its node. An upgrade raises it, or a different part sets a different number.
- **A governor post must be 1**, refused at build. Two people do not drive one winding engine.

### 2.2 Who is at a post

`station_index` (post → one id) becomes **`crews`** (post → the **sorted** list of minion ids whose `station` is that post).
- It is built once per tick from N−1 state, as now.
- Sorted, so every sum and every "first of" over a crew is order-independent.
- `station`, not `posting`: somebody still walking there is not working yet.

### 2.3 The unit of effort: worker-equivalents

**The worked value of an effort post becomes lever % × Σ capability over the crew.** 100 means one competent, unaided human flat out; five of them flat out read 500.

Every node that reads an effort post stops clamping at 100 % and multiplies a **per-worker** figure by the worked value:
- a conduit's `max_kg_per_s`;
- a vessel heater's rate;
- a rope's splice rate;
- packing, sealing and trapping.

The ad-hoc clamps (1.0, 1.5, 2.0) go. **The crew is the ceiling now**: capacity bounds headcount, and the stats bound each worker. That also removes the clip on a strong single worker.

Valves are unaffected. A valve's value is its position, which `ControlPoint` already clamps to its range, so lifting the upper clamp in `Conduit#opening` changes nothing for a valve.

**Pros and cons:**
- Pros:
  - Nodes stay ignorant of crews. They read one number, in units that mean the same everywhere.
  - Cross-post comparisons stay meaningful (see 2.6).
  - It fixes the single-worker clip as a side effect.
- Cons:
  - Ten node sites change.
  - Ports downstream of a crewed conduit must be sized for a full, strong crew. The rule that "a derate above 1.0 cannot beat the narrowest port" applies here too, and an undersized port silently caps the crew.

**Alternative rejected:** normalising by capacity, so worked = lever × Σ cap ÷ capacity and a full crew reads 100. Nodes would be unchanged. But "hewing" and "timbering" would then be in different units whenever their capacities differ, and `Roadway`'s `hewing − timbering` would silently lie. It also keeps the strong-worker clip.

### 2.4 Activity: what perils scale with

A node's `activity` is busy-ness against its rating (`carried / (rated × dt)`, clamped at 1). **The rating becomes the full-crew figure**, per-worker × capacity, so:
- A fully crewed, flat-out post reads 1.0, exactly as a fully worked post does today.
- Each person's peril rate tracks **how busy the place is**.
- Total accidents grow with headcount, because there are more people each carrying that rate.

The alternative is to keep the rating per worker. Activity would then saturate at one worker's worth, so per-person risk would stop rising once the place was busier than one person makes it.

**The tuning effect to expect:** one putter on a three-man road sees a third of today's per-person rate, because fewer tubs pass. That is the honest model, and the retune absorbs it.

### 2.5 Everything else that reads a post

| Reader | Rule with a crew | Why |
|---|---|---|
| Effort output | Σ capability, sorted | 2.3 |
| Stiff lever speed (`crew_multiplier`) | The **strongest** `rate_multiplier` in the crew | A valve wheel turns at the speed of the hands on it, not the sum of everyone near it. Moot at capacity 1 |
| Slips | Each occupant slips from their **own** fate, as now. The lever slips if anyone does, and the **lowest id** among those who slipped picks the kind and the victim | P(slip) = 1 − Π(1 − pᵢ): a bigger crew makes more mistakes, which is true, and which animosity will lean on. No new draws |
| Governor and `lateness` | The single occupant | Capacity 1, enforced |
| Marshal, staffed, boarding checks | Anyone at the post | These are presence checks |
| Gauge reader | The **best** wits in the crew | A crew reads a dial as well as its sharpest member |
| Fatigue | Unchanged. Each person works at the lever's intent with their own capability | The lever is the instruction to everyone at it |
| Hazards, accident margin, breath, scorch | Unchanged | Already per person. A `stations:` hazard (a roof fall on the face) catches the whole crew, which is right |

### 2.6 Ratios between posts

`Roadway` wears on hewing − timbering. In worker-equivalents that reads **one timberer supports one hewer**. Today, with one of each, that is what it already means.

With five hewers, the ratio has to be a declared figure. Roadway gains `supported_per_worker:`, how many hewers' advance one timberer keeps up with. I don't have a sourced figure. A bord-and-pillar face had far fewer timbermen than hewers, so it's a tuning value with a first guess around 3. `ShotHole` reading hewing gets the same treatment where the units cross.

### 2.7 Determinism and state

- No new state. A crew is derived from each minion's `station`.
- No new draws.
- Every sum and every pick over a crew walks sorted ids.
- Nothing new to normalise on restore.

### 2.8 UI and projection

- **Panel:** `stations` entries gain `capacity:`. This is configuration, so the panel stays a pure function of the loadout.
- **Projection:** no new field. The client already has every minion's `posting` and `station`, so it counts the crew at each post itself.
- **Station dropdown:** each option reads **"Hewing 2/5"** from postings. A full post is shown disabled; the server still refuses, as now.
- **Lever strip:** an effort lever shows its crew as **working/posted**, for example "3/5, 1 walking". That makes "why is the face slow" answerable at a glance.
- **Refused posting:** check whether the console tells the player when `assign_minion` refuses for lack of room. If it says nothing, fix that in the same change.

---

## 3. The retrofit

Each existing post gets a capacity. Its per-worker figure is set so that **a full crew reproduces today's tuned output**, which keeps downstream balance (tubs, winding, screens) where playtesting left it. Workers who are better than the reference now push past it; an undermanned post now falls short of it.

Per-worker figures are game-compressed at `time_scale` 1. A real hewer cut roughly 0.1–0.15 kg/s **[gk]**; the proposed figures below run about 2× that. That's a deliberate fiat so a 30–60 minute match moves sensible coal, and the alternative is a lower per-worker rate with bigger crews.

**Steam engine** (2 seats):

| Post | Capacity | Notes |
|---|---|---|
| stoking | 1 | Room to raise it later on a bigger firebox ("double firing doors") |
| ash_raking | 1 | |
| blower | 1 | |
| oiling | 1 | |
| all valves | 1 | |

**Colliery** (10 seats on the lamp cabin, 14 on the pit-head baths):

| Post | Capacity (proposed) | Per-worker figure (current ÷ capacity) |
|---|---|---|
| hewing, `hand_picks` | 5 | 1.4 ÷ 5 = 0.28 kg/s |
| hewing, `coal_cutter` | 2 (cutterman and helper) | 5.6 ÷ 2 |
| haulage, `hand_putting` | 3 | 6 ÷ 3 = 2 kg/s |
| haulage, `rope_haulage` | 2 | 24 ÷ 2 |
| belt_attending | 2 | |
| timbering | 2 | Plus `supported_per_worker` (2.6) |
| boring | 1 | |
| packing | 3 | |
| sealing | 2 | |
| banking | 2 | |
| onsetting | 2 | |
| trapping | 1 | |
| furnace_stoking | 1 on `fire_basket` and `brick_furnace`; 2 on `double_furnace` | |
| greasing | 1 | |
| recapping | 2 | |
| reroping | 3 | |
| shotfiring | 1 | |
| man_winding | 1 | Governor |
| valves, refuges, quarters | 1 / as declared / unlimited | |

**What follows from the table:**
- The posts now want about 35 people at full strength against 10–14 seats.
- **Seats become the real constraint**, and choosing which posts to man is the game.
- Two tuning questions follow:
  - Does the lamp cabin's 10 rise?
  - Do the advance shifts (3 and 5 seats) still cover the opening move?

---

## 4. Specs

These are thin, zero-tick or a few ticks from constructed state.

**Crews:**
- Two competent hewers produce twice one hewer's coal. A third is refused at capacity 2.
- An ogre on the stoker exceeds the reference rate. This is the clip regression.

**Ratios and activity:**
- `Roadway`: five hewers and one timberer wear the road. Five and two at a ratio of 3 do not.
- Activity: one putter on a three-man road reads a third of a full road's activity.

**Readers:**
- Slips: a crew of two daft hands slips more often than one, and with the same fate count (draw count unchanged).
- The best reader at a post decides the gauge reading.

**Validation and UI:**
- Validation refuses a governor post above 1.
- Panel: `stations` carries `capacity`.
- The conservation specs must stay green with crewed posts.

**Updated rather than new:** the existing specs that relied on unlimited posting. Fit them to the physics, per the standing rule.

## 5. Docs touched in the same change

- [`nodes.md`](../reference/nodes.md) and `nodes/CLAUDE.md`: the effort unit and the end of the per-node clamps.
- [`tick.md`](../reference/tick.md) and `lib/reactor_sim/CLAUDE.md`: crews, and the slip and reader rules.
- [`build-an-operation.md`](../guides/build-an-operation.md) and `operations/CLAUDE.md`: `crew:` as a part stat, sizing ports for a full crew, and the governor rule.
- The `Minion#capability` comment becomes true again.
- [`current_progress.md`](../current_progress.md): unit 1 done, plus the retune list.

---

## 6. Questions for review

1. **The effort unit (2.3):** worker-equivalents, with the per-node clamps removed. Agree?
2. **Activity against the full-crew rating (2.4)**, so per-person risk tracks busy-ness. Or per worker, saturating?
3. **The retrofit rule (§3):** a full crew reproduces today's output. Or set per-worker figures from history and let output move?
4. **The capacities in §3:** any you want different?
5. **Seats:** raise the lamp cabin and the shifts now, or leave the scarcity in and tune after a playtest?
6. **`supported_per_worker`:** accept a tuning figure of one timberer per about 3 hewers, pending a source?

---

## 7. Review decisions

1. **Worker-equivalents are the unit, and the clamps come off.** An effort post caps nothing but
   its workers. If the work is bottlenecked further down the flow, that is the player's
   allocation problem, not a design flaw. Any effort post that seems to want a cap is flagged
   for review instead of being given one.
   - A worked conduit's own ports are unbounded too. Otherwise the conduit would cap the crew at
     one worker's rate at its own port.
   - Conduits are marked `worked: true`, and the build refuses an effort post on an unmarked
     conduit. That keeps the cap from coming back unnoticed.
2. **Activity is measured against the full-crew rating.** Incident rates are tuned up as wanted.
3. **Per-worker figures come from history**, and output is tuned to them. Today's figures were
   placeholder ballparks.
4. **Levers sum their workers too.** This replaces 2.5's "strongest hand" rule. A stiff valve
   with two people on it moves at the sum of their rates. Historically levers were often worked
   by several people (a heavy ladle, Akimov and Toptunov on a corroded valve). Capacity is still
   1 by default; a part raises it where the job allows. **Only a governor post is held to one.**
5. **The §3 capacities stand.** Upgrades adjust them later.
6. **Seats:** the fully staffed mine is a long-term upgrade path.
   - The advance shift starts at **5 at the face and 4 at the pit bottom**.
   - The lamp cabin rises to **13**, which leaves 4 up top.
   - The tech tree waits until more operations exist.
7. **`supported_per_worker` starts at 3**, to be re-sourced if a figure turns up.
   - **As built, the roadway wears on the coal actually cut**: what its `advanced_by:` node cut last
     tick, less `TIMBERED_KG_PER_S` (three hand hewers' worth) for each worker-equivalent of
     timbering. That replaces the comparison of two levers.
   - Ground opened is then measured in kg of coal. A cutter's face wants more timbermen than a
     hand face, without a second ratio.
   - The old rate converts exactly: 7.3 per hewer-equivalent at 1.4 kg/s becomes 5.2 per kg/s.

### Per-worker figures from history

| Post | Per worker | Source |
|---|---|---|
| Hewing, hand picks | **0.12 kg/s** (about 3 t per 7-h shift) | A Tyneside hewer cut 2.5–4 t a day, mid-century ([Tyneside living standards, 1836–62](https://etheses.whiterose.ac.uk/id/eprint/8752/1/MSc%20Dissertation%20WReO.pdf)) |
| Hewing, coal cutter | 0.8 kg/s each, crew of 2 | **[gk]**: an early chain or disc cutter undercut enough for 40–60 t a shift |
| Hand putting | 0.3 kg/s | **[gk]**: one putter kept two or three hewers supplied. Tubs were 3–10 cwt ([Children's Employment Commission evidence, 1842](https://hoodfamily.info/coal/putting.html)) |
| Stoking | 0.25 kg/s (unchanged) | A hand fireman peaked at about 5,000 lb/h (0.63 kg/s) on a locomotive. A stationary boiler fireman sustained well under that ([steamlocomotive.com](https://www.steamlocomotive.com/appliances/stoker.php)) |
| Rate-of-work posts (packing, sealing, boring, splicing, recapping, re-roping, greasing, trapping, oiling, raking, blowing) | Unchanged per worker | They were already per person, since one person worked them |
| Machine-limited posts (rope hauling, banking, onsetting, belt clearing) | Unchanged per worker | The machine sets the pace; more hands add more of it |

**What these figures do:**
- A full hand face now cuts about 0.6 kg/s, against the placeholder's 1.4.
- Mechanised haulage (rope 24 kg/s, belt grip 30) is far oversized for a hand face, which is
  historically true.
- **The belt's overfeed stall can no longer be reached from a hand face**, so belt fires need a
  new route into a stall. Flagged for the tuning list, not solved here.
