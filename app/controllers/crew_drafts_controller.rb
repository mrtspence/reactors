# frozen_string_literal: true

# What a crew *would be*, without posting it.
#
# A draft is a resource, which is why this exists rather than a `preview` action on
# `CrewsController` — the same reasoning `LoadoutDraftsController` records. Choosing a different
# minion asks the server what that crew would be, and the answer is a rendering rather than a
# saved record; `create` is the honest verb.
#
# It matters more here than it does for parts: changing who is in a job changes **which kit is
# offered**, because equipment is owned per minion. Without a round trip the three equipment
# selects would go on offering the previous person's wardrobe.
#
# POST rather than GET so a roster rides in the body instead of going into the query string —
# and from there into history and logs — on every dropdown change.
class CrewDraftsController < ApplicationController
  include CrewParams

  def create
    @crewing = Crewing.for(owner_id: DevPlayer::ID, crew: submitted_crew)

    render "crews/edit"
  end
end
