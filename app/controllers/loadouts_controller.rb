# frozen_string_literal: true

# The outfitting screen: which parts a machine is built from.
#
# `edit` renders it, `update` fits and rebuilds the engine. Everything either action needs is
# `Outfitting`'s work — see `app/CLAUDE.md`, "Controllers are routing, not logic".
class LoadoutsController < ApplicationController
  include LoadoutParams

  before_action :require_operator!

  def edit
    @outfitting = Outfitting.for(owner_id: current_player, operation_id: operation_id)
  end

  def update
    @outfitting = Outfitting.for(owner_id: current_player, operation_id: operation_id,
                                 parts: submitted_parts, chassis: submitted_chassis)

    return render :edit, status: :unprocessable_content unless @outfitting.ok?

    @outfitting.fit!
    redirect_to console_path(here), notice: "Fitted. The engine is being rebuilt — she will be cold."
  rescue Outfitting::NotDelivered
    redirect_to edit_loadout_path(here), alert: "Could not reach the engine room. Nothing was changed."
  end

  private

  def operation_id = current_operation.operation_id

  # Back to the machine this request was about, rather than to the one hardcoded machine.
  def here = { match_id: current_operation.match_id, operation_id: operation_id }
end
