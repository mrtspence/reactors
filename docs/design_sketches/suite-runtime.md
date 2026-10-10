# The suite takes two hours, and almost all of it is settling

Design input. The suite has become the slowest thing in the development loop, and the cause is
measurable rather than diffuse.

---

## 1. What the time actually goes on

**A tick costs ~10 ms, for either operation.** Measured on current content: mine 9.93 ms/tick over
400 ticks (26 nodes), steam engine 8.94 ms/tick (32 nodes). They are within 11% of each other, so
there is no "the mine is the slow one" — the suite's cost is simply **ticks executed**, and two
hours is about 720,000 of them.

Static tick counts per file, which predict measured wall time well (mine_tech estimates 13 min
against 17 measured):

| File | ticks | examples |
|---|---|---|
| `steam_engine_spec` | 114,900 | 46 |
| `mine_tech_spec` | 79,500 | 17 |
| `firedamp_spec` | 56,400 | 14 |
| `dust_spec` | 45,000 | 9 |
| `blackdamp_spec` | 42,900 | 14 |
| `slip_spec` | 23,500 | 11 |
| `cage_spec` | 23,000 | 10 |
| `afterdamp_spec` | 18,200 | 7 |
| `crown_sheet_spec` | 18,000 | 6 |
| `mine_spec` | 17,800 | 21 |
| *(remaining 10 of the top 20)* | ~66,000 | — |

**And almost none of those ticks are the measurement.** They are *reaching a state*: a cold start
to a hot engine, 600 ticks of walking a shift to its posts, 3,000 ticks of letting the air settle.
Every example pays it again from scratch.

## 2. The finding that changes the shape of the problem

```
build a mine from cold            16.8 ms
settle it (3000 ticks)        30,316.5 ms   ← what every example pays today
serialise the settled state        0.7 ms
restore from that state            7.6 ms
```

**Restoring a settled operation is 3,985× cheaper than re-settling it** — and it is
*bit-identical* (`canonical` digests match) and *carries on identically* (200 further ticks on
each leave the two indistinguishable). That is not a trick; snapshot fidelity is an existing
invariant with its own specs, and this is simply using it.

So the first lever needs no change to what any spec *claims*:

> **Settle once per distinct precondition, snapshot it, restore per example.** One `light_and_run`
> becomes one 36-second cold start for the whole file instead of 46 of them.

For `steam_engine_spec` alone that is ~27 minutes of cold starts replaced by ~36 seconds plus 46
restores of 7.6 ms each.

### Why this is better than the memoisation already in `peril_spec`

That file memoises the *operation* and hands the same mutable object to several examples — which
worked and cut it from 13m31s to 4m10s, but it shares state between examples, which is a smell
whatever the comment says. A restore gives each example its **own** operation at the same settled
state: faster *and* properly isolated. `peril_spec` should be converted too.

## 3. The second lever: a mechanism does not need an operation

Every module a person is subject to is already **pure over a state hash** — `Injury`, `Fatigue`,
`Breath`, `Scorch`, `Peril`/`Blunder`, `Burden`. A claim about how one *behaves* can be made
against the module directly, and the cost difference is four orders of magnitude.

Measured this week, in one file: `carrying_spec`'s **12 unit examples run in 33 ms**; its 7
integration examples take **2m13s**. Same file, same mechanic, 2,400× the cost per claim.

So the split is:

| Question | Where it belongs |
|---|---|
| Does the arithmetic do the right thing? | the pure module, directly |
| Is it *wired* — does this operation actually read it? | one integration example |
| Does the whole machine still balance and conserve? | the per-operation integration spec |
| Does phase order still hold? | integration, and only where order is the claim |

## 4. On "they couple to a tuning value rather than guarding a mechanic"

Partly true, and I cannot measure it cleanly enough to say how much. A crude classification of
assertion shapes puts `steam_engine_spec` at 22 bare thresholds and 7 pinned numbers against 9
relational comparisons — the most tuning-coupled file by a distance — while the mine's specs come
out more relational. **Those regexes miss a lot and should not be quoted as a finding**; they are
only a hint about where to read first.

The honest version: the *cost* is not in the assertions at all, it is in the setup. Rewriting a
threshold into a relationship is good hygiene and buys **no** time. That is worth saying plainly
so the work gets aimed at the setup, where the two hours are.

## 5. Proposed plan, in order of prize over risk

1. **`spec/support/settled.rb`** — a helper that settles a named precondition once per suite run,
   snapshots it, and hands out fresh restores. Generated at run time, never committed: a stored
   blob would rot and would hide the very physics changes the suite exists to catch.
2. **Convert the top five files** to restore from it — `steam_engine`, `mine_tech`, `firedamp`,
   `dust`, `blackdamp`. That is ~340,000 of the ~505,000 counted ticks.
3. **Move mechanism claims down** to the pure modules, file by file, deleting the integration
   example only where a unit example genuinely replaces it.
4. **Leave each operation one or two integration specs** that still go from cold, per the brief —
   which is also the mitigation in §6.
5. **Re-measure.** The target worth stating out loud: **under twenty minutes.**

## 6. The risk, and what guards it

**A restored fixture cannot catch a bug in the settling path.** If reaching a hot engine breaks,
every example that starts from a snapshot of a hot engine still passes.

So the per-operation integration spec that starts **from cold** is not a nicety — it is what makes
the rest of the suite trustworthy, and it is exactly what the brief already asks to keep. The six
specs a new operation owes (`guides/build-an-operation.md`) stay as they are: cold start, output,
failure, long run with nothing to report, conservation, snapshot round-trip.

Two smaller guards:

- **Conservation specs must not be converted.** They need a real graph running for a real span,
  and they are the specs that have historically caught actual physics bugs.
- **Determinism and digest specs must not be converted**, for the obvious reason.

## 7. What actually worked, and it was neither of the two levers above

> **`spec/support/settled.rb`, proposed in §5 and built, is gone.** Constructing a precondition
> beat caching one everywhere it applied, so its last caller disappeared and a spec helper with no
> callers rots. The measurements above are the record; the code is not worth keeping for them. What
> survives of the idea is its rule — *the one thing that must not be built on a shortcut is the
> path that reaches the state* — now carried by `mine_spec`'s real walk and `steam_engine_spec`'s
> real cold start.


Both levers in §2 and §3 are real and both were applied. **Neither is the finding.** The finding,
which came from the brief rather than from this document, is that *waiting* was never necessary:

> *"The fundamental issue is that we are waiting for ticks rather than handing it the setup that
> actually cuts to the part that matters. Everything is deterministic — we should be able to build
> exactly what we need as starting state and then only run the important ticks."*

State is a plain hash and the engine is deterministic, so a precondition can be **constructed**
rather than reached. Measured:

| Claim | Reached by running | Constructed |
|---|---|---|
| What a 7% firedamp mixture does at a flame | ~2,400 ticks of seepage, one arbitrary point | 0 ticks, **both limits**, 40 ms |
| Whether the regulator wire-draws | 3,600-tick startup × 2 | 40 ticks × 3 levers |
| That a banked grate chokes the fire | 7,200 ticks × 2 | **0 ticks** — read off the state |
| That the wheel bursts when the load is shed | 4,200 ticks | 40 ticks |
| That the safety valve pins the drum | 4,000 ticks | 60 ticks, from three seeds |

`spec/support/ignition_rig.rb` and `spec/support/engine_rig.rb` are the two rigs. The engine's
whole spec went from 38 runs of up to 7,200 ticks to **nothing over 100 ticks**, with 32 more
examples of coverage than before.

### The three ways a constructed state is a lie, and what closes each

1. **A key the node does not read.** A node's own temperature is stored as `joules`; patching
   `temperature_k:` adds a dead key, leaves the wall at ambient, and it then quietly robs the hot
   water put in beside it. `EngineRig#seed` **refuses any key the built state does not have**.
2. **Energy that does not match the temperature.** Parcels go through `Parcel.build`, which derives
   enthalpy from specific heat — hand-written `joules` is how you get a drum at a temperature its
   contents cannot explain.
3. **A state the simulation could not reach.** Every figure `EngineRig#at_work` writes was *read off a
   running engine*, and the first example in `engine_stages_spec` asserts a seeded engine **carries
   on without a transient** (607.5 → 608.3 kPa over 400 ticks). Without that check a seed drifts:
   seeding the cylinder at drum temperature puts compression above the relief valve's setting, so
   every "ordinary run" is quietly an engine lifting its valve on every stroke.

### A composite is not a separate claim

A whole startup is the *sum* of the stage claims, so running one re-proves each slice in sequence
at a hundred times the price. Warming through is the worked example: it decomposes into a cold
casting condensing more than a warm one, the cocks draining it, revolutions sweeping it out, and
the relief valve venting what is left. **It also cannot be constructed faithfully** — a cold
cylinder on a working engine reads occupancy 0.011 against the 0.859 a slow warm-up reaches,
because a turning engine sweeps the water out. That is the third slice, which is the point.

What survives as a whole-machine run is only what no constructed state can stand in for: **that a
cold machine can be brought to life at all**, because a fixture starting from a hot engine cannot
fail when the path to a hot engine breaks. That needs 100 ticks — the fire is alight at tick 11.

### The mine, and the two shapes of claim that resist it

The mine had **two** costs where the engine had one: the **walk** (up to 2,000 ticks of people
going down a shaft) and the **make** (two to twelve thousand while gas seeped, dust settled or
water rose). `at_the_face` and `district_mix`/`bottom_mix` remove both, and the arrival is
checkable: a constructed one is **field-for-field identical** to a walked one, which `mine_spec`
asserts — and `mine_spec` keeps a real walk, because a constructed arrival cannot fail when the
walking breaks.

Converting ten files surfaced two kinds of claim that do not shorten, and both are worth naming:

1. **A failure that is really an erosion rate.** A district ruptures after ~600 ticks of fire and a
   fissure gives way after ~12,000 of hard driving. Waiting measures the *rate*; seeding the part
   **part-worn** measures the failure. Both are real claims and they want separate examples — the
   rate belongs to the node that owns it, the failure to the spec.
2. **An equilibrium.** What a better fan buys is the balance between its throughput and the
   ground's make, and a balance takes thousands of ticks to settle into. The short form is its
   **sign**: seed the district at a working concentration and see which way each fan moves it. On
   the gassiest ground the waddle settles at 0.92479 and the Guibal at 0.93081, either side of the
   0.93 safe line — the same claim, in 200 ticks.

Three claims came out **stronger** for being constructed rather than reached, which is the general
case and not a consolation: stone dusting is now the whole suppression curve rather than one
comparison (1963 K bare, 733 K at 130 kg of stone, **293 K and no ignition at all** at 400); the
flame lamp's warning gap is a concentration sweep rather than a single crossing (it warns at 4%
blackdamp while the air is still breathable at 0.9644, and the air does not go unsafe until 8%);
and `blackdamp_spec`'s long-broken "starves the fire" example turned out to be asserting the wrong
quantity entirely — it demanded that 20–90% of the gas survive, where 97–99% is consumed at every
level and what displacement actually does is make the fire **cooler** (2379 → 1935 → 1544 K).

### "A handful of ticks" is the real target, and most claims reach it

Cutting a 12,000-tick example to 200 feels like success and is not. **If an example still needs
hundreds of ticks, something in it is still being waited for** — so find what, and seed that too.
Pushed to the end, almost everything turns out to be derived from state that could have been
handed over:

| File | Before | After | Max ticks |
|---|---|---|---|
| `crown_sheet_spec` | 935 s | **1.2 s** | 20 |
| `injury_spec` | 156 s | **0.3 s** | 20 |
| `diagnostic_spec` | 117 s (2 examples) | **2.5 s** (45) | **0** |
| `event_spec` | ~35 s | **4.2 s** | 50 |
| `carrying_spec` | ~119 s | **12.2 s** | ~460 |

Three findings from doing it, all of which made the test better rather than merely faster:

1. **Two claims in one example is what forces the long window.** The diagnostic tiers bundled *a
   drum's reading swells* with *a coarse instrument distorts a moving reading*. The first is the
   boiler's and belongs in `crown_sheet_spec`; the second is the **filter chain's**, and a filter
   chain does not care where its numbers came from — so it takes a synthetic signal and costs
   **no ticks at all**. Splitting them also exposed that the tiers differ in filter *parameters*
   rather than classes, and that the signal is a **fraction, not a percentage** — fed percentages,
   every chain clamps on its `Range(0.0, 1.25)` and all three read identically.
2. **Seed the state, then seed its consequence separately.** "Out of service without destroying the
   boiler" was the plug melting *and* the fire going out. A plug seeded **already blown** tests the
   consequence instead of re-measuring the melt. Note `melted:` alone is not enough — the plug
   re-derives it from `fusible_remaining_kg` every tick, the same stored-versus-derived trap as the
   firebox's `alight`.
3. **A long run can be hiding a weaker claim.** "Stays melted with the feed restored" starved a drum
   for 12,000 ticks and then opened the feed — which left the plate still bare, so it never offered
   the plug the chance to re-seat it was supposed to refuse. Seeded into a *full* drum at exposure
   0.0000 it is the condition a `ReliefValve` would actually heal under.

### When a claim is a rate, find the function that computes it

Three times now the thing a long sample was measuring turned out to be a **pure function** sitting
right there, and sampling it was both slower and worse:

| Claim | Was | Is |
|---|---|---|
| a coarse gauge misreads more than a fine one | 2,200 ticks of a boiler | the filter chain on a synthetic signal, **0 ticks** |
| a boneheaded hand fumbles a lever more often | 9,000 ticks of sampling | `ControlPoint#slip_chance`, **0 ticks** |
| a poor hand spends margin faster than a sound one | two shifts compared | `Blunder.spend`, **0 ticks** (already done) |

`slip_spec` is the clearest case, because sampling was not merely slow — it was **wrong**. Slips
arrive in bursts of `SLIP_TICKS`, so a sample has to catch several before two hands can be ordered
at all: at 200 ticks the kobold and the uncertificated hand tie at thirteen apiece and the ordering
claim reads as false. The rates are 0.01002 and 0.00578 per tick and always were. Asking the
function also bought two claims a sample could never make — that an ordinary valve is **exactly**
zero for an unsuited hand, and that doubling `boneheaded` doubles the chance to nine decimal
places.

The signature of this case: an example that counts occurrences, or averages an error, or compares
two tallies. Something decided it per tick, and that something takes arguments.

### Achievements must not cost an integration test each

`event_pipeline_spec` raised steam from cold for 1,700 ticks so that a `ProgressionDigest` could be
handed real records. Most of what that bought is available in **thirty** ticks from a constructed
engine, because the transitions are edge-triggered: `fire_lit`, `steam_raised` and `heater_engaged`
are announced on the tick the engine first reads its own state (with one pulse of the igniter for
the pilot). What it should never have bought is an *achievement* unlock.

**Whether a sequence of records earns an award is a rule about record ordering**, and
`progression_digest_spec` already takes synthetic records for exactly that reason. One integration
test per achievement does not scale, and the cold-start award is the proof: 1,700 ticks were being
spent to discover that three records arrived in the right order — and the example got the answer
backwards first, because disqualification is **windowed**, so the pilot that lights every real fire
falls outside the interval it would otherwise forfeit. Three records are the whole test.

The event *budget* claim improved too. "Fewer than twenty records" says the window was short;
**the count not moving between a 30-tick window and a 400-tick one** says the records are
transitions, which is the property the design actually rests on. Measured: four, and four.

### Measuring the wrong quantity is the other trap

A fast spec makes it cheap to measure something adjacent to the claim. Draught was first measured
as *the air a firebox holds*, which is a **stock**: it tracks the draught only while consumption is
equal on both sides of a comparison, so a dead fire — consuming nothing — accumulates 6.3 kg
against a working fire's 0.98 and reads as six times the draught. The flow across the damper
(`carried_kg`) is the quantity a blower, a stack and a blastpipe all act on.

## 8. What I would not do

- **Not parallel execution.** It hides the cost rather than removing it, and the suite's whole
  value is that a figure is reproducible — a flaky parallel suite would cost more than two hours.
- **Not committing fixture blobs.** They rot silently, which is the failure mode this codebase
  writes rules against.
- **Not cutting tick counts by guesswork.** Several of those windows are load-bearing: a 3,000-tick
  settle in `afterdamp_spec` is what puts the district in the explosive range at all, and the
  comment there says so. Shortening a window needs the same measurement that chose it.
