# Operator identity, and the dev escape hatch

> **Status: draft for review, 2026-09-19.** Prompted by the need to run two operations at once
> for testing, which the current one-match-one-operation shortcut cannot express.

---

## 1. What exists, and what it is standing in for

**There is no identity anywhere.** Three `TODO`s say so, in the three places it matters:

```ruby
# commands_controller.rb
# TODO: expedient — NO AUTH, AT ALL. Anyone who can reach this endpoint can drive the engine.

# operation_channel.rb
# TODO: expedient — anyone may watch anything, and everyone gets the player view.

# dev_player.rb
# TODO: expedient — there is exactly one hardcoded player, exactly as there is exactly one
# hardcoded match.
```

And every controller answers the identity question by string comparison against a constant:

```ruby
return head :not_found unless params[:match_id] == DevMatch::ID
return head :not_found unless params[:operation_id] == DevMatch::OPERATION_ID.to_s
```

That is four copies of a rule with no owner. It is also **why a second operation cannot exist**:
`DevMatch::OPERATION_ID` is a constant, the runner holds `{ DevMatch::ID => DevMatch.build }`,
and `MatchRunner#telemetry` reaches for `@matches.values.first`.

### 1.1 What is already the right shape

- **`ReactorSim::Match.create(operations: [...])` takes a list.** Many operations in lockstep is
  what the sim was built for; nothing in the engine needs changing to run two.
- **Commands already carry `operation_id`.** `set_control` and `assign_minion` both name it, so
  routing a command to the right machine is a lookup rather than a new field.
- **`StreamNames.operation(match_id:, operation_id:)`** is already per-operation, so two
  consoles on two cables work without touching the broadcast path.
- **`loadouts` and `rosters` are keyed `(match_id, operation_id)`** with a unique index. The
  storage already assumes several operations; only the code above assumes one.

**So the missing piece is genuinely just identity.** That is a smaller change than it looks.

---

## 2. The model

### 2.1 An operation is the thing that is owned

```ruby
create_table :operations do |t|
  t.string :match_id,     null: false
  t.string :operation_id, null: false
  t.string :type,         null: false   # :steam_engine — a registered Operations type
  t.string :owner_id,     null: false
  t.timestamps
  t.index %i[match_id operation_id], unique: true
end
```

**Not a column on `loadouts`.** A loadout is what is fitted and an operation is the machine
itself; a player who has never opened the outfitting screen still owns their engine. Hanging
ownership off a configuration row would make "does this exist" and "have you configured it" the
same question, and they are not.

**One owner, not a list.** *"One player per operation"* is the rule; spectators are a separate
permission on a separate axis (§2.3) rather than more owners.

### 2.2 Two permissions, because they diverge later

```ruby
operation.operable_by?(owner_id)   # may I pull this lever
operation.viewable_by?(owner_id)   # may I watch this dial
```

Today these are the same answer. **They are written as two methods from the start** because the
moment spectators exist they stop being — and a single `authorised?` would have to be split at
exactly the point when there is a live feature depending on its current meaning.

The projection already distinguishes them: `project(viewer: :player)` and
`project(viewer: :spectator)` both exist and the channel currently sends the player view to
everybody. `viewable_by?` is what will choose.

### 2.3 What a stranger gets

**Recommended: `404` for an operation you cannot view, `403` for one you can view but not
operate.**

- **Pros.** Not leaking existence is the right default for something you have no relationship
  with; but once spectating exists, a spectator who tries to pull a lever should be told *"not
  yours"* rather than *"no such thing"*, because they can see it on their screen and a 404 reads
  as a bug.
- **Cons.** Two failure modes rather than one.

**Alternative: 404 for everything.** Rejected for the spectator case above — it would make the
UI unable to distinguish "gone" from "not yours", and those want different words.

---

## 3. The escape hatch

**The requirement: a developer drives several operations at once, bypassing the one-player rule.**

### 3.1 It must be structurally absent in production, not merely switched off

**Recommended: a config flag whose initializer refuses to enable it outside development.**

```ruby
# config/initializers/operator_bypass.rb
enabled = ActiveModel::Type::Boolean.new.cast(ENV.fetch("REACTOR_OPERATOR_BYPASS", false))

raise "REACTOR_OPERATOR_BYPASS is not available in #{Rails.env}" if enabled && !Rails.env.local?

Rails.application.config.x.operator_bypass = enabled
```

- **Pros.** A misconfigured production **fails to boot** rather than quietly serving everybody
  everything. That is the same instinct as `content_spec` refusing a structural material with no
  temperature rating: a default that silently opens a gate is the failure mode worth designing
  against, and the loud version costs three lines.
- **Cons.** One more initializer, and a developer has to set an env var.

**Alternative: `Rails.env.development?` inline at the check.** Rejected — it scatters the rule
across every call site, which is what §1 says is already wrong with the match-id comparison, and
it gives no way to test the *enforcing* path in development.

**Alternative: a `developer` flag on the player record.** Rejected for now: there are no player
records, and a data-driven bypass is one row away from being granted in production by accident.
Worth revisiting when accounts exist — the seam below does not care which answer supplies it.

### 3.2 It widens who may operate, and nothing else

```ruby
def operable_by?(candidate)
  return true if Operator.bypass?
  owner_id == candidate.to_s
end
```

**The bypass may not fabricate an owner.** `owner_id` stays whatever it was, so every row still
says who the machine belongs to and turning the hatch off restores the real rule with no data to
repair. A bypass that wrote `owner_id = "dev"` would quietly rewrite the thing it was bypassing.

### 3.3 It is visible on the page

A console being operated through the hatch **says so** — a small marker beside the existing
`time ×N` badge. A development affordance that looks identical to the real thing is how a
developer ends up debugging the wrong rule for an afternoon, and the chassis/loadout mismatch
note in `app/CLAUDE.md` is the precedent for making a dev-only state legible.

---

## 4. The controllers

### 4.1 What changes

**`ApplicationController` gains the seam and nothing else gains a rule:**

```ruby
def current_player = DevPlayer::ID                    # becomes session-backed later
def current_operation = @current_operation ||= Operation.locate(params)
def require_operator! = head(:forbidden) unless current_operation&.operable_by?(current_player)
def require_viewer!   = head(:not_found) unless current_operation&.viewable_by?(current_player)
```

Every `params[:match_id] == DevMatch::ID` comparison is deleted and replaced by a `before_action`.
That is the whole point: **four copies of an unowned rule become one rule with a name.**

| controller | filter |
|---|---|
| `ConsolesController#show` | `require_viewer!` |
| `CommandsController#create` | `require_operator!` |
| `LoadoutsController`, `CrewsController`, and their drafts | `require_operator!` |
| `MatchResetsController#create` | `require_operator!` |
| `OperationChannel#subscribed` | `viewable_by?`, else `reject` |

**No new actions.** Every one of these is already one of the seven, and ownership is
authorisation — which `app/CLAUDE.md` explicitly lists as a controller's business.

### 4.2 `operation_id` stops being a constant

`CommandsController` currently writes `DevMatch::OPERATION_ID` into every command it builds. It
becomes `current_operation.operation_id`, which is the change that actually lets two consoles
drive two machines.

### 4.3 `DevMatch` becomes a seed rather than a singleton

It keeps its job — *"the ONLY code both web and runner touch"* — and stops hardcoding one
machine:

```ruby
DevMatch::OPERATIONS = { engine: :steam_engine, engine_b: :steam_engine }
```

The runner builds `Match.create(operations: …)` from that list, `MatchRunner#telemetry` stops
reaching for `@matches.values.first`, and `DevMatch.panel` memoises **per operation** as well as
per loadout — it is already a pure function of the loadout, so the same argument holds one level
down.

> **`TYPE` and `OPERATION_ID` are the constants to kill**, and they are the whole of gap 4 on the
> pre-mine list. Once operations are rows, the type comes from the row and both processes read it
> from one place — which is the `chassis:` lesson (`app/CLAUDE.md`) applied to the operation
> itself.

---

## 5. What this must not foreclose

- **Real accounts.** `current_player` returning a constant is the *only* thing that has to change;
  nothing else may learn that the id is fixed. That is already `DevPlayer`'s stated contract.
- **Spectators.** §2.2 splits the two permissions before there is a reason to, precisely so this
  is a widening rather than a refactor. The spectator projection already exists.
- **Several matches.** Nothing here assumes one, and the routes have carried `:match_id` since
  the beginning for this reason. The dev setup uses one match with several operations because
  the sim advances a match in lockstep, which is what makes two machines comparable.
- **Operations owned by different players in one match.** That is the actual multiplayer shape —
  several overseers, one plant — and an `owner_id` per operation row expresses it already.
- **Transfer of ownership.** A row with an `owner_id` can be updated. Do not bake the owner into
  the operation's id or into a stream name.
- **The broker bypass.** `commands_controller.rb` notes that anyone reaching the broker skips the
  controller entirely. Identity at the HTTP edge does not fix that, and this sketch does not
  claim to — it is a separate problem for when the ingress is not trusted.

---

## 6. Staging

| | |
|---|---|
| **A** | **`operations` table + `Operation` model**, with `operable_by?` / `viewable_by?` and a backfill for the existing dev match. Model and migration only — nothing reads it yet. |
| **B** | **The `Operator` bypass**: the initializer that refuses to boot enabled outside development, and `Operator.bypass?`. Specced both ways, which is the half that matters. |
| **C** | **The controller seam**: `current_player`, `current_operation`, the two filters, and the deletion of every `params[:match_id] == DevMatch::ID`. Behaviour-preserving for one operation. |
| **D** | **Two operations in the dev match**: `DevMatch::OPERATIONS`, the runner's list, `telemetry` per operation, the panel memoised per operation, the console marker. |
| **E** | **The channel**: `viewable_by?` on subscribe, and the spectator projection for anyone who is not the operator. Wants §2.2 to have been honoured. |

**A and B are independent and can land in either order.** C is the one that deletes code. D is
what the request was actually for; it is last because it is the one that needs the rest to be
true first.

---

## 7. Verification

- **A non-owner cannot pull a lever**, and gets `403` rather than `404` when they can see it.
- **A non-viewer gets `404`**, and the response is identical to one for an operation that does
  not exist — asserted side by side, because "identical" is the claim.
- **The bypass refuses to boot in production.** The initializer raises; asserted by stubbing
  `Rails.env`, because this is the example that stops the hatch shipping open.
- **With the bypass off, the dev player cannot drive an operation they do not own** — the
  enforcing path has to be exercised in development or it rots, which is the `DevPlayer.earn`
  versus `grant` argument one layer out.
- **With it on, they can drive both.** Two operations, two commands, both applied.
- **Commands carry the operation they were addressed to**, not a constant — the assertion that
  says §4.2 actually landed.
- **Two operations advance in lockstep and independently**: the same tick, different states, and
  a command to one does not move the other.
- **Ownership survives a loadout change.** Fitting parts must not touch `owner_id`, which is the
  §2.1 separation asserted rather than assumed.
- **`DevMatch.panel` is still a pure function**, now of `(operation, loadout)` — two operations of
  the same type and loadout return identical chrome.

---

## 8. As built

Landed 2026-09-19, stages A–D. **E (spectators) is not built**; the seam is.

### What it deleted

Four copies of `params[:match_id] == DevMatch::ID`, the `DevMatchScoped` concern — whose own
comment predicted this refactor — and the constants `DevMatch::OPERATION_ID` and
`DevMatch::TYPE`. That was the whole of gap 4 on the pre-mine list.

`Outfitting` and `Crewing` gained an `operation_id:` beside their `owner_id:`, which is the
argument they were always shaped for.

### Three things the sketch did not foresee

> **`kind`, not `type`.** `type` is Rails' single-table-inheritance column: a row reading
> `type: "steam_engine"` sends Active Record looking for a `SteamEngine` class and blows up on
> load. `kind` is the word `Unlock` and `Parts.register` already use.

> **A stale loadout could stop the match booting.** A stored row still named `:stock_blower`,
> which the driven-transport release had replaced — `Assembly` refused the build, correctly, and
> the dev match became unbootable with no way back but deleting the row by hand.
> `DevMatch.stored_parts` now drops part ids the catalogue no longer knows and logs loudly, so
> the slot falls back to its default. The sim stays strict; the delivery tier decides what to do
> about stale data.

> **A memo key that lied.** `panel` keyed on `[operation_id, loadout]` and then called `build`
> with no arguments, so asking for a different loadout got a fresh cache entry holding the
> *stored* machine's panel — a cache answering a question it was not asked. The loadout goes
> into the build now, and both halves are asserted: same loadout gives identical chrome, a
> different loadout gives different chrome.

### Measured

Two operations in one match, advanced in lockstep and driven independently:

```
operations: [:engine, :engine_b]
engine stoking=70.0  engine_b stoking=0.0  tick=3
reset keys: ["engine", "engine_b"]
```

`MatchRunner` publishes **two views per tick**, one per operation — which is what
`match_runner_spec`'s example was always called and could not check until now.

### The hatch

`REACTOR_OPERATOR_BYPASS=1`, and `config/initializers/operator_bypass.rb` **raises at boot** if
it is set anywhere but development or test. The console shows a `borrowed` badge when a machine
is being driven through it, and the bypass never writes `owner_id` — asserted, because that is
what makes turning it off a clean restoration.

> **`Rails.env.local?` needs `EnvironmentInquirer`.** Stubbing `Rails.env` with a plain
> `StringInquirer` answers `local?` through `method_missing` as *"is this string 'local'"* —
> false for development, so the spec refused a boot the real Rails allows. The initializer was
> right; the stub was not.
