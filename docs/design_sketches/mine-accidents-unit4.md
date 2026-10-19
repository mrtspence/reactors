# Mine accidents, unit 4 — new production tiers

**Status: reviewed 2026-10-16 — decisions in §9, which change §3, §4 and §7; building in order.
All five built: 20, 19, conveyors, sprays and the furnace.**
The last accident unit: each item is a way to get more coal out, and
the accident it arrives with. Drafted against the code as unit 3b and its follow-ups left it —
prompt reactions, rock walls, the shift parts. §0 of the unit 3 sketch carries over unchanged: thin
specs, machines do not know they are unattended, dice only in phase 0, steep tag levels, places not
jobs, docs with the change.

| # | Tier | The accident it brings |
|---|---|---|
| 20 | **Shotfiring** — powder, between picks and cutters | blown-out shots, misfires drilled into, premature fire, fumes |
| 19 | **Rope haulage** — the upgrade over putting | the rope parting on an incline, runaway sets, catch points |
| — | **Conveyors** — the tier after rope haulage | belt fires from a slipping drive, on the intake |
| — | **Water sprays on the cutter** | against frictional sparks, and the dust the cutter makes |
| — | **Furnace ventilation** — a fire at the upcast foot | igniting the return's gas; answered by the dumb drift |

---

## 1. Findings from the survey

1. **The machinery is already here.** Every item reuses the existing engine, and nothing needs a
   new physics core:
   - A conduit takes `displacement: true` and `driven_by:` (rope haulage, conveyors) and
     `stack_height_m:` (a furnace's draught).
   - `Nodes::Rope` is generic (the haulage rope).
   - A sheave's slip-heat lighting a timber frame through `hot_spot:` is a belt fire's mechanism
     exactly.
   - A prompt deflagration is a blown-out shot's consequence, and it takes the raised dust with it.
2. **The haulage road is level, and a runaway needs a hill.** `tub_road` is a rate-limited conduit
   (6 kg/s) worked by the putter. Nothing has a gradient, so nothing can run away. Item 19 has to
   give the road one (§4).
3. **Sparks now burn their seed one for one in lean gas.** That's the burn-down rule from the
   playtest. `CUTTER_SPARKS` (1e-4 kg/s) is therefore a 5.5 kW methane burn, and `BELL_SPARK`
   (2e-4) one of 11 kW. A spark lights a mixture; it does not burn a stove's worth of it. Both
   should be a spark's seed, about 1e-7 kg/s, which changes nothing about what they ignite. This
   is folded into the sprays item, which is about cutter sparks anyway.
4. **Face output is not yet the binding limit.** Hand picks win 1.4 kg/s at most, the cutter 5.6,
   and the haulage road carries 6. Shotfiring raises the face first, and that is what makes rope
   haulage worth buying. So the build order is the one in which each tier creates the need for
   the next (§2).
5. **The staffing pass overlaps.** Several hewers, station headcounts, putters scaling with the
   face, better tubs: it was deferred to after this unit, and it still fits there. Shotfiring and
   rope haulage are the two tiers it scales against. This unit adds no new hewing stations.

## 2. Build order

**20 → 19 → conveyors → sprays → furnace.** Shotfiring raises what the face wins; rope haulage
then carries it; conveyors are the tier after the rope on the same slot. The sprays are small, and
answer the cutter sparks every tier so far ignores. The furnace stands alone, a ventilation tier.

---

## 3. Item 20 — shotfiring

**What it is.** Holes drilled into the face, charged with powder, and fired, bringing down in one
shot what a hewer takes an hour to win. The tier sits between hand picks and the cutter. It is a
new slot, `blasting`, empty by default:

| Tier | Coal per shot | Flame | Fumes |
|---|---|---|---|
| Black powder | 1.5 t | long and hot: blows out readily | heavy, CO-rich |
| Permitted explosives | 1.5 t | cooled by its salts: rarely ignites gas or dust | lighter |

**The model.**
- A **shotfirer** post in the district, certificated (the ticket a player buys) and effort-gated
  by `darkvision`, works a `shot_hole` node.
- The cycle is drill, charge, fire, at a rate set by who is posted. Each firing moves a tonne and
  a half of coal from the seam to the district in one tick, alongside the hewer's own.
- It raises coal dust (a share of the coal brought down, into the district's air) and makes
  fumes (CO, flue gas).

**The accidents.** All are perils on the shotfirer's post, so a poor hand has more of them,
spends margin by activity, and draws dice only in phase 0. Each is a mishap on the `shot_hole`:
- **Blown-out shot.** The shot fires out of its hole rather than bringing the coal down. For that
  tick the hole is a large ignition source (a seed and real watts), so firedamp in range or a
  raised dust cloud goes up as a prompt explosion. That is Senghenydd's chain from a shot rather
  than a spark. Black powder blows out far oftener than permitted explosive does; the tier is a
  multiplier on the peril's rate.
- **Misfire.** The charge does not go off and stays in the hole (`misfires` in state). A hewer
  working that face is exposed to a severe `drilled_into_misfire` peril until the shotfirer clears
  it, which is a task the post does before it fires again. The hazard is all or nothing until the
  charge is dug out completely (§9.2).
- **Premature fire.** The shot goes while the shotfirer is still at it: a blast peril on him alone.
- **Fumes** are not an accident: every shot makes them, so firing in a still district poisons it.

**Counterplay.** Permitted explosives, a ticketed shotfirer, and ventilation to carry the fumes.
Stone dusting, so a blown-out shot finds no dust to carry it. Not firing when the flame cap shows.

**Specs.**
- A shot brings down its coal, raises dust and makes fumes.
- With nobody posted, nothing fires.
- On a constructed blown-out mishap: it fires an in-range district and leaves a lean one alone.
- Permitted explosive blows out less, as a rate.
- A misfire left in the hole exposes the hewer until cleared.
- Conservation through a shot.

## 4. Item 19 — rope haulage, and runaway tubs

**The geography it needs.** The haulage road gets a **gradient**: the sump is the lowest point,
so the district lies up-dip of the pit bottom, a rise of `ROAD_RISE_M` (first figure 12 m over the
200 m road, about 1 in 17). Full tubs go down to the shaft and empties come back up. Putting is
unchanged on a gradient this gentle. The rise only matters to what can run. Who a runaway reaches,
and how hard, is §9.3.

**The tier.** A `haulage` slot:
- **Hand putting** is the default: today's `tub_road` and putter, unchanged.
- **Rope haulage** is a haulage engine on the line shaft (`displacement: true`, so it moves sets
  only while the shaft turns) hauling sets of tubs on a main-and-tail rope. A **hauler** post at
  the pit bottom works the engine. Throughput is several times a putter's, and so is the bill on
  the shaft, which pays to raise the empties.

**The rope** is a `Nodes::Rope` with its own tier figures. Its tension is the set's weight down
the incline (`m·g·sin θ` plus rolling resistance). It wears by bending and corrosion as the
winding rope does, and parts past what is left of its strength.

**The runaway.** A rope parting, or a set breaking from it, makes a `runaway`:
- The set runs down the incline to the pit bottom. That is a blow to everybody on the road and
  at the pit bottom, scaled by the set's mass and the speed it reaches; it wrecks the haulage
  door, and it spills its coal at the pit bottom.
- A **hooker-on** coupling sets without fitting the backstay is a mishap peril on the hauler's
  post (the coupling breaks).

**Counterplay is a safety fitting**, `runaway_catch`, in the pattern of the manholes and shaft
gates:
- **Catch points** derail a runaway at the top of the incline, catching it before it gathers
  speed, by effectiveness.
- **Drags** (the backstay hooked on every set) stop it within a few metres.
- Either turns a runaway into a derailment and a near miss.

**What crosses the coupling.** The haulage engine is a load on the line shaft like the fan and
the pump. A set running away takes its load off the rope at once, a small load rejection felt up
the shaft.

**Specs.**
- The rope's tension follows the set on the incline.
- Rope haulage carries more than putting, and costs the shaft for it.
- Stopped, it carries nothing.
- A worn rope parts under a full set where a sound one holds.
- A runaway hurts the pit bottom and the road, wrecks the door and spills its coal.
- Catch points turn it into a derailment.

## 5. Conveyors, and belt fires

**The tier.** The third in the haulage slot: a belt conveyor on the road, driven off the line
shaft. It carries continuously and needs a hand only to watch it — the most coal for the least
labour.

**The accident is the intake fire it brings.**
- The drive drum is a `Bearing` (slip heat): an overloaded or wet belt slips on it and heats it.
- The belt is fuel, `belt` (rubber and canvas), with an `autoignition_k`, lying against the drum
  through `hot_spot:`.
- A belt fire burns in the **main road, on the intake**, so its smoke and CO go inbye to the face.
  That is Creswell (1950), and it is the headframe's mechanism exactly.

**Counterplay:**
- Don't overload the belt. Its load is the face output, so shotfiring plus a conveyor is the risk
  pairing.
- A belt attendant, whose post reads the drum's heat.
- Fire-resistant belting as an upgrade tier, which is what Creswell bought the industry.

**Specs.**
- The belt carries without a putter.
- Overloaded, the drum slips and heats, and a sound load does not.
- A drum past the belt's ignition point lights it.
- A belt fire's smoke reaches the district.
- Fire-resistant belting does not light from the same drum.

## 6. Water sprays on the cutter

A part in a new slot, `cutter_sprays`, only meaningful with a cutter fitted:
- **Sparks:** the cutter's spark seed is multiplied by a quench (first figure 0.1).
- **Dust:** the cutter's dust make is multiplied down (first figure 0.3).
- **Water:** it draws from the sump through a small line, so the sprays run while the pit bottom
  has water and stop when it is pumped dry. Drainage and dust suppression share one source, and a
  player who pumps the sump bare loses the sprays.

Folded in: the spark seeds of finding 3 become a spark's, about 1e-7 kg/s.

**Specs.**
- Sprays cut the cutter's ignition seed and its dust.
- They stop with a dry sump.
- A cutter in band gas lights it with the sprays off, and much later with them on.

**As built, 2026-10-17.** "Much later" could not be built. A deflagration triggers on any lit seed
above 1e-12 kg, so a spark scaled by 0.1 fires band gas on the next tick exactly as a whole one
does. **Decided instead: the sprays make the sparks harmless while they wet the face.** The quench
takes the hot streak behind each pick below what fires methane, so with the face fully wet the
cutter offers no spark at all, and once the sprays fail it offers its whole spark again.
- `Mine::SprayLine` is a displacement pump off the line shaft. It lifts sump water 12 m to the
  face at three bar, 0.4 kg/s, on its own `spraying` valve, which is a lever open by default.
  - The water lands in the district and runs back down the road to the sump (`face_drain`), so it
    is conserved and the sprays never drain the sump themselves.
  - **How wet the face is** is what the line passed last tick against its rating: fully at half
    its rating and above.
- `PickLine` records `quenched` while the face is fully wet, and offers no spark then. A face only
  partly wet is no protection: a spark quenched part way is still a spark.
- `DustLine` lays 0.7 of the cutter's dust in proportion to how wet the face is.
- **A sump pumped bare still takes its seepage**, and the sprays get that trickle: about 15%
  wetting in the spec rig, no protection. Sprays and drainage share one sump, so the player keeps
  water in it.
- Folded in: `CUTTER_SPARKS` and `BELL_SPARK` are now a spark's seed, 1e-7 kg/s. That changes
  nothing about what they ignite, only how much lean gas they burn.

## 7. Furnace ventilation

**The tier.** A furnace in its own slot, alongside the fan (§9.6): a coal fire at the upcast foot, heating the upcast column
so it draws by buoyancy (`stack_height_m:` on the upcast). It needs **no power from the line shaft**,
which is its whole appeal. It does need stoking, by a furnaceman post (effort, like the steam
engine's fireman), and its draught follows its fire.

**The accident.** The return air passes over the fire. Firedamp in the return reaching its range
there is an explosion at the upcast foot. The prompt deflagration resolves it in the furnace
vessel, hurts the furnaceman, and can drive back into the workings. This is the classic igniter of
return gas, and the restart slug of unit 3a finds it too.

**Counterplay is the dumb drift**, a part only a furnace can use. The return is carried past the
furnace in its own drift into the upcast above it, and the fire is fed from the intake, so no
return gas ever reaches the flame. It costs a little of the draught.

**Specs.**
- A furnace draws with the line shaft stopped.
- Its draught follows its fire.
- Return firedamp in its range fires at the furnace.
- The dumb drift keeps the same gas off the flame.

### 7a. Building it: the wiring

**Reviewed 2026-10-17**: A, the two-shaft upcast foot, and the furnaceman as a post (§7b). §7 and §9.6 are decided. What they leave open is how two slots, the furnace
and the dumb drift, change one airway, when **a part's builder sees only the chassis spec, never
the loadout**. Nothing in the mine has had to know another slot's fitting before.

**What is common to every option.**
- **The draught is buoyancy on the upcast.** The fan's conduit gets `stack_height_m:` at the
  shaft's 90 m, and `Arbiter.path_head` reads the source holder's temperature. A cold upcast foot
  pulls nothing, so this changes no existing number. A foot warmed by the furnace's flue pulls the
  whole return, fan or no fan.
  - At an upcast near 450 K that is about 370 Pa, against the waddle fan's 2,200. That is a
    furnace's historical draught on a shallow shaft: a cheap supplement, not a replacement.
- **The two-shaft frame gains an upcast foot** as a fixture, the single-shaft one already has one,
  so a furnace has a holder to heat in either frame. That is a holder in series where the
  two-shaft return now runs straight to the fan, so the measured ventilation figures (the gauze
  comment's 1.84 and 2.02 m/s) must be re-measured, and any spec pinned to them re-fitted.
- **The furnace is its own vessel**: a grate of coal stoked by a furnaceman (an effort post like
  the steam engine's fireman), its flue into the upcast foot. Its tiers are the grate's size and
  draught: fire basket, brick ventilating furnace, double furnace. Firedamp burns in it, prompt
  like the district's, so return gas in its range fires at the furnace.

**What differs is where the furnace's air comes from.** Without the dumb drift it comes off the
return, gas and all; with the drift it comes off the intake, and the return passes it by.

| | How | For | Against |
|---|---|---|---|
| **A. The spec carries the loadout's answer** | `assembly_for` merges what the resolved loadout fits into `spec` (`furnace_fed_from: :intake` when a dumb drift is fitted), and the furnace builder wires its air from that. | One builder decides its own air; no node knows another slot exists; build-time, in `options:` already through the loadout. | A new mechanism: one slot's fitting shaping another's graph. Every future case will reach for it, and the dependency is invisible in the slot list. |
| **B. The dumb drift is a furnace tier** | Each furnace tier comes with or without a drift: six parts in one slot. | No cross-slot wiring at all; what is fitted is exactly what is wired. | Against §9.6's "separate part", and buying the drift means re-buying the furnace in the outfitting screen. |
| **C. The furnace draws from both, the drift shuts one** | The furnace always takes intake and return air through two conduits; the dumb drift's part fits a stopping node, and the return conduit is shut while that node exists. | Two separate parts, no spec change. | A build-time fact read at run time through a node's presence, and a conduit that must pass nothing without a zero conductance (which `gas_coupling` refuses). |

**Recommendation: A**, written as a narrow rule: **a slot may declare `informs:` the spec keys
its fitting sets**, so the dependency is named on the slot rather than hidden in a builder, and
`spec` stays the one channel a builder reads. The dumb drift sets `furnace_fed_from: :intake`; with
it empty, the furnace is fed from the return.

**Questions.**
1. A, B or C?
2. The two-shaft frame gaining an upcast foot, with its ventilation re-measured and any pinned spec
   re-fitted. Recommend yes: a furnace needs a holder to heat, and the single shaft already has one.
3. The furnaceman as a new effort post at the upcast foot, rather than a lever. Recommend the post,
   per §7: "its draught follows its fire", and the fire follows the stoking.

### 7b. Built so far, and one gap: the flame does not travel

**Decided:** A, the slot `informs:` system; the two-shaft frame gains an upcast foot; the
furnaceman is a post.

**Built.**
- `Slot#informs` and `Part#informs`, folded into the spec by `Assembly` before any slot builds.
  A key a slot does not allow, or two slots informing one key, refuses the build.
- The upcast foot is in both frames. The fan's conduit carries the shaft's 90 m of stack. The
  two-shaft frame moved 1.6% (11.49 → 11.31 kg/s up the upcast).
- Three furnace tiers in their own slot: a fire basket, a brick furnace and a double furnace. A
  furnaceman post, a bunker, the furnace drift and a flue into the foot.
- The dumb drift's part informs `furnace_fed_from: :intake`, and it feeds the fire through a
  regulator at a fifth of the grate's bore.
- A latent bug fixed on the way: `Layout#merge_places` dropped a place's declared `air:` when a
  fitting added nodes to it.

**Measured** (brick furnace, two-shaft rig, fan running, ten minutes):

| | Upcast | Main road (face air) | Furnace |
|---|---|---|---|
| No furnace | 11.23 kg/s | 10.48 | — |
| Furnace | 13.69 | 12.86 | 702 K |
| Furnace + dumb drift | 13.71 | 10.83 | 935 K |

With the line shaft stopped, the furnace draws 4.78 kg/s where an unpowered pit draws 0.24.

**The gap.** With the fan stopped the district gassed to about 7.6% by volume, which is in its
range. Two things happened:
1. **The furnace went off every nine seconds.** Each deflagration burnt the 30 m³ chamber's
   mixture, the return refilled it to its range, and it went again.
2. **The district beside it, full of the same mixture, never lit.** Nothing carries a front from
   one node to another. That is wrong: a flame in an explosive stream runs back up the stream that
   fed it, which is how a furnace fired the workings. The pit bottom's comment ("where a district
   explosion's flame arrives") already assumes a front that travels, and none does.

Both are one missing mechanism: **a deflagration lights the in-range mixture in the nodes that feed
it gas**. With it, the first furnace explosion fires the district, and the pulsing never starts,
because the district's explosion consumes the gas the furnace was refilling with.

**Decided and built: the general rule.** Every operation with an explosion will need it.
- A node whose front burnt anything records `front:`.
- Next tick, `Tick#react` hands each node the first gas neighbour (`Operation#gas_neighbours`,
  derived once from the paths) whose N−1 state shows a front.
- That counts as a front arriving, so the node goes off if its own mixture is in range. The cause
  is `:front_from_neighbour`, with `detail: { from: }`.
- It runs **both ways along a gas path**, not only up the stream that fed the explosion, because a
  front leaves a room by every road out of it.

Measured, fan stopped, the district gassing: the furnace fires, the district goes up the next tick
and blows the door out, and with no fan the gas builds back and the pair repeats every five minutes
or so. The nine-second pulsing is gone.

**The question as it was put.** Build flashback as a general rule of `PromptReaction`, or keep the
furnace self-contained and not built? The general rule would read N−1 gas flows in phase 5. Each node that
resolves a front this tick would offer a seed next tick to every node that sent it gas on a path,
and that node goes off only if its own mixture is in range. It touches every operation with prompt
reactions, which today is only the mine: district → pit bottom, pit bottom → district, and the
furnace.
Recommend the general rule, because it is how explosions actually travel. Its first test is the
furnace firing the district, and its second the district's front reaching gas at the pit bottom.

---

## 8. Questions for review

1. **Build order** 20 → 19 → conveyors → sprays → furnace (§2), against the numbered order.
   Recommend as drafted: each tier then creates the need for the next.
2. **Shotfiring's accidents as perils on the shotfirer's post**, rather than per-shot dice. Recommend
   perils — competence-scaled, margin-spent, dice already in phase 0, and the machinery exists.
3. **A gradient on the haulage road** — the district 12 m up-dip of the pit bottom. Recommend: a
   runaway needs one, and full sets running down to the shaft is the drama.
4. **The shotfirer's ticket**: reuse `certificated` (the engineman's), or a ticket of its own.
   Recommend its own, `shotfirers_ticket`, so a player can buy one without the other.
5. **Sprays drawing on the sump** rather than free water. Recommend the sump: it ties two systems
   a player already manages.
6. **The furnace as a fan-slot tier**, cheaper and older than the waddle fan, rather than a slot of
   its own. Recommend the fan slot: it is what ventilates the pit, and you fit one or the other.

## 9. Decisions from review

1. **Build order as drafted**: 20 → 19 → conveyors → sprays → furnace.
2. **Shotfiring's accidents are perils on the shotfirer's post.** **A misfire is all or nothing
   until it is dug out.** A charge left in the hole is a whole charge: its hazard stays at its full
   weight for as long as any of it remains. Clearing is a job with progress
   (`clearing` 0 → 1, worked by whoever is posted to clear it), and the misfire goes the tick the
   work completes, all at once. Partial work buys nothing. It never erodes the hazard by degrees.
3. **The gradient, the right way up.** The sump is the lowest point, so the road rises from the pit
   bottom 12 m to the district, and full sets come down to the shaft. A runaway therefore starts at
   the district end and runs down to the pit bottom. **It does not strike everyone, nor everyone
   alike**:
   - What a person meets is the **set's speed where they stand**. That is `v = √(2·g·d·sin θ)` less
     rolling resistance, `d` being how far it has run.
   - **Each role has a place on the road**, and the order follows the gradient:
     - hands at the district end meet it as it breaks away, slowest;
     - the trapper at the doors near the foot meets it near full speed;
     - **at the pit bottom it is everybody**, at its fastest. No assumption that it stays on its
       rails down a road that may be strewn with debris: off the track at the foot, it is a hazard
       to the whole of the pit bottom, by place. That means the onsetter, and anybody idling there
       or waiting at the landing to board, all alike.
   - **Putters, and anybody walking the road, are at one of a few positions along it**, drawn per
     person in phase 0 from a `road:` fate.
   - **Somebody on the road may reach a manhole** (the existing escape cubbies) by the fitted
     manholes' effectiveness, scaled by their wits as safety equipment already is. Reaching one is
     a near miss.
   - **The worst case is its own injury**: `crushed_by_runaway`, a far heavier version of `wedged`
     — pinned against the side by a fast set, or caught between it and a standing tub. Its weight
     rises steeply with speed, so it is a real risk only well down the road.
4. **The shotfirer's ticket is its own** (`shotfirers_ticket`), apart from the engineman's
   certificate.
5. **The sprays draw on the sump.**
6. **The furnace is its own slot**, alongside the fan, not instead of it. Transitional pits ran
   both, and keeping a furnace on is a cheap way to more air at the price of fire and explosion.
   **It has tiers of its own**, by grate and arch — the draught a bigger, hotter fire buys:
   - a fire basket;
   - a brick ventilating furnace;
   - a large double furnace.

   The dumb drift stays a separate part, meaningful only with a furnace fitted.

**Added in review, while 20 was building: a misfire is first judged.** The draft's flat "drilled
into a misfire" peril reached the hewer at full weight for a charge everybody knew was there. That
is not how it killed people.

**The misfire is one peril split by the shotfirer's judgement** (`judged:` on `Peril`). Of the
misfire rate:
- `1 − m` is a recognised misfire. It waits in the hole for him to dig out, all or nothing, and
  digging may set it off on him (`set_off_misfire`).
- `m` is a misjudged one, taken for a spent shot. It is left **live in the face**, unknown to
  anybody, and the shotfirer's gauge goes on reading as if nothing were wrong. The hewer
  working that face strikes it at a rate scaled by how hard he is hewing (`struck_live_charge`),
  and it goes off on him.

`m` is `Minion#misjudges`. It is a tenth over the hand's wits, read in the room's light, plus 0.8 of
`daftness` (`boneheaded` cubed), clamped. So a sound hand in a lit district misjudges about one in
ten, the same hand in the dark nearly always, and a 1.0 bonehead all but always. Both goings-off are
a blast to whoever set it off, a flame in the room for a tick, and a little coal.

**Item 19, as built.** The haulage slot holds the tub road itself, so both tiers keep its roof and
its `:haulage` post. The rope haulage is the same `Roadway`, driven and displacement-limited, its
sets on `Mine::HaulageRope`:
- The rope's tension is a 2.6 t set down the incline, about 2 kN.
- It wears with traffic.
- It parts under a set's **snatch** (eight times the standing tension) once it is worn below about
  a quarter. A sound rope never parts under a set's weight.
- A hooker-on coupling without the backstay breaks a set away: the mishap `:breakaway`.

The runaway is a generic **`along:` hazard** in `Tick#along`. It reaches each person by their
share of the way down, then offers the manholes (`dodge:`) and the crush (`caught:`). Walkers count
by their real progress, and only the road's own hands draw a position (`road:`). Two dice per
person were added to `draw_fates`, which moved every stream; the specs that pinned a lucky roll
were re-seeded. The district's coal outlet and the pit bottom's inlet widened to 30 kg/s to carry
the haulage. The doc's "spills its coal" is not built: a set's coal is in a conduit, which holds
nothing. **Nor is the counterplay, `runaway_catch`** (catch points and drags). It was missed in
building, and found in the completeness pass. It is built now, as below.

**The runaway catch, as built (2026-10-18), deliberately plain.**
- **Slot.** A `runaway_catch` slot, empty to start. Each tier informs the haulage's builder
  (`informs: { runaway_catch: { at:, holds: } }`), and the rope haulage writes it into its
  runaway's `along:` as `catch:`.
- **The rule, with no new dice.** `at` is how far down the road the catch stands, and `holds` how
  much of a runaway it stops.
  - Anybody further down than `at` meets the set at `1 − holds` of the share they otherwise would.
  - Those above the catch are hit as before.
  - The door's wreck scales by `1 − holds` too.
- **Catch points**: `at` 0.15, `holds` 0.8. Sprung points that derail the set near the top,
  unless they are left open or the set jumps them.
- **Drags**: `at` 0.05, `holds` 0.95. A backstay on every set, which digs in within a few metres.
- **Specs**:
  - fitted, the pit bottom is hurt far less by the same runaway;
  - the door survives a caught set;
  - at zero ticks, a share below the catch falls and one above it does not.

**Conveyors, as built.** Two haulage tiers, `belt_conveyor` and `fire_resistant_conveyor`, both
`Mine::Conveyor`: a driven `Roadway` with no hand on it. Its `:haulage` control is the loading
point's feed, a plain lever, and a belt attendant (`belt_attending`) is a post at the drive head
whose `drum_heat` gauge is his word on the drum.

- **The slip is a stall, not a share.** A belt sliding on its drum grips less than one standing on
  it, so a belt that starts to slip does not recover until its load comes off. The loading point
  can push 40 kg/s onto a belt whose drum grips 30. With a pile waiting and the feed past
  three-quarters, the belt stops and carries nothing, and the drum turns on under it.
- **The drum is a stock `Bearing`** on the line shaft, `loaded_by:` the belt.
  - While stalled it rubs dry at the capstan slip force: 11.5 kN, a five-ply 30-inch cotton belt
    at its working tension, so 23 kW at 2 m/s. Gripping, it does not rub.
  - It is a real gate-end drum: 16 inch by 0.7 m in an 8 mm shell, 2.7×10⁴ J/K.
  - It sheds 48 W/K, so a drum stalled for good settles about 773 K at working speed, the most
    stalled drums are measured at.
  - The stall's drag is a load the engine feels: the spec rig's shaft sags from 207 to 151 rpm.
- **What lights is the spillage, then the belt** (§5a): drum → deposit at the drive head → belt.
  Measured in the spec rig, from cold at 151 rpm:
  - the deposit lights about 8 minutes after the stall;
  - the belt catches about 30 seconds later;
  - the drive head peaks about 1,100 K, against its half-tonne of frame;
  - the deposit burns out within a couple of minutes, and the belt fire carries on alone at its
    air limit.
- **The ignition points are measured, not chosen**, and none was moved to make the timing:
  - The deposit lights at 483 K, ASTM E2021's figure for a 25 mm layer.
  - Rubber belting lights at 672 K: the US Bureau of Mines found about 750 °F the least such belts
    lit at of themselves in air (RI 7053, 1967). Raw rubber is nearer 573 K; the cotton carcass
    and fillers hold a belt off longer, so period belting is not the more flammable kind.
  - PVC lights at 727 K (454 °C). Its fire resistance is its quench, five times its spread,
    rather than a much higher ignition point.
- **A clean drive head** leaves the belt only its own 672 K, which the drum reaches only near
  working speed. Keeping the spillage clear is what the attendant is for.
- **Wet** is the pit bottom's flooding: wet rubber on steel loses 0.6 of the grip, so a rising sump
  stalls a feed the dry belt carried. The sprays will be a second source; not built.
- **The belt road is a second intake** beside the main road, at half its conductance (its three
  airways in series, the drive head between them), carrying about a third of the intake. That is how belts were laid, and it is what makes the fire Creswell's: an
  air-limited belt fire there puts about 0.16% CO into the district, whitedamp's toxic fraction.
  Fitting a belt therefore raises the pit's air about 8%, as a new road would. A sixteenth of the
  conductance was tried first: the fire starved at 1 MW and the district got 0.03%.
- The belt road has 200 m of `coal_measures` round it, which holds its gas near 340 K while the
  belt burns. Without it, the gas reached 1,175 K and would have fired the district.
- The tub perils do not ride the belt. It carries `caught_in_the_belt`, at the drive head, on the
  attendant's post.

### 5a. Revision: what lights first is the spillage at the drive head

**Reviewed and built, 2026-10-17**, with all four questions as recommended: the deposit as its own
vessel, a fixed 483 K, spillage at 0.2% for a first pass, and grease as part of the deposit. One
change in building: the drive head carries its frame's steel as heat capacity. Without it, a
burning deposit drove the lumped gas to 2,150 K, coal's flame temperature.

As first built, the belt lit only through its own spontaneous ignition (672 K), which a stalled
drum reaches only near working speed, and slowly. The Bureau of Mines puts the
common source elsewhere: **the coal dust and grease packed round the drive head**. The figures
agree:
- Coal dust **lying as a layer** on a hot surface lights far lower than the same dust as a cloud,
  and lower the thicker it lies. ASTM E2021, Pittsburgh bituminous: 6.4 mm at 300 °C, 12.7 mm at
  240 °C, **25.4 mm at 210 °C** (483 K).
- RI 9380 lit belts from small coal fires 5–10 cm beneath them.
- `hot-spots.md` §1 found nothing missing at the drum itself. The missing piece is this fuel.

**The chain**: drum → deposit → belt.
- A stalled drum heats.
- At 483 K the deposit packed against it lights.
- The burning deposit is far hotter than the drum, and the belt lying over it lights from it.

**Built from what exists**, and no engine change: rule B of `hot-spots.md`, a separate body.
- **`drive_head`**, a small vessel holding the deposit, `hot_spot: :belt_drive`. It sits on the
  belt road's air, in series between `belt_draught` and `belt_road`, so it breathes and its smoke
  goes inbye.
- **The deposit is coal** spilled off the belt, which keeps mass conserved. A `Spillage` conduit
  from the loading point carries a share of the belt's traffic (0.2% to start), the way `ShotYield`
  rides the shot's total.
- **It burns by `coal_layer_combustion`**: coal's stoichiometry and heat, with
  `autoignition_k: 483`. That is the same coal as `coal_combustion` (700 K, a heating in bulk), in
  a configuration that lights lower. The geometry is in the reaction's name, as the figure is.
- **`belt_road` gains `drive_head` in its `hot_spot:`**, so the belt lights from the burning
  deposit's temperature, and its 672 K stays the belt's own true figure.
- **The belt attendant clears it.** His post works a conduit from the drive head back onto the
  pit bottom's coal, so an attended drive head keeps no deposit and its belt lights only by its
  own 672 K. The deposit builds while nobody clears it. That gives the attendant a mechanical job
  beside his gauge.

**The drum, realistically sized.**
- A gate-end drive drum, 16 inch by 0.7 m, with an 8 mm steel shell: about 55 kg, **2.7×10⁴ J/K**.
  This is not a fiat.
- **23 kW** stalled at working speed: 11.5 kN of slip, a five-ply 30-inch cotton belt at its
  working tension, at 2 m/s. This is already in.
- Heat loss of **48 W/K**, so a drum stalled for good settles about 773 K, the most stalled drums
  are measured at.
- Estimated: the deposit lights about **5 minutes** after a stall at working speed, and about 8
  with the drag slowing the shaft to 150 rpm. A clean drive head lights the belt itself only near
  working speed, in about 16 minutes. To be measured.

**What changes in the claims.**
- Fire-resistant belting "does not light from the same drum" becomes **"does not carry the fire"**.
  The deposit still burns at the drive head and smokes, and PVC lit locally goes out. That is
  truer to what fire-resistant belting bought.

**Questions.**
1. The deposit as its own vessel, with drum → deposit → belt by `hot_spot:`, against a general
   rule that a fire in a vessel lights its other fuels. Recommend the vessel. The general rule
   would also touch the firebox (kindling and coal), which sits on a measured plateau, and it is
   a new engine mechanism for a case the existing one already expresses.
2. A fixed 483 K, the 25 mm figure, against an ignition point that falls with the deposit's
   thickness. Recommend fixed. A thin deposit already burns out quickly, and a variable ignition
   point would need the node to override content.
3. Spillage at 0.2% of traffic, cleared by the attendant's effort. Recommend as drafted.
4. Grease is not modelled separately: no reliable autoignition figure for mineral grease was
   found, and it acts here as part of the deposit. Recommend leaving it out.

## 10. Documentation owed

Per the root `CLAUDE.md` table, in the change that lands each item:
- `operations/CLAUDE.md`, `build-an-operation.md`: the new slots and tiers.
- `nodes.md`: the shot hole, the haulage engine and rope, the conveyor drive.
- `add-content.md`, `content/CLAUDE.md`: `belt` and its reaction, and any new tag.
- `physics.md`: the incline's tension.
- `diagnostics.md`: new gauges (the hauler's rope report, the belt attendant's drum heat, the
  shotfirer's holes).
- `spec/CLAUDE.md`: a row per spec.
- `current_progress.md`: tick each item off.
