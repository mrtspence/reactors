# Reaction pathways: what a reaction does when it cannot get what it wants

Whitedamp is the occasion for this and the least important thing about it.

**A reaction whose products change with the supply of one reagent is most of industrial
chemistry**, and every operation after the mine runs on it. A gasworks *is* coal burnt in
deliberately too little air. A blast furnace is the same trick with the atmosphere tuned to
reduce rather than oxidise. Producer gas, water gas, coking, calcining, smelting — all of them
are one fuel and one counter-reagent where **the ratio decides the product, not the rate**.

The engine today has no way to say that. A reaction has one `produces:`, and running short of a
reagent makes it slower and nothing else. This sketch is the smallest thing that fixes that and
still carries the weight of the operations that will need it.

---

## 1. What the engine does today

The whole of it is six lines in `Resources::Reaction.advance`:

```ruby
limit = consumes.map { |resource, ratio|
  available = held[resource]&.fetch(:kg) || 0.0
  available = [ available, ignited_fuel_kg ].min if ignited_fuel_kg && fuel?(resource, content)
  available / ratio.to_f
}.min

extent = limit * (1.0 - Math.exp(-spec.fetch(:rate_per_s).to_f * dt))
```

Three things follow, and they decide the design:

1. **The limiting reagent is already computed.** `limit` is a `min` over per-reagent headroom.
   "What is this reaction short of" is one `min_by` away from an answer we already pay for.
2. **`available / ratio` is the equivalence ratio, unnormalised.** The air term divided by the
   fuel term *is* λ — actual air-to-fuel over stoichiometric — which is the parameter real
   combustion engineering uses to decide whether a flame makes CO₂ or CO. The number the
   chemistry needs is already sitting in that array.
3. **Starvation currently only slows things down.** Being short of air reduces `limit`, so a
   starved fire burns *less* coal. That is wrong in a way that matters: a rich fire burns
   **more** fuel per unit of air, because each carbon takes one oxygen instead of two.

Point 3 kills the cheapest options in §3.

---

## 2. The design

The proposal — an optional tiered set of pathways selected by how short the counter-reagent is
— is the right shape. Three refinements.

### 2.1 Blend on the budget, not on a ratio

"Some ratio depending on how starved it is" invites a tuned curve, and it does not need one.
There is an exact answer and it is easier arithmetic than any curve.

Let a reaction want `E` units this tick (set by the rate and what is alight). Pathway 1 needs
`a₁` of the limiting reagent per unit; pathway 2 needs `a₂ < a₁`. With `A` available, the split
`x` that consumes **exactly** what there is:

```
x·a₁ + (1 − x)·a₂ = A / E
```

Three cases, no clamping, no tuning:

| Condition | Outcome |
|---|---|
| `A ≥ E·a₁` | all clean. The reagent is not limiting and nothing changes |
| `E·a₂ ≤ A < E·a₁` | all the fuel reacts, split so the reagent is exactly spent |
| `A < E·a₂` | even the last pathway cannot be fed: `E = A / a₂`, and *now* it caps the extent |

The middle row is the feature. The bottom row is today's behaviour generalised. The top row is
today's behaviour unchanged — which is what keeps every existing tuning intact.

**No new constant and no curve to balance.** The blend falls out of mass balance. A tuned number
here would need re-tuning per fuel and per furnace.

### 2.2 Continuous, not switched

Selecting a tier by threshold would put a cliff in the middle of the most-used reaction in the
game. `combustion.yml` already carries a long note about `rate_per_s` being sharply peaked with
failures rather than degradations at both ends, and how much time that cost. Blending is fewer
lines than switching. Do not add a second cliff.

### 2.3 N pathways cost almost nothing

With the budget formulation, N pathways is a greedy fill — spend the reagent on the cleanest
first, then the next — reducing exactly to the two-pathway formula. A loop instead of a
subtraction. Allow the list; declare two; let soot be a third when somebody wants it.

---

## 3. What I considered instead

### (a) Two separate reactions on the node, arbitrated by `reaction_throttle`

Tempting because **it needs no engine change at all** — `reaction_throttle` is already
per-reaction, and a node could return `λ` for the clean reaction and `1−λ` for the dirty one.
Four independently fatal problems:

- **It scales `dt`, not extent**, and extent is exponential in `dt`. Throttling to 0.5 halves
  nothing, so the two halves would not sum to the whole.
- **They run in sequence over the same parcels**, so the first eats the reagent and the second
  gets the remainder. The answer depends on declaration order.
- **Every node hosting combustion would compute λ itself**, putting chemistry in
  `operations/*/definition.rb` — the wrong home for something every furnace shares.
- **Both fire**, so the fuel is consumed twice unless each limit knows about the other.

Written down because it will look attractive again in six months.

### (b) React completely, then convert some product afterwards

Thermodynamically respectable — enthalpy is a state function, so "burn fully then partially
reverse" releases exactly what burning partially would, and the reverse is endothermic by the
difference. Cheap, and mass balances trivially.

**It fails on §1.3.** Starved combustion consumes more fuel per unit of air, and a post-hoc
conversion cannot change how much fuel was burnt — the extent was already fixed by an
air-limited `min`. The fire would still shrink when it should stay large and turn poisonous,
which is the whole behaviour we want. Rejected on physics, not taste.

### (c) Products as formulas of a continuous variable

Unbounded complexity, no way to validate mass balance at boot, and a content file a reader must
evaluate arithmetic to understand. No.

### (d) Give whitedamp its own source and skip the mechanism

Blackdamp is modelled by *where it is wired* rather than by chemistry, and that worked well. The
same trick here would be a `whitedamp_source` seeping into the district.

Tempting, and **wrong for a reason worth stating**: blackdamp's character is where it collects,
so placement *is* the model. Whitedamp's character is that **it is what a fire makes when it is
smothered** — it appears behind a stopping, in a gob that is heating, after a fire in a sealed
district. A seep reproduces the gas and loses the causation, and the causation is the thing a
player can act on. It would also leave the gasworks with nothing to build on.

---

## 4. The content shape

Purely additive. **A reaction with no `alternatives:` parses, validates and computes exactly as
today**, which is non-negotiable: `rate_per_s` sits on a measured plateau for every existing
fuel and none of them may move.

```yaml
coal_combustion:
  consumes: { coal: 1.0, air: 11.0 }
  produces: { flue_gas: 11.9, ash: 0.1 }
  enthalpy_j_per_unit: -30000000
  rate_per_s: 1.5
  min_temperature_k: 500
  ignition: { spread_per_s: 0.30, quench_per_s: 0.45 }

  # The reagent whose supply picks the pathway. Named rather than inferred: a reaction with
  # three reagents has no obvious counter-reactant, and inferring it from whichever happens to
  # be short would make a content file's meaning depend on the state of a node.
  limited_by: air
  # Ordered, most of `limited_by:` first. The first pathway the supply can pay for is the one
  # that runs; the extent splits across the boundary so the reagent is exactly spent.
  alternatives:
    - consumes: { coal: 1.0, air: 5.5 }
      produces: { flue_gas: 5.4, whitedamp: 1.0, ash: 0.1 }
      enthalpy_j_per_unit: -9000000
```

`limited_by:` reads as the gate it is, and unlike `starved_of:` it is not a combustion word — a
blast furnace running rich is at its intended operating point, not failing.

### The validation rules, checkable at boot

1. **Every pathway balances mass**, exactly as the top-level pair already must. Same code, once
   more per pathway.
2. **Every pathway consumes the same quantity of every reagent the parent consumes, except the
   one named by `limited_by:`.** Coal stays at 1.0 everywhere; air is free to vary.

Rule 2 is what makes splitting the extent meaningful: the pathways must be alternative fates for
*the same kilogram of coal*, or the extents are not commensurable and the blend is nonsense. It
turns a whole class of authoring mistake into a boot failure.

### A pathway may introduce a reagent the parent does not use — and this is a seam

Water gas is carbon plus **steam**, not carbon plus less air: a genuinely different
counter-reactant rather than less of the same one. Rule 2 permits this by only constraining the
reagents the parent names, so a pathway may add its own.

The cascade then caps each pathway by three things rather than two: the fuel still to react,
the remaining `limited_by:` reagent, and **the availability of any reagent only that pathway
needs**. A pathway whose extra reagent is absent simply cannot run and the cascade falls through
to the next — which is also how a pathway consuming *none* of `limited_by:` becomes the bottom
of the cascade, always payable.

> **This is deliberately a seam and it will ship under-tested.** Nothing in the game uses an
> extra reagent yet, so the only coverage will be a rig. **Say so in the code**, at
> `Reaction.advance` and in `add-content.md`, so that the first person to build a water-gas
> plant on it knows they are the first — and treats a surprise as a gap in this design rather
> than as a bug in their content.

### Ignition is shared, not per-pathway

A fire is one fire: the spread of flame across a grate is not a different process because the
products differ, and the difference is not worth the complexity anywhere we currently care.
`ignition:` stays on the parent and governs all its pathways.

**The retrofit if we ever want it** is a per-pathway `quench_per_s` — a smothered fire arguably
dies back faster — and it is additive in the same way this whole block is. Not now.

---

## 5. What this generalises to, and what it deliberately does not

**It does:** any reaction where the supply of one reagent picks the product. Coking and gasworks
(coal plus deliberately insufficient air → coal gas and coke, this mechanism used *on purpose*
rather than as a hazard). Blast furnace reducing vs oxidising. Calcining. Roasting sulphides to
oxide or sulphate. **Operation 3 as sketched in `mine.md` is a gasworks, so this is not
speculative generality — it is the enabling mechanism for the next operation.**

**It does not, and should not:** catalysis. A catalyst changes the *rate* and leaves the products
alone, so it belongs on `rate_per_s` as a multiplier keyed off a tagged resource being present —
a separate, smaller change on a different axis. One mechanism doing two unrelated jobs would do
both badly. `Reaction`'s doc-comment already lists "catalysis, inhibitors and competing
pathways" as three things, and it is right to.

---

## 6. The lift

Smaller than it reads, because the hard information is already computed.

| File | Change | Size |
|---|---|---|
| `physics/resources/reaction.rb` | The cascade, behind `spec[:alternatives]` | ~45 lines |
| `content.rb` | Validate pathways: balance, known resources, rule 2 | ~15 lines |
| `content/resources/damps.yml` | `whitedamp`, with `toxic_fraction:` | ~10 lines |
| `content/reactions/combustion.yml` | `alternatives:` on coal and firedamp | content |
| `breath.rb` | **nothing** — `poisoned?` already reads `toxic_fraction:` | 0 |
| Docs | `add-content.md`, `content/CLAUDE.md`, `physics/CLAUDE.md` | — |

`Breath.poisoned?` was written in the breathable-air release with `toxic_fraction:` in its
signature and no substance declaring one. **This is its first client** and it needs no change,
which is a fair sign the two designs agree.

### The one real risk

**`rate_per_s` is tuned on a plateau and this changes what limits the extent.** The guard is
that the new path is entered only when `alternatives:` is present, so every existing reaction
takes the identical branch and the steam engine's digest must not move. That is a spec, not a
hope — `steam_engine_spec`'s snapshot and `determinism_spec` both fail loudly if it does.

**The closed firebox is not the second risk, it is the payoff.** Once coal has an alternative
pathway, a banked fire in a shut-down firebox starts making whitedamp rather than merely
smouldering — a hazard nobody designed, arriving from the physics being right. That is the
argument for this shape over every alternative in §3, all of which would have produced the gas
only where somebody had thought to put it.

It does mean the steam engine acquires a new way to hurt its crew, so it is sequenced well
after the mine rather than folded in here — see §7.

---

## 7. Staging

**A — the mechanism, with no content using it.** The cascade, the validation, the specs. Prove
on a rig that a fuel-limited reaction is bit-identical to today, that a reagent-limited one
splits its extent exactly, and that a pathway needing an absent extra reagent is skipped.
Nothing in the game behaves differently at the end of this stage.

**B — whitedamp.** The resource, `alternatives:` on firedamp and coal dust, `toxic_fraction:`
reaching `Breath.poisoned?`. The canary as a fitting, since whitedamp is what a canary is *for*
and it is the only hazard whose historical answer is a leading indicator.

**C — the steam engine's firebox. Much later**, after the mine's own follow-ups rather than
after B. It is the one place this touches a machine that is already tuned and already playable,
it needs the places retrofit from `breathable-air.md` §5 to have somewhere to put the crew, and
a banked fire quietly gassing a boiler house is a change to an operation people know. Nothing
about it is urgent; everything about it is better done once the mine has taught us what a
place is worth.

---

## 8. Settled

1. **Ignition is shared across pathways.** Close enough in every case we care about; a
   per-pathway `quench_per_s` is the retrofit if it ever earns one.
2. **A pathway may name a reagent the parent does not use.** Supported from the start because
   water gas is a real case and it costs only cognitive overhead — but flagged in the code as
   an untested seam, so the first user of it knows.
3. **`limited_by:`**, not `starved_of:`. It expresses the gate, and it does not read as failure
   in the operations where running rich is the point.
