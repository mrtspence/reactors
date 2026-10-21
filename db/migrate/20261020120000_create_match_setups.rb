# frozen_string_literal: true

# What a match is played under, chosen before it starts: the season, so far.
class CreateMatchSetups < ActiveRecord::Migration[8.0]
  def change
    create_table :match_setups do |t|
      t.string :match_id, null: false
      t.string :season, null: false
      t.timestamps
    end
    add_index :match_setups, :match_id, unique: true
  end
end
