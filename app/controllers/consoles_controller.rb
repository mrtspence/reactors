# frozen_string_literal: true

# The operator's console.
#
# Renders chrome only — instrument faces, lever bounds, crew names. Not one simulation VALUE
# reaches this page from here: every gauge starts at "—" and fills in when the first projection
# arrives over the cable. That split is the point (docs/architecture.md §7), and it is what
# makes the page cheap to serve and impossible to serve stale.
class ConsolesController < ApplicationController
  before_action :require_viewer!

  def show
    operation = current_operation

    @panel = DevMatch.panel(operation_id: operation.operation_id)
    @places = ConsolePlaces.new(@panel)
    @minions = DevMatch.crew(operation_id: operation.operation_id)
    @operation_id = operation.operation_id
    @kind = operation.kind
  end
end
