# frozen_string_literal: true

# A loadout a player is *considering*, evaluated but not stored.
#
# **A draft is a resource, and that is why this exists rather than a `preview` action on
# `LoadoutsController`.** Changing a dropdown asks the server what this build would be — the
# stats, and more importantly the verdict — and the answer is a rendering, not a saved record.
# `create` is the honest verb: it makes a draft and hands it back.
#
# The verdict is the reason this is a round trip at all rather than a few lines of JavaScript:
# only the simulation can say whether a build assembles, and a screen showing live stats beside
# stale warnings would be worse than one showing neither.
#
# POST rather than GET so a twenty-slot loadout rides in the body instead of going into the query
# string — and from there into history and logs — on every dropdown change.
class LoadoutDraftsController < ApplicationController
  include LoadoutParams

  before_action :require_operator!

  def create
    @outfitting = Outfitting.for(owner_id: current_player,
                                 operation_id: current_operation.operation_id,
                                 parts: submitted_parts, chassis: submitted_chassis)
    render "loadouts/edit"
  end
end
