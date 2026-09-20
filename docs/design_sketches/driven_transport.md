# Driven transport: what pays for a head

> **Status: draft for review.** Nothing here is built. The measurements in §1 are real, taken on
> the reference high-pressure engine with the reference crew.

The sim can charge a transport in **mass** — the injector is exactly that, live steam condensing
into the feedwater, and it is what makes the feed lever a decision rather than a slider. There is
no equivalent for **torque** or for **crew time**. `Conduit#head_pa` is a pressure source with a
lever on it and nobody paying the bill.

That is a rough edge on the steam engine. It is the core loop of a mine, where the two problems
that defined the industry — drainage and ventilation — are both *shaft work buys flow*.

---

## 1. The gap, measured

### 1.1 A pressure source with no owner

```ruby
# conduit.rb:117
# A fan or a pump: pressure this conduit supplies of its own, independent of temperature.
# On a lever if it has one, so forced draught is something an operator turns up.
def head_pa(ctx)
  fan = if @head_pa.zero?       then 0.0
        elsif @head_control_id  then @head_pa * (ctx.controls.fetch(@head_control_id, 0.0) / 100.0).clamp(0.0, 1.0)
        else @head_pa
        end
  fan + blast_pa(ctx)
end
```

Nothing reads a shaft, draws a fuel, or consults a minion. The engine already knows
(`definition.rb:261`):

> **TODO: the blower is free and should not be.** Intended cost is crew time first, a consumable
> second. **Assume a black start** — a player may be the only one generating power, so nothing may
> depend on an electrical supply.

### 1.2 How big is the free lunch

Pressure–volume work delivered to the gas, `P = ΔP · Q`, over a reference cold start and run:

| phase | flow | head | **power given away** |
|---|---|---|---|
| raising steam (blower 100) | 3.19 kg/s | 600 Pa | **1.59 kW** |
| running (blower 20, blast pipe working) | 3.49 kg/s | 120 Pa | **0.35 kW** |
| peak | — | — | **7.82 kW** |

Against a 450 kW engine those are rounding errors, and it would be easy to file this as
bookkeeping. **It is not, and the reason is *when* it is free.** During raising steam the engine
produces exactly zero. That 1.59 kW of free draught is the entire reason a cold machine can be
brought to life. Pricing it is a difficulty change aimed squarely at the most interesting part of
the procedure.

### 1.3 The blower is not sized as a person

3.19 kg/s of air at 1.204 kg/m³ is **2.65 m³/s**, delivered at 1.59 kW.

A person sustains 75–100 W of useful output indefinitely and perhaps 500 W in short bursts.
**The current blower is ten to twenty times a human**, which settles what it is: a machine. §3.3
makes that literal by giving it an engine, and introduces a genuinely human alternative beside it.

### 1.4 Nothing connects absorption to delivery

`Nodes::Load` absorbs shaft power and produces nothing. `Conduit#head_pa` produces flow and absorbs
nothing. They are the two halves of a pump and there is no way to wire them together.

---

## 2. Three things can pay for a head, and only one is missing

| supplier | worked example | machinery today |
|---|---|---|
| **crew effort** | a hand bellows | **already complete** — see §2.1 |
| **a consumable** | an oil-fired donkey blower | one small node, existing combustion |
| **shaft power** | a mine sump pump, a ventilation fan | **genuinely missing** |

### 2.1 Effort already works, and costs nothing to adopt

`Tick#control_values` already routes an effort control through the crew:

```ruby
def control_values(controls)
  controls.to_h do |id, s|
    control = control_points.fetch(id)
    [ id, control.effort? ? worked(control, s) : control.value(s) ]
  end.freeze
end

def worked(control, control_state)
  minion_id = station_index[control.id]
  return 0.0 if minion_id.nil?
  ...
  control.value(control_state) * minion.capability(...)
end
```

`head_pa` reads `ctx.controls.fetch(@head_control_id)`, which **is** that worked value. So adding
`effort:` to a blower control makes the head scale with who is pumping, with **no engine change at
all** — and an unmanned station returns `0.0`, so a bellows nobody is working delivers no draught.
That is correct, and free.

### 2.2 A consumable is small

Covered in §3.3. One new node class, reusing `oil_combustion`, which already exists.

### 2.3 Shaft power is the real gap

Covered in §3.2. It is the only item here that touches the tick path.

---

## 3. The model: a head is bought, and the seller is named

One rule:

> **The head a fitting delivers is proportional to the drive actually supplied to it, and
> whoever supplied that drive is charged for it.**

Three adapters differing only in who the supplier is — deliberately the shape `Bearing`'s `duty:`
took, because that abstraction has now survived two duties and a release.

```ruby
# effort: the lever IS the drive, because Tick#control_values already worked it
Conduit.new(id: :bellows, head_pa: 600.0, head_control_id: :blower)

# a consumable: a tiny prime mover with its own fuel, driving the fan through the shaft adapter
Conduit.new(id: :donkey_blower, head_pa: 600.0, driven_by: :donkey)

# shaft power: belted to the line shaft
Conduit.new(id: :sump_pump, head_pa: 0.0, lift_m: 180.0, driven_by: :line_shaft,
            efficiency: 0.55, accepts: [ :liquid ])
```

### 3.1 What the shaft is charged

**The hydraulic power the fitting actually delivered, divided by its efficiency.**

```
P_hydraulic = (head_pa + ρ · g · lift_m) · Q
P_shaft     = P_hydraulic / efficiency
```

`head_pa` is what the device *supplies*; `lift_m` is static head it must *overcome*. They appear
in the same term because they are the same physics — the only difference is whether that ΔP drives
the flow or resists it, which §4.3 settles.

Both collapse to zero when nothing is flowing, which is the behaviour that matters: **a pump
against a shut valve costs the shaft almost nothing**, and a pump that has lost its water costs
nothing and delivers nothing, which is how a real one fails.

### 3.2 The shaft adapter reuses the drag vocabulary wholesale

This is what made the design cheap, and it is a direct dividend of the bearings release.

`Arbiter.drive_drags` gathers drag by **shaft**, from any node that answers to it:

```ruby
nodes.each_with_object(Hash.new(0.0)) do |(id, node), acc|
  next unless node.respond_to?(:drag_conductances)
  ...
  shaft = node.drag_shaft
  ...
end
```

It already works for a **non-rotating declarer naming a shaft it is not** — that is precisely what
a `Bearing` is. A conduit that declares `drag_conductances` and `drag_shaft` is picked up with **no
change to the arbiter, the relaxation solver, or the tick.**

**The conductance, not the torque.** For a centrifugal machine head goes as ω² and so does torque,
so `c = τ/ω` is linear in ω — the same shape as `Load`'s fan curve, which is already proven. It
lands on the diagonal of the backward-Euler drive solve and is therefore unconditionally stable at
any `dt`, which the drag release bought and which an applied torque would hand straight back.

**Where the energy goes is already expressible.** `drag_conductances` returns
`{ destination => conductance }`, and `Tick#book_drive` understands three kinds of destination:

| destination | meaning | the fitting that wants it |
|---|---|---|
| `:work` | leaves the operation usefully, on the ledger | a sump pump lifting water out of the mine |
| `:friction` | leaves the operation as loss | the inefficiency term on any of them |
| a node id | becomes heat in that node's metal | a fan warming what it blows through |

So a mine pump declares `{ work: hydraulic_c, friction: loss_c }` and every existing accounting
path works unmodified. **Nothing new on the ledger for the energy side.**

> The mass side is a different matter: water pumped out of a mine leaves *usefully*, and the
> ledger has `mass_vented` (a relief path) and `mass_spilled` (a leak) and no productive exit at
> all. That is the `mass_delivered` line, staged separately below, and the mine pump is its first
> consumer.

### 3.3 The blower becomes a slot with two parts

Decided in conversation, 2026-09-17. Two blueprints, not two modes — the choice is a fitting a
player buys and lives with, and the upgrade is earned.

| | **Hand Bellows** | **Donkey Blower** |
|---|---|---|
| supplier | a minion at an effort station | its own fuel oil |
| sustainable output | **0.2–0.3 kg/s** | **3.19 kg/s** |
| flat out | **0.75–1.0 kg/s**, at heavy fatigue | — |
| needs a person | **yes, continuously** | no |
| fails by | nobody is on it; nobody left with anything in the tank | running out of oil; refusing to start cold |
| black start | yes | yes |
| unlock | starting blueprint | later |

Both honour the black-start constraint: neither depends on the main engine turning, which is the
whole point of a blower.

**The Donkey Blower is deliberately today's figures, exactly.** 600 Pa and the same rating, so a
player who has bought it gets the machine that every existing balance measurement was taken
against — the cold-start gradient (60/80/60 survives, 80/90/70 bursts the flywheel), the sweeps in
`bearings.md` §6.3, all of it. **The existing balance survives the release**, and the Hand Bellows
is a new, harder starting condition rather than a rebalancing of the old one.

**The bellows is a better station than it first appears.** It competes for the same person as the
shovel, at exactly the moment both matter most — raising steam needs draught *and* fuel, and one
fireman cannot do both. That is a real decision on a cold start, made out of parts that already
exist.

**The donkey engine is a small prime mover**, not a third adapter:

```ruby
Nodes::Motor.new(id: :donkey, label: "Donkey Engine",
                 fuel: :fuel_oil, thermal_efficiency: 0.12,
                 moment_of_inertia: 0.4, control_id: :blower)
```

`Thermal` + `Holds` + `Rotating`, burning its own charge through the existing `oil_combustion`
reaction and putting the shaft power on its own rotor. The fan is then `driven_by: :donkey` and
uses the **shaft adapter** — so there is one new adapter in this document, not three. A separate
oil store feeding it by a path gives "it ran out" for free and audits through the same
conservation spec as everything else. The cheaper alternative is in §4.4.

### 3.4 Working flat out, and why it cannot ship first

The two bellows figures are the same physics at two exertion levels:

| | flow | hydraulic power | what a person is doing |
|---|---|---|---|
| sustainable | 0.25 kg/s | ~125 W | working, indefinitely |
| flat out | 0.75–1.0 kg/s | ~375–500 W | sprinting, and paying for it |

The lever carries this with **no new control**: its upper range is the flat-out range, and fatigue
accrues **superlinearly** in `intent ÷ capability`. That is the rule `minions.md` §9 already
proposes, with an exponent on it. The player's choice is to spend a person to skip a wait, which
is a far sharper decision than a progress bar.

> **The flat-out range must not ship before fatigue does.** Until something advances
> `state[:fatigue]`, working flat out is free — which would make the Hand Bellows a 1 kg/s blower
> with no cost, reintroducing exactly the unpriced power this document exists to remove.
>
> **So the bellows ships at its sustainable figure, and the fatigue release opens the top of the
> lever.** Each release is coherent on its own and neither one ships an unpriced lever.
>
> **Unblocked 2026-09-18** — [`fatigue.md`](fatigue.md) landed, so the bellows may ship with its
> full range from the start. The station declares an `exertion:` and the top of the lever is
> priced by it. Note what the fatigue release measured: the runaway makes time-to-spent **a third**
> of the declared rate's reciprocal, so a bellows figure set from `1/exertion` will be three times
> more punishing than intended.

**A slow start is the intent, not a problem to be tuned away.** At 0.25 kg/s the bellows delivers
about **a twelfth** of the air the engine currently raises steam on, and raising steam by hand
should be slow. It is a balance and progression trade-off, and the player's route out of it is to
buy the Donkey Blower or to find a better person.

**Which is what makes the station interesting as accounts progress.** Effort scales with
`capability`, so an exceptional minion — a hulking ogre on the bellows — should be able to close a
good part of the gap to the donkey engine on their own. The choice then stops being "hand-crank
until you can afford the machine" and becomes a real one between spending a remarkable person and
spending money, which is the better shape for an upgrade.

> **If it is so slow the engine cannot raise steam at all**, the answer is **natural draught**, not
> a bigger bellows. A real engine standing cold has draught before it has a blower, and this one
> models none — `Arbiter.path_head` computes buoyancy only from the *source's* gas temperature, so
> a cold stack pulls nothing. That is a missing piece of physics rather than a number to nudge, and
> §5 reserves it.

---

## 4. Decisions, alternatives and what they cost

### 4.1 Where the shaft drag is declared

**Recommended: on the conduit, naming a shaft — `driven_by:`.**

- **Pros.** Zero arbiter change (§3.2). Exactly mirrors `Bearing#supports` and `Cylinder#drives`,
  both working. One node per fitting. A conduit naming no shaft behaves exactly as today, so
  nothing existing has to change at once.
- **Cons.** A conduit now reads another node's state. Legal — every cross-node read here is lagged
  by a tick — but it is the first transport node to do it.

**Alternative A: a `Nodes::Pump` that is `Rotating` and transport.** More physically literal.
Rejected: transport nodes may not hold material, and making one rotate puts it in the drive network
as a shaft needing its own inertia and a `DriveLink` — two extra concepts for no expressiveness.

**Alternative B: a pump node beside the conduit, feeding it.** Rejected: two nodes per fitting, and
the pump has to be asked what head to apply through a second mechanism identical to the first.

### 4.2 The one-tick lag on the shaft speed

Phase 4a (mass) runs before 4d/4e (drive), so a conduit computing its head must read the shaft's
speed from tick N−1.

**This is fine, and for a different reason than the analogous case in `bearings.md` §6.4.** There
the prime mover's torque is a near-constant source, so splitting it is benign. Here the loop is
genuinely coupled — but it is **negative feedback**: faster shaft → more head → more flow → more
torque → slower shaft. A lag on negative feedback is damped. A lag on *positive* feedback is what
diverges, and this is not one.

**Still the first thing to check if a pump oscillates**, and the signature is the one that caught
operator splitting before: halve `dt` and see whether the amplitude halves.

### 4.3 Keep liquid transport rate-driven

**Recommended: yes.** A pump's lift is charged as torque, not expressed as a pressure gradient.

The injector is already explicitly rate-driven — *"a fixed-geometry nozzle"* — so this keeps one
regime rather than introducing a second. A mine's depth costs shaft power without hydrostatic
pressure having to exist.

- **Pros.** No new transport regime. No interaction with `cap_gas_by_pressure`, which is already
  scheduled for deletion. Depth becomes a torque bill, which is the game.
- **Cons.** A pump cannot be stalled by head the way a real one is — it moves its rated flow or
  nothing. Acceptable: a flooding mine is about whether the shaft can carry the load, not about
  where the pump curve's knee sits.

**Deliberately not built:** hydrostatic pressure as a modelled quantity. `concerns/CLAUDE.md`
already states the position — *"Not modelled: pump head, hydrostatic pressure, flow-induced
pressure drop"* — and `Units::GRAVITY_M_PER_S2` is currently used for gas buoyancy only.

### 4.4 The donkey blower: prime mover or gated head

**Recommended: a prime mover (`Nodes::Motor`), per §3.3.**

- **Pros.** One adapter in the whole design. Fuel, heat and exhaust audit through existing
  machinery. Gives a second, non-steam prime mover the game will want again — a hoist's standby, a
  compressor.
- **Cons.** A new node class. Perhaps 60 lines, but it has to be specced.

**Alternative: a `Vessel` burning oil whose running state gates the conduit's head.**

- **Pros.** No new class; reuses combustion directly.
- **Cons.** Invents a third adapter whose only consumer is this one part, and the gating function
  ("how running is it?") is a fudge with no physical referent. What makes the shaft adapter worth
  building is that it has three consumers; a fuel adapter would have one.

### 4.5 Efficiency: one number

**Recommended: a scalar `efficiency:` per fitting, around 0.55 for a period pump.**

- **Pros.** Honest about what it is, and the difference between a good pump and a bad one becomes a
  fitting rather than a constant.
- **Cons.** A real pump's efficiency varies strongly along its curve. Modelling that needs a duty
  point and a curve shape — which is `Load`'s `curve:`/`rated_omega:` machinery again, worth
  reaching for **only if a sweep shows the flat number makes the choice of pump uninteresting.**

---

## 5. What this must not foreclose

- **Pump curves.** `Load` already has `curve:` and `rated_omega:`; if efficiency needs to vary,
  extend that vocabulary rather than inventing a second.
- **The belt snapping.** `DriveLink#max_torque` is still declared and never read, and a pump that
  suddenly loads a line shaft is one of the better ways to discover it. `bearings.md` §5 reserves
  this — do not spend it here.
- **A pump that can fail.** Nothing here adds `Wearing` to a driven conduit. It must stay addable
  without rework: cavitation, a lost prime, a worn impeller.
- **Hydrostatic pressure.** §4.3 defers rather than designs against it. If it arrives it belongs in
  `Arbiter.path_head` beside the buoyancy term, which is already the symmetric case.
- **Natural draught.** §3.4 raises it as the likely answer if a bellows cannot raise steam. A
  chimney that draws when cold is a real thing this engine does not have.
- **Volumes.** A sump at the bottom of a shaft is a place, and per-level pumping is what makes a
  mine's depth legible. Do not build a mine pump that assumes exactly one sump.

---

## 6. Staging

| | |
|---|---|
| **A** | **Measure first**: can an engine raise steam on 0.25 kg/s of blast at all, and how long does it take? Everything in §3.3's left-hand column depends on the answer. |
| **B** | **`mass_delivered` on the ledger.** Independent, tiny, prerequisite for anything whose output is material. |
| **C** | **The shaft adapter**: `driven_by:`, `lift_m:`, `efficiency:` on `Conduit`, plus `drag_conductances`/`drag_shaft`. No arbiter or solver change. Specced against a synthetic rig before any machine uses it. |
| **D** | **`Nodes::Motor`** and the Donkey Blower part, at today's figures. |
| **E** | **The Hand Bellows** at its sustainable figure, `effort:` on the control, the blower slot becomes two blueprints with prices in `blueprints.yml`. |
| **F** | **The sweep**: cold start with each blower, recorded as a table. |

**Then fatigue**, which is its own release and its own sketch — and which opens the top of the
bellows lever (§3.4). B and C are independent of the blower work and can land first.

---

## 7. As built

Landed 2026-09-19, stages A–E. **F folds into the mine's sweep**, per the ordering decision.

### Stage A answered the gating question, and changed the plan

| blower lever | total air | fire | 500 kPa reached |
|---|---|---|---|
| 100 (600 Pa) | **3.199 kg/s** | 1016 K | t=1600 |
| 20 (120 Pa) | **0.927** | 897 K | t=3800 |
| 10 | 0.630 | 827 K | never |
| 0 | **0.302** | 668 K | never |

**Natural draught already exists** — 0.302 kg/s with no blower at all — so §3.4's fallback
("if a bellows cannot raise steam, add natural draught") was not available: it was already there
and already counted. And a bellows at its *sustainable* 0.25 kg/s lands around lever 5–10, which
keeps a fire in and never raises steam.

**Flat out it can, and only because fatigue landed first.** 0.93 kg/s is lever 20, which raises
steam at t=3800 against the donkey's t=1600 — 2.4× the wait, payable in exhaustion. So the
sketch's own staging note is obsolete in the good direction: the bellows ships **whole** rather
than at its sustainable figure. `head_pa: 120.0` puts full lever at that flow, and flow is linear
in head because the arbiter settles on conductance × ΔP (600 Pa → 2.897 kg/s of forced air,
120 Pa → 0.625, a ratio of 4.64 against 5).

### Three things the sketch did not anticipate

> **A conduit cannot know its own throughput.** It is resolved *through*, so it is never a
> flow's endpoint and its `Grant` is empty — and §3.1's `ΔP × Q` needs actual flow.
> `Tick#advect` now records `carried_kg` **and `carried_m3`** per wall: volume as well as mass,
> because `carry_through` strips `:parcels` from the wall state and neither is recoverable from
> the other afterwards. Written to every conduit including untouched ones, or a stale figure
> keeps charging a shaft for a flow that has stopped.

> **Torque is not `power / ω`.** The first `Nodes::Motor` derived it that way and it is wrong at
> rest: with any floor on ω, a full charge catching on tick one asks for **kilonewton-metres**.
> Measured — the rotor hit 262 rad/s on 0.4 kg·m², then drained its own block from 700 K to
> 334 K, paying 1.88 MJ of friction out of a 154 kJ burn. Nothing was created (`transmit_torque`
> bounds work against the charge); it was a heat engine eating itself. Torque comes from the
> **ignited fraction** instead, so an engine makes its rated torque when firing and none when
> not.

> **A combustion chamber has to breathe by DISPLACEMENT.** Left to exchange gas by thermal
> cycling alone the motor ran air-starved at **380 W** against the ~3 kW a fan wants, and no
> chamber volume fixes it — with no pressure difference there is no flow to bring fresh air in.
> The firebox escapes this because a chimney pulls for it. A reciprocating engine pumps its own
> charge, which `Cylinder#displacement_kg` already models, so the motor scavenges proportional
> to speed. With that it burns 58.8 kW and conservation is **exact**. It also gives the right
> behaviour for free: it must be turning before it will make power.

### As shipped

| | Hand Bellows | Donkey Blower |
|---|---|---|
| `head_pa` | **120.0** | **600.0** — today's figures exactly |
| paid for in | a person on the handles, continuously | fuel oil from its own 60 kg tank |
| unlock | starting blueprint | gated on `first_full_head_of_steam` |

`Nodes::Motor` is `Thermal` + `Holds` + `Pressurized` + `Rotating` + `Wearing`, burning through
the ordinary `oil_combustion` machinery so it audits with no special case. It carries its own
rotor, so `drives` returns its own id — which `Tick#transmit_torque` had to learn, because
`drives => spun` and `id => charged` collided on one key and silently dropped the spin.

**Efficiency is emergent, not declared.** The reaction decides how fast fuel goes and
`rated_torque_nm` decides how much work comes out; the ratio between them is what a thermal
efficiency *is*, and declaring both would let them disagree.

> **Its own tank, and that is the rake it sidesteps.** `oil_combustion` is already in the
> firebox's reaction list, so a fuel-oil line routed to the fire would let a player burn the
> donkey's fuel in the main grate. A separate tank makes that unexpressible rather than merely
> discouraged.

---

## 8. Verification

- **Conservation, before the physics.** A driven conduit moves energy from a shaft into flow and
  loss; exactly the class of change `conservation_spec` exists to catch. `loop_rig` is the right
  place, because it is where the drag machinery was proven.
- **A pump against a shut valve costs nothing.** The assertion that says §3.1 is right.
- **Halving `dt` does not halve an oscillation**, per §4.2 — the standing test for a splitting
  error, and the one that caught the last one.
- **An unmanned bellows delivers zero draught**, and the engine cannot raise steam. Free from the
  effort machinery; worth asserting anyway because it is what a player will feel.
- **The donkey runs out of oil** and the draught stops, with the oil on the ledger throughout.
- **The Donkey Blower reproduces today's cold start**, tick for tick where the rest of the loadout
  is unchanged. This is the assertion that says §3.3's balance claim is true rather than hoped.
- **Determinism** — no new entropy anywhere; a pump is a pure function of shaft speed and flow.
- **The shaft actually slows** when a pump is engaged under load. The trap is the one
  `bearings.md` §3.5 documents for seizure: a declared drag that never reaches `drive_drags`
  because of a `respond_to?` miss fails *silently and in the safe direction*, which is the worst
  kind.
- Full suite in the background at each stage boundary — **example count, not just failures.**
  It is 635 today.
