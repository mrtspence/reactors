# frozen_string_literal: true

# What each of a player's people is still carrying from earlier matches, healing a little each
# match. Replaces the injury list, whose dice gave a mortal injury one to three matches out: how
# long somebody is out is now how long their wounds take to heal.
class CreateWounds < ActiveRecord::Migration[8.0]
  def change
    create_table :wounds do |t|
      t.string :owner_id, null: false
      t.string :minion_id, null: false
      t.string :kind, null: false
      t.float :depth, null: false
      t.integer :variant, null: false
      t.string :cause
      # The run the wound was taken in and its place among the person's wounds that run, so a
      # replayed event, or a wound deepening, is the same row.
      t.string :run_id, null: false
      t.integer :slot, null: false
      t.timestamps
    end
    add_index :wounds, %i[owner_id minion_id run_id slot], unique: true

    drop_table :minion_conditions do |t|
      t.string :owner_id, null: false
      t.string :minion_id, null: false
      t.integer :matches_remaining, null: false, default: 0
      t.string :run_id
      t.string :cause
      t.timestamps
      t.index %i[owner_id minion_id], unique: true
    end
  end
end
