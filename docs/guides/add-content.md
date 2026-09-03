# Adding content

Substances, reactions and materials are **data**, not code: diffable, rebalanceable without a
migration, and validated at boot. `content/` is the only thing `lib/reactor_sim` reads from
disk, and only once, never during a tick.

```
content/
  resources/   water.yml, combustion.yml, materials.yml
  reactions/   combustion.yml
  minions/     crew.yml
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
```

`tensile_strength_pa` is only required on things actually used as structural materials;
asking for one that is missing raises rather than returning nil into a stress calculation.

What a spinning part cares about is the **ratio** of tensile strength to density. Cast iron
does badly on it — excellent in compression, poor in tension, which is exactly the wrong way
round for a flywheel.

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

### `rate_per_s` must suit the timestep

`extent = limit × (1 − e^(−rate × dt))`. At `rate 0.8` and `dt 0.25` only 18% of the
available reaction happens per tick — a firebox set that slow starves in the middle of a full
grate, because draught passes through faster than it can burn. Combustion wants ~6–14.

### `min_temperature_k` is not the ignition point

A node is one lumped temperature, so there is no local hot spot to light. This threshold has
to mean *"the bulk temperature at which this reaction sustains itself"*, which is well below
the temperature a match applies to a corner. Set at coal's true 700 K, a fire can never be lit
at all — the boiler drains heat faster than any plausible firelighter supplies it.

---

## A minion archetype

```yaml
fireman:
  label: Fireman
  strength: 1.0        # required
  tags: [ practised ]
```

`strength` is what a minion brings to a lever. A control point travels at
`stiffness × strength × health × (1 − fatigue)`, so the archetype sets the ceiling and the
minion's condition erodes it.

**Health and fatigue are state, not archetype.** They change during a match and live in
`state[:minions]`; strength does not and lives here. Getting that backwards would make a
worn-out minion recover on restore.

Only the actuation path is modelled. Intelligence (which would drive the gauge-reading path
through a diagnostic's `observer:`), skills, and tags like `undead` / `covetous` / `licensed`
are designed but not built — see `docs/simulation_architecture.md` §7.

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
