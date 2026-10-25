# The steam shovel — unit 4b

> Input to a decision, not a description of the system. Unit 4b of the open-pit sequence, after
> 4a's engine ([`mobile-engines.md`](mobile-engines.md)). **This draft covers the shovel only**:
> the locomotive and its trains are 4c, the pit itself unit 5; what each needs from here is in §9.

## 1. What is decided, and what 4a gives

- **A shovel is a mobile engine digging** — 4a's vertical-boiler engine, 61 kW at work, its own
  coal and water, worked by a fireman and a driver.
- **Few levers.** The player's lever on a shovel is how hard it is asked to dig; the crew does the
  rest. Gauges are the crew's.
- **Its status in words**, deferred from 4a to here: the pit's panel is the first to show it.
- **Stripping is a second gang**, the player's own — so a pit has at least two shovels, one on the
  overburden and one on the ore, and the slots must say which is which (§7).

The period machine is the railroad shovel: a boom, a dipper on a hoisting chain, a crowd to set the
cut, swinging a half-circle to dump into a car on the track beside it. The crew is a **runner**
(hoist, swing, travel), a **craneman** (the depth of cut, tripping the dipper over the car), a
**fireman**, and **4–7 pitmen** clearing spill and shifting the track a rail-length at a time as it
**moves up**, 3–10 minutes with no digging while it does (Hermann 1894, Marsh 1920). A 2¼-yd³ dipper
filled 1,500–2,000 t of ore a day in the Lake Superior pits; 4a's 61 kW engine is a smaller shovel's,
a yard or so, and about **30 kg/s at work**.

## 2. Digging, as a driven conduit

**Proposed: the dipper is a conduit from the bench to the car, driven by the engine's shaft.** The
whole of what it needs already exists on `Nodes::Conduit`:

- `driven_by:` the engine's flywheel and `displacement: true` — it shifts in proportion to the
  shaft's speed and nothing at rest, so a shovel whose engine has stopped digs nothing;
- `worked: true` with the **craneman's** effort post on its lever — a sound craneman takes a full
  dipper, a poor one a scrape;
- the shaft is **charged for what it lifts** (`lift_m:`, the bank's height) — and for what it
  **cuts**, which is most of the power and nothing the conduit can say yet.

**One new figure on `Conduit`: `work_j_per_kg:`** — energy a driven fitting spends on each
kilogram it moves beyond any lift: cutting a bank, crushing ore. Booked with the lift, so a shovel
in hard ground pulls its engine down where one in sand runs light. Generic; **its second caller is
the crusher in unit 5**. Calibrated so the shovel at work loads 4a's engine to about the 60 kW it
makes — a real dipper's work is mostly the cut, about 1.5–2 kJ/kg, against a few hundred joules of
lift.

**Alternative: a dipper cycle as a node** — dig, swing, dump as states on a drum and a jib, a
full dipper a discrete 1.4 t. Truer to watch and the right home for "struck by the swing"; also a
new node with its own failure story and a cycle the engine must be timed to. **Not proposed for
4b**: a rate is what the trains and the pit need from it, and a cycle can replace the conduit later
without anything around it changing.

## 3. Moving up, as the pitmen keeping the face in reach

A shovel digs only what its boom reaches, then must move up. **Proposed: what is in reach is a
small holder between the bench and the dipper**, and the pitmen are an effort post on the conduit
that fills it — shifting the track, blocking the jacks, bringing the face to the dipper:

```
bench ─(pitmen: moving up)─➤ reach ─(dipper: driven by the engine, worked by the craneman)─➤ car
```

Enough pitmen and the reach never empties; too few and it runs down and the shovel stands, waiting
on them. **A continuous stand-in for a periodic stop**, conserved, and a crew decision the player
sees as a shovel that keeps stopping. The reach is a few tonnes — a set-up's worth.

**Alternative: discrete set-ups** — dig a set-up's worth, stop, move up for a time the pitmen set.
Closer to the period and harder to tune; the holder gives the same average for nothing.

## 4. The car

**The dipper dumps into a car standing on the track** — a holder with a capacity, and full is full:
the dipper has nowhere to put the next and the shovel waits (sink room, nothing new). **Who takes
the car away is 4c's.** In 4b the rig's car empties on a lever, standing in for the train.

## 5. Coal and water

- **Water by hose.** A standpipe — in the pit, fed from the reservoir by the line shaft's pumps; on
  the rig a big holder — joined to the engine's tank by a hose, a conduit with a valve. **The driver
  works it**, as a third internal lever: he calls for water when the tank is low and stops at full.
  At work the small tank lasts about ninety minutes, so it matters over a shift and not a minute.
- **Coal is not brought up in 4b.** The small bunker lasts nearly three hours at work; a match is
  30–60 minutes. Coaling becomes a job when the pit's logistics are unit 5's.

## 6. Who works it, and what can go wrong

| Post | Kind | Does |
|---|---|---|
| Driver | governor (4a), the player's lever | the throttle to how hard he is asked to dig, the feed, **the hose** |
| Fireman | effort (4a) | stokes at the blueprint's rate |
| Craneman | effort | the dipper's lever: how full a dipper comes up |
| Pitmen | effort, a gang of 4–7 | moving up: the reach |

**Hazards**, each an existing mechanism:

- **Struck by the dipper or the swing** — a peril of the pitmen's and the craneman's posts, spent by
  the dipper's activity, impact, everyday severity. **`opportunity: true`**: a pitman can be pushed
  into it.
- **The boiler** — 4a's, reaching the place the shovel stands in.
- **The hoisting chain** — period chains broke often (Hermann). **Proposed: deferred**, with the boom
  failure: both want the dipper as a node (§2's alternative) to be worth their keep.

## 7. Slots in a pit with several engines

A pit has a stripping shovel and an ore shovel at least, and later locomotives.

- **(a) Fittings per engine — proposed.** Every shovel has its own slots (`stripping_shovel_safety_valve`,
  `ore_shovel_safety_valve`), and the outfitting screen groups them by engine. Each machine can be
  fitted differently — a better-kept ore shovel, a cheap stripper — and it is what 4a's slots already
  are.
- **(b) Fittings per class of engine.** One set of fittings for every shovel. Fewer choices on the
  screen; but two shovels can never differ, and a sidegrade fitted to one is fitted to all.

**Which shovels a pit has is its chassis's**: two, named for their work, `stripping_shovel` and
`ore_shovel`. A third is a later chassis or a part, not a count.

## 8. Status in words

`winding_signals`' pattern: a phrase per engine, written onto its boiler's state by the tick after
it settles and shown by a prose display. The first that holds of:

- **Standing** — nobody driving, or the fire out.
- **Out of water** / **short of water** — the tank empty, the glass low.
- **Short of steam** — the drum well under its working pressure.
- **Priming** — water coming over.
- **Blowing off** — on the safety valve.
- **Moving up** — the reach empty, the pitmen at it.
- **Waiting on cars** — the car full.
- **Digging** / **standing by** — at work, or asked for nothing.

Read off the true state, as the cage's board is: it is what the crew would shout, and somebody in
the cab knows.

## 9. Deferred

- **4c, the locomotive and trains**: the car taken away, positions, the coaling and water point, the
  moving node.
- **Unit 5, the pit**: the bench as geometry (its height is the dipper's `lift_m`), slides that bury
  a shovel, ground that varies per match (frozen, hardpan — `work_j_per_kg` by bench), blasting it,
  ore and overburden as different benches, the standpipe's pumps, coaling.
- **A dipper cycle as a node**, with the hoisting chain and the boom as its failures.

## 10. Content

**`overburden`** — a new solid resource, the clay, gravel and soft rock over the ore, at about 1.8
t/m³ broken: the thing a stripping shovel moves and the first thing this unit can dig. The ores are
unit 5's.

## 11. Specs (relational, on 4a's rig with a bench and a car)

- The shovel digs from the bench into the car while the engine turns and not at all once it stops.
- Harder ground (a larger `work_j_per_kg`) pulls the engine down and digs less.
- A poor craneman fills less than a sound one; no pitmen and the reach runs out and digging stops.
- A full car stops the dipper; emptied, it digs again.
- The driver opens the hose with the tank low and shuts it full.
- The board says what holds, in order: a shovel with an empty reach reads moving up, one with a full
  car waiting on cars.
- The pitmen can be struck, and pushed.
- Conservation through digging, and a snapshot replays.

## 12. Questions

1. **Digging as a driven conduit** (§2), with `work_j_per_kg:` on `Conduit` — or the dipper cycle
   now?
2. **Moving up as the pitmen keeping a reach** (§3) — or discrete set-ups?
3. **Fittings per engine** (§7a) — or per class?
4. **The hose is the driver's** (§5) — or a post of its own (a water boy)?
5. **The chain and the boom deferred** with the dipper cycle (§6)?

## 13. Review decisions

1. **The dipper cycle now**, as a node, because the hoisting chain and the dipper are core hazards and
   want to be in early — so the chain and the boom come with it (question 5 answered by 1). §2's
   conduit is replaced by §14.
2. **The reach stays** (§3).
3. **Fittings per engine** (§7a).
4. **The hose is the driver's** (§5); a post of its own later if one is needed.

## 14. The dipper cycle (for review)

**`MobileEngine::Dipper`, a holder of its own** — machine-specific, so under
`operations/mobile_engine/`, not `nodes/`. It holds a dipperful and goes round four phases, a
state machine written in `apply` and read from the last tick like every node:

| Phase | Ends when | Material | What the engine pays |
|---|---|---|---|
| **Digging** | the dipper is full, or the reach is empty | draws from the reach | the cut and the lift, per kilogram |
| **Swinging** | `SWING_S` at full speed, longer as she slows | holds | the swing, a little |
| **Dumping** | the dipper is empty — only while the car has room | pushes into the car | nothing |
| **Returning** | `SWING_S` again | empty | the swing |

- **It digs as fast as the shaft and the craneman allow**: the fill rate is the dipper's rating by
  the shaft's speed against its rated speed and by the craneman's lever (an effort post, as the
  conduit would have had). **Hard ground slows the engine** because the cut is charged off the
  shaft as a drag (`work_j_per_kg`, on the dipper rather than `Conduit`), so a shovel in hardpan
  digs slower as well as costing more — nothing decides that but the engine.
- **The swings are time, scaled by speed**, so a struggling engine is a slow shovel all round.
- **A full car holds it at dumping** — waiting on cars; an empty reach holds it at digging — moving up.
- At 4a's 61 kW a yard dipper (0.76 m³, about 1.4 t of overburden) comes round in about 45 seconds —
  some 30 kg/s, the period's figure for its size. Sweep, not this table.

**The hoisting chain** is the dipper's, and wears the way a winding rope does — by load and by
cycle — and **snatches** when the dipper hits ground harder than it was digging. Two tiers:

- **Iron chain**, the bottom: weaker, and it wears visibly — the period's choice because it gave
  warning.
- **Steel chain**: stronger, and it wears faster under the snatch and parts sooner without warning
  (Hermann: "rapid wear and frequent breakages").

**Parted, the dipper falls**: a crush hazard to whoever is under it — the pitmen and the craneman,
by the shovel's place — and the shovel digs nothing until the pitmen **renew the chain from a spare**,
a few minutes' work at their post, as the hauling hands splice a rope. The bottom tier carries one
spare.

**The boom** takes the crowd and the cut. It fatigues when the dipper is forced into ground past
what it was built for and **comes down** when it is spent: a wreck, everybody at the shovel in its
weight, and the shovel out for the match. Stronger booms are a tier.

**Struck by the swing**: a peril of the pitmen's and the craneman's posts spent only while the dipper
swings, so a shovel that stands is safe to work round — `opportunity: true`.

**What the board adds**: chain parted, renewing the chain, boom down.

**Questions:**

1. **Repair from a spare chain, by the pitmen** — or a chain renewed is the match's end for that
   shovel at the bottom tier?
2. **A craneman slipping trips the door off the car**, spilling the dipperful onto the track for the
   pitmen to clear — in now, or later?
3. **The boom's fatigue from forcing the cut** — enough, or should a slide (unit 5) also be able to
   bring it down?

## 15. Settled while building

- **`work_j_per_kg` is the dipper's**, not `Conduit`'s: the dipper replaced the conduit (§13), so the
  cut is charged where it is made. The crusher (unit 5) can carry its own.
- **The dipper declares both ports every tick**, a zero where it is not taking or giving. Declaring
  only the open one let the path drive the other, and the bench poured through the dipper into the
  car at 38 kg/s while it sat digging forever.
- **The engine wheel is heavier** (1.2 t at 0.7 m, about 290 kg·m²): on the 4a wheel the engine raced
  to 66 rad/s on every swing, the work vanishing as the dipper left the cut. The drum and the gearing
  turn with a shovel's engine, so the weight is real.
- **The driver keeps her from racing** — past her governed 37 rad/s he eases the throttle, and shuts
  it a fifth over — and **works the hose**, calling for water under half a tank and stopping at full.
- **The engine fragment no longer belts its own wheel to a load**: the stationary engine's flywheel
  brought its belt with it (`belted:`), so the 4a rig ran its engine belted twice. The host links
  what a mobile engine drives. Re-observed: **81 kW at 34 rad/s** (§11 of `mobile-engines.md`).
- **First figures at work**: a round in about 58 seconds — some 30 s digging, 12 swinging each way —
  so about 23 kg/s of overburden; the cut tensions the chain to about 150 kN; five pitmen at 8 kg/s
  each outpace it and the reach fills to its cap. **The iron chain wears to worn in about forty
  minutes' digging and parts on a snatch near the hour**, about once a match; the steel one sooner
  and without a word. The timber boom does not tire in ordinary ground: hard ground (unit 5) is what
  will. All for the sweep.
- **The board is the dipper's own** (`signal`, written in its `apply` from the engine's last tick and
  its own), read by `Sources::Field` through a prose display (`MobileEngine.board`) — the cage's
  pattern, with no change to `Tick`. Priming is not on it yet.
- **The rig's car is emptied by a lever** into a `Delivery`, standing in for 4c's train.

**Decided:** a parted chain is **re-spliced** by the pitmen; a craneman tripping the door off the car
is **later**; and **a slide brings the boom down too** — a common cause. The slide is unit 5's, and
reaches the boom through `damages:` as any failure reaches the parts beside it, so 4b leaves no seam
for it beyond the boom being a part that can be damaged.
