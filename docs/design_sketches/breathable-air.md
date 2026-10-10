# Breathable air

> **Stages A, B and C are built, and D in part** (apparatus is metered; nobody can be carried
> out yet). What follows is the design as reviewed, kept because the
> reasoning is the point; `docs/current_progress.md` records what actually landed and what
> measurement it landed at. Three things came out differently and are worth reading against the
> text below:
>
> - **Places declare their nodes**, rather than `Node#place` declaring its place. Threading a
>   kwarg through fourteen node classes was a lot of churn for an attribute one operation uses,
>   and the `Layout` index is identical either way.
> - **The haulage road is in no place at all.** §5 argued a node belongs to a room; a conduit
>   joining two rooms belongs to neither, and putting it in the district made a roof fall miss
>   the putter — the person it was most likely to kill.
> - **There is no `Perils::Suffocation`.** Bad air's effect is a fatigue rate rather than a
>   Danger Check, so it lives in phase 6c beside the work that shares its pool. The place key in
>   `endanger` is built and used by real failure hazards; the ambient-peril sweep waits for a
>   hazard whose effect actually is a bite, which is heat.

**The absence of air is a permanent, ambient hazard, and the engine has no way to express one.**
Every hazard today is *triggered*: phase 6b builds its exposure map out of `wear_events`, so
somebody is hurt because a part broke on that tick. Nothing in the engine can say "this place is
bad to stand in, continuously, and has been for ten minutes."

That is why afterdamp was left owed at the end of the mine's stage F. It is also why this wants a
general answer rather than a mine-shaped one: bad air is the first of a family — heat, cold, water,
noxious gas, radiation, depth — that all share the shape *"where you are is hurting you"* and share
nothing else.

The content answer is small: **air gets a `breathable` tag, every other gas asphyxiates by
displacement, a few poison air they have barely diluted, and the effect is fatigue.** That is most
of §1–§4 and it is nearly free.

The structural answer is not small, and it is the reason this sketch is worth reading twice.
**Hazards are keyed by station today, and a station is the wrong thing to key them by** — the
fireman is not hurt because of the job he was doing, he is hurt because he was standing next to a
boiler when it let go. Bad air is simply the first hazard that cannot be expressed in the old key
at all, because it has no task attached. So this release makes **places first class and nodes
belong to them**, which is §5 and which is a larger change than the breathing is.

---

## 1. The argument that settles it before we start

**Afterdamp is already in the box.**

```yaml
firedamp_combustion:
  consumes: { firedamp: 1.0, air: 17.2 }
  produces: { flue_gas: 18.2 }
```

`flue_gas` is tagged `[gas, exhaust]`. It is produced by every combustion reaction in the game,
it already fills the district when the gas goes up, and it is already conserved, advected,
ventilated and reported. The only reason it is not lethal today is that **nothing asks whether the
people standing in it can breathe.**

So the moment `air` carries a `breathable` tag and one function asks "what fraction of this
volume is breathable", afterdamp exists — with **no new resource, no new reaction, and no new
content of any kind.** A firedamp explosion consumes 17.2 kg of air per kilogram of gas and hands
back 18.2 kg of something nobody can breathe. That is exactly what afterdamp is, and the model
already does it; we have simply never read the answer.

That is a very strong argument for doing it by tag rather than by any bespoke mechanism, and it is
the reason to take the proposal's framing more or less as offered.

---

## 2. What already exists

| Need | Exists | Where |
|---|---|---|
| Resource tags as an open vocabulary | Yes, and already used for two distinct purposes (transport, and `oxidiser` for reactions) | `content/resources/*.yml`, `content/CLAUDE.md` |
| Per-node contents, by resource, with density | `Holds#parcels`, `Parcel.volume_m3`, `content.density` | `concerns/holds.rb`, `physics/parcel.rb` |
| A volume for every holder | `volume_m3` is required config on `Holds` | `concerns/holds.rb` |
| Where a person is | `minion.place(state)`, advanced in phase 6d | `minion.rb`, `tick.rb:802` |
| Where a lever is | `ControlPoint#place`, and `Layout#place_of` | `control_point.rb`, `graph/passage.rb` |
| A pure, entropy-free module over a minion's state hash | Two of them, `Fatigue` and `Injury` — the template to copy | `fatigue.rb`, `injury.rb` |
| Graded harm that degrades work before it removes somebody | `Fatigue`, including the runaway and `minion_spent` | `fatigue.rb` |
| Sudden harm that fires once, on a transition | `Injury.check`, resilience rolled at `initial_state` | `injury.rb` |
| Gear that mitigates a named hazard | The `:"#{tag}_resistance"` convention — no engine change to add a kind | `injury.rb:resistance` |
| Gear that gates a capability to zero | `gated_by:`, multiplied, so a missing tag is a zero | `control_point.rb`, `minion.rb:gate` |
| An instrument that already reports the district's air | The flame cap, `Sources::Fraction(:district, :firedamp)` → `Prose` | `operations/mine/panel.rb` |

**Almost nothing here needs inventing.** The work is three small joins and one new pure module.

---

## 3. Four decisions

### D1 — How a gas declares what it does to a person

Three categories, and the proposal names all three correctly.

| Category | Meaning | Examples |
|---|---|---|
| **Breathable** | Sustains life. Exactly one substance. | `air` |
| **Simple asphyxiant** | Harmless in itself; kills by taking up room. The default for every gas. | `firedamp`, `flue_gas`, steam, `blackdamp` |
| **Potent asphyxiant** | Poisons air that is still mostly air. | `whitedamp` (CO), `stinkdamp` (H₂S) |

**Options for the declaration:**

**(a) `breathable` tag only; everything else is a simple asphyxiant by omission.**
*Pros:* one word of content; correct for every gas we have today; the failure direction is safe
(a new gas you forget to think about is an asphyxiant, which is the truth). *Cons:* no way to say
whitedamp.

**(b) `breathable` tag, plus a `toxicity:` field on the resource — a fraction above which the
mixture is unbreathable however much air is present.**
*Pros:* covers all three categories in one line each; a number rather than a tag, because potency
is a quantity (CO is dangerous at 0.04%, H₂S at 0.01%); the field is absent on almost everything.
*Cons:* a second non-transport use of the resource schema, so `add-content.md` and
`content/CLAUDE.md` both grow a row.

**(c) A whole `effects:` block on the resource** — toxicity, irritancy, corrosivity, flammability.
*Pros:* the obvious long-term home. *Cons:* designed from one example, and the only entry we can
fill honestly today is toxicity. Premature.

> **Recommend (b).** `breathable` on `air` and nothing else; `toxic_fraction:` on the two damps that
> earn it, absent everywhere else. It is two schema additions total and it closes the category the
> proposal explicitly names as the second case. **(c) is what (b) grows into** when a second effect
> arrives, and renaming a field is cheap.

**Note the precedent this sets and say it in `content/CLAUDE.md`:** tags govern *transport*
(the rule the dust work established) and now also *physiology*. That is a third use — transport,
reactions (`oxidiser`), physiology — and the file should name all three rather than let a reader
discover the exception.

### D2 — How a place knows what it is breathing, and what that turns out to mean

**Settled: nodes belong to places, and this is the release that does it.**

Minions live in **places** (`:bank`, `:pit_bottom`, `:district`). Air lives in **nodes**
(`:atmosphere`, `:pit_bottom`, `:district`). These are two namespaces that overlap in the mine by
coincidence and are not the same thing — `:bank` is a place with no node, `:atmosphere` is a node
with no place. A breathability check has to join them, and the cheap joins (name convention, a
side-map of place → air node) all buy the same thing: one more parallel list to keep in step, and
a silent "no data → safe" when it drifts.

They are also the wrong answer to a larger question, which is §5.

**The shape:**

```ruby
Place.new(id: :district, label: "The District")   # declared, not derived from passage endpoints
Nodes::Vessel.new(id: :district, place: :district, ...)
```

- **`Node` gains `place:`, defaulting to `nil`** — the same pattern, one layer down, as
  `ControlPoint#place`, which already defaults to nil and already means "can be worked from
  anywhere". That symmetry is the argument: it is a decision the codebase has already taken once
  and is happy with.
- **`Place` becomes a declared object** rather than a symbol scraped out of passage endpoints, so
  it has somewhere to hang a label for the UI and whatever a place wants next.
- **A place's breathable volume is derived from its membership**, not declared twice: the
  gas-holding node in that place is the one you breathe. Exactly one is unambiguous; **two refuses
  the build** with a message telling you to declare `breathes:` explicitly; none means it is not a
  place anybody can breathe in, which the build should also refuse for a place a minion can stand.
- Things that are not rooms have `place: nil` and always did. The **seam is rock, not a space**;
  so is `dust_source`. That keeps the district's air unambiguous without a special case, and it is
  the honest description anyway.

*Costs, eyes open:* it touches `Passage`, `Layout#derive_places`, `Operation#build_routing` and
every mine node builder. **It does not touch minion state at all** — `place` is already there and
already survives `restore`, `crew_view` and the delta protocol — so the four-edit trap list from
`mine.md` §4.3 does not apply. This is build-time work, which is the cheap kind.

### D3 — Where the check runs, and what it drains

The engine's sharpest relevant rule, from `Fatigue`'s own comment: **"nothing that happens every
tick may be an event."** So the continuous part cannot announce itself, and only a transition can.

**(a) Extend phase 6b `endanger` to grind `resilience`.**
`Injury` already documents two routes into harm — *accumulation* ("a long shift in a hot place
grinds resilience down") and *overload* — and **accumulation has never had a client.** This is it.
*Pros:* maximum reuse; the `_resistance` tag convention, severity escalation, the hurt event and the
`stood_down` consequence all come free. *Cons:* resilience **does not regenerate.** Five minutes in
foul air you walked out of would permanently mark a minion, which is wrong: you recover from nearly
suffocating. And `Injury.check` fires on transitions, so it cannot express the graded impairment
that comes *before* collapse.

**(b) Extend phase 6c `tire` — bad air is a third term in `Fatigue.advance`.**
```ruby
rate = accrual(...) - recovery(control) + suffocation(...)
```
*Pros:* everything the mechanic needs is already in this pool. Fatigue **derates capability**, so a
man in bad air works worse *before* he drops — which is the whole texture of it. It **regenerates**,
so walking into good air is recovery with no new code. `endurance` becomes the thing that decides
how long you last, which is exactly the right stat. And `minion_spent` already fires as a warning,
giving the player a free early signal that something is wrong in a district. *Cons:* `Fatigue`'s
doc-comment is built entirely around *"effort is subjective"* — station, lever, capability. Bad air
is a property of **where you are**, not what you are doing, so it muddies a clean concept if it is
folded into `accrual`. Added as a separate, additive term it does not.

**(c) A new phase 6e `breathe`.**
*Pros:* clean separation, nothing else changes. *Cons:* a fifth sub-phase of 6, and it would write
`minions` a third time in one tick — 6b, 6c and now 6e — each needing a merge discipline with the
last. The phase list is the most load-bearing thing in the engine; adding to it for one mechanic is
expensive.

> **Recommend the hybrid: (b) for the grind, (a) for the collapse.**
>
> - **Suffocation accrues fatigue**, as an additive term in `Fatigue.advance`, computed by a new
>   pure module `Breath`. Graded, reversible, station-independent, and it degrades work on the way
>   down. **`endurance` is the clock** — it is already the fatigue divisor and it is the stat that
>   means stamina, so the two halves of the mechanic agree about who lasts.
> - **Collapse is an injury**, fired through `Injury` when `fatigue >= 1.0` **and** the air is still
>   bad. That conjunction matters: a stoker flat out also reaches 1.0 and is merely spent. Being
>   pinned at the ceiling *in foul air* is a different thing, and it is a transition, so it is
>   event-legal.
> - The collapse rides into `endanger` as an **ambient hazard** (see §4), so it gets severity
>   escalation and the `stood_down` clearing of station and posting for free.

#### The two tiers, and why the clock between them is the point

**`severe` is out for this match; `mortal` is out for the next one too.** `Injury::MODES` already
has exactly that split and needs no change — `mortal` carries `lasting: true`, which is the
injury-list tier, "revived and missing a shift" rather than dead.

**The dwell between them is what makes rescue worth doing.** Collapse straight to `mortal` and
nobody would ever go back for anybody; the clock is the entire mechanic.

`Injury.check` will not produce it on its own. Grinding `resilience` to zero gives `:severe`, and
every bite after that re-proposes `:severe`, which `Severity.escalate` correctly refuses to
announce twice. Reaching `:mortal` needs a bite of `MORTAL_BITE` (2.5), and a steady hazard never
grows one.

So the collapsed minion needs a second accumulator, and it should be **the same shape as fatigue,
just past the end of it**: once down, `Breath` fills an `asphyxia` counter 0 → 1 at the
deficit-driven rate, and at 1.0 delivers a single `MORTAL_BITE` hazard. That buys three things
for one number:

- **It drains back down in good air.** Fixing the ventilation *is* the revival, with no separate
  mechanic, and a man pulled back from 0.9 is a man who nearly died.
- **It is a rescue timer the UI can show**, because it is a fraction and not a hidden countdown.
- **It reuses the one rule that must never drift** — `Severity.escalate` — rather than inventing a
  second escalation path beside it.

**What falls out, and it is correct rather than a gap:** `Injury.apply_mode` clears the station and
the posting but **does not move anybody.** A collapsed minion lies exactly where they fell, in the
same air, and the clock keeps running. The player's counterplay is the fan — which is historically
precisely what saved people. The *other* counterplay, somebody going in and carrying them out, is
the mine's first real rescue mechanic and wants its own pass.

### D4 — Stratification: no

**Breathability is the bulk concentration of the volume, and nothing else.** No head height, no
assumed shape, no density gradient, no second gas solve.

This is the right call for three reasons that all point the same way. A node already has **one**
temperature and **one** pressure, so a partial stratification for breathing alone would be a
special case in a model that is otherwise ruthlessly lumped. **Afterdamp — the thing actually
owed — is a well-mixed hazard**: the explosion converts the whole district's air at once and there
is no clear layer to stand above. And any head-height model needs a shape for the space, which
means either a fiction (a cube, which is wrong by a factor of five for a low, flat district) or
real geometry on every node, which is exactly the overhead this mechanic must not introduce.

What it costs is one piece of drama — blackdamp pooling in the sumps and dips, firedamp collecting
in the roof cavity — and that is content rather than physics. If we want it later, the cheap way in
is a **per-place** declaration ("the sump is a dip; heavy gases concentrate here") multiplying the
concentration a person there sees. That is a game-design lever a player can reason about, it uses
the `density_kg_per_m3` already on every resource, and it needs no gradient solve. **Leave `Breath`
taking a fraction it does not compute itself** and that stays a one-call-site change.

---

## 4. The recommended shape

### The general mechanism: hazards get a second source, and a better key

`Tick#endanger` derives its exposure map from exactly one source, keyed by station:

```ruby
exposure = hazards_from(wear_events)      # keyed by STATION
```

It needs two sources and a second key:

```ruby
exposure = hazards_from(wear_events)        # by place where a node has one, by station otherwise
             .merge(ambient_hazards(ctx))   # always by place
             { |_, a, b| combine(a, b) }
```

`ambient_hazards` sweeps the **perils** — small pure objects, each answering *"what does this place
do to a person standing in it this tick"* — and returns the same `{ severity:, tags:, sources: }`
shape `hazards_from` returns. `endanger` looks each minion up by their `place` and then by their
`station`, and `Injury.check` never learns the difference.

**This is the whole generalisation, and it is about fifteen lines.** It answers *"lots of other such
hazards to come"*: heat in a Cornish level, cold, water rising in a dipping road, a roof that has
been creaking for ten minutes. Each is a new peril object and **no engine change at all**.

Crucially it generalises the *source* and the *key* of a hazard, not its *effect*. Effects genuinely
differ — gas takes your breath, heat takes your strength, water is simply fast — and a framework
that tried to unify those would be a framework designed from one example.

```
lib/reactor_sim/place.rb                  a declared space; nodes and control points belong to one
lib/reactor_sim/perils/suffocation.rb     the first peril
lib/reactor_sim/breath.rb                 the pure physiology module, beside Fatigue and Injury
```

### `Breath`, the module

Shaped exactly like `Fatigue` and `Injury`: pure, no entropy, over a state hash it does not own.

```ruby
module Breath
  # Air is ~21% oxygen, so displacing air displaces oxygen proportionally. The thresholds are
  # the standard ones divided by that: 19.5% O2 is the safe floor, 16% is impairment, 10% is
  # unconsciousness in minutes.
  SAFE     = 0.93   # below this, breathing starts to cost
  SEVERE   = 0.48   # below this, it is quick

  # Flat out in clean air is ~20 minutes to spent. Total displacement is ~45 seconds, which
  # is the whole point: bad air is not hard work, it is a different order of thing.
  MAX_RATE = 2.2e-2

  EXPONENT = 2.0    # superlinear, so slightly foul air is survivable and bad air is not

  # An oxygen reserve varies between people by perhaps a factor of two, never by more. Clamped
  # so that a TIRELESS fixture cannot be immune to suffocating.
  RESERVE = (0.5..2.0)
end
```

- `Breath.breathable_fraction(parcels, content)` — the **volume** fraction tagged `breathable`.
  Volume, not mass, because it is displacement that suffocates and 200 kg of methane takes up
  vastly more room than 200 kg of flue gas. `Parcel.volume_m3` already exists.
- `Breath.poisoned?(parcels, content)` — any resource whose volume fraction exceeds its declared
  `toxic_fraction:`. Short-circuits the whole thing to zero: whitedamp does not need to displace
  anything.
- `Breath.rate(fraction, minion)` — `0.0` at or above `SAFE`, rising superlinearly to `MAX_RATE`
  at zero, divided by the clamped reserve.
- `Breath.gated?(minion)` — `unbreathing` returns true and skips everything. A golem does not
  breathe; that is binary and belongs in a gate, not in a resistance.
- `respirator` is a **fraction**, scaling the rate — it is apparatus, and apparatus is imperfect.
  Its historical character is that it **runs out**, which is the hard limit on how far a rescue
  team can go. Note the hook; do not build the duration yet.
- `Breath.asphyxiating(state, rate, dt)` — the post-collapse clock of D3, filling and draining on
  the same deficit.

### One tick, end to end

```
phase 5   react      — the district explodes; 17.2 kg of air per kg of gas becomes flue_gas
phase 6a  stress     — the roadway's roof comes in
phase 6b  endanger   — hazards_from(wear_events)  →  the roof fall, by PLACE
                       ambient_hazards(ctx)       →  suffocation, by PLACE
                       resolved per minion; collapse and the mortal bite fire here
phase 6c  tire       — Fatigue.advance nets accrual − recovery + Breath.rate
phase 6d  travel     — somebody walks out of it, or does not
phase 7   observe    — the lamp will not burn
```

The breathability of each place is computed **once per tick per place**, not once per minion — a
handful of parcel sums against 12–20 people. Negligible against a phase solve that is already half
the tick.

---

## 5. The tension this actually resolves: hazards belong to spaces

Worth stating plainly, because it is bigger than bad air and it is the reason the place work is
being pulled forward rather than deferred.

**Today a hazard resolves through a station**, because when `Injury` was written there was no
geometry and a station was the only coarse notion of *where* the engine had. `current_progress.md`
says so in as many words: *"Hazards resolve through stations, which gives coarse place with no
geometry and upgrades cleanly when volumes arrive."* Volumes have arrived.

The station key encodes a falsehood. `endangers: { fireman: 1.0, driver: 0.4 }` reads as "the
boiler hurts the fireman more than the driver", and the mechanism by which it does that is *the job
they were doing*. **That is not why they were hurt.** They were hurt because they were near the
boiler. A visitor standing in the same room with no job at all takes nothing, and a fireman who
walked out two minutes ago takes it in full.

Keyed by place, the model says the true thing: **the boiler is in the engine room, the engine room
is what the explosion fills, and everybody in the engine room is in it.** Exposure becomes a
property of geometry, which is what it is. If the fireman should be worse off than the driver, they
are standing in different places — the firebox side and the footplate — and that is a statement
about the machine's layout rather than about its payroll.

Three things fall out that are hard to get any other way:

- **Being somewhere becomes dangerous on its own**, with no task attached, which is the whole
  premise of the ambient perils above.
- **Walking away works.** Under the station key, leaving your post protects you; under the place
  key, leaving the *room* protects you, and those are different distances. The travel phase
  suddenly matters to survival and not only to productivity.
- **An unmanned machine can still kill somebody** who happens to be passing, which the station key
  cannot express at all.

### Migration: the mine leads, the engine follows

**Both keys stay legal**, and that is the migration. A node with `place: nil` keys its hazards by
station exactly as today, so **the steam engine is untouched and bit-identical** — the same guard
that kept phase 6d free, one layer down. The mine declares places from the start and is the proving
ground.

The retrofit, when the lessons are in, is small and worth naming now so the target is clear: the
engine's places are roughly **boiler house**, **footplate** and **yard**; `endangers:` maps from
station keys to place keys; the four stations distribute between them. The interesting question it
will answer is whether a place is the right granularity for a machine you stand *on* rather than
*in* — and that is exactly the lesson the mine cannot teach us, which is why it is worth doing
second rather than guessing at now.

---

## 6. Content this opens, in order of cost

| Substance | Cost | Gets us |
|---|---|---|
| **Afterdamp** | **Nothing.** `flue_gas` exists and is already the product of firedamp and dust combustion | The thing actually owed. The survivors of the blast suffocate, which is what killed more of them than the blast did |
| **Blackdamp** | One resource. Vented by the strata like firedamp, or produced by slow oxidation in the goaf | The silent one, and the one that puts a lamp out — which is the second reading on an instrument we already have |
| **Whitedamp** | One resource **and a genuinely new reaction** — combustion that produces CO when the oxidiser runs short. The engine has no concept of an incomplete reaction today; `rate_per_s` is limited by whichever reagent runs out first, and it produces the same products either way | The canary. Worth its own pass — it is a change to how reactions work, not content |
| **Stinkdamp** | One resource, high `toxic_fraction:`, plus the detail that it deadens the sense of smell that warned you | Flavour, later |

**Kit and traits, all of which fit the existing conventions with no engine change:**

- `unbreathing: true` — undead, golems, constructs. A gate.
- `respirator: 0.0..1.0` — Draeger apparatus, a Proto rebreather. Scales the rate.
- `asphyxia_resistance` — falls out of the `_resistance` convention for free if the collapse
  hazard is tagged `:asphyxia`.
- The canary is not a tag, it is an **instrument**, and it belongs in §7.

---

## 7. The instrument, and this is the best part

**The player must be able to see this coming, and the instrument already exists.**

The flame safety lamp reads gas by the height of the blue cap above the flame — and it reads
*blackdamp by going out*. One instrument, two readings, in opposite directions, and it is already
built: `Sources::Fraction(:district, :firedamp)` through `Lag → Noise → Stick → Bands` into
`Displays::Prose`. Adding the other end is a new source and a band, not a new instrument.

That is the game's whole thesis in one object. A number inferred from the behaviour of a flame,
reported by a minion of variable competence, from one point in a district, some minutes ago.

The **canary** is the second instrument and the right one for whitedamp specifically: it collapses
before a human does, which makes it a *leading* indicator with a cost attached. It should be a
fitting, not a tag.

---

## 8. Invariants, conservation, performance

- **Purity.** No clock, no I/O. ✔
- **Entropy.** None drawn. Everything uncertain was rolled at `initial_state` — the resilience
  threshold, exactly as the Danger Check already works. **No amendment to the entropy invariant.**
- **Order-independence.** The sweep reads node contents settled by phase 5 and minion places from
  N−1, writes minions, and reads no minion's state to decide another's. ✔
- **Idempotence.** Nothing here is a command. ✔
- **Conservation — and this is a deliberate choice that must be written down so nobody "fixes" it
  later: minions do not consume air.** A person at work breathes about 2×10⁻⁴ kg/s. Twenty of them
  is 4×10⁻³ kg/s against a fan moving **40 kg/s** — four ten-thousandths. Modelling it would need a
  mass sink, a ledger line and a conservation spec to account for a rounding error. The case where
  it is not a rounding error is a sealed space over many hours (the Hartley men, walled in with the
  shaft blocked), and that wants its own mechanism if we ever want it.
- **Performance.** O(places) parcel sums plus O(minions) comparisons. Nothing near the phase solve.
- **The steam engine stays bit-identical**, and by two independent guards, which is deliberate:
  `layout.spatial?` is false without passages so no minion has a `place`, and every engine node
  has `place: nil` so its hazards still key by station. Neither is a special case — both are the
  same opt-in default that made phase 6d free.

---

## 9. What this deliberately does not do

- **Model oxygen as a resource.** It would split `air` into O₂ and N₂ everywhere, rewrite every
  combustion reaction, change every existing operation's content and break the engine's digest —
  all for mass flows that are four orders of magnitude below the noise. The fraction-of-air
  proxy is exact enough for every threshold that matters.
- **Model head height, or the shape of a space, or a density gradient.** Concentration is bulk
  concentration. §D4.
- **Carry anybody out.** A collapsed minion stays where they fell. The counterplay is the fan.
- **Expire a respirator.** Apparatus duration is the real limit on rescue and it deserves better
  than an afterthought.
- **Unify hazard *effects*.** The peril sweep generalises where a hazard comes from. What it does
  stays specific, because suffocation, heat and drowning genuinely differ.

---

## 10. Traps to write down before anybody starts

1. **`ReferenceCrew` has `endurance: 1.0e6`.** If the suffocation rate divides by raw endurance,
   the reference crew is *immune to suffocating* and every spec passes while the mechanic does
   nothing. This is the same bug shape as `Minion::PACE`, where `TIRELESS` walked at 700,000×
   human pace and made the travel phase look unwired. **Clamp the divisor** (`RESERVE`), and give
   the breathing specs their own crew fixture with a real endurance, as every mine spec already
   does for `darkvision`.
2. **Mass fraction is not volume fraction.** Firedamp is 0.668 kg/m³ against air's 1.225. Reading
   breathability off kilograms makes methane look half as dangerous as it is.
3. **A place a minion can stand in, with no breathable volume, must fail the build rather than read
   as safe.** So must two gas-holding nodes in one place. Both are the same rule and it is the
   whole value of declaring places rather than deriving them: for a hazard system, silence must
   never be the safe answer.
4. **Collapse must be gated on the air, not on fatigue alone**, or every stoker working flat out
   suffocates at his post.
5. **`Injury.apply_mode` clears `posting` as well as `station`.** A collapsed minion will not walk
   anywhere, which is intended — but it means bad air escalates to mortal without further input.
   Make sure the spec asserts that as a *feature*.
6. **`minion_spent` will fire before the collapse does**, as a warning, for a reason unrelated to
   work. That is a gift, not a bug, but a consumer that reads `minion_spent` as "they need a rest"
   will be wrong about it.
7. **Two hazard keys means a node can declare into the wrong namespace and hurt nobody.** A node
   with a `place:` whose `endangers:` still names stations, or the reverse, resolves to an empty
   index and is silently harmless. `injury_spec` already walks every catalogued machine looking for
   hazards wired to stations that do not exist; **extend that walk to places in the same commit**,
   or the migration in §5 will lose a hazard without failing anything.

---

## 11. Suggested staging

**A — Places become first class.** `Place`, `Node#place`, `Layout` holding declared places, the
build-time refusals, `endangers:` keyed by place with the station key still legal. **No new
behaviour at all**, and the test is that the mine's existing specs stay green and the steam engine
stays bit-identical. Doing this first and alone is what keeps the breathing work from being
entangled with a spatial refactor when something goes wrong.

**B — Breathability, well-mixed.** The `breathable` tag on air, `Breath`, the suffocation term in
`Fatigue.advance`, the ambient-peril sweep in `endanger`, collapse and the asphyxia clock.
**Afterdamp works at the end of this stage with no content added at all**, which is the whole point
and makes it the natural first spec.

**C — Blackdamp.** One resource, vented by the strata. The lamp going out as a second reading on
the instrument that already exists. If per-place concentration is ever wanted, this is the stage
that would earn it.

**D — Gear and rescue.** `unbreathing`, `respirator` and its duration, the canary as a fitting,
carrying a collapsed minion out.

**E — Whitedamp.** Needs incomplete combustion first, which is a reaction-engine change and wants
its own sketch.

**Later, on the mine's lessons — the steam engine's retrofit.** §5.

A and B close what is owed. C, D and E are content and each is cheap once B exists — which is the
test of whether this design was the right size.

---

## 12. Settled, and what is left open

**Settled:**

1. **Collapse escalates `severe → mortal` on a clock.** `severe` is out for this match, `mortal` is
   out for the next one too, and the dwell between them is what makes rescue worth doing at all.
2. **`endurance` is the clock**, clamped so a fixture cannot be immune.
3. **Every operation is spatial, and nodes belong to places.** Hazards key by place. The mine leads;
   the steam engine keeps its station keys until the lessons are in.

**Open:**

1. **Does a place carry its own `endangers:` weight, or does a node hurt its place at face value?**
   A weight per place lets a blast reach the *next* room at a fraction — `{ engine_room: 1.0,
   yard: 0.3 }` — which the station key could never express and which is plainly true of an
   explosion. The alternative is to derive the falloff from the passage graph, which declares
   nothing but is a tuned physical model where a declaration would do. I lean to the declaration,
   with adjacency as a thing we do not build.
2. **Should `Place` know its own volume, separately from the node it breathes?** It does not need
   to for anything here. It probably does the day two nodes share a room.
3. **Does a mortal asphyxiation ever actually kill?** `MODES[:mortal]` today is lasting but
   survivable — "miss one, revived", which is what was asked for. A genuine death tier would be a
   fourth mode and a decision about the game rather than about air.
