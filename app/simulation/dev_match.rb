# frozen_string_literal: true

# The one match this prototype runs, and the only thing the web tier and the runner both know
# about.
#
# TODO: expedient — there is exactly one hardcoded match, created at runner boot from a fixed
# seed. No models, no migrations, no lobby, and no `match.lifecycle`. A proper implementation
# creates matches on demand, gives each its own seed, and has the runner learn about them from
# the lifecycle topic rather than from a constant.
module DevMatch
  ID = "dev"
  OPERATION_ID = :engine

  # The registered operation TYPE, which is not the operation's id: `:engine` is what this
  # particular machine is called in this match, `:steam_engine` is what kind of machine it is.
  # The delivery tier needs the type to ask the registry what frames it offers.
  TYPE = :steam_engine

  # Fixed rather than random, so a restart reproduces the same machine — which is the whole
  # point of a deterministic simulation and makes "it did that again" a usable bug report.
  SEED = 20_260_828

  module_function

  # Both processes MUST read the chassis through here, never from ENV directly. It changes which
  # diagnostics exist (`condenser_vacuum` is atmospheric-only) and the pressure gauge's
  # full-scale reading, so a web process disagreeing with the runner renders a panel that does
  # not match the values arriving on it.
  #
  # The env var is the fallback rather than the source: a stored loadout carries its own chassis,
  # because a loadout built against one frame means nothing on the other.
  def default_chassis = ENV.fetch("REACTOR_VARIANT", "high_pressure").to_sym

  def chassis = stored&.chassis_sym || default_chassis

  # The persisted loadout, or nil if nobody has been to the outfitting screen yet.
  #
  # **Not the authority during a match** — the runner is handed the loadout inside the reset
  # command that rebuilds it, so it never reads this at a moment when the web process might
  # have just written it. This is what a cold runner boots from and what the screen edits.
  def stored
    Loadout.find_by(match_id: ID, operation_id: OPERATION_ID.to_s)
  end

  def stored_parts = stored&.to_sim || {}

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
  def reset_command
    { "type" => "reset_match" }.tap do |command|
      # Availability is applied HERE as well as in `build`, because the runner rebuilds from this
      # payload rather than from the table — a raw roster would field somebody the screen has
      # just called unavailable.
      roster = stored_roster
      command["crew"] = Roster.stringify_crew(available(roster.to_sim)) if roster

      row = stored
      next unless row

      command["chassis"] = row.chassis
      command["loadout"] = row.parts
    end
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
  def build(chassis: nil, loadout: nil, crew: nil)
    ReactorSim::Match.create(
      id: ID, seed: SEED, time_scale: time_scale,
      operations: [ { id: OPERATION_ID, type: TYPE,
                      chassis: chassis || self.chassis,
                      loadout: loadout || stored_parts,
                      crew: crew || stored_crew } ]
    )
  end

  # The persisted roster, or nothing, in which case every role falls to the standin.
  #
  # **Not the authority during a match**, exactly as `stored` is not: the runner is handed the
  # roster inside the reset command.
  def stored_roster
    Roster.find_by(match_id: ID, operation_id: OPERATION_ID.to_s)
  end

  # **The roster is the player's INTENT; availability is applied when a machine is built.** A
  # player who posted Jim and then watched him carried out keeps Jim in the roster, and the
  # labour exchange fills the job meanwhile; when his recovery runs out he is simply back, with
  # no second decision to make. Rewriting the row would silently discard a choice the player
  # made and leave them to notice and redo it.
  #
  # The whole posting goes, not just the name: a day-labourer who has never met Jim is not
  # wearing Jim's oilskin.
  def stored_crew = available(stored_roster&.to_sim || {})

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
  def outfitting(chassis: nil, loadout: nil)
    ReactorSim::Operations::SteamEngine.assembly_for(
      chassis || self.chassis, loadout || stored_parts
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
  def panel(loadout: nil)
    key = loadout || stored_parts
    (@panels ||= {})[key] ||= build(loadout: key).panel(operation_id: OPERATION_ID).freeze
  end

  # The roster, for rendering names next to the levers. Configuration like the panel, and
  # rebuildable for exactly the same reason — a `Minion` is frozen config.
  #
  # Where each of them is STANDING is not configuration: `station` is state, it changes when a
  # player reassigns someone, and it arrives on the projection. Do not read it from here.
  def crew = @crew ||= build.operation(OPERATION_ID).minions.values.freeze
end
