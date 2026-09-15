# frozen_string_literal: true

# Things a player has done, which some blueprints require before they can be unlocked.
#
# **A stub, and deliberately a shallow one.** Every achievement reports as earned, because
# nothing observes a match closely enough to award one yet: incidents exist only inside whatever
# projection is broadcast, `match.events` is not built, and a match does not end. Awarding is the
# whole feature and it is not this stage's.
#
# What stage 5c decides — and the only decision here worth making early — is **where a
# prerequisite lives: on the blueprint**. A blueprint then carries everything needed to answer
# "may I have this yet?" in one place, rather than that answer being assembled from a separate
# rules engine nobody can read end to end. See `docs/design_sketches/blueprints.md` §7.
#
# The ids below are named for things the simulation can already observe, so that when awarding
# arrives it has somewhere obvious to hook: the boiler reaching its relief pressure, an hour of
# running without the safety valve lifting, raising steam from cold without the igniter held in.
module Achievement
  # Checked against, for the same reason every other id in this system is: a blueprint naming an
  # achievement that does not exist would be a permanent lock nobody could explain, and a lookup
  # that silently misses is a feature silently switched off.
  KNOWN = %i[
    first_full_head_of_steam
    raised_steam_from_cold_alone
    ran_an_hour_without_blowing_off
    burst_a_flywheel
  ].freeze

  module_function

  def known?(id) = KNOWN.include?(id.to_sym)

  # TODO: expedient — always true. Nothing awards an achievement, so gating on one would lock
  # every blueprint that names a prerequisite, permanently and with no way to earn it. Returning
  # true keeps the call site live and honest: it is wired, it is specced against a stubbed
  # `false`, and the day awarding exists this is the only method that changes.
  #
  # **The signature is the useful part of the stub** — an achievement is earned by *somebody*,
  # so `owner_id:` is named here even though nothing reads it yet. Dropping it would mean
  # changing every call site later rather than one method body.
  def earned?(_id, owner_id: nil) # rubocop:disable Lint/UnusedMethodArgument
    true
  end
end
