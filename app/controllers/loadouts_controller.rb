# frozen_string_literal: true

# The outfitting screen: which parts a machine is built from.
#
# `edit` renders it, `update` fits and rebuilds the engine. Everything either action needs is
# `Outfitting`'s work — see `app/CLAUDE.md`, "Controllers are routing, not logic".
class LoadoutsController < ApplicationController
  include DevMatchScoped
  include LoadoutParams

  before_action :require_dev_operation

  def edit
    @outfitting = Outfitting.for(owner_id: DevPlayer::ID)
  end

  def update
    @outfitting = Outfitting.for(owner_id: DevPlayer::ID, parts: submitted_parts,
                                 chassis: submitted_chassis)

    return render :edit, status: :unprocessable_content unless @outfitting.ok?

    @outfitting.fit!
    redirect_to console_path(match_id: DevMatch::ID, operation_id: DevMatch::OPERATION_ID),
                notice: "Fitted. The engine is being rebuilt — she will be cold."
  rescue Outfitting::NotDelivered
    redirect_to edit_loadout_path(match_id: DevMatch::ID, operation_id: DevMatch::OPERATION_ID),
                alert: "Could not reach the engine room. Nothing was changed."
  end
end
