# The app's layout: now, and the goal

**Two wireframes and one table.** *Now* describes what the screens are. *The goal* is the layout
the UI overhaul builds towards ([`design_sketches/ui-overhaul.md`](../design_sketches/ui-overhaul.md)).
Each region in the table names the sub-unit that builds it.

**A change to where anything sits on screen updates this file in the same change.** When a region
is built, it moves from the goal to now. When the goal changes, the change is made here first,
and then in the code.

## Now

The console (`consoles/show`), inside the frame:

```
┌ NAV ROW ──────────────────────────────────────────────────────────────────────────────────┐
│ Reactor │ [Open Pit] Colliery Steam Engine / frame │ Console Outfitting Crew │ Match setup│
│ Hiring° Workshop° Record°                 [borrowed] time ×N  tick 1234  live  [dev ▾]    │
├ STATE STRIP ──────────────────────────────────────────────────────────────────────────────┤
│ The Hour · The Light · How It Feels · The Weather · …   │                  Finished Ore   │
├──────────────┬────────────────────────────────────────────────────────┬───────────────────┤
│ PLACES       │ STRIPPING BENCH  9 here, 2 on the way                  │ Incidents         │
│ Bank       6 │ ┌ this place (placeholder) ──────────────────────────┐ │ newest first      │
│ Stripping  9 │ └────────────────────────────────────────────────────┘ │                   │
│  a misfire…  │ its instruments, PANEL_ORDER  │ Controls, 5/8 a gang   │                   │
│ …            │ grid of 2–4 columns           │ Here: one row each     │                   │
│ The Works    │                               │ On the way: a line     │                   │
│ ┌ the    ┐   │ every place's panel is drawn, one is shown             │                   │
│ │ works  │   │ the machine's start-up note, if it has one             │                   │
│ └────────┘   │                                                        │                   │
└──────────────┴────────────────────────────────────────────────────────┴───────────────────┘
```

- **The frame is the layout's** (`layouts/application`, `Frame` and `Frame::*Component`): the nav
  row and the strip in one `data-turbo-permanent` header, the feed in a permanent aside, both with
  ids naming the machine. Outfitting, crew and match setup yield only their centre; match setup is
  framed on the match's primary machine.
- **The grid is `.frame`** in `app/assets/tailwind/application.css`: from `lg` it fills the window
  and each column scrolls; below it the regions stack.
- **The strip draws an instrument with a `role:`** — `:weather` or `:output` — and the console's
  place panels draw the rest.
- **The console is one place at a time** (`ConsolePlaces`, `PlacePanelComponent`): a panel for each
  place the machine declares, then The Works, chosen in the places box and remembered per
  machine. A machine with one place — the steam engine — is that place's panel, with no box; the
  left column then holds only the minimap's room.
- **Six controllers, one job each**: `stream` (the frame's subscription, announcing each view on
  `window`), `gauges`, `levers`, `crew`, `places`, `feed`.

## The goal

```
┌ NAV ROW — every page ─────────────────────────────────────────────────────────────────────┐
│ Reactor │ [Open Pit] Colliery Steam Engine │ Console Outfitting Crew │ Match setup        │
│ Hiring° Workshop° Record°                            tick 1234 · live · time ×N · [dev ▾] │
├ STATE STRIP — every page ─────────────────────────────────────────────────────────────────┤
│ about noon · grey · feels cold · raining · a breeze│ Finished Ore 12.3 t                  │
│                                                    │ (this machine's outputs, only)       │
│                                                    │                                      │
├──────────────┬────────────────────────────────────────────────────────┬───────────────────┤
│ PLACES       │ PLACE PANEL  Stripping Bench — 9 here · getting        │ FEED — every page │
│ Bank       6 │ ┌ SCHEMATIC of this place ───────────────────────────┐ │ 14:19 shot fired  │
│ Stripping  9 │ │                                                    │ │ 14:12 a man hurt  │
│ Ore Bench  5 │ └────────────────────────────────────────────────────┘ │ …                 │
│ …            │ its boards and gauges                                  │                   │
│ The works    │ its levers, posts with their gang  │ who is here, and  │                   │
├──────────────┤                                    │ who is on the way │                   │
│ MINIMAP      │                                                        │                   │
│ the works    │                                                        │                   │
└──────────────┴────────────────────────────────────────────────────────┴───────────────────┘
                     ┌ DIALOG — an event's detail, over the centre ┐
```

° a stub: shown, not yet a page.

- **The strip and the feed are this machine's alone.** Another player's output stays on their
  screen; looking in on an ally's machine is its own frame, read-only.
- **Each region is its own component, placed only by the layout's grid areas.** Moving a region
  is an edit to `grid-template-areas`, not to the region.

## The regions

| Region | Holds | Now | Goal | Built in |
|---|---|---|---|---|
| **Nav row** | The app's screens, the match's machines, this machine's screens, the tick, the connection, the developer's menu | Built: every page | — | U1 ✓ |
| **State strip** | The hour, the light and the weather; this machine's outputs | Built: every page, live | — | U1 ✓ |
| **Feed** | The incidents | Built: the right column, every page | — | U1 ✓ |
| **Event dialog** | One event in detail: a fight's report, a shot's | — | Centred over the page, opened from the feed | U6 |
| **Places** | One line per place: how many are there and its first board saying something not calm; selects the place | Built: the console's left column, on a machine with more than one place | — | U2 ✓ |
| **Minimap** | A schematic of the whole works; selects a place | A placeholder, below the places | The left column, bottom, about 16rem square | not scheduled |
| **Place panel** | One place's boards, gauges, levers and people, and who is on the way | Built: the centre, one place shown | — | U2 ✓ |
| **Place schematic** | A drawing of the place shown | A placeholder, the top of each place panel | The top of the place panel | not scheduled |
| **Developer's menu** | Reset; later pause, step, speed and seeded states | Reset, in the nav row's menu | — | U4 fills |
| **Fitting screens** | Outfitting, crew, match setup | Long forms in the centre | Grouped and summarised | U5 |
| **An ally's machine** | Their frame and console, read-only | — | The same screens, nothing movable | not scheduled |
