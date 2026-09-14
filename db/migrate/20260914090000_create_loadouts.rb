# frozen_string_literal: true

# The first table in this application, and it is worth saying what it is for.
#
# Match runtime state never touches Postgres — during play it lives in the runner's memory and
# is snapshotted to Kafka (`config/database.yml` says so at the top). What goes here is the
# durable, low-volume stuff, and a loadout is the first of it: **which parts a player chose to
# build their machine out of**, which has to survive a runner restart and has to be readable by
# both processes.
#
# It is deliberately not the *authority* during a match. The runner is handed the loadout inside
# the reset command that rebuilds the match, so it never has to read this table at a moment when
# the web process might have just written it. This row is what a fresh runner boots from and what
# the outfitting screen edits — see `DevMatch` and `docs/design_sketches/modular_components.md` §8.
class CreateLoadouts < ActiveRecord::Migration[8.1]
  def change
    create_table :loadouts do |t|
      t.string :match_id, null: false
      t.string :operation_id, null: false
      t.string :chassis, null: false
      # Slot id => part id, with an explicit null for a slot left deliberately empty. It is the
      # resolved loadout `Assembly` hands back, not the partial one a form submitted: a partial
      # one re-defaults on load and would quietly grow missing parts back.
      t.jsonb :parts, null: false, default: {}

      t.timestamps
    end

    # One machine, one loadout. Upserting on this pair is what keeps the outfitting screen
    # idempotent under a double submit.
    add_index :loadouts, %i[match_id operation_id], unique: true
  end
end
