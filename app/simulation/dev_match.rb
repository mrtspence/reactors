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

  # Fixed rather than random, so a restart reproduces the same machine — which is the whole
  # point of a deterministic simulation and makes "it did that again" a usable bug report.
  SEED = 20_260_828

  module_function

  # Both processes MUST read the chassis through here, never from ENV directly. It changes
  # which diagnostics exist (`condenser_vacuum` is atmospheric-only) and the pressure gauge's
  # full-scale reading, so a web process disagreeing with the runner would render a panel that
  # does not match the values arriving on it.
  #
  # `REACTOR_VARIANT` keeps its old spelling as the env var: the concept did not change when
  # the engine became assembled from parts, only what it is now one axis of. It is the fallback
  # now rather than the source — a stored loadout carries its own chassis, because a loadout
  # built against one frame means nothing on the other.
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

  # TODO: expedient — 1.0 is the only setting whose skill gradient has actually been measured
  # (60/80/60 survives, 80/90/70 bursts the flywheel). Raising it makes a cold start bearable
  # for a first-time tester but shifts that gradient, so it is a dial for impatience during
  # development, not a supported difficulty setting.
  def time_scale = Float(ENV.fetch("REACTOR_TIME_SCALE", "1.0"))

  # `chassis:` and `loadout:` are arguments rather than reads, because the runner is given them
  # by the reset command that rebuilds the match. Left unset they fall back to what is stored,
  # which is what a cold boot wants.
  def build(chassis: nil, loadout: nil)
    ReactorSim::Match.create(
      id: ID, seed: SEED, time_scale: time_scale,
      operations: [ { id: OPERATION_ID, type: :steam_engine,
                      chassis: chassis || self.chassis,
                      loadout: loadout || stored_parts } ]
    )
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
  # The web process has no Match — the runner owns it, in another process — so this rebuilds
  # one purely to ask it. That is sound for one specific reason: `Operation#panel` reads only
  # CONFIGURATION. It maps over frozen instrument and control-point objects and never touches
  # `@state`, so a match built from the same builder with the same options returns byte
  # identical chrome regardless of seed, tick, or anything that has happened in the match.
  # Operation configuration is code, not data (docs/guides/build-an-operation.md), and this is
  # the payoff.
  #
  # **Memoised per LOADOUT, not per process, and that is the whole of the old TODO here.** The
  # note used to say this would stop being sound the moment a match's configuration was chosen
  # at creation rather than read from the environment — which is now, because a player picks it
  # on the outfitting screen. It stays sound for the same reason it always did, with one word
  # changed: the panel is a pure function of the *loadout*, so as long as both processes read
  # the same stored loadout they cannot disagree about what the machine is.
  #
  # The remaining exposure is a race, not a design flaw: a player saves a loadout and the runner
  # has not reset yet, so the console renders the new panel over the old machine's values. It
  # closes itself within a tick or two because the reset is ordered on the same topic as the
  # commands. A proper implementation still has the panel come FROM the runner — published on a
  # compacted topic, or sent over the channel on subscribe — which is where this goes when
  # matches are created on demand.
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
