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
    @minions = DevMatch.crew(operation_id: operation.operation_id)
    @match_id = operation.match_id
    @operation_id = operation.operation_id
    # **The console says when the hatch is open.** A development affordance that looks identical
    # to the real thing is how somebody debugs the wrong rule for an afternoon.
    @borrowed = Operator.bypass? && !operation.owner_id.eql?(current_player)
    # Only the ones this player may look at, so the switcher never offers a 404.
    @siblings = Operation.in_match(operation.match_id)
                         .select { |op| op.viewable_by?(current_player) }
  end
end
