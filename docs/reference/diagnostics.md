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
| `Field.new(node, key)` | A raw field out of a node's state hash |
| `Derived.new(node, quantity)` | Something the node computes |
| `Level.new(node)` | How full, 0–100 |
| `Contents.new(node, resource)` | kg of one substance inside a mixture |
| `Durability.new(node)` | Remaining durability, absolute |
| `Broken.new(node)` | 1.0 / 0.0 — feeds a lamp |
| `Aggregate.new([sources], operation: :sum \| :max \| :min)` | One number across many nodes |

`Derived` accepts only the quantities in `Sources::Derived::SIGNATURES`:
`temperature_k`, `pressure_pa`, `contents_volume`, `room_m3`, `contents_kg`, `omega`, `rpm`,
`rim_speed`, `kinetic_joules`, `stress_fraction`, `integrity`. **Add new ones there** with
the right arity (`:with_content` or `:state_only`) or the source will not build.

A source that cannot read reports unavailable, and the diagnostic flags `:offline` rather
than reporting a fabricated zero.

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
| `Rate.new` | Change per simulated second. |

### The noise deadband matters

With a fresh draw every tick, every noisy gauge reported a change every tick forever and
"send only what changed" compressed nothing. Holding the offset until the signal actually
moves is both more honest — a miscalibrated gauge reads *consistently* wrong — and what makes
the delta protocol worth having. Default deadband is the noise magnitude.

### `distortion?` decides what a spectator sees

A god-view skips filters that make a reading **worse** but keeps those that change what it
**means**.

- `distortion? == true` (default): Lag, Noise, Range, Quantize, Stick, Misread
- `distortion? == false`: **Bands, Rate**

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
PlayerView(tick:, operation_id:, viewer:, gauges:, flags:, controls:, incidents:)
  #.delta_from(previous)  # only what changed — what goes over the wire each tick
  #.unchanged_from?(previous)
```

`controls` reports `{ target:, actual: }` per lever, so a client can show a valve that is
still travelling.

Spectators get `truth` (undistorted, transforms applied) and no instrument flags — they have
no instrument.

---

## Adding a gauge: checklist

1. Pick a source. If the quantity is derived, make sure it is in `SIGNATURES`.
2. Chain filters in the order the physical instrument would apply them — usually lag, then
   noise, then scale.
3. Pick a display and put any unit conversion there.
4. Add it to the operation's diagnostics list.
5. If you add a **new filter class**, decide `distortion?` deliberately and spec it. Unused
   palette pieces get specced too — an upgrade slot nobody has exercised is one that will not
   work when it is first reached for.
