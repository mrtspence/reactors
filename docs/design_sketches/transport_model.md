# Transport model: mass joins Relaxation

**Status: design proposal, revision 2. Nothing here is built.**

Input: [`flow_through_issue_draft.md`](flow_through_issue_draft.md), which established that
`Conduit#plan`'s inventory map is `h ↦ T − h` — an involution with eigenvalue exactly −1, so the
oscillation is **undamped by construction** — and that `Arbiter.cap_gas_by_pressure` amplifies it
into an attractor by sampling both ends of a link in antiphase.

Decisions taken (2026-09-03):

| | |
|---|---|
| Approach | **Potential-driven transport.** Mass joins `Relaxation` beside heat and rotation |
| Conduits | **Zero-residence but still failable nodes** |
| Direction | **`one_way: true` by default** — precise about the exceptions instead |
| Rate caps | **Conductance alone.** Rate modes are per-node fiats, added when a part needs one |
| Stack height | **Config** — something players tinker with |
| Phases | **All three from the start** — gas, liquid *and* solid, with pump head, fans and conveyors |
| Modes | **Relaxation is the default for every fluid phase**; rate modes may replace or supplement it per node |

Driving principle: *if we get the physics abstraction right, the correct behaviour is an emergent
property.*

**Revision 2 changes one thing materially:** revision 1 claimed liquids could not join the
relaxation because they are incompressible. That was wrong. Under a **hydrostatic** potential
their capacity is `A/g` — finite, well-behaved, and simpler than the gas case (§3.3). Hydrostatics
turns out to be the enabler rather than the complication, so it is in from the start.

---

## 1. Why the cheap fix was rejected, with the measurement

Worth recording, because it is the strongest argument for doing the expensive thing.

The conduit's inventory recurrence is `h' = h − p(h) + d(h)`. With `p(h) = h` (push everything),
`dh'/dh = d'(h)`. Writing `d(h) = T − αh`:

| α | `dh'/dh` | Behaviour | Measured |
|---|---|---|---|
| **1.0** (today) | **−1** | involution — undamped, orbits forever | `0.8400 / 0.0000` forever |
| 0.75 | −0.75 | converges to `h* = T/(1+α)` | `0.686` — predicted 0.686 ✓ |
| 0.50 | −0.50 | converges | `0.800` — predicted 0.800 ✓ |
| 0.25 | −0.25 | converges | `0.960` — predicted 0.960 ✓ |
| **0.0** | 0 | steady *if* the push always lands; **unbounded if it does not** | damper ran 1.2 → 7.0 kg and climbing in a 1 m³ duct |

A one-line change genuinely fixes the oscillation, at a cost of `T/(1+α)` throughput. Rejected
because **α is a magic number standing in for physics we have not modelled.**

The α = 0 row is the important one. It proves the dilemma is real: **a separately-stateful
intermediate node reading N−1 cannot both receive and forward the same material in one tick.**
Steady inventory and steady throughput are mutually exclusive for it, because it must commit to
its intake before it knows what it will discharge. Any fix must stop the conduit being an
endpoint.

---

## 2. The option space

| Option | Verdict |
|---|---|
| **Damped conduit** (α ∈ (0,1)) | One line, measured to work. Magic constant; throughput still scaled by `1/(1+α)`; duct pressure still an artifact; hop still costs a tick. *Rejected — but it is the fallback if this stalls* |
| **Scheduled delay line** | Honest, but adds per-parcel scheduling to the hottest path in the engine and fixes neither the duct pressure nor the hop. *Rejected* |
| **Conduits as pure `Link` properties** | **Does not say what drives flow.** `Vessel#plan` and `Atmosphere#plan` both return `Intent.none`, so deleting conduits leaves every link with no active end and nothing moves. Also loses pipe rupture and thermal links to pipes. *Rejected as stated* |
| **Zero-residence, rate-driven paths** | Fixes everything in the investigation, but flow is still "as fast as allowed" rather than driven by anything, so back-pressure stays a special case. *Rejected as an endpoint — kept as migration step 1* |
| **Potential-driven transport** | **Chosen.** Below |

---

## 3. The model

### 3.1 One law, three phases, two modes

`Relaxation.settle(links, capacities, potentials, dt)` is already fully generic — it needs only
`id/a/b/conductance` plus two hashes keyed by node id.

| | capacity `dm/dP` | potential | conductance |
|---|---|---|---|
| heat | heat capacity (J/K) | temperature (K) | W/K |
| rotation | moment of inertia (kg·m²) | angular velocity (rad/s) | N·m/(rad/s) |
| **gas** | **`V_free · M / (R·T)`** | `nRT / V_free` | kg/(Pa·s) |
| **liquid** | **`A / g`** | `P_gas + ρ·g·depth` | kg/(Pa·s) |
| **solid** | — | none | — (rate only) |

Dimensional check against `Relaxation`'s `tau = 1/(k·(1/cₐ + 1/c_b))`: `1/c` is Pa/kg, so
`k·(1/c)` is 1/s only if `k` is kg/(Pa·s). ✓ That unit is a **valve flow coefficient** — a real
engineering quantity, not an invention.

This makes the Arbiter's own docstring — *"mass and heat go through the same machinery because
they are the same problem"* — literally true for the first time, and inherits both of
`Relaxation`'s guarantees: **unconditionally stable at any `dt`** (so `time_scale` stays a safe
dial) and **exactly conservative** (one number applied twice with opposite signs).

**Two modes, chosen per path per phase:**

- **`:relaxation`** — the default for gas and liquid. Potential-driven, closed form.
- **`:rate`** — the only mode for solids, and available anywhere as an override or a supplement.
  A declared kg/s, limited by availability and room.

Solids are the honest exception, not a compromise. Granular flow through an orifice follows
Beverloo's law — mass flow scales with the orifice, and is **independent of head**, which is why
a hopper empties at a constant rate rather than slowing as it drains. A conveyor is even more
plainly a rate device. Reaching for a potential here would be inventing physics to match a
pattern.

### 3.2 Rate as a supplement, not just a replacement

Some parts are genuinely both. The cylinder is the worked example:

- **Inlet: relaxation.** It fills toward boiler pressure at its inlet conductance, and `cutoff`
  becomes a **conductance multiplier** — which is what a cutoff valve physically is.
- **Exhaust: rate.** A piston is **positive displacement**; it sweeps its swept volume per
  revolution regardless of ΔP. Modelling that as a conductance would make a stalled engine
  unable to exhaust and a fast one unable to breathe.

So `mode:` is declared per phase per path, defaulting to relaxation for fluids and rate for
solids, and a node may override either side. This is the flexibility asked for in review — parts
add their own mechanics rather than the transport law being one-size-fits-all.

### 3.3 Hydrostatics is what makes liquids work

Revision 1 got this wrong. The reasoning that killed it — "liquids are incompressible, so
`dm/dP ≈ 0` and `pairwise`'s epsilon guard returns zero" — is only true if the potential is
*compression*. It is not. For a liquid with a free surface the potential is **depth**:

```
   m = ρ·A·h        P = ρ·g·h        =>   m = A·P/g        =>   dm/dP = A/g
```

**Independent of density**, finite, and simpler than the gas expression. Computed for the steam
engine's vessels (taking `height_m` as new config, `A = volume_m3 / height_m`):

```
vessel        V_m3  height_m   A_m2   dm/dP (kg/Pa)   vs its gas capacity
boiler         5.0      2.0    2.50   2.548420e-01        13069x larger
supply        12.0      2.0    6.00   6.116208e-01        30581x larger
condenser      3.0      1.5    2.00   2.038736e-01        13592x larger
```

Four orders of magnitude larger than the gas capacity is exactly right: it says liquid pressure
barely moves when mass transfers, which is what "nearly incompressible" *means* in this
formulation. And the boiler holding 2000 kg of water gives a depth of 0.802 m and 7848 Pa of
hydrostatic head, on top of whatever steam pressure sits above it.

Three things fall out for free:

- **Communicating vessels.** Two tanks joined at the bottom relax toward **equal levels**, not
  equal mass. That is the textbook result, emergent from the solver we already have.
- **A pressurised boiler pushes water out harder**, because the liquid potential includes the gas
  pressure above it. Gas and liquid stay coupled without a special case.
- **Hydro dams and sluice mining** run on this same law. They stop being a future rework and
  become a future *operation*.

The cost is one new config value per vessel (`height_m`) and one new derived quantity. If it ever
does become problematic it can be delegated per node via a rate-mode override (§3.2) — but on this
analysis it is the cheap half of the design, not the expensive one.

### 3.4 The capacity term is already in the codebase

`Concerns::Pressurized#gas_headroom_kg` computes `(target_pa · free / (R·T)) · M − present_kg`,
which for a single gas is **identically `(dm/dP) × (target − current)`**. Measured on a running
engine:

```
node        V_free   T_K      P_kPa   dm/dP (kg/Pa)   gas_headroom   (dm/dP)·ΔP
boiler       2.945   327.4    16.26   1.948762e-05        1.6577        1.6577   ← identical
cylinder     0.189   293.2     0.00   1.396502e-06        0.1415        0.1415   ← identical
firebox      5.993   715.8    35.94   2.916136e-05        1.8912        1.9066   ← mixture
```

**So `cap_gas_by_pressure` was already computing capacity × ΔP.** It applied it as an
instantaneous clamp — full equalisation in one tick — instead of as a rate with a time constant.
That is exactly why it behaved as an amplifier: an instantaneous equaliser sampled in antiphase
saturates, where a relaxation converges.

The change is therefore smaller than it looks. The formula moves into a `mass_capacity_kg_per_pa`
reader; the exponential comes from `Relaxation`. **`cap_gas_by_pressure` is deleted, not fixed** —
a closed form converges *on* its equilibrium, and `Relaxation#bounds` already handles the network
case the pairwise form gets wrong. The whole §4 failure class in the investigation becomes
structurally impossible.

The firebox row flags a real limitation: for a **mixture**, one scalar capacity with a mean molar
mass is an approximation (~0.8% here). Partial pressures per species would be exact; a later
refinement, not a blocker.

### 3.5 Conduits: zero-residence, still failable

| Keeps | Loses |
|---|---|
| `id`, `label`, `control_id`, ports + tag filters | `Concerns::Holds` — no `parcels`, no `volume_m3` |
| new `conductance` (kg/(Pa·s)), `head_pa`, `one_way` | `Concerns::Pressurized` — **the artifact pressure** |
| optional `rate_kg_per_s` for rate-mode phases | phase change in transit |
| `Concerns::Thermal` — wall heat capacity, ambient loss | one tick of delay per conduit |
| `Concerns::Wearing` — durability, `broken`, rupture | being an endpoint for material |
| | **`max_kg_per_s` as a universal choke** |

Keeping `Thermal` is not sentiment. The flue's `ambient_conductance: 200.0` and the hotwell's
`400.0` are load-bearing, and `loop_rig` has a `ThermalLink` to `:steam_line` that
`validate_graph!` would otherwise reject outright. A pipe has a wall; the wall exchanges with the
stream crossing it and with ambient. Heat loss becomes a function of **flow** rather than of a
standing inventory — more correct, since a chimney loses more heat when more gas is going up it.

A broken conduit sets its path conductance to zero, so a line still backs up behind a rupture
exactly as it does today.

**`max_kg_per_s` goes**, per review: conductance alone, with rate fiats where a specific part
needs one. The startup-transient worry that motivated keeping it as a choke is handled by
relaxation's own self-limiting — a closed form cannot transfer more than reaches equilibrium — and
if a specific part turns out to need a ceiling, that part declares a rate-mode supplement.

**`one_way: true` is the default.** A conduit clamps negative transfer to zero unless told
otherwise. This preserves today's directional behaviour, makes backflow an explicit modelling
decision, and means `Port#direction` and `validate_graph!`'s "no link into an outlet" rule keep
meaning what they say. Reverse flow is then a named feature — backdraught, siphoning, a failed
check valve — rather than something that happens everywhere by accident.

### 3.6 Paths, precomputed

The arbiter settles over **paths** — a real source port to a real sink port, through zero or more
conduits — not over links.

```
   today     boiler ──► throttle ──► cylinder      2 links, 2 ticks, throttle holds steam
   proposed  boiler ────[throttle]────► cylinder   1 path,  1 tick, throttle holds nothing
                           │
                           └── conductance, head, lever, wall heat, failure, one-way
```

**The graph is static, so paths are precomputed at construction** — no per-tick traversal and no
performance cost. Series combination is the usual one:

```
   conductance = 1 / Σ (1 / kᵢ)          # series resistances add
   head        = Σ headᵢ                 # pressure sources in series add
   rate cap    = min over conduits declaring one
   one_way     = true if ANY conduit on the path is one-way
```

No chains exist in the steam engine today — every conduit is a single hop — but the resolver must
handle them, and `validate_graph!` must reject a conduit ring with no working node in it, and a
conduit with more than one inlet or outlet.

### 3.7 `head_pa` — one concept, four jobs

A conduit may contribute a **pressure source in series**. This single addition covers everything
review asked for:

| Job | Head | Phase |
|---|---|---|
| **Chimney draught** | `(ρ_ambient − ρ_stream)·g·height_m` — computed, not configured | gas |
| **Fan / blower** | fixed, or scaled by a lever | gas |
| **Feed pump** | fixed, or scaled by a lever | liquid |
| **Conveyor** | n/a — rate mode | solid |

---

## 4. The consequence that reframes the firebox

**Today's firebox sits at 35.9 kPa — about 65 kPa *below* ambient.** No chimney explains that. It
is an artifact of the flue conduit actively pulling gas out regardless of pressure: a fake
draught. Under potential-driven flow that fake disappears, and if nothing replaced it the chimney
would suck air *downward*.

What replaces it is the real mechanism, and it is `head_pa`:

```
   ambient 293 K -> rho 1.2040 kg/m3
   flue  500 K -> rho 0.7059   draught over a 10 m stack = 48.9 Pa
   flue  715 K -> rho 0.4936   draught over a 10 m stack = 69.7 Pa
   flue  900 K -> rho 0.3922   draught over a 10 m stack = 79.6 Pa
   flue 1100 K -> rho 0.3209   draught over a 10 m stack = 86.6 Pa
```

**A hotter fire makes its own draught, which feeds the fire.** A genuine positive feedback loop
that real furnaces have, that a player can learn, and that the current model structurally cannot
express. It also gives the damper an honest job — restricting a flow driven by something else,
rather than being a pump. And with `height_m` as config (per review), stack height becomes a
design decision a player can tinker with: a taller chimney is a better-breathing engine.

| | today | proposed |
|---|---|---|
| firebox pressure | 35.9 kPa (unphysical) | ~1 atm less the draught (~70 Pa) |
| standing air | `0.2231 / 0.0000` alternating | ~2.6 kg, steady |
| what moves the air | the flue conduit's `pushes` | buoyancy across a stack |
| hotter fire | no effect on draught | **more draught** |

To move 4 kg/s on 70 Pa needs `k ≈ 0.057 kg/(Pa·s)` — **large conductance, small ΔP**, which is
the regime real furnace draught operates in.

An **optional blower** on the damper is the cheapest way to exercise fans immediately, and it
doubles as a genuine game mechanic: forced draught to get a cold fire going, which is exactly what
the igniter should stop having to do.

---

## 5. The extension seam — parts that add their own transport mechanics

Review named the next mechanic explicitly: **water carryover from boiler to piston**, with water
lock as a failure mode and player-operated drain valves. The architecture must not preclude it,
so the seam is designed now even though the mechanic is not built now.

Three things it needs, in increasing order of novelty:

1. **Drain valves — already free.** A drain is an ordinary path: cylinder → somewhere, liquid
   phase, with a control point. Nothing new.
2. **Water lock — already detectable.** `Cylinder#liquid_fraction` exists and is unused, with the
   comment *"the consequence is deliberately not modelled yet."* It becomes a `stress_per_second`
   or `overload?` rule. Nothing new in transport.
3. **Carryover — this is the real seam.** A boiler priming violently sends liquid water along
   with its steam.

Carryover needs one new idea: **entrainment.** Today `apportion` splits a flow across the
resources present, proportionally, filtered by both ports' tags. A steam line tagged `:gas` would
therefore refuse water outright — which is why wet steam is currently impossible.

The rule that makes it work, and which should be written down before anything depends on it:

> **A port's `accepts:` filter gates what may flow *independently*. Material entrained in a
> carrier phase rides with it regardless.**

That is physically right — a pipe does not filter droplets out of wet steam — and it is what turns
priming into a hazard that travels. The seam is a source-side hook, `entrainment(state, ctx,
phase)`, returning what the outgoing stream carries beyond its own phase. A boiler answers it from
how hard it is boiling and how high its water level is; everything else answers nothing.

**This also resolves a known gap.** "Condensate cannot leave a gas-only line" is currently listed
as unsolved with three candidate fixes. Under this design the pipe holds nothing, so the question
disappears — and where condensate genuinely matters (in the cylinder) it becomes the water-lock
mechanic instead of a bookkeeping problem.

---

## 6. Exercising all three phases immediately

Per review, gases, liquids and solids all ship in the first pass. The steam engine already has one
of each; they only need their modes made explicit, plus two small optional parts:

| Phase | Existing part | Mode | Head |
|---|---|---|---|
| **solid** | `stoker` (bunker → firebox) | `:rate` | — |
| **liquid** | `feed_pump` (supply → boiler) | `:relaxation` | **pump head** |
| **liquid** | `hotwell` (condenser → supply) | `:relaxation` | gravity (hydrostatic) |
| **gas** | `damper`, `flue`, `throttle`, `relief` | `:relaxation` | **chimney buoyancy** on the flue |
| **gas** | *new, optional* `blower` | `:relaxation` | fan head, on a lever |
| **solid** | *new, optional* conveyor variant of `stoker` | `:rate` | — |

So no new operation is needed to test the full model — the steam engine covers it, and the two
optional parts are cheap and are things a player would want anyway.

---

## 7. Sea-level changes

| # | Change | Consequence |
|---|---|---|
| 1 | **`cap_gas_by_pressure` deleted** | The amplifier ceases to exist rather than being corrected |
| 2 | **`max_kg_per_s` removed as a universal cap** | Conductance is the law; rate caps become per-part declarations |
| 3 | **Flow can reverse, but does not by default** | `one_way: true`; `Port#direction` keeps meaning what it says |
| 4 | **Vessels gain `height_m`** | Needed for the liquid capacity `A/g`. One number per vessel |
| 5 | **The cylinder's `draws` intent disappears** | `cutoff` becomes a conductance multiplier; `supplied_by: :boiler` becomes structural truth rather than a dodge |
| 6 | **The cylinder's exhaust stays a rate push** | Positive displacement. Deliberate asymmetry — comment it, do not gloss it |
| 7 | **"An active sink is authoritative about its own intake" retires** | It fixed a bug that only existed because conduits were endpoints |
| 8 | **Delay drops one tick per conduit** | Every operation gets more responsive. Accepted |
| 9 | **`total_mass` stops counting in-transit material** | Conservation still exact; absolute totals shift, so conservation specs need re-baselining |
| 10 | **Phase change no longer runs in pipes** | `run_phase_change` needs `volume_m3`; conduits stop having one, so they are skipped naturally |
| 11 | **`Sources::Level` on a conduit becomes meaningless** | `loop_rig` uses one. Replaced by §8 |
| 12 | **Gas and liquid potentials couple** | Boiler pressure pushes water out harder, with no special case |

---

## 8. `Sources::Flow`, and reading a rate where you mean a rate

A new source reading **kg/s across a conduit**, recorded into node state each tick so it snapshots
and restores like everything else. Needs a `SIGNATURES`-style entry and a row in
[`reference/diagnostics.md`](../reference/diagnostics.md).

This is the direct answer to the investigation's open question 2, and the *correct* fix for the
**Draught gauge** — which today reads an inventory when it means a rate, and can therefore only
ever say "choked". It also replaces `loop_rig`'s `Sources::Level(:steam_line)`.

**Both existing workarounds should come out, and that is the acceptance test:**

- `Filters::Average(8)` on `engine_power` and `cylinder_pressure` — should be removable outright.
  If the cylinder still needs averaging, the redesign has not worked.
- `Ignition::OXIDISER_MEMORY_PER_S` — set it to zero and see whether the fire still behaves. If it
  does, it stays only if we want it as deliberate fuel-bed inertia, with a comment saying so
  rather than the current one about oscillation.

---

## 9. Risks

1. **Determinism.** Path precomputation must not depend on hash order. `graph_spec` already
   shuffles node and link order and compares digests — run it early, not last.
2. **The mixture approximation** (§3.4) — one scalar capacity per node, ~0.8% off on the firebox.
3. **Stiff systems.** Liquid capacity is ~13,000× gas capacity. Relaxation is unconditionally
   stable so this cannot blow up, but a badly chosen conductance can make a liquid path
   *imperceptibly slow*. Expect to tune `k` per phase, and watch the feed pump specifically.
4. **The engine will not run for a while.** This touches `settle_mass`, every conduit, the
   cylinder, the relief valve, every vessel and the panel at once. Expect several rounds against a
   scratch script before any spec passes — the documented way to bring up an operation.
5. **Cold start** is where every path begins at zero potential and ΔP is briefly enormous. With
   `max_kg_per_s` gone this is the case to watch hardest.

## 10. Migration order

Staged so the engine runs again as early as possible:

1. **Paths, still rate-driven.** Conduits go zero-residence; the arbiter settles over precomputed
   paths. **The oscillation dies here** and the engine should run. Largest structural step,
   independently verifiable.
2. **Gas relaxation.** Add `mass_capacity_kg_per_pa` to `Pressurized`; delete
   `cap_gas_by_pressure`; `one_way` clamping.
3. **Liquid relaxation.** `height_m` on vessels, hydrostatic potential, gas/liquid coupling.
4. **`head_pa`** — chimney buoyancy, pump head, optional blower. §4 becomes real here.
5. **Cylinder and relief valve** onto conductance, with the exhaust kept as rate.
6. **`Sources::Flow`**, then pull both workarounds and re-point the Draught gauge.
7. **Re-measure the skill gradient** and rewrite the balance constants from scratch.

Carryover, water lock and drains (§5) are a **separate design round** after this lands.

## 11. Specs and guards

The involutory-matrix idea is sound, but the nuclear option — running the sim a thousand times
hunting attractors — is unnecessary: under relaxation the closed form *cannot* overshoot, so the
oscillation is structurally impossible rather than merely absent. Cheap, direct guards on a small
3-vessel/2-conduit rig instead:

- **No inventory alternates.** Past a settling window, the sign of successive differences must not
  flip every tick. The direct test for the failure class.
- **Steady-state delivery matches the conductance law**, not half of it. This is the test that
  would have caught the halving in the investigation's §5, and nothing today would.
- **A conduit holds nothing** — trivially true by construction, and worth asserting so that
  re-adding `Holds` to a conduit fails loudly.
- **Communicating vessels**: two tanks joined at the bottom equalise *levels*, not masses. One
  assertion that proves the whole liquid model at once.
- Conservation and determinism as they already are, re-baselined per §7.9.
