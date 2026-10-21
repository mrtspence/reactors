# frozen_string_literal: true

# **What the match is played under**: the season, chosen before it starts so the crew and the
# rig can be outfitted for it. Saving it rebuilds the match, as fitting a loadout does.
class MatchSetupsController < ApplicationController
  before_action :require_match_operator!

  def edit
    @setup = MatchSetup.for(params[:match_id])
  end

  def update
    @setup = MatchSetup.for(params[:match_id])
    return render :edit, status: :unprocessable_content unless @setup.update(season: params.dig(:match_setup, :season).to_s)

    DevMatch.request_reset!
    redirect_to console_path(match_id: @setup.match_id, operation_id: DevMatch::PRIMARY),
                notice: "Set for #{@setup.season}. The match is being rebuilt."
  rescue StandardError => e
    Rails.logger.error("match_setups: reset failed: #{e.class}: #{e.message}")
    redirect_to edit_match_setup_path(match_id: params[:match_id]),
                alert: "Saved, but could not reach the runner. Reset the match to play it."
  end
end
