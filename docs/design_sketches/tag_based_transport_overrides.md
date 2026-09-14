# Tag-based transport overrides

> **Status update, 2026-09-09: O2 is built, with §5's sub-decisions.**
> `Node#transport_affinity`, a weighted `apportion`, `Nodes::Boiler` for carryover, and
> speed-dependent entrainment on the cylinder's exhaust. Steps 3 (a separator part) and 5
> (a sorter) are not built and are waiting for something that needs them.
>
> **Three things below did not survive implementation** and are corrected in the boxes marked
> CORRECTION: the clamp band in §5.4 was two orders of magnitude too tight, §5.1's "never the
> total" is true only of rate-driven paths, and §1.1's account of the pipeline missed that a
> pressure-driven path splits the stream before `apportion` ever sees it.
>
> **A fourth correction, 2026-09-09 — the additive rule needed a bound and a default, and
> lacking both it shipped a broken part.**
>
> *The entrainment term was unbounded.* `desired × (1 − gas_share)/gas_share` grows without limit
> as a stream approaches pure liquid, so a drum on the point of priming claimed its whole
> inventory in one tick. The only thing behind it was `scale_by_sink_room`, which scales a claim
> **uniformly** — so it trimmed the *gas* figure below what the pressure solve settled, quietly
> breaking the one invariant the additive design exists to protect. The bound is physical rather
> than defensive: **conductance rates a gas, a bore rates a liquid**, so liquid is capped by
> `Port#max_kg_per_s` and gas is not.
>
> *And `weights.empty?` dropped liquid entirely*, which mattered far more than it looks because
> membership in the pressure regime is **structural** — any conductance-bearing path whose ends
> declare no intent. So "nobody has an opinion" is the common case, and on it a pressure-driven
> path silently passed no condensate at all. **It is why the steam engine's cylinder relief valve
> passed water in exactly zero states**: lifted it was pressure-driven with no affinity, shut its
> throughput was zero. A part fitted for one job, incapable of it, under a comment asserting it
> could. Liquid now falls to the proportional rate term solids already took.
>
> Neither was caught because `Arbiter.entrained` had **no coverage of any kind** —
> `transport_affinity_spec`'s rig declares no `conductance:`, so every example in it tests the
> other branch. `spec/reactor_sim/entrainment_spec.rb` is the missing half.

**Status: design sketch.** Input to a decision.

Every stream in this simulation carries the composition of whatever it came from, in exactly the
proportion it was held. That single rule is now blocking four separate mechanics, and it has
already forced one bad fix. This is about giving a part a say in **what** crosses it, not just
how much.

Related: [`obstruction.md`](obstruction.md) §6 step 4 is blocked on this;
[`transport_model.md`](transport_model.md) §5 sketched the narrow version (entrainment) that
turns out to be one case of a much more general pattern.

---

## 1. What exists

### 1.1 Two controls, and that is the whole vocabulary

Composition is decided in exactly two places in `Arbiter`, and they run once each per path per
tick:

```ruby
# 1. A binary gate. Material must satisfy EVERY port on the path.
def eligible_parcels(state, ports, content)
  state.fetch(:parcels, []).select { |p|
    ports.all? { |port| port.accepts?(p.fetch(:resource), content) }
  }
end

# 2. Proportional by mass. The mixture that leaves matches the mixture that stays.
def apportion(desired, parcels)
  total = parcels.sum { |p| p.fetch(:kg) }
  parcels.to_h { |p| [ p.fetch(:resource), desired * (p.fetch(:kg) / total) ] }
end
```

So a part can say **"this may cross"** or **"this may not"**, and then everything that may cross
does so strictly in proportion to what is held. There is no third thing it can say. A port's
`accepts:` is the same answer at every temperature, every flow rate and every level.

### 1.2 The pipeline shape, which is the good news

`settle_mass` builds `per_resource` once — the composition vector — and every stage after it
**only scales that vector**:

```
apportion               →  per_resource          the composition decision, ONE place
scale_by_source_availability                     scales per resource
cap_gas_by_pressure                              scales per resource
scale_by_sink_room                               scales
extract                                          takes exactly per_resource from the source
```

That means a composition override is a change to **how one function builds one hash**, not a
change to the pipeline. Whatever is chosen below, it lands in `apportion` and nothing downstream
needs to know.

### 1.3 What proportional-by-mass actually means here — measured

At tick 3600, throttle 60, stoking 60, the composition of every holder that matters:

| Node | Resource | kg | Share of node |
|---|---|---|---|
| **boiler** | water | 2620.787 | **99.7650%** |
| | steam | 6.174 | 0.2350% |
| **firebox** | coal | 235.462 | **94.8392%** |
| | ash | 10.652 | 4.2905% |
| | flue_gas | 1.397 | 0.5626% |
| | air | 0.764 | 0.3077% |
| **steam_chest** | steam | 1.984 | 100.0000% |
| **cylinder** | steam | 0.340 | 90.7639% |
| | water | 0.035 | 9.2361% |

These numbers are the whole problem in one table. **Open the boiler's steam outlet to liquid and
99.77% of what leaves is water.** Tag the firebox's ash outlet `:solid` rather than `:waste` and
94.8% of what the fireman rakes out is unburnt coal.

### 1.4 What it has already cost

Three of these are measured, not hypothetical:

- **The chimney tag, and a fix that was wrong in both positions.** `flue` was declared
  `accepts: [:gas]`, so condensate had no route out of the cylinder at all and it flooded to
  21.9 kg — a liquid fraction of 1.455, hydraulically locked. The only available fix was to flip
  the bit to permissive, which means water now leaves *proportionally by mass* — preferentially,
  since the exhaust stroke sweeps a volume and water is a thousand times denser than the steam
  carrying it. **Both settings are wrong and there is no third**, so the flooding was traded for
  an over-generous drain.
- **Priming cannot be built.** [`obstruction.md`](obstruction.md) needs boiler carryover to make
  hydraulic lock reachable, and §1.3 says why the tag route is closed: opening `steam_out` to
  liquid carries 99.77% water and empties the boiler into the cylinder in seconds.
- **The cylinder cocks are a cliff** (337 → 50 kW) partly because they take a proportional cut
  of the charge rather than preferentially draining what has collected.

And two that are simply absent: a steam separator, and any kind of sorter.

### 1.5 The cases this has to serve

| Mechanic | Direction | Where | Depends on |
|---|---|---|---|
| Boiler priming / frothing | **enrich** liquid in the outgoing steam | source port | water level, firing rate, temperature |
| Steam separator / baffle | **deplete** liquid from the passing stream | conduit | flow velocity, design type |
| Steam trap | **deplete** vapour — the inverse | conduit | temperature |
| Ore sorter | **route** by tag, two ways at once | two paths from one holder | mechanism condition |
| Cylinder cocks | **enrich** liquid in what is drained | source port | — |
| Ash raking | **enrich** waste, exclude fuel | source port | — |

What they share: **a part changes the composition of what crosses it, per tag, as a function of
its own state.** The last column is why static configuration is not enough.

---

## 2. What the field does

### 2.1 Split fractions — the process-simulation answer

Aspen Plus's `Sep`, `FSplit` and `SSplit` blocks separate a stream by **per-component split
fraction**: for each component, what fraction reports to each outlet. `FSplit` splits a stream
into several according to user specification; `SSplit` does it per sub-stream. The fractions must
sum to 1, which is how conservation is enforced by construction.

This is the canonical shape and it is exactly right for anything with **two outlets**.

### 2.2 Partition curves — and separation is never perfect

Mineral processing has the sharper idea. A **Tromp curve** (Tromp, 1937) plots the partition
coefficient — the percentage of feed of a given property reporting to one product — against that
property. Two things matter for us:

- **The area between the ideal and the real curve is the "error area", and it is the measure of
  misplaced material.** Every real separator misplaces some.
- **Efficiency is highest far from the cut point and worst near it.** The `Ecart probable` (Ep)
  quantifies it: half the difference between the density at which 75% reports to sinks and the
  density at which 25% does.

For a game this is the interesting half. A perfect sorter is a boring machine; **the misplacement
is the mechanic**, and it is something that can worsen with wear.

### 2.3 Real separators are velocity-dependent, which forces a dynamic rule

- A **cyclone** separator removes condensate at about **98% efficiency up to ~13 m/s, falling to
  around 50% at 25 m/s.**
- A **baffle / vane** type holds high efficiency over a *wider* velocity range — a genuine design
  trade-off between peak performance and tolerance.
- Separators aim to deliver steam at a **dryness fraction of 0.98 or better** to the cylinder.
- Baffle demisters separate completely above ~30 µm droplets, optimally at a 40° baffle angle.

**Efficiency falling with flow is not a detail — it is the mechanic.** Drive the engine harder
and the separator stops protecting it. A static per-port number cannot express that.

### 2.4 Carryover is a function of level and load

Boiler carryover — "any solid, liquid or vaporous contaminant that leaves a boiler with the
steam" — has mechanical causes (unstable water level, poor separation, **sudden increases in
load**, operation above design load) and chemical ones (alkalinity and dissolved solids driving
foaming). So frothiness is a function of drum level and firing rate now, and of water chemistry
later if that is ever modelled.

---

## 3. Constraints any answer must satisfy

1. **Conservation, exactly.** Whatever leaves the source must be what arrives, less what the
   walls legitimately take. Lossy is fine; silent is not.
2. **Order-independence.** The override reads tick N−1 only. Velocity-dependence therefore reads
   *last tick's* flow — which is fine and must be documented, not discovered.
3. **One composition decision.** It must stay inside `apportion`, because every stage after it
   assumes `per_resource` is already the right mix and only scales it.
4. **The binary gate stays.** `accepts:` is *structural* — a gas outlet wired to a liquid inlet
   is a wiring mistake and must still move nothing. An override is behavioural and sits inside
   what the gate already permits.
5. **Not a second throughput control.** This codebase has twice been burned by two numbers
   describing one restriction (`max_kg_per_s` against `conductance`; the `extractable_joules`
   clamp standing in for a throttle). **Composition and rate must stay separate.**
6. **Cheap.** `apportion` runs per path per tick.
7. **Config, not state.** Nothing new to snapshot.

---

## 4. Options

### O1 — Static per-tag weights on a port

Replace `accepts: [:gas]` with `affinity: { gas: 1.0, liquid: 0.05 }`. `apportion` weights by
`kg × affinity` instead of `kg`. The current boolean gate is the special case where every weight
is 0 or 1.

**Pros.** Tiny change, entirely inside `apportion`. Backwards compatible by construction.
Composes along a path by multiplication. Conserves trivially, because it only re-weights a fixed
desired total. No new hooks anywhere.

**Cons.** **Static.** It cannot express a separator whose efficiency collapses with velocity
(§2.3), a boiler whose frothiness rises with firing rate (§2.4), or a sorter that degrades as it
wears. Those are the cases that make the mechanics worth having, so this solves the plumbing and
misses the game.

### O2 — A per-port affinity hook, evaluated against state *(recommended)*

```ruby
# Node, default: no opinion
def transport_affinity(_port_id, _state, _ctx) = {}
```

Returning `{ tag_or_resource => multiplier }`. `Arbiter` collects the affinities of **every port
on the path** — both holders' and every conduit's, exactly as the tag gate already does — and
weights `apportion` by the product.

Worked, for the three cases:

```ruby
# A boiler that froths as it is driven harder and its level rises.
def transport_affinity(port_id, state, ctx)
  return {} unless port_id == :steam_out
  { liquid: 1.0 + (froth(state, ctx) * 400.0) }     # tuned so 99.77% water is not the answer
end

# A separator that stops protecting you when you open up. 0.02 is 98% removal.
def transport_affinity(_port_id, state, ctx)
  { liquid: 0.02 + (0.5 * overspeed(state, ctx)) }
end

# A sorter: two outlets, opposite biases, and never perfect.
#   ore port    { ore: 9.0, gangue: 1.0 }
#   waste port  { ore: 1.0, gangue: 9.0 }
```

That last one produces a **partition curve with its error area built in**: with those weights a
path drawing 1 kg takes 0.9 ore and 0.1 gangue, so recovery is 90% and misplacement 10%.
Sharpen the sort by widening the ratio; a perfect sort needs an infinite one, which the rules
forbid — so **there is always misplaced material**, which is what §2.2 says a real separator
does.

**Pros.**
- Handles every case in §1.5 with one mechanism, including the two that are only interesting
  because they are dynamic.
- **Per part, per tag**, which is what was asked for, and per *port* so one node's two outlets
  can disagree — which is what makes a sorter expressible at all.
- Composes multiplicatively along a path, mirroring the tag gate's `ports.all?`.
- Conserves by construction: it re-weights a fixed total and never changes it (§5.1).
- The existing gate is untouched and still structural.
- Imperfection is the natural expression and perfection is the awkward one, which is the right
  way round for this game. Wear can degrade an affinity toward 1.0 — *no separation* — with no
  new machinery.
- No new state, so nothing new to snapshot.

**Cons.**
- **It cannot send material somewhere else.** A separator that *collects* its catch has nowhere
  to put it: the water simply is not drawn and stays in the source, which is not where it
  physically was. The honest resolution is that a collecting separator is a **holder with two
  outlets**, which is consistent with the rule `Obstructs` already established — a conduit holds
  nothing, so it cannot accumulate. Worth stating loudly, because the alternative reading
  ("a conduit can drain") is wrong and inviting.
- A hook on `Node` that most nodes will never implement.
- The velocity-dependent cases read last tick's flow, so a separator's efficiency is one tick
  stale. Harmless at 250 ms, but it is a real approximation.
- Silent failure mode: an affinity so extreme that the requested mass cannot be made up from
  what is available. The path then quietly under-delivers. Needs to be visible (§7).

### O3 — Split fractions across a node's outlets

The Aspen model: a node declares, per resource, what fraction of its outflow reports to each of
its outlet ports; the fractions sum to 1.

**Pros.** The canonical answer, and the only one that is *explicitly* conservative across
several destinations. Exactly right for a two-outlet separator or a sorter, and it makes "where
does the caught water go" a first-class question rather than an awkward one.

**Cons.** A node does not currently know its outlet paths — `Path` is resolved from the graph and
a node declares intent per *port*, deliberately, so that it does not have to inspect topology it
does not own. Giving nodes that knowledge is a real architectural change. It is also the wrong
shape for the boiler: there is only one outlet, and what is wanted is *enrichment relative to
what is held*, not a division of it. So O3 solves the routing cases well and the composition
cases badly.

### O4 — A per-path composition function

One hook: the source returns the whole `per_resource` hash for a given desired mass.

**Pros.** Maximum flexibility; anything is expressible.

**Cons.** Every implementer has to re-derive conservation, availability and the desired total,
and they will get it wrong differently each time. This is the "each node solves it its own way"
option that `Obstructs` was written to avoid, one level down. Reject.

### O5 — An additive entrainment term

The original [`transport_model.md`](transport_model.md) §5 shape: a source-side hook returning
extra material that rides along with a carrier phase.

**Pros.** Matches the physical story of carryover directly, and it is already written down.

**Cons.** **Only does enrichment.** A separator, a trap and a sorter all need depletion, and
half the cases in §1.5 are the wrong way round for it. It also changes the total, which makes it
a second throughput control (constraint 5) and drags conservation into every implementation. It
is one case of O2 wearing a costume.

### O6 — Leave it; solve each case where it arises

**Pros.** No abstraction to get wrong.

**Cons.** There are already six cases in §1.5 and two measured bugs. This is the option the
evidence exists to rule out.

### Comparison

| | O1 static | **O2 hook** | O3 split fractions | O4 free function | O5 entrainment |
|---|---|---|---|---|---|
| Boiler frothing | ✗ static | ✓ | awkward — one outlet | ✓ | ✓ |
| Velocity-dependent separator | ✗ | ✓ | ✗ static | ✓ | ✗ depletion |
| Steam trap | ✓ | ✓ | ✓ | ✓ | ✗ |
| Ore sorter | partial | ✓ via competition | ✓ natural | ✓ | ✗ |
| Collects what it removes | ✗ | ✗ (needs a holder) | ✓ | ✓ | ✗ |
| Conserves by construction | ✓ | ✓ | ✓ | ✗ | ✗ |
| Keeps rate and composition separate | ✓ | ✓ | ✓ | ✗ | ✗ |
| Node must know its topology | no | no | **yes** | no | no |
| New state to snapshot | no | no | no | no | no |

---

## 5. The sub-decisions, which matter as much as the option

### 5.1 Re-weight the mix, never the total

Two possible semantics, and they are **not** equivalent:

```
(a) renormalised    per_resource(r) = desired × w(r)·kg(r) / Σ w·kg      total unchanged
(b) absolute        per_resource(r) = desired × kg(r)/Σkg × w(r)         total changes
```

**Take (a).** Under (b) an affinity is secretly a throughput control, and this codebase has been
burned twice by two numbers describing one restriction. Throughput belongs to rates and
conductances; composition belongs here; the two should never be able to disagree.

It also gives the right answers. A separator on a line still delivers the mass the engine
demands — just drier, which is the point. A frothing boiler still passes the throttle's kg/s —
just wetter, so the engine gets less steam and some water, loses power, and eventually locks.
**That is exactly what priming does to an engine**, and it falls out of (a) with no special case.

### 5.2 How several tags on one resource combine

The existing gate is **OR within a port** (`(tags & accepts).any?`) and **AND across ports**
(`ports.all?`). The weights should mirror it exactly: **max within a port, product across
ports.** Anything else and the boolean gate stops being the limiting case of the weighted one,
which is how the two would drift apart.

The trap this avoids: with *product* inside a port, a port declaring `{ solid: 0.5, waste: 2.0 }`
gives ash — which is both — a weight of 1.0, silently neutral.

### 5.3 Allow resource keys as well as tag keys

Tags generalise, but sometimes the substance is the point. Let a key be either, with an exact
resource match taking precedence over any tag match. One rule, no ambiguity.

### 5.4 Never 0 and never infinity

A weight of zero re-implements the gate in a place where it does not belong, and a zero on the
wrong tag is a deadlock that looks like a tuning value. Clamp to a finite band and keep hard
exclusion in `accepts:`, where it is structural and visible in the operation definition. It also
means **misplacement always exists**, which §2.2 says is the truth about real separators and is
the more interesting game.

### 5.5 The material that does not cross stays where it was

Not a bug, a stated abstraction: the line only passes what it passes. A part that genuinely
*collects* must be a holder with its own outlet — the same rule `Obstructs` arrived at from the
other direction, since a conduit holds nothing and therefore cannot accumulate anything.

---

> ### CORRECTION — three things here did not survive implementation
>
> 1. **§5.4's clamp band was two orders of magnitude too tight.** ±10³ sounded generous and is
>    not: an affinity works against the mass ratio actually *held*, and a drum holding 2620 kg
>    of water against 6.2 kg of steam is 424 to 1. The 99.5%-dry steam a real drum delivers
>    needs a liquid weight near **1.2 × 10⁻⁵**, which a 10⁻³ floor silently rounds up into
>    violent priming. The band is ±10⁶. **A phase separator is the ordinary case, not an
>    extreme one**, and it is also why `Nodes::Boiler` declares a steam quality and solves for
>    the multiplier rather than taking one — nobody would have guessed 1.2 × 10⁻⁵, and a fixed
>    multiplier stops meaning the same thing the moment the level moves.
> 2. **§5.1 is right about rate-driven paths and wrong about pressure-driven ones.** "Re-weight
>    the mix, never the total" was reasoning from the case where the rating *is* a mass
>    throughput. A pressure solve rates the **gas**: moles crossing a conductance are unaffected
>    by a droplet hitching a lift, so entrained liquid rides *on top* and the gas figure is
>    preserved exactly. Entrainment is additive there and redistributive on a rate path — which
>    means **O5 was not wrong, it was right about one of the two cases** and §4 generalised too
>    hard in rejecting it.
> 3. **§1.1 said composition is decided in one place. It is decided in one place per *stream*,
>    and a pressure-driven path has two.** `settle_mass` partitions into gas (pressure-settled)
>    and bulk (rate-settled) *before* `apportion`, so liquid fell into the bulk stream where two
>    things went wrong at once: the rate is the **port's** rating, so a boiler primed at 4 kg/s
>    however gently it was fired; and `apportion` on a bulk list holding only water renormalises
>    to **100% water** whatever weight it is given, so the affinity was not ignored — it could
>    not apply. Measured: 424–518 kg of water in a 1 m³ steam chest and a burst flywheel on
>    every run, including at a calm 0.5% wetness. `Arbiter.entrained` is the repair.
>
> A fourth thing was found rather than corrected: **`contents_volume` is not a level.** It
> prices every parcel at nominal density, gases included, so the boiler read **317% full** and
> pinned its wetness at the foaming figure from the first tick. `Sources::Level` had the same
> bug, and its spec was passing by reading steam volume. `room_m3` had the right rule all along.

## 6. Recommendation

**O2, with §5's sub-decisions**, and O1 as its degenerate case rather than a separate feature.

Order of work:

1. **`Node#transport_affinity(port_id, state, ctx)`**, defaulting to `{}`, and a weighted
   `apportion`. Nothing changes behaviour until a node overrides it — the whole first step should
   be provably inert, and the specs should assert that.
2. **The cheap wins that are already bugs**: cylinder cocks preferring liquid, ash raking
   excluding fuel, the flue carrying water at a fraction rather than proportionally. Each is a
   measured defect in §1.4.
3. **A steam separator**, as the first part whose *whole purpose* is an affinity, with efficiency
   falling as flow rises (§2.3). This is the one that proves the dynamic half.
4. **Boiler frothing**, which unblocks priming, which makes hydraulic lock reachable and closes
   [`obstruction.md`](obstruction.md) §6 step 4. Only then is it worth re-sizing the cocks.
5. **A sorter**, when there is an operation that needs one — as the test that the abstraction
   reaches past the steam engine.

O3 is not rejected so much as **deferred**: the day something must genuinely divide its contents
between two destinations *and* keep what it removes, split fractions are the right tool and can
sit on top of affinity rather than replacing it. Nothing here forecloses it.

---

## 7. Verification

- **Inert by default.** With no node overriding the hook, every existing spec and the steam
  engine's digest must be **bit-identical**. This is the one that makes step 1 safe.
- **The boolean gate is the limiting case.** A weight of 1 on everything reproduces
  proportional-by-mass exactly; `accepts:` still blocks absolutely.
- **Conservation per resource**, with affinities in play: what leaves the source equals what
  arrives plus what the walls took, to float noise.
- **Composition changes, throughput does not.** Same rate, same total mass moved, different mix —
  asserted directly, because §5.1 is the decision most likely to be quietly undone.
- **Affinities compose along a path**: a separator halfway down a line gives the same result as
  the same affinity on the source port.
- **A sorter produces a partition curve.** Recovery and misplacement both non-zero, and
  sharpening the ratio moves recovery toward 1 without reaching it.
- **Under-delivery is visible.** An extreme affinity against a scarce resource must show up as
  rejected/short flow rather than silently moving less.
- `performance_spec` re-measured — `apportion` is on the hot path and this makes it do more work.

---

## 8. Sources

- [Separation and Mixing in Aspen Plus (FSplit, SSplit, Sep)](https://eiepd.com/wp-content/uploads/2023/07/Seperation-and-Mixer.pdf)
- [Aspen Plus Study Guide — splitter blocks and split fractions](https://www.aspentech.com/-/media/aspentech/home/cst-certification/aspen-plus-certification/study-guide-aspen-plus-basics)
- [Partition Curve — ScienceDirect Topics](https://www.sciencedirect.com/topics/engineering/partition-curve)
- [Tromp Curve — Example of a Partition Curve, 911Metallurgist](https://www.911metallurgist.com/blog/tromp-curve-example-partition-curve/)
- [Separators and their Role in the Steam System — TLV](https://www.tlv.com/steam-info/steam-theory/other/separators)
- [Separators — Spirax Sarco](https://www.spiraxsarco.com/learn-about-steam/pipeline-ancillaries/separators)
- [What is Boiler Carryover — causes, effects and prevention](https://feedwater.co.uk/boiler-carryover-cause-effect-prevention/)
- [Water Handbook, Chapter 16: Steam Purity — Veolia](https://www.watertechnologies.com/handbook/chapter-16-steam-purity)
- [Foaming and priming in boilers — Lenntech](https://www.lenntech.com/applications/process/boiler/foaming-priming.htm)
