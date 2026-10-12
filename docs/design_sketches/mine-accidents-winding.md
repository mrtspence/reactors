# Mine accidents, part 1 — the couplings, and the shaft

Input to design. Not a description of anything that exists.

The first of several drafts. This one designs **unit 1** (four prerequisites, P1–P4) and **unit
2** (the frame, and the cage and winding hazards). Units 3 and 4 are listed in §6 with what each needs from this
one, and are **deliberately not designed here**: they lean on P1–P4 and on the shaft as built, and
designing them now would be designing against guesses about code that does not exist yet. Each
gets its own draft once the unit before it has landed, so no one document grows past the point of
being reviewable.

The research behind the list — mechanisms, precedents, sources — is condensed in the appendix.

---

## 0. Decisions already made

**No beam engine.** Both engine chassis have a crankshaft, and a beam engine proper is a large
lift for the steam engine. The beam's hazards are got instead from **shaft-top gear on the mine's
side of the coupling**: a *bob* — a rocking iron beam over the shaft, driven by a crank off the line
shaft, which is how a distant rotative engine historically worked rods down a shaft — carries the
man engine here, and the Cornish set in unit 3. It hangs over the shaft exactly as an engine beam
did, and exposes the shaft to everything an engine beam would: fatigue, fracture, and iron falling
down the shaft.

**What that loses:** the engine trying to leap out of its own house when its load vanishes — a
Cornish engine with a broken pump rod slamming its indoor stroke into the catch beams. Underload
hazards still reach the engine through P1 (a rod parting is a load rejection like any other); only
that specific piece of character is gone. **A beam engine remains available as a later blueprint.**

**This is a mine pass, and steam-engine work is out of it.** The engine's governor — the answer to
a shed load — is deferred until after the pass (P1, "Deferred").

**The single shaft is the starting frame; two shafts is an upgrade.** That is Hartley's lesson
made into the tech tree: the starting pit has one way out and one shaft carrying both halves of
the air, and buying the second shaft is buying the second way out (S0).

**The engineman drives the cage; the player names where it goes.** A player driving the cage
directly is a possible later sidegrade, not designed here.

**The order of work:**

| Unit | Contents | Designed in |
|---|---|---|
| 1 | P1 two-way coupling, P2 the hoist, P3 ignition as a property of the room, P4 mishaps | this draft |
| 2 | S0 the single-shaft frame; first-order shaft and winding hazards, W1–W8 | this draft |
| 3 | Non-winding hazards that depend on P1–P4 or nothing new | a later draft (§6) |
| 4 | Hazards that need a new production tier | a later draft (§6) |

### Specs are thin slices, and every claim states its tick budget

**Ticks bear a real, linear cost**, and design cycles are meant to be short and frequent. So:

- **A claim that is a function is tested as a function, at zero ticks.** Torque at a given pair of
  speeds, snatch tension for a given slack, stopping distance for a given brake — these are
  arithmetic on a node and need no tick at all.
- **A claim about behaviour is tested from a constructed state** (`spec/support/constructed.rb`,
  `engine_rig`, `pit_rig`), running only the ticks that decide it. **Target ≤ 20; justify anything
  over 50 in the spec itself.** Every proposed example below carries its budget.
- **No example runs a whole machine to reach a precondition**, and no composite re-proves its
  stages. `current_progress.md` §"construct the state, do not wait for it" is the pattern.
- **A match-level claim uses two thin rigs, not the engine and the mine.** A coupling spec that
  first has to raise steam measures the boiler.
- **If a claim cannot be made short, restate it rather than fake it** — by its sign, by a rate, by
  `integrity` after a short run — as the ventilation tier and roof falls already are.

---

## 1. What exists, and the finding that reorders everything

**The coupling between operations is one-way and carries energy only.** `Match#exchange!` copies
the engine's `:load` `joules_extracted` into the mine's `Import` buffer. Nothing comes back:

- The engine's Mill Drive brakes on **its own** `load_demand` lever and fan curve. It never learns
  what the mine is drawing, so a mine throwing its clutch, or a rod parting, changes nothing
  upstream. The overflow lands in `Import#receive` and is booked as friction.
- `Import#apply` declares `rated_torque × (1 − ω/rated_omega)`, which is zero at `rated_omega`. A
  surging engine **cannot** overspeed the mine; surplus is simply wasted.

So the cross-operation chains this feature exists for — a mine shedding load bursting the engine's
flywheel, an engine surge driving a cage through the headgear — are currently impossible. P1 fixes
that, and it is the largest single unlock in the whole list.

What the shaft has today:

- `cage_drive` is a `Nodes::Load`, `curve: :constant`, which can only **brake**. Nothing can drive
  the drum backwards, so there is no overhauling load and no roll-back.
- The cage `Passage` is a speed scaled by a lever and by line-shaft `ω`. **There is no cage
  position**, so there is no overwind, no landing, no slack.
- **A traveller's passage is not recorded.** `Tick#step` re-picks `quickest` every tick, so a man
  half-way down in the cage when it stops is half-way down the *ladders* on the next tick.
- The coal `winder` is a rate-driven `Conduit` with `lift_m`, booking lift work as `:work`.
- The district has exactly one ignition source: `Vessel#run_heater` reads one lever id,
  `:naked_flame`, which only the open-flame lighting tiers declare.

---

# Unit 1 — Prerequisites

## P1. Two-way coupling

### The observation that makes this cheap

**`Import` is already a coupling to a reservoir.** Its torque curve rearranges to

```
τ = T_r (1 − ω/ω_r) = k (ω_r − ω)        k = T_r / ω_r
```

— a viscous coupling of conductance `k` to a shaft held at `ω_r`. The mine is driven by a rope
whose far end turns at a constant `rated_omega`. P1 is mostly **replacing that constant with the
far end's actual speed**, and giving the far end the mirror image.

### The proposal: both ends are rope ends

A coupling joins two **rope ends**, one in each operation. At the tick barrier — where
`exchange!` already runs, every read before any write — each end publishes three things from the
settled previous tick, and the other end receives them into state:

| Published | Received as | Used for |
|---|---|---|
| `ω`, scaled by the coupling's `ratio:` | `remote_omega` | the reservoir this end is coupled to |
| its clutch fraction | `remote_clutch` | `k_eff = k × own clutch × remote clutch` |
| joules it extracted | into its buffer (as `Import` today) | funding the next tick's driving |

Each end then plays one of two roles every tick, decided by which side of the reservoir it is on:

- **Slower than `remote_omega`: a driver.** Declares `k_eff(ω_remote − ω)` and is charged
  through `transmit_torque` against its buffer — exactly `Import` today, budget-scaled when
  starved.
- **Faster than `remote_omega`: a brake.** Declares the drag linearised as `τ(ω)/ω` — exactly
  `Load`'s idiom, bounded by `max_drag_conductance` — booked to `:work`, so it is exported.

**What crosses is the transmitted torque at the far speed, and the difference is slip.** A viscous
coupling carrying `τ` between `ω₁` and `ω₂` delivers `τω₂` and dissipates `τ(ω₁ − ω₂)`. The sending
end books both: export at the reservoir speed, slip as friction. The receiving end spends what its
shaft measurably gained, from its buffer, as `transmit_torque` already does.

**Conservation holds without either side trusting the other's arithmetic.** The receiver can
never spend more than it was sent (the budget scale), and anything it is sent and cannot use stays
in the buffer, overflowing to friction exactly as now. The lag shows up as a small, bounded
residue in the buffer, which is already counted in `total_joules`.

### What falls out

- **Load rejection (item 8).** The mine throws its clutch, a rope parts, a rod parts: next tick the
  engine end sees `remote_clutch` 0 or a remote shaft running up toward its own speed, its brake
  falls away, and everything the boiler is pouring in becomes acceleration. `Flywheel#overload?`
  does the rest. **No engine code changes.**
- **Overspeed delivered downstream (item 9).** An engine at 1.3× its working speed is a reservoir
  at 1.3×, and the mine's shaft is driven up to it.
- **The mine driving the engine.** An unbraked cage running away down the shaft spins the line
  shaft past the engine; the mine end becomes the brake, exports, and the engine end becomes the
  driver. **A runaway cage can burst the engine's flywheel** — the most "emergent" chain in this
  document, and it needs nothing beyond bidirectional ends.

### Ratio

`Coupling` gains `ratio:` (driver ω per driven ω). Speeds cross scaled by it; energy is invariant
under it, so the ledger needs nothing. `k` is declared on the mine side and reflected by `ratio²`.

### Stability: the one real risk

Each end sees the other's speed **as of last tick**, which is an explicit cross-term between two
implicit solves. For two equal inertias with `a = I/dt`, the gap between them scales per tick by

```
(a − k) / (a + k)
```

so past `k = I/dt` it **changes sign every tick** — the alternating, slowly-decaying ringing that
`Relaxation`'s own header records for an explicit pairwise law. At `k = I/dt` it is deadbeat.

> **Candidate rule: `k_eff ≤ min(I)/dt` across a coupling, refused at `Match#validate_couplings!`**
> beside the existing `time_scale` check. Today's line shaft is `I = 900`, `dt = 0.25`, so the bound
> is 3,600 N·m·s/rad against `Import`'s current 245 — plenty of room. **Unequal inertias change the
> factor; measure it on the two rigs before writing the rule down.** A rope drive is compliant in
> reality, so a soft coupling is also the honest one.

### Options considered

| | Pros | Cons |
|---|---|---|
| **A. Rope ends, roles by side of the reservoir** ★ | Reuses `transmit_torque` and `Load`'s linearised drag; no solver change; each operation still settles alone | One-tick lag; the stability bound above; a node that is sometimes a driver and sometimes a brake is a new shape |
| B. Teach `Relaxation` drags a non-zero reservoir potential | Exact implicit treatment of the local side (`diag += k`, `rhs += k·p_res`); the heat solve already does this to ambient | `book_drive` assumes a drag only *removes* energy — a reservoir that is faster than the shaft *adds* it, and that assumption is load-bearing in the measured-total split. Larger blast radius |
| C. One drivetrain solve across both operations | No lag, no stability bound | Breaks "operations step independently": `Match#step!` would need to settle drive between operations mid-tick, against `invariants.md` §3 and the per-operation `Tick`. **Reject** |

> **Recommendation: A.** B is the cleaner physics and may be worth it later if A rings; it is a
> change to the most carefully argued function in the engine, and nothing here needs it yet.

### The engine side

~~A `rope_drive` part in the `load` slot.~~ **Built instead: any load can be sold.** The dev match
takes the engine's loadout from the outfitting screen, which offers only mill drives, so a
dedicated part would have been refused or silently overridden. `Load` includes the rope concern:
a load a coupling names brakes by the rope instead of its own curve and is driven when the far end
overruns it; uncoupled it is the mill it always was. `load_demand` is its clutch either way.

### As built — three things the measurements changed

- **The braking end sends everything its rope drag took**, not `τ·ω_far`. Sending only the
  far-speed share looked like the honest split of work and slip, and it deadlocks: a stopped mine
  shaft has `ω_far = 0`, so nothing was sent, the mine had nothing to spend, and it never turned.
  The driven end spends what its shaft gained and its buffer overflows the slip to friction.
- **The rope's brake is its own drag destination, `:rope`, booked to `joules_roped`.** Booked as
  `:work` it was summed with every other `:work` drag on the same shaft, and the mine sent its own
  fan and pump work back up the rope to the engine — ~355 J a tick while it was the slower end.
- **The stability bound, measured** on an engine roped to a working pit: no reversal of the slip
  at a stiffness of the line shaft's `I/dt` (3,600), a reversal on 90 of 180 ticks at twice it.
  `Match` refuses a rope past either end's own `I/dt`. The default, 245, is far inside it.

And one the design missed: the coupled engine feels only the mine, which draws ~16 kW against a
working engine's ~495 kW, so at today's settings it bursts by tick 91. The mine's power rebalance
follows P1 as its own item.

### Deferred: the governor

P1 lands a new way to destroy the engine, and its answer — a centrifugal governor trimming the
throttle from `ω`, with a lag and a deadband so it is imperfect rather than an off switch — is
**steam-engine work, deferred until after this mine pass**. Until then the operator's hands are
the only thing between a shed load and a burst wheel. That is acceptable for a development
period and worth knowing when playtesting: an engine coupled to a mine with unit 2 in it will
burst more often than it will once the governor lands, and that is not a balance finding.

### Specs (P1)

| Claim | How | Ticks |
|---|---|---|
| Driver below the reservoir, brake above it, nothing at it | rope end as a function of `ω` and `remote_omega` | 0 |
| Clutch out at either end transmits nothing | function | 0 |
| Books close on both sides and together | two thin rigs coupled, one spinning | 20 |
| Order of operations in `exchange!` cannot change the result | swap order, compare digests | 20 |
| **Load rejection**: mine clutch out, engine `ω` rises | `engine_rig` at speed, coupled to a thin sink | 20 |
| Surge reaches the sink | source reservoir raised, sink `ω` follows | 20 |
| No sign alternation at the bound; alternation past it | measured on the rigs, sets the rule | 10 each |

---

## P2. The hoist

### The node

`cage_drive` becomes a **hoist**: a drum that carries its own rotor (`drives = id`, as `Import` and
`Motor` do) and knows where its cages are.

| State | Meaning |
|---|---|
| `angular_momentum` | the drum, as now |
| `position_m` | cage A's depth below the bank landing; cage B is at `depth − position_m` |
| `slack_m` | rope paid out that the cage has not followed (W4) |
| `payload` | who and what is in cage A |

**Two cages in balance**, as real winding was: cage B's weight cancels cage A's, so only the
*imbalance* — payload, mostly — costs power. It also gives W1 its classic shape for free: when one
cage overwinds at bank, the other is arriving at the bottom.

**Gravity is a driver.** The imbalance declares a constant torque `g r (m_A − m_B)`, charged by
`transmit_torque` like any prime mover's. **This is what makes roll-back possible**: a stalled,
unbraked drum is driven backwards by its own load.

> **Refined while building P2: gravity is an external field, booked on the ledger, not a store
> of potential energy in state.** Storing `potential_joules` would make every man stepping into
> the cage a change of potential at a fixed position — work done by his legs that something would
> have to book — and would tie conservation to how exactly position is integrated. Booking
> gravity's work as it is done is exact and needs neither: work it puts into the drum is
> `joules_added`, work raising a load takes out is `joules_to_work`, exactly as the coal winder
> already books its lift. Position then only has to be right for the game, not for the books.

### The drive: clutched, geared links

A line shaft turns one way; a drum must be driven both ways, held, and run backwards by its own
load. Decided in review: **two clutched drive links between the line shaft and the drum, inside
the one implicit drive solve** — forward, and a reversing gear.

- **A drive link may be geared.** With ratio `g`, the coupling's torque is `k·(g·ω_a − ω_b)`: `b`
  gains `τ·dt` of momentum and `a` loses `g·τ·dt`, because a gear multiplies torque. Momentum is
  not conserved across a gear and is not meant to be; energy is, and the slip a geared link
  dissipates is `τ·(g·ω_a − ω_b)`, never negative. In the solve it is still symmetric:
  `k·[g², −g; −g, 1]`. A reverser is `g = −1`.
- **A drive link may be clutched.** `control_id:` scales its conductance by the lever, and a
  disengaged clutch drops out of the network. The controller (below) works the clutches as its
  regulator: forward engaged to raise cage A, the reverser to lower it.
- **What it buys:** an overhauling cage with a clutch in drives the line shaft back, and through
  the rope the engine — so W5's roll-back and W2's runaway reach the engine house as physics,
  not as rules.
- **Two links between one pair of nodes need their own ids**, so `DriveLink` takes `id:`.

### Gravity is a source inside the drive solve, and the brake sticks

Found working it through: **if gravity is an impulse applied after the drive solve, no brake can
ever hold a cage.** The brake's drag is solved in phase 4d against a drum at rest; gravity then
adds its impulse in 4e; the next tick's drag removes it and gravity adds it again — so a "held"
cage creeps at about one impulse per tick, which for a laden deck is metres a second. The same
splitting would make an engaged clutch fight gravity a tick late.

- **Gravity enters the solve as a torque source** — a constant term on the right-hand side,
  `τ·dt`, which `Relaxation.settle` takes as `sources:` beside `drags:`. A clutch, a brake and the
  load then reach equilibrium together, implicitly, in one step.
- **Its work is booked by `Tick#book_drive`**, estimated at the settled speed as the drags are:
  into the operation as `joules_added` while the load is falling, out as `joules_to_work` while
  it is being raised.
- **The brake sticks, then slips.** Linearised as `τ/ω`, a constant-torque brake has no torque at
  rest and could never hold. So: while the drum is all but stopped and the brake's capacity
  exceeds the torque it is holding against, it is **locked** — a conductance so large the drum
  stays put; past that, it **slips** at its capacity. The torque it holds against is the hoist's
  own, read from last tick through the brake's declared `supports:` — the relationship
  `Bearing` already declares.

**Landings** are fixed marks: bank at 0, pit bottom at `SHAFT_DEPTH_M`. Above bank is the
headframe's clearance (W1); below the bottom landing is the sump.

### Levers: the player names a destination, the engineman drives

Real winding was three controls — regulator, reverser, brake — worked by an engineman driving to
bell signals and a depth indicator. **The player commands where the cage goes; the engineman is
the controller.** Driving a cage to a landing through a 4 Hz panel over a network would be a
latency tax rather than a skill, and putting the controller in the crew moves the hazard onto
crew choice, which the whole minion layer exists for. A later sidegrade letting a player drive
directly is possible and not designed here.

**The commanded lever.** `man_winding` becomes a **destination** in percent of shaft depth — 0 the
bank landing, 100 the pit bottom. Absolute and idempotent, as every command must be. A value
between landings is legal and means "stop there", which is how a cage is held in the shaft to
inspect it. It moves to the certificated post: `complexity:` and `requires: :certificated` go
where the overwind is.

**The driven levers.** Two **internal** control points, `:regulator` (−100..100, signed for the
reverser) and `:winding_brake` (0..100), are what the hoist reads through `ctx.controls` like any
other lever. **No command may set them** — `set_control` refuses an internal lever — because their
`actual` is written in phase 0 by the engineman's controller and nothing else.

**The controller** is a pure function, beside the hoist in `operations/mine/`:

```
drive(destination_m, hoist N−1 position and speed, competence, this tick's fate)
  → regulator, brake
```

It drives toward the destination and starts braking at a **brake point it believes in**:
`v² / 2a_believed` plus a margin, where `a_believed` is a nominal figure for a sound brake. The
hazards come from where that belief and the world part company:

- **Competence** sets the error in the brake point and the margin. A ticketed engineman's is small.
- **Slips**, already drawn for `winding` today, keep their meanings: a freeze is a late stop, a
  wrong direction is a wrong direction, a wrong lever is the brake grabbed or not grabbed.
- **The world**: a faded brake (W2) decelerates less than believed, and a surge (P1) arrives with
  more speed than the brake can take out of the distance left. **Overwinds emerge from the gap
  between belief and truth**, with no rule saying when one happens.

**No new draws.** The controller reads the fates `draw_fates` already throws — slip, kind, victim —
so the per-minion draw count stays fixed, which is the rule that keeps replay intact.

**Phase 0 now reads node state.** It is the frozen N−1 state, so order-independence is untouched,
but it is a new dependency and `tick.md` must say so.

**The hoist does not know whether anybody is winding it.** Unattended means only that nobody is
running the controller: the regulator and the brake stay exactly where they were last left, and the
hoist goes on obeying gravity, the supply and its own brake, minus nothing but the operator. There
is no unattended branch anywhere in the node.

What that produces, with no rule saying so:

- A cage left at a landing with the brake on stays there, because the brake holds it.
- **A cage abandoned mid-wind runs on** — an engineman stood down by an injury, or sent elsewhere,
  with the regulator open is a cage going into the headframe.
- A cage left braked mid-shaft on a faded brake creeps, and then runs (W2).

The internal levers have no target to travel toward — the controller writes their `actual`
directly — so the rule that an unattended lever travels at its rated speed has nothing to act on,
and they simply hold.

> **Interim: two certificated posts.** The coal winder's `winding` stays certificated and stays a
> rate this pass (see "What P2 leaves alone"), so a pit winding coal and men needs two ticketed
> hands. They merge into one post when coal goes onto the hoist.

### Riders: committed to the passage

A man in the cage stays in the cage. On boarding, a rider records `via:` the hoist's passage;
from then on **their progress is the hoist's position**, not their own pace. They board and alight
only at a landing with the cage there and stopped, and cannot switch to the ladders mid-shaft.
`endangers:` gains **`riders:`** (by hoist id) beside `places:` and `stations:`, and `injury_spec`
walks it like the other two.

Rejected: the cage as a moving place (coherent, but a place with no fixed position touches
`Layout`, breath and every place sweep), and leaving travel alone (cage and riders would disagree
about where the cage is, and overwind would hurt the wrong people).

**A stranded cage now exists**: riders committed to a stopped hoist wait where they are. That is
item 10's shaft half, and it comes free.

> **As built.** `riders:` on `endangers:` is **not** in P2 — nothing hurts a rider yet, so it lands
> with W1, its first caller. One rule the design missed: **a cage with no power behind it is not a
> way down**, so a ridden passage is offered only while its shaft is turning, and a rider in a
> stopped cage at the landing they boarded at steps off and takes the ladders. Without it a starved
> pit's shift boarded a cage that could not move and waited in it forever.

### The man engine is not a hoist, and shares only the shaft-top gear

A man engine is a rod reciprocated by a crank through a **bob**. It needs a **stroke phase**
integrated from the line shaft, and the same `via:` commitment for riders (who still advance by the
passage's speed, since the rod carries them twelve feet a stroke). The bob is a `Wearing` node over
the shaft; W7 is its hazards.

> **As built: the stroke phase moved to W7**, its only caller — built ahead of it, it would be a
> field nothing reads.

### What P2 leaves alone

**The coal winder stays a rate-driven conduit** for this pass, and only for this pass. A rate
with `lift_m` is hard to justify beside a physical hoist, and it gets harder with every hazard built
on the hoist that coal is exempt from. **Coal on the hoist is the first item of the next pass**
(§6): a loaded deck is payload, overload counts tubs, an overwind can happen with no men aboard, and
the two certificated posts become one.

### Specs (P2)

| Claim | How | Ticks |
|---|---|---|
| Gravity torque from imbalance; balanced cages cost nothing | function | 0 |
| Position follows the drum | constructed drum at speed | 10 |
| **An unbraked, unsupplied, loaded drum runs backwards** | constructed stall mid-shaft, supply cut | 10 |
| Potential energy balances the books, both directions | hoist up, then run down | 20 |
| A rider's progress is the cage's; they cannot leave mid-shaft | constructed rider aboard, hoist stopped mid-shaft | 10 |
| Boarding only at a landing with the cage there | rider at bank, cage at bottom; then cage at bank | 10 |
| The controller's brake point: early for a ticketed hand, late for an unticketed one | function | 0 |
| A sound brake stops short of the mark; a faded one at the same brake point does not | function over the controller and stopping distance | 0 |
| Nobody at the post: the levers hold where they were left | constructed hoist, post emptied | 5 |
| A cage left braked at a landing stays; one left driving mid-wind runs on | constructed, post emptied | 5 each |
| `set_control` refuses an internal lever | command against a built mine | 0 |

---

## P3. Ignition as a property of the room

### The proposal

A node may answer **`ignition(state, levers)`**, returning the igniter strength it offers the air
of its place, in the same kg/s seed units `run_heater` uses now. `Tick` builds the map per place
from **N−1 node state and this tick's levers** — the exact construction `ambient_tags` uses, for the
same order-independence reason — and the place's air vessel adds it to its own seed.

**The first caller is the existing candle.** Open-flame `Lighting` answers `ignition` with its
`igniter_kg_per_s × lit fraction`, and the district's `heater_control_id: :naked_flame` goes away.
P3 is therefore born as a refactor with a real caller, guarded by `district_fire_spec` as it
stands, rather than a seam waiting for one. **The second caller is the signal bell (W6)**, in
unit 2.

**Alternative: a list of `heater_control_id`s on the vessel.** Cheaper, and wrong: a vessel would
have to know every source by lever id, and the sources unit 3 wants — a hot bearing, a gauze lamp
in a fast draught — have no lever at all. Reject.

**The event changes shape slightly.** `:heater_engaged` names the control that lit it; it should
name the **source node** instead, which the delivery tier already gets for `part_failed`.

**Seams, by name** — each marked in code as a `TODO:` naming its caller, untested until it lands:

- gauze lamps whose flame passes in a fast draught — unit 3, item 15
- hot bearings and a burning headgear — unit 3, item 12
- the fan drift when a stopped fan is restarted — unit 3, item 10
- a blown-out shot — unit 4, item 20

### Specs (P3)

| Claim | How | Ticks |
|---|---|---|
| The map is the sum by place of what nodes offer, from N−1 | function over a built layout | 0 |
| Candle-lit district behaves as before | `district_fire_spec`, unchanged | as now |
| A safe tier offers nothing | function | 0 |

---

## P4. Mishaps — a peril whose consequence is the machine

### Why it is a prerequisite rather than a shaft feature

Today a peril has exactly one outcome: the minion whose margin ran out is hurt. W4 wants a
different one — *the clumsy banksman lets a tub run into the shaft* — where the person is fine and
**the machine** takes the consequence. That is going to be a frequent pattern in every operation:
a fireman cracking the gauge glass, a deputy dropping a lamp and splitting its gauze, a trapper
propping a door. So it is built once, generically, beside the peril model, with nothing in it
that knows about mines.

### The shape

**A peril may name a mishap as well as, or instead of, an injury:**

```ruby
Peril.new(id: :tub_into_shaft, severity: 1.0, scales_with: :winds, places: %i[bank],
          mishap: { node: :shaft, kind: :obstruction })
```

- A positive `severity:` hurts the person, as now; zero means no Danger Check. `tags:` are only
  what the injury is resisted by.
- `mishap:` names a node and a kind. At least one of the two outcomes is required.

**Incidence is the one margin, as now**, spent by every peril in reach. Safety equipment turns
either outcome into a near miss. A fitting deletes either by not declaring it: **shaft gates are
the fragment without the tub peril in it.**

### Which peril fires: a pick weighted by this tick's spend

The rule applies to every peril, mishap or injury, and **replaces the one already built** — so it
lands in P4 rather than being left to the haulage road.

**Today the cause is `max_by` over this tick's bites**, and that quietly throws away the variety
the declarations promise. Perils at one place usually share one activity measure — the haulage
road's three all scale with `:tubs` — so the ratio between their bites is fixed by declaration,
and the same peril always wins. A human on that road is caught in the haulage every time and is
never struck by a tub.

**At the crossing, the peril is picked at random with probability `bite / Σ bites`**, over the
perils in reach on that tick.

- **One margin reproduces the mix that a margin per peril would give.** With independent margins
  each peril fires at a long-run rate in proportion to its own spend; with one margin and a
  spend-weighted pick, the expected count of each is the number of crossings times its share of the
  spend — the same proportions, with one number in state rather than one per peril.
- **This tick's bites, not the episode's.** They are already computed, they restrict the pick to
  what reaches the person *now* — nobody is caught in the haulage while standing at the shaft top —
  and they tell the right story for a bursty hazard: the margin is luck and attention, and once it
  is gone whatever arrives next is what gets you. A slow grind that did most of the depleting gets
  little say if a burst lands on the crossing tick, and that is accepted.

### Rate is not severity

**A peril declares how often it bites separately from how hard.** One figure did both, and with a
weighted pick that inverts the injury pyramid: the worst thing on the haulage road would also be
the commonest. In every real workplace the minor accidents vastly outnumber the deadly ones, and
the deadly ones are often the rare ones — which the model had no way to express.

```ruby
Peril.new(id: :struck_by_tub,     rate: 2.0, severity: 1.4, ...)  # often, and it bruises
Peril.new(id: :caught_in_haulage, rate: 0.4, severity: 2.6, ...)  # seldom, and it kills
```

- **`rate:` spends the margin** and therefore also decides how often a peril is the one picked:
  `bite = rate × weight_for × activity × susceptibility × SPEND_PER_S × dt`.
- **`severity:` is the Danger Check**, and nothing else.
- **`rate:` defaults to `severity:`**, so the change is behaviour-neutral except for the pick itself,
  and the haulage road is then retuned deliberately — a short sweep, not a guess.

### The die

**`draw_fates` gains a `peril:` draw, thrown every tick for everybody**, used only at a crossing and
discarded otherwise — the fixed-count rule that keeps replay intact. No existing draw will do:
`dodge` decides whether safety equipment saves the same accident, so reusing it would correlate
*which* accident with *whether it was dodged*, and `kind`/`victim` belong to slips. Adding a draw
shifts every seed's sequence once; there are no replays yet to break.

> **Trap: the pick must walk the perils sorted by id.** `perils_in_reach` is built by iterating
> `nodes`, and `graph_spec` shuffles declaration order and compares digests. `max_by` only depended
> on order at an exact tie; a cumulative pick depends on it every time, so an unsorted walk picks a
> different accident from the same seed depending on how the operation listed its nodes.

### When the machine feels it: next tick, through the events

The mishap is decided in phase 6d, after phase 6 has already settled every part's wear. Three
places it could land:

| | Pros | Cons |
|---|---|---|
| a. Write the node in 6d, this tick | No lag | A second writer to node state after `stress`, outside the one place wear is settled. **Reject** |
| **b. A mailbox key in state, read next tick** ★ (built) | Explicit, and snapshotted with everything else | A new state key that phase 8 must name, holding symbols as values that `Operation#restore` must normalise |
| c. The mishap is an event, and next tick's `stress` applies it | No new state: `state[:events]` is already last tick's events. The same shape as `spread_damage` | **Events are not snapshotted**, so a pending mishap is lost across a restore. **Reject** — see below |

> **Built: b, not c.** c was recommended and built first, and it is wrong: **`Operation#to_h`
> leaves `events` out of a snapshot on purpose**, because they are output already published. A
> mishap waiting in them vanished across a restore, so a match snapshotted between the mishap and
> its consequence resumed without it and diverged from the one that ran straight through. The spec
> that should have caught it injected the event by hand after `to_h`, which is exactly the path
> that does not lose it. So the mishap is reported as an event for the delivery tier *and* written
> to `state[:mishaps]`, which is snapshotted, normalised on restore, and read by the next tick's
> `stress`. b's "serialisation trap" con was real and is paid in `Operation#restore`; c's was
> worse and silent.

### What the node does with it

`Node#suffer(state, mishap, ctx) → [state, events]`. **The default lives in `Wearing`** and is
`spread_damage`'s: lose a share of starting durability, scaled by `severity`, breaking through
`break_part` with `cause: :mishap` if it runs out — so a failure a person caused is a `part_failed`
like any other, distinguishable by its cause. A node with a structural consequence overrides it:
the shaft adds an obstruction. A node with neither refuses the mishap at build, because a peril
pointing at something that cannot suffer it is a hazard that silently does nothing.

### The event

**`:minion_mishap` is a new type**, because no existing one is the transition: nobody is hurt, so
`minion_hurt` is wrong, and nothing has necessarily failed. Severity `:warning`, `cause:` the peril,
`detail:` the node and the minion. The delivery tier can then say "Jim let a tub into the shaft"
and, a tick later, read whatever the shaft did about it. `event_spec` finds it by its literal
`type:`.

### Callers

- **First caller: the tub into the shaft (W4).**
- Seams, by name: a deputy dropping a lamp and splitting the gauze (unit 3, item 15); a trapper
  propping a door (unit 3, item 14). Out of this pass, the generality test is the steam engine's
  fireman cracking a gauge glass — named here so that whoever builds it knows the mechanism
  exists, and **not** built as part of this work.

### Specs (P4)

| Claim | How | Ticks |
|---|---|---|
| The pick: given these bites and this draw, this peril — at each boundary of the cumulative weights | function | 0 |
| The pick is the same however the perils arrive ordered | the same function over a shuffled list | 0 |
| `rate:` spends the margin and `severity:` does not; `rate:` defaults to `severity:` | `Blunder.spend` as a function | 0 |
| A mishap peril and an injury peril compete in one pick | function | 0 |
| A mishap event in last tick's events damages the named part | constructed state with the event already in it | 1 |
| A part worn through by a mishap fails with `cause: :mishap` | same, part seeded near its end | 1 |
| A mishap naming a node that cannot suffer it is refused at build | build | 0 |
| A seeded-thin margin at the shaft top produces the mishap and then the obstruction | constructed banksman, only the tub peril in reach | ≤ 20 |
| A snapshot taken between the mishap and its consequence replays identically | round-trip on that tick | 2 |

---

# Unit 2 — The shaft

## S0. The frame: a single shaft first

**The starting pit has one shaft.** It carries the cage or man engine, the ladderway, and both
halves of the ventilation — downcast and upcast as two compartments divided by a **brattice**.
Two shafts becomes an upgrade, separately unlockable as every chassis already is.

**What changes in the frame:**

- **`single_shaft` joins `CHASSIS` and becomes the default.** The downcast and the upcast stay
  separate conduits — they are separate airways — but both belong to one shaft node (W4), so what
  happens in the shaft happens to both.
- **The brattice is a leak path between them**, on `Inrush`'s pattern: nearly shut while sound, a
  torrent when broken. Broken, the fan pulls air down one side and straight back up the other and
  the district starves. Wreckage in the shaft damages it through `failure_damages`.
- **`two_shaft` gains what it promises.** Its comment says "there is a second way out", and **there
  is no passage up the upcast** — the second way out does not exist. The upgrade adds a ladderway
  in the second shaft; that is what the player is buying. That comment should be corrected on
  sight if this work does not land soon.

**What it buys without a single new hazard rule:** a rod parting (W7) or a jam (W4) in the one
shaft blocks the only way out *and* takes the brattice with it, so the men below are trapped in a
district whose air has just been short-circuited. **That is Hartley's shape**, from unit 2's own
parts; the falling engine beam that caused it there is unit 3's Cornish set.

**Leakage belongs to the brattice that is fitted.** A brattice slot on the single-shaft frame, and
its tiers differ in how much air gets through them sound:

| Tier | Kind | Leaks | What it trades (deferred, see §6) |
|---|---|---|---|
| Canvas sheet | temporary | a lot | comes down harmlessly |
| Creosoted canvas | temporary | less | burns |
| Timber | permanent | a fair amount | a real obstruction when it falls |
| Concrete walling | permanent | very little | a devastating obstruction when it falls |

**This pass builds the leakage only.** Every tier is the same leak-path node with a different
figure; what each does when it comes down or catches fire is deferred, because the dynamics only
mean something against roof falls, fires and shaft obstructions that do not all exist yet.

**`Ground::RANGE` was tuned against the two-shaft pit's fan**, and any leakage moves that line.
Mine specs that measure ventilation figures pin their frame and brattice the way they already pin
`ground:`, so changing the default frame does not move every figure in the suite.

**Specs.**

| Claim | How | Ticks |
|---|---|---|
| A broken brattice starves the district | constructed failed brattice; district air flow by its sign | 20 |
| Canvas leaks most, creosoted canvas less than canvas, concrete least of all | the leak path's conductance per part | 0 |
| A blocked shaft leaves no route out of a single-shaft pit, and one in a two-shaft pit | `Layout` routing | 0 |
| A rod parting breaks the brattice | failure event with `failure_damages` | 1 |

Each hazard below names its mechanism, its model on P1–P4, its counterplay, what it does across the
coupling, and its specs. Precedents are in the appendix.

**Shared plumbing.** Failures report through `part_failed` with a mode — no new event types. People
are reached by `places:`, `stations:` and P2's `riders:`. **Nothing in the game resists `crush`,
`impact` or `fall` yet** (`current_progress.md`), so every shaft accident lands at full severity on
everybody; that pass over `kit.rb` should land with this unit rather than after it, or the safety
kit a player buys against the shaft does nothing.

**Tune per shift, not per person.** `mine-follow-ups.md` Part 0's trap applies doubly here: seven
new hazards each at a "reasonable" rate is a disaster every few minutes.

## W1. Overwind and underwind

**Mechanism.** The engineman stops late — a slip, a misread depth indicator, a surge outrunning
him — and cage A passes the bank mark at speed into the headframe. Stopping distance is `v²/2a`
against the headframe's clearance; past it, the cage hits the sheaves, the rope parts, and cage A
falls back down an open shaft while cage B hits the bottom. Underwind is the bottom end: arriving
at the pit-bottom landing faster than a landing speed, severity in `v²`.

**Model.** Hoist modes `:overwound` → `:crashed`, decided by speed at the mark. Riders take
`impact`/`fall` scaled by that speed (`scales_with:`, `reference:`). An overwind that parts the rope
hands off to W3's fall.

**Counterplay.**

- **The engineman.** Certificated, already slipping, already the one post that takes knowing how.
- **A depth indicator** — an instrument at `winding`, with tiers: chalk marks on the rope read by
  the banksman (`observer:`, so misreadable), a dial, a dial with an overwind bell.
- **A detaching hook** (King's 1867): a pure-safety fitting that turns the fall-back into a cage
  hung in the headframe — a near miss rather than a casualty list.
- **An overwind trip**: an automatic brake past a mark. **Only as good as the brake** (W2).

**Across the coupling.** An engine surge (P1) delivers the cage faster than the engineman's brake
point assumed. A detaching hook releasing **is** a load rejection upstream.

**Specs.** Stopping distance against clearance as a function (0). A cage constructed just below
bank at speed, brake late → overwound; same at landing speed → lands (10 each). The hook converts
the fall (10).

## W2. Brake failure and runaway descent

**Mechanism.** Markham's brake was **spring-applied and held off by power**, acting through a rod
permanently in tension. A fatigue crack grew until the rod parted, and the emergency stop that
should have saved it cut the power — and with it the dynamic braking. Separately, **brake fade**:
a long overhauling descent heats the paths, the lining glazes, and friction falls.

**Model.** A **brake node** that is a friction interface on the drum. Its drag names itself as the
destination, so `book_drive` already heats it — exactly how a `Bearing` runs hot. Friction falls
with temperature; linings are `Fusible`. The rod is `Wearing`, stressed per application and by
time under tension. Modes: `:glazed` (derates friction) → `:rod_parted` (no force, whatever the
lever says).

**The compound is the point.** A sound brake holds a brownout; a parted rod with the supply up
still has the engine's dynamic braking through P1. **Both at once is Markham** — and the player
can always reconstruct it: "I left the brake unserviced and the engine house browned out."

**Counterplay.** Brake inspection as an observer-read gauge; a heavier brake path as a fitting; a
second, independent brake as the top tier; keeping the supply up.

**A sibling of `Bearing`, not a third `duty:`.** A bearing's oil round is meaningless on something
that must run dry, and a `duty:` that switches off half the class is two classes. `Nodes::Brake`
shares the friction law — extracted so the two cannot drift — and not the class.

**The lever sets how far the brake is held off.** `:winding_brake` is what the controller (P2)
writes, and it stays wherever it was left when nobody is at the post. The spring applies whatever
the lever does not hold off — so a parted rod means the brake is "on" by the lever and has no
force behind it, whoever is or is not standing there.

**Specs.** Friction against lining temperature (0). A constructed hot brake on an overhauling
drum decelerates less than a cold one (20). Rod parted + supply cut → runaway; either alone → held
(10 each).

## W3. Rope failure, and the sheave

**Mechanism.** Bending fatigue over the sheave once a wind; corrosion fatigue — hidden, internal,
worst in wet shafts; kinks left by slack; overload and snatch. And heat: **a sheave whose bearing
seizes leaves the rope dragging over a stopped pulley.**

**Model.** A rope node, `Wearing`, stressed by winds × tension, by wetness (`Mine::Ground`'s water
draw is the corrosion rate, so a wet pit eats ropes), by sheave temperature past a threshold, and
by W4's kinks. `overload?` when tension exceeds breaking strength × integrity. Modes `:frayed` →
`:parted`. A parted rope drops cage A and **unloads the drum** — a load rejection upstream.

**The sheave is a `Bearing`, `duty: :journal`**, which `nodes.md` already names as the intended use.
Its heat, oil and seizure are built. **Its temperature is also the seam for the headgear fire**
(unit 3, item 12) — `TODO: first caller is unit 3`.

**Counterplay.**

- **Rope inspection** — the banksman's report, observer-read, banded prose ("she looks sound").
- **Recapping** — an effort station at bank, worked with the cage at the landing and the shaft out
  of service. Cutting off the worn end restores some integrity, and **the rope is shorter every
  time**: it carries `spare_m`, each recap spends a fixed length of it, and with none left recapping
  does nothing. A finite resource inside a match.
- **A spare rope** — a fitting whose whole value is reliability. Fitted, it lets the shaft be
  **re-roped** mid-match: a long job at the same post, consuming the spare and leaving a new rope at
  full integrity and full length. **A blueprint, so the choice is made between matches**: a player
  spending progression on a spare rope is choosing reliability over capacity, which is the
  risk-reward trade the tech tree is supposed to keep offering. It wins no coal and shows nothing on
  a gauge until the day it is used, exactly as the manholes are.
- **Safety catches** (keps gripping the guides) as a fitting: a parted rope becomes a near miss
  more often than not.
- **Oiling the sheave**, which is the bearing's oil round, already built.

**Specs.** Snatch tension for a given slack (0 — see W4). A rope seeded near its end parts under a
loaded wind and not under an empty one (10 each). A constructed hot sheave wears the rope faster
than a cool one, read off `integrity` (20). Catches turn the drop into a near miss (10). Recapping
a constructed worn rope raises its integrity and spends `spare_m`; with `spare_m` at zero it does
nothing (5 each — the rig's job length is short, or the state is constructed near the job's end).
Re-roping consumes the spare and leaves a new rope; with no spare fitted the job is unavailable
(5 each).

## W4. Hang-ups, slack rope, and things in the shaft

**Mechanism.** The cage jams on its guides or on something in the shaft. The drum keeps paying
out, slack piles on top of the cage, and when the jam gives, the cage falls the slack. With the
rope as a spring of stiffness `s`, the peak tension is

```
T = mg + √((mg)² + 2 s m g h)
```

which is **exactly double the static load at zero slack** — the Milfraen inquiry's "at least
double" — and climbs with the square root of the slack.

**Model.** A **shaft node**: no ports, like `Manholes`, holding what is in the shaft and where. An
obstruction holds the cage while load spends its hold (a durability, so no dice); meanwhile the
drum's payout minus the cage's descent accumulates as `slack_m`. When the hold is spent, the cage
falls the slack: snatch tension to W3, `impact` to the riders, a kink to the rope. The ladderway
passes the same obstruction and is **blocked by it** — which is the Hartley shape, and the first
time the shaft itself can trap a shift.

**Where obstructions come from in unit 2:**

- **A clumsy banksman lets a tub run into the shaft** — P4's first caller. The shaft node overrides
  `suffer` to add an obstruction at the bank end, and a falling-object hazard to anybody riding
  below. Shaft gates are the fragment without the peril in it.
- **Wreckage from W7** — a parted man-engine rod.

**Counterplay.** Shaft gates; a slack-rope indicator (a real period instrument); an engineman who
stops when the depth indicator says the cage has stopped and the drum has not.

**Specs.** Snatch tension at zero slack is 2mg; rises with slack (0). A constructed jam accrues slack
while the drum pays out (10); freeing it produces the snatch (10). The ladderway is impassable while
blocked (5).

## W5. Overload: stall and roll-back

**Mechanism.** More payload than the supply can lift: the drum stalls, then — the hoist being an
overhauling load — runs backwards.

**Model.** Nothing new beyond P1 and P2. Payload is riders' `mass_kg + worn_kg`, which the sheet
already carries for `Burden`. A cage has a rated payload; boarding past it is allowed unless
somebody stops it. **The banksman is who stops it**: posted, boarding is capped at the rating;
unposted, everybody piles in.

**Across the coupling.** A brownout upstream rolls a cage back without the mine operator touching
anything. A cage running away backwards drives the line shaft, and through P1 the engine.

**Specs.** Covered by P2's roll-back example, plus: a banksman caps boarding; nobody at bank does
not (10 each).

## W6. Signalling

**Mechanism.** The engineman winds on bells from the banksman and the onsetter, and cannot see the
cage. A false "ready" — men still boarding, gates open — catches men between cage and shaft side.
And the bells themselves: Senghenydd's inquiry judged a **signal-bell spark** the likeliest ignition.

**Model.**

- **Onsetter and banksman are posts.** Boarding takes time, so a rider is *boarding* for some ticks
  at the landing.
- **"Ready to wind" is an instrument with `observer: :onsetter`.** A poor onsetter reports ready
  while somebody is still boarding, and holds the wrong belief — `Misread`'s hold, already built.
- **Winding while somebody is boarding** is a hazard to that rider: `crush`, keyed by `riders:`.
- **The bell is an igniter (P3)** at the places it rings, scaled by its battery: the second caller
  of P3. A flameproof bell is a fitting that offers nothing.

**Why this one is worth its cost.** Almost all of it already exists — `observer:`, `Misread` with a
hold, slips, perils, near misses. What it adds is **one minion's report driving another minion's
lever**, so a good engineman paired with a bad onsetter is a crew problem nobody near the machinery
can see. That is the strongest crew-composition puzzle on this list.

**Specs.** A poor onsetter's ready reads true while boarding more often than a good one's — sized
like `slip_spec`'s sample, not more (≤ 400). Winding on a boarding rider hurts them (5). A rung
bell in a firedamp-laden constructed mix ignites; a flameproof one does not (`ignition_rig`, 20).

## W7. The man engine and its bob

**Mechanism.** Every stroke is a step on or off at a reversal; a tired or clumsy rider mistimes it
and is caught or falls. And Levant: **the bracket joining the beam to the rod broke**, the rod fell,
the platforms went with it — and the safety catch that should have held it **was knocked out of line
by the same breakage**.

**Model.**

- **Missteps are a `Peril`**, `scales_with: :strokes` — the cleanest fit for the peril model on the
  whole list. Overspeed (a surge, P1) shortens the step window, so the same rider at the same post
  is spending margin faster because the *engine house* opened its throttle.
- **The bob and its strap are `Wearing`**: stressed per stroke × riders × speed², with `overload?`
  on a hard reversal. Modes `:cracked` → `:parted`.
- **A parted strap drops the rod**: `fall` to everyone on it, wreckage into the shaft (W4's shaft
  node, blocking the ladderway), and the rod's load gone from the line shaft — **a load rejection
  upstream**, which is the chain you asked for.
- **Catches on the rod** as a fitting, whose effectiveness depends on **how** it failed: a fatigue
  parting leaves them in line and they mostly hold; an overload parting knocks them out and they
  mostly do not. Levant, by mode.

**This is where the beam's hazards now live** — §0's decision made concrete.

**Specs.** Missteps per stroke rise with stroke rate and with a clumsy rider (seeded thin margin,
≤ 200, sized as `peril_spec`'s finding says). A strap seeded near its end parts at overspeed and not
at working speed (10 each). The parting blocks the ladderway and unloads the shaft (10). Catch
effectiveness by mode (0).

## W8. What the shaft does to the engine house

Not a hazard of its own — the winding triggers for items 8, 9 and 10, collected so none is lost:

| Trigger in the shaft | Upstream through P1 |
|---|---|
| Rope parts (W3), hook detaches (W1), rod parts (W7), clutch thrown | load rejection — engine overspeeds |
| Cage runs away backwards (W5, W2) | the mine **drives** the engine — engine overspeeds |
| Engine surges | cage overspeed (W1), shorter man-engine step windows (W7) |
| Engine browns out | stranded cage (P2 riders); roll-back (W5); no dynamic braking (W2) |

**Spec.** One end-to-end example: rope parted on a loaded wind, engine `ω` rising on the next ticks,
on the two thin rigs (20). Everything else is already proven a slice at a time.

---

## Unit 2, as built — where it parted from the design

- **S0.** The shaft is a portless `Wearing` node every way runs `through:`; routing became
  shortest-distance, keyed by the closed set, because the second way out is the long one.
- **W1.** `position_m` is **rope paid out**, which is what a drum-geared depth indicator honestly
  reads; the cage is `cage_m`, which only differs once W4 can hang it. The engineman's belief in a
  2 m/s² brake against a real ~9.5 is left for the tuning pass.
- **W3.** No `:frayed` rung — a failure takes a part out of service, and a rope still in use is not
  that. The banksman's rope report (`observer: :banking`) is the warning. Catches come with the
  hooked tiers rather than as a separate fitting. The sheave is a `Bearing` on the drum, so a seized
  one stops the winding as well as scoring the rope; its dry equilibrium (~400 K) is estimated from
  a 376 K measurement at a slightly higher heat loss.
- **W4.** A tub lodges at a fixed 25 m, or falls onto the cage if the cage is below that — and
  **that fall hurts nobody yet** (TODO on `Mine::Shaft#suffer`: a mishap cannot raise a hazard). A
  jam interacts with a descending cage only. A snatch the rope survives jolts nobody. Shaft gates are
  the bank's `safety_equipment` rather than the fragment without the peril, because a gate left
  open is the realistic failure and attention-gated saving already models it. While hung, cage B's
  unbalanced weight is not modelled — the drum simply feels nothing of cage A.
- **W5.** The cap is a pass after the walk that admits this tick's boarders **in id order** against
  last tick's cargo, so two boarders on one tick cannot both slip under the rating.
- **W6.** The ready signal is the marshal's state, read by the governor in phase 0 — not an
  instrument; there is no "ready to wind" gauge. A false ready is **any slip** at the marshal's
  post, so it rides the existing slip machinery and its `complexity:`/`boneheaded` gates. The pit
  bottom gained the firedamp reaction so the bell has something to light, which also lets a
  district explosion's flame arrive there.
- **W7.** No reciprocating stroke phase: `strokes` is `(ω/rated)²`, which is what a step window
  shortening with speed needs. Riders of the rods are found by a new `riding` field — the man
  engine's `via` — which `riders:` hazards and perils both key on. Catches are a second part tier.
- **Kit.** A pit helmet and a safety belt; `blast` and `afterdamp` remain unresisted by kit, which
  is deliberate for afterdamp (breath has its own apparatus) and open for blast.
- **During the pass**, `boneheaded` became **cubed** (`Minion#daftness`), so a 1.0 hand is an
  accident waiting to happen rather than a mild version of a 0.3 one.

---

## 5. Decisions from review

**Decided:**

1. **The governor** is steam-engine work, deferred until after this mine pass (P1).
2. **The engineman is the controller**; the player commands a destination. Driving the cage
   directly is a possible later sidegrade, not designed (P2).
3. **Riders are committed to the passage**, their progress slaved to the hoist (P2).
4. **The brake is a sibling of `Bearing`**, sharing the friction law, not a third `duty:` (W2).
5. **Recapping is a finite effort station at bank**, and **a spare rope** is a reliability fitting
   chosen between matches — capacity against reliability, at the progression level (W3).
6. **Mishaps are general**, built beside the peril model for every operation (P4).
7. **The single shaft is the starting frame**; two shafts is the upgrade, and it gains the second
   way out it claims (S0).
8. **The accident that fires is a pick weighted by this tick's spend**, with **`rate:` separate
   from `severity:`** and its own unconditional draw (P4).

9. **Brattice leakage is a property of the fitted tier** — canvas, creosoted canvas, timber,
   concrete. This pass builds leakage only; collapse and fire are deferred (S0, §6).
10. **The hoist does not know whether anybody is winding it.** Unattended removes the operator's
    forces and nothing else; the levers hold where they were left (P2).
11. **Two certificated posts are accepted for this pass only.** Coal on the hoist is the first item
    of the next one (P2, §6).

Nothing is open.

---

## 6. Deferred: units 3 and 4

**Designed in later drafts, after the unit before has landed.** Each row says what this draft
leaves for it, so the seam is findable.

### Unit 3 — non-winding hazards on P1–P4

| # | Hazard | Needs | Left for it by units 1–2 |
|---|---|---|---|
| — | **Coal on the hoist, first.** The coal winder's rate abstraction is hard to justify beside a physical hoist: a loaded deck becomes payload, overload counts tubs, an empty-of-men overwind becomes possible, and the two certificated posts merge | P2 | the hoist, the controller, both `winding` posts |
| 9 | Overspeed delivered downstream: **fan rotor burst**, pump surge and water hammer, lamps over-run | P1 | P1's surge; `Flywheel`'s hoop stress as the model |
| 10 | **The restart slug** — restarting a stopped fan drives accumulated firedamp past an ignition source | P3 | P3 seam at the fan drift |
| 11 | **The Cornish set**: pump rods and their bob, Hartley's beam falling into the shaft, the rising main bursting | P1, W4's shaft node, W7's bob, S0's brattice | the bob, the shaft node, the single shaft, load rejection |
| 12 | **Fire on the intake**: hot bearings, slipping drives, the headgear burning (Creswell, Sunshine, Mauricewood, Margaret Mine); fan reversal | P3 | sheave temperature (W3); P3 seam |
| 13 | **Gob fire** — spontaneous heating in the goaf, driven by fan-pressure leakage | nothing new | `OldWorkings` |
| 14 | **Doors, trappers, stoppings** — the short-circuited circuit; explosions blowing them out | nothing new | slips, misreads, `failure_damages` |
| 15 | **Ignition beyond the candle** — gauze in a fast draught, frictional sparks from the cutter | P3 | P3 seam |
| 16 | **Sudden outburst** — the `Inrush` pattern on the blower | nothing new | — |
| 17 | **Goaf falls** — the gas flush and the windblast | nothing new | — |
| 18 | **Inundation that kills** — drowning, the air pocket, mud; survey plans as an imperfect instrument | nothing new | W4's blocked ladderway |

### Unit 4 — new production tiers

| # | Hazard | The tier it arrives with |
|---|---|---|
| 19 | **Runaway tubs and the haulage rope** — rope breaks on inclines, runaways, catch points | rope haulage, the upgrade over hand putting |
| 20 | **Shotfiring** — blown-out shots, misfires drilled into, premature fire | powder, between picks and cutters |

### Last — brattices and stoppings as hazards

Deliberately at the end, because every tier's character is an interaction with something built
earlier, and the interactions are the interesting part:

| Tier | When it comes down | When there is a fire |
|---|---|---|
| Canvas | little or no obstruction | burns, briefly |
| Creosoted canvas | little or no obstruction | **a fire load** — the price of leaking less |
| Timber | a real obstruction | burns, and stays burning |
| Concrete | **a devastating obstruction** | does not burn |

What each needs to be meaningful: the **shaft node's obstructions** (W4), **roof and heading
collapses** bringing a stopping down with them (the roof model, unit 3's goaf falls), and **fire on
the intake** (unit 3, item 12) carrying through a brattice that is itself fuel. The same tiers then
apply to roadway stoppings when doors and stoppings land (unit 3, item 14). This pass leaves them
the brattice slot, its tiers and the leak path.

---

## 7. Documentation owed when units 1–2 land

Per the root `CLAUDE.md` table:

- `reference/tick.md`, `lib/reactor_sim/CLAUDE.md` — phase 0 reading hoist state for the
  engineman's controller; the new `peril:` draw in `draw_fates`; phase 6d's weighted pick; phase 6
  applying last tick's mishaps; the ignition map beside the ambient-tag map
- `peril.rb`'s own header — the cause is a weighted pick, not the largest bite; `rate:` beside
  `severity:`; mishaps
- `lib/reactor_sim/CLAUDE.md` events section, `event_spec` — `:minion_mishap`
- `reference/settlement.md`, `graph/CLAUDE.md` — the rope end's two roles in the drive settle
- `reference/physics.md`, `physics/CLAUDE.md` — potential energy on the books; the cross-coupling
  stability bound
- `reference/nodes.md`, `nodes/CLAUDE.md`, `concerns/CLAUDE.md` — rope end, hoist, brake, rope,
  bob, shaft; `ignition`; `riders:` in `endangers:`
- `reference/diagnostics.md`, `diagnostics/CLAUDE.md` — depth indicator, ready signal, rope and
  brake inspection
- `guides/build-an-operation.md`, `operations/CLAUDE.md` — coupling `ratio:`, the rope-drive part,
  the refused unsold rope end; internal levers no command may set; `single_shaft` as the mine's
  default chassis; mishap perils and `rate:`
- `design_sketches/blueprints.md` — `two_shaft`, the brattice tiers and the spare rope as unlocks
- `reference/invariants.md` — **if** the coupling's lag changes what order-independence promises
  across operations. It should not; say so explicitly either way
- `spec/CLAUDE.md` — a row per new spec file
- `current_progress.md` — tick off units 1–2; the cross-coupling stability trap if it bites

---

## Appendix — the research, condensed

The twenty modalities as researched, with the precedent behind each. Numbering is the research
list's and is used throughout.

| # | Modality | Unit | Mechanism, in one line | Precedent |
|---|---|---|---|---|
| 1 | Overwind / underwind | 2 (W1) | Late stop drives the cage into the headframe; rope parts, cage falls back | King's detaching hook, 1867 |
| 2 | Brake failure | 2 (W2) | Spring-brake rod parts by fatigue; emergency stop cuts dynamic braking too | Markham, 1973 — 18 dead |
| 3 | Rope failure | 2 (W3) | Bending fatigue, hidden corrosion, kinks, a rope dragging over a seized sheave | Aldwarke Main, 1904 |
| 4 | Hang-up, slack, obstructions | 2 (W4) | Jammed cage, slack piles up, snatch ≥ 2× load when it frees | Milfraen, 1902 |
| 5 | Overload, stall, roll-back | 2 (W5) | Overhauling load drives the drum backwards when supply fails | — |
| 6 | Signalling | 2 (W6) | False "ready", winding on boarding men; bell sparks igniting gas | Senghenydd, 1913 — 439 dead |
| 7 | Man engine | 2 (W7) | Missteps at reversal; the beam strap parts and the rod falls | Levant, 1919 — 31 dead |
| 8 | Load rejection upstream | 1 (P1) + W8 | A shed load lets the engine run away; flywheel bursts | Loganlea, 1925; Malago Vale |
| 9 | Overspeed downstream | 3 | Surge overspeeds fans, cages, pumps | — |
| 10 | Brownout and restart | 2 (stranding) / 3 (slug) | Stopped cage; restarting the fan drives gas over an igniter | — |
| 11 | Cornish set, Hartley | 3 | Pump rods break; the beam falls into the only shaft | Hartley, 1862 — 204 dead |
| 12 | Fire on the intake | 3 | Friction fire on the intake; the fan carries the smoke through the mine | Creswell, 1950; Sunshine, 1972; Mauricewood, 1889 |
| 13 | Gob fire | 3 | Spontaneous heating in the goaf; "fire stink"; sealing the district | 1912 Departmental Committee |
| 14 | Doors and stoppings | 3 | An open trap door short-circuits the air; gas builds | Thornley, 1841; Burdon Main, 1835 |
| 15 | Ignition sources | 3 | Flame through gauze in a fast draught; frictional sparks | Seaham, 1880 |
| 16 | Outburst | 3 | Stressed, gassy coal ejected with a flood of gas | Agrappe, 1879 — 121 dead |
| 17 | Goaf fall / windblast | 3 | A collapsing void flushes gas or compresses air into a blast | Northparkes, 1999 |
| 18 | Inundation | 3 | Old workings broken into; trapped air pockets; liquid peat | Tynewydd, 1877; Lofthouse, 1973; Knockshinnoch, 1950 |
| 19 | Runaway tubs | 4 | Haulage rope breaks on an incline; tubs run back | Windlestone, 1908; Denaby, 1942 |
| 20 | Shotfiring | 4 | Blown-out shots; drilling into a misfire | US Bureau of Mines misfire study |

Sources: Wikipedia (Markham, Hartley, Levant, Senghenydd, Knockshinnoch, Lofthouse, Mauricewood,
windblast); Northern Mine Research Society accident records (Milfraen, Thornley, Burdon Main,
Creswell, Kinneddar, Margaret Mine, Seaham, Loganlea); Museum Wales (Tynewydd); MSHA (Sunshine);
Annales des Mines de Belgique (Agrappe); Grace's Guide (Malago Vale, Crescent Mill); Nature 1936
on rope corrosion fatigue; CDC/NIOSH *A Study of Misfires in Mining*.
