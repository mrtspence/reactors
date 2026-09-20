# Fatigue

> **Status: draft for review, 2026-09-18.** No code yet. The requirements come from
> `current_progress.md` item 6 and from two releases already designed against it —
> [`driven_transport.md`](driven_transport.md) §3.4 and [`crew_capacity.md`](crew_capacity.md) §2.

---

## 1. What is missing

`state[:fatigue]` has existed since the minions release. It is initialised to `0.0`, it survives a
snapshot, it multiplies into **both** things a minion is worth:

```ruby
# minion.rb — rate_multiplier and capability, identically
condition = state.fetch(:health) * (1.0 - state.fetch(:fatigue))
```

**Nothing anywhere advances it.** `minion_spec` says so out loud — *"there is no legitimate way to
arrive at a tired minion"* — and reaches one by merging a state hash by hand.

So the axis is wired, gauged and inert. That is the fifth instance of the pattern this codebase
keeps finding (four inert rate caps, the material ratings, `Cylinder#stress_per_second`, thermal
damage), and it has the same shape: complete, reachable, switched off.

**Two designed releases are blocked on it.**

- The **Hand Bellows'** flat-out range ([`driven_transport.md`](driven_transport.md) §3.4). Its
  upper travel is 0.75–1.0 kg/s against a sustainable 0.25, and *"until something advances
  `state[:fatigue]`, working flat out is free"* — which would reintroduce exactly the unpriced
  power that document exists to remove.
- The **Crew Quarters'** `recovery_rate` ([`crew_capacity.md`](crew_capacity.md) §2), declared on
  the part so the quarters need not be reopened, and read by nothing.

---

## 2. The law

### 2.1 Effort is subjective, and that is the whole idea

The rule `minions.md` §9 proposes, and it is the right one:

> Fatigue accrues with **`intent ÷ capability`**, not with the lever's position. Working somebody
> past what they can manage tires them; a strong worker coasting at a setting that is killing a
> weak one does not.

That single choice is what makes the stat layer matter beyond throughput. A lever at 80 is one
number; what it costs is a different number for every person who stands there.

```ruby
load    = demand / capability                      # demand is the lever as a 0..1 fraction
accrual = station.exertion * (load ** EXPONENT) / endurance
```

**`EXPONENT = 2.0`**, because superlinear is the requirement and quadratic is the cheapest thing
that satisfies it. Half effort costs a **quarter**, which is what makes sustainable work genuinely
sustainable and working flat out a decision rather than a default.

### 2.2 `load` must be clamped, and the reason is a real singularity

`capability` already contains `(1 - fatigue)`. So as a minion tires, their capability falls, their
`load` rises, and they tire faster — **a runaway, and a wanted one**: a tired person does work
harder to achieve the same thing. It is the hot-box shape one layer out.

But it is a runaway with a pole. At `fatigue → 1.0`, `capability → 0`, `load → ∞`.

```ruby
LOAD_CEILING = (0.0..4.0)
```

Same constant and same reasoning as `Tick::HAZARD_SCALE`: four times over-matched is already far
past anything the design cares to distinguish, **so this bounds a bug without bounding the
design.** A severely injured minion has every derate at `0.0` and therefore capability exactly
zero, which is how the pole gets reached in practice rather than in theory.

> Guard the zero-demand case by returning early. `0.0 / 0.0` is `NaN`, and `NaN.clamp` raises —
> a lever at rest must not be able to throw.

### 2.3 Recovery is continuous, and nets against accrual

```ruby
fatigue' = (fatigue + (accrual - recovery) * dt).clamp(0.0, 1.0)
```

Both terms always apply and net out. The alternative — "accrue while working, recover while not" —
puts a discontinuity at demand zero and makes a lightly-worked station behave like an idle one.
Netting is continuous, and it makes *light work is sustainable, hard work is not* fall out of the
arithmetic rather than being a special case.

**Recovery is a property of where you are standing**, declared on the control point:

| where | recovers | why |
|---|---|---|
| an **effort** station | `0.0` | you are still at the fire |
| any other station (a valve) | `BASE_RECOVERY` | standing by, not resting |
| **no station** | `BASE_RECOVERY` | off post |
| the **Crew Quarters** | its part's `recovery_rate` | the seam `crew_capacity.md` already cut |

**This ships without the quarters.** A valve is somewhere to stand down to, so fatigue is a
complete mechanic on the steam engine today, and the quarters raises the ceiling rather than
enabling it. That matters for ordering — see §6.

### 2.4 The numbers, and what they mean in minutes

`exertion:` is declared as **fatigue per second at `load` 1.0** — a competent, unaided human with
the lever hard over. Its reciprocal is the honest reading:

| station | `exertion` | flat out, spent in | at load 0.3 |
|---|---|---|---|
| `:stoking` | `3.3e-3` | **300 s** | ~55 min |
| `:ash_raking` | `2.8e-3` | 360 s | ~66 min |
| `:oiling` | `1.1e-3` | 900 s | ~2.8 h |
| `BASE_RECOVERY` | `1.67e-3` | *spent → fresh in 600 s* | — |

> **Calibrate against the game's clock, not against a real shift — and check which clock.** The
> first draft of this table was built on `time_scale` 40 and `dt = 10 s`. **The steam engine runs
> at `time_scale` 1.0**, deliberately — `definition.rb` says a steam engine is a fast machine that
> wants no time compression — so `dt` is **0.25 s** and the whole reference cold start is about
> seven simulated minutes. The original figures were 40× too slow: a fireman would have finished
> raising steam 4% tired and nothing would ever have tired anybody.

The two ends of the range are worth reading as a pair. Measured on the engine, both stoking flat
out:

| | spent at | |
|---|---|---|
| the reference hand (capability 1.0) | ~t=850 | about 3.5 min |
| the standin day-labourer (capability 0.41) | **t=75** | about 19 s |

The labourer's figure is faster than `load² = 5.95×` alone predicts, because the runaway compounds
it — and that is the stat layer finally having consequences in both directions.

> **These are the first guesses and are labelled as such.** Unlike the heat figures they are not
> derived from anything physical, and §7 stages a sweep. What the sweep must not change is the
> *shape*: superlinear, subjective, bounded.

---

## 3. Where it runs — phase 6c, and the existing TODO is wrong

`tick.rb:119` says:

```ruby
# TODO: fatigue accrual belongs in phase 0, alongside the actuation entropy it would feed.
```

**Recommended: a new phase 6c, immediately after `endanger`.** Three reasons, in increasing order
of how much they cost to get wrong:

- **The effort actually demanded this tick is settled at phase 1**, in `control_values`. Accruing
  at phase 0 charges people for last tick's levers, which is a tick of skew for nothing.
- **`endanger` already writes `minions`.** A second writer at phase 0 means two producers of one
  state key and a merge rule between them; 6c consumes 6b's output and there is one chain.
- **A minion carried out in 6b has `station: nil` on the same tick** and must stop accruing
  immediately. Ordered the other way, somebody stretchered off the footplate keeps shovelling
  until the next tick.

The TODO's premise — *"alongside the actuation entropy it would feed"* — assumed fatigue would be
rolled. **It draws no entropy at all**, exactly as the Danger Check does not, so there is nothing
to sit alongside. Delete the TODO with the change.

**Alternative: fold it into `endanger` and rename the phase.** Rejected — injury is event-driven
and episodic, fatigue is continuous and every-tick. One method doing both reads as a coincidence
of timing rather than a shared idea.

---

## 4. Decisions

### 4.1 How the modifiers are declared

`current_progress.md` item 6 asks for modifiers *"declared the way `failure_hazards` is — a table
on the thing inflicting it, resolved through stations, scaled by a figure the event carries."*

**That precedent is the wrong one, and the third clause is why.** There is no event. A hazard
table exists because a failure is a discrete thing that happens at an instant and has a magnitude
worth reading off the record. Fatigue is a rate, every tick, for everybody posted — and the engine
has a hard rule about exactly that:

> **Nothing that happens every tick may be an event.** (`lib/reactor_sim/CLAUDE.md`)

So the shape to copy is **`ControlPoint#effort`**, not `Node#failure_hazards`. It is already "a
table on the thing inflicting it, resolved through stations" — the station is the inflicter — and
it is already validated at construction. `exertion:` and `recovery:` sit beside `effort:` and
`aided_by:` and need no new resolution machinery at all.

- **Pros.** No new concept; one declaration site per station; validated at build like the effort
  weights; nothing added to the hot path that is not already looked up there.
- **Cons.** Departs from the letter of the recorded requirement. Stated here rather than done
  quietly.
- **Tradeoff accepted:** the requirement's *intent* — the machine knows what each job costs — is
  met exactly. Only the borrowed vocabulary changes.

### 4.2 The `endurance` stat

**The sixth stat, `1.0` is the human norm**, and it means resistance to fatigue. It divides the
accrual rather than multiplying capability, because **what you get done and what it costs you are
two statements about a person** — an ogre who shifts coal twice as fast and tires twice as fast is
expressible only if the two are separate.

Adding to `Sheet::STATS` is not a one-line change, and the cost is worth stating:

| touched | why |
|---|---|
| `Sheet::STATS` | the list itself |
| `Content::REQUIRED_ARCHETYPE_KEYS` | derived from `STATS` — **every archetype must now declare it** |
| `content/archetypes/races.yml` | human, elf, kobold |
| `spec/support/reference_crew.rb` | the flat-1.0 fixture |
| `content_spec`, `minion_spec` fixtures | the `human` helper spells all five |

**This fails loudly, which is the good case.** `content_spec` already refuses an archetype missing
any stat, so the day `endurance` joins the list every archetype raises at boot until it is
declared. Compare the inert-off-switch pattern in §1 — this is the opposite, and deliberately.

> **The trap: `Sheet::MIN_STAT` is `0.0`, and endurance is a divisor.** Enough bulky kit clamps it
> to exactly zero and the accrual divides by it. Needs `Fatigue::MIN_ENDURANCE = 0.1` at the point
> of use — a floor on the reader, not a second clamp in `Sheet`, because `MIN_STAT`'s reasoning
> ("negative strength is a different machine") is about the sheet and this is about one consumer.

Proposed figures, offsets from the human 1.0:

| archetype | endurance | reading |
|---|---|---|
| human | 1.0 | the norm, by definition |
| elf | 0.85 | sharp, not hardy — consistent with strength 0.75 and toughness 0.7 |
| kobold | 0.7 | the bottom of the labour market stays at the bottom |

### 4.3 Endurance penalties on equipment

**Free once the stat exists**, and the point of the stat beyond the obvious. `Sheet.add_stats`
already folds signed offsets from the equipment layer, so heavy kit says it in one line:

```ruby
Equipment.register(:fettlers_gloves, slot: :gear, ...,
                   stats: { dexterity: -0.1, endurance: -0.1 })
```

*"This armour tires me"* is a trade-off the three-slot system could always express and has never
been able to say. Candidates: the fettler's gloves and the leather apron (bulky), and a new heavy
gear item whose whole pitch is protection at the cost of stamina — which is the first piece of kit
in the catalogue with a genuine downside rather than a rounding error.

### 4.4 One event, on a transition

A minion reaching `fatigue >= SPENT` is a **transition**, and transitions are what events are for.
`:minion_spent`, `severity: :warning`, carrying the person and the station — the same split
`minion_hurt` makes, because the injury list belongs to a person and the post outlives them.

**With hysteresis**, re-armed below a lower threshold. `ReliefValve` announced itself 20 times in
40 ticks without it, and a minion hovering on the threshold would do the same.

- **Cons.** `Event::TYPES` is a closed vocabulary and a new entry is a delivery-tier change too.
- **Alternative considered:** no event, and let the panel show the number. Rejected — *"worked the
  crew to a standstill"* is exactly the kind of thing the progression tier is built to notice, and
  a value on a gauge is not something a consumer can key an achievement to.

---

## 5. What this must not foreclose

- **The quarters' `recovery_rate`.** The station-declares-recovery seam in §2.3 is shaped so the
  quarters is a bigger number in an existing field, never a new mechanism.
- **The bellows' flat-out range.** `driven_transport.md` §3.4 needs the top of a lever to be
  expensive rather than forbidden. Nothing here may cap a lever's travel.
- **Injury and fatigue stay separate and multiply.** `minions.md` §10 is explicit: *"do not invent
  a second condition axis"*. They already multiply through `condition`; keep it that way.
- **Fatigue changing how *likely* an accident is — never how bad it is.** Deferred, and the
  distinction is the whole of why.

  A tired worker gets their hand caught in the belt. **The belt does not then care how tired they
  are.** So fatigue belongs on the *incidence* of an injury and not on its severity, and the
  obvious-looking seam is the wrong one: `Injury.resistance` reduces the **bite**, so wiring
  fatigue into it would say a tired body is mangled worse by the same blast, which is not the
  claim anybody wants to make.

  This release therefore leaves `Injury` untouched. **A rate-based / probabilistic injury release
  is coming and will be designed by Tim**, after the currently open work closes; it is what
  introduces "an accident happened" as a thing with a likelihood, at which point fatigue is one of
  its inputs and a natural one. Build nothing here that assumes every injury originates in a
  `failure_hazards` table — that is today's only route into harm, and it is not the only one there
  will be.
- **Per-station recovery being a thing a part can buy.** Already true via `stats:`; do not
  hard-code a station's figure where a part could supply it.

---

## 6. Ordering, and one honest caveat

[`crew_capacity.md`](crew_capacity.md) §3 says the fatigue release *"should come after this, not
before"*, because swapping seats is only meaningful when there are fewer people than posts.

**That argument is about how interesting fatigue is, not about whether it works.** Fatigue is
self-contained: it needs a station to stand at and a station to stand down to, and the steam
engine has both today. Shipping it first means the steam engine gets a tired fireman who can be
moved to a valve to recover — a real, complete mechanic — and the quarters later turns that into a
scarcity problem.

**The cost of this order, stated plainly:** until crew capacity lands, the roster fills every role,
so there is always somebody to swap in and the decision is softer than designed. Fatigue will look
under-tuned until capacity makes posts scarce, and **the balance sweep in §7 should therefore be
run after capacity lands, not as part of this release.**

---

## 7. Verification

- **Determinism.** Fatigue is a pure function of state and levers, draws no entropy, and must
  replay bit-identically. The standing determinism spec covers it once a run tires somebody.
- **Snapshot round-trip.** Fatigue is a `Float`, so it is **not** the symbols-as-values trap —
  worth asserting once precisely so the next reader does not go looking for a normalisation that
  should not exist.
- **Order-independence.** 6c reads 6b's output and the frozen control values; two minions at two
  stations must settle identically whatever order they are visited in.
- **The subjective claim, as a ratio.** The same station at the same lever, worked by the
  reference hand and by a day-labourer, tires them at rates whose ratio is `(1/0.41)²` — assert
  the ratio, never pinned figures.
- **Light work is sustainable.** A station held at low demand reaches a steady state below 1.0
  rather than creeping to spent over a long run. This is the one that says §2.3 netted correctly.
- **The runaway terminates.** Drive a minion to `fatigue` 1.0 and assert it stays there, finite,
  with no `NaN` and no `Infinity` anywhere in the state. This is the `LOAD_CEILING` assertion.
- **A spent minion delivers nothing**, and therefore an effort station they are posted to produces
  zero — which is `capability` already working, asserted end to end for the first time.
- **Recovery at a valve**, from spent back to fresh, in the neighbourhood of the declared rate.
- **Zero demand cannot throw.** The `NaN.clamp` guard, asserted directly.
- **No new events at the tick rate.** `event_pipeline_spec` already asserts *fewer than 20 records
  on a cold start*; `:minion_spent` with hysteresis must not move that number much.
- Full suite in the background at each stage boundary — **check the example COUNT.** It is
  **661** today.

---

## 8. Staging

| | |
|---|---|
| **A** | **`endurance` into `Sheet::STATS`**, the three archetypes, the fixtures. Content and validation only — nothing on the tick path, and the loud failure in §4.2 is the proof it landed. |
| **B** | **`ReactorSim::Fatigue`** — the law, the constants, the clamps — plus `ControlPoint#exertion` / `#recovery` / `#demand`, validated at build. Pure module, fully specced, called by nothing. |
| **C** | **Phase 6c wired into `Tick`**, the TODO deleted, the steam engine's three stations given their `exertion:` figures. This is the tick where a minion first tires. |
| **D** | **Equipment endurance penalties** and the new heavy gear item. Catalogue only. |
| **E** | **`:minion_spent`** with hysteresis, into `Event::TYPES`, plus `crew_view` carrying fatigue so the panel can show it. Delivery tier included — the crew panel is where this is legible. |
| **F** | **The balance sweep**, recorded as a table. **Deferred until crew capacity lands**, per §6. |

---

## 9. As built

Landed 2026-09-18, stages A–E. **F is deliberately not done** — the sweep waits on crew capacity,
per §6.

### What the plan got wrong, and the measurements that said so

**The time base.** §2.4 was first written against `time_scale` 40 and `dt = 10 s`. The steam
engine runs at **`time_scale` 1.0**, deliberately — `definition.rb` says a steam engine is a fast
machine wanting no time compression — so `dt` is **0.25 s** and the whole reference cold start is
about seven simulated minutes. Every `exertion:` figure was **40× too slow**: a fireman finished
raising steam 4.3% tired. Caught by running the thing rather than by reading it.

**The runaway is worth three times what it looks like.** `capability` contains `(1 - f)`, so
accrual is `K/(1-f)²`, and integrating `(1-f)²df = K dt` gives

```
t = (1 - (1-f)³) / 3K        →        time to spent = 1/3K
```

**A third of what a flat rate would take, at every load.** Predicted 824 ticks against **832
measured** on the engine, so this is the arithmetic and not an estimate of it. The consequence for
anybody setting a figure: **`1/exertion` is nominal and the real answer is `1/(3·exertion)`.**

### Shipped figures

| station | `exertion` | flat out, actually spent in |
|---|---|---|
| `:stoking` | `1.1e-3` | ~300 s |
| `:ash_raking` | `9.3e-4` | ~360 s |
| `:oiling` | `3.7e-4` | ~900 s |
| `BASE_RECOVERY` | `2.2e-3` | *spent → fresh in 455 s, no runaway, so literal* |

Measured on the engine, both stoking flat out: the reference hand is spent around **t=400**, the
standin day-labourer at **t=75** — faster than `load² = 5.95×` alone predicts, because the runaway
compounds on top of it.

### The consequence nobody designed, and it is the good kind

**One fireman cannot hold the firehole.** `injury_spec`'s boiler-burst example fired at
`stoking: 70` for 7000 ticks to blow a drum and hurt somebody; it now goes: spent at **t=832**,
capability zero, **the fire dies** (firebox 918 K → 319 K), and the boiler cools for the remaining
six thousand ticks with nobody hurt. Nothing was wired to make the fire go out — an unmanned
effort station simply delivers nothing, and a spent minion is unmanned in all but name.

That is the mechanic working, and it is exactly the scarcity `crew_capacity.md` is about.

> **It also means machine specs needed a decision, and the right one was not to rotate crew.**
> `ReferenceCrew` now sets `endurance: TIRELESS` (1e6). **`endurance` divides accrual and never
> enters `capability`**, so an arbitrarily large value moves no throughput baseline whatsoever
> while keeping a spec about a machine measuring the machine. A spec about fatigue posts its own
> people, exactly as `injury_spec` and `crew_spec` already do.

### What is deferred, and by whom

**Fatigue as a modifier on how LIKELY an accident is** — never on how bad it is; see §5. That
needs the probabilistic injury model, which **Tim is designing**, and it does not exist yet.
`Injury` is untouched by this release.
