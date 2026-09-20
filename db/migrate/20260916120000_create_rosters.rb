# frozen_string_literal: true

# Who is crewing a machine, and what they are carrying.
#
# **`loadouts`' twin, deliberately.** A crew is a loadout by another name: both are a choice the
# player makes before the match that changes what gets built, both ride inside the reset command
# rather than being read from here during play, and both exist only so the screen has something
# to render and a cold runner has something to boot from.
#
# See docs/design_sketches/minions.md §8.
class CreateRosters < ActiveRecord::Migration[8.1]
  def change
    create_table :rosters do |t|
      t.string :match_id, null: false
      t.string :operation_id, null: false
      # `{ role_id => { minion:, training: [], tool:, gear:, utility: } }`. jsonb for the same
      # reason `loadouts.parts` is: the shape is the simulation's, it is written whole every
      # time, and a column per equipment slot would need a migration the moment a fourth exists.
      #
      # **A null value means deliberately empty and must survive as null**, not be re-defaulted
      # — the trap `Assembly#loadout` documents, applied to kit.
      t.jsonb :crew, null: false, default: {}

      t.timestamps
    end

    # One roster per operation per match, so `fit`-style upserts have something to conflict on.
    add_index :rosters, %i[match_id operation_id], unique: true
  end
end
