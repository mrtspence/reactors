# The failure model: what a broken part becomes

> **Status: DESIGN, 2026-09-14. Reviewed and settled; nothing is built.** This is the sketch
> [`blueprints.md`](blueprints.md) §3 said would be needed and deliberately did not write, and
> it is what `current_progress.md` playtest item 2 has been blocked on since 2026-09-05.
>
> Framing: *"the actual failure methods must be overridable properties of the hazardous
> concerns … Specific parts must always be able to override their concerns as specifics of
> geometry/etc must trump all. Alternatively, and perhaps better, would be creating new
> concerns that express the failure modes concretely and letting the specific parts simply
> include them."*
>
> The finding is that both proposals put the failure mode in a concern, and the measurement in
> §1 says a node **already has** the right home for four of the five things a failure does. What
> is missing is smaller and more specific than either proposal: a vocabulary wider than one
> boolean, a failure that can get worse, and the one effect a node genuinely cannot express
> about itself — a hole in the graph.

---

## 1. What exists, measured

`Concerns::Wearing` is the detection half and it is in good shape. Stress accumulates
deterministically (`stress_per_second`), brittle limits fail on the tick they are passed
(`overload?`), `integrity` scales the limit so history keeps mattering, and the rolled starting
durability is hidden so the uncertainty lives in the part rather than in a dice roll.

The consequence half is one boolean. `broken: true`, and here is **every** place in the
simulation that reads it:

| Site | What it does |
|---|---|
| [`tick.rb:567`](../../lib/reactor_sim/tick.rb#L567) | zeroes `angular_momentum` if the state has any |
| [`tick.rb:320`](../../lib/reactor_sim/tick.rb#L320) | a driver does no work on a broken shaft |
| [`arbiter.rb:639`](../../lib/reactor_sim/graph/arbiter.rb#L639) | drive links touching a broken node transmit nothing |
| [`conduit.rb:123`](../../lib/reactor_sim/nodes/conduit.rb#L123) | `throughput_kg` → 0 |
| [`conduit.rb:170`](../../lib/reactor_sim/nodes/conduit.rb#L170) | `gas_conductance` → 0 |
| [`cylinder.rb:189`](../../lib/reactor_sim/nodes/cylinder.rb#L189), [`:399`](../../lib/reactor_sim/nodes/cylinder.rb#L399) | draws nothing, makes no torque |
| [`vessel.rb:110`](../../lib/reactor_sim/nodes/vessel.rb#L110) | the heater stops |
| [`operation.rb:150`](../../lib/reactor_sim/operation.rb#L150), [`sources.rb:191`](../../lib/reactor_sim/diagnostics/sources.rb#L191) | reporting |

Read that table as a statement about coverage and it says: **failure is implemented for things
that spin, and for nothing else.**

### The three bugs already in it

- **A ruptured vessel is a sealed vessel.** `Vessel` and `Boiler` guard only the heater. A
  boiler that has burst keeps its contents, keeps its pressure, and keeps making steam. There is
  no state in which the destruction of the most dangerous part in the engine does anything at
  all.
- **A ruptured pipe is a stronger seal than a working one.** `throughput_kg` → 0 is the
  behaviour-by-omission `blueprints.md` §3 rules out by name. The TODO at
  [`conduit.rb:114`](../../lib/reactor_sim/nodes/conduit.rb#L114) has said so since the node was
  written.
- **And it is worse than a plug.** `gas_conductance` → 0 makes `gas_coupling` return `nil`
  ([`arbiter.rb:238`](../../lib/reactor_sim/graph/arbiter.rb#L238) rejects any conductance
  `<= 0.0`), so the path stops being pressure-driven **entirely**. `graph/CLAUDE.md` records what
  that costs when it happens by accident: *"a single missing number deletes the draught, the
  chimney and the blower together, with no error of any kind."* One ruptured flue section does
  that on purpose. A failure that changes the *regime* of a path rather than its rate is not a
  hobbled machine, it is a different machine.

### One failure mode is already built, correctly, and it is not in a concern

`Nodes::FusiblePlug` is a working, irreversible, latched failure that changes the graph's
behaviour: it senses a state key on another node and opens a path that was shut. It lives in a
**node**, it is configured in the chassis definition, and its whole implementation is
`open_fraction` reading its own latch. That is the shape the rest of this should take, and §3
is largely the argument that it generalises.

---

## 2. Cause and mode are many-to-many

The two questions a failure asks are genuinely independent, and every design that hangs one off
the other gets a case wrong:

| | Question | Answered by | Status |
|---|---|---|---|
| **cause** | what conditions destroyed this | `stress_per_second` / `overload?` | built |
| **mode** | what the part is now | `broken: true` | one bit |

- A boiler can be destroyed by **over-pressure** or by a **dry crown sheet**. Different causes,
  same mode: a hole in the drum.
- Over-pressure at 1.1× rating produces a **seam split** and at 3× produces an **explosion**.
  Same cause, same concern, different modes, and the difference is the whole gameplay distance
  between "limp home" and "that is the run".
- A cylinder that hydro-locks bends a rod; one that is run dry and hot scores its bore. Both are
  `Wearing` on the same node.

So the mode cannot be a property of the concern that noticed the stress, and it cannot be
derived from `cause:` either. **It is a third thing the node decides at the moment of failure,
from the conditions at that moment** — and, per §5, decides again every tick afterwards.

---

## 3. The two proposals

### A — failure methods on the hazardous concerns

`Pressurized#rupture`, `Rotating#fly_apart`, `Thermal#melt`, `Holds#leak`, each overridable per
part.

**Pros.** Zero inclusion boilerplate — if you are `Pressurized` you can rupture, automatically,
and a node author cannot forget to opt in. Excellent discoverability: the concern table in
`concerns/CLAUDE.md` would list what each concern can do *to* you next to what it does *for*
you. It also matches the instinct correctly on one point — "a pressure vessel can split or
explode" really is a reusable statement, not a per-part one.

**Cons.**

1. **The concern that detects the stress does not own the consequence.** A boiler letting go
   vents its *contents* (`Holds`), its *energy* (`Thermal`), through a *breach* (topology it has
   no access to), because its *shell* (`Pressurized`) failed. One failure, four concerns, and any
   choice of owner is wrong somewhere.
2. **`Rotating` is included by `Load`, which includes no `Wearing` and must not fly apart.**
   Hanging failure off a hazardous concern makes capability and hazard the same declaration, and
   they are not: `Load` is where work leaves the operation, it spins, and it is not a hazard.
3. It re-couples cause to mode, against §2.

### B — failure-mode concerns a part includes and calls

`Concerns::Vents`, `Concerns::Severs`, included explicitly, the part calling the right one with
its internal state.

**Pros.** The separation in §2 falls straight out — including `Vents` says nothing about what
broke you. Opt-in is explicit, so `Load` is safe by construction. A failure mode becomes a
nameable, testable unit.

**Cons.**

1. **"Calls the correct method" fights the engine everywhere else.** Nodes do not *do* things;
   they declare intent against a frozen previous tick and the engine settles every claim at once.
   A node calling `rupture!` inside `apply` would be reaching for mutation it cannot have — the
   graph is configuration, `Path.resolve` runs at construction, and `apply` returns a state hash.
2. **Four of the five effects would be concerns wrapping a one-line `case`.** Measured below.
3. Six concerns to express what a burst boiler does is more ceremony than the codebase spends on
   anything else, including chemistry.

### Recommended: neither, and the reason is measurable

Enumerate what a failure actually *does* to a running simulation, across every hazard this engine
has or will plausibly have, and it comes to five effects. Four of them already have a home:

| Effect | Example | Where it lives today |
|---|---|---|
| **Sever** | burst flywheel leaves the drivetrain | `Arbiter.settle_drive` + `Tick#transmit_torque` — **built, generic** |
| **Release** | the wheel's KE wrecks the shop | `Tick#stress` ledgers it as `joules_to_friction` — **built, generic** |
| **Seize** | a jammed damper stops answering its lever | `Conduit#open_fraction` reading its own state — **the `FusiblePlug` pattern** |
| **Derate** | a scored bore, a fouled tube, a dragging bearing | the node's own `apply` / rating methods — **one `case` each** |
| **Vent** | boiler ruptures, pipe leaks, cylinder head lets go | ✗ **nowhere. Needs topology a node cannot reach.** |

That is the finding. **A node already has the right home for a failure mode: its own two
methods.** `nodes/CLAUDE.md` says it outright — *"`apply` is only for what makes this node
**this** node"* — and a bent rod is exactly that. Both proposals would move per-part specificity
*out* of the node and into a concern, then immediately need the override to put it back, which is
the framing's own escape hatch ("specifics of geometry must trump all") doing all the work.

So the recommendation is:

> **Widen the vocabulary, let it escalate, build the one missing effect, and leave the rest in
> the nodes.**
>
> 1. `broken: true` becomes `failure: <mode symbol>` — §4.
> 2. A broken part keeps wearing, and a failure can get worse — §5.
> 3. A **breach** becomes a real part in the graph, dormant until it is not — §7.
> 4. Concerns supply a **default mode table**, which a part overrides. Data, not methods — §8.

Point 4 is where the framing's instinct is kept: the reusable thing about a pressure vessel is
*which modes it has*, not *what they do*. That is a table, it costs nothing, and overriding it is
one method.

**Tradeoffs, stated plainly.**

- Loses A's automatic coverage. A node that can be destroyed but declares no modes gets the
  generic `:failed`, which is a real footgun — `nodes/CLAUDE.md` already records that *"a
  capability nothing exercises is indistinguishable from one that does not work"* about exactly
  this class of default. Mitigation in §12: a spec that walks every `Wearing` node in every
  registered operation and asserts it names its modes, the same shape as the `content_spec` rule
  that every structural material be rated.
- Loses B's explicit per-mode unit to test. Mitigated by the modes being data: a table can be
  asserted directly, which a `case` in `apply` cannot.
- Puts a handful of inert nodes in every graph. Measured cost in §7: zero ticks of work, and they
  are visible in the chassis definition, which this codebase counts as a benefit ("declare the
  relationship in config so it stays visible").

---

## 4. `broken` becomes a mode

```ruby
# Concerns::Wearing
{ durability:, initial_durability:, failure: nil }   # was `broken: false`

def broken?(state) = !state.fetch(:failure, nil).nil?
```

Every existing reader in the §1 table is `if broken?(state)` or `state[:broken]`; the former is
unchanged and the latter becomes `state[:failure]`, which is truthy on exactly the same ticks.
No behaviour moves in this step. It is a pure widening.

The node names the mode:

```ruby
# Concerns::Wearing — the one new authoring hook on the detection side
def failure_mode(_state, _ctx, _cause) = :failed
```

> **As built (stage A):** both the overload and fatigue routes converge on
> `Wearing#break_part(state, ctx, cause)`, which is the single sound → failed transition and
> currently reads `mode = GENERIC_FAILURE`. Stage B is one line there —
> `mode = failure_mode(state, ctx, cause)` — plus the escalation loop in §5. Having one
> transition point rather than two was worth the small refactor on its own: naming the mode in
> two places is exactly how a cause and its consequence drift apart.

It receives `cause` because the same node often splits on it — a cylinder's `:overload` is
hydraulic lock and its `:fatigue` is a worn bore — and the conditions because the severity band
is a reading at that instant:

```ruby
# Nodes::Boiler
def failure_mode(state, ctx, _cause)
  over = pressure_pa(state, ctx.content) / rated_pressure_pa(ctx.content)
  over > EXPLOSION_RATIO ? :explosion : :seam_split
end
```

`failure_type` and `failure_detail` already live on the node for the event; this sits beside them
and the event carries all three. A gauge, a log line and a post-match report all want to know
that it was an explosion rather than a split, and today none of them can.

### The JSON trap, and it is the fifth in this family

**`failure` is a symbol held as a value.** `deep_symbolize` converts keys only, so a restored
snapshot gets `"explosion"` and `!nil?` is still true — the part stays broken, in a mode nothing
matches, and every `case` falls to its else branch. `Operation#restore` must normalise it, beside
the four it already normalises (parcel resource ids, instrument flags, minion stations, loadout
part ids).

**The digest cannot catch this.** `canonical` runs through `JSON.generate`, where `:explosion`
and `"explosion"` are the same string, so a round-trip spec passes with the bug present. Only an
identity assertion — `be(:explosion)`, never `eq` — finds it. This is the trap
`lib/reactor_sim/CLAUDE.md` documents four instances of; adding a fifth means adding the line to
that list in the same commit.

---

## 5. Failure escalates, and the early return has to go

`apply_wear` returns early on a broken node:

```ruby
return [ state, [] ] if state.fetch(:broken)
```

That is a footgun, and the reason is general rather than steam-specific: **an early, mild failure
must never immunise a part against a catastrophic one.** A cracked pipe that goes on being fed
should be able to tear open. A reactor that has already lost a seal must still be able to melt
down. Today the first failure a part suffers is the last thing that can ever happen to it, and
for the most dangerous machines that is exactly backwards — it makes a minor failure a *safe
harbour*.

So a broken part keeps being evaluated. Three rules make that well-behaved:

1. **The mode table is ordered by severity**, and a mode may only move forward. Ruby hashes
   preserve insertion order, so `failure_modes` already carries the ordering with no new
   concept — `Wearing` compares indices and ignores any recomputed mode that is not worse than
   the current one. An explosion never relaxes into a seam split.
2. **An event is emitted only on a transition.** Recomputing every tick without this would emit a
   failure event at 4 Hz forever.
3. **Fatigue cannot escalate; overload can.** Durability is already spent, so `stress_per_second`
   has nothing left to consume — escalation is therefore driven by `overload?` and by
   `failure_mode` re-reading the conditions, which is the right story anyway: a split drum that
   keeps being fired reaches explosion conditions, and one that is shut down does not.

This is also what makes **multiple, escalating breaches** work, which is a natural failure mode
for a great many parts: each breach is its own node reading the same latch, opening at a
different mode, so a part that splits and then lets go simply has a second and larger hole open.
Nothing needs to be added to support that, and nothing should be added to forbid it.

**Stub, do not guess.** Stage A lands the loop and the ordering with every node declaring a
single mode, so escalation is structurally live and behaviourally inert. What a second failure on
an already-failed part *should* do is a per-part question and gets answered per part, in §12's
measurement stage.

---

## 6. Run-ending is emergent; collateral damage is fiat

### The run

The temptation is a `severity:` or `fatal: true` on the mode, so that a burst boiler can be
declared to end the run.

**Don't.** A boiler with a full-bore hole in it has no pressure, so the chest has no steam, so
the cylinder makes no torque, so the flywheel coasts down and the engine stops. That is the run
ending, derived from the physics, with no new concept and no number anybody has to keep
consistent with the effects. It is the same rule that `nodes/CLAUDE.md` states as *"a
conservation clamp is not a mechanism"* and that `transport_model.md` reached about the
`extractable_joules` bound: when the outcome falls out of the model, do not also assert it.

The corollary is that the **mode's parameters must be strong enough to actually end it**. If an
explosion's breach area is timid, the engine limps and the design has quietly lied. That is a
measurement, and §12 makes it one.

The same applies to what the player sees. A pressure gauge on a burst boiler reads zero because
the pressure *is* zero — no instrument needs to know about failure. (An instrument's **own**
failure — a stuck needle, a gauge reading the last good value forever — is a different and
genuinely missing mechanic. It belongs in the diagnostic chain as a `Filter`, it is now possible
because a gauge is a part, and it is out of scope here.)

### What a failure does to what is next to it

A bursting part throws its structural energy at its surroundings, and that matters in exactly two
places: **it breaks adjacent or linked machinery, and it injures nearby minions.** Both are
consequences the failure can simply declare.

> **Structural energy is fiat. It does not go on the ledger and it is not new physics.**

There is no strain-energy term, no shrapnel, no blast model. A mode names what it damages and by
how much, and the engine spends that as durability on the named parts. Conservation is untouched
precisely because nothing is created: damage is a durability write, not a joule.

> **Corrected on the build: the casualties are not in the mode table.** This section put
> `damages:` alongside `vents:` and `derates:` as one more entry. That breaks the rule that
> everything under `nodes/` is generic — `Nodes::Boiler` cannot name a `:cylinder`, because a
> boiler in some other machine has no cylinder near it. **Which modes exist belongs to the class;
> who is standing next to it belongs to the machine.** So they are two declarations:
> `failure_modes` in the class, and `failure_damages` — `{ mode => { node_id => share } }` —
> configured per instance, on the steam engine's drum rather than on `Nodes::Boiler`.
>
> `Tick#spread_damage` spends it, **after** every node's wear is settled rather than inside the
> map, so two parts failing on the same tick and damaging each other give the same answer
> whatever order they are visited in. Phase 6 obeys order-independence like everything else.
> The share is of the bystander's *starting* durability, so one figure means the same thing to a
> light fitting and a heavy one, and it is spent on the **transition only** — otherwise a failed
> part would grind its neighbours to nothing at the tick rate.

The alternative — modelling release energy properly so that neighbours are damaged by something
derived — would be a whole physics for one narrative beat, and it would need a notion of *place*
(§10) before it could even name a neighbour. Fiat is not a shortcut here; it is the right scope.
The contents leaving through the breach are a different matter and are real advected enthalpy,
handled for free by the transport that already exists.

---

## 7. A breach is a part, not a flag

This is the one architectural call in the sketch.

### Why it cannot be dynamic

The graph is configuration. `Path.resolve` runs at construction, `validate_graph!` runs at
construction, `options:` must reproduce the graph's shape from a snapshot, and `blueprints.md` §3
already rules out changing the node list under a running tick. **There is no way to add a link
mid-match, and there should not be one.**

### Why that costs nothing

Because the conduit's restriction is *already* dynamic, and a shut one is already free:

```ruby
# Conduit
def gas_conductance(state, ctx)
  @conductance * open_fraction(ctx)          # conductance is state-dependent TODAY
end

# Arbiter.gas_coupling
return nil if conductances.any? { |k| k <= 0.0 }   # a shut path is not pressure-driven
```

A breach fitted with `open_fraction` → 0 contributes nothing to any pressure solve, passes no
mass (`throughput_kg` → 0), and is not on any other path, so it cannot poison a regime the way an
accidental missing conductance does. It is inert until the part it watches fails. **The engine
already runs such a node** — `FusiblePlug` is precisely this, shut and waiting, and it costs
nothing measurable.

### The part

```ruby
# Nodes::Breach < Conduit  — a hole that is not there until it is.
Breach.new(id: :boiler_breach,
           senses: :boiler,               # whose failure opens me
           opens_by: { seam_split: 0.03,  # fraction of full bore, per mode
                       explosion:  1.0 },
           max_kg_per_s: ..., conductance: ...)   # one_way is forced on
```

> **`to:` was dropped on the build, and dropping it serves §10 better than keeping it.** A
> breach is a transport node, so where it spills is its outlet's **link** — which is already how
> every other route in this engine is expressed. A `to:` argument would have been a second
> declaration of the same fact, free to disagree with the link. Pointing a breach at a room
> rather than at the sky is therefore a change to one `Link` and nothing else, which is exactly
> the property that section asks for. The steam engine's drum wires
> `boiler:breach_out → boiler_breach → atmosphere:spill`.

`open_fraction` is `@opens_by.fetch(sensed_failure, 0.0)`, read from `ctx.node_state(@senses)`
exactly as `FusiblePlug#sensed_value` does — previous tick, order-independent, no new contract.
Always one-way: a hole lets contents out and must never let the graph breathe in through it.

**Give it a negligible heat capacity.** It is a `Conduit`, so `Tick#carry_through` will mix the
escaping stream with its wall; for the geometry every rupture in this game will have, transient
heat lost to the hole is not a quantity worth modelling, and a wall with no thermal mass keeps it
from being an accidental free heat sink on the way out of a ruptured boiler.

This is a direct sibling of `FusiblePlug` and shares its defence: *a device whose defining
property is that it is irreversible must not be built on one that is reversible.* A breach reads
a latch that never clears, so it cannot heal. The one difference worth writing down is that a
plug is a **safety device that operates deliberately** and a breach is **damage**, which is why
they ledger differently — §9.

### Conduit stops plugging

> **Corrected on the build.** This section proposed a `leak_derating(state)` factor on
> `throughput_kg`, so a ruptured pipe passed *most* of its rating and the breach dumped "the
> rest". That is wrong twice over. **A hole in a pipe does not reduce its bore** — the pipe
> still passes what it always passed. And "the rest" is not a quantity: a conduit is a transport
> node that holds nothing, so anything it declines to pass simply stays with the upstream
> holder as back-pressure. There was no leak in it at all, only a throttle.
>
> What actually starves the far end is that **the upstream holder is now being drained by two
> paths**, and the arbiter apportions between them. So the breach is the entire mechanism and
> `Conduit` needs no failure term whatsoever:

```ruby
def throughput_kg(_state, ctx)        # both `broken?` guards deleted outright
  port(:outlet).capacity_kg(ctx.dt) * open_fraction(ctx)
end
```

Both guards go. The `gas_conductance` one was the more dangerous of the two — at zero it does
not shut the path, it drops the path out of the pressure-driven regime entirely (§1).

**The honest consequence: a ruptured conduit with no breach beside it now does nothing at all.**
That is a deliberate trade rather than an oversight. Plugging was *wrong* — a rupture is not a
better seal than the working part — and a subtraction would have hidden the spill inside a term
where it could be neither sized nor pointed anywhere. Conduit breaches are stage D.

This also disposes of the open question this section used to carry, about the leak splitting a
stream rather than a pressure difference. The breach is its own path with its own conductance,
so it is rated by the pressure across it like anything else.

---

## 8. Modes are data a concern supplies and a part overrides

This is where the framing's reuse instinct lands, and it is one method:

```ruby
# Concerns::Pressurized — the reusable half: which modes a pressure vessel HAS,
# in ascending severity, because §5 escalates along this order.
def failure_modes
  { seam_split: { vents: 0.03 },
    explosion:  { vents: 1.0, damages: { flywheel: 0.4 } } }
end

# Nodes::Cylinder — geometry trumps, exactly as the framing requires
def failure_modes
  { scored_bore: { derates: { compression: 0.55 } },
    bent_rod:    { derates: { stroke: 0.0 } },
    blown_head:  { vents: 0.6 } }
end
```

A plain method returning a hash, which is precisely the existing idiom for `reactions`:
*"chemistry is data; a node just declares which reactions can happen inside it."* Deliberately
**not** a class-level DSL — there is not one anywhere in this library, and config-as-readers is
the established convention. One idiom, not two.

What consumes the table:

- `Wearing` reads the **key order** for the escalation rule in §5.
- `Breach` reads `vents:` to size its opening (or takes `opens_by:` directly — settled at review:
  **`opens_by:` for now**, because it keeps the hazard visible at the site where it is wired,
  which is the codebase's stated preference; revisit once there are enough breaches to see
  whether the duplication actually hurts).
- The **node's own `apply`** reads `derates:`, because what a derating means is the node's
  business — the same division `Obstructs` already draws, where the concern gives you `occupancy`
  and stops because "what it means is the node's business".
- The engine spends `damages:` as durability on the named nodes (§6), once, on the transition.
- A build-time spec reads the whole table and asserts every mode a `failure_mode` can name has an
  entry, which is the check that makes the generic `:failed` default safe.

---

## 9. `mass_spilled` finally gets a writer, and it is a port

`mass_spilled` is declared in `Ledger` and documented as *"Reserved — nothing writes it yet."*
A breach is the node it was reserved for. But the writer is not where it first looks:

**`Atmosphere` is the boundary, and it books everything it receives as `mass_vented`** in one
lump (`mass_vented: grant.total_received`, [`atmosphere.rb:100`](../../lib/reactor_sim/nodes/atmosphere.rb#L100)).
So a breach discharging to the sky is currently *deliberate discharge*, which balances the books
and is semantically a lie — and the class comment is explicit that the gross figures exist so
that *"a fuel gauge, air-supply gauge or efficiency readout"* can be built on them. A safety
valve lifting and a boiler bursting must not be the same number.

The fix is one port, and `Atmosphere` already takes `ports:` as a constructor override:

```ruby
Port.new(id: :intake,  direction: :outlet, accepts: [ :gas ])
Port.new(id: :exhaust, direction: :inlet)     # deliberate  -> mass_vented
Port.new(id: :spill,   direction: :inlet)     # damage      -> mass_spilled
```

`apply` books `received_at(:exhaust)` and `received_at(:spill)` separately, and `record_injections`
gains one sum line beside the `mass_vented` one it already has. Per-port rather than per-node is
the existing rule for anything where a node's ends must be allowed to disagree
(`Node#transport_affinity` documents exactly this reasoning).

Conservation is unaffected — `Ledger.mass_out` already sums both keys.

---

## 10. What this must not foreclose: repair and place

From `blueprints.md` §3: repair is a minion job, and **what a broken part spills can prevent the
crew from reaching it.** That makes the spill's *destination* load-bearing later, and it means
`to: :atmosphere` must be a parameter from the first commit rather than a hard-coded universal
sink. Today every breach points at the sky; when the simulation grows a notion of place, some
point at a room instead, and nothing about the breach changes but that argument.

Two more things the design must stay compatible with, neither of them built:

- **Pre-match wear.** Blueprints mint fresh instances, but a future unlock hands a part out with
  durability already spent and a maintenance report to read or skip. `Wearing` rolls
  `initial_durability` from the seeded rng and needs no change — a pre-worn part is a different
  roll, not a different mechanism.
- **In-match repair** clears `failure` back to `nil` and restores durability. The breach is a
  pure function of the sensed latch, so it shuts again on its own with no repair-side code at
  all. Worth checking that this stays true whenever a mode is added: a mode that is irreversible
  *by design* (a shattered casting) must say so in its own table entry rather than by being
  unclearable in practice.

---

## 11. Failure is still unrelated to `when_empty:`

Restating from `blueprints.md` §3 because this sketch is where the two would get conflated: a
slot's `:bypass` says what the topology is when a part is **never fitted**, decided at build. A
failure mode says what a **fitted** part does once broken, decided in the tick. Reusing the
bypass link for a failure would silently repair the machine at the moment it broke. A breach is a
*third* link and neither of the other two.

---

## 12. Staging

Each stage is independently shippable and leaves the suite green.

> **One thing a stage-A draft of this table got wrong**, corrected on the build: it claimed the
> digest would "still match bit for bit". It cannot, and should not — renaming a state key
> changes `canonical`, so a snapshot taken before stage A has a different digest after it, and a
> pre-existing `broken: true` restores as *sound*. That is acceptable only because match state is
> disposable pre-release. **Any later stage that changes a state key inherits the same break**,
> and once matches are durable it needs a migration rather than a note.

| Stage | Work | Proves |
|---|---|---|
| **A** | `broken:` → `failure:`; `broken?` derived; `Operation#restore` normalises; `break_part` as the single transition; identity assertion in `failure_spec`; CLAUDE.md trap list gains its fifth entry | pure widening — no physics moves and every existing assertion holds on the new key. **Built 2026-09-14.** |
| **B** | `Atmosphere` gains `:spill` (+ `Grant#received_kg`); `record_injections` sums `mass_spilled`; `failure_modes` / `failure_mode` / `escalate_to`; the escalation loop from §5, live but inert; all five node classes name their modes; the walk spec | the vocabulary exists, nothing is unlabelled, and no early return immunises a broken part. **Built 2026-09-14.** |
| **C** | `Nodes::Breach`; `Conduit` stops plugging and stops zeroing its conductance; one breach on the steam engine's boiler, sized from a sweep | **the measurement stage** — see below. **Built 2026-09-14.** |
| **D** | `failure_damages` spent on the transition; flash evaporation decides the boiler's mode (§14), which is what finally makes `:explosion` reachable | **partly built 2026-09-14.** Still open: breaches on cylinder, chest and main steam pipe, and `derates:` consumed by cylinder and vessel |

### Stage C is measurement-first, like the transport model

The transport model earned its corrections by sweeping the parameter and printing the outcome
rather than by asserting a tuned number, and this wants the same treatment. Three things to
measure before any of it is trusted:

1. **Sweep breach area against time-to-stop**, from a weep to a full bore. §6 claims run-ending
   falls out of the physics; that claim is false if a 100% breach leaves a working engine, and it
   is uninteresting if a 3% breach also stops it dead. **What is wanted is a boundary that is
   operable** — a small leak the driver can work around, a large one they cannot — and if the
   curve turns out to be a cliff, the mode table is wrong, not the physics.
2. **Confirm a leaking pipe starves downstream without stalling upstream.** That is the specific
   claim in the conduit TODO and it is the one §7 flags as possibly too crude.
3. **Confirm conservation holds across a burst**, on both keys. `mass_spilled` getting its first
   writer is exactly the sort of change that puts mass on a line nothing sums.

Assert *events and directions*, never tuned occupancies — the lesson `hydrolock_spec` records.

### What the measurement actually found

**There is an operable band, and the first guess missed it by four orders of magnitude.**

The breach was sized against the safety valve, on the reasoning that it is the only other hole
in the drum with a physical meaning. Every fraction from 0.03 down to 0.0005 took a 175 rpm
engine to a standstill — a perfect cliff, and the sketch's own rule said that meant the mode
table was wrong. It did, but the error was the *reference*. A safety valve only opens above its
setting; a breach is open always. **The number to compare against is the regulator wide open**
(`conductance: 1.5e-3`), which is the hole this engine's entire output already goes through.

Swept on a worked engine (175 rpm, 608 kPa, 2034 kg in the drum) — rpm at +600 ticks:

| conductance | 2e-5 | 1e-4 | 4e-4 | 2e-3 | 2.0 |
|---|---|---|---|---|---|
| rpm | 175 | **151** | 80 | 18 | 2 |
| spilled kg | 26 | 111 | 230 | 294 | 2150 |

`seam_split` is therefore **1e-4**: the engine loses speed slowly, and a driver who damps the
fire and runs for the shed has a decision worth making. The area is honest too — 5e-5 of the
shell is about 8 cm² on a drum this size, a hole three centimetres across, which is what a
weeping seam is. `explosion` opens the whole bore and empties the drum inside a hundred ticks.

**§6 holds: run-ending is not declared anywhere.** The engine stops because there is no
pressure, because there is a hole.

### The hazard the breach exists for is not reachable by pressure

Measured after stage C landed, because a mechanism nothing can trigger is the same defect as a
rating of infinity. Firing hard for 6000 ticks, with the safety valve removed **and** the fusible
plug removed:

| | rated | peak | ratio | durability |
|---|---|---|---|---|
| ordinary, valve fitted | 1458 kPa | 609 kPa | 0.42× | untouched |
| hard fire, no safety valve | 1458 kPa | 770 kPa | 0.53× | untouched |

**The drum never gets past 0.53 of its cold rating and never loses a point of durability.** So
`:explosion` — which needs 1.5× — cannot be named by any pressure this engine can produce, and
`:seam_split` cannot be reached by over-pressure either. The shell is rated at nearly 2.4× its
own working pressure, which is a *correct* boiler and a sound piece of engineering; it simply
means over-pressure is not the hazard here.

That leaves the **crown sheet** as the route in, which is historically the right answer — far
more boilers were destroyed by low water than by over-pressure. Starving the feed and working
the engine:

| | water left | durability | failure | events |
|---|---|---|---|---|
| plug fitted | 0 kg | **949 (untouched)** | none | `fusible_plug_melted` |
| **no plug** | 619 kg | **0** | **`:seam_split`** | `vessel_rupture` |
| no plug, no valve | 694 kg | 0 | `:seam_split` | `vessel_rupture` |

So the chain is complete and it is the one the period sources describe: run the water down, the
plate softens, the shell tears along a seam at ordinary working pressure, and the breach empties
the drum into the shop. The fusible plug is a **real save** — with it fitted the drum comes
through untouched. `spec/reactor_sim/crown_sheet_spec.rb` asserts both halves.

Note what this confirms about §2: the **cause** is a dry crown sheet and the **mode** is a seam
split, and no amount of knowing the cause would have told you the mode. It is the pressure
behind the metal that decides, exactly as `EXPLOSION_RATIO`'s comment predicted.

**`:explosion` was decoration, and the fix was to change the criterion, not the ratio.**
Nothing this engine can do reaches 1.5× the rating, so the mode could never be named. See §14.

### Three ways the measurement lied before it told the truth

Worth recording, because each looked like a clean result:

- **Time-to-stop measures the flywheel, not the failure.** Seam split and explosion both
  reported 1182 ticks — that is a 3 200 kg wheel coasting down once the steam has gone, which is
  identical however the steam went. Measure the engine *while it is still being worked*.
- **An invented lighting schedule put the fire out.** A rewrite dropped the igniter and blower
  at tick 400, and swept eight breach sizes against an engine that had never turned over. Every
  row read `0 rpm / 31 kPa` — beautifully consistent, entirely meaningless. **Use the suite's
  own schedule** (igniter off at 300, regulator at 1200, blower off at 1600).
- **Total spill saturates.** A full-bore breach finishes inside a couple of ticks, so comparing
  twenty-tick totals compares "done" against "still going": it reported a 3× gap for a 10,000×
  difference in hole size. Compare **what is left in the drum**.

**A trap this codebase has already paid for twice**: a rating of infinity and a rate of zero are
silent off switches, and a mode table that no operation names is a third one. Stage B's walk is
the guard, and it should fail loudly rather than warn.

---

## 13. Settled at review

| Question | Decision |
|---|---|
| Breach reads `failure_modes` or takes `opens_by:`? | **`opens_by:`**, for now — visible at the wiring site. Revisit if duplication bites. |
| Does a breach need its own thermal mass? | **No.** Negligible heat capacity; the geometry of these ruptures makes transient wall heat not worth modelling. |
| What fails a part that is already broken? | **Removed the early return.** Failures escalate along an ordered mode table; a mild failure must never immunise a part against a catastrophic one. Stubbed per-part until measured — §5. |
| Where does a burst part's structural energy go? | **Fiat.** It matters only for breaking adjacent machinery and injuring nearby minions, both declared by the mode as `damages:`. No new physics, no ledger line — §6. |
| Multiple breaches on one node? | **Yes**, and expected: escalating breaches are the natural failure mode for many parts. The shape already allows it — §5. |

### Still open

- **What does a second failure actually do, per part?** Deliberately stubbed at stage B. Needs a
  part with a real escalation story to answer it.
- **An instrument's own failure.** Out of scope; belongs in the diagnostic chain as a `Filter`,
  and is newly possible now that a gauge is a part.

---

## 14. Flash evaporation: what actually destroys a boiler

Added after stage C measured `:explosion` as unreachable. The fix was not to lower the ratio —
it was that **a pressure ratio is the wrong question**.

A drum holds water at saturation *under pressure*. Open it, and the water is instantly
superheated with respect to its new boiling point; the excess sensible heat buys latent heat and
part of the water flashes to steam:

```
x = c_p · (T_sat(P_vessel) − T_sat(P_ambient)) / h_fg
```

At this engine's 609 kPa that is **11% of the water at once** — 362 kg from a full drum, which is
**604 m³ at atmospheric trying to leave a 5 m³ shell**. The saturation curve it needs is the one
`Resources::Saturation` already uses for everything else, so this is arithmetic over existing
machinery rather than new physics.

### One correction to the intuition, and it changes the criterion

**Flashing cannot raise the pressure.** Making steam costs latent heat, which cools the water, so
the pressure follows the water down rather than spiking above it. (A vessel run *water-solid*,
with no steam space, is the real exception — this engine has no such part.) So a model built on
"the flash over-pressures the shell" would be modelling something that does not happen.

What the accident literature attributes the destruction to is the **volume**: the potential
energy of the escaping steam and water "peels back the material around the break". So the
criterion is **how much flash steam is available, as a multiple of the drum's own volume** —
`Boiler#flash_expansion`. No rent passes ten vessel-volumes in the time a flash takes, so past
that the shell has to go.

### This inverts what the pressure rule said about the crown sheet

The pressure rule made a low-water crown-sheet failure a gentle `:seam_split`, and §12's first
draft of this document called that "a pleasing consequence". **It was backwards.** The accident
reports are unambiguous: a low-water crown-sheet failure at ordinary working pressure was *the*
catastrophic locomotive boiler explosion — staybolts let go one after another, then all at once,
and heavy engines were torn off their frames.

Measured at the real event, with the plug removed: the drum ruptures on tick 6111 holding 626 kg
at 609 kPa, **22.8 drum-volumes of flash steam**, and is now correctly an `:explosion`.

`FLASH_EXPANSION_FOR_RUPTURE` is **12**, not the 20 first guessed. 20 happens to give the right
answer here by 14%, which is too thin a margin for a case the history is unambiguous about and
an engine whose balance constants move. At 12 the crown-sheet rupture is explosive by a factor of
1.9, while the quiet regimes stay quiet: the same water at 265 kPa is 11.4, a nearly-dry drum
4.0, a cold one 0.

> **A methodological note worth keeping.** A synthetic sweep of the same water mass said 18.6 —
> straddling a threshold of 20 — because it evaluated a pressure the running engine never
> actually sits at. Tuning to that table would have put the canonical explosion on the wrong
> side of the line. **Measure the event, not a proxy for it.**

### What it unlocks

- `:explosion` is reachable, so the `failure_damages` hanging off it stops being decoration.
- The player-facing decision is now the right one: **how much water is in the glass decides how
  badly the boiler fails**, on top of deciding whether it fails at all. A drum run low is in
  more danger *and* is a bigger bomb, which is exactly the trap the period sources describe.
