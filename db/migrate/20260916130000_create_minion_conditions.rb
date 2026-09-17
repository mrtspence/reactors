# frozen_string_literal: true

# The injury list. The one thing about a minion that outlives the match that hurt them.
#
# Minor and severe injuries are match state and die with the match — a scratch and a bad shift
# do not follow somebody into next week. Only `:mortal` writes here, and it takes them off the
# board for a match or three while they recuperate or are resurrected.
#
# **A countdown rather than a date**, and the reasoning is in `minions.md` §11: there is no
# per-owner match counter and nothing else needs one yet, so this decrements when a match starts.
# It is farmable by starting and abandoning matches; that costs a match each time and gains
# nothing today, and it should be revisited when a match is worth something.
class CreateMinionConditions < ActiveRecord::Migration[8.1]
  def change
    create_table :minion_conditions do |t|
      t.string :owner_id, null: false
      # The individual, not the archetype — `jim`, never `human`. Being on the injury list is
      # something that happens to a person.
      t.string :minion_id, null: false
      t.integer :matches_remaining, null: false, default: 0
      # Kept for the roster screen to explain itself with: "Jim — out for 2 more matches, blown
      # boiler". Without it the screen can say somebody is unavailable and not why.
      t.string :cause
      t.string :run_id

      t.timestamps
    end

    add_index :minion_conditions, %i[owner_id minion_id], unique: true
  end
end
