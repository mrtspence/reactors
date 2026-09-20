# frozen_string_literal: true

# **Who owns a machine.** One player per operation is the rule the whole identity model rests on,
# and until now nothing anywhere recorded it: every controller answered "may you touch this" by
# comparing a path segment against a constant, four times over.
#
# **Not a column on `loadouts`.** A loadout is what is *fitted*; an operation is the machine
# itself, and a player who has never opened the outfitting screen still owns their engine.
# Hanging ownership off a configuration row would make "does this exist" and "have you configured
# it" the same question, and they are not.
#
# `kind` is a registered `ReactorSim::Operations` key, and it is the column that retires
# `DevMatch::TYPE` — once the type comes from a row, both processes read it from one place, which
# is the lesson `chassis:` taught (see `app/CLAUDE.md`, the panel problem).
#
# > **`kind`, not `type`.** `type` is Rails' single-table-inheritance column: an `Operation` row
# > reading `type: "steam_engine"` would send Active Record looking for a `SteamEngine` class to
# > instantiate and blow up on load. `kind` is the word this codebase already uses for the same
# > idea on `Unlock` and `Parts.register`.
#
# See docs/design_sketches/operator_identity.md §2.
class CreateOperations < ActiveRecord::Migration[8.1]
  def change
    create_table :operations do |t|
      t.string :match_id, null: false
      t.string :operation_id, null: false
      t.string :kind, null: false
      # One owner, never a list. Spectating is a **different permission**, not more owners — see
      # `Operation#viewable_by?`. Not null: an operation nobody owns is one nobody can be refused
      # from, which is the gate failing open.
      t.string :owner_id, null: false

      t.timestamps
    end

    # The same key `loadouts` and `rosters` already carry, so the three agree on what addresses a
    # machine.
    add_index :operations, %i[match_id operation_id], unique: true
    # "What am I running?" is the query the lobby will ask.
    add_index :operations, :owner_id
  end
end
