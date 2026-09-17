# frozen_string_literal: true

# Turns the durable log into a player's permanent record.
#
# **A live streaming fold, not a post-game digest**, and the reason is situational as much as
# architectural: a post-game handler needs a match to *end*, match lifecycle is not built, and
# the dev match never ends — it gets reset. A digest that only runs at the end would award
# nothing in the one environment where this is exercised, and would rot exactly as
# `Achievement.earned?` did. See `docs/design_sketches/event_system.md` §8.
#
# Routed by the shape of the fact, which is what makes the usual objections to folding live go
# away:
#
# - **Point facts** are complete on arrival. Award immediately.
# - **Cumulative facts** arrive as ABSOLUTE meter readings, so the write is `greatest(total,
#   reading)` — idempotent under redelivery, insensitive to order, and a crash costs at most one
#   sampling interval rather than corrupting a total.
# - **Extent facts** hold their open interval in Postgres rather than in memory, so a consumer
#   restart resumes it instead of losing it.
#
# Every write here must be idempotent: `match.events` is at-least-once and a replayed tick
# re-emits its events verbatim.
class ProgressionDigest
  def initialize(owner_id: DevPlayer::ID, logger: Rails.logger)
    @owner_id = owner_id.to_s
    @logger = logger
  end

  # One record off the topic. Returns the achievement ids awarded by it, which is what a caller
  # would broadcast as an "unlocked" moment.
  def call(record)
    case record["kind"]
    when "event" then absorb_event(record)
    when "meter" then absorb_meter(record)
    else []
    end
  rescue StandardError => e
    # A poisoned record must not stop the consumer: the log is at-least-once and ordered, and a
    # crash loop on one bad payload would block every fact behind it forever.
    @logger.error("digest: skipped #{record['kind']} at tick #{record['tick']}: " \
                  "#{e.class}: #{e.message}")
    []
  end

  private

  # **Everything compared as Strings, on purpose.** A record has crossed JSON into Kafka and
  # may cross `jsonb` on the way back, so `type`, `node`, `mode` and `severity` are all symbols
  # that arrive as strings — the sixth instance of that trap in this codebase and the worst
  # placed, because a mismatch here is not an error. It is an achievement that silently never
  # fires, which looks exactly like one nobody has earned. `Achievement`'s definitions are
  # written with String values for the same reason.
  def absorb_event(record)
    Achievement.all.flat_map do |definition|
      if definition.point?
        matches?(definition.when_seen, record) ? award(definition, record) : []
      elsif definition.extent?
        advance_interval(definition, record)
      else
        []
      end
    end
  end

  def matches?(spec, record)
    spec.all? { |key, value| record[key.to_s].to_s == value.to_s }
  end

  # An interval opens, is spoiled, or closes. Order within a tick is the engine's, and it is
  # deterministic, so two consumers folding the same stream reach the same answer.
  # An interval opens, is spoiled, or closes. `disqualified_by` is a LIST, because more than one
  # thing usually spoils a run — a clean cold start is ruined by the pilot coming back on and,
  # separately, by the fire going out.
  #
  # **Spoiling is checked before closing, and a spoiler arriving with no interval open is
  # ignored rather than remembered.** That second rule is not obviously right and it is worth
  # being explicit about: you cannot ruin something that has not started. It is also what made
  # "cold start without the pilot" award on every ordinary run, because the igniter fires before
  # the fire catches — the fix was to the definition, not to this.
  def advance_interval(definition, record)
    attempt = attempt_for(definition, record)

    if Array(definition.disqualified_by).any? { |spec| matches?(spec, record) }
      attempt&.update!(disqualified: true)
      return []
    end

    return open_interval(definition, record) if record["type"] == definition.between[:opens].to_s
    return [] unless record["type"] == definition.between[:closes].to_s

    close_interval(definition, record, attempt)
  end

  def attempt_for(definition, record)
    AchievementAttempt.find_by(owner_id: @owner_id, run_id: record["run_id"],
                               achievement_id: definition.id.to_s)
  end

  # **Re-opening is not the same as restarting.** A second `steam_raised` after a bad spell
  # must not wipe an interval that is still running cleanly, or an hour of quiet steam could
  # never be accumulated by a driver who is doing well. Only a disqualified or absent attempt
  # is replaced.
  def open_interval(definition, record)
    attempt = attempt_for(definition, record)
    return [] if attempt && !attempt.disqualified

    AchievementAttempt.upsert(
      { owner_id: @owner_id, run_id: record["run_id"], achievement_id: definition.id.to_s,
        opened_at_tick: record["tick"], disqualified: false,
        created_at: Time.current, updated_at: Time.current },
      unique_by: %i[owner_id run_id achievement_id]
    )
    []
  end

  def close_interval(definition, record, attempt)
    return [] if attempt.nil? || attempt.disqualified

    lasted = record["tick"].to_i - attempt.opened_at_tick
    attempt.destroy!
    return [] if definition.lasting_ticks && lasted < definition.lasting_ticks

    award(definition, record)
  end

  # Meter readings are absolute, so the fold is a max rather than a sum. Two rows per metric:
  # this run's contribution, and the owner's lifetime total.
  def absorb_meter(record)
    ledger = record["ledger"] || {}
    awarded = []

    ledger.each do |metric, value|
      next unless value.is_a?(Numeric)

      raise_to(metric, value, run_id: record["run_id"])
      raise_to(metric, lifetime_total(metric), run_id: nil)
    end

    Achievement.all.each do |definition|
      next unless definition.meter?

      awarded.concat(check_meter(definition, record))
    end
    awarded
  end

  # `greatest`, in one statement, so two consumers racing the same reading cannot interleave a
  # read and a write and lose the higher one.
  def raise_to(metric, value, run_id:)
    Progress.upsert(
      { owner_id: @owner_id, run_id: run_id, metric: metric.to_s, value: value.to_f,
        created_at: Time.current, updated_at: Time.current },
      unique_by: %i[owner_id run_id metric],
      on_duplicate: Arel.sql("value = GREATEST(progresses.value, EXCLUDED.value)")
    )
  end

  # A lifetime figure is the sum of every run's own total, not the running total of whatever
  # arrived last: runs overlap in principle and a max across them would report only the best.
  #
  # **Written back through `GREATEST`, so a sweep cannot claw a lifetime total back.** Runs are
  # pruned after a week and their per-run rows go with them, which makes this sum drop; the max
  # on the way in is what stops the owner's permanent figure dropping with it. A player does not
  # un-generate a gigajoule because the evidence was tidied away.
  def lifetime_total(metric)
    Progress.where(owner_id: @owner_id, metric: metric.to_s).where.not(run_id: nil).sum(:value)
  end

  def check_meter(definition, record)
    scope = definition.scope == :lifetime ? nil : record["run_id"]
    row = Progress.find_by(owner_id: @owner_id, run_id: scope, metric: definition.when_meter)
    return [] if row.nil? || row.value < definition.reaches

    award(definition, record)
  end

  def award(definition, record)
    return [] if Award.exists?(owner_id: @owner_id, achievement_id: definition.id.to_s)

    Award.grant(owner_id: @owner_id, achievement_id: definition.id,
                run_id: record["run_id"], tick: record["tick"])
    [ definition.id ]
  end
end
