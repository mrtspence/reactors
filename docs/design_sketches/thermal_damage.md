# Thermal damage: the mechanic that is already built and switched off

> **Status: BUILT, 2026-09-12.** All three pieces landed in the recommended order — materials,
> boiler tubes, crown sheet — plus the fusible plug. What follows is the sketch as written, kept
> because the reasoning stands; §5 records where the build departed from it, and it departed in
> one place that matters.
>
> Original framing: "we need to add thermal damage as a mechanic — it will be present EVERYWHERE
> in all sorts of operations. If the walls get too hot, they should wear out and fail." The
> finding was that most of it existed; what was missing was smaller and more specific than the
> request implied, and one part of it was a genuine physics gap rather than a configuration gap.

## 1. What already exists

Over-temperature fatigue is implemented generically, for every node that can hold or carry
anything, and has been since `Wearing` landed.

```ruby
# Concerns::Wearing — accumulates, then fails, deterministically
lost = stress_per_second(state, ctx) * ctx.dt
# ... durability hits zero -> [state, [failure_event(cause: :fatigue)]]

# Nodes::Vessel#stress_per_second
over_p = fraction_over(pressure_pa(state, ctx.content), @max_pressure_pa)
over_t = fraction_over(temperature_k(state, ctx.content), @max_temperature_k)
(over_p + over_t) * @stress_rate

# Nodes::Conduit#stress_per_second
over = temperature_k(state, ctx.content) - @max_temperature_k
over.positive? ? (over / @max_temperature_k) * @stress_rate : 0.0
```

It is proportional to the *fractional* overshoot, so a part 10% over its rating dies slowly and
one at double its rating dies fast; it is deterministic, so a player learns "I ran it too hot for
too long" rather than being told the dice disliked them; and it surfaces through `integrity`,
which is banded into prose and never shown as a number.

**Nothing in this repository declares a `max_temperature_k`.**

```sh
grep -rn "max_temperature_k:" lib/ content/ | grep -v "def \|@max\|Float::INFINITY"
#   (no output)
```

Every node in every operation ships the `Float::INFINITY` default, so `stress_per_second`
returns 0.0 on the first branch every time. The mechanic is complete, wired, untested in play,
and **inert because no part has ever been given a rating**.

That changes what this work is. It is not "add thermal damage"; it is three separate things,
and only one of them is new physics.

## 2. The three pieces

### (a) Ratings — configuration, not code

Give the parts that can cook a `max_temperature_k` and a `stress_rate`. On the steam engine the
honest candidates, with the temperatures they actually reach today:

| Part | Reaches | Plausible rating | What failing means |
|---|---|---|---|
| `boiler_tubes` | near firebox gas temperature, 900–1050 K | ~800 K | a burst tube: the classic boiler failure, and it puts the fire out |
| `flue` | 400–700 K | — | already cooled by ambient; not interesting |
| `firebox` | 750–1050 K | ~1400 K | burning out the grate and the brickwork |
| `cylinder` | steam temperature, ~430 K | — | not a thermal part; it fails on compression pressure |

`boiler_tubes` is the one worth having. It is the part that sits between the fire and the water,
it has no ambient loss at all (`ambient_conductance: 0.0`), and its temperature is set by the
balance between the gas scrubbing through it and the water carrying heat away. **Starve the
water side and the tube metal climbs** — which is the real mechanism, and it needs nothing new.

**Open question for the balance pass:** the tube wall currently sits near the *water*, not near
the gas, because `ThermalLink(boiler_tubes, boiler)` is 20 000 against a gas stream carrying far
less. That is deliberate and correct while the boiler has water in it. Whether the existing
lumped wall climbs far enough on low water to be a hazard is a measurement nobody has taken.

### (b) The crown sheet — the genuine gap

This is the one that cannot be configured into existence, and it is the failure Tim is actually
reaching for: **"a player might realistically fear running dry."**

Today a boiler is one lumped body. Its temperature is the mass-weighted mix of everything it
holds, which is dominated by water — so a drum at 5% water is at very nearly the same
temperature as a drum at 60% water, and `max_temperature_k` on the boiler would never trip. A
low-water boiler in this model is not hot. It is merely empty.

The real failure is positional and the lumped model has no positions. The crown sheet is the
plate over the firebox; while water covers it, it runs a few degrees above the water and is
safe at any fire. Uncover it and it is a steel plate with a fire on one side and steam — a poor
conductor — on the other. It reaches red heat in minutes, loses its strength, and lets go. This
is what destroyed locomotive boilers, and it killed crews, because the failure is not a leak: the
whole water content flashes to steam through the hole at once.

**What it would take.** The shape that fits this codebase is the one `Boiler` already uses for
swell — a derived quantity off the existing fill, not a new body:

```ruby
# Nodes::Boiler
# The fraction of the fire-side plate that water is not covering. 0 while the level is above
# the sheet; rises as the level falls past it.
def crown_exposure(state, content)

# Uncovered plate runs at fire temperature rather than water temperature, because steam
# cannot carry heat away fast enough to matter.
def stress_per_second(state, ctx)
  # blend water temperature and the sensed firebox temperature by crown_exposure,
  # then the existing fraction_over against max_temperature_k
end
```

`crown_sheet_fill:` — the fill fraction below which the plate starts to uncover — is one new
config number, and `senses:`-style coupling to the firebox is the one new relationship. It reads
the previous tick like every other cross-node read, so it breaks no invariant.

**It also needs its remedy shipped with it**, per `nodes/CLAUDE.md`: the remedy is the feed pump
and the fusible plug. A fusible plug is a soft-metal bung in the crown sheet that melts before
the plate does and dumps steam onto the fire — a loud, survivable, ruinous warning. That is a
better mechanic than the failure itself, and it is a `ReliefValve` with `senses_quantity:` set to
the crown temperature, which is a part that already exists.

### (c) Ratings as content, not as code

Tim's framing — "it will be present EVERYWHERE in all sorts of operations" — argues against
hand-writing `max_temperature_k:` at every call site. A temperature rating is a property of
**what a part is made of**, and this codebase already has materials in content: `Flywheel` takes
`material: :cast_iron` and reads its strength and density from `content/materials`.

The consistent move is the same one: a part declares its material, and its temperature rating
comes from there, with `stress_rate` staying per-part (how a given casting fails is a property of
the casting, exactly as `safety_factor` is on the flywheel). That keeps a hundred future
operations from each inventing their own number for "steel".

This is the piece that makes the mechanic *general* rather than one more steam-engine special
case, and it is worth doing before the ratings in (a) get sprinkled around by hand.

## 3. Recommended order

1. **(c) first, narrowly** — add `max_temperature_k` to the material rows that need it, and let
   `Vessel`/`Conduit` read a rating from `material:` when one is declared. Small, and it stops
   (a) from creating drift.
2. **(a)** — rate `boiler_tubes`, measure whether a starved water side actually cooks them.
3. **(b)** — the crown sheet, with the fusible plug shipped in the same change.

(b) is the one with a real design decision in it and the one that delivers what was asked for.
(a) is an afternoon. (c) is the difference between a mechanic and a special case.

## 5. Where the build departed from this sketch

**The fusible plug is not a `ReliefValve`, and this sketch was wrong to say it was.**

§2(b) proposed it as "a `ReliefValve` with `senses_quantity:` set to the crown temperature, which
is a part that already exists". That is a tidy reuse and it is the wrong part. **A relief valve
re-seats.** A fusible plug does not — it operates once, it cannot be undone from the footplate,
and the engine is out of service until somebody fits a new one. Built on the reversible base, a
boiler would have quietly healed itself the moment water came back over the plate, which is
precisely the consequence-free behaviour the low-water hazard exists to not have.

So `Nodes::FusiblePlug` is its own class and latches `melted` in state. The lesson generalises:
**a device whose defining property is that it is irreversible must not be built on one that is
reversible**, however similar the opening rule looks. Two parts that share an `if` are not the
same part.

It also sensed the wrong *kind* of thing. `ReliefValve#senses_quantity` names a **method**, and
`Context#node_reading` calls it as `method(state, content)` — which cannot work for a value that
is itself a cross-node read. `Boiler#crown_temperature_k` needs the firebox and therefore needs
`ctx`; handing it `content` fails at the first call. The plug senses a recorded **state key**
instead, the way `Conduit#blast_pa` already reads the cylinder's `exhaust_kg`. One node owns the
derivation; everyone else reads the number.

**Two things the sketch got right and are worth keeping.** Ratings belong on the material (§2c)
and doing that first did stop (a) from creating drift. And the "open question" in §2(a) — whether
the tube wall climbs far enough on low water to be a hazard — resolved cleanly: **561 K in normal
running against a 750 K rating**, so the tubes are never a nuisance failure, and they do burst
in a genuine runaway (867 K at feed 20, 1046 K at feed 0, with the plug scaled over).

**And one measurement that reframes the whole mechanic.** With the plug fitted the boiler *never*
ruptures — the crown peaks at the plug's 620 K and integrity stays at 1.00 in every run. Scale
the plug over and the crown reaches 1152 K and the shell goes at tick 7088. The iconic explosion
is there, sitting underneath the safety device, which is exactly the risk/reward the
modularisation plan wants from automatic safeties as luxury parts.

## 6. What this does *not* need

No new concern, no new tick phase, no change to `Wearing`, and no new failure plumbing —
`failure_event`, `integrity`, the prose banding and the event stream all already carry it. The
temptation to build a `Concerns::ThermalStress` should be resisted; `stress_per_second` is
already the extension point and it is already the right shape.
