# Winding signals: what the cage is waiting on

> **Status: agreed 2026-10-16, all three §4 recommendations taken; built — see §6.** Raised in
> review on 2026-10-16. The lift is the least intuitive
> part of the mine: the player names a landing and the cage may sit there with no visible reason.
> This adds one plain-words gauge that says what the cage is doing and what it is waiting on.

---

## 1. What is hidden today

The engineman's decisions are made in phase 0 and thrown away. `Tick#governed` knows where he is
winding to and whether the landing's marshal has rung. `Tick#calls_for` knows who is aboard and
who is waiting. Boarding and the marshal's let-on are in phase 6e. A player sees a depth needle and
a slack lamp, and nothing else. A cage standing at the bottom because the onsetter has not rung
looks exactly like a cage standing there because nobody called it.

All of it is visible in a real pit to the people at the landings: the bell, the men in the cage,
a tub jammed in the guides. So this is not an instrument that lies. It is a **signal board**, a
plain report of what both landings can see. No lag, no noise, no observer.

## 2. The gauge

One prose diagnostic, `winding_signals` ("Winding"), on the panel next to the cage depth. It shows
the **one most pressing fact**, by precedence; the first that holds wins:

| # | Phrase | Holds when |
|---|---|---|
| 1 | `rope parted — cage on its catches` / `rope parted — cage fallen` | the rope's failure mode |
| 2 | `cage caught in the headframe` / `overwound into the headframe` / `cage crashed at the bottom` | the hoist's failure mode |
| 3 | `tub lodged in the shaft` | the shaft holds a jam |
| 4 | `hung in the shaft — slack rope` | the cage is hung on a jam, slack past 0.3 m |
| 5 | `no engineman at the winder` | nobody posted at `man_winding` |
| 6 | `winding engine stopped` | the line shaft is not turning, or the clutch is out |
| 7 | `winding down` / `winding up` | the cage is moving |
| 8 | `stopped in the shaft` | stopped away from both landings |
| 9 | `men getting in at bank` / `… at the pit bottom` | somebody at this landing is still boarding |
| 10 | `false ready rung — a man still getting in` | the marshal rang while someone was boarding (a slip) |
| 11 | `waiting on the banksman's bell` / `waiting on the onsetter's bell` | marshal posted, has not rung |
| 12 | `loading coal at the pit bottom` / `running off coal at bank` | the deck is filling or emptying here |
| 13 | `no onsetter to load coal` | shuttling, coal waiting, nobody onsetting |
| 14 | `called to bank — men waiting` / `called to the pit bottom — men waiting` | a call stands at the other landing and he has not set off |
| 15 | `standing at bank` / `standing at the pit bottom` | nothing called |

The row 10/11 pair is the one players most need. The bell has two halves: the marshal
holding the cage because somebody is getting in, and a slipping marshal ringing anyway.

## 3. Where it is computed

**At the end of phase 6e, by a pure function over the settled tick**: the node states, the
minion states as walked, and this tick's lever positions. `Winding#signal` lives beside
`dispatch` and `govern`, so the engineman's rules and the report of them are in one file and
cannot drift apart. The result is written onto the hoist's node state as `signal:`, an index
into the phrase list, and read by `Sources::Field(:cage_drive, :signal)` into a `Prose` display.

There is precedent for the tick writing a derived key onto a node it does not own:
`Tick#advect` gives every conduit its `carried_kg`, because a node resolved through has no other
way to know it. This is the same: no node can see the marshals and the boarders. It is written
after the walk and before `observe`, so it reports the tick that just settled. It reads only that
tick's outputs, so order-independence holds.

**Why not a Source that computes it.** Sources see node states only, never minions or
levers, and teaching one to read the crew would make every instrument potentially a crew reader.
Computing in the tick keeps the instrument chain as it is.

## 4. Questions for review

1. **One gauge or two.** Recommend one board, unobserved: it is what everybody at both landings can
   see. The alternative is a bank board and a pit bottom board, each read through its marshal and
   dark when that post is empty — closer to life, and noisier on the panel.
2. **The precedence order** in §2. Faults first, then why it is not moving, then what it is waiting
   on. Recommend as drafted.
3. **Slack threshold** for row 4, the same 0.3 m the slack lamp bands at. Recommend sharing it.

## 5. Specs

On constructed states, zero or one tick each — every row is a condition that can be seeded:
- each phrase in §2 from its condition;
- precedence where two hold at once (a jam over winding, a missing engineman over waiting on a bell);
- the false ready, on a seeded slip with a boarder;
- the gauge always reads, with nobody posted at either landing.

---

## 6. As built

Five departures from §2, all forced by the code.

**The bell and the boarding are one condition.** `Tick#signalled?` withholds the bell only while
somebody is still getting in, so rows 9 and 11 cannot be told apart. With a marshal posted the
board reads "waiting on the onsetter's bell — men getting in"; without one, "men getting in at
the pit bottom". The false ready comes first, because it is the same moment with the marshal
slipping.

**Slack rope comes before the lodged tub**, the reverse of §2: a cage hung on a jam always has the
jam, so the more specific row must win.

**Three rows were added**, each a way the cage stands still that nothing else names:
- "the engineman is fumbling the levers" — a slip at his post;
- "no banksman to run off coal", the bank's counterpart to "no onsetter to load coal";
- "men waiting at bank" or "at the pit bottom" — somebody across the shaft whom he has not been
  sent for, which is the commonest reason a player's cage sits where they last put it.

**`Winding` names its deck's loader and unloader** (`loader:`, `unloader:`), so the board can say a
deck is being worked without naming conduits of its own.

**The two slips are asserted on `Winding#signal` at zero ticks.** A slip begins from a die thrown
in phase 0, so `seed` cannot construct one. The function is pure, and the slip flag is all the
tick hands it, so the claim is the same. Every other row is one tick from a constructed state.
