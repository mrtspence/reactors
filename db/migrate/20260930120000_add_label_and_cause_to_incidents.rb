# frozen_string_literal: true

# What an incident was *called* and what *did* it, neither of which the row held.
#
# The feed renders `label` and falls back to `node`, so a backfilled line read `crew_8` where a
# live one read the person's name; and with no `cause` every backfilled line ended in "unknown".
# A history that reads differently from the live feed is worse than no history.
class AddLabelAndCauseToIncidents < ActiveRecord::Migration[8.0]
  def change
    add_column :incidents, :label, :string
    add_column :incidents, :cause, :string
  end
end
