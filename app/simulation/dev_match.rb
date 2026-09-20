# frozen_string_literal: true

# The one match this prototype runs, and the only thing the web tier and the runner both know
# about. It holds **several machines**, which is what the sim always supported and the delivery
# tier assumed away.
#
# TODO: expedient — there is exactly one hardcoded match, created at runner boot from a fixed
# seed. No lobby, and no `match.lifecycle`. A proper implementation creates matches on demand,
# gives each its own seed, and has the runner learn about them from the lifecycle topic rather
# than from a constant. **Its operations are rows now** (`Operation`), so who owns what is no
# longer part of this shortcut — only the match itself is.
module DevMatch
  ID = "dev"

  # **The machines this match runs, as a list rather than a constant.** `:engine` is what a
  # particular machine is *called* here; `:steam_engine` is what *kind* it is — a registered
  # `ReactorSim::Operations` key. The sim has always taken a list
  # (`Match.create(operations: [...])`, advanced in lockstep); only the delivery tier assumed
  # one, in four places.
  #
  # A second engine is deliberately the same kind as the first: two machines side by side, one
  # run against the other, is what testing a change actually looks like.
  OPERATIONS = { engine: :steam_engine, engine_b: :steam_engine }.freeze

  # Where `/` lands. The first machine, not the only one.
  PRIMARY = OPERATIONS.keys.first

  # Fixed rather than random, so a restart reproduces the same machine — which is the whole
  # point of a deterministic simulation and makes "it did that again" a usable bug report.
  SEED = 20_260_828

  module_function

  # **The rows that say who owns what.** Idempotent and safe to call at boot: `provision` never
  # touches an existing `owner_id`, so re-running it cannot transfer a machine.
  def provision!
    OPERATIONS.each do |operation_id, kind|
      Operation.provision(match_id: ID, operation_id: operation_id, kind: kind,
                          owner_id: DevPlayer::ID)
    end
  end

  def operation_ids = OPERATIONS.keys

  def kind_of(operation_id) = OPERATIONS.fetch(operation_id.to_sym)

  # Both processes MUST read the chassis through here, never from ENV directly. It changes which
  # diagnostics exist (`condenser_vacuum` is atmospheric-only) and the pressure gauge's
  # full-scale reading, so a web process disagreeing with the runner renders a panel that does
  # not match the values arriving on it.
  #
  # The env var is the fallback rather than the source: a stored loadout carries its own chassis,
  # because a loadout built against one frame means nothing on the other.
  def default_chassis = ENV.fetch("REACTOR_VARIANT", "high_pressure").to_sym

  def chassis(operation_id: PRIMARY)
    stored(operation_id: operation_id)&.chassis_sym || default_chassis
  end

  # The persisted loadout, or nil if nobody has been to the outfitting screen yet.
  #
  # **Not the authority during a match** — the runner is handed the loadout inside the reset
  # command that rebuilds it, so it never reads this at a moment when the web process might
  # have just written it. This is what a cold runner boots from and what the screen edits.
  def stored(operation_id: PRIMARY)
    Loadout.find_by(match_id: ID, operation_id: operation_id.to_s)
  end

  # **Parts the catalogue still knows, and nothing else.**
  #
  # A stored loadout naming a part that has since been renamed or removed makes `Assembly` refuse
  # the build — correctly, because a machine with a missing fitting is not a machine. But the
  # delivery tier inheriting that refusal means **the dev match cannot boot at all**, with no way
  # back except deleting the row by hand; it happened the day `:stock_blower` became
  # `:hand_bellows` and `:donkey_blower`.
  #
  # Dropped rather than nil'd, so the slot falls back to its default and the machine is the one a
  # player would get fresh. Logged loudly, because a silently forgotten choice is worse than a
  # noisy one — this is the loadout's equivalent of the stale `unlocks` rows
  # `rake blueprints:audit` exists to find.
  def stored_parts(operation_id: PRIMARY)
    parts = stored(operation_id: operation_id)&.to_sim || {}
    known, stale = parts.partition { |_, part| part.nil? || ReactorSim::Parts.key?(part) }
    if stale.any?
      Rails.logger.warn(
        "dev_match: #{operation_id} loadout names #{stale.map(&:last).join(', ')}, " \
        "which the catalogue no longer has — falling back to the slot default"
      )
    end

    known.to_h
  end

  # **A match beginning, which is the one thing that advances the recovery clock.**
  #
  # Not in `build`, which the web process also calls to rebuild a `Match` for the panel and the
  # roster — a decrement there would tick somebody's recovery down every time a page rendered,
  # so a player could heal their crew by refreshing.
  #
  # TODO: expedient — this belongs on `match.lifecycle` as the `started` record, and the clock
  # belongs to whatever consumes it. Called today from the two places a match actually starts: a
  # reset requested by the player, and posting a crew.
  def start!
    MinionCondition.advance!(DevPlayer::ID)
  rescue StandardError => e
    # A recovery clock that failed to tick must not stop a match from starting.
    Rails.logger.error("dev_match: could not advance recovery: #{e.class}: #{e.message}")
  end

  # **The loadout and crew ride INSIDE this command, not merely referenced by it.** The runner
  # has Rails booted and could read the tables, but the web process writes those rows and *then*
  # produces this, so a runner reading a table would read it at whatever moment the record
  # happened to arrive — a reset racing a save rebuilds the previous machine with no sign
  # anything went wrong. In the payload, the command says exactly which machine it means, and
  # stays ordered against the lever commands because it rides the same key on the same topic.
  #
  # The tables are still what a cold runner boots from; they are just not what a reset consults.
  # **Keyed by operation**, because a match holds several and a reset rebuilds all of them. One
  # flat `chassis`/`loadout`/`crew` was only ever right while there was one machine.
  def reset_command
    { "type" => "reset_match",
      "operations" => operation_ids.to_h { |id| [ id.to_s, reset_spec(id) ] } }
  end

  def reset_spec(operation_id)
    spec = {}
    # Availability is applied HERE as well as in `build`, because the runner rebuilds from this
    # payload rather than from the table — a raw roster would field somebody the screen has
    # just called unavailable.
    roster = stored_roster(operation_id: operation_id)
    spec["crew"] = Roster.stringify_crew(available(roster.to_sim)) if roster

    row = stored(operation_id: operation_id)
    return spec unless row

    spec.merge("chassis" => row.chassis, "loadout" => row.parts)
  end

  # TODO: expedient — 1.0 is the only setting whose skill gradient has actually been measured
  # (60/80/60 survives, 80/90/70 bursts the flywheel). Raising it makes a cold start bearable
  # for a first-time tester but shifts that gradient, so it is a dial for impatience during
  # development, not a supported difficulty setting.
  def time_scale = Float(ENV.fetch("REACTOR_TIME_SCALE", "1.0"))

  # `chassis:`, `loadout:` and `crew:` are arguments rather than reads, because the runner is
  # given them by the reset command. Left unset they fall back to what is stored, which is what a
  # cold boot wants.
  #
  # An unfilled role is not an empty one — `Crew::STANDIN` turns up — so an empty roster is a
  # legitimate machine crewed entirely by day-labourers, which is what a player gets before they
  # have hired anybody.
  # `specs:` is what a reset hands over, keyed by operation id; left unset, every machine falls
  # back to what is stored, which is what a cold boot wants.
  def build(specs: {})
    ReactorSim::Match.create(
      id: ID, seed: SEED, time_scale: time_scale,
      operations: operation_ids.map { |id| operation_spec(id, (specs || {})[id.to_s] || {}) }
    )
  end

  def operation_spec(operation_id, given)
    { id: operation_id, type: kind_of(operation_id),
      chassis: given["chassis"]&.to_sym || chassis(operation_id: operation_id),
      loadout: given["loadout"]&.to_h { |slot, part| [ slot.to_sym, part&.to_sym ] } ||
               stored_parts(operation_id: operation_id),
      # Handed over as it arrived. `Crew.normalise` symbolises at build, where every seat is
      # named and every empty slot made explicit — doing it here as well would be a second place
      # for the two to disagree about what an empty posting means.
      crew: given["crew"] || stored_crew(operation_id: operation_id) }
  end

  # The persisted roster, or nothing, in which case every seat falls to the standin.
  #
  # **Not the authority during a match**, exactly as `stored` is not: the runner is handed the
  # roster inside the reset command.
  def stored_roster(operation_id: PRIMARY)
    Roster.find_by(match_id: ID, operation_id: operation_id.to_s)
  end

  # **The roster is the player's INTENT; availability is applied when a machine is built.** A
  # player who posted Jim and then watched him carried out keeps Jim in the roster, and the
  # labour exchange fills the job meanwhile; when his recovery runs out he is simply back, with
  # no second decision to make. Rewriting the row would silently discard a choice the player
  # made and leave them to notice and redo it.
  #
  # The whole posting goes, not just the name: a day-labourer who has never met Jim is not
  # wearing Jim's oilskin.
  # **Seats the fitted quarters actually has, and nothing else.** `Crew.normalise` refuses an
  # unrecognised key outright, which is right for the library and wrong to inherit here: a stored
  # row written against a larger quarters — or against the job names seats replaced — would take
  # the dev match down at boot with no way back except deleting the row.
  def stored_crew(operation_id: PRIMARY)
    seats = ReactorSim::Crew.seats(outfitting(operation_id: operation_id).crew_capacity)
    posted = (stored_roster(operation_id: operation_id)&.to_sim || {})
             .slice(*seats, *seats.map(&:to_s))

    available(posted)
  end

  def available(crew)
    unavailable = MinionCondition.remaining_for(DevPlayer::ID)
    return crew if unavailable.empty?

    crew.to_h do |role_id, posting|
      minion = (posting || {})[:minion] || (posting || {})["minion"]
      [ role_id, unavailable.key?(minion.to_s) ? {} : posting ]
    end
  end

  # What the outfitting screen reads: the slots, what is fitted, the alternatives, and the
  # verdict — without building an operation, because most of what it renders is for builds
  # nobody has chosen.
  # **Asked of the registry by TYPE, never by naming a concrete operation module.** A second
  # machine is then a registration rather than a branch here and in every other screen — which is
  # the same reasoning `Operations.chassis_for` already exists for.
  def outfitting(operation_id: PRIMARY, chassis: nil, loadout: nil)
    ReactorSim::Operations.assembly_for(
      kind_of(operation_id),
      chassis: chassis || chassis(operation_id: operation_id),
      loadout: loadout || stored_parts(operation_id: operation_id)
    )
  end

  # Instrument and lever chrome for the console page.
  #
  # The web process has no `Match` — the runner owns it, in another process — so this rebuilds
  # one purely to ask it. Sound for one checkable reason: **`Operation#panel` reads only
  # configuration.** It maps over frozen instrument and control-point objects and never touches
  # `@state`, so the same builder with the same options returns byte-identical chrome regardless
  # of seed, tick or match history.
  #
  # **Memoised per LOADOUT, not per process**, because the panel is a pure function of the
  # loadout — so two processes reading the same stored loadout cannot disagree.
  #
  # The remaining exposure is a race, not a design flaw: save a loadout and the console renders
  # the new panel over the old machine for a tick or two until the reset lands. The real fix is
  # the panel coming FROM the runner, which is where this goes when matches are created on
  # demand.
  # **Memoised per (operation, loadout)**, one level down from where it was. The panel is a pure
  # function of the loadout, and two operations of the same kind and loadout return identical
  # chrome — which is what makes the key honest rather than merely convenient.
  # > **The key has to name what was actually built.** A first cut keyed on
  # > `[operation_id, loadout]` and then called `build` with no arguments, so asking for a
  # > different loadout got a fresh cache entry holding the *stored* machine's panel — a cache
  # > that answers the question it was not asked. The loadout goes into the build.
  def panel(operation_id: PRIMARY, loadout: nil)
    id = operation_id.to_sym
    parts = loadout || stored_parts(operation_id: id)

    (@panels ||= {})[[ id, parts ]] ||=
      build(specs: { id.to_s => { "loadout" => stringify_parts(parts) } })
        .panel(operation_id: id).freeze
  end

  def stringify_parts(parts) = parts.to_h { |slot, part| [ slot.to_s, part&.to_s ] }

  # The roster, for rendering names next to the levers. Configuration like the panel, and
  # rebuildable for exactly the same reason — a `Minion` is frozen config.
  #
  # Where each of them is STANDING is not configuration: `station` is state, it changes when a
  # player reassigns someone, and it arrives on the projection. Do not read it from here.
  def crew(operation_id: PRIMARY)
    (@crews ||= {})[operation_id.to_sym] ||=
      build.operation(operation_id.to_sym).minions.values.freeze
  end
end
