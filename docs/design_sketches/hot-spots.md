# Hot spots — where a part is hotter than its node

**Status: reviewed 2026-10-17.**
- §1 agreed: the belt needs no hot-spot mechanism. Its tuning goes through the drum's size and
  power, and the deposit at the drive head (`mine-accidents-unit4.md` §5a).
- Rubber belting keeps its 672 K.
- B and the rule of §4 are the general mechanism, written into `nodes/CLAUDE.md` and `nodes.md`.
- Pieces 1 and 2 are deferred to `current_progress.md`: the headframe works well enough as it
  stands, and they are built when a caller needs them.

Raised by the belt conveyor (unit 4, §5): a stalled belt
lights against its drum, and the question was whether the drum's one lumped temperature
understates the face the belt touches. This sketch answers that for the belt, and proposes the
general rule for every case like it.

---

## 1. The belt, worked through

The claim was that the belt's lap, stationary on a turning drum, runs far hotter than the drum's
rim. The numbers do not support it.

- **Where the heat goes.** Heat made at a sliding contact splits by the two sides' effusivity
  (`√(kρc)`): steel about 13,900, rubber about 540. So **96% goes into the drum**, and more than
  that, since the drum's face is always fresh.
- **How much hotter the face is than the drum's skin.** The drum's face passes under the 1.1 m lap
  in about 0.55 s at 2 m/s. Jaeger's moving-source result for 15.6 kW over about 1 m² gives a mean
  face excess of **about 1 K**.
- **How far the drum is from lumped.** Heat crosses a 12 mm steel shell in about 11 s, against a
  fire that takes minutes. One temperature is the right model for the drum.
- **The belt's side.** Its face is at the contact temperature from the first moment. Heat takes
  about 5 minutes to soak 5 mm into the rubber, but **ignition is a surface event**, so the face is
  what counts.

So `hot_spot: :belt_drive`, reading the drum's lumped temperature, is right to within about a
kelvin. What separates the model from the field reports — belts lighting within seconds of a full
slip, with the drum reading 370 °C — is not where the hot spot is:

- **Drive power.** A trunk belt's drive is many times this gate belt's 15.6 kW.
- **The ignition criterion.** 672 K is spontaneous ignition. Rubber's pyrolysis vapour lights
  lower with something to set it off, and the drum friction tests are full of abraded rubber.
- **The drum's mass, and here our error runs the other way.** A 0.6 m × 0.9 m shell 12 mm thick is
  about 160 kg, roughly 7.8×10⁴ J/K. The `belt_drive` node carries 2×10⁴ J/K, so it is about four
  times too light, and it lights the belt **faster** than its own physics would.

**Recommendation for the belt:** no new hot-spot mechanism. Decide separately whether to:
- give the drum its true mass;
- revisit the drive's size;
- read the belt's ignition as piloted rather than spontaneous.

These are all figures, and §5 lists them.

## 2. The general problem

A node is one temperature. Some hazards live at a **place on a part**, hotter than the part
taken whole:
- the crown sheet over a low glass;
- a brake lining's face;
- the white metal in a bearing against its housing;
- the timber bearers under a plummer block;
- a heating's core in the goaf;
- later, a fuel pin's centreline.

The codebase already handles this two ways, without a rule for choosing between them:

| Case | How | Kind |
|---|---|---|
| `Boiler#crown_temperature_k` | a temperature derived from the water and the fire, recorded in state | **derived reading** |
| `Gob`, `district_rock` | their own nodes, linked to the room, named in `hot_spot:` | **separate body** |
| `Bearing` | the interface is its own node, apart from the shaft | **separate body** |

## 3. The two options

### A. An alternate resolve — a different solve while the geometry holds

While the condition holds (a belt stalled, a glass low), the part computes its hot spot from a
geometry-specific formula, for example the transient for a stationary patch against a moving
source. Otherwise it reads its bulk temperature.

**Pros**
- Exact where an analytic answer exists, including the `√t` growth of a skin being heated. A
  lumped skin of fixed depth gets that only approximately.
- No extra nodes, and no stiff small heat capacities.
- The geometry change is explicit and named in the code: "stalled" is a branch a reader can find.

**Cons**
- **It is a second solver beside the one implicit network.** As a reading it moves no energy, so a
  hot spot cannot cool by its own route, heat a neighbour, or be ledgered. If it does move energy,
  it is operator splitting, which `physics/CLAUDE.md` records costing a factor of two in a fan's
  speed.
- **A transient needs a clock.** "Time since the stall began" is state that has to survive
  snapshots and reset correctly. Switching modes is a discontinuity in what the hot spot reads.
- **It does not generalise.** Every geometry is a new formula in a new node: a stationary patch on
  a moving surface, a plate between fire and water, a sphere in a bed. The next operation writes a
  third one.

### B. A separate body and link — the hot place as its own node

The hot place is a node with its own heat capacity:
- **The source names where its heat lands.** A drag already does this; `Tick#book_drive` heats
  the node it is keyed to.
- **A link carries the heat into the bulk**, at `area × k ÷ depth`.
- **`hot_spot:` reads it**, as it reads the gob and the rock now.

A change of geometry is a **change of the link's conductance**, recomputed per tick. The radiant
`ThermalLink` already does exactly that through `Coupling`.

**Pros**
- **Conservation and stability for free.** It is one more body in the same implicit solve, stable
  at any `dt` and on the ledger.
- **It subsumes A's quasi-steady case.** Backward Euler with a heat capacity much smaller than
  `G·dt` settles the node at `T_bulk + P/G` within the tick. A part whose hot spot equilibrates
  faster than a tick needs no special path; it gets the steady excess automatically.
- **It is general and composable.** It is the same three pieces in every operation (a body, a
  link, a named heat destination), and the hot body can also touch air, timber or a vessel.
- **Mostly built.** `Nodes::Wall` is a skin of a material, area and depth. `book_drive` routes
  drag heat to any node. The per-tick `Coupling` is already in `settle_heat`.

**Cons**
- **A lumped skin has a fixed depth**, so a transient is approximate. The skin has to be chosen
  for the timescale that matters, as `ROCK_SKIN_M` is chosen for minutes.
- **More nodes, and figures to choose for each one**: area, depth, material.
- **A geometry change needs a conductance method** on the part that owns it, which is new surface
  on the link.

## 4. The rule, and the recommendation

**Use B by default; use A only where the physics cannot be written as a conductance.** Two numbers
decide whether a hot spot needs anything at all:

1. **The excess**, `P/G_spot`: the power through the place over its conductance to the bulk.
   Within a few kelvin of the bulk, the bulk node is the hot spot, and nothing is needed. This is
   the belt.
2. **Its time constant**, `C_spot/G_spot`:
   - Much under a tick, B's node settles in the tick, or a recorded reading would do.
   - On the scale of the hazard (minutes for a fire, hours for a heating), B's node is the right
     model.

A remains right where the answer is a **blend of two known temperatures**, not a stored heat. The
crown sheet is an interpolation between water and fire by exposure, it is fine as it is, and it is
not converted.

To make B the easy path, in order:

1. **`heats:` on a heat source.** A `Bearing` books its drag into a named node instead of itself;
   it defaults to itself, so nothing changes. That makes the white metal and its housing
   expressible as two bodies.
2. **`Nodes::Wall` takes a `behind:` node.** Its conduction then runs into that node rather than
   to ambient, so a skin can sit on a body as well as on the earth. Unset, it keeps the earth.
3. **A contact link whose conductance a node answers per tick**, for a geometry that changes:
   gripping against slipping, a door open against shut. TODO: no first caller — §1 shows the belt
   does not need it — so it is not built until one exists.

**The first caller worth checking is the headframe.** Its timber reads `hot_spot: :sheave`, the
journal's own temperature, but the bearers sit under the plummer block's housing, which is cooler
than the white metal inside it. With pieces 1 and 2, the housing becomes a skin the journal heats
and the timber reads instead. Whether that moves the headframe fire by enough to matter is the
first measurement.

## 5. Questions for review

1. **The belt needs no hot-spot mechanism** (§1). Agree, and take the drum's mass and the drive's
   size as a separate figures pass? Recommend yes: a heavier drum makes the fire slower, and the
   drive size is what decides whether it lights at all.
2. **Rubber's ignition, spontaneous or piloted.** 672 K is the Bureau of Mines' spontaneous
   figure. Piloted ignition of rubber-based materials is about 400 °C against about 600 °C
   unpiloted. A drum shedding rubber dust and smoke is arguably piloted, which would be about the
   same 672 K for belting. Recommend keeping 672 K.
3. **B as the general mechanism, with the rule of §4.** Recommend yes.
4. **Build pieces 1 and 2 now, with the headframe as their first caller and measurement**, or
   defer until a caller needs them? Recommend deferring, and putting it on the to-do list with the
   headframe named, because §1 removed the caller that prompted this.
