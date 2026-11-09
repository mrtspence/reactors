# frozen_string_literal: true

# **One place on the console**: its schematic's room, its instruments, its levers, and who is
# there and on the way. Every place's panel is in the page and one is shown, so a hidden one
# stays painted and changing place costs no request.
#
# Driven entirely by `Operation#panel`, never by a hardcoded list, so a new gauge appears in its
# place without anybody touching the view layer.
class PlacePanelComponent < ViewComponent::Base
  def initialize(place:, shown:, here:, minions:, stations:, places_known:)
    @place = place
    @shown = shown
    @here = here
    @minions = minions
    @stations = stations
    @places_known = places_known
    super()
  end

  attr_reader :place, :here, :minions, :stations

  def shown? = @shown
  def places_known? = @places_known
  def id = place.id
  def instruments = place.instruments
  def controls = place.controls
end
