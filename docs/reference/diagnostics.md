# Diagnostics

`lib/reactor_sim/diagnostics/`. The only thing that ever leaves the simulation.

Raw state never reaches a browser. Everything a client sees has been through an instrument,
which is what keeps ground truth inside the engine and makes the client legitimately dumb.

```
Source  ->  Filters  ->  Display
```

The base class enforces the shape and nothing else. Behaviour lives in composable pieces
because the properties compose — noisy, lagged, quantised, sticky, misread. A subclass per
combination would be `NoisyLaggedStickyGauge` and 2ⁿ siblings.

**"Upgrade your instrument" is literally "remove a filter from the list."**

---

## Shape

```ruby
Diagnostic.new(
  id:      :boiler_pressure,
  label:   "Boiler Pressure",
  source:  Sources::Derived.new(:boiler, :pressure_pa),
  filters: [ Filters::Lag.new(2), Filters::Noise.new(8_000.0),
             Filters::Range.new(0.0, 1.4e6) ],
  display: Displays::Needle.new(unit: "kPa", convert: :kpa, precision: 0,
                                min: 0.0, max: 1.4e6),
  observer: :grubwick   # reserved for minions; inert for now
)
```

---

## Sources — stateless, pure

| Source | Reads |
|---|---|
| `Field.new(node, key)` | A raw **numeric** field out of a node's state hash |
| `Flag.new(node, key)` | A **boolean** state key, as 1.0 / 0.0 — feeds a lamp |
| `Derived.new(node, quantity)` | Something the node computes |
| `Level.new(node)` | How full, 0–100 |
| `Contents.new(node, resource)` | kg of one substance inside a mixture |
| `Durability.new(node)` | Remaining durability, absolute |
| `Broken.new(node)` | 1.0 / 0.0 — feeds a lamp |
| `Aggregate.new([sources], operation: :sum \| :max \| :min)` | One number across many nodes |

`Derived` accepts only the quantities in `Sources::Derived::SIGNATURES` — a snapshot, and
`ruby -Ilib -e 'require "reactor_sim"; puts ReactorSim::Sources::Derived::SIGNATURES.keys'`
is the truth: `temperature_k`, `pressure_pa`, `contents_volume`, `room_m3`, `occupancy`,
`compression_pressure_pa`, `effective_fill`, `contents_kg`, `omega`, `rpm`, `rim_speed`,
`kinetic_joules`,
`stress_fraction`, `integrity`.
**Add new ones there** with the right arity (`:with_content` or `:state_only`) or the source
will not build — it raises at construction rather than reading nothing at runtime.

A source that cannot read reports unavailable, and the diagnostic flags `:offline` rather
than reporting a fabricated zero.

### `Field` reads numbers; `Flag` reads booleans

`Field` ends in `Reading.of(value)`, which calls `to_f` — and `true.to_f` does not exist, so a
boolean state key **raises** rather than reading wrong. That is the right failure and `Field`
must not be taught to coerce: a flag has no scale, no noise and no units, and the only sensible
display for it is a lamp. `Flag.new(node, key)` is the reader for those; `Broken` is the same
shape hardwired to one key, and was the precedent.

### A transport node has to publish before it can be gauged

`Field` reads a node's state hash, and **a conduit's state hash contains almost nothing**: it
holds no material, so the arbiter leaves no parcels behind and there is nothing for a gauge to
find. That made the parts that act unsupervised — relief valves above all — the parts a player
could not watch, which is precisely backwards.

`ReliefValve#apply` therefore writes `lift:` into its own state purely so an instrument can read
it. If you need to gauge something a transport node does, the node has to record it in `apply`
first; there is no generic flow figure in state to reach for.

Not every gauge deserves a distortion. `safety_valve` on the steam engine has **no lag and no
noise** because a valve blowing off is the loudest thing in the building — the player is not
reading a dial at all. That is also what makes it worth fitting next to a pressure gauge that is
two ticks late and ±8 kPa: the moment the boiler starts wasting steam is the moment that needle
is least trustworthy.

Anything needing memory is a **filter**, not a source — that is why `Rate` is a filter.

---

## Filters — stateful, applied in order

| Filter | Effect |
|---|---|
| `Lag.new(ticks)` | Reports what was true n ticks ago. Flags `:warming_up` until it has history. |
| `Noise.new(magnitude, deadband: nil)` | Offsets the reading. **Holds the offset until the value moves past the deadband.** |
| `Range.new(min, max)` | Clamps to the instrument's scale. Flags `:pegged_low` / `:pegged_high`. |
| `Quantize.new(step)` | Coarse dial increments. |
| `Bands.new([thresholds])` | Collapses a value to a band index — pair with `Prose`. |
| `Stick.new(chance:, release_chance:)` | Needle catches and holds. Flags `:stuck`. |
| `Misread.new(chance:, magnitude:)` | An observer occasionally and confidently wrong. Flags `:misread`. |
| `Average.new(window)` | Mean of the last `window` readings. Flags `:warming_up` until full. |
| `Rate.new` | Change per simulated second. |

### Average is for oscillation, not for taste

`Average` exists because the cylinder genuinely alternates between two values on successive
ticks — a period-2 limit cycle against a supply it reads one tick behind — which made a digital
readout unreadable and a needle flicker across half its scale.

Reach for it when the underlying quantity oscillates, not when a reading merely feels busy. A
twitchy needle is a legitimate diagnostic signal and smoothing it away costs the player
information. Note also that averaging an oscillation is honest at 4 Hz — a tick spans many
power strokes, so indicated power is already a mean over strokes and the only question is the
window — whereas averaging *noise* would be laundering a distortion into apparent precision.

Put it **first** in the chain. Lagging or quantising an oscillation just gives you a lagged
oscillation.

### The noise deadband matters

With a fresh draw every tick, every noisy gauge reported a change every tick forever and
"send only what changed" compressed nothing. Holding the offset until the signal actually
moves is both more honest — a miscalibrated gauge reads *consistently* wrong — and what makes
the delta protocol worth having. Default deadband is the noise magnitude.

### `distortion?` decides what a spectator sees

A god-view skips filters that make a reading **worse** but keeps those that change what it
**means**.

- `distortion? == true` (default): Lag, Noise, Range, Quantize, Stick, Misread
- `distortion? == false`: **Bands, Rate, Average**

Get this wrong and a rate instrument reports the raw temperature in a box labelled K/s.
`Diagnostic#record` runs two parallel chains — one full, one distortion-free — each with its
own state, because a stateful transform sees different inputs on each. The undistorted pass
draws **no entropy**, since only distorting filters ever do.

---

## Displays — pure formatting

`Needle`, `Digital`, `Lamp`, `Prose`. The **only** place unit conversion may happen:
everything inside the sim is SI, and Kelvin becomes °C here or not at all (`convert: :k_to_c`,
`:kpa`, `:kilo`).

`Prose.new([phrases])` fed by a `Bands` filter is how durability becomes readable without
ever becoming a health bar: *"the fitting is showing some cracks."*

> **A display's own `label:` never reaches the client.** `Diagnostic#chrome` is
> `@display.chrome.merge(id: @id, label: @label)`, so the diagnostic's label always wins and
> `Lamp.new(label: "RUPTURE")` has never once shown that word. `loop_rig` still passes one. Name
> the lamp through the `Diagnostic`, not the display.

---

## Record vs read — the property everything rests on

**`record` runs once per tick and is the only thing allowed to draw entropy. `read` is a pure
lookup.**

A tick may be projected any number of times — a player view, a spectator view, a resync of
either. If reading drew noise, how many people happened to be watching would change the
match. Never move a draw into `read`.

---

## Projection

```ruby
op.project(viewer: :player | :spectator, tick:)  #=> PlayerView
op.panel                                          #=> instrument + lever chrome, sent once
```

```ruby
PlayerView(tick:, operation_id:, viewer:, gauges:, flags:, controls:, incidents:, crew:)
  #.delta_from(previous)  # only what changed — what goes over the wire each tick
  #.unchanged_from?(previous)
```

`controls` reports `{ target:, actual: }` per lever, so a client can show a valve that is
still travelling.

`crew` reports `{ station:, injury: }` per minion — **only what changes.** A minion's name, job
and race are configuration and reach the client once with the panel; where they are standing and
what has happened to them are state.

It exists because the console's crew dropdown could *send* an assignment with no source of truth
to display one, so it rendered at its first option whatever the real posting was, and a
reassignment, a reset or a restore was never reflected back. **A station's output now depends on
who is at it**, which makes this load-bearing rather than chrome: an effort lever that does
nothing because nobody is manning it is indistinguishable from a broken machine unless the panel
can say so.

### `incidents` are appended, not merged

Everything else in a view is *state* and merges; incidents are a **record of what happened on
one tick**. The simulation replaces its event list every tick, so a client that assigns rather
than appends loses the entry one tick after it appears.

A failure event carries more than the fact of it, and the panel is expected to use all of it:

| Field | What it is for |
|---|---|
| `mode` | **what the part became** — `explosion`, `blown_head`, `scored_bore`. The headline |
| `cause` | `:fatigue` or `:overload` — the post-mortem, not the lead |
| `severity` | `:critical` or `:warning`, and they must not look alike |
| `escalated_from` | present only when the part was already broken and got worse |
| `damaged` | node ids this failure took with it, or absent |
| `detail` | per-part forensics: rpm at burst, occupancy, pressure |

**Lead with `mode`, not `cause`.** What a part became decides what the operator does next; what
broke it is history. The console led with the cause for a while and buried the one fact that
mattered. And a fusible plug doing its job must not read like a boiler letting go — those are a
ruined day against a ruined engine, and `severity` is what separates them.

Spectators get `truth` (undistorted, transforms applied) and no instrument flags — they have
no instrument.

### `flags` is sparse, and the delta says so explicitly

An instrument with nothing to say has **no key** in `flags` — `project` only writes one when
the list is non-empty. That makes the map cheap, and it makes one thing easy to get wrong.

Rejecting unchanged entries is not sufficient on its own, because `reject` iterates the
*current* flags and an instrument whose flags cleared is not among them. The clear then never
gets mentioned, and a client merging deltas goes on showing `:pegged_high` forever after a single
pressure excursion. `:warming_up` is worse: every lagged gauge raises it for its first few ticks,
so a fresh panel lights up with warnings that can never be retracted.

`delta_from` emits an **explicit empty list** for an instrument that fell silent, so a merge
clears it. `unchanged_from?` reads the same path, which is what stops the runner skipping a
broadcast that would have cleared a warning.

A client may therefore merge each section of a delta over its previous state and never needs
to diff flags itself.

---

## Adding a gauge: checklist

1. Pick a source. If the quantity is derived, make sure it is in `SIGNATURES`.
2. Chain filters in the order the physical instrument would apply them — usually lag, then
   noise, then scale.
3. Pick a display and put any unit conversion there.
4. Add it to the operation's panel catalogue **and to its panel order** — the order is what
   decides where it sits, and `Assembly` refuses a gauge the order does not name rather than
   quietly appending it to the end.
5. Decide which part it arrives with. Most gauges are *named* by a part (`instruments: %i[…]`)
   and defined in the panel; a gauge that is itself a fitting is built by that part instead —
   see below.
6. If you add a **new filter class**, decide `distortion?` deliberately and spec it. Unused
   palette pieces get specced too — an upgrade slot nobody has exercised is one that will not
   work when it is first reached for.

## When the gauge is itself a part

Most instruments belong to a machine part: the wheel stress gauge arrives with the flywheel, the
crown sheet with the boiler. Those name gauge ids and the panel holds the definitions, which is
what keeps the reasoning about how each one lies in one readable file.

**A gauge that is a separate object gets to be a part.** The boiler pressure gauge is a brass
instrument screwed to the drum, and its full-scale reading is a property of *it* — a 0–14 atm
dial and a 0–4 atm dial are different fittings, chosen to suit the boiler. Treating that as a
property of the machine is what stranded `burst_pa` on the steam engine's chassis for a week.
Such a part builds a `Fragment` carrying `diagnostics:`; the definition still lives in the panel
and the part passes it figures.

> **An instrument upgrade may reduce a filter. It may never remove a class of one.** Less lag,
> less noise, a finer band — never zero lag, and never a number where the design chose prose.
> Three gauges on the steam engine are exempt outright: `safety_valve`, which is *true* by design
> because the player is not reading a dial at all, and `crown_sheet` and `flywheel_condition`,
> whose vagueness **is** the hazard they name.
>
> The reason is the whole premise of this file: the instruments are not an obstacle between the
> player and the game, they *are* the game. A panel that can be bought into telling the truth has
> sold the only thing it was protecting.

The steam engine has two instrument slots — `:boiler_gauge` and `:water_glass` — and both are
**optional**, which is the same bargain the safety devices offer applied to what a driver can
*see* rather than to what can break. The water gauge is the sharper of the two: the crown sheet
is what destroys that boiler and the glass is the only notice of it.

A downgrade is a filter **added**, not a bigger number in an existing one. Try-cocks are taps at
fixed heights — a `Quantize` on top of the usual three — which is a different instrument rather
than a worse glass, and historically exact, since cocks predate the glass and many boilers
carried both.

### Measure an instrument tier against a running engine, or ship a placebo

Both water-gauge tiers were wrong on the first pass, and both looked fine until measured:

- **Try-cocks at 25% steps never moved at all.** Over 1400 ticks of a level swinging 44% → 56%,
  the whole working band sat inside one step: not a coarse gauge, an absent one. 10% steps read
  in visible jumps and still carry a trend.
- **A reflex glass over a ±1.2% plain glass is a placebo.** It cuts noise three-fold and no
  player can tell, because the display reads **whole percent** and ±1.2% is already smaller than
  one unit of what is shown. The plain glass sits at ±2.5% so there is something for an upgrade
  to improve on.

> **A filter finer than the display's precision does not exist.** Check a proposed tier against
> `Displays::Needle`'s `precision:` before believing it changes anything.

Measured mean error against the spectator's truth, level moving: try-cocks 3.3%, gauge glass
0.8%, reflex glass 0.3%. Note the *maximum* error stays near 10–17% on all three — that is
**lag** during a fast change, which no tier removes, so the swell trap survives every upgrade.
`spec/reactor_sim/diagnostic_spec.rb` asserts the ordering and never the figures.
