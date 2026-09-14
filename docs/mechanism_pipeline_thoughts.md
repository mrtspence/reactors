# The Mechanism Pipeline, Traced

A walkthrough of what actually happens between a player moving a lever and that player
seeing a number change, using the Chemical Vats operation. Every number below is real
output from the committed code at seed `20260822`, not hand-arithmetic — the traces are
reproducible with the scripts described in [Reproducing this](#reproducing-this).

The goal is to make the buffer/mechanism machinery concrete enough to argue with.

---

## 1. The cast

Five kinds of object. The division of labour is the thing to hold onto, because most of
the complexity comes from *where state is allowed to live*, not from the physics.

| Object | Holds config | Holds state | Role |
|---|---|---|---|
| `ControlPoint` | range, default | `{value:}` | A lever. Absolute values only. |
| `Mechanism` | rates, thresholds, wiring | **no** | Pure function: `(state, ctx) → Result` |
| `Buffer` | capacity, delay | `{contents:, transit:, arrived:, spilled:}` | An edge between mechanisms |
| `Diagnostic` | range, noise, delay | `{history:, noise_offset:}` | A gauge. Distorts on purpose. |
| `Operation` | the wiring of all four | **all of it** | Owns the tick |

The load-bearing rule is in [`mechanism.rb:6-9`](../lib/reactor_sim/mechanism.rb#L6-L9):
a Mechanism holds **no mutable state**. All state lives in the Operation's frozen state
hash and is passed in. A mechanism physically cannot write to the tick it is reading
from, so the double buffer is enforced by construction rather than by discipline.

A `Result` ([`mechanism.rb:15`](../lib/reactor_sim/mechanism.rb#L15)) carries four things:

```ruby
Result = Struct.new(:state, :draws, :pushes, :events, keyword_init: true)
```

Note `draws` and `pushes` are **requests, not actions**. A mechanism says "I would like
1.8 units of `line_a`" and returns; the Operation decides what actually happens to the
buffer later, in the commit phase.

---

## 2. The tick contract

`Operation#step!` ([`operation.rb:53-83`](../lib/reactor_sim/operation.rb#L53-L83)) runs
five phases in a fixed order. This is the whole engine:

```
  ┌─ PHASE 1: READ ──────────────────────────────────────────────┐
  │  read_mechanisms = state[:mechanisms]     (frozen, tick N-1)  │
  │  read_buffers    = state[:buffers]        (frozen, tick N-1)  │
  │  controls        = current lever values                       │
  │  available[b]    = buffer contents        ← from tick N-1     │
  │  room[b]         = capacity - contents    ← from tick N-1     │
  └───────────────────────────────────────────────────────────────┘
  ┌─ PHASE 2: EVALUATE ──────────────────────────────────────────┐
  │  every mechanism .step(its own tick N-1 state, ctx)           │
  │  → returns next state + draws + pushes + events               │
  │  NOTHING is applied. Order is irrelevant.                     │
  └───────────────────────────────────────────────────────────────┘
  ┌─ PHASE 3: COMMIT BUFFERS ────────────────────────────────────┐
  │  sum all draws / all pushes per buffer                        │
  │  buffer.commit → shift transit, clamp to capacity             │
  └───────────────────────────────────────────────────────────────┘
  ┌─ PHASE 4: RECORD DIAGNOSTICS ────────────────────────────────┐
  │  read the NEW mechanism states, push onto gauge history,      │
  │  draw this tick's noise offset                                │
  └───────────────────────────────────────────────────────────────┘
  ┌─ PHASE 5: PUBLISH ───────────────────────────────────────────┐
  │  freeze the new state hash, return this tick's events         │
  └───────────────────────────────────────────────────────────────┘
```

Two consequences worth stating plainly, because they explain most of the confusing
behaviour further down:

1. **`available` and `room` are one tick stale.** Every mechanism in a tick sees the
   buffer as it was at the *end of the previous tick*. Two mechanisms drawing from the
   same buffer in the same tick both see the full amount.
2. **Diagnostics record phase 4, so a gauge with `delay: 0` still shows tick N's truth
   only at the end of tick N.** Gauge delay stacks *on top of* buffer delay; it does not
   overlap with it.

---

## 3. Scenario A — cold start, dissected tick by tick

Setup: fresh match, all four levers at `0.0`. The player pushes both feeds to 60%.

```ruby
match.apply([
  { type: "set_control", operation_id: "vats", control_point_id: "feed_a_rate", value: 60 },
  { type: "set_control", operation_id: "vats", control_point_id: "feed_b_rate", value: 60 }
])
# => { applied: 2, rejected: [] }
```

### Tick 0 — before anything runs

```
feed_a   : reservoir=900.0  delivered=0.0  wear=0.0
vessel   : temperature=20.0  pressure=100.0  slurry_a=0.0  slurry_b=0.0  trapped=0.0
turbine  : rpm=0.0  power=0.0
buf line_a     : contents=0.0  transit=[0.0, 0.0]
buf steam_line : contents=0.0  transit=[0.0]
dia vessel_temp: history=[0.0, 0.0]   ← note: NOT [20.0, 20.0]
```

Hidden state rolled from the seed, never visible to anyone:

```
thresholds: {feed_a: 0.9499, feed_b: 0.9861, vessel: 1.0352, turbine: 1.0616}
```

Each of those came from `roll_threshold` ([`mechanism.rb:47`](../lib/reactor_sim/mechanism.rb#L47)),
drawn from that mechanism's own named RNG stream (`vats/vessel`, etc. —
[`operation.rb:176`](../lib/reactor_sim/operation.rb#L176)). This is the incident model:
wear accumulates deterministically, and the machine fails when wear crosses a number the
player was never told.

### Command application

`Match#apply` ([`match.rb:39`](../lib/reactor_sim/match.rb#L39)) runs **at the tick
barrier, before stepping**. It mutates `state[:controls]` directly and nothing else:

```ruby
controls now: {feed_a_rate: 60.0, feed_b_rate: 60.0, coolant: 0.0, throttle: 0.0}
```

Levers are the *only* state a command can touch. There is no command that reaches into a
mechanism.

### Ticks 1–3 — the pipe fills, and nothing else happens

```
tick | feed_a.delivered | line_a contents | line_a transit  | vessel.slurry_a
   1 |             1.80 |            0.00 | [1.8, 0.0]      |          0.0000
   2 |             1.80 |            0.00 | [1.8, 1.8]      |          0.0000
   3 |             1.80 |            1.80 | [1.8, 1.8]      |          0.0000
```

`1.8` is `(60/100) × MAX_RATE(12.0) × dt(0.25)`
([`reagent_feed.rb:35`](../lib/reactor_sim/mechanisms/reagent_feed.rb#L35)).

The transit array is doing the work. `Buffer#commit`
([`buffer.rb:34-54`](../lib/reactor_sim/buffer.rb#L34-L54)) treats it as a shift register:

```ruby
arrived     = transit.fetch(@delay - 1)            # oldest slot falls out
new_transit = [pushed] + transit[0, @delay - 1]    # this tick's push goes in front
raw         = contents - drawn + arrived
```

With `delay: 2`, material pushed at tick 1 occupies `transit[0]`, moves to `transit[1]`
at tick 2, and becomes `arrived` at tick 3. **The vessel sees nothing for two full ticks
after the lever moves.** That is the mechanic, not a lag.

Also note the vessel *did* run at ticks 1–3. It drew 0.0, reacted 0.0, and its
temperature stayed at 20.0. Mechanisms always execute; they just have nothing to work
with.

### Tick 4 — the first tick that does something, in full

Entry state (all from tick 3): `line_a.contents = 1.8`, `line_b.contents = 1.8`,
`vessel.temperature = 20.0`, `steam_line.contents = 0.0`, `steam_line.transit = [0.0]`.

The player also set `throttle = 80` just before this tick.

**Phase 1 — read.**

```
controls  = {feed_a_rate: 60.0, feed_b_rate: 60.0, coolant: 0.0, throttle: 80.0}
available = {line_a: 1.8, line_b: 1.8, steam_line: 0.0}
room      = {line_a: 58.2, line_b: 58.2, steam_line: 400.0}
```

**Phase 2 — evaluate.** Four mechanisms, in the order they happen to be listed, which
does not matter.

*`feed_a` and `feed_b`* — identical:
```
wanted    = (60/100) × 12.0 × 0.25            = 1.8
delivered = min(1.8, reservoir 894.6)         = 1.8
wear      += 0   (rate 60 ≤ CAVITATION_AT 85)
→ Result(pushes: {line_a => 1.8})
```

*`vessel`* ([`reaction_vessel.rb:59`](../lib/reactor_sim/mechanisms/reaction_vessel.rb#L59)):
```
draw_a   = min(available 1.8, MAX_INTAKE 10.0 × 0.25 = 2.5)  = 1.8
draw_b   = 1.8
slurry_a = 0.0 + 1.8 = 1.8        slurry_b = 1.8
reacted  = min(1.8, 1.8) × EFFICIENCY 0.55                   = 0.99

temperature:
  gained  = 0.99 × HEAT_PER_UNIT 9.0                         = 8.91
  removed = (coolant 0/100) × COOLANT_MAX 64.0 × 0.25        = 0.0
  ambient = (20.0 - 20.0) × AMBIENT_LOSS 0.08 × 0.25         = 0.0
  → 20.0 + 8.91 - 0.0 - 0.0                                  = 28.91

steam   = 0.99 × STEAM_PER_UNIT 1.4 × (28.91 / REF_TEMP 260) = 0.15414
pool    = trapped 0.0 + 0.15414                              = 0.15414
vented  = min(pool 0.15414, room 400.0, VENT_RATE 40×0.25=10) = 0.15414
trapped = 0.15414 - 0.15414                                  = 0.0

pressure = BASE 100.0 + (0.0 × 9.0) + ((28.91 - 20.0) × 0.6) = 105.346
wear     += 0   (28.91 < TEMP_SAFE, 105.3 < PRESSURE_SAFE)

→ Result(draws: {line_a=>1.8, line_b=>1.8}, pushes: {steam_line=>0.15414},
         state: slurry_a: 1.8-0.99 = 0.81, ...)
```

*`turbine`* ([`turbine.rb:40`](../lib/reactor_sim/mechanisms/turbine.rb#L40)):
```
wanted = (80/100) × MAX_STEAM 40.0 × 0.25 = 8.0
drawn  = min(available[steam_line] 0.0, 8.0) = 0.0     ← steam is still in transit
target = 0.0 → rpm = 0.0 → power = 0.0
```

Here is the staleness rule biting in a benign way: the vessel pushed 0.154 steam *this
tick*, but the turbine read `available` in phase 1 and saw `0.0`. Even with `delay: 0`
the turbine could not have consumed it, because pushes are not applied until phase 3.

**Phase 3 — commit buffers.** Draws and pushes are summed across all mechanisms
([`operation.rb:146-162`](../lib/reactor_sim/operation.rb#L146-L162)) and then applied:

```
line_a:     arrived = transit[1] = 1.8
            contents = 1.8 - drawn 1.8 + 1.8 = 1.8
            transit  = [1.8] + [1.8] = [1.8, 1.8]
steam_line: arrived = transit[0] = 0.0
            contents = 0.0 - 0.0 + 0.0 = 0.0
            transit  = [0.15414]
```

**Phase 4 — record diagnostics.** Against the *new* mechanism states:

```
dia vessel_temp     : history=[28.91, 20.0]     noise_offset=+1.2202
dia vessel_pressure : history=[105.346, 100.0]  noise_offset=-3.0866
dia slurry_a        : history=[0.81, 0.0, 0.0]  noise_offset=+0.0558
```

Noise is drawn **once here**, not at read time — the reasoning is in
[`diagnostic.rb:16-18`](../lib/reactor_sim/diagnostic.rb#L16-L18): a tick may be projected
any number of times (a player view, a spectator view, a resync of either), and drawing
noise at read time would make the RNG stream depend on how many people happened to be
watching. This is what keeps `project` pure.

**Phase 5 — project.** Two viewers, same state:

```
PLAYER : vessel_temp=21.2   vessel_pressure=96.9   slurry_a=0.1  turbine_rpm=1.1
SPECTR : vessel_temp=28.9   vessel_pressure=105.3  slurry_a=0.8  turbine_rpm=0.0
```

The player's `21.2` is `history[delay=1] + noise = 20.0 + 1.2202`, i.e. **tick 3's truth
wearing tick 4's noise**. The spectator's `28.9` is `history.first` — tick 4's truth,
undistorted ([`diagnostic.rb:47-53`](../lib/reactor_sim/diagnostic.rb#L47-L53)).

Note the player's pressure reading of `96.9` is *below* the vessel's floor of
`BASE_PRESSURE = 100.0`. Noise is applied after the delay and clamped only to the
instrument's range, so a gauge can legitimately display a physically impossible value.
That is fine and arguably good, but it is a design choice worth being aware of.

### Delta on the wire

`PlayerView#delta_from` ([`player_view.rb:27`](../lib/reactor_sim/player_view.rb#L27))
produces what actually ships each tick:

```ruby
{ tick: 4,
  changed: {vessel_temp: 21.2, vessel_pressure: 96.9, slurry_a: 0.1,
            slurry_b: 0.3, turbine_rpm: 1.1, vitriol_level: 892.8,
            quicklime_level: 892.8},
  controls: {throttle: 80.0},
  incidents: [],
  power: 0.0 }
```

---

## 4. The latency ledger

This is the part that matters for game feel. Two levers, two very different distances
from the player's eye.

**`coolant` — acts directly on a mechanism, no buffer in the way.** Measured from a
warmed-up vessel at tick 20:

```
                        truth      spectator    player
tick 20 (before)      245.693            —          —
COMMAND coolant = 100
tick 21               241.379        241.4      246.8   ← player still sees tick 20
tick 22               237.151        237.2      240.4   ← player now sees tick 21
```

Lever → player-visible change: **2 ticks (500 ms)**. One tick to act, one tick of
`Diagnostic(delay: 1)`.

**`feed_a_rate` — acts through a `delay: 2` buffer and a `delay: 2` gauge.** From
Scenario A, cutting the feed at tick 6:

```
tick | feed_a.delivered | line_a transit | line_a contents | vessel draw_a | slurry_a
   5 |             1.80 | [1.8, 1.8]     |            1.80 |          1.80 |   1.1745
>>> COMMAND feed_a_rate = 0
   6 |             0.00 | [0.0, 1.8]     |            1.80 |          1.80 |   1.3385
   7 |             0.00 | [0.0, 0.0]     |            1.80 |          1.80 |   1.4123
   8 |             0.00 | [0.0, 0.0]     |            0.00 |          0.00 |   1.4456
   9 |             0.00 | [0.0, 0.0]     |            0.00 |          0.00 |   0.6505
```

The pump stops **immediately** at tick 6. The vessel keeps receiving reagent at full rate
through ticks 6 and 7 — that material was already in the pipe — and only starves at tick
8. The effect on `slurry_a` first appears in the truth at tick 9. The player's `slurry_a`
gauge has `delay: 2`, so it lands at tick 11.

**Lever → gauge: 5 ticks, 1.25 seconds.**

Adding it up:

| Hop | Cost | Source |
|---|---|---|
| Command applied at barrier | 0 ticks | `Match#apply` runs before `step!` |
| Mechanism reacts | same tick | pure function of `controls` |
| Buffer transit | `delay` ticks | `line_a` = 2 |
| Downstream mechanism reads stale `available` | +1 tick | phase 1 reads tick N−1 |
| Gauge history | `delay` ticks | `slurry_a` = 2 |

That +1 for stale `available` is easy to miss when reasoning about the wiring, and it
applies at *every* mechanism-to-mechanism hop, not just the first.

---

## 5. Scenario B — back-pressure, and how the vessel actually dies

Setup: both feeds at 100%, coolant at 0%, **throttle at 0%**. The player is making steam
as fast as possible and refusing to let the turbine consume any of it.

```
tick | steam_line contents |   room | vented | trapped |   temp |   press | wear
   5 |               0.240 | 399.76 |  0.538 |   0.000 |   50.1 |   118.0 | 0.0000
  20 |              37.859 | 362.14 |  4.489 |   0.000 |  333.5 |   288.1 | 0.0000
  40 |             164.566 | 235.43 |  8.120 |   0.000 |  603.2 |   449.9 | 0.0484
  60 |             350.433 |  49.57 | 10.000 |   1.735 |  783.3 |   573.6 | 0.2342
  80 |             400.000 |   0.00 |  0.000 | 181.133 |  903.5 |  2260.3 | 0.6734
  88 |             400.000 |   0.00 |  0.000 | 280.671 |  939.6 |  3177.8 | 1.0544
>>> EVENT: vessel_rupture (wear 1.0544 crossed threshold 1.0352)
```

The mechanism is the `room` term in
[`reaction_vessel.rb:85-89`](../lib/reactor_sim/mechanisms/reaction_vessel.rb#L85-L89):

```ruby
pool    = state.fetch(:trapped) + steam
room    = ctx.room.fetch(@out_buffer, Float::INFINITY)
vented  = [pool, room, VENT_RATE * dt].min
trapped = pool - vented
```

Three distinct regimes, all visible in the table:

- **Ticks 1–~55:** `vented` is limited by `pool` — the vessel makes less steam than it can
  vent. `trapped` stays at zero and pressure tracks temperature alone.
- **Ticks ~55–64:** `vented` pins at `10.0` = `VENT_RATE(40) × dt(0.25)`. The relief vent
  is saturated. `trapped` starts to accumulate slowly.
- **Tick 65 onward:** `room` hits zero. `vented` collapses to `0.0` and every unit of
  steam produced is trapped. Pressure goes from 573 kPa to 2260 kPa in fifteen ticks,
  because `trapped` is multiplied by `PRESSURE_PER_UNIT = 9.0`.

Wear crosses the vessel's hidden threshold of `1.0352` at tick 88 and it ruptures. This
is the throttle-as-safety-control design working: the turbine lever is not just an output
dial, it is the vessel's relief path.

**What the player can see while this happens:** `vessel_temp` and `vessel_pressure`, both
one tick late, plus a `turbine_rpm` of zero. The variable that is actually killing them —
`steam_line.contents` at 400/400 — has no instrument at all. See finding 5 below.

---

## 6. Scenario C — banking unreacted slurry

Setup: both feeds at 60%, then `feed_a_rate → 0` at tick 6 while `feed_b_rate` stays at
60%. This is the reagent-balance mechanic.

```
tick | slurry_a | slurry_b | reacted
   8 |   1.4456 |   1.4456 |  1.7668
   9 |   0.6505 |   2.4505 |  0.7951
  10 |   0.2927 |   3.8927 |  0.3578
  12 |   0.0593 |   7.2593 |  0.0724
  16 |   0.0024 |  14.4024 |  0.0030
```

Because `reacted = [slurry_a, slurry_b].min × 0.55`
([`reaction_vessel.rb:74`](../lib/reactor_sim/mechanisms/reaction_vessel.rb#L74)), the
starved reagent decays geometrically (×0.45 per tick) while the over-fed one grows
linearly. Output collapses within about four ticks of the imbalance reaching the vessel,
and quicklime piles up at 1.8 units per tick with nowhere to go.

The banked slurry is not lost — restore `feed_a` and it all reacts at once, in a single
large heat spike. That is the trap the `slurry_a` / `slurry_b` gauges exist to let you
see coming, two ticks late and ±0.5 units noisy.

Run the imbalance long enough and the feed line itself overflows: at 100% `feed_a` with
`feed_b` at zero, `line_a` reaches capacity and first spills at **tick 118**. The pump
delivers 3.0 units/tick while the vessel can only draw `MAX_INTAKE × dt = 2.5`, so the
line gains 0.5/tick until it is full.

---

## 7. Scenario D — why redelivery is safe

The three properties the Kafka ingress design depends on, verified by digest comparison:

```
base == duplicate delivery       : true
base == reversed order           : true
last-write-wins: (60, 90) == (90): true
```

All three fall out of `ControlPoint#set`
([`control_point.rb:27`](../lib/reactor_sim/control_point.rb#L27)) storing an absolute
clamped value. Applying `set feed_a_rate = 60` twice is indistinguishable from once, so
at-least-once delivery needs no dedup table. This is the single assumption that lets the
runner commit offsets after snapshotting rather than before.

---

## 8. What the trace exposed

Observations, with evidence. These are facts about the current code, not proposals.

### 1. Diagnostics cold-start at zero, not at the mechanism's initial value

`Diagnostic#initial_state` ([`diagnostic.rb:37`](../lib/reactor_sim/diagnostic.rb#L37))
fills history with `0.0`. But the vessel starts at 20.0 °C and 100.0 kPa. So at tick 0:

```
vessel truth  : temperature=20.0  pressure=100.0
PLAYER gauges : vessel_temp=0.0   vessel_pressure=0.0
SPECTR gauges : vessel_temp=0.0   vessel_pressure=0.0
```

Even the god-view is wrong, because `truth` reads `history.first`. It self-corrects after
`delay + 1` ticks, so it is cosmetic — but a match's opening frame shows a reactor at 0 °C
and 0 kPa, which reads as "instruments not connected" rather than "idle".

### 2. Back-pressure is off by one transit slot, and the excess vanishes silently

`room` is computed as `capacity − contents`
([`operation.rb:59`](../lib/reactor_sim/operation.rb#L59)) and ignores `transit`. So the
vessel can be told there is room for 9.57 units when 10.0 are already in flight. From
Scenario B:

```
tick | contents |  room | vented(pushed) | transit | spilled
  65 |  400.000 |  0.00 |         9.5667 |   9.567 |  0.4333
  66 |  400.000 |  0.00 |         0.0000 |   0.000 |  9.5667
```

Ten units of steam were destroyed across those two ticks. The vessel had already
subtracted them from `trapped` — it believes it vented successfully — so this is not
conserved. No event fires and no gauge moves.

For the vats specifically the amount is small and the vessel is doomed anyway by that
point. The structural point is that `Buffer#commit` is the only place that knows an
overflow happened, and it tells nobody.

### 3. `spilled`, `arrived`, and `pegged?` are computed but never read

Confirmed by grep across `lib/`, `app/`, and `spec/`: `spilled` and `arrived` are written
into buffer state and read only by `Buffer#commit` itself; `Diagnostic#pegged?`
([`diagnostic.rb:57`](../lib/reactor_sim/diagnostic.rb#L57)) has no callers at all. Three
pieces of telemetry that exist, are maintained every tick, are serialised into every
snapshot, and are structurally unreachable by a player.

`pegged?` is the interesting one — the comment above it argues that "your gauge is maxed
out" is real information, and the operation's diagnostic ranges are explicitly chosen so
a badly-run vessel pegs them. But `PlayerView` carries only the clamped number, so the
player cannot distinguish "600 °C" from "≥600 °C".

### 4. Noise defeats delta compression

With **all controls at zero and the machine completely idle**, gauges reported as changed
per tick over 30 ticks:

```
[5, 4, 4, 3, 5, 4, 4, 4, 4, 4, 3, 3, 4, 4, 4, 4, 5, 5, 5, 4, 4, 5, 4, 3, 2, 3, 4, 5, 4, 5]
```

Of eight gauges, five carry noise and three do not. Because `noise_offset` is re-drawn
every tick regardless of whether the underlying value moved, essentially every noisy gauge
reports a change every tick, forever. The delta is only compressing the three noiseless
gauges.

This does not break anything — the payload is small either way — but the delta protocol in
[architecture.md §7](architecture.md) is doing much less work than the design assumes, and
"send only what changed" is not a meaningful reduction while noise is drawn this way.

### 5. Diagnostics can only observe scalar fields on a single mechanism

`record_diagnostics` ([`operation.rb:164-171`](../lib/reactor_sim/operation.rb#L164-L171))
is hard-wired to `next_mechanisms.fetch(d.mechanism).fetch(d.field)`. A Diagnostic
therefore cannot report:

- a buffer level (`steam_line.contents` — the state that kills the player in Scenario B)
- a rate or a delta between ticks
- anything derived from two mechanisms
- anything about the operation as a whole

The vats currently have eight gauges and all three buffers are invisible. Whether that is
a deliberate cruelty or an accidental limitation is worth deciding explicitly, because
right now it is enforced by the shape of the code rather than by the operation's design.

### 6. Draws are summed and clamped with no arbitration

`commit_buffers` sums every mechanism's draws into one number, then
[`buffer.rb:45-47`](../lib/reactor_sim/buffer.rb#L45-L47) does:

```ruby
raw     = contents - drawn + arrived
contents: raw.clamp(0.0, @capacity)
```

If two mechanisms drew from the same buffer in the same tick, they would both have seen
the same stale `available` and could jointly request more than exists. `raw` would go
negative, clamp to `0.0`, and both mechanisms would keep the material they recorded
receiving. Matter is created and nothing reports it.

The vats never hit this because every buffer has exactly one consumer. It is latent, not
live — but it is precisely the seam that the deferred resource/port contract will have to
close, and it will not announce itself when it first breaks.

### 7. Above ~83% feed rate, the lever does nothing

`MAX_RATE × dt = 3.0` units/tick delivered, `MAX_INTAKE × dt = 2.5` units/tick drawn. At
any feed rate above `2.5/3.0 ≈ 83%`, the surplus accumulates in the line and then in
`slurry`, and eventually spills. This is arguably a fine trap. But the player has an
instrument for the reservoir level and none for the line level, so the lever's top 17% is
a dead zone with no feedback distinguishing it from the useful range.

---

## Reproducing this

The trace scripts live in the session scratchpad rather than the repo:

```
/tmp/claude-1000/-home-tim-projects-reactor/<session>/scratchpad/
  trace.rb    # Scenario A, full per-phase dump, ticks 0-10
  trace2.rb   # Scenarios A-continued, B, C, D
  trace3.rb   # spill reachability, latency ledger, delta churn
```

Run from the repo root with `ruby <path>`. They require only `lib/reactor_sim` and no
Rails. Seed `20260822` throughout; every number above is reproducible.




COUNTER PROPOSAL:

Buffer is not a great abstraction. I think the properties it represents are good, but I think it is overloaded. Would benefit from breaking down the system into more mechanisms and more interfaces. Delay is a bad implementation of a good idea -- very complex and results in having to juggle different delays mentally while thinking about a large and complex system. Too much mental overhead.

I would propose instead:

The properties of Temperature, Pressure, Mass, Specific Heat, Capacity, Resource State (bad name, but the idea that one or more of some kind of resource is contained in some quantity ie the working fluid in a turbine or the chemicals in a chemical pipe), Durability (easier to think about wear as a depleting resource rather than an accumulation), and the ability to fail/break are pretty well universal for both mechanisms and interfaces and many resources (see below), so we may want some sort of composed-in interface.

Just about any system could be described as a combination of those properties (with varying relevance). Also going to want to represent temperature in Kelvins at least internally to make math easier.

### Mechanism
A part that does something in an operation. These stay pretty much unchanged from before, other than they need to have the methods/properties we need.

### Interface
The join between mechanisms. My suspicion is that these actually should just be another mechanism with a flag set or something to differentiate. They need to be susceptible to the same set of wear and tear as mechanisms (and indeed, the joins between mechanisms is where many systems fail). Their capacity, instead of representing how much of a resource they can contain, simply represents how much resource can transit through them. If they are just another mechanism, then THEY get to be a really common place for control points which means a lot of the complexity burden on a mechanism gets dispersed to the interfaces around them (it also makes intuitive sense -- the fitting / pipe between your chemical tank is where you would want to put a control valve).

### Resource
This is whatever the 'thing' is inside a given mechanism (can be multiple in a single part ie the chemicals in the chemical vat or the combination of reactor fuel/moderator/cooling liquid). Working fluid, reactants, whatever. We need an abstraction for this concept to help us break down the complexity and pull it out of mechanisms and interfaces where possible.

These also need to keep track of some of their fundamental properties like temperature, density, and a note of where phase transitions occur. Likely going to want a tag system as well (so that Steam knows it is a Gas and Water knows its a liquid -- making these composable will let us improve modularity and allow us some useful opportunities later).

Steam is going to be the big one here as something like a boiling water reactor will have both steam and water in it. There are going to be many many systems that deal with steam/water mixtures or other combinations of materials, and each of them having to re-implement phase-transitions is going to be tedious -- many won't need to care about the difference, but some like our nuclear reactors absolutely will as the void coefficient is of vital importance to describing that kind of system. So whenever we resolve temperature for a given resource, we will need to check the pressure in the mechanism and can see how much of it undergoes a phase transition. I am also very content to completely alleviate ourselves having to worry about phase transition descriptions / systems IF we can suitably handle it in the mechanisms that care about it (like a boiling water reactor where the amount of water / vapour is an absolutely CRITICAL description of that system). Open to suggestions.

As for the specific mechanics of how to resolve the heat transfer, we can just do some crude math to say that if pipe A has X units of chemical B moving through it at Temperature Y, average out their temperatures, taking into account their specific heats, up to some equilibrium based on the simple mass-temperature combinations and with some coefficients inherent to the mechanism / interface in question like geometry, nuances in material (could just be a misc modifier for all of them), and dwell time (since we know our engine ticks -  time conversion, we could simply do a 1:1 or, more likely, some modification like saying each tick represents 5 or 10 seconds or some tunable value until we get the performance we want for a fun timescale for a game).

The mechanism probably needs to define the sequence of what materials to interact with. For most it will be simple like inlet interface-to-pipe (likely with a tiny geometry coefficient) then pipe-working fluid. In more complex systems, like a water cooled + moderated nuclear reactor, the thermal sequence could be inlets-vessel -> fuel rods -> water -> vessel (or each thermal chain could and should be evaluated separately? likely simpler that way).

This process likely needs some simplifying abstractions, but our mechanisms should be able to just say, hey Resource A, I know how much of you is in here right now, so do the temperature math with me -- here is the coefficient to represent the abstract complexities of geometry and variances in materials -- and you know how long a tick is internally so instead of reaching equilibrium, you know to just get part way there based on our time scale. This lets us vastly simplify the mechanism's necessary understanding of the complex parts of the physics. Would also let the mechanism basically delegate the phase transition or chemical math (think igition points or that some chemicals may decompose or restructure above or below certain points) to the resources inside it. It tells them to run the temperature calcs and passes in pressure and they respond back by mutating the state inside. For example, the water knows that at X temperature and Y pressure that there should be A amount of Water Vapour and B amount of liquid water so it mutates the state inside the mechanism accordingly. If that working medium is instead a chemical, it could tell the mechanism containing it what its new values are (such as if some different reaction took place above a certain temperature/pressure). By having the resource itself do those calcs, we can also add complexity such as the increased corrosivity of water at high temperatures and pressures in a way that the mechanism doesn't have to know about (the material of the mechanism could just be a tag passed in to the calc or something).

Again, this might be too complex to bother with in that specific implementation (it almost certainly is), but if we don't have some kinds of abstractions to absorb complexity OUT of the mechanisms, they are going to end up each being super bespoke and complicated with a single part representing the entire complexity of the system. I want a modular system where players can easily tinker with their operations by swapping parts in and out like trying a pipe of different diameter here or trying a different mix of chemicals. If the mechanisms themselves are ultra bespoke, we are never going to get there and we need to ensure we get the abstractions right early to avoid pigeon holing ourselves.


### Resolution Order
This is a large change in the working of things.

I would suggest that, when a mechanism is resolved, after doing its temperature calcs or whatever other internal mechanics it needs to handle, it would attempt to push its outputs through any correct outlet interfaces by their tags (I do like how we stored those buffers as inlets/outlets on the mechanism and they seem like a logical place to similarly track interfaces) in accordance to its internal logic.

So something like a pressure relief mechanism might have an outlet interface for liquid resources and a different one for gas resources. In a refinery (remember that operations are not just about generating power) a different mechanism like a centrefuge might have one outlet for denser materials and one for lighter ones or an ore refinery might have a mechanical sorter that puts resources above a certain size in one outlet and below a different size in another. Hopefully you can see the value in a combination of this tag / inlet / outlet system -- it would let us describe any complex system as a series of much simpler pipelines.

When a resource is pushed to a given interface, that interface knows its capacity. It attempts to transit up to that amount of resource -- any excess is rejected and remains in the 'pushing' mechanism. Since an interface has all the temperature math interfaces and knows its own coefficient to pass in, it calls for those internal calcs on itself The pushing mechanism could either do a pressure calc after attempting to push all its resources OR could just do the pressure calc after doing the temperature calcs on the next tick through. Either probably fine, so whatever is more elegant.

Instead of having a complex delay system where each mechanism is given some sort of god offset that determines what part of the pipeline it 'sees', we could just resolve each interface and mechanism in reverse order, so that each object with 10 parents goes first (as some operations might not just have one single node that they end in -- could easily be branching like having separate streams of outputs such as in a refinery or things like relief valves that might be nested 4 levels in as their own terminal node for a subset of a given resource/pipeline), then ones with 9 parents and so on. This is going to be mechanically very similar to a delay, but is a lot easier to reason about. Open to being convinced otherwise, but the delay system I think is better suited as an emergent property of a sequence of mechanisms rather than something we have to hardcode in from the start.


### Control Point Feedback and Minions
These are broadly good, but remember that the player won't be hitting all these levers themselves. They are going to have Minions doing the dirty work for them. So at a given control point, we will also need to pass in the state of that minion. They are going to need some attributes like strength and intelligence (a pixie might not be a great choice to operate a stiff pressure relief valve while an ogre might be poorly suited for a reactor control panel), Health (if someone gets doused in a caustic chemical they may become too injured to operate their station) as well as a set of tags that help represent their quirks and behaviour (maybe an animated skeleton is not bothered by neutron flux in a reactor or a covetous gnome may skim some of the gemstones out of your mining operation if they are manning the sorting station). They will be a source of hijinks and entertainment.

So if you tell that pixie to open their valve that was set to 0% open to 85% open, they may only be strong enough to move it by 15% per turn. That ogre might be too boneheaded and instead press the wrong button or accidentally wrench a delicate switch off the board entirely! These minions will also be a key resource for account progression later (if you get that ogre his senior reactor operator license, he will be less likely to suffer mishaps). This layer needs to be woven into our architecture sooner than later, but can be ignored for now as we work on the underlying operations themselves first.

### Diagnostic Feedback
I think the base class for diagnostic is doing too much. There is no sense having all the complexity of stuck dials, jittery outputs, etc in the base class. A diagnostic might be as simple as an indicator light, so why have the parent class bear the complexity? Instead, I propose that the parent class for diagnostic simply needs to enforce an interface to take some input from a mechanism and another to output some kind of display. All the complexity can then live in the appropriate subclasses.
