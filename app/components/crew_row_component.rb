# frozen_string_literal: true

# One person: where they are, what has happened to them, and where they are sent.
#
# Who they are is configuration, resolved at build from the roster in `options:`. Where they are,
# their posting and any injury are state, filled in from the projection — and the `crew`
# controller moves the row into the panel of whichever place they are in.
#
# **`stations`, not `controls`.** Somewhere a person can stand is not the same list as things a
# player can move: the crew quarters is a posting with nothing to set, so it belongs in this
# dropdown and not among the levers.
class CrewRowComponent < ViewComponent::Base
  def initialize(minion:, order:, minions:, stations:, places_known:)
    @minion = minion
    @order = order
    @minions = minions
    @stations = stations
    @places_known = places_known
    super()
  end

  attr_reader :minion, :order, :stations

  # **Who this one could be sent to fetch**, which is everybody but themselves. Offered in the
  # same dropdown that posts somebody to a lever, because a fetch order *is* a posting — the id
  # spaces cannot collide, so one control still cannot be ambiguous. Whether a carry is accepted
  # is the simulation's business; it refuses what it cannot do.
  def rescuable = @minions.reject { |other| other.id == minion.id }

  # **No places, no carrying.** Without geometry everybody is always wherever they are needed, so
  # there is nobody to go and fetch.
  def places_known? = @places_known
end
