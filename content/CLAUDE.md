# `content/` — substances, reactions, materials and crew as data

Data, not code: diffable, rebalanceable without a migration, validated at boot. This is the
**only** thing `lib/reactor_sim` reads from disk, and only once — never during a tick. Guide:
[`docs/guides/add-content.md`](../docs/guides/add-content.md).

Every `*.yml` in a folder is loaded and merged, so file names are organisational only.

## Tags drive everything

Ports filter on tags, so tags are the compatibility system. **`:gas` is structural, not
cosmetic** — it decides whether something is limited by volume or by pressure, whether it
occupies room, and whether it can be routed through a gas-only port. Tag a gas `:gas`.

The tag vocabulary is **open** — it grows with the content, so any written list of it is a
snapshot rather than the contract. Derive the current one:

```sh
grep -h "tags:" content/resources/*.yml | tr -d '[]' | cut -d: -f2 | tr ',' '\n' | tr -d ' ' | sort -u
```

At the time of writing: `bearing`, `coolant`, `exhaust`, `fuel`, `gas`, `liquid`, `metal`,
`moderator`, `oxidiser`, `solid`, `structural`, `waste`, `working_fluid`.

**Adding a tag means updating this list and
[`docs/guides/add-content.md`](../docs/guides/add-content.md) in the same commit.** A tag is a
vocabulary shared between content and every port that filters on it, so an undocumented one is
a word only its author knows.

## Phase pairs: the formation enthalpies must encode the latent heat

Declare `phase:` on the **liquid**; the registry indexes the pair from both sides. The gap
between the pair at the reference temperature *is* the latent heat:

```
h_water(373.15) = 4181 × 373.15 + 0             = 1_560_144
h_steam(373.15) = 2010 × 373.15 + 3_067_108.65  = 3_817_144
difference                                       = 2_257_000  ✓
```

Get this wrong and boiling and condensing stop being each other's inverse — energy leaks
across every phase change in the game. `spec/reactor_sim/content_spec.rb` asserts it.

`molar_mass_g_per_mol` is required for anything tagged `:gas`.

## Reactions: mass must balance, and three dials are easy to get wrong

```yaml
coal_combustion:
  consumes: { coal: 1.0, air: 11.0 }
  produces: { flue_gas: 11.9, ash: 0.1 }   # 12.0 = 12.0
  enthalpy_j_per_unit: -30000000           # negative = exothermic
  rate_per_s: 6.0
  min_temperature_k: 500
```

`Content` **refuses to load** a reaction whose `consumes` and `produces` ratios do not sum to
the same number — an unbalanced reaction would create matter every time it fired, from inside
a data file where nobody would look when conservation started failing.

- **`enthalpy_j_per_unit` is per unit of *extent*, not per kilogram.** One unit consumes the
  whole `consumes` set. It must also **absorb any formation-enthalpy difference between the
  two sides** — the stoichiometry itself conserves enthalpy exactly, so this is the only place
  a reaction may change system energy.
- **`rate_per_s` must suit the timestep.** `extent = limit × (1 − e^(−rate × dt))`. At rate 0.8
  and dt 0.25 only 18% of the available reaction happens per tick, so a firebox starves in the
  middle of a full grate. Combustion wants ~6–14.
- **`min_temperature_k` is not the ignition point.** A node is one lumped temperature, so there
  is no local hot spot to light. It means *"the bulk temperature at which this reaction
  sustains itself"*, well below the temperature a match applies to a corner. Set at coal's true
  700 K, a fire can never be lit at all.

## Materials

Materials are resources too, so a foundry could one day produce them. `tensile_strength_pa` is
required only on things actually used as structural materials; asking for a missing one raises
rather than returning nil into a stress calculation.

What a spinning part cares about is the **ratio** of tensile strength to density.

**Safety factors do not belong here.** How far below the ideal figure a real part fails depends
on casting quality and geometry — properties of the part. They go on the node.

## A minion archetype

```yaml
fireman:
  label: Fireman
  strength: 1.0        # required — actuation rate at full health
  tags: [ practised ]
```

`strength` is what a minion brings to a lever: a control point travels at
`stiffness × strength × health × (1 − fatigue)`, so the archetype sets the ceiling and the
minion's condition erodes it. **Health and fatigue are state, not archetype** — they change
during a match; strength does not.

`REQUIRED_MINION_KEYS` is `label` and `strength`. Only the actuation path is modelled today;
intelligence (which would drive the gauge-reading path through a diagnostic's `observer:`),
skills, and tags like `undead` / `covetous` / `licensed` are designed but not built.

## Validation and testing

`Content::Registry` validates eagerly at boot and raises `ReactorSim::Error` naming the
offending id, because a typo is otherwise a nil surfacing mid-match.

For specs, build a registry in memory and inject it — no filesystem, and it exercises the
injection seam:

```ruby
inert = ReactorSim::Content.build(resources: {
  brine: { tags: [ :liquid ], specific_heat_j_per_kg_k: 3900, density_kg_per_m3: 1100 }
})
Operation.new(..., content: inert)
```

A substance with no `phase:` cannot boil, so nothing turns into anything else while you test
something unrelated.
