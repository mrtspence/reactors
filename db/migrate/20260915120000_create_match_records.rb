# frozen_string_literal: true

# Where the durable record lands, after `match.events` has carried it out of the runner.
#
# **This is not match state.** `docs/architecture.md` §8 says match state never reaches Postgres
# during play, and that rule stands: a match's physics lives in the runner's memory and in Kafka,
# and none of it is here. What is here belongs to a *player* — it is small, rare, and outlives
# every match that produced it, which is a different object with a different lifetime.
#
# See docs/design_sketches/event_system.md §9.
class CreateMatchRecords < ActiveRecord::Migration[8.1]
  def change
    # One row per BUILD of a match, which is not the same as one per match. `MatchRunner#reset`
    # rebuilds in place under the same `match_id` and the tick count restarts at zero, so
    # without this identity two different runs both claim tick 412 and any fold over the stream
    # corrupts itself. It is also what `match.lifecycle` will key on when matches are created
    # on demand rather than at runner boot.
    create_table :match_runs do |t|
      t.string :run_id, null: false
      t.string :match_id, null: false
      t.bigint :seed
      t.string :chassis
      t.jsonb :loadout, null: false, default: {}
      t.datetime :started_at
      # Null while the match is live. Nothing sets it yet — match lifecycle is not built — and
      # the design deliberately does not wait for it: every fold here completes on a transition
      # the engine emits, so a match that never ends still banks what it earned.
      t.datetime :ended_at

      t.timestamps
    end
    add_index :match_runs, :run_id, unique: true
    add_index :match_runs, %i[match_id created_at]

    # The feed a player reads, and the reason a spectator joining one tick late can still learn
    # the flywheel burst. Before this, an incident existed only inside whatever projection
    # happened to be broadcast.
    create_table :incidents do |t|
      t.string :run_id, null: false
      t.string :operation_id, null: false
      t.bigint :tick, null: false
      # Index within the tick. Deterministic, because the simulation is: `Tick` walks its nodes
      # in build order, so a replayed tick emits the same events in the same order.
      t.integer :seq, null: false
      t.string :type, null: false
      t.string :node
      t.string :mode
      t.string :severity, null: false
      t.jsonb :detail, null: false, default: {}

      t.timestamps
    end
    # **The dedupe key IS the constraint.** Kafka is at-least-once and a crash between producing
    # a tick's events and snapshotting past them replays that tick, re-emitting every one. With
    # this index the redelivery is an upsert no-op instead of a duplicate line in the feed, and
    # no consumer needs a dedup table.
    add_index :incidents, %i[run_id operation_id tick seq], unique: true
    add_index :incidents, %i[run_id id]

    # Cumulative quantities, folded from absolute meter readings. A row with a null `run_id` is
    # the lifetime total for that owner; a row with one is that run's contribution.
    create_table :progresses do |t|
      t.string :owner_id, null: false
      t.string :run_id
      t.string :metric, null: false
      t.float :value, null: false, default: 0.0

      t.timestamps
    end
    add_index :progresses, %i[owner_id run_id metric], unique: true

    # An interval an extent achievement is waiting to close — "an hour without blowing off"
    # needs to know when the hour started and whether anything disqualified it since.
    #
    # **In Postgres rather than in consumer memory, deliberately.** It is the one real cost of
    # folding live rather than digesting at end of match, and this pays it: a consumer restart
    # resumes the interval instead of silently dropping it, and the row is the artifact somebody
    # reads when an achievement did not fire and nobody can say why.
    create_table :achievement_attempts do |t|
      t.string :owner_id, null: false
      t.string :run_id, null: false
      t.string :achievement_id, null: false
      t.bigint :opened_at_tick, null: false
      t.boolean :disqualified, null: false, default: false

      t.timestamps
    end
    add_index :achievement_attempts, %i[owner_id run_id achievement_id], unique: true

    # The permanent record, and the only thing here that is never swept. This is what
    # `Achievement.earned?` finally reads instead of returning true for everything.
    create_table :awards do |t|
      t.string :owner_id, null: false
      t.string :achievement_id, null: false
      t.string :run_id
      t.bigint :tick

      t.timestamps
    end
    # Earning a thing twice is not a thing, exactly as with `unlocks`. The index is what makes
    # awarding idempotent under redelivery with no check-then-write race.
    add_index :awards, %i[owner_id achievement_id], unique: true
  end
end
