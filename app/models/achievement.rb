# frozen_string_literal: true

# Things a player has done, which some blueprints require before they can be unlocked.
#
# **The rules live here and the simulation knows nothing about them.** The engine reports
# *transitions in the machine* — `:fire_lit`, `:steam_raised`, `:blew_off`, `:part_failed` — and
# this composes them into meaning. A predicate in a node would make the sim learn what an
# achievement is, and every new one a simulation change needing both dev processes restarted.
#
# **A prerequisite lives on the blueprint**, so a blueprint carries everything needed to answer
# "may I have this yet?" in one place rather than in a rules engine nobody can read end to end.
#
# Three shapes, because most achievements should cost one line:
#
#   when_seen:   a point fact, complete the moment it arrives
#   when_meter:  a threshold on a cumulative quantity, folded from absolute meter readings
#   between:     an interval, with `disqualified_by` naming what spoils it
#
# Anything stranger takes a `predicate:` receiving the fold and the record — the seam this is
# meant to be extended through. See `docs/design_sketches/event_system.md` §2 and §10.
module Achievement
  Definition = Struct.new(:id, :label, :when_seen, :when_meter, :reaches, :scope,
                          :between, :lasting_ticks, :disqualified_by, :predicate,
                          keyword_init: true) do
    def point? = !when_seen.nil?
    def meter? = !when_meter.nil?
    def extent? = !between.nil?
  end

  DEFINITIONS = {}

  module_function

  def define(id, label:, **options)
    DEFINITIONS[id.to_sym] = Definition.new(id: id.to_sym, label: label, **options).freeze
  end

  # **Derived from the definitions, never written out beside them.** It was a hand-maintained
  # array, which is the shape `docs/CLAUDE.md` calls an inventory list — it drifts the moment
  # somebody adds a definition without looking, and it drifts silently, because the new
  # achievement is simply unreachable.
  def known = DEFINITIONS.keys

  def known?(id) = DEFINITIONS.key?(id.to_sym)

  def fetch(id) = DEFINITIONS.fetch(id.to_sym)

  def all = DEFINITIONS.values

  # Whether this owner has earned it.
  #
  # **This used to return `true` for everything**, with a TODO saying the day awarding existed
  # would be the day this method changed. It is that day. The stub was honest — nothing
  # observed a match closely enough to award anything, so gating on one would have locked every
  # blueprint naming a prerequisite, permanently and with no way to earn it.
  #
  # `owner_id` may still be nil (no auth yet, `DevPlayer::ID` is the only owner there is) and a
  # nil owner has earned nothing, which is the safe answer: an unattributable gate stays shut.
  def earned?(id, owner_id: nil)
    return false if owner_id.nil?

    Award.exists?(owner_id: owner_id.to_s, achievement_id: id.to_s)
  end

  # --- the catalogue -------------------------------------------------------
  #
  # In Ruby rather than YAML, on the same reasoning that settled parts authorship: these are
  # authored in-house, they are game design rather than configuration, and half of them will
  # eventually want a predicate. Blueprints are YAML because they are a flat catalogue of
  # numbers; achievements are rules.

  define :first_full_head_of_steam,
         label: "A Full Head of Steam",
         when_seen: { type: "steam_raised" }

  # **"Without the pilot at all" is not expressible**, because the igniter is what lights a cold
  # fire: `heater_engaged` always arrives before `fire_lit`, so a window opening at the lighting
  # can never contain it and the achievement would be awarded on every ordinary start.
  #
  # What the machine can express is the skill that matters — the igniter is a match, not a
  # furnace, and a player who leans on it is a player whose fire is dying. So the window runs
  # from the fire catching to working pressure, spoilt by the pilot coming back on or the fire
  # going out.
  define :raised_steam_from_cold_alone,
         label: "A Clean Cold Start",
         between: { opens: "fire_lit", closes: "steam_raised" },
         disqualified_by: [ { type: "heater_engaged" }, { type: "fire_out" } ]

  # An hour of simulated running at 4 Hz. `closes:` is the fire going out rather than the match
  # ending, deliberately — nothing here may wait on match lifecycle, which is not built.
  define :ran_an_hour_without_blowing_off,
         label: "An Hour of Quiet Steam",
         between: { opens: "steam_raised", closes: "fire_out" },
         lasting_ticks: 14_400,
         disqualified_by: [ { type: "blew_off", node: "relief" } ]

  define :burst_a_flywheel,
         label: "Centrifugal Education",
         when_seen: { type: "part_failed", node: "flywheel" }

  # The ledger's own line, read straight off a meter reading. No event counts this and none
  # should: it changes every tick, so it belongs to the accumulator that already tracks it and
  # is checked by the conservation specs.
  define :generated_a_gigajoule,
         label: "A Gigajoule of Honest Work",
         when_meter: "joules_to_work", reaches: 1.0e9, scope: :lifetime
end
