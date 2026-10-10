# frozen_string_literal: true

# The gear the pit issues to whoever the labour exchange sends.
#
# Beside `crew` rather than inside it, because it is one decision for the whole roster: raising
# the standard has to re-equip every unfilled seat at once, which baking it into each seat at
# save time could not do.
class AddStandinKitToRosters < ActiveRecord::Migration[8.0]
  def change
    add_column :rosters, :standin, :jsonb, default: {}, null: false
  end
end
