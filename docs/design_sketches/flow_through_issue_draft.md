# Flow-through quantities and period-2 limit cycles

**Status: investigation. Draft for review — deliberately contains no solutions.**

This document exists to describe a failure mode precisely enough that we can design against it.
It is item 4 of [`current_progress.md`](../current_progress.md)'s playtest list, expanded.
Everything measured here was measured against the real simulation this session; every table
names the controls that produce it so any figure can be re-derived.

---

## 1. The failure signature

> A node that reads the **instantaneous inventory** of a quantity that is **passing through**
> it will eventually read zero, and act as though the supply had failed.

It is worth being precise about why this is dangerous rather than merely untidy:

- **Nothing raises.** No exception, no `nil`, no `NaN`.
- **Conservation still holds exactly.** Mass and energy balance to zero drift. Every existing
  guard spec passes. The ledger is clean.
- **The graph is correct.** The wiring is right, the ports are right, the tags are right.
- **The physics is correct** in the sense that no equation is wrong.

The system simply starves, quietly, and the only symptom is that something downstream behaves
worse than its settings say it should. Both times it has actually damaged the physics it was
found **by accident, while looking for something else** — and the third instance below was
found only because this investigation went looking for it deliberately.

Three instances are confirmed. Two have workarounds that treat the *reader* rather than the
oscillation. **One is live, unfixed, and visible to the player right now** (§6.3).

---

## 2. How the tick produces the delay

None of this is a bug. It is the design working as intended, and the oscillation is a
consequence of it. Understanding the oscillation means being exact about the tick first.

### 2.1 Everything reads N−1; everything writes N

From [`tick.rb:78-116`](../../lib/reactor_sim/tick.rb):

```
             ┌──────────────── FROZEN state of tick N−1 ────────────────┐
             │      nodes[].parcels · joules · angular_momentum …       │
             └───────────────────────────┬─────────────────────────────┘
                                         │  every READ below comes from here,
                                         │  and it is identical for every node
   phase 0  actuate   levers travel      │
   phase 1  read      ctx built ─────────┤
   phase 2  plan      node.plan(…) ──────┤   ← INTENT declared against N−1
   phase 3  settle    Arbiter.settle ────┘   ← CLAIMS arbitrated against N−1
   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
   phase 4  transfer  advect / conduct / ambient / drive / torque  ─┐
   phase 5  react     ignition, chemistry, phase change             │
   phase 6  stress    wear                                          ├─ WRITES
   phase 7  observe   instruments sample                            │
   phase 8  publish   freeze                                       ─┘
                                         │
                                         ▼
             ┌───────────────── state of tick N ───────────────────────┐
             │   which is the frozen input the next tick reads from    │
             └─────────────────────────────────────────────────────────┘
```

This is invariant 3, order-independence, and it is not negotiable: it is the reason nodes can
be evaluated in any order, the reason a closed loop needs no topological sort, and the reason
a match replays bit-for-bit. **The one-tick lag is the price, and it is a price worth paying.**

### 2.2 One hop per tick, and it is emergent

There is no `delay:` parameter anywhere and there must never be one. Because `plan` reads N−1
and settlement writes N, material crosses exactly **one link per tick**. Tracing a slug of air
along `atmosphere → damper → firebox`, at damper 42%:

```
                atmosphere            damper              firebox
   tick 1   ──►    [ ∞ ]  ──0.84 kg──► [0.84]              [0.00]
   tick 2         [ ∞ ]                [0.00] ──0.84 kg──► [0.84]
   tick 3   ──►    [ ∞ ]  ──0.84 kg──► [0.84]              [0.00]   ← flue cleared it
   tick 4         [ ∞ ]                [0.00] ──0.84 kg──► [0.84]
```

Two hops, so air takes two ticks — 500 ms at `time_scale` 1.0 — to reach the fire. That is
correct and intended. **What is not intended is that the damper is empty half the time.**

---

## 3. The generator: a conduit is a bucket brigade

[`Conduit#plan`](../../lib/reactor_sim/nodes/conduit.rb) is four lines, and they are the
source of the whole problem:

```ruby
held = contents_kg(state)                              # state is tick N−1
Intent.new(
  draws:  { inlet:  [ throughput_kg(ctx) - held, 0.0 ].max },
  pushes: { outlet: held }
)
```

Both rules are individually correct and both were written to fix real bugs. `pushes: held` says
a pipe sends on whatever is in it. `draws: T − held` says a pipe already full cannot take more
— and the comment above it records why: *"a conduit that ignores this becomes an infinite sink,
draining its source every tick and holding it at nothing."*

Together they make the conduit alternate.

### 3.1 The map

Write `T` for the throughput this tick — `max_kg_per_s × dt × lever_fraction` — and `h` for the
inventory. Over one tick, with everything granted:

```
   h(N+1)  =  h(N)  −  pushes  +  draws
           =  h(N)  −  h(N)    +  (T − h(N))
           =  T − h(N)
```

So the inventory map is **`h ↦ T − h`**. Three properties follow immediately:

| Property | Consequence |
|---|---|
| It is an **involution** — apply it twice and you are back where you started | Every value of `h` lies on a period-2 orbit |
| Its derivative is exactly **−1** | The eigenvalue sits on the unit circle. **There is no damping.** Not weak damping — none |
| Its only fixed point is `h* = T/2` | And it is not attracting: neighbours orbit it, they do not approach it |

A conduit therefore **cannot settle by itself, from any starting condition**. And because a
cold operation starts every conduit at `h = 0`, the default start is the
**maximum-amplitude orbit** — the worst case is the one every match begins in.

### 3.2 As a state machine

```
              draws T−h = 0.84                    draws T−h = 0.00
              pushes h  = 0.00                    pushes h  = 0.84
          ┌───────────────────────┐          ┌───────────────────────┐
          │   held = 0.00 kg      │ ───────► │   held = 0.84 kg      │
          │      (empty)          │ ◄─────── │      (full)           │
          └───────────────────────┘          └───────────────────────┘
                 delivers nothing                 delivers everything
```

Measured — damper 42%, so `T = 8.0 kg/s × 0.25 s × 0.42 = 0.84 kg`:

```
   tick   damper    firebox      flue
     1    0.8400    0.0000     0.0000
     2    0.0000    0.9300     0.0000
     3    0.8400    0.0864     0.8436
     4    0.0000    1.0164     0.0000
     5    0.8400    0.1655     0.8509
     6    0.0000    1.0955     0.0000
```

Dead on the prediction, to four decimal places. Note the flue in the last column: it is a
conduit too, running the same cycle, **phase-locked** to the damper — and the firebox between
them therefore sits in **antiphase to both**, which is what §4 turns on. The firebox's rising
floor is coal accumulating on an unlit grate.

---

## 4. The amplifier: pressure sampled in antiphase

This part was not previously known, and it is the reason the oscillation is worse than the
theory above suggests.

The delay puts a duct and its destination in **antiphase** — when the damper is full the
firebox has just been cleared, and vice versa. And
[`Arbiter.cap_gas_by_pressure`](../../lib/reactor_sim/graph/arbiter.rb) compares their
**instantaneous** pressures to decide how much gas may cross:

```ruby
supply   = source.pressure_pa(states.fetch(link.from_node), content)
headroom = sink.gas_headroom_kg(states.fetch(link.to_node), supply, content, resource)
[ kg, headroom ].min
```

So it samples both ends at the worst possible moment in their cycle — always at an extreme,
never anywhere near the average. Measured:

```
   tick   damper_kg   damper_kPa   firebox_kPa    push allowed?
    12      0.1600         13.5          11.8     yes
    13      0.8800         74.1           1.7     yes
    14      0.1200         10.1          12.3     NO — capped
    15      1.0000         84.2           0.0     yes
    16      0.0000          0.0          14.0     NO — capped
    17      1.0000         84.2           0.0     yes
    18      0.0000          0.0          14.0     NO — capped
```

```
                 tick 15      16      17      18      19
   damper   kPa    84.2     0.0    84.2     0.0    84.2
   firebox  kPa     0.0    14.0     0.0    14.0     0.0
                     ▲       ▲
                     │       └── source 0 kPa < sink 14 kPa → headroom 0 → BLOCKED
                     └────────── source 84 kPa > sink 0 kPa → wide open
```

### 4.1 Why this is positive feedback

On a blocked tick the duct **keeps its charge and draws more anyway** — `draws` and `pushes`
are independent claims, and only the push was refused. So a duct that was nearly empty ends up
fuller, which empties the firebox harder next tick, which blocks the push harder still.

The orbit therefore does not merely persist. It **grows, and locks at the saturated extremes**.
Perturbed deliberately off both extremes (running at 42% until the duct held 0.84 kg, then
opening to 50% so `T = 1.00` and the duct sat at neither bound):

```
   0.1600 → 0.8800 → 0.1200 → 1.0000 → 0.0000 → 1.0000 → 0.0000 → …
                                       └─ locked, still locked 60 ticks later ─┘
```

**The saturated full/empty orbit is an attractor**, not one orbit among many. This is the
single most important finding in this document: the involution says the oscillation will never
decay, and the pressure cap says it will always grow to maximum amplitude.

There is a bitter irony here. `cap_gas_by_pressure` is a *stabilising* rule — it exists to stop
a small vessel being packed to a higher pressure than the thing feeding it, which is *"not a
thing pipes do"*. Under antiphase it becomes destabilising, for no other reason than that it is
reading a number at the wrong moment.

### 4.2 A duct's pressure is an artifact, not a measurement

A 1 m³ damper alternating full/empty reports **0 Pa on one tick and 84 kPa on the next**, with
nothing physical changing. It is a bucket that is momentarily full or momentarily empty; its
"pressure" is an arithmetic consequence of `Pressurized` being applied to a node whose volume
means nothing.

**`Cylinder#plan` already knows this.** Its comment says so outright:

> It caps itself rather than relying on the arbiter because the pipe between it and its supply
> is a duct, not a container — a duct reports whatever pressure its own small volume implies,
> which is not the pressure actually driving the flow.

It works around it by reading `supplied_by: :boiler` — looking *past* the throttle to the vessel
behind it. But `Arbiter.cap_gas_by_pressure` still reads the duct.

**The workaround is not merely half-applied; it is defeated.** The node opted out of the trap,
and the layer below it then applies the trap to the node's own claim. §6.2 measures the result:
a cylinder starved every other tick while its boiler holds five times the pressure it needs.

---

## 5. The cost nobody was charged for

Because the amounts alternate, a conduit's **mean delivery is `T/2`** — half its rated
throughput. In the clean case this is exact: the damper at 42% moves 0.84 kg every two ticks
against a rated `T = 0.84` kg/tick. Once the pressure cap starts refusing pushes outright it is
worse: measured 0.5 kg/tick against `T = 1.2` kg/tick, about 42%.

So **a damper rated 8 kg/s delivers roughly 4 kg/s.**

The firebox's own `air_in` port is rated **4.0 kg/s**. That is not a coincidence anyone chose:
[`definition.rb`](../../lib/reactor_sim/operations/steam_engine/definition.rb) records the
damper being widened 4 → 8 when ignition landed, a sweep showing 12 kg/s produces *less* power
than 8, and the note *"the firebox's own `air_in` port stays at 4.0."* Every one of those is a
true empirical observation. They are also exactly what tuning around an unseen factor of two
looks like — the numbers were found by experiment, and the experiment was measuring the
oscillation as much as the physics.

This does not mean the balance is wrong. It means **we do not currently know which of our
tuned constants are physics and which are compensation.**

---

## 6. The three instances

### 6.1 The firebox draught — cost us the ignition model

Air alternates between a slug and **literally nothing**:

```
   tick   firebox_air_kg
   6981         0.0000
   6982         0.2231
   6983         0.0000
   6984         0.2231
```

The first ignition model read this instantaneously and computed starvation from it. Every
other tick it concluded the fire had no air, applied the full quench rate, and killed the fire
two ticks at a time — **on a fire consuming barely one percent of the air blowing past it**.

This cost a full debugging cycle and was diagnosed only because the fire kept dying for no
visible reason. See [`ignition.md`](ignition.md).

**Workaround in place:** `Ignition::OXIDISER_MEMORY_PER_S = 1.5` — the fire keeps a short
memory of the draught, rising instantly and falling slowly.

### 6.2 The cylinder — a 4.8× swing at operating speed

`current_progress.md` records 14.9/21.4 kW, measured on a cold engine. At a mature ~101 rpm it
is far worse. Measured at throttle 60 / load 80 / stoking 60, **boiler at 709 kPa**:

```
   tick   throt_kg   throt_kPa   cyl_kg   cyl_kPa   ind_kW     rpm    throt > cyl?
   6981     0.3750       252.8   0.1361     122.8    16.43   99.79    yes
   6982     0.2344       158.0   0.2243     202.4    78.23  101.96    NO — capped
   6983     0.3750       252.8   0.1361     122.8    16.43   99.79    yes
   6984     0.2344       158.0   0.2243     202.4    78.23  101.96    NO — capped
```

- **Indicated power swings 4.8×**, every 250 ms, indefinitely.
- **Cylinder pressure swings 65%.**
- **It reaches the flywheel** — 24 tonnes of cast iron, wobbling 99.79/101.96 rpm.

The mean is ~47 kW, and the mean is what the machine actually delivers. But no instantaneous
reading of this machine is within 60% of the truth.

**This is the same trap as §4, one link downstream** — not a separate mechanism, which is why
it is worth reading the two together:

1. The throttle is a `Conduit`, so it runs the brigade of §3. Its pressure alternates
   **252.8 / 158.0 kPa**.
2. On the high tick the cylinder fills, reaching 202.4 kPa.
3. On the next tick the throttle has dropped to 158.0 kPa — **below the cylinder's 202.4** — so
   `cap_gas_by_pressure` gives zero headroom and **nothing crosses at all**.
4. The cylinder exhausts down to 122.8 kPa; the throttle refills to 252.8. Repeat forever.

The boiler is sitting at **709 kPa** throughout. There is nearly five times the pressure needed.
The cylinder is starved every other tick **not by any shortage of steam**, but because a duct's
momentary pressure is an artifact of where it is in its own cycle.

And here is the part that matters most for the design round: `Cylinder#plan` **deliberately
looks past the throttle** to size its draw against the boiler, for exactly this reason
(§4.2) — and then the arbiter vetoes that draw using the throttle's pressure anyway. The
workaround is not merely half-applied. **It is actively defeated by the layer below it.**

**Workaround in place:** `Filters::Average.new(8)` on the two affected gauges, applied *before*
noise and quantisation, with the reasoning recorded at
[`panel.rb`](../../lib/reactor_sim/operations/steam_engine/panel.rb): *"lagging or quantising an
oscillation just gives you a lagged oscillation."* It is a display treatment only — the machine
still oscillates exactly as above.

### 6.3 The Draught gauge — live, unfixed, and the player sees it

This is the clearest illustration of the whole class, and it is still broken.

```ruby
Diagnostic.new(
  id: :air_supply, label: "Draught",
  source: Sources::Contents.new(:firebox, :air),
  filters: [ Filters::Lag.new(1), Filters::Bands.new([ 0.5, 3.0, 10.0 ]) ],
  display: Displays::Prose.new([ "choked", "thin", "adequate", "strong" ])
)
```

The bands want **0.5 kg** of standing air for "thin", **3.0** for "adequate", **10.0** for
"strong". The firebox never holds more than about 0.34 kg, because the flue clears it every
tick — the standing inventory is a function of the *hop pattern*, not of the draught.

Measured with the **damper wide open** (rated 8 kg/s), stoking 80, and an **879 K fire**:

```
   tick   firebox_air_kg   Draught gauge
    761           0.3381   "choked"
    763           0.3370   "choked"
    765           0.3360   "choked"
    767           0.3353   "choked"
    769           0.3347   "choked"
```

**Three of its four phrases look unreachable.** The reading above is at the *maximum* draught
the high-pressure variant can produce, and it is still a factor of 1.5 short of the "thin"
band; the atmospheric variant runs a weaker draught (`damper_conductance: 0.1`), so it can only
be worse. Confirming that no lever combination on either variant clears 0.5 kg is a sweep
nobody has run — but the mechanism says the ceiling is set by how fast the flue clears the box,
not by how much air arrives, and no lever moves that.

Two things make this worse than a cosmetic bug:

1. The gauge's own docstring says *"Air reaching the fire. Starve it and the fire dies with no
   other warning — the firebox just quietly stops making heat."* It is the designated warning
   instrument for a failure with no other symptom, and it is stuck on the alarm value while the
   engine runs perfectly. A player who learns to ignore it — and they will, since it never
   changes — has been trained to ignore the one gauge that was supposed to save them.
2. The prototype's own acceptance test said *"Draught reads adequate/strong"*. That step
   describes something the code cannot do. It was written from the intent of the gauge rather
   than from its behaviour, and nobody caught it.

---

## 7. The generalisation

> **The standing amount of something passing through a node is not a measure of its supply.**

An inventory answers *"how much is here right now"*. A flow-through quantity is characterised
by a **rate**, and its inventory is a function of the hop pattern rather than of the rate. The
two happen to correlate for things that accumulate — coal in a bunker, water in a supply tank —
which is why the mistake is easy to make and hard to see: **the same code is correct for a
stock and wrong for a flow.**

Everything currently reading in this shape:

| Reader | What it reads | Verdict |
|---|---|---|
| `Conduit#plan` | own `contents_kg` at N−1 | **the generator** — `h ↦ T − h` |
| `Arbiter.cap_gas_by_pressure` | source `pressure_pa` at N−1 | **the amplifier** — meaningless when the source is a duct |
| `ReliefValve#plan` | own `contents_kg` | same brigade; it is a `Conduit` subclass |
| `Cylinder#plan` | `node_pressure(@supplied_by)` | **the one correct reader** — deliberately looks past the duct to the boiler. Overridden by the arbiter anyway (§6.2) |
| `Ignition.remember_oxidiser` | firebox `parcels` | was a victim; now buffered |
| `Sources::Contents(:firebox, :air)` | firebox `parcels` | **live bug** (§6.3) |
| `Cylinder#apply` | `node_pressure(@exhausts_to)` | vessel or atmosphere in both variants — not currently affected, but only by luck of wiring |

Derive the current list with:

```sh
grep -rn "ctx.node_pressure\|ctx.node_state\|contents_kg" lib/
```

---

## 8. What the workarounds do, and what they do not

Both existing mitigations act on the **reader**. Neither touches the oscillation.

| Workaround | What it does | What it does not do |
|---|---|---|
| `Ignition::OXIDISER_MEMORY_PER_S` | Gives the fire a 1.5/s memory of the draught, rising instantly and falling slowly | Nothing about the draught itself. Any *other* consumer of firebox air hits the same wall |
| `Filters::Average.new(8)` | Settles two gauges over two seconds | Nothing about the cylinder. The machine still oscillates; the player just cannot see it |

The ignition memory is **independently defensible physics** — a bed of burning coal genuinely
does have thermal inertia and does not go out because the draught faltered for 250 ms. That is
what makes it insidious: it is a good model that we adopted for the wrong reason, and it is now
load-bearing for a problem it was not designed to solve. If the underlying oscillation were
fixed tomorrow, that constant should stay — but nothing currently records that it is doing two
jobs.

`Filters::Average` is more honest and more limited: it is explicitly a display treatment, and
its comment says so.

**Neither scales.** Every new node that reads a flow-through quantity needs its own bespoke
buffer, invented by whoever writes it, after they have lost a day to it.

---

## 9. Open questions for the design round

Framing only — this document deliberately proposes nothing.

> **Answered.** These were taken up in
> [`transport_model.md`](transport_model.md), which proposes moving mass onto
> `Relaxation` alongside heat and rotation, with conduits kept as failable nodes that hold no
> material. In short: (1) damp at source; (2) yes — `Sources::Flow`; (3) a conduit stops
> reporting a pressure at all, because it stops having a volume; (4) straight bug; (5) balance
> constants are disposable; (6) the guard is a no-alternation spec plus a rated-throughput
> spec, not a thousand-run attractor sweep.

1. **Damp at source, or teach readers to average?** A fix in `Conduit#plan` corrects every
   reader at once but changes the flow characteristics of every operation, and every tuned
   constant in the steam engine was measured against the current behaviour (§5).
2. **Should a node expose a *flow* as well as an inventory?** `grant.sent_kg` /
   `grant.received_at` already carry per-tick flow, but only inside `apply`, and only for the
   node itself — not through `ctx`, where the cross-node reads happen.
3. **Should a `Conduit` report a pressure at all?** It already reports `gas_headroom_kg` as
   `Infinity` on the grounds that a duct is not a container. `pressure_pa` arguably deserves the
   same treatment, which would fix §4 without touching flow dynamics.
4. **Is the halved throughput a bug or an undocumented convention?** If a conduit is *supposed*
   to deliver `T/2`, that should be written down and the ratings doubled. If it is not, fixing
   it silently doubles every draught in the game.
5. **What do we do about the balance constants?** Whichever way §4 goes, the skill gradient
   (60/80/60 survives; 80/90/70 bursts the flywheel) was measured against the oscillating
   machine and will have to be re-measured.
6. **What is the guard?** A conservation spec cannot catch this — conservation holds perfectly
   throughout. Whatever we build needs a spec that fails when a node starves, and it is not
   obvious what that spec asserts.
