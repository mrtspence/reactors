# `diagnostics/` — the only thing that leaves the simulation

Raw state never reaches a browser. Everything a client sees has been through an instrument,
which is what keeps ground truth inside the engine and lets the client be legitimately dumb.
Reference: [`docs/reference/diagnostics.md`](../../../docs/reference/diagnostics.md).

```
Source  ->  Filters  ->  Display
```

The base class enforces that shape and nothing else. Behaviour lives in composable pieces
because the properties compose — noisy, lagged, quantised, sticky, misread. A subclass per
combination would be `NoisyLaggedStickyGauge` and 2ⁿ siblings.

**"Upgrade your instrument" is literally "remove a filter from the list."** Keep it that way.

## The property everything rests on

**`record` runs once per tick and is the only thing allowed to draw entropy. `read` is a pure
lookup.**

A tick may be projected any number of times — player view, spectator view, a resync of
either. If reading drew noise, how many people happened to be watching would change the match.
**Never move a draw into `read`.**

## Sources — stateless, pure

`Field`, `Derived`, `Level`, `Contents`, `Durability`, `Broken`, `Aggregate`. A snapshot; the
palette is the truth:

```sh
grep -oP '^\s{4}class \K\w+' lib/reactor_sim/diagnostics/sources.rb   # sources
grep -oP '^\s{4}class \K\w+' lib/reactor_sim/diagnostics/filters.rb   # filters
```

`Derived` accepts only the quantities listed in `Sources::Derived::SIGNATURES`. **Add new ones
there**, with the right arity (`:with_content` or `:state_only`), or the source will not build.
`SIGNATURES` is a third inventory list — a new entry belongs in
[`docs/reference/diagnostics.md`](../../../docs/reference/diagnostics.md) too, since that is
where a gauge author looks before reaching for a quantity.

A source that cannot read reports unavailable and the diagnostic flags `:offline`, rather than
reporting a fabricated zero.

**Anything needing memory is a filter, not a source.** That is why `Rate` is a filter.

## Filters — stateful, applied in order

`Lag`, `Noise`, `Range`, `Quantize`, `Bands`, `Stick`, `Misread`, `Rate`, `Average`. Derive
with the command above.

**`Average` goes first in a chain.** It exists for genuine oscillation — the cylinder alternates
between two values on successive ticks — and lagging or quantising an oscillation just gives
you a lagged oscillation. Do not reach for it to calm a reading that is merely busy: a twitchy
needle is a diagnostic signal.

### `distortion?` must be decided deliberately

A god-view skips filters that make a reading **worse** but keeps those that change what it
**means**.

- `distortion? == true` (the default): Lag, Noise, Range, Quantize, Stick, Misread
- `distortion? == false`: **Bands, Rate, Average**

Get this wrong and a rate instrument reports the raw temperature in a box labelled K/s.
`Diagnostic#record` runs two parallel chains — one full, one distortion-free — each with its
own state, because a stateful transform sees different inputs on each. The undistorted pass
draws **no entropy**, since only distorting filters ever do.

### The noise deadband matters

`Noise` holds its offset until the value moves past the deadband (default: the noise
magnitude). With a fresh draw every tick, every noisy gauge reported a change every tick
forever and "send only what changed" compressed nothing. Holding the offset is also more
honest — a miscalibrated gauge reads *consistently* wrong.

## Displays — pure formatting

`Needle`, `Digital`, `Lamp`, `Prose`. **The only place unit conversion may happen.**
Everything inside the sim is SI; Kelvin becomes °C here or not at all (`convert: :k_to_c`,
`:kpa`, `:kilo`).

`Prose.new([phrases])` fed by a `Bands` filter is how durability becomes readable without ever
becoming a health bar: *"the fitting is showing some cracks."* Numbers are deliberately never
shown for durability.

## Projection

```ruby
op.project(viewer: :player | :spectator, tick:)  #=> PlayerView
op.panel                                          # instrument + lever chrome, sent once
view.delta_from(previous)                         # only what changed — what goes over the wire
```

`controls` reports `{ target:, actual: }` per lever, so a client can show a valve still
travelling. Spectators get `truth` (undistorted, transforms applied) and no instrument flags —
they have no instrument.

`op.telemetry` is raw truth bypassing instruments. **Specs and the runner's stdout only, never
a client.**

## Adding a gauge

1. Pick a source; if derived, make sure it is in `SIGNATURES`.
2. Chain filters in the order a physical instrument would apply them — usually lag, then
   noise, then scale.
3. Pick a display and put any unit conversion there.
4. Add it to the operation's diagnostics list.
5. A **new filter class** needs a deliberate `distortion?` and a spec. Unused palette pieces
   get specced too — an upgrade slot nobody has exercised is one that will not work when it is
   first reached for. It also needs a row in the filter table in
   [`docs/reference/diagnostics.md`](../../../docs/reference/diagnostics.md) and a place in the
   `distortion?` split above — **in the same commit**. A filter missing from that split is one
   nobody can reason about from the spectator view.

`observer:` is reserved for minions and inert for now. `Diagnostic#observer` is the seam for
"who is reading this gauge"; do not repurpose it.
