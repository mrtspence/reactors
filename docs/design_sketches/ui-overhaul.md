# The UI overhaul (for review)

> Input to a decision, not a description of the system. The third of three units decided in the
> open-pit lookover (2026-11-01), after lighting and the blast whistle. **The overhaul is split
> into sub-units (§2). U1, the frame, is built (§3, §8); U2, the console by place, is built (§4,
> §9, §10).** Each later one gets its own draft once the one before has landed.
> The layout these build towards is kept in [`reference/layout.md`](../reference/layout.md).

## 1. What is wrong now

**The console is one flat page**, built for the steam engine's dozen gauges and one room:

| | Steam engine | Pit to start | Pit fully fitted |
|---|---|---|---|
| Instruments | about 20 | 23 | 34 |
| Levers | about 12 | 17 | 46 |
| Posts | a handful | 21 | 51 |
| People | 2–3 | 14 | 40 |
| Places | 1 | 8 | 10 |

- **Instruments are in `PANEL_ORDER`, in one grid.** Nothing says which belong to the ore bench
  and which to the kiln, so reading the pit is reading a list.
- **Levers are one column**, effort posts (how hard a gang works) beside pure levers (a valve).
- **People are one list, each with a dropdown of every post** — 51 options for each of 40 people.
  Moving a gang is a dozen dropdowns, and a refused posting only shows as a disabled option.
- **Every screen draws its own header**, and only the console streams: on the outfitting screen
  the match is still running and nothing says so.
- **What the machine makes and what the sky is doing** are gauges in the grid like any other.
- **The incidents are a 10rem box** under the crew.
- **The outfitting and crew screens** list every slot and seat in one long form.
- **`console_controller.js` is 678 lines** doing the stream, the gauges, the levers, the crew and the
  incidents.
- **Testing a state** (night, a charged hole, a flooded bench) means playing to it.

## 2. The overhaul, in sub-units

| | Sub-unit | What it adds | What the player gets |
|---|---|---|---|
| **U1** | **The frame** | The layout's nav row, state strip and feed, on every page and connected across navigation; each machine's outputs declared; the places and minimap reserved; the controller split | One app, with the match's state always in view |
| U2 | The console by place | Every instrument and lever knows its place; the places list and one place panel at a time, with its schematic reserved | The pit readable a place at a time |
| U3 | Gangs, not people | Posting from the post: each post's gang, filling it from who is idle or nearest; picking several people and sending them together; sorting and filtering; a refused posting said | Moving forty people in a few actions |
| U4 | A developer's bench | Pause, step and speed in the developer's menu; starting a match at an hour and on a pinned ground; seeding a named state (night, a charged hole, a flooded bench, a breached dam) | Testing a state without playing to it |
| U5 | The fitting screens at scale | The outfitting and crew screens grouped, collapsible and summarised | Outfitting a pit without scrolling a form |
| U6 | The record | The feed filtered by place; an event opens the dialog with its detail; the brawl report the animosity unit left owed | Knowing what happened, and where |

**Not scheduled**: the minimap's schematic of the works, and each place's schematic. U1 and U2
reserve their room.

**Why the frame first:** U2's place panel sits in it, and every later screen is drawn inside it.
Building the place panel into today's page and then moving it is the work done twice.

## 3. U1 — the frame

### 3.1 The layout is the app's

- **`layouts/application` draws the nav row, the state strip and the feed**, and yields the centre
  and, where a page has one, the left column. The four screens lose their own headers.
- **The frame stays connected across navigation.** Turbo Drive is already on; the frame is
  `data-turbo-permanent`, so going from the console to outfitting and back keeps the subscription,
  the strip's readings and the feed's history. Its element id names the machine, so going to
  another machine's screen replaces it and subscribes to that one.
- **Match setup belongs to no machine**, so its frame is the match's primary machine's
  (`DevMatch::PRIMARY`, as the root route already is).
- **Each region is its own component** (`Frame::NavComponent`, `Frame::StripComponent`,
  `Frame::FeedComponent`, and the placeholders of §3.5), placed only by named grid areas in the
  layout. Moving one later is an edit to `grid-template-areas`.

### 3.2 The nav row

| Group | Contents | Now from |
|---|---|---|
| **Reactor** | the name, to the root | — |
| **The match's machines** | one pill each, the current one marked | the console's sibling links and `shared/_machine_switcher` |
| **This machine's screens** | Console, Outfitting, Crew (the last two when `fittable?`) | the console header's links |
| **The match** | Match setup | the console header's link |
| **Stubs** | Hiring, Workshop, Record: shown, not links | — |
| **Right** | the tick, the connection, the time scale, borrowed, the developer's menu (Reset) | the console header |

Each stub is marked `TODO:` with what fills it: Hiring the roster and buying people
(`Blueprint.minions`), Workshop the blueprints and unlocks, Record U6.

### 3.3 The state strip

**The weather**: the machine's `WeatherGauges` instruments, out of the grid and into the strip.
They stay instruments — somebody's word through `observer:` — so the strip shows the sky as this
machine's people tell it, which is the game. One sky covers the match; a second machine's people
may say it differently.

**The outputs: what each machine makes**, declared by the machine (built as a `role:` on the
instrument instead of a list, §8):
- **`OUTPUTS` beside `PANEL_ORDER`** in each panel module: the instruments that are what the
  machine produces, in order, as many as it has. The pit's Finished Ore; the colliery's Coal
  Raised; the steam engine's Indicated Power. A mobile engine declares none: its work shows as the
  pit's.
- **They are instruments already in the catalogue**, so an output is read as imperfectly as any
  gauge, and an output whose part is not fitted is not shown. `Assembly` refuses an output its
  catalogue does not hold, as it refuses a `PANEL_ORDER` entry.
- **`Operation#panel` lists them** as `outputs:` (ids, fitted only, in order). Nothing else in the
  sim changes.
- **One home each**: an output or weather instrument is drawn in the strip, not in the grid.

**Whose outputs: the machine being looked at, only** (decided, §7). The power is the generator's
screen's, the coal the colliery's; another player's figures stay on their screens. Looking in on an
ally's machine is that machine's own frame, read-only — a later unit.

**The day and the night** are in the weather: The Hour, somebody's word for it by the sun (the
small hours, morning, about noon, evening), beside The Light.

### 3.4 The feed

The incidents move to the right column, full height, on every page, and keep their weights by
severity as now. Because the frame is permanent, the feed keeps its history across navigation.
**Entries stay plain list items in U1**; U6 makes each open the dialog. Nothing reserves the
dialog in the page until then: it sits over the centre, so it costs no room.

### 3.5 What U1 reserves

- **The left column**, on the console only: a **places** box (top) and a **minimap** box (bottom,
  about 16rem square, the size an RTS minimap is), each a component that renders a labelled,
  dashed placeholder. U2 fills the places box; the minimap waits for its schematic.
- **"Too small" has an answer already**: U2's places list has an entry for **the works**, and the
  works' place panel is where the whole schematic would be drawn large. The minimap stays
  navigation; the works panel is for reading.
- **Each placeholder carries a `TODO:`** naming what fills it.

### 3.6 The controller split

`console_controller.js` becomes Stimulus controllers with one job each:

| Controller | Where | Job |
|---|---|---|
| `stream` | the frame | subscribing, the run check, the deltas; dispatches `reactor:view` on the frame's element with each view |
| `gauges` | wherever instruments are drawn (the strip, the console) | painting instruments from the view |
| `levers` | the console | painting levers, sending commands |
| `crew` | the console | painting people and postings, sending postings |
| `feed` | the frame | the incidents |

The split changes no behaviour and is done first, under the existing request specs and checked by
hand in a browser. **The stream controller living in the frame is what makes the strip and feed
live on the outfitting screen**, with no code of that screen's own.

## 4. U2 — the console by place

Agreed in the first draft (§7): a place on every instrument and lever, derived and never written;
the places box; one place panel at a time; a footplate as a place of its own; the steam engine as
one place. This section makes it buildable.

### 4.1 Where everything is, measured

From the machines as they build today (scratch script over `Operation#panel` and `Layout`):

| | Places | Instruments by observer | by node | by the posts on its node | left over |
|---|---|---|---|---|---|
| Pit to start | 8 | 8 | 9 | 0 | 0 |
| Pit fully fitted | 10 | 12 | 14 | 2 (the shovel boards) | 0 |
| Colliery | 3 | 6 | 15 | 2 (Roof, Tubs) — in **two** places | 2 (The Make, Seam) |
| Steam engine | 1 | 5 | 14 | 0 | 1 (Water in Supply) |

- **Every lever already has a place.** In the fitted pit: bank 14, ore bench 11, stripping bench
  10, kiln top 3, the dams, dump and kiln foot 2 each, each footplate 1, the haul road none.
- **The rule agreed — observer, then node, then the works — leaves the shovel boards in the
  works**, because the dipper is in no room: a shovel is not a place, its crew stand on the bench.
  One more derived step finds them: **the places of the posts that work the node it reads**. The
  craneman and the casting lever are on the bench, so the board is too.
- **That step finds the colliery's tub road in two places**: it is a way, not a room, worked by
  the putter in the district and the timberman at the pit bottom. §9 Q1.
- **What is left over is nobody's room**: the seam and the ground's water make, which are rock;
  and the engine's water supply, which the engine house does not list among its nodes. A machine
  with one place puts it there regardless (§4.3).

### 4.2 The sim side

- **`Source#nodes`**: the nodes a source reads — one for every source but `Aggregate`, which is
  the union of its parts'. Configuration, read at build.
- **`Operation#panel` adds places, derived once:**
  - each instrument: `places:`, a list, in this order of precedence —
    1. its observer's post's place;
    2. else the places its nodes are in;
    3. else the places of the posts whose `node:` it reads;
    4. else empty — **the works**.
  - each control and station: `place:`, its post's (`Layout#place_of`), nil for the works.
  - `places:` already lists the declared places in order, with labels.
- **No declaration anywhere.** A new gauge lands in a place because of what it reads or who reads
  it; nothing to keep in step. A machine with no places (the dev engine) has everything in the
  works.
- **Nothing on the tick path changes**, nor the view, the stream or the protocol: places are
  chrome, sent once with the panel.

### 4.3 The places box

The left column's top region, replacing U1's placeholder. One line a place, in `Layout` order,
then **The Works** last:

```
PLACES
Bank             6   the dam is full
The Dams         1
Stripping Bench  9   a misfire in the hole
Ore Bench        5   water on the floor
…
The Works
```

- **The count** is how many are in the place now (the crew view's `place`), live.
- **The words** are that place's most pressing board, as its instrument says it — see §9 Q2 for
  what "pressing" can mean when the sim has no notion of it.
- **Clicking a line shows that place** in the centre. The choice is kept per machine in
  `localStorage` (wrapped, falling back to the first place), so going to outfitting and back
  returns to it.
- **An operation with one place shows no box**: the steam engine's console is its engine house
  panel, holding everything, what belongs to no place included, and the left column holds only
  the minimap's placeholder (§9 Q3).

### 4.4 The place panel

The centre, under the schematic placeholder U1 put there, which now belongs to the place shown:

```
STRIPPING BENCH — 9 here, 2 on the way
┌ SCHEMATIC of this place (placeholder) ─────────────┐
└────────────────────────────────────────────────────┘
its instruments, in PANEL_ORDER       │ its levers, in slot order
                                      │   Getters  ▮▮▮▮▮▯▯▯ 5 of 8
                                      │   Barmen   ▮▮▯▯    2 of 4
                                      │ here: Ada, Bert, … (U1's crew rows)
                                      │ on the way: Cy (to Getters, 40%)
```

- **Instruments and levers keep their orders**, filtered to the place: `PANEL_ORDER` and slot
  order are what a player learns a panel by, and a place's share of them reads the same way.
- **A gang post shows its count**: how many are working it (`station`) against its `capacity`,
  from the crew view. A post for one shows who is on it.
- **Who is here** is everybody whose `place` is this one; **on the way** is everybody posted here
  (their posting's place, or the place of the person they were sent to) who is not here yet, with
  the travel bar the crew rows already draw. Each person is one row, moved between panels as they
  walk, with U1's dropdown unchanged — U3 replaces posting.
- **The Works panel** holds whatever is in no place, and is the large schematic's home (§3.5). In
  the pit today that is nothing but its placeholder (§9 Q4).

### 4.5 In the page

- **Every place's panel is rendered, one shown.** Every painter already paints by id wherever the
  element is, so a hidden panel stays current and switching place is instant, with no request.
  An instrument in two places is two elements with one id's data; the gauges controller paints
  every element for an id rather than the first.
- **A `places` controller** owns the box: counts and words from `reactor:view`, the selection,
  `localStorage`. **The `crew` controller** moves each person's row into the panel for their place.
- **`PanelComponent` becomes `PlacePanelComponent`**, one per place, taking the panel and a place;
  `Frame::PlacesComponent` replaces the places placeholder.

### 4.6 Specs

- **Sim, zero ticks**: every instrument's places are declared places; an observer's post wins over
  the node; the pit's shovel boards are on their benches; the colliery's Roof and Tubs are in the
  district and at the pit bottom; every lever and station carries its post's place; the dev engine's
  are all the works.
- **Request**: the pit's console renders a panel for each place and the works and a line for each
  in the box; each role-less instrument appears in exactly the panels its places name; the steam
  engine renders one panel and no box.
- **The JavaScript is checked in a browser**, as U1's is.

## 5. Specs

- **Outputs, sim side** (zero ticks): `panel[:outputs]` lists only fitted outputs, in order; every
  output is in the catalogue (`Assembly` refuses one that is not); each catalogued machine but the
  mobile engine declares at least one.
- **The frame** (request specs): every screen renders the nav row, the strip and the feed; the
  console's weather and outputs render in the strip and not in the grid; a stub is not a link;
  outfitting and crew only for a fittable machine; match setup frames the primary machine.
- **The JavaScript** has no test harness in this repo, so the split is checked in a browser, as the
  current controller is; `current_progress.md` already records that gap.

## 6. Questions on U1 (answered, §7)

1. **Whose outputs the strip shows.**
   - *(a) Every machine the player can view, by subscribing to each machine's existing channel*
     (proposed). *For*: match-level, as asked, with no new server code but drawing each sibling's
     output chrome. *Against*: a full projection per machine at 4 Hz to read one or two gauges —
     fine at three machines, wasteful at twenty.
   - *(b) This machine's only.* *For*: no extra subscriptions. *Against*: not match-level; the
     colliery's coal disappears from view on the steam engine's console.
   - *(c) A match channel carrying only outputs.* *For*: the right shape at scale. *Against*: a new
     projection and channel on the runner, for a problem three machines do not have.
   - **Recommended (a)**, with (c) as the TODO for when a match holds many machines.
2. **One home for an output or a weather gauge** (the strip only), or also in its place in U2?
   Recommended one home: a reading drawn twice on one screen invites comparing them.
3. **The left column: places over the minimap**, or the RTS bottom bar — minimap, then the place's
   levers, then its people, under the place panel? The bottom bar is more familiar, but forty-six
   levers will not fit a fixed-height strip. Recommended the left column.
4. **The placeholders visible** as labelled dashed boxes in every build, since the layout judgments
   are made by looking? Recommended visible.
5. **The nav stubs**: Hiring, Workshop, Record?

## 7. Review decisions

### 2026-11-03, on the first draft

1. **The sub-units and their order**, the console by place first: agreed. The frame is now put
   ahead of it (§2).
2. **A footplate is its own place panel.**
3. **One place at a time, with an overview.**
4. **An instrument's place by its observer first**, then its node's, then the works.
5. **The controller split as the first step.**
6. **Added:** the app's frame — a nav row on every page, for an SPA feel; a state strip of the
   weather and the outputs, with no limit of one output per machine; the event feed as the right
   column, its events later opening a central dialog with their detail; a minimap of the works,
   probably bottom left as in an RTS, clickable to open a place; a schematic in each place panel.
   None of the schematics built yet, but their room reserved or the regions movable. **A
   wireframe of the current and the goal layout kept as a to-do**: `reference/layout.md`.

### 2026-11-03, on U1

1. **The machine being looked at, only.** Each player's state stays on their screen; switching
   to an ally's machine to check on it, read-only, is a later state.
2. **One home**: the strip only.
3. **The left column.**
4. **The placeholders visible.**
5. **Hiring, Workshop, Record** for now.
6. **Added:** the day-night cycle in the strip's weather.

### 2026-11-08, on U2

U1 checked in a browser and approved; U2 to go ahead as recommended (§9):

1. **A way's instrument in both places' panels.**
2. **`calm:` on `Prose`**, marking the `SIGNALS` boards now and the banded ones as they are touched.
3. **One place, no box.**
4. **The Works always listed.**
5. **People moved between panels as they walk**, posting unchanged until U3.

## 8. Settled while building U1

- **An instrument's `role:`** (`:output` or `:weather`, `Diagnostic::ROLES`) says it belongs to
  the whole machine, and its chrome carries it. Nothing else changed in the sim: no list of
  outputs to keep in step with the catalogue, and an unfitted part's output leaves with its gauge.
  The pit's Finished Ore, the colliery's Coal Raised and the steam engine's Indicated Power are
  the outputs; every weather gauge is the weather.
- **The Hour** is a sixth `WeatherGauges` guess on every panel, banded by the hour of the sky.

## 10. Settled while building U2

- **`Prose.signals(SIGNALS, calm: CALM)`**: a node's `CALM` keys beside its `SIGNALS`, fetched so
  a typo raises. The fourteen signal boards are marked. Two calls were judgment: a road with no
  signals fitted ("the drivers' own look") and lights off ("out") are calm, because both are the
  ordinary state for a whole match or a whole day and would otherwise fill the box; a charged
  hole is not, because it is waiting on the player's fire lever.
- **Everybody starts in the panel of their seat's dealt place** (`Minion#default_place`), so the
  rows are visible before the first view; the crew controller moves them from there, never while
  their dropdown is open.
- **The places box counts by `place`**; a panel's header counts here and on the way. A walker is in
  the place they stand in and a line in the one they are walking to.
- **`PanelComponent` and `CrewComponent` are gone**, replaced by `PlacePanelComponent` and
  `CrewRowComponent`; the places placeholder region is gone with them.

## 9. Questions on U2 (answered, §7)

1. **An instrument on a way between two places** — the colliery's Roof and Tubs, on the tub road
   from the pit bottom to the district.
   - *(a) In both places' panels* (proposed). *For*: the putter in the district and the timberman
     at the pit bottom both answer to the road, and only one place is shown at a time, so the
     reading is never drawn twice on one screen. *Against*: the gauges controller paints every
     element for an id, not one, and the places box could name the same board twice.
   - *(b) The works.* *For*: one home, no new rule. *Against*: the road's two gauges sit away from
     both people who work it, in a panel that is otherwise empty.
   - *(c) The first place in `Layout` order.* *For*: one home. *Against*: arbitrary — the pit bottom
     wins because the chassis declares it first.
   - **Recommended (a).**
2. **What "most pressing board" means.** The sim has no notion of it: nearly every board is
   `Prose`, and its phrases are ordered by thresholds or by "the first that holds", with the calm
   one sometimes last (the shovel's "digging"), sometimes neither end (the kiln's "black … bright").
   - *(a) `calm:` on `Prose`*: the phrases that need nobody's attention. A place's line shows the
     first of its boards, in `PANEL_ORDER`, saying something not calm, and nothing when all are.
     Undeclared means never pressing. *For*: the words are the instrument's own, read as
     imperfectly as ever, and a board says nothing in the box until its author decides it should.
     *Against*: about fifty `Prose` displays, each a judgment, and a display gains a fact about
     meaning that only the box reads. A first pass can mark the boards (the `SIGNALS` ones, about
     fifteen) and leave the rest silent.
   - *(b) The place's first board, whatever it says.* *For*: no sim change. *Against*: the bank's
     first board is the coal yard's, so a reservoir about to go over its crest shows in the box as
     how much coal is left.
   - *(c) The count only, the words later.* *For*: U2 lands smaller. *Against*: the box tells you
     where people are, not where to look, which was the point of it.
   - **Recommended (a)**, marking the `SIGNALS` boards in U2 and the banded ones as they are
     touched.
3. **One place, no box?** The steam engine has one room, so a box with one line is a box that
   does nothing. Recommended no box; the left column keeps the minimap's reserve.
4. **The Works always listed** on a machine with places, even with nothing in it but the
   schematic's placeholder (the pit today)? *For*: it is the large schematic's reserved home, and
   it is where something new in no room turns up. *Against*: an empty panel on the pit until the
   schematic is built. Recommended always listed.
5. **People moved between panels as they walk**, each keeping U1's row and dropdown, U3 then
   replacing posting? *For*: U2 stays about places, and U3 has a page to build on that already
   groups people by where they are. *Against*: posting somebody elsewhere is still a 51-option
   dropdown for one more unit. Recommended yes.
