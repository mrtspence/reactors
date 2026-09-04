# Ignition

**Status: BUILT (2026-09-03).** `lib/reactor_sim/physics/resources/ignition.rb`, specced in
`spec/reactor_sim/ignition_spec.rb`. This file is kept as the record of *why*; the current
reference is [`../reference/physics.md`](../reference/physics.md#ignition).

Three things changed on contact with reality, each after the model failed a run:

1. **Spread must not depend on bulk temperature.** The first implementation gated spread on
   `min_temperature_k` and failed in exactly the way the model it replaced did — a fire cannot
   reach 500 K without spreading, and cannot spread without reaching 500 K. A flame front is
   hot even when the room is cold. Bulk temperature moved to the *quench* side.
2. **The ignited fraction caps the FUEL term, not the finished extent.** Scaling the extent
   double-charges a fire for its draught, because `limit` is usually set by the air already. A
   grate with 46 kg of coal and 0.25 kg alight burned half a percent of what the air allowed
   and produced 9 kJ a tick instead of megawatts.
3. **The fire needs a short memory of the draught.** Air passes *through* a firebox and its
   standing inventory oscillates to zero every other tick. Read instantaneously, that says
   "starved" about a fire consuming barely one percent of what blows past it.

Measured outcome: the igniter is now held for ~150 ticks and then never again, and the engine
reaches 440 K / 747 kPa, 72 rpm, 54 kW on its own. Before, it had to be held at 100% forever.

## The problem, measured

A player has to hold the igniter at 100% more or less permanently. The fire is not really
*lit*; it is being held alight by an external heat source, which makes the igniter a
throttle rather than a match.

The cause is already documented as a known compromise
([`current_progress.md`](../current_progress.md)): **`min_temperature_k` means "the bulk
temperature at which this reaction sustains", not the ignition point**, because a node is one
lumped temperature and therefore has no hot spot to light. Coal's real ignition point is
~700 K; set there, no plausible firelighter could ever raise a whole firebox to it, so the
value is 500 K — well below the truth, and still the thing that decides whether the fire lives.

Measured behaviour today (light, then cut the igniter at t=400, watch to t=1400):

| damper | stoking | firebox K at 500 / 900 / 1400 | outcome |
|---|---|---|---|
| 85 | 70 | 672 / 690 / 713 | sustains |
| 60 | 60 | 583 / 597 / 615 | sustains |
| **40** | **50** | **338 / 328 / 327** | **out, permanently** |

So the fire *does* sustain — but only above roughly damper 60 / stoking 60, and the failure is
**silent, absorbing and unrecoverable**: below that band the bulk temperature falls under
500 K, the reaction stops completely, and nothing short of the igniter can ever restart it.
There is no smouldering, no partial burn, no ember. The player's only reliable strategy is to
leave the igniter on, which is exactly what happened.

Two things are wrong, and they are separable:

1. **Ignition is modelled as a bulk property.** It is a local one. A match does not raise a
   coal bunker to 700 K; it raises a few grams, which then raise their neighbours.
2. **The reaction is all-or-nothing at the threshold.** Either the whole grate burns or none
   of it does, so there is no low-power regime and no gradient for a player to read.

## Proposal — an ignited fraction

Carry, per node per reaction, the **fraction of the fuel currently alight**:

```ruby
state[:ignition] = { coal_combustion: 0.0..1.0 }
```

The reaction rate is then scaled by that fraction rather than gated by bulk temperature:

```
extent = limiting_reagent × ignited_fraction × (1 − e^(−rate_per_s × dt))
```

The fraction moves under three influences, all closed-form and deterministic:

| Influence | Effect on the ignited fraction |
|---|---|
| **An igniter** (`heater_control_id`, an arc, a pilot) | Drives it toward a small floor — enough to start, not enough to run |
| **Spread** | Burning fuel lights its neighbours, at a rate rising with bulk temperature and available oxidiser |
| **Quenching** | Falls when bulk temperature drops, when the oxidiser runs out, or when fresh cold fuel arrives |

The result is a fire that behaves like one: it catches slowly from a small seed, grows to fill
the grate, dies back when choked, and — crucially — **can be nursed back from an ember** rather
than needing the igniter again.

### What this buys

- **The igniter becomes a match, not a throttle.** It seeds a fraction; the fire grows itself.
- **A real low-power regime.** A quarter-lit grate is a legitimate operating state — a banked
  fire — instead of a cliff between "roaring" and "out".
- **The failure becomes legible.** "The Fire" already bands its prose; an ignited fraction is
  the natural thing behind it, so a player can watch a fire dying and act.
- **`min_temperature_k` stops being a lie.** It becomes what it says: the temperature at which
  spread outpaces quenching. Coal's real 700 K becomes usable, because the *fraction* is what
  survives below it, not the whole grate.
- **It generalises.** Any reaction that needs to be started rather than merely permitted —
  furnaces, kilns, a runaway — is the same mechanism with different rates.

### What it costs

- **Reactions grow state.** They are currently pure functions of the node's contents;
  this gives them memory. `Resources::Reaction` stays pure, but the node has to carry the
  fraction and the tick has to advance it, most likely as part of phase 5.
- **Three more numbers per reaction** to balance (`spread_per_s`, `quench_per_s`, and an
  igniter floor), and the steam engine's measured skill gradient will move.
- **Conservation must be re-checked.** The fraction scales extent, so nothing is created — but
  the conservation spec should be run against a fire that is deliberately part-lit, which is a
  state that has never existed.

## Alternatives considered

**Lower `min_temperature_k` further.** Widens the sustaining band, changes nothing structural:
still a cliff, still unrecoverable below it, still no low-power regime. Cheap, and worth doing
as a stopgap if the fraction is not built soon.

**Give the firebox a second, smaller "hot spot" node.** Physically honest — it is what the
lumped-temperature approximation is hiding — and needs no new concepts, just a node and a
thermal link. But it doubles the node count for every combustor, and the hot spot's size is as
arbitrary as any rate constant. Worth keeping in mind if the fraction turns out to need too
many dials.

**Let the igniter be cheap and leave it on.** Reframes the problem as a UI one. Rejected: it
makes an operating procedure into a permanent state, and the startup procedure is the most
interesting thing the engine currently asks of a player.

## Open questions

1. **Where does the fraction advance — phase 5, or its own phase?** It is chemistry-adjacent
   and reads bulk temperature and oxidiser, so phase 5 seems right, but it must happen before
   `run_reactions` uses it.
2. **Is the fraction per-reaction or per-node?** Per-reaction is more general; per-node is
   simpler and no operation currently hosts two competing combustions.
3. **Does fresh fuel arrive unlit?** It should — shovelling cold coal onto a fire damps it,
   which is a real effect a stoker has to manage. That makes the fraction depend on mass flow,
   not only on temperature.
4. **Should the igniter draw a resource?** Today it is free. A pilot light that consumes fuel
   would close the loop, but it is not needed for this to work.
5. **How does this interact with `Wearing`?** A part-lit firebox runs cooler; if stress is
   temperature-driven, a banked fire should be gentler on the grate. Probably falls out for
   free, but worth asserting.
