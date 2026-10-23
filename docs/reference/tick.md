# The tick

One advance of one operation. Implemented in `lib/reactor_sim/tick.rb`; `Operation#step!`
delegates to it and installs the result atomically.

```ruby
@state = Tick.new(self, @state).call(tick:, dt:)
```

`dt` is **simulated** seconds — `ReactorSim::DT (0.25) × operation.time_scale`. Wall-clock is
always 4 Hz; `time_scale` is how fast the world runs relative to that, per operation. A steam
engine uses 1.0; an operation running alone may use much more.

> **Coupled operations must share a `time_scale`**, and `Match#validate_couplings!` refuses to
> build a match where they do not. Work crossing between operations is energy, and energy per
> *tick* means nothing unless both sides agree what a tick is worth: at 40× an operation lives 10
> simulated seconds per tick against 0.25 at 1.0, so it would need forty times the joules to run
> the same machines and would be starved in exactly that proportion — while the supplier's own
> instruments read correct throughout. Scaling the transfer to compensate would mint energy. Two
> operations joined by a shaft are in the same world at the same time.

---

## The eight phases

| # | Phase | What it does | May draw entropy? |
|---|---|---|---|
| 0 | `draw_fates`, `draw_tempers` → `actuate` | **Every die thrown for a person this tick** — their fates from their own stream, and their temper's dice from a second stream of their own (`Animosity.stream`), so neither moves the other — then levers travelling toward their targets at the rate their minion can manage — and not always to the lever they were aimed at, because somebody out of their depth at a tricky post freezes, pulls it backwards, or grabs a different one in the same room. A slip somebody **meant**, left in `state[:spite]` by last tick's 6d′, begins in place of the dice. Then a post with a **governor** — the winding engineman — drives the internal levers it works from its own lever's value and the machine's **frozen N−1 state**, writing their target with their actual; with nobody posted it does nothing and they hold where they were left. Where he winds to is the player's lever, or — with `coal_winding` on — his own **shuttle** (`Winding#dispatch`): men first (`Tick#calls_for`: the far landing of anybody aboard, then the landing of anybody waiting to cross), else a laden deck up and an empty one down for more. He winds by speed, feathering the clutch from where he left it, and **at the mark holds the cage with the brake**, whichever way the ropes' imbalance is pulling it. He winds away from a landing only on its **bell** (`Tick#signalled?`): with a marshal posted there he holds until nobody is still getting in — unless the marshal is slipping, which rings a false ready; with nobody posted there is no bell and he winds on the order alone | **yes** |
| 1 | read | Freeze tick N−1, build the `Context` every node sees. `ctx.controls` is not the lever positions: an **effort** station's value is its position scaled by what the crew posted there can manage between them, in worker-equivalents, gates included. The context also carries **the sky as of last tick** (`ctx.sky`, from the outdoors node, or the standard sky where there is none) and each node's `exposure`, which `ctx.ambient_k_of(node)` uses. A place open to the sky is offered its light as `darkvision`, and `wet` and `icy` underfoot, by its exposure (`Tick#under_the_sky`), merged better-of with what its nodes offer — and a gate may be met by the **room** as well as by the person, which is `Tick#ambient_tags` (light on the roadway against a lamp on a belt; the better of the two, never the sum). The room also supplies its **ignition**: `Tick#ignition_sources` sums what every node in a place offers through `ignition(state, levers)`, and then the naked light of anybody standing there carrying `open_flame` (`Minion::HAND_FLAME`, from N−1 minion state), and hands it to that place's air as `ctx.room_ignition(id)` — nodes then minions, each walked by sorted id. And each hoist's or man engine's **cargo** — everybody committed `via` a drum or `riding` the rods, from N−1 minion state — as `ctx.cargo_kg(id)` | no |
| 2 | `plan` | Every node declares intent, independently, against N−1 | no |
| 3 | settle | One pure function over every claim — mass, heat, momentum | no |
| 4a | `advect` | Granted parcels cross a whole **path**, carrying their energy. Returns what was *delivered* per inlet, which is what the walls left of it | no |
| 4b | `conduct` | Granted heat moves across thermal links | no |
| 4c | `shed_to_ambient` | Waste heat leaves for the environment → ledger | no |
| 4d | `drive` | Angular momentum crosses the drivetrain, drag included, through geared and clutched links; torque **sources** (gravity on a drum) solved in the same step; work → `joules_extracted`, a rope end's brake → `joules_roped`, a source's work booked on its node, the rest → ledger | no |
| 4e | `apply_nodes` → `transmit_torque` | Node-specific effects, then prime movers pay for their torque | no |
| 5 | `react` | First, anything faster than a tick: a node hosting a `prompt:` reaction resolves whatever triggers, in sequence (`Concerns::PromptReaction`), emitting `:explosion` and recording `front:`. A front a gas neighbour recorded last tick arrives here this tick and sets off a mixture in range, so a front travels a room a tick, read from N−1. Then ignition spreads and the rest of its chemistry runs at its rates (scaled by the node's `reaction_throttle`), then phase change — local to each node | no |
| — | `record_injections` | Everything injected or extracted goes on the ledger | no |
| 6 | `stress` | First, what somebody did to a part **last** tick: every mishap in `state[:mishaps]` is suffered by the part it names (`Wearing#suffer`). Then durability, overload, failure events. A failure's `damages:` are spent on its neighbours — **and so are this tick's explosions'**, keyed `explosion:` | no |
| 6b | `endanger` | What a failure **or an explosion** does to the **people** near it: a Danger Check per minion, against the **place** they are standing in, the station they are posted to, and what is carrying them through a shaft (`riders:`, by `via` or `riding`). An `:explosion` from phase 5 is looked up by its node and `mode: :explosion` exactly as a failure is by its mode, and may scale with its `joules`. **A hazard declaring `along:` runs down a passage** — a runaway set — and reaches each person by their share of the way down (`Tick#along`): everybody at the foot, little at the top, stations placed by `positions:`, walkers by their real progress, and the road's own hands (`roaming:`) at their `road:` die; anybody on the road may reach the place's refuge (a near miss, on their `dodge:` die) or be crushed (`caught:`, rising as the share squared); a `catch:` on the run cuts the share of anybody below it to `1 − holds`. Severity adds where more than one reaches them | no |
| 6b′ | `scorch` | What the **heat** of the room does to the people in it: resilience ground away at a rate set by the gas's volumetric heat capacity and how far it is past what that person tolerates. The gas phase only — you stand beside water, not in it — and a threshold rather than a multiplier, so below somebody's rating it costs exactly nothing | no |
| 6b″ | `chill` | What the **cold** of the room does to the people in it: below a tolerance (`Chill::TOLERATED_K`, raised by `cold_resistance` and toughness), resilience is ground at a rate set by how far the air *as felt* is past it — the place's gas, with the wind chill taken as far as the place is open to the sky (`Tick#place_felt`). A dwell counter, `chilled`, carries it past collapse to mortal. Nothing at all above the tolerance | no |
| 6c | `tire` | What the **work** does to the people doing it, and what the **air** does to them: fatigue accrues on `intent ÷ capability` — times `Chill.strain` in a hot place, since heat makes the same work cost more; somebody in a brawl pays `Animosity.exertion` instead, a flat rate plus the weapon's weight against their `force`, and rests not at all — and recovery and suffocation net against it. The air is the gas phase of each place's air node (`Tick#breathable_air`), and none at all where that node is `submerged?` — drowning is suffocation. Pinned at the ceiling in bad air is the collapse, and the clock from there to a mortal injury runs here | no |
| 6d | `blunder` | **What the people do to themselves**, which is the route into harm that needs nothing to break first. A hidden `margin` of safety, spent by the **perils of the place** in proportion to how hard it is being worked, and mended only where no peril reaches at all — a lull between tubs is not recovery. Crossing zero is an accident, and **which peril it was is picked in proportion to what each took this tick** (the `peril:` fate, walked by sorted id) — so every peril that reaches somebody can happen to them, at the rate it spends rather than the severity it hurts with. A `judged:` pair splits one event by `Minion#misjudges`, read in the room's light, so who is posted decides which of the two it is. `safety_equipment` fitted in that place may turn it into a `:minion_near_miss` instead. A peril that names a `mishap:` emits `:minion_mishap` and writes it to `state[:mishaps]`, and the part it names suffers it at the start of the **next** tick's phase 6 — a state key rather than the event, because events are not snapshotted. How much of a peril reaches somebody is divided by their `avoid` — wits and agility both — and raised by what is distracting them | no |
| 6d′ | `provoke` | **What the people do to each other** (`Animosity::Provoke`). A hidden `patience`, spent while somebody shares a place with others — the deepest grudge held against anybody present, plus a little `IRRITATION` for each person there, more for somebody `annoying` and less for somebody `calming` — scaled by temper and fatigue, and mended only apart. Running out is an act at somebody they can get at who is not already in a fight, picked by the `target:` die weighted by how much each is resented, unless a boss overseeing the place steps in (`quarrel_averted`): a row, a brawl, a shove into an `opportunity:` peril, or sabotage through an `opening` of their post — whichever of those they are willing to do, by hostility (grudge plus a violent nature), callousness and how many bystanders it catches, a bonehead taking it for harmless. A shove or sabotage is a contest of `strike` against `defend`, all or nothing; sabotage that lands leaves a mishap in `state[:mishaps]` or a slip in `state[:spite]` for the next tick. A brawl is an exchange of blows every `BOUT_S`, each a `Combat` contest: landing on a bell-curved roll of `strike` against `defend`, graded by how far it won, hitting by whatever is in hand (`Minion#wielding`: the weapon's `handling:` read off the body on a tight damage stretch, plus its `edge`; bare hands are a poor weapon of their own), and on a critical slipping past the armour to meet only `CRITICAL_TOUGHNESS` of the target's toughness, until the one who started it is sated, either is down or spent, or the boss parts them; each exchange gives both of them back some patience, more for what lands and far more once it has hurt them (`HURT_RELIEF`). Each exchange a fighter may reach for their weapon, on a chance that climbs as the square of their hostility times their callousness — a grudge counting partly as callousness towards the one it is held against — and far likelier once the other drew at an earlier exchange. Blows leave no grudge; once the fight is over, a fighter it carried out or killed holds `WOUND_GRUDGE` against the other. Every decision reads the minions as the phase begins; what lands is applied by sorted holder id | no |
| 6e | `travel` | Where the people have got to, in **two passes**. One: everybody who can walk moves toward the place their `posting` is worked, at their own `pace` less whatever they are carrying, by the **quickest passage that is actually running**. Two: anybody being carried is *stowed* — their place written from their carrier's, their station and posting cleared. Also keeps `remaining` and `journey`, which are how far there is left to go and how far there was to go at the farthest point of this walk — a panel divides them for a progress bar. A posting may name **a person** rather than a lever, which is a fetch order and becomes a pickup on arrival. A **ridden** passage (a cage) is boarded, not walked: somebody waits at the landing until the cage is there and stopped, is then `via` the drum and wherever the cage is, and gets off at the far landing — or back where they got on, if that is where they are going or the cage has stopped running. Getting in takes `Hoist::BOARDING_S`; a cage wound away meanwhile catches them (`boarding_hazard`) and leaves them at the landing. Where a landing's **marshal** is posted, a pass after the walk lets on this tick's boarders in id order while the cage's `rated_kg` has room, as of last tick, and sends the rest back to wait. A ridden way is offered only while its post is manned, its drum sound and its shaft turning. Somebody part-way along a powered way is `riding` its drive. **Somebody in a fight does not walk**: their order waits until it is over. A no-op in an operation that declares no passages | no |
| 6f | `signal_winding` | **The signal board**: for each winder, what its cage is doing and waiting on — a fault, then why it is not moving, then the bell, men getting in, a deck being worked, men waiting across the shaft (`Winding#signal`) — written onto the drum as `signal:` for the panel. Over the tick just settled, because no node can see the people: the same reason `advect` hands a conduit its `carried_kg` | no |
| 7 | `observe` | Instruments sample; their filters advance. An instrument that names an `observer:` is **somebody's word**: it reads through whoever is posted at that station and goes `:offline` when nobody is | **yes** |
| 8 | publish | Freeze the new state, return this tick's events | no |

Entropy is confined to phases 0 and 7 (plus `initial_state`). That is what makes projection
pure — see [`invariants.md`](invariants.md#2-determinism).

**Phase 6b draws no entropy, and that is why it can sit here at all.** A minion's `resilience` is
rolled once at `initial_state`, so the Danger Check is a deterministic comparison rather than a
throw — which keeps injuries replayable and needed no amendment to the rule above. It runs after
all wear is settled, never inside it, so two parts failing on the same tick hurt the same people
whatever order they were visited in. It reads the failure events rather than the nodes, which is
also what lets a hazard's severity scale with how big the event actually was.

**Phase 6b′ grinds `resilience` directly rather than draining a pool of its own**, because heat
is not tiredness and does not recover by standing somewhere cooler for a minute. It is beside
`endanger` rather than inside it because the two are different shapes: a hazard is a blow
delivered by a part that failed, and heat is a condition of the room that keeps working for as
long as somebody is in it.

> **A steady harm needs a dwell to be able to kill.** Grinding resilience to zero proposes
> `:severe`, every bite after proposes `:severe` again, and `Severity.escalate` rightly refuses
> to announce the same injury twice — so nothing ever reaches `:mortal` without a bite of
> `Injury::MORTAL_BITE`, which no steady hazard grows. `Breath` counts `asphyxia` past the
> collapse and `Scorch` counts `burns`, both for this reason. Anything added here that harms
> continuously owes the same counter, or it produces a minion who is permanently stood down in
> a furnace and never dies.

**Phase 6c draws no entropy either, and it runs after 6b rather than at phase 0** — which is where
a long-standing `TODO` said it belonged. Three reasons: the effort actually demanded this tick is
settled at phase 1, so phase 0 would charge people for last tick's levers; `endanger` already
writes `minions`, and a second writer would need a merge rule between them; and a minion carried
out in 6b has `station: nil` on **this** tick and must stop working on this tick, not the next.
The TODO's premise — that accrual would sit alongside the actuation entropy it draws — was simply
wrong, because it draws none.

**Phase 6d grinds the accident margin, and it runs after `tire` so it reads this tick's fatigue
rather than last tick's.** The usual rule that everything must read the frozen N−1 constrains what
*nodes* may see of each other; a minion's fatigue and their margin are one object being advanced
twice in a fixed order. Running after `endanger` matters too: somebody already carried out by an
exploding boiler this tick has no station before their own margin is weighed.

**Phase 6d′ runs after `blunder` and before `travel`**, so a brawler is held where the fight is
and somebody carried out this tick has no temper to lose. It writes other people's state — the
one phase that does — so every decision and every exchange reads the minions as the phase began,
and only what lands is applied, by sorted holder id: two people going for each other on one tick
cannot depend on which was visited first.

**Phase 6e runs last of the five and reads no controls at all.** Who is standing where is built in
phase 0 from the *previous* tick (`crews`, `control_values`), so a minion who arrives in 6e
takes up their post on the **next** tick — the same one-hop delay everything else in the engine
has, and what keeps arrival from depending on phase order. It runs after `tire` so a minion carried
out in 6b has already had their posting cancelled and does not get up and resume the walk.

> **Geometry is opt-in, and that is what kept this from touching anything.** An operation that
> declares no `passages:` has an empty `Layout`, `travel` returns immediately, and `assign_minion`
> sets `station` the moment the command lands exactly as it always did. The steam engine did not
> acquire a walk to the firehole.

> **Fatigue is a runaway, and it has a closed form.** `capability` contains `(1 - fatigue)`, so
> tiring raises the load, which tires faster. Integrating `(1-f)²df = K dt` gives
> `t = (1 - (1-f)³)/3K`, so **time-to-spent is a third of what a flat rate would give, at every
> load** — an `exertion:` reciprocal is a nominal figure. `Fatigue::LOAD_CEILING` bounds the pole
> at `fatigue` 1.0, which a severely injured minion reaches the moment they are hurt.

---

## Orderings that are load-bearing

These are the parts most likely to be broken by a well-meaning rearrangement.

**A choked node reacts on a shorter second.** `run_reactions` scales `dt` by
`Node#reaction_throttle` (1.0 unless a node says otherwise), which is how a grate banked with
its own ash smothers its fire: the air can no longer reach the fuel. Applied to `dt` rather than
to the finished extent **on purpose** — the closed form stays a closed form and stays exact, and
scaling the extent would charge a fire for its draught twice, which is the mistake
`Resources::Ignition` records having made with the lit-mass term.

**Mass moves before heat (4a before 4b).** A parcel carries its own energy, so advection must
happen first or a parcel's energy arrives without it.

**Material crosses a whole path in one tick.** Settlement resolves from one node that *holds*
material to the next, straight through any conduits between them, so a valve or a length of
pipe adds no delay. `Tick#carry_through` then mixes the stream with each conduit's wall to a
single temperature on the way past — that is what keeps a chimney cooling its flue gas and
lets a hot line still rupture, now that nothing lingers in one. See
[`settlement.md`](settlement.md#mass-settles-over-paths-not-links) for why a conduit may not
hold material.

**Torque is transmitted after node effects (4e after `apply_nodes`).** A prime mover computes
its torque in `apply`; `transmit_torque` then applies that impulse to the driven shaft,
measures the kinetic energy the shaft *actually* gained, and charges the mover exactly that.

> Why measured rather than predicted: a shaft's KE gain from an impulse is `ω·ΔL + ΔL²/2I`.
> Billing the first-order `torque × ω × dt` alone manufactures the second term. Invisible at
> small timesteps, very visible at large `time_scale`.

**`record_injections` runs after `react` (phase 5).** Combustion releases energy in phase 5.
Ledgering before that would miss it entirely — this was a real bug worth ~1.8 MJ/tick.

**`observe` runs last (phase 7).** Instruments must see the settled tick, not a partial one.

---

## The crew is consulted twice, and the second one is the one that matters

`Tick#crews` maps each post to **everybody working it**, by sorted id, from **state** rather than
configuration, because a minion who has been reassigned is at the post their state names. It
counts `station`, not `posting`, so somebody still walking there is not working yet, and leaves
out anybody in a fight, who is at their post and working nothing. A post holds
as many as its `capacity` (one for a lever unless its part says otherwise; `Operation#room_at?`
refuses the next), and the crew's efforts **sum**. It is read in two different places.

> **Every seat starts in the crew quarters, so a machine nobody deploys does nothing at all.**
> Measured on the steam engine: 322.8 K and 0 kW undeployed against 1022.0 K and 495.5 kW with
> one hand on the shovel. Nothing implements that — an unmanned effort station already delivered
> zero — but it means a spec that runs a machine has to post somebody first.

**Phase 0 — how fast a lever travels.** `actuate` takes `rate_multiplier: crew_multiplier(id)`,
so a lever with a finite `stiffness` moves at `stiffness × rate_multiplier × dt`, where
`stiffness` is percent of the lever's range per second and the multiplier is the **sum** over
the hands on it — two people on a stiff valve wheel turn it faster than one. The mine's valves
ship finite figures — the fan is forty seconds hard over — and everything else keeps the default
`Float::INFINITY`, which snaps `actual` to `target` and discards the multiplier before it is read.

**Phase 0 — slips.** Everybody at a post can get it wrong, each on their own die from
`draw_fates`, so a crew slips more often than one of its members and no draw is added. The first
of them by id who slipped picks the kind and the victim.

**The governor** reads the post's one occupant: a governor post's capacity is held to one at
build. Presence checks — a marshal at a landing, a passage's `staffed_by` — ask whether anybody
is at the post. A gauge with an `observer:` reads as well as the **sharpest** member of the crew
at that post.

**An unattended lever travels at its rated speed**, deliberately: surface plant is the overseer's
own, and a colliery's fan and pump are at bank where nobody is normally posted. Posting
somebody makes a lever faster or slower than rated, never possible at all.

**Effort stations stay frictionless on purpose.** There the lever is intent and `capability`
already supplies the rate, so a finite travel would charge the same minion twice.

**`control_values` — what comes of the lever.** This is the live path, and it is not phase 0: it
runs wherever a control becomes the number a node reads.

```ruby
control.effort? ? worked(control, s) : control.value(s)
```

A control declares itself an **effort station** with a weighted stat blend, and what the node
reads is then `lever × Σ capability` over the crew, where capability is the blend × kit ×
condition. **That is worker-equivalents**: 100 is one competent, unaided human flat out and five
of them read 500, so a node multiplies a per-worker rate by it and caps nothing but the crew:

```ruby
ControlPoint.new(id: :stoking, effort: { swing: 0.75, dexterity: 0.25 }, aided_by: :shovelling)
```

**A blend may name any stat and three derived quantities** — `force`, `swing`, and `precision`
(agility 0.6 + dexterity 0.4, a quick deft hand). `strength` is a strength-to-weight
*ratio*, so a job that wants absolute output asks for `force` (`strength × mass ÷ 70`) or for
`swing` (`√force`, where a tool caps what bulk buys). All four are 1.0 for a reference human, so
every weight set still sums to 1.0 against the same baseline.

> **The lever is the player's intent; the crew supplies the rate.** An earlier design gave weak
> minions a finite `stiffness` instead, which models the *derivative* — a kobold would take longer
> to reach the setting and then deliver exactly as much as an ogre. Who can actually do the work
> is the comparison the game is about, and stiffness could not express it. See
> [`design_sketches/minions.md`](../design_sketches/minions.md) §9.

Weights must sum to 1.0, enforced, because that is what keeps *a fit unaided human scores 1.0*
true at every station — and therefore what lets a node's declared throughput mean "what a
competent person achieves". There is deliberately **no clamp**: the stoker's `0.25 kg/s` is a
person rather than a firehole, so somebody exceptional exceeds it. A conduit worked this way is
declared `worked: true`, which lifts its valve's 100% clamp and unbounds its ports;
`Operation#validate_worked!` refuses an effort post on a conduit that is not, and a worked
conduit on a valve. If the work then backs up further down the line, that is the player's
allocation to fix rather than a cap to add.

**An unmanned effort station delivers nothing** — an unmanned shovel moves no coal. It applies
only to the controls that are somebody's work; a valve needs nobody. A minion carried out has
`station: nil` and therefore mans nothing, which falls out rather than needing a case.

### The state hash must name it

`Tick#call`'s phase-8 return **is** the next state, so a key it does not name is silently
dropped. `minions:` carries whatever 6b and 6c settled for exactly that reason — omitting the
line deletes the crew on tick 1 and raises on tick 2.

A minion's state holds, among others, `health`, `fatigue`, `spent`, `station`, `posting`,
`place`, `resilience`, `injury`, `margin`, `patience`, `grudges` and `fight`. **The Symbols held as
values** — `station`, `posting`, `place`, `via`, `riding`, `injury`, every id in `carrying`, and the
seat a `fight` is `with` — are normalised on restore in `Operation#restore`; numbers and booleans
round-trip through JSON unchanged, and `grudges` is keyed by seat, which JSON keeps. So is the
operation's `spite` list, whose control and slip are values.

---

## The Context

What a node is allowed to see. Built once in phase 1 and passed to every `plan` and `apply`.

```ruby
Tick::Context = Struct.new(:controls, :dt, :tick, :content, :nodes, :states)
```

| Member | What it is |
|---|---|
| `controls` | `{ control_id => actual_value }` — the lever's **actual** position, not its target |
| `dt` | simulated seconds this tick |
| `tick` | tick number |
| `content` | the frozen `Content::Registry` |
| `nodes` / `states` | the **previous tick's** nodes and frozen states |

Helpers over previous-tick state, all returning `nil` when the node cannot answer:

```ruby
ctx.node_pressure(:boiler)    # Pa
ctx.node_omega(:flywheel)     # rad/s
ctx.node_temperature(:firebox)# K
ctx.node_state(:supply)       # the raw frozen state hash
```

Note `Operation::Context` is an alias for `Tick::Context`; both names work.

---

## What a node does NOT have to do

The engine handles all of this generically. A node that re-implements any of it is a bug:

- **Parcel bookkeeping.** By the time `apply` runs, granted parcels have already been removed
  from senders and added to receivers, and every node rebalanced to one temperature.
- **Heat transfer, ambient loss, friction.** Driven by concerns and links.
- **Phase change and reactions.** Driven by content and the node's `reactions` list.
- **Wear and failure.** Driven by `Concerns::Wearing`.
- **Observation.** Driven by the operation's diagnostics.

A node author writes `plan` and `apply`. See [`nodes.md`](nodes.md).
