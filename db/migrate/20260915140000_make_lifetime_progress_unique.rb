# frozen_string_literal: true

# **Postgres unique indexes treat NULLs as distinct, so the lifetime rows were never unique.**
#
# `progresses` carries two kinds of row: one per run, and one with a null `run_id` holding the
# owner's lifetime total. The index on `(owner_id, run_id, metric)` enforced the first and
# silently did nothing for the second — `NULL = NULL` is unknown, not true, so `ON CONFLICT`
# never matched and every single meter reading INSERTED A NEW lifetime row rather than raising
# the existing one.
#
# Found by running the consumers against a live broker for forty seconds: **40 lifetime rows
# for 10 metrics.** No spec caught it, and the one that should have came closest and still
# passed — `Progress.lifetime_totals` does `pluck(:metric, :value).to_h`, and `to_h` keeps the
# last value for a repeated key, which happened to be the right number sitting on top of three
# wrong rows.
#
# `NULLS NOT DISTINCT` (Postgres 15+) says what was meant all along: there is one lifetime row
# per owner and metric. The alternative was a sentinel string instead of NULL, which works
# everywhere but puts a magic value in a column and makes every query read worse.
class MakeLifetimeProgressUnique < ActiveRecord::Migration[8.1]
  def up
    # Collapse what the old index allowed through, keeping the highest value — which is the
    # correct total, since readings are absolute and the fold is a max.
    execute(<<~SQL.squish)
      DELETE FROM progresses a USING progresses b
      WHERE a.owner_id = b.owner_id
        AND a.metric = b.metric
        AND a.run_id IS NULL
        AND b.run_id IS NULL
        AND (a.value < b.value OR (a.value = b.value AND a.id < b.id))
    SQL

    remove_index :progresses, %i[owner_id run_id metric]
    add_index :progresses, %i[owner_id run_id metric], unique: true, nulls_not_distinct: true
  end

  def down
    remove_index :progresses, %i[owner_id run_id metric]
    add_index :progresses, %i[owner_id run_id metric], unique: true
  end
end
