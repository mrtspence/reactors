# frozen_string_literal: true

# The pre-match crew screen: who is in which job, and what they are carrying.
#
# Routing, not logic — `Crewing` does the work, exactly as `Outfitting` does for parts. The order
# in `update` is the same and matters for the same reason: **validate, store, reset.** A roster
# the screen refused must never reach the database, and one that never reached the database must
# never reach the runner.
class CrewsController < ApplicationController
  include CrewParams

  before_action :require_operator!

  def edit
    @crewing = Crewing.for(owner_id: current_player, operation_id: operation_id)
  end

  def update
    @crewing = Crewing.for(owner_id: current_player, operation_id: operation_id,
                           crew: submitted_crew)

    return render :edit, status: :unprocessable_content unless @crewing.ok?

    @crewing.fit!
    redirect_to console_path(here), notice: "Crew posted. The engine is being rebuilt — she will be cold."
  rescue Outfitting::NotDelivered
    redirect_to edit_crew_path(here), alert: "Could not reach the engine room. Nothing was changed."
  end

  private

  def operation_id = current_operation.operation_id

  def here = { match_id: current_operation.match_id, operation_id: operation_id }
end
