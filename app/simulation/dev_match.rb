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

  # Both processes MUST read the variant through here, never from ENV directly. It changes
  # which diagnostics exist (`condenser_vacuum` is atmospheric-only) and the pressure gauge's
  # full-scale reading, so a web process disagreeing with the runner would render a panel that
  # does not match the values arriving on it.
  def variant = ENV.fetch("REACTOR_VARIANT", "high_pressure").to_sym

  # TODO: expedient — 1.0 is the only setting whose skill gradient has actually been measured
  # (60/80/60 survives, 80/90/70 bursts the flywheel). Raising it makes a cold start bearable
  # for a first-time tester but shifts that gradient, so it is a dial for impatience during
  # development, not a supported difficulty setting.
  def time_scale = Float(ENV.fetch("REACTOR_TIME_SCALE", "1.0"))

  def build
    ReactorSim::Match.create(
      id: ID, seed: SEED, time_scale: time_scale,
      operations: [ { id: OPERATION_ID, type: :steam_engine, variant: variant } ]
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
  # Memoised because it is a per-process constant, and building an engine allocates ~17 nodes.
  #
  # TODO: this stops being sound the moment a match's configuration is chosen at creation
  # rather than read from the environment, because the two processes could then disagree. The
  # panel must come from the runner at that point — published to a compacted topic when the
  # match is created, or sent over the channel on subscribe.
  def panel = @panel ||= build.panel(operation_id: OPERATION_ID).freeze

  # The roster, for rendering names next to the levers. Configuration like the panel, and
  # rebuildable for exactly the same reason — a `Minion` is frozen config.
  #
  # Where each of them is STANDING is not configuration: `station` is state, it changes when a
  # player reassigns someone, and it arrives on the projection. Do not read it from here.
  def crew = @crew ||= build.operation(OPERATION_ID).minions.values.freeze
end
