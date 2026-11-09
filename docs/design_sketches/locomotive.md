# The locomotive and its train — unit 4c

> Input to a decision, not a description of the system. Unit 4c of the open-pit sequence, after
> 4a's engine ([`mobile-engines.md`](mobile-engines.md)) and 4b's shovel
> ([`steam-shovel.md`](steam-shovel.md)). **This draft covers one train serving one shovel**: the
> pit's track layout, a second train and the pit's logistics are unit 5's; §12 lists what each needs
> from here.

## 1. What is decided, and what 4a and 4b give

- **A locomotive is a mobile engine on wheels** — 4a's engine, its own coal and water, a fireman
  and a driver; few levers, a board in words, fittings per engine.
- **Its job is to take the shovel's car away.** 4b's rig empties the car on a lever; 4c replaces
  that lever with a train that comes, is loaded, runs to the dump, is tipped and comes back.
- **A node whose place moves** — the footplate is wherever the train is, and a boiler bursting
  beside the shovel has to reach the pitmen.

**The period**: in a stripping pit, a **dinkey** of 6–12 t on 24–36-in track hauled a few **side-dump
cars** of 1–4 yd³; ore went out behind standard locomotives. Pit grades were held to **2% or less**
(5–7% only on short runs). **Two locomotives per shovel**, each making 7–8 round trips in a 9-hour
shift — an hour a round: 18 minutes loading, 15 moving, 6 switching, 5 dumping, 4 waiting and 6 on
shovel delays (Marsh 1920). The train crew was an engineer, a fireman and a brakeman; the dump had a
foreman and one or two men a shift. See [`open-pit-iron-research.md`](open-pit-iron-research.md) §2.7.

**4a's engine is a dinkey's.** About 81 kW is 108 hp, a 10-t contractor's engine; a 30-t train
climbing 2% at 3.5 m/s wants about 25 kW, so she has power in hand and is governed, not strained.
Vertical-boilered locomotives were built for contractors' lines, so **the engine slot takes the
same `vertical_engine` part**; a saddle-tank engine with a locomotive boiler is a later upgrade.

## 2. The train, as a node on a track

**Proposed: `MobileEngine::Train`, the hoist laid flat.** `Nodes::Hoist` already has every piece in
the shape a train needs:

| The hoist's | The train's |
|---|---|
| the drum's rotation, `Rotating` | the wheels' rotation; rim speed is the train's speed |
| `position_m` integrated from its speed | `position_m` along the track |
| gravity on the cage's cargo as `drive_torque`, **booked as it is done**, nothing storing potential energy | gravity on the train's mass along the grade where it stands, booked the same way |
| `deck:`, a holder in the cage whose contents are load | `cars:`, a holder riding the train whose contents are load |
| the ends of the shaft are failures, by speed and position | the ends of the track, and overspeed |
| `stopped_at?` a mark, for a landing | `standing_at?` a mark, for loading and tipping |

**The track is the host's**, handed to the train as configuration: a length, sections each with a
grade and the place it runs through (`pit`, `haul road`, `dump`), and marks (`loading`, `dump`). On
the rig it is fixed; in the pit (unit 5) it is the pit's geometry. A sunk pit is the hard case and the
default: the loaded train climbs out, the empty one runs down towards the shovel.

**Rolling resistance is friction**, viscous, set to about 0.3% of the laden weight at running
speed. At rest it is nothing, so a train standing on 2% with the brake off rolls — as it should,
because 2% is several times any rolling resistance.

**Its inertia is fixed**, at the tare and half a load. `Rotating` takes a configured moment of
inertia, and the load comes and goes. The mass on the grade and the rolling resistance read the true
mass every tick. What the fixed figure gets wrong is **timing, never outcome**: whether a brake holds
a train on a grade is torque against torque, and the inertia is in neither. An empty train
accelerates down the grade at about two-thirds of its true rate, and brakes at the same share, so
both are slow together. **Alternative:** an inertia read from state. True, but `Rotating`, the drive
solve and the kinetic-energy books all assume it is constant, so it is a change to the engine, not
to the train.

**Three failures**, all decided by speed and position, as the hoist's are:

- **Crashed**: reaching the loading end faster than a buffer takes, into the shovel. It endangers
  the pit and the footplate. Through `damages:`, it also hits **the shovel's boom**, the same way a
  slide will (4b, decided).
- **Over the tip**: reaching the dump end too fast. Dump-edge derailments were a period staple. The
  train is gone, and it endangers the dump and the footplate.
- **Derailed**: past a share over the track's rated speed anywhere. It endangers the footplate,
  and through §6 wherever the train is.

Any one of them ends the train's match.

## 3. Driven by its engine, through clutches

**Proposed: the winding engine's arrangement.** The engine's flywheel drives the wheels through two
geared, clutched drive links, forward and reverse. The gear is about 1:4, so the governed 37 rad/s
makes about 3.5 m/s on 0.4 m wheels. A `Nodes::Brake` sits on the wheels, held off by its lever.
**The engine keeps turning and the driver lets the gear in**: the clutch slips the train away from
a stand, its heat booked as friction. All of it exists and is proven on the cage.

**Alternative: direct drive**, the cylinder geared to the wheels with no clutch, which is how a real
geared locomotive worked. It needs a cylinder that starts a laden train from rest on a grade, and no
engine in the game has ever started under load. Starting torque from a stopped crank is unproven
physics. Later, with a locomotive boiler and two cylinders.

**The brake is a tier**: a **hand brake** to start, weak and quick to fade, then a **steam brake**.
Both are `Nodes::Brake` with different figures. Fade, glazing and a parted rod are already its
failures, and each is a runaway waiting to happen.

## 4. Loading and tipping, by where the train stands

**Proposed: `Mine::Landing` becomes `Nodes::Landing`**: a conduit that passes only while its
`carrier:` stands at its mark. The hoist answers `standing_at?` as it answers `cage_stopped_at?`
today, and the train answers it the same way, so the mine comes out **bit-identical**.

- **Loading**: a landing from the shovel's dipper into the cars, open while the train stands at the
  loading mark. With the train away the dipper's dump is refused, and it waits at dumping — 4b's
  "waiting on cars", unchanged. **The shovel needs no change**: the host passes the train's cars as
  its `car:`. Spotting each car under the dipper in turn is abstracted: the cars are one holder.
- **Tipping**: a landing from the cars into the dump, open while the train stands at the dump mark,
  and **worked by the dumpmen**, an effort post of two at the dump. With nobody there the train stands
  full at the dump, and the shovel waits on cars — a crew problem nobody at the shovel can see.

## 5. The driver runs the round

**Proposed: the driver is two governors in one post**, both of which exist:

- **4a's `Driver` keeps the engine**: throttle, feed, governed speed, read through what is fitted.
- **The winding engineman's run moves the train**: the clutches by how far short of the speed he
  wants the train is running, and the brake from a point he believes in, `v²/2a` divided by his
  lateness, plus a margin. A hand out of their depth brakes late, so a crash and a run over the tip
  come from the same place an overwind does. A faded brake stops shorter than he believes; nothing
  says when a crash happens.

**What he does, in order** (the cage's `dispatch`):

1. **At the shovel**: he stands with the brake on until the cars are full.
2. **Loaded**: he runs to the dump.
3. **At the dump**: he stands until they are tipped.
4. **Empty**: he runs back.

**The player's lever is his post's**, as on the shovel: 0 is stand where you are, and anything more
is the round at that share of the track's rated speed. A slip at the post works as a slip does
anywhere. Frozen, he stops working the levers, they hold where he left them, and a train running
down the grade when he froze runs on.

## 6. Where the footplate is: a place that moves

**The problem.** A place owns nodes, statically, and a hazard reaches the places it names. The
engine's boiler has to be in a place, and the fireman and driver must be in one with it. But a burst
at the shovel must hurt the pitmen, and the same burst at the dump must not.

**Proposed: the footplate is a place of its own, carried.**

- `Place.new(id:, carried_by: :train, open: 0.5)`: the footplate and everything on it are in that
  place, and the crew are posted in it.
- The train answers `place_at(state)`: the place its track section runs through.
- **`Tick#hazards_from` shares a hazard between a carried place and the place it stands in**, by
  `open`, both ways, computed from the train's last tick and from the hazards before sharing. That
  keeps it order-independent, and nothing is counted twice.
  - A burst on the footplate reaches the pit at half weight.
  - The boom coming down on the bench reaches a train standing under it.
- **Nothing else in the tick changes**: ambient tags, ignition, the weather and breathing all read
  the footplate as an ordinary place. A brawl on the bench does not reach the footplate, which is
  fair: the train crew are on the engine.

**Alternatives:**

- **(a) The train's nodes change place**: `Layout#place_of_node` reads state. True everywhere at
  once, but ambient tags, ignition, a node's exposure and every rider's place would move every tick.
  That is the widest change for the least gain.
- **(b) A fixed footplate, hazards by station only.** No engine change, but a burst beside the
  shovel would hurt only the train crew, which loses the point.

**Getting on and off is deferred.** The train crew start aboard, as the advance shift left them,
and stay there. When the pit's shift deploys from its quarters (unit 5) they need a way aboard. The
cage's boarded passage is that way already: offered while the carrier stands at a landing.

## 7. What can go wrong

| Hazard | Mechanism | Who |
|---|---|---|
| **Struck by the train** | a peril spent by the train's movement through the loading section (and the dump's); `opportunity: true` | the pitmen; the dumpmen |
| **Caught tipping a car** | a peril of the tipping, by how much is going over | the dumpmen |
| **A runaway into the shovel** | an empty train down the grade with a faded brake or a late hand: crashed (§2) | the pit and the footplate; the boom wrecked |
| **Over the tip** | the same, at the other end | the dump and the footplate |
| **Derailed** | overspeed anywhere | the footplate, shared to where it is |
| **The boiler** | 4a's, on the footplate | the footplate, shared to where it is |

**A pushed pitman is the train's too**: anybody willing to kill will shove somebody in front of the
train, as with any opportunity peril.

## 8. Coal and water

**Neither is brought to the train in 4c.** Flat out, this engine empties the small tank in about
ninety minutes (4a's measurement, 0.27 kg/s; the period's 30 lb per hp-hour says an hour). A train on the round
works perhaps a third of the time — standing to load, standing to tip — so the tank lasts hours, and
the bunker longer. The **coaling stage and the water column** are a holder each and a landing gated
on the train standing beside them, exactly §4's shape. They wait for unit 5, where coal and water
come from somewhere. **The low-water hazard stays live** through the driver's own feed.

## 9. Slots

`MobileEngine.locomotive_slots(loco, place:, track:, serves:)`: 4a's engine slots, plus three:

| Slot | Bottom | Above it |
|---|---|---|
| **Running gear** | a dinkey's frame, wheels and clutched gearing: the `Train` and its drive links | — (direct drive, later) |
| **Brake** | hand brake | steam brake |
| **Cars** | four wooden side-dump cars, 3 yd³ each (about 16 t of overburden) | six steel ones |

`serves:` names the shovel whose dipper the loading landing takes. Fittings are per engine, as the
shovel's are.

## 10. The board, in words

`MobileEngine.board`'s pattern, written by the train in its `apply`. The first that holds:

- **Faults:** crashed, over the tip, derailed, brake gone.
- **Why she isn't working:** standing — fire out, out of water, short of water, short of steam.
- **The round:**
  - **At the shovel:** loading; waiting on the shovel (standing, nothing coming).
  - **Running:** running loaded; running empty.
  - **At the dump:** tipping; at the dump — no dumpmen.
  - **Otherwise:** standing by.

## 11. Figures (for the sweep)

| | |
|---|---|
| Dinkey | 10 t, the vertical engine, geared 1:4 to 0.4 m wheels |
| Cars | four at 1.5 t tare and 2.3 m³, about 4 t of overburden each |
| Track | 600 m from the shovel to the dump, climbing 2% (12 m, a bench) |
| Rated speed | 3.5 m/s, about 8 mph |

**The round, worked through:**
- **Loading** takes about 12 minutes at the shovel's 23 kg/s.
- **The trip** is about 3 minutes each way, plus 2 minutes' tipping.
- **The shovel stands** a little over a third of the time, waiting on cars — **with one train**. A
  second train is the upgrade that pays, and it needs a passing track (unit 5).

## 12. Deferred

- **To unit 5, the pit:**
  - **A second train for the same shovel**: passing track, switches, who waits where. It is the
    period's two-locomotives-per-shovel, and the thing one train makes the player want.
  - **The track as the pit's geometry**: switchbacks; the track moved up behind the shovel by the
    track gang.
  - **Boarding** at a stand, the cage's passage.
  - **The coaling stage and the water column.**
- **Wheel slip and sanding**: adhesion against a wet or icy rail, from the weather already in the
  game. `DriveLink#max_torque` is declared and enforced nowhere, so it is the natural home for it.
- **A brakeman, coupling, and cars breaking away on the grade.**
- **An inertia that follows the load** (§2's alternative).
- **Direct drive and a locomotive boiler** (§3's alternative), as the upgrade engine.

## 13. Specs (relational, on the rig)

The rig grows a track (pit, haul road and dump, a footplate per train) with a shovel and a train
serving it. Each example starts from a constructed point on the round.

- **Movement:** the train climbs loaded under its engine and not with the gear out; standing on the
  grade with the brake off it rolls down, and with the brake on it holds.
- **Loading:** the shovel loads the cars only while the train stands at the loading mark; with the
  train away it waits on cars.
- **Tipping:** the cars are tipped only at the dump and only with the dumpmen there.
- **The round:** the driver leaves full, stops at the dump, comes back empty, and stops at the
  shovel. A hand out of their depth stops past where a sound one does.
- **Failures:** a faded brake on the way down crashes into the shovel and wrecks its boom, where a
  sound one stops. Overspeed derails, and running the tip end fast goes over it.
- **The footplate:** a burst on it reaches the place it stands in, at the shovel and not at the
  dump, and the boom coming down reaches a train standing under it.
- **Perils:** struck by the train only while it moves through the loading section; caught tipping
  only while tipping.
- **The board** says what holds, in order.
- **Regressions:** the mine is bit-identical after the landing moves; mass and energy close
  through a round; a snapshot mid-run replays.

## 14. Questions

1. **The train as the hoist laid flat** (§2), with its inertia fixed at tare and half a load — or an
   inertia that follows the load now?
2. **Clutched gearing off a turning engine** (§3) — or direct drive now, with the starting-torque
   work that needs?
3. **A carried footplate sharing hazards with where it stands** (§6) — or one of the alternatives?
4. **Dumpmen as a post at the dump** (§4) — or the train's own brakeman tipping, riding the train?
5. **Coal and water deferred to unit 5** (§8)?
6. **One train per shovel in 4c** (§12), the second train with the pit's track?

## 15. Review decisions

Every recommendation taken: the hoist laid flat with a fixed inertia at tare and half a load;
clutched gearing off a turning engine; a carried footplate sharing hazards with where it stands;
dumpmen as a post at the dump; coal and water deferred to unit 5; one train per shovel.

## 16. Settled while building

- **The cars are tiered with the running gear, not in a slot of their own.** The train's inertia
  and its tare need the cars' figures at build, and a part cannot read another slot's; `informs:`
  keys are one per assembly, so two locomotives would collide on them. A train is weighed and braked
  as one, so it is one part: a dinkey with four wooden side-dumps, or with six steel ones.
- **Open-air places** (`Place#open_air`): an open pit has many places under one sky and only one
  can own the `Atmosphere`, so a place may breathe it without holding it.
- **The driver eases her in over his lateness as well as braking late by it.** Easing in over the
  last 25 m kept a sound driver below any speed his brake point mattered at, so lateness changed
  nothing until the easing distance shrank with it too.
- **The buffers are a drag**, a lock past either end while the train runs onto them, so a train
  creeping onto one stops; past `BUFFER_M_S` it is a failure instead.
- **The board shows "blowing off" only while she stands by**: a train lifts her valve standing at
  the shovel every few minutes, and it hid the round.
- **A generic governor is told the occupant's lateness**; the engine's `Driver` ignores it.
- **First figures on the rig**: climbing loaded at 3.5 m/s on the clutch at about 8%; the 580 m
  bank in under three minutes; tipped by two dumpmen in a little over two; back down empty held at
  about 3.8 m/s with the brake partly on, the hand brake reaching about 480 K at 1.5×10⁴ J/K — so
  its capacity went to 2.5×10⁴, short of fade on one run down and into it over several hard ones.
  Stopped within a metre of both marks.
- **Found on the way**: a stopped mobile engine wiped its piston rings after about five minutes
  standing — the bearing law's `÷ ω` overflowing as the shaft decayed into denormals. Fixed with
  `Bearing::STILL_OMEGA`; the stationary engine's only change is a few parts in 10¹³ of two
  bearings' durability on the atmospheric cold start, where the shaft starts below the floor.
