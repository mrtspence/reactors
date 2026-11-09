# frozen_string_literal: true

# **An achievement is earned on one machine.** A window opens and closes on one operation's own
# transitions, and a meter folds one operation's ledger: a kiln catching in the pit must not open
# a window the stationary engine's drum closes, and two machines' ledgers must not race into one
# row by `GREATEST`.
#
# Rows already here were written before machines were told apart, and every meter achievement
# so far is the steam engine's, so they are taken as its. Their `operation_id` stays null: a run
# that wrote one is never read again once the runner has restarted.
class ScopeProgressionByMachine < ActiveRecord::Migration[8.0]
  def up
    add_column :progresses, :operation_type, :string, null: false, default: "steam_engine"
    change_column_default :progresses, :operation_type, from: "steam_engine", to: nil
    add_column :progresses, :operation_id, :string
    remove_index :progresses, %i[owner_id run_id metric]
    add_index :progresses, %i[owner_id run_id operation_id operation_type metric], unique: true,
                                                                                   nulls_not_distinct: true,
                                                                                   name: "index_progresses_on_owner_run_machine_metric"

    add_column :achievement_attempts, :operation_id, :string, null: false, default: ""
    change_column_default :achievement_attempts, :operation_id, from: "", to: nil
    remove_index :achievement_attempts, %i[owner_id run_id achievement_id]
    add_index :achievement_attempts, %i[owner_id run_id operation_id achievement_id], unique: true,
                                                                                      name: "index_attempts_on_owner_run_machine"
  end

  def down
    remove_index :achievement_attempts, name: "index_attempts_on_owner_run_machine"
    add_index :achievement_attempts, %i[owner_id run_id achievement_id], unique: true
    remove_column :achievement_attempts, :operation_id

    remove_index :progresses, name: "index_progresses_on_owner_run_machine_metric"
    add_index :progresses, %i[owner_id run_id metric], unique: true, nulls_not_distinct: true
    remove_column :progresses, :operation_id
    remove_column :progresses, :operation_type
  end
end
