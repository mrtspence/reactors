# Adding content

Substances, reactions and materials are **data**, not code: diffable, rebalanceable without a
migration, and validated at boot. `content/` is the only thing `lib/reactor_sim` reads from
disk, and only once, never during a tick.

```
content/
  resources/    water.yml, combustion.yml, materials.yml
  reactions/    combustion.yml
  archetypes/   races.yml     — kinds of person
  minions/      crew.yml      — the people themselves
```

Every `*.yml` in a folder is loaded and merged, so file names are organisational only.

---

## A resource

```yaml
water:
  tags: [liquid, coolant, moderator]
  specific_heat_j_per_kg_k: 4181     # required
  density_kg_per_m3: 997             # required
  molar_mass_g_per_mol: 18.015       # required for anything tagged :gas
  formation_enthalpy_j_per_kg: 0
  phase:
    model: saturation
    vapour: steam
    latent_heat_j_per_kg: 2257000
    reference_temperature_k: 373.15
    reference_pressure_pa: 101325
```

### Tags drive everything

Ports filter on them, so tags are the compatibility system. `:gas` is **structural**, not
cosmetic — it decides whether something is limited by volume or by pressure, whether it
occupies room, and whether it can be routed through a gas-only port. Tag a gas `:gas`.

The vocabulary is **open** and grows with the content, so the list below is a snapshot rather
than the contract. Derive the current one:

```sh
grep -h "tags:" content/resources/*.yml | tr -d '[]' | cut -d: -f2 | tr ',' '\n' | tr -d ' ' | sort -u
```

In use at the time of writing: `bearing`, `coolant`, `exhaust`, `fuel`, `gas`, `liquid`,
`metal`, `moderator`, `oxidiser`, `solid`, `structural`, `waste`, `working_fluid`.

A tag is a vocabulary shared between the content files and every port that filters on one, so
**introducing a tag means updating this list in the same commit**. An undocumented tag is a
word only its author knows, and the next person writes a near-synonym instead.

### Phase pairs

Declare `phase:` on the **liquid**. The registry indexes the pair from both sides, so
`content.phase_pair(:steam)` finds it too — a condenser holding nothing but vapour has no
liquid parcel to discover the pair from.

**The formation enthalpies must encode the latent heat.** The gap between the pair at the
reference temperature *is* the latent heat:

```
h_water(373.15) = 4181 × 373.15 + 0          = 1_560_144
h_steam(373.15) = 2010 × 373.15 + 3_067_108.65 = 3_817_144
difference                                    = 2_257_000  ✓
```

Get this wrong and boiling and condensing stop being each other's inverse — energy leaks
across every phase change in the game. `spec/reactor_sim/content_spec.rb` asserts it.

---

## A material

Materials are resources too, so a foundry could one day produce them.

```yaml
cast_iron:
  tags: [solid, metal, structural]
  density_kg_per_m3: 7200
  specific_heat_j_per_kg_k: 460
  tensile_strength_pa: 150.0e6
  max_temperature_k: 800
```

`tensile_strength_pa` is only required on things actually used as structural materials;
asking for one that is missing raises rather than returning nil into a stress calculation.

What a spinning part cares about is the **ratio** of tensile strength to density. Cast iron
does badly on it — excellent in compression, poor in tension, which is exactly the wrong way
round for a flywheel.

`max_temperature_k` is where the metal **stops being structural**, not where it melts — steel
melts near 1700 K and is useless as a pressure boundary by 900. A part gets it by declaring
`material:`, and `Concerns::Thermal#rated_temperature_k` resolves an explicit
`max_temperature_k:` on the part first, so a water-cooled wall can still be special.

> **Rate every `:structural` material, and `content_spec` insists.** `Content#max_temperature_k`
> returns infinity for a resource that declares none — right for coal and steam, and a silent
> off switch for anything a boiler is built from. Over-temperature fatigue existed in `Vessel`
> and `Conduit` from the day `Wearing` landed and **had never once fired in any operation**,
> because every node shipped the infinite default. Nothing failed and nothing warned.

**Safety factors do not belong here.** How far below the ideal figure a real part fails
depends on casting quality and geometry — properties of the part. They go on the node.

---

## A reaction

```yaml
coal_combustion:
  consumes: { coal: 1.0, air: 11.0 }
  produces: { flue_gas: 11.9, ash: 0.1 }    # 12.0 = 12.0
  enthalpy_j_per_unit: -30000000            # negative = exothermic
  rate_per_s: 6.0
  min_temperature_k: 500
```

All four keys except `min_temperature_k` are required.

### Mass must balance

`consumes` and `produces` ratios must sum to the same number. `Content` refuses to load a
reaction where they do not — an unbalanced reaction would create matter every time it fired,
from inside a data file where nobody would look when conservation started failing.

### `enthalpy_j_per_unit` is per unit of *extent*

One unit of extent consumes the whole `consumes` set — for coal, 1 kg of coal plus 11 kg of
air. **It must also absorb any formation-enthalpy difference between the two sides.** The
stoichiometry itself conserves enthalpy exactly (products inherit what the reactants had,
split by mass), so this is the only place a reaction may change the system's energy.

### `rate_per_s` must suit the timestep — and it means something different once a reaction ignites

`extent = limit × (1 − e^(−rate × dt))`.

Without an `ignition:` block, `limit` is the available reagents, so this is "how much of what
is present reacts per second" and it wants to be **high**: at `rate 0.8` and `dt 0.25` only 18%
happens per tick, and a firebox set that slow starves in the middle of a full grate because
draught blows past unreacted.

**With `ignition:`, `limit` is capped by the mass actually alight, so the same number becomes
"how fast lit fuel is consumed" — and it wants to be far lower.** Coal was left at `6.0` across
that change, which meant 78% of the fire vanished every tick; the lit mass could never
accumulate, and `oxidiser_demand` (derived from the same rate) then asked for a kilogram of air
per tick to sustain a 0.12 kg fire. The whole engine read as air-starved.

It is also **sharply peaked rather than forgiving** — too slow and the fire cannot outpace the
boiler draining it, too fast and the lit mass outruns `spread_per_s` and goes out. Coal's
plateau is 1.5–2.0 and both edges are outright failures. Measurements are in
[`content/reactions/combustion.yml`](../../content/reactions/combustion.yml).

**Re-measure it whenever you change `spread_per_s`, `quench_per_s`, or the firebox geometry.**

### `ignition:` makes a fire something you light

```yaml
  ignition:
    spread_per_s: 0.30   # how fast burning fuel lights its neighbours
    quench_per_s: 0.45   # how fast it dies when cold or starved of air
```

**Opt-in.** A reaction without this block keeps the old bulk-temperature gate and behaves
exactly as before, so adding it to one reaction cannot disturb another.

With it, the reaction carries how much of its fuel is alight and only that portion burns. The
fuel is inferred from the `:fuel` tag, so nothing has to be declared twice. See
[`../reference/physics.md`](../reference/physics.md#ignition).

**Set `quench_per_s` above `spread_per_s`**, or a cold box can never put a fire out — at
equilibrium the two balance, and a fire settles where its draught can support it.

### `min_temperature_k` is not the ignition point

A node is one lumped temperature, so there is no local hot spot to light. This threshold has
to mean *"the bulk temperature at which this reaction sustains itself"*, which is well below
the temperature a match applies to a corner. Set at coal's true 700 K, a fire can never be lit
at all — the boiler drains heat faster than any plausible firelighter supplies it.

---

## An archetype, and an individual

**A minion is a person; an archetype is what kind of person they are.** One table held both for a
release, under the names `fireman` and `yardhand` — which are *jobs an operation asks for*, not
kinds of person. The same person can do either, which is what made it the wrong noun.

```yaml
# content/archetypes/races.yml — layer one, the baseline for everyone of that race
elf:
  label: Elf
  strength: 0.75       # all five stats are required
  toughness: 0.7
  intelligence: 1.25
  dexterity: 1.2
  charisma: 1.1
  tags:
    darkvision: 0.3

# content/minions/crew.yml — layer two, who they are, written as OFFSETS
galathas:
  name: Galathas        # required — a name is what separates a person from a race
  archetype: elf        # required, and checked at boot
  stats:
    strength: 0.35      # strong for an elf…
    dexterity: -0.25    # …and heavy-handed with it
  tags:
    clumsy: 0.2
```

Omit a stat to take the race's figure unchanged; omit `stats:` entirely for somebody unremarkable.

There are four layers — **archetype → individual → training → equipment** — and each offsets the
last. Only the first two are content: training and equipment are things a player *owns*, and the
simulation is not allowed to know what a player is. `Content::Registry#sheet(id)` returns the first
two already folded.

Rules worth knowing before you add one:

- **The five stats are fixed and every archetype declares all of them.** The engine reads them and
  needs a number rather than an absence. `strength` drives actuation today, `toughness` drives the
  Danger Check; the other three are declared and read by nothing yet.
- **`dexterity` does not replace `clumsy`.** How finely somebody works and how often they drop
  things are two different statements about one person, and a steady-handed worker who knocks
  things over is a real person.
- **Minion tags are a MAP, not a list.** Resource tags are flat — a thing is `:liquid` or is not —
  but "how well can you see in the dark" has a number for an answer. Write `true` for a trait that
  is simply present.
- **Values add across layers and are then clamped; consumers multiply what they read.** Merge
  adds, use multiplies. Getting this the other way round makes every piece of kit a rounding error.
- **Health, fatigue, station and injury are state, not content.** They change during a match and
  live in `state[:minions]`; stats do not and live here. Backwards, and a hurt minion recovers on
  restore.

The gauge-reading path (a diagnostic's `observer:`) is reserved and read by nothing — see
`docs/simulation_architecture.md` §7.

---

## Validation and testing

`Content::Registry` validates eagerly at boot and raises `ReactorSim::Error` with the
offending id. A typo is otherwise a nil surfacing mid-match.

For specs, build a registry in memory and inject it — no filesystem, and it exercises the
injection seam:

```ruby
inert = ReactorSim::Content.build(resources: {
  brine: { tags: [ :liquid ], specific_heat_j_per_kg_k: 3900, density_kg_per_m3: 1100 }
})
Operation.new(..., content: inert)
```

Useful for isolating behaviour: a substance with no `phase:` cannot boil, so nothing can turn
into anything else while you test something unrelated.
