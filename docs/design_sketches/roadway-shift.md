# The roadway shift, and a refuge at the pit bottom

> **Status: agreed 2026-10-16 and built — see §6.** Raised in review on 2026-10-16. The district already starts with
> three hands; the roads need the same, a way to buy more of them, and somewhere for them to rest
> that is not a walk to bank.

---

## 1. What exists

- **`Mine::ADVANCE_SHIFT`** — `{ seats: 3, place: :district }`, declared on both chassis, so the
  last three seats start in the district posted to nothing. Its `TODO:` says it belongs on a part
  the blueprint tree sells — "a night shift, a lodging house, an underground stable". This is that
  change.
- **The roadway's work is posted at the pit bottom**: putting (`haulage`), the onsetter and the
  trapper. There is no separate "roadway" place; the haulage road is the passage between the pit
  bottom and the district, and its people stand at the pit bottom.
- **`refuge_hole`** — the starting rest station: a `rest` post in the district, room for one, 1.4×
  recovery. The `snap_cabin` upgrade takes three at 2.4×. Nothing underground lets a roadway hand
  rest without walking to bank.
- **The stand-ins' kit already exists and is working.** Equipment bought against `kobold_temp` is
  the pit's rack, issued by `DevMatch.issue_kit` to every unfilled seat; the crew screen's labour
  exchange section chooses it. The dev player owns all of it, and the stored roster already issues
  **miner's tools and a Davy lamp** — measured on the built crew: pick 0.8, darkvision 1.0. Nothing
  to build there; §5 says what was checked.

## 2. The design

**Two shift slots, each fitted with the arrangement that decides how many start there.**

| Slot | Default (free) | Upgrade |
|---|---|---|
| `face_shift` | `advance_shift` — 3 in the district | — |
| `roadway_shift` | `roadway_shift` — 3 at the pit bottom | `underground_stable` — 5 at the pit bottom |

The upgrade is the historical one: ostlers and pony lads who lived below with the ponies and were
at the pit bottom before the first cage came down. A part declares `stats: { advance_seats:,
advance_place: }`, and `Assembly#advance_shifts` reads them off what is fitted — the same shape as
`crew_capacity` off the quarters. The chassis stops declaring `advance:`.

**Seats are dealt from the end of the roster, face first.** The district takes the last seats, the
roadway the ones before, and bank keeps the first — so a roster filled from the top still has its
named hands at bank. A quarters too small for both is dealt face first and then roadway, never
more than it holds, exactly as today's single shift is.

**A refuge at the pit bottom**: `pit_bottom_refuge`, a `roadway_rest` post at the pit bottom, room
for one at 1.4× — the refuge hole's twin, in its own slot (`roadway_rest`), fitted by default. Its
own post id, because two rest stations cannot share `:rest`.

## 3. Blueprints

All four new parts are blueprints by derivation. The two defaults are free (`materials: {}`); the
stable is priced in `config/blueprints.yml` (first figure: wrought iron 4, steel 1 — stalls and a
pump for the water). The refuge is free, as the refuge hole is.

## 4. Questions for review

1. **"The roadway" is the pit bottom.** Recommend: the posts are there and so is the haulage road's
   end. A separate roadway place would split the main road passage for no change in what anybody
   does.
2. **Both shifts as parts** (the district's too, which closes its `TODO`), against leaving the
   district on the chassis and adding only the roadway. Recommend both — one mechanism.
3. **The upgrade's size: five.** With the lamp cabin's ten seats that is eight underground and two
   at bank.
4. **The refuge: weak only for now**, no roadway snap cabin. Recommend; a cabin is a second line
   when somebody wants it.

## 5. The stand-ins' kit, checked

Owned by the dev player: every `kobold_temp/*` equipment blueprint, `crude_miners_tools` and
`miners_tools` among them. The stored roster's labour exchange issues `miners_tools` and
`davy_lamp`, and `DevMatch.reset_command` carries them into every one of the ten seats. Built, a
stand-in has `mining_effectiveness` 0.8 and `darkvision` 1.0 — a working hewer.

## 6. As built

Review took every recommendation, and **added an upgrade for the face as well**. So there are four
shift parts, two in each slot:

| Slot | Free | Upgrade |
|---|---|---|
| face | `advance_shift`, 3 | `back_shift`, 5: the night's hewers still at the face when the day comes down |
| pit bottom | `pit_bottom_shift`, 3 | `underground_stable`, 5 |

The refuge is `pit_bottom_refuge`, a `pit_bottom_rest` post, priced as the refuge hole is (wood
90). The upgrades' bills are first figures: wood 260 and wrought iron 40 for the back shift, wood
420 and wrought iron 60 for the stable.

**With both upgrades on the lamp cabin's ten seats, nobody starts at bank.** Seats are dealt face
first and never past the roster. That is what the deal says, and the player fits the pit-head
baths' fourteen to keep four at bank.

**The pit rig leaves the pit bottom shift unfitted unless asked.** Its hands and its engineman
fill the first seats, so the shift would deal the winder's man underground in every example that
rides the cage. Where the crew starts is the rig's to lay out, the same way `at_the_face`
constructs arrivals. `shifts_spec` fits the shift and covers it.
