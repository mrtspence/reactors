# frozen_string_literal: true

# The operator's console.
#
# Renders chrome only — instrument faces, lever bounds, crew names. Not one simulation VALUE
# reaches this page from here: every gauge starts at "—" and fills in when the first projection
# arrives over the cable. That split is the point (docs/architecture.md §7), and it is what
# makes the page cheap to serve and impossible to serve stale.
class ConsolesController < ApplicationController
  def show
    return head :not_found unless params[:match_id] == DevMatch::ID
    return head :not_found unless params[:operation_id] == DevMatch::OPERATION_ID.to_s

    @panel = DevMatch.panel
    @minions = DevMatch.crew
    @match_id = DevMatch::ID
    @operation_id = DevMatch::OPERATION_ID
  end
end
