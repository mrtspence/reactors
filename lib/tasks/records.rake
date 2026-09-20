# frozen_string_literal: true

# Housekeeping for the durable record.
#
# Retention is one week on every feed, matching `match.commands` — which is what bounds replay
# anyway, so there is one number to change rather than two that can silently disagree. See
# `docs/design_sketches/event_system.md` §9.
namespace :records do
  desc "Delete runs, incidents and open attempts older than MatchRun::RETENTION"
  task sweep: :environment do
    before = MatchRun::RETENTION.ago
    stale = MatchRun.stale(before).count

    MatchRun.sweep!(before)

    puts "swept #{stale} run(s) older than #{before.to_fs(:db)}"
    # Stated rather than assumed, because the distinction is the whole point of the policy:
    # what is swept is working material about matches nobody will revisit, and what survives is
    # the player's permanent record.
    puts "kept #{Award.count} award(s) and #{Progress.lifetime.count} lifetime total(s)"
  end

  desc "What the durable record currently holds"
  task summary: :environment do
    puts "runs:      #{MatchRun.count}"
    puts "incidents: #{Incident.count}"
    puts "awards:    #{Award.count}"
    puts "open attempts: #{AchievementAttempt.open.count}"
    Progress.lifetime.order(:metric).each { |row| puts "  #{row.metric}: #{row.value}" }
  end
end
