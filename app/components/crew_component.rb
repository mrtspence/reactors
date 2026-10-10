# frozen_string_literal: true

# The crew, and where each of them is standing.
#
# The roster is read from a rebuilt Match, like the panel, and is correct for the same reason:
# who holds which job, and what they are called, is **configuration** resolved at build from the
# roster in `options:`.
#
# A minion's STATION and any INJURY are state, so both are filled in from the projection rather
# than rendered here. That is now true rather than merely intended — `PlayerView#crew` carries
# them. It did not for a release, and the consequence was a control that always rendered at its
# first option however the crew were actually posted.
# **`stations`, not `controls`.** Somewhere a person can stand is not the same list as things a
# player can move: the crew quarters is a posting with nothing to set, so it belongs in this
# dropdown and not on the lever strip.
class CrewComponent < ViewComponent::Base
  def initialize(minions:, stations:, places: [])
    @minions = minions
    @stations = stations
    @places = places
    super()
  end

  attr_reader :minions, :stations

  # Place id to label, for the projection to look a minion's room up in. Rendered as data rather
  # than resolved server-side because where somebody is standing is state and arrives on the
  # cable; only the names are chrome.
  def place_labels = @places.to_h { |place| [ place.fetch(:id), place.fetch(:label) ] }.to_json

  # **Who this one could be sent to fetch**, which is everybody but themselves. Offered as part of
  # the same dropdown that posts somebody to a lever, because a fetch order *is* a posting — the
  # id spaces cannot collide, so one control still cannot be ambiguous.
  #
  # Chrome, not state: who is on the roster is configuration, and whether a given carry would
  # actually be accepted is the simulation's business. The engine refuses what it cannot do, and
  # offering an order that comes back refused is better than a dropdown that silently hides the
  # one person the player is looking for.
  def rescuable(minion) = minions.reject { |other| other.id == minion.id }

  # **No places, no carrying.** Without geometry everybody is always wherever they are needed, so
  # there is nobody to go and fetch — and offering the order would put a dozen inert entries in
  # the steam engine's dropdown.
  def places_known? = @places.any?
end
