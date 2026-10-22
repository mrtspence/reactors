# frozen_string_literal: true

# Who holds what against whom, carried from one match to the next.
class CreateGrudges < ActiveRecord::Migration[8.0]
  def change
    create_table :grudges do |t|
      t.string :owner_id, null: false
      t.string :holder_id, null: false
      t.string :target_id, null: false
      t.float :amount, null: false, default: 0.0
      # The run whose events are being folded in, and the ticks of those already folded, so a
      # replayed event cannot deepen a grudge twice.
      t.string :run_id
      t.jsonb :applied_ticks, null: false, default: []
      t.timestamps
    end
    add_index :grudges, %i[owner_id holder_id target_id], unique: true
  end
end
