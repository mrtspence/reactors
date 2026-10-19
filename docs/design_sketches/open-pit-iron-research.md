# Open-pit iron ore: research

Status: research only, awaiting review. Input to the design sketch for the next operation, an
open-pit hematite or limonite mine. Nothing here is designed or built.

This document covers how such mines worked from about 1800 to about 1914: work arrangements,
extraction, logistics and hazards, and how each would meet the systems the sim already has.

**How figures are marked:**
- Figures with a source are cited (list at the end).
- Figures marked **[gk]** are general knowledge that was not re-checked during this research.
  Treat them as unverified until a design sketch relies on one.
- Imperial units are kept where the source used them, with metric conversions in the
  "sim-scale" notes.

---

## 1. Which ore, and which mine

### 1.1 The two ores

| | **Hematite** (Fe₂O₃) | **Limonite / brown ore** (FeO(OH)·nH₂O, goethite family) |
|---|---|---|
| Pure Fe | 69.9 % [gk] | 59.89 % for "pure limonite" (Prime 1875) |
| Shipped grade | Mesabi Bessemer base 55 % natural Fe; non-Bessemer base 51.5 % (Crowell & Murray 1911). Bilbao *vena* about 58–61 %, *campanil* about 55–56 % (hobbyist source; treat as approximate) | Lehigh assays ran 32.7–58.5 % Fe, mostly 43–52 %. Insolubles were 3–39 % (Prime 1875). Bilbao *rubio* about 53 % |
| Phosphorus | The point of the trade. Bessemer ore must not exceed 0.060 % P (Crowell & Murray). Bilbao and Cumbria were valued for being low-P | Usually high: 0.04–0.6 % P at Lehigh, which makes it non-Bessemer, foundry or forge ore |
| How it occurs | Massive or soft beds. Mesabi ore is "mostly soft, hydrated hematite, although some limonite is found" (Crowell & Murray). Cumbria has replacement bodies and "sops" in limestone (BGS) | Lumps, "pipe" and "pot" ore and "wash ore" scattered through clay. Seams "suddenly stop" (Prime) |
| Density | About 5.26 g/cm³ solid [gk] | About 3.6–4.0 g/cm³ solid [gk] |
| Needs | Stripping, breaking (blasting) and loading. Drying when wet (Mesabi ore ran 18–20 % moisture) | Digging, then **washing** the clay off, which needs a lot of water. Often **calcining** to drive off combined water |
| Era fit | Mostly late tier: the steam-shovel pits of the 1890s on | Every tier: bog ore from colonial times, hand-dug banks from the 1840s to 1880s, washers from 1842 |

**Why "either" is a real choice and also a false one.** Real ore bodies mix the two. Mesabi
soft hematite carries limonite. Bilbao moved from hematite (*vena*, *campanil*) to brown ore
(*rubio*, about 90 % of output by 1905) and carbonate as the rich ore ran out (Glückauf, via
search). A deposit with a hematite core inside limonite and clay gives the game an ore that
changes character as the pit deepens. That is a natural progression lever, and it lets washing
and calcining matter for some benches and not others.

### 1.2 Reference mines

| Region | Ore | Period | Character | Most useful for |
|---|---|---|---|---|
| **Lehigh Valley, Pennsylvania** brown-ore banks | Limonite | 1840s–1890s | Farm-scale open pits, 5–75 ft deep, hand-dug by 10–30 "men and boys", horse-carted to log washers. Pits flood and their walls slump | Early and mid tier, washing, water, small crews |
| **Centre and Huntingdon counties, Pennsylvania** | Limonite | 1850s–1890s | Open cuts plus shafts. Irish labourers "paid by the ton". Water "invariably stopped them" | Piecework, flooding |
| **Virginia and Alabama brown-ore districts** | Limonite | 1880s–1910s | Virginia led US limonite output 1890–1901. Russellville, Alabama, ran over 100,000 tons a year, with washers and tailings ponds | Later washing practice |
| **New Jersey and Virginia bog ore** | Limonite | 1700s–about 1850 | Dug from swamp edges for charcoal furnaces. Low grade, small quantities | Tier 0 flavour, possibly too small to model |
| **Northamptonshire and Oxfordshire ironstone** | Oolitic ironstone, closer to limonite or siderite | 1850s–1960s | Shallow quarries worked by hand ("barrow and plank"): overburden wheeled away over planks on trestles, ore thrown up into standard-gauge wagons from the quarry floor. Pay measured weekly per man. Steam navvies came only about 1915; one pit stayed hand-dug until 1964 | Hand tier, the face-and-gullet layout, calcining clamps |
| **Bilbao and the Triano mountains, Vizcaya** | Hematite, then *rubio* | about 1865–1914 | Hillside open-casts (*cortas*). Peaked at about 6 Mt in 1899. Mostly exported to Britain for Bessemer steel. Rail and inclines to riverside loading staithes, plus aerial ropeways. Women carried ore baskets. Barracks and truck-shop canteens. 1890 strike | A hillside pit that drains by gravity, inclines and ropeways, export, labour unrest |
| **Mesabi Range, Minnesota** | Soft hematite | 1892–1914+ | First ore shovel at Biwabik in 1892. Mahoning stripped by hand gangs in 1891 and by shovels from 1895. Pits 75–150 ft deep, benches 25–30 ft, 4–5 t of overburden stripped per t of ore. Standard-gauge rail into the pit | Late and Edwardian tier, shovels, rail, stripping economics, winter |
| **Iron Mountain and Pilot Knob, Missouri** | Hematite | 1830s–1920s | A surface hematite mine from the 1830s; Iron Mountain mined into the 1960s | A long-lived US hematite open cut |
| **Cumbria and Furness** | Hematite | 19th century | Mostly **underground** (Hodbarrow and others). Notable for sea inrushes at Hodbarrow, which the sea breached in 1885 and 1898 before the Outer Barrier of 1900–05 | Mainly as a contrast. "Red lung" belongs to the 1920s and 1930s, after percussion drills |
| **Kiruna, Sweden** | Magnetite and apatite (not hematite) | 1898–1952 open-cast | Steam excavators struggled in the cold. Real mechanisation came only with electric machines in the 1910s. Eight electric shovels arrived 1914–16 | Edwardian electric shovel, polar winter |

---

## 2. How the ore was got: method by era

### 2.1 Hand banks and quarries (about 1800–1890, and later in Britain)

- **Tools:** pick and shovel. At Lehigh, "gunpowder was never needed for the clay or soft
  slate" (Prime). Wherever the ore was hard or cemented, black powder was used in hand-drilled
  holes.
- **Layout:**
  - **The pit (Lehigh).** It advances as an open hole. A ramp road is left so that horses and
    carts can climb out. Lean ore is left standing unless paying ore lies beneath it. The
    Thomas Iron Co. took everything out, ore and barren clay alike, to even out its costs.
  - **The face (Northamptonshire).** A long face moves across the field. Overburden is cast or
    wheeled back over the worked-out ground, which leaves "hill and dale" spoil.
- **Overburden depth worked by hand:** "a foot or two" up to 40–50 ft at Lehigh. Up to about
  20 ft at Spratton.
- **Hoisting out of the pit:**
  - **Inclined planes** were the only lifting method Prime names (Barber, Breinig, Wiand,
    Schwartz & Fogel).
  - Horse whims hoisted from shafts sunk off the pit floor. West Pennington had "an old whim
    shaft" (Lesley).
- **Output per man.** These are washed ore per crew-day, from Prime's mine-by-mine notes:

  | Mine | Output | Crew |
  |---|---|---|
  | Ludwig, Hertzog & Liess | 20 t/day | 20 men |
  | Kreischmann | 15 t/day | 18 men, 3 boys |
  | Wiand | 20 t/day | 12 men |
  | Breinig | 20 t/day | 20 men and boys |
  | Gackenbach | up to 1,300 t/month | 30 men and boys |

  - **About 1 t of washed ore per worker per day is the norm.** Lesley converts 3 yd³ of
    ore-bearing ground to 1 t of washed ore, so each worker digs and moves roughly 3 yd³ (about
    2.3 m³) a day.
  - For comparison, a railway navvy filled seven 2¼-yd³ wagons a day, lifting about 20 t
    (Victorian Web). That is the upper bound for pure shovelling in loose earth.
- **Sim-scale:**
  - 1 t a day over a 10-h shift is about 0.03 kg/s of product per worker. The navvy's 20 t a
    day of shifted earth is about 0.55 kg/s.
  - For comparison, the colliery's `hand_picks` cut 1.4 kg/s per face.
  - A hand bank is therefore a **crew-throughput** operation, like hand putting, not a machine
    one.

### 2.2 Washing: limonite's defining process

- **The log washer.** Invented about 1842 (Valentine paper abstract). Prime describes the
  two-shaft "Thomas washer" of the 1870s:
  - Two shafts 20–24 ft long carry angled teeth, set with a rise of 12–14 in over their length.
  - One shaft is steam-driven through an endless chain, the other through gearing.
  - Ore is dumped in at the low end, and the teeth carry it upward over a sieve.
  - Water comes from a perforated wooden gutter. The clay slurry floats off to a **mud-dam on
    trestles**.
  - The washer stands 10–20 ft up.
  - Output was **15–35 t/day, typically 20–25**.
  - Sticky clay rolls into fist-sized balls. Some teeth were reversed to slow the ore so the
    clay had longer to cut.
- **The single-shaft washer** came first and was "almost entirely replaced" by the two-shaft
  type by 1875.
- **The Bradford washer** used a rotary sieve and then a **jig**, which separates by specific
  gravity, with self-acting rakes skimming off slate and flint.
- **Water.** Washers had to stand by a stream or raceway (Valentine). The artesian wells
  introduced in 1865 let washeries be built away from streams. The settling ponds survive as
  large clay deposits (Lower Macungie).
- **Sorting at the head.** Ore was tipped onto a **grizzly**, a bar screen. Lumps went straight
  to the furnace and the fines went through to the washer (Valentine).
- **Sim-scale:**
  - 20–25 t/day is about 0.6–0.7 kg/s of washed ore per washer. With roughly 3 m³ of ground
    per tonne, that means about 2 kg/s of muck going in.
  - Water use is not in the sources read. Modern log washers suggest several tonnes of water
    per tonne of ore **[gk]**. Treat the figure as open.

### 2.3 Calcining (roasting)

- **What it does.** Calcining drives off combined water from limonite, CO₂ from siderite
  ("carbonato"), and some sulphur. That cuts the **weight to be carried**. Rosedale ore was
  calcined because railway tolls were paid by the tonne carried (Hoole, via Wikipedia).
- **Clamps.** Open heaps of ore interbedded with small coal (Warren Moor, Cleveland, 1865).
  Later Northamptonshire clamps held up to 30,000 t each (Nassington, 1941).
- **Kilns.** Cleveland and Rosedale shaft kilns, now a scheduled monument. Bilbao carbonate ore
  cost about 3s per ton to calcine.
- **Chemistry [gk]:**
  - Goethite → hematite + H₂O at about 250–400 °C. This is endothermic.
  - Siderite → FeO + CO₂, oxidising to hematite, at about 400–550 °C.
  - Brown ore loses roughly 10–14 % of its mass as water, siderite about 30 % as CO₂.
- **Fuel ratio.** No sourced coal-per-ton figure was found, so it stays open.

### 2.4 Stripping and the steam shovel (1880s–1914)

- **Sequence on the Mesabi:**
  1. Hand stripping with shovels and wheelbarrows (the R. B. Dear gang at Mahoning, 1891).
  2. Teams, scrapers and wagons.
  3. Teams with 1-ton side-dump cars.
  4. Steam shovels, because "hand stripping was too slow".
- **The shovel arrives.**
  - The first ore shovel went to Biwabik in 1892, shipped in parts and dragged in by horse and
    man. A 27-ton machine followed in 1893 (Marsh).
  - Bucyrus first shipped to mining companies in April 1890, to the Michigan iron country.
  - Mahoning had 2-yd³ shovels by 1895.
- **The railroad-type shovel** (Herman 1894; Marsh 1920):
  - **Mounting.** The machine sits on a flat car and swings only about 180–260°. It moves up on
    4-ft track sections dragged from the back to the front.
  - **Moving up** takes 3–10 minutes, with no loading meanwhile. Pit track is extended a rail
    length at a time.
  - **Boiler.** Upright, worked at 90 psi with the safety valve at 120 (1894), and about 125
    psi later. The 1,000-gal tank lasts half a day. A Mesabi shovel used 12,000–15,000 gal of
    water and 5 gal each of black oil and cylinder oil per 24 h.
  - **Drive.** The hoisting drum is the most stressed part. Friction clutches overheat. Iron
    chains were preferred to steel because steel chains "suffered rapid wear and frequent
    breakages".
  - **Output per 10-h day, 2¼-yd³ dipper:**

    | Material | Output |
    |---|---|
    | Loose gravel | 1,800 yd³ (best about 2,400) |
    | Dry clay | 1,350 yd³ |
    | Damp clay | 900 yd³ |
    | Hardpan after blasting | 450 yd³ |

  - **Cycle time.** 30–45 s in gravel, 1.5–2 min in hard ground.
  - **Ore output.** 1,500–2,000 t of ore per shovel per day in the Lake Superior pits.
  - **Sizes.** By 1917, ¾–8 yd³ dippers and 25–135-ton machines.
- **The crew.** Herman (1894) and Marsh's Mesabi crew of 1915 agree:

  | Role | Duty | Mesabi wage, 1915 |
  |---|---|---|
  | Engineer ("runner") | Hoist, swing and travel | $5.77 per 10-h day plus bonus |
  | Craneman | Depth of cut; trips the dipper door over the car | $4.04 |
  | Fireman | The boiler | $2.50 |
  | 4–7 pitmen | Clear spill, level, lay and shift track, set jacks and blocking | $2.35 |

  In harder ground the crew adds 2–6 men to bar down overhangs and drill shots. Large jobs add
  a blacksmith, a helper and 2–5 car repairers.
- **Revolving shovels.**
  - The first "full-swing" machine was English (1884). Whitaker and Wilson built revolvers for
    the Manchester Ship Canal (1888–94).
  - Ruston No. 6 revolvers date from 1909. Large revolving stripping shovels ran to 95–325 t
    with 1.5–8-yd³ dippers by the 1910s.
- **Electric shovels.**
  - A 100-C cost $20,500 in 1915, about a third more than the steam version.
  - At 1 c/kWh it ran for $32.60 a day against $44.50 coal-fired.
  - Repairs were about two-thirds those of steam.
  - Kiruna took eight in 1914–16.
- **Draglines.** Page, 1904 [gk]. Used for stripping at the Balkan mine, Michigan.
- **British steam navvies.** Dunbar–Ruston from 1874–75. The Manchester Ship Canal bought 57
  Ruston excavators. Northamptonshire adopted them late (1915 at Lowick and Park Farm).

### 2.5 Benches, slopes and pit geometry

- **Bench height.**
  - Mesabi preferred 25–30 ft; copper pits 45–60 ft.
  - Under 12 ft is uneconomic, because the shovel spends its time moving up. Over 75 ft is
    hard to control.
  - For a railroad shovel, the ideal bank is the horizontal distance from the track centreline
    to a point 6 ft above rail: 60 ft for a 100-C.
- **Repose.** Broken material lies at about 1½:1 and blasted rock at about 2:1. Slopes are
  about 1:1 for clayey earth, 1½–2:1 for sand, and vertical for rock taken in a single cut
  (anthracite).
- **Benches and berms.** Working benches are rarely under 50 ft wide. Safety berms are 20–30 ft.
- **Depth and stripping.**
  - Mesabi pits were 75–150 ft deep. Stripping 4–5 t of overburden per ton of ore was economic.
  - Marsh's worked planning example uses 2 yd³ of overburden per ton of ore.
  - The Alpena mine ran about 1 yd³ per ton.
- **Haul grades.**
  - Permanent pit approaches stay at or under 2 % compensated, 2½–3 % at most. Grades of 5–7 %
    are used only on very short runs.
  - Curves are 10° at most by preference and 20° allowable, although 50° curves sometimes
    cannot be avoided in the pit.
  - Getting out of a deep pit therefore needs **switchbacks** (Agnew had four) or an
    **incline**. Anthracite hoisting planes ran at about 20°, with 150 cars a day on single
    track and 300 on double.
- **Hillside versus sunk pit.**
  - Bilbao and Northamptonshire worked hillsides and shallow faces. Spoil goes downhill and
    water drains by gravity.
  - Lehigh and the Mesabi were sunk below the surrounding ground, so they need hoisting or
    inclines and **pumping**.
  - This one geographic choice decides most of the logistics.

### 2.6 Drilling and blasting

- **Hand drilling.** Jumper top holes 15–20 ft apart, about 22 ft deep at most, about 50 ft per
  man per day. A 15-ft hole took 2–6 sticks of 60 % dynamite to "spring" it, then 1–1½ 25-lb
  kegs of black powder. Up to five holes were fired in series.
- **Gopher holes on the Mesabi.**
  - Earlier man-sized holes "caused frequent accidents"; by 1920 they were about 15 in across.
  - Gangs were 10–30 labourers working in pairs. Holes were 15–25 ft deep at 15–25 ft spacing
    and took 2–12 h each.
  - Charge: 15–25 sticks to spring, then 5–10 kegs of black powder. Fired in sets of 3–5.
- **Machine drills.**
  - Tripods for 10–25-ft holes. The Mesabi D-113 drilled about 90 ft per shift with two men.
  - Churn drills were used above 25-ft faces. They made 20–60 ft per shift, with a driller and
    a tool-dresser per drill.
- **Powder factors.** About 0.3–0.7 lb of 40 % dynamite per yd³, roughly 4–6 t of rock per
  pound of explosive.
- **Firing.** At least two detonators per hole. Parallel firing needs ½ A per detonator, series
  firing 2 A per series.
- **Delays.** Blasting takes about 6 % of operating time (Marsh) and 8 % at Chuquicamata.
- **Explosives chronology [gk]:**
  - Black powder: throughout.
  - Dynamite: Nobel 1867.
  - Gelignite: 1875.
  - Electric blasting caps: widespread from the 1880s–90s.
  - Burleigh air drill: about 1866–70.
  - Ingersoll and Rand drills: 1870s–80s.

### 2.7 Haulage: from the face to the furnace

| Stage | Early | Mid | Late / Edwardian |
|---|---|---|---|
| Face to the pit's edge | Barrow and plank; basket; horse and cart up a ramp road | Horse tramway, 2-ft gauge; incline plane | Standard-gauge rail into the pit, switchbacks |
| Out of the pit | Horse whim, windlass | Steam-hoisted incline | Locomotives on grades up to 2 %; skip inclines |
| Pit to the railhead or dock | Cart | Light railway; aerial ropeway (Hodgson monocable 1868 [gk]; Bleichert bicable 1872–74) | Main-line rail; Mesabi to Duluth at 80¢/t from 1892 |
| Loading for shipment | Women carrying 40–50 kg baskets, about 200 t per 12 h per team (Basque coast) | Gravity staithes | Ore docks with pockets [gk]; Hulett unloaders 1898 [gk] at the receiving end |

**The early Mesabi, Vermilion and Lake Superior rail stack:**
- **Stripping dinkies.** 6–12-t dinkey engines on 20–30-lb rail of 24–36-in gauge, with
  1–4-yd³ side-dump cars.
- **Ore cars.** 10–15-t ore cars, then 25-t from the early 1890s, then 50–70-t steel cars.
- **Locomotives.** Standard 19×26-in locomotives on grades of 2 % or less. Two locomotives per
  shovel, each making 7–8 round trips per 9-h shift.
- **The train cycle.** One hour per round trip: 18 min loading, 15 moving, 6 switching, 5
  dumping, 4 waiting, 6 shovel delay, 6 other.
- **Track shifting.**
  - A steam track shifter moved 3,000 ft of track 10 ft sideways in half a day. By hand that
    took 40–50 men a full day.
  - 4–5 men followed it to tamp.
  - Track work was a constant: moving up shovel tracks and dump tracks.
- **Aerial ropeways.**
  - Bleichert had built more than 3,000 lines by 1912.
  - A Spanish ore line used 525-kg buckets at 2.5 m/s, about 1,200 t per 10-h shift.
  - The Bingham Highland Boy line (1902) carried 116 buckets and about 500 t per 15 h.
- **Sim-scale:**
  - 1,200 t per 10 h is about 33 kg/s, the same order as the colliery belt's grip of 30 kg/s.
  - A shovel at 1,500–2,000 t per day is about 42–55 kg/s while loading.

### 2.8 Spoil dumps

- Waste was hauled 2–4 miles on Mesabi grades of ¾–2 %. Dumps stood 25–60 ft high; 25–40 ft is
  best for soft material.
- Dumps were trestled at $2.50–5 per linear ft, or tipped over an edge with a plough or air-dump
  cars.
- **Failures.** "Breakbacks" opened 20–30 ft behind the edge and took track with them. Water as
  shallow as 5 ft beneath a dump "caused sudden sloughing".
- **Swell.** About 25 % when cast (Marsh).
- **Land.** Spoil space and the mine's own growth forced the town of **Hibbing** to move: 188
  buildings shifted two miles south between 1918 and 1921.

### 2.9 Drainage

- **Mesabi pits** commonly pumped **500,000–2,000,000 gal/day**. Some drained through drifts to
  a pump shaft.
- **Lehigh.**
  - Gackenbach ran four pumps day and night; Prime reports 11 million gal in 24 h, which may be
    an OCR error.
  - The Pennington steam pump kept one shaft dry by working 2–3 h a day.
  - Spring rains in 1857 flooded the works "to the top of the shaft".
  - "In all the banks water has stopped work" (Lesley).
  - Miners avoided cutting into the white "hill-clay" for fear of letting the mountain's water
    in (Prime).
  - Limestone **caverns** under the ore fed water up from below. At Whitely a cavity lay 24 ft
    down.
- **Abandoned pits** fill: "the sides begin to wash down" and the pit floods (Prime). Bilbao's
  La Arboleda pits are lakes today.
- **Sim-scale:**
  - 500,000–2,000,000 gal/day is about **22–88 kg/s** of water.
  - The colliery's `sinking_set` pumps 14 kg/s and its `cornish_set` 26 kg/s.
  - **The open pit's water problem is as large as the colliery's or larger**, and it is driven
    by rain as well as strata.

### 2.10 After the pit: preparation and grading

- **Hand cobbing.** Picking the lumps and breaking them with hammers.
- **Crushers.**
  - The Blake jaw crusher dates from 1858 [gk] and the Gates gyratory from 1881 [gk].
  - Biwabik's No. 24 gyratory with a 48-in opening took 1,000 t/h at 200 hp and cost under
    $75,000.
  - Biwabik crushing cost about 1.5¢/t.
- **Drying.** Cutting moisture from 18 % to 8 % cost 13–25¢ per ton. Taking 48 %-Fe ore at 20 %
  moisture down to 6 % raises its Fe content to about 56.6 %.
- **Grading and mixing.** Lake Superior ores were "more and more mixed, to establish certain
  grades". They were priced on a base Fe and P with premiums and penalties.
- **Washing plants for siliceous hematite.** Coleraine and Trout Lake, about 1910 [gk], and
  Edwardian.
- **Sintering.** The Dwight–Lloyd machine of 1906–08 used Mesabi fines, which were blamed for
  the surge in blast-furnace flue dust.

---

## 3. Work arrangements

- **Piecework.**
  - The Centre County Irish were "paid by the ton". Northamptonshire men were measured weekly,
    man by man.
  - Underground Mesabi miners were on contract per car [gk]. Open-pit shovel crews were on day
    rates plus a **performance bonus**: $20–25 for a full month of 25–26 days for the runner and
    craneman, and up to $20 a month for locomotive engineers.
- **Contract stripping.** Stripping was let to specialist firms such as Winston-Dear (from
  1891), at 25–32¢ per yd³ for jobs over 0.5 Myd³. This puts a separate party, with its own
  incentives, on the overburden.
- **Gangs.** Each gang has its own skills:

  | Gang | Make-up |
  |---|---|
  | Shovel | 8–10 men |
  | Powder | 10–30, working in pairs, under a powder foreman. Should not work over 8 h except to finish a blast |
  | Track | A foreman and 14 or more men serving four dumps |
  | Dump | A foreman and 1–2 men per shift |
  | Train | Engineer, fireman, brakemen [gk] |
  | Washer | Not stated. Prime's crews are all "men and boys" |
  | Pit labourers | Pick and shovel |

- **Who worked:**
  - **Lehigh:** farmers digging ore on their own hundred-acre farms, so the work was seasonal
    and part-time.
  - **Mesabi:** Finnish, Italian and later South Slav immigrants. Companies gave immigrants
    "the most dangerous and lowest paying jobs".
  - **Bilbao:** workers came in from Spain, Navarre and beyond. Women were *cargueras* (dock
    and ore carriers) and *sirgueras* (towing barges), and earned up to 50 % of a mining
    family's income.
- **Hours:**
  - Mesabi: 10–12-h days (1907); an 8-h day came after the 1916 strike.
  - Bilbao: 12–16 h (1890); after the Loma Pact, **11 h in summer and 9 in winter**. The
    working day was set by daylight.
- **Company control:**
  - Bilbao barracks had one bed for two men. The foremen ran both the barracks and the
    compulsory canteens (the truck system).
  - In the 1916 Mesabi strike, guards and razor-wire trenches surrounded the mines.
- **Strikes:** Bilbao 1890 (troops sent in), Mesabi 1907 and 1916.
- **Pay levels:**
  - Mesabi daily pay was about $1.75–2.25 for immigrant labour (date unclear), and $2.35 for
    pitmen in 1915.
  - The skilled shovel runner earned about 2.5× a pitman.

---

## 4. Logistics: what the operation has to keep fed

1. **Fuel and water for the boilers.** Every steam shovel and locomotive is a mobile boiler. A
   shovel takes 12,000–15,000 gal (about 45–57 t) of water a day plus coal. A locomotive burns
   about 4 lb of coal and evaporates about 30 lb of water per hp-hour. Water trains or
   standpipes and coal supply are a whole supply chain.
2. **Explosives.** Magazines at the ICC distances (50 lb needs 120 ft from inhabited buildings,
   barricaded). **Thawing houses** (5×8 ft, with the heater housing at least 10 ft away) were
   needed because dynamite **freezes at about 46 °F (8 °C)**.
3. **Track.** Constant relaying: the shovel's moving-up track, dump tracks and switchbacks.
   80-lb rail was standard in the pit, and ties lasted 3–20 years by species.
4. **Spoil room.** Every tonne of ore brings 1–5 t of waste, which must go somewhere. Dumps
   grow, fail and eat land.
5. **Water.**
   - **Too much:** pit flooding, which halts work, softens banks and slumps walls.
   - **Too little:** washers need a stream or wells.
   - The same pit can have both problems.
6. **Season.**
   - The Lake Superior shipping season ran roughly April to December (about 8½ months).
   - Frost runs 3–8 ft into the banks. It is opened with red-hot jumpers or steam points and
     6–8 lb charges of black powder.
   - Winter adds 5–6¢ per yd³ to stripping. Snow fills the benches.
   - Kiruna's steam excavators struggled in the cold.
7. **Grade control.** Mixing benches or stockpiles to hit a shippable Fe and P. Bessemer ore is
   the premium market.
8. **Carriage weight.** The reason for calcining and drying at the mine is that freight is paid
   per tonne.
9. **Land and royalties.** Mesabi royalties were 25¢–$1.00 per ton, against open-pit mining
   costs of about 30–40¢ per ton on cars (about 15¢ stripping and 15¢ shovelling).

**Overall cost picture (Mesabi, about 1915–20).** Mining cost 15–75¢/t, typically about
30–40¢. Marsh's planning example comes to about $1.00/t once capital is included. Ore is cheap,
so the margins sit in **stripping ratio, haul distance and water**.

---

## 5. Hazards

Each hazard is given with its mechanism and, where it exists, the nearest system in the sim.

| Hazard | Mechanism and source notes | Nearest sim analogue |
|---|---|---|
| **Bank slide / face collapse** | The leading killer in quarries: in 1939 US quarry fatalities, "falls or slides of rock or overburden" were the major cause. Herman's main precaution is "avoid an avalanche of the material burying the machine". Undercutting the toe, high banks, wet ground, frost crust undercut by gopher holes, and blast vibration all start slides elsewhere in the pit. Exposed banks "slough off into the pit" over the years. Shovels and track can be buried | `Roadway` wear → `roof_fall` (an `endangers:` hazard with rockfall and crush tags, reaching places). The shift is from **support** (timbering) to **geometry and water**: slope angle against repose, saturation, toe cut, frost |
| **Dump breakback** | Failures open 20–30 ft behind the edge and take track and men with them. Water 5 ft deep below a dump causes sudden sloughing | Same family as the slide, located at the dump |
| **Flyrock and premature shots** | Men in the open struck by thrown material (a New Zealand inspection case). Heavy gopher-hole charges | `ShotHole` states, the `blown_out_shot` and `premature_shot` perils, the `blast` tag. Surface flyrock reaches far further than underground; the colliery has no equivalent of a range to clear |
| **Misfire struck when drilling** | A classic quarry death | `struck_live_charge` exists already |
| **Gopher-hole accidents** | Man-sized holes "caused frequent accidents" (Marsh) | A confined-space charging peril, a variant of `misfired_shot` |
| **Thawing dynamite** | A British report counted 101 thawing incidents between 1871 and 1905, with 80 deaths and 123 injuries (secondhand). Men baked, boiled and toasted cartridges by stoves; thawed nitroglycerin exudes and is shock-sensitive | A genuinely **thermal** hazard. A cartridge store is a body whose temperature matters both ways: frozen means misfires and handling danger, overheated means it goes off. Fits the hot-spot rule as its own vessel and node. **New and distinctive** |
| **Frozen-dynamite misfire** | Frozen dynamite is unreliable and partly fires | Raises the misfire probability; ties to ambient temperature |
| **Drowning** | Flooded pits, and men in water-filled pits | `Sump` drowns at 6× the flood mark, and `breath.rb` |
| **Inrush from below or beside** | Caverns in the limestone; breaching the "hill-clay" lets the mountain's water in; Hodbarrow's sea breaches of 1885 and 1898 | `Inrush` (old water ahead) and `Ground` seep multipliers |
| **Rail: struck, crushed, runaway** | Switching moves, runaway cars on grades, dump-edge derailments, coupling, men walking track [gk]. The Mesabi pit grades of 4½ % at Alpena needed two locomotives on four cars | `HaulageRope` → `RUNAWAY` along a path, `struck_by_tub`, `caught_in_haulage`, and the runaway catch (catch points and derails) |
| **Shovel: struck by the dipper or swing, chain or rope parts, boom failure** | Chains broke often (Herman). Pitmen work under the boom | `ROPE_HAZARDS` and the rope peril family. The dipper swing is a new caught or struck peril for anyone at the pitman post |
| **Boiler explosion** | Every shovel and locomotive is a boiler at 90–125 psi | The steam engine operation's boiler, relief valve and fusible plug. The mine imports power and has no boiler |
| **Plank and trestle falls** | Barrow and plank needed "a good sense of balance" | The `fall` tag. A walking-place peril with a load on, which fits `burden.rb` |
| **Heat and cold exposure** | Summer sun in an open pit; Mesabi and Kiruna winters | `scorch.rb` starts at 318 K, but nothing makes an open pit hot or cold. **Needs weather** |
| **Dust lung** | Siderosis. Cumbrian hematite "red lung" appears in the 1920s–30s and is tied to high-speed percussion drills, which is after our window | Long-term harm. Probably out of scope |
| **Calcining clamp** | CO and SO₂ fumes, burns, clamp collapse [gk] | Combustion reactions, whitedamp and the prompt-reaction machinery. A clamp is a slow-burning coal-bed vessel, like the drive-head deposit |
| **Lightning, flood surge** | Plausible but unsourced | Needs weather |

**Scale of risk.** The UK in 1914 had 78,908 people employed at quarries under the Quarries
Act and 95 fatal accidents, about 1.2 deaths per 1,000 per year. Between 1905 and 1910, over
70 men a year died in the Iron Range's *underground* mines, so the open pits were safer but
far from safe.

**What disappears compared with the colliery:**
- Firedamp, the ventilation circuit, doors, brattices, fans, furnaces and afterdamp.
- Darkness, at least by day.
- Winding falls down a deep shaft.

The open pit trades **gas** for **water, geometry, rail and surface blasting**.

---

## 6. How it meets the existing sim

Codebase facts below come from a survey of `lib/reactor_sim` and `content/`.

### 6.1 Framework: reused as is

- The operation is a new `operations/open_pit/` package: `Operations.register`, a chassis,
  slots, parts, fragments, fixtures, places, passages, `ROUTES`, `PANEL_ORDER` and `informs:`.
  The guide in [`../guides/build-an-operation.md`](../guides/build-an-operation.md) applies
  unchanged.
- **Chassis candidates:**
  - **Hillside open-cast** (Bilbao, Northamptonshire): gravity drainage, spoil downhill, no
    hoist.
  - **Sunk pit** (Lehigh, Mesabi): needs an incline or hoist and pumps.

  This is the same pattern as the colliery's `single_shaft` and `two_shaft`.
- **Places.** Bench or face, pit floor, pit edge or bank, dump, washer, railhead or staithe,
  powder magazine. Places with `air:` matter less, since everywhere is open air and the gas
  volume is the `Atmosphere`.
- **Posts with `effort:`:**

  | Post | Weighting |
  |---|---|
  | Getter or pitman | force and swing |
  | Barrowman | force; `burden.rb` and its 130 kg lift limit apply |
  | Driller / jumper | swing and endurance |
  | Powderman | dexterity and intelligence |
  | Shovel runner and craneman | dexterity and intelligence, a governor pattern like the winding engineman |
  | Fireman | force |
  | Washer hand | — |
  | Trackman | force |
  | Teamster | — |

  The Mesabi shovel crew is a natural **multi-post machine**, close to `mine/winding.rb`'s
  governor with internal levers.
- Shifts, seats and quarters carry over directly. Bilbao barracks are a quarters tier.

### 6.2 Physics: what carries over

| Need | Existing piece | Fit |
|---|---|---|
| Ore and overburden as material | Solids flow through ports tagged `solid`; nodes hold mass by resource | Good. **New content:** `hematite`, `limonite`, `clay` (gangue), `overburden` and perhaps `siderite`. Today `coal_measures` is the only rock material, a Wall |
| A bench that yields ore and waste | The colliery seam is a large stock with a `PickLine` drawing from it | Good. A bench is a stock with ore and overburden fractions, and the cut draws both |
| Washing (separation) | Conduits and vessels; no separator node yet | **New node**: a washer that takes muck plus water and sends ore, slurry to the mud-dam, and lumps separately. This is the first *separation by resource* in the sim |
| Calcining | Reactions with `limited_by:` and `alternatives:`; thermal links; a coal-layer reaction vessel (the drive-head pattern) | Very good. `limonite → hematite + steam` (endothermic) and `siderite → hematite + CO₂` are ordinary reactions, and a clamp is a coal-bedded vessel. The hot-spot rule already covers it |
| Pit water | `Ground` seep, `Sump` with a flood mark and drowning, `Pump`, `PumpBeam`, `Inrush` | Very good for the strata side. **Missing: rain**, the dominant open-pit inflow |
| Haul out of the pit | `HaulageRope` (rise over a run), gravity solved in the drive solve, `RUNAWAY` along a path, runaway catches, `Landing` | Very good for **inclines**. Pit rail with locomotives is a new node family |
| Aerial ropeway | `Conveyor` (capstan grip, stall, drum `Bearing`), `Rope` | Good. A ropeway is a rope conveyor with grip, and stalls and runaways carry over |
| Blasting | `ShotHole` (idle, charging, fired, misfire, clearing; 1,500 kg per shot), `black_powder_firing`, `permitted_firing`, the shotfirer's ticket | Good. **New:** dynamite as a resource and reaction, a freeze state, a thawing house, and heavier springing and gopher shots with a much larger flyrock reach |
| Slides | `Roadway` wear → `roof_fall` with `endangers:`; `Gob` and `OldWorkings` failure patterns | Medium. The driver changes from timbering to **slope, water content and toe undercutting**. It is the same hazard shape with a new wear model |
| Power to the plant | The colliery imports a `line_shaft` from the steam engine operation through a coupling (`dev_match.rb`, ratio 0.78) | **Tension. See 6.3** |
| Steam machinery | The steam engine operation: boiler, relief valve, fusible plug, cylinder, flywheel | Available in principle, but those are another operation's nodes |
| Output | `Nodes::Delivery` writes `mass_delivered` to the ledger; the `coal_raised` gauge | Good. Ore delivered goes to a staithe or railhead `Delivery`. **Grade (Fe %, P %)** is a new gauge derived from the mix of resources at the Delivery |
| Weather, temperature, seasons | `Nodes::Atmosphere` is fixed in pressure and temperature; no day or night cycle | **Missing entirely.** It drives rain, frost, thawing dynamite, the winter season and heat or cold exposure |
| Economy | None. Blueprints are bills of materials that nothing can pay yet | Ore grade and the Bessemer premium have nowhere to pay out yet. The ore→ironworks chain is the "chain of operations" that [`blueprints.md`](blueprints.md) §4 defers |

### 6.3 Decisions this research raises

1. **Power rule against mobile steam.** The standing rule is that powered fittings are sinks on
   the operation's line shaft, with no outboard engines. Historically the shovel and the
   locomotive each carried a boiler.
   - **Fixed plant** (washer, crusher, incline hoist, pumps, aerial-ropeway drive) maps cleanly
     onto a line shaft.
   - **Mobile plant** is the question. Options:
     - (a) Keep the rule. Treat shovels and locomotives as abstracted sinks on the shaft, which
       is a fiat for the 1890s and accurate for Edwardian electric shovels fed by cable from a
       powerhouse.
     - (b) Allow a self-contained boiler node per machine, which breaks the rule but is
       historically faithful and brings the fireman, water and coal logistics with it.
     - (c) Treat mobile machines as **crews with a capability**, not as physics nodes: a shovel
       is a post whose output is set by its tier, its crew and its fuel and water stock.
   - Each has real costs. A design sketch would set out the pros and cons.
2. **Weather.** Rain, frost and season are central to open-pit logistics and hazards, and the
   sim has none. Is a minimal ambient model (rain rate and temperature drawn per match, slow
   drift) a prerequisite, a later unit, or out of scope? Without it, water comes only from the
   strata and nothing freezes.
3. **Ore quality.** Is grade (Fe %, and P % for Bessemer) a modelled quantity or just tonnage?
   It is the backbone of hematite's story and of washing and drying, but it has no payout until
   an ironworks or market exists.
4. **Chassis geography.** Hillside open-cast, sunk pit, or both as chassis.
5. **Ore choice.** Pure hematite (late-tier, shovel-heavy), pure limonite (washing and water,
   every tier), or a **zoned deposit** of limonite and clay over a hematite core (§1.1).
6. **Scope of rail.** Full locomotive physics, rope inclines only, or rail abstracted as
   haulage throughput with perils, the way `hand_putting` is.
7. **Stripping as a separate party.** Contract stripping could be a distinct crew or loop that
   the player must keep ahead of the ore shovel. The pit stalls if stripping falls behind,
   which is a natural pacing mechanic.

---

## 7. Candidate blueprint tiers

This is a menu, not a design. Slot names are illustrative.

| Slot | Early (about 1800–50) | Mid (1850–80) | Late (1880–1900) | Edwardian (1900–14) |
|---|---|---|---|---|
| **Getting** | Pick and shovel getters | Getters plus black powder in jumper holes | Railroad steam shovel (Otis or Bucyrus type, 2–2¼ yd³) | Revolving steam shovel; electric shovel |
| **Stripping** | Barrow and plank | Horse scrapers and side-dump carts | Steam shovel with dinkey and side-dump trains; contract strippers | Dragline (1904); large revolving stripper; air-dump cars |
| **Breaking** | — | Black-powder hand holes | Tripod air drills; gopher holes; dynamite | Churn or well drills; electric firing |
| **Explosives store** | Powder house | Magazine | Magazine plus thawing house | Magazine plus a steam-heated thawing house; "permissible" practice |
| **Pit haulage** | Horse and cart up a ramp road | Horse tramway; steam-hoisted **incline plane** | Locomotives and switchbacks; skip incline | Heavier locomotives; steam track shifter |
| **Long haul** | Cart to the furnace | Light railway; **aerial ropeway** (monocable) | Bicable aerial ropeway; standard-gauge branch line | High-capacity ropeway; ore dock |
| **Track work** | — | Hand gangs | Track gang | Steam track shifter (one machine replaces 40–50 men a day) |
| **Drainage** | Bucket and windlass; drainage adit (hillside) | Steam pump | Cornish or steam pumps; drainage drift to a pump shaft | Electric centrifugal pumps |
| **Washing** | Hand riddle at a stream | Single-shaft log washer (horse or water) | Two-shaft steam log washer; grizzly | Jig (Bradford-type) washing plant |
| **Calcining** | Open clamp | Clamp | Shaft kiln (Cleveland-type) | Gas-fired kiln |
| **Preparation** | Hand cobbing | Hand cobbing plus hammers | Jaw crusher | Gyratory crusher; drying plant; sintering (1906–08) |
| **Quarters** | Farm (seasonal labour) | Shanties | Barracks plus company store (truck) | Company location housing |
| **Safety** | — | — | Berms; powder foreman | "Safety First" programmes; track derails and catch points (reuse) |

**Content and parts that already exist and could carry over:** black powder and permitted
explosives, `ShotHole`, `HaulageRope` with runaway catches, `Conveyor` (as the basis of a
ropeway), `Pump`, `Sump`, `Ground`, `Inrush`, `Landing`, `Delivery`, the combustion reactions
with coal-layer ignition (as the basis of a clamp), the kit (helmets, safety belt) and the
shift and quarters parts.

---

## 8. Gaps in this research

- **Washer water use and yield per yd³, and calcining fuel ratios.** Not in the sources read.
  Prime's water figures sit in a section the text cut off.
- **Detailed 1890s Mesabi pit accident causes.** The inspector reports are not online as text.
  The cause mix is inferred from Marsh, Herman and the general quarry statistics.
- **Bilbao working methods in detail.** The bench practice, ropeway dates and *cortas* layout
  need Spanish-language mining history that was only reachable in snippets.
- **The Minnesota historic-context study** (Minnesota SHPO, 2014) and **USGS Bulletin 470**.
  Both are scanned PDFs with no text layer, so they were not read. They would fill the gaps on
  Mesabi labour and on Alabama washing.
- **The [gk] dates and densities** should be checked before any design sketch depends on them.

---

## Sources

**Primary and period texts:**
- Marsh, *Steam Shovel Mining* (1920): https://archive.org/details/steamshovelminin00marsuoft
- Hermann, *Steam Shovels and Steam Shovel Work* (1894): https://archive.org/details/cu31924003942665
- Crowell & Murray, *The Iron Ores of Lake Superior* (1911): https://archive.org/details/ironoreslakesup04murrgoog
- Prime, *Report of Progress on the Brown Hematite Ore Ranges of Lehigh County* (1875): https://archive.org/details/reportofprogress00prim
- Lesley, *The Brown Hematite Iron Ore Banks … Centre and Huntingdon Counties* (1874): https://archive.org/details/brownhematiteiro00lesl

**Mesabi and Minnesota:**
- Minnesota DNR, mining methods: https://www.dnr.state.mn.us/lands_minerals/underground/mining_methods.html
- 911Metallurgist, "Antique Mining Equipment": https://www.911metallurgist.com/blog/antique-mining-equipment/
- Hull–Rust–Mahoning Mine: https://en.wikipedia.org/wiki/Hull%E2%80%93Rust%E2%80%93Mahoning_Open_Pit_Iron_Mine
- Missabe Railroad Historical Society: https://www.missabe.com/oliverabout
- Mesabi Tribune, early iron ore days: https://www.mesabitribune.com/news/local/early-iron-ore-days-on-land-and-lakes/article_de93f64a-d819-11ea-817b-2bbf68e85e1f.html
- Mesabi Tribune, Biwabik through the years: https://www.mesabitribune.com/news/community/biwabik-through-the-years/article_55dd3a22-e6d5-11ee-bc89-ff978aa418fc.html
- MNopedia, 1907 strike: https://www.mnhs.org/mnopedia/search/index/event/mesabi-iron-range-strike-1907
- Brewminate, 1916 strike: https://brewminate.com/the-minnesota-miners-strike-that-brought-immigrant-workers-together-in-1916/

**Brown ore, limonite and bog ore:**
- Valentine log-washer paper (abstract): https://www.academia.edu/36681080/
- Lower Macungie, iron mining: https://www.lowermac.com/262/Iron-Mining
- Virginia DMR circular: https://energy.virginia.gov/commercedocs/MRC_1.pdf
- Alabama brown ores (OneMine): https://onemine.org/documents/papers-prospecting-mining-and-washing-the-brown-iron-ores-of-alabama-t-p-860-
- NPS, New Jersey bog ore: https://www.nps.gov/parkhistory/online_books/nj2/chap5b.htm

**British ironstone and Cumbria:**
- Northamptonshire HER, Hunsbury, Spratton and Nassington records: https://her.northamptonshire.gov.uk/
- Industrial Railway Society, Desborough Co-op pits: https://shop.irsociety.co.uk/Archives/15/Iron_5.htm
- Cleveland ironstone mining: https://en.wikipedia.org/wiki/Ironstone_mining_in_Cleveland_and_North_Yorkshire
- BGS, Cumbrian haematite: https://earthwise.bgs.ac.uk/index.php/Haematite_deposits_of_Cumbria
- Hodbarrow Outer Barrier: https://co-curate.ncl.ac.uk/hodbarrow-outer-barrier
- Ruston, Proctor & Co: https://en.wikipedia.org/wiki/Ruston,_Proctor_and_Company
- Navvy rates: https://victorianweb.org/history/work/sullivan/7.html
- Haematite lung (Faulds 1934): https://era.ed.ac.uk/items/a65a35a5-4e3c-4d91-843d-db1fd00d9aa7

**Spain and Sweden:**
- Enkarterri mining routes: https://www.visitenkarterri.com/default/documentos/647_en-0.pdf
- Bizkaia, *sirgueras* and *cargueras*: https://www.bizkaia.eus/es/tema-detalle/-/edukia/dt/12215
- Basque loaders: https://zientzia.eus/artikuluak/zamalekuak-garai-bateko-industriaren-azken-katebeg/en/
- Universitat de Barcelona, women dock workers: https://diposit.ub.edu/dspace/handle/2445/158038
- Argia, women in mining households: https://argia.eus/en/argia-astekaria/2722/bilbo-eraiki-zuten-emakume-trauskil-haiek
- Basque iron quality: https://aboutbasquecountry.eus/en/2018/01/29/when-basque-iron-was-the-world-standard-for-quality/
- Kiruna: https://en.wikipedia.org/wiki/Kiruna
- LKAB history: https://lkab.com/en/who-we-are/a-history-of-lkab/

**Ropeways, explosives and safety:**
- Bleichert ropeways (Highland Boy): https://utahrails.net/bingham/highland-boy-bleichert.php
- Thawing dynamite: https://columbian.com/news/2013/jun/02/thawing-dynamite-in-stoves-was-standard-practice
- Quarry accident statistics (HathiTrust digest): https://hathi.library.illinois.edu/feed/packages/BrittleBooks/demo/99397111412205899v110/00001357.txt
- Dwight–Lloyd sintering: https://onemine.org/documents/development-of-the-dwight-lloyd-sintering-process
