# frozen_string_literal: true

# What a player owns, permanently.
#
# **A blueprint, not a part.** An unlock is the right to mint a *fresh* instance of something
# into any match; it is never consumed by using it, and nothing an instance accumulates comes
# back here. That is why this table has no condition column, no quantity, and no match id —
# see `docs/design_sketches/blueprints.md` §1 for the model, and §3 for what happens instead
# when a part is destroyed.
#
# **One table for all four kinds**, typed by `(kind, blueprint_id)`, rather than four tables
# that differ in nothing that matters. A new kind of unlockable is then a new value in a column
# instead of a migration, and the `created_at` an achievement system will eventually want to
# read comes along for free (`blueprints.md` §5, Option B).
class CreateUnlocks < ActiveRecord::Migration[8.1]
  def change
    create_table :unlocks do |t|
      # No `players` table yet — `DevPlayer::ID` is the only owner there is. A string rather
      # than a reference for exactly that reason, and because the eventual owner of a blueprint
      # may not be a player row anyway (a guild, a save slot).
      t.string :owner_id, null: false
      # :operation, :chassis, :part or :minion. `Blueprint::KINDS` is the list, and `Unlock`
      # validates against it — the database cannot, which is the one cost of this shape.
      t.string :kind, null: false
      # Meaningful only beside its kind. Chassis ids are scoped to their operation
      # (`steam_engine/high_pressure`) because a chassis has no standalone existence and two
      # machines could each call a frame `standard`; part ids are already globally unique,
      # because `Parts` is one flat registry that refuses a duplicate.
      t.string :blueprint_id, null: false

      t.timestamps
    end

    # Owning a thing twice is not a thing. Granting is idempotent by construction, which is
    # what lets a "grant everything" run repeatedly without a dedup pass.
    add_index :unlocks, %i[owner_id kind blueprint_id], unique: true
  end
end
