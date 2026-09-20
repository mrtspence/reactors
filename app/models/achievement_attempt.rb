# frozen_string_literal: true

# An interval an extent achievement is waiting to close.
#
# "An hour without blowing off" cannot be decided from a single record: it needs to know when
# the hour started and whether anything spoiled it since. This is that state, and it lives in
# Postgres rather than in the consumer's memory on purpose — it is the one real cost of folding
# live rather than digesting at end of match, and holding it here pays it. A consumer restart
# resumes the interval instead of silently dropping it, and the row is the artifact somebody
# reads when an achievement did not fire and nobody can say why.
#
# Scoped to `run_id`, so a reset abandons whatever was open rather than letting it close
# against a transition from a machine that is not the same machine.
class AchievementAttempt < ApplicationRecord
  validates :owner_id, :run_id, :achievement_id, presence: true
  validates :achievement_id, uniqueness: { scope: %i[owner_id run_id] }

  scope :open, -> { where(disqualified: false) }

  def ticks_elapsed(now) = now.to_i - opened_at_tick
end
