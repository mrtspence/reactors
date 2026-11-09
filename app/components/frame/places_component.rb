# frozen_string_literal: true

class Frame
  # **The places box**: one line a place, how many are there and the first of its boards saying
  # something that is not calm. Picking one shows its panel. Only the boards that name calm
  # phrases are read, and only those phrases reach the page — the rest of a board's words stay
  # the display's.
  class PlacesComponent < ViewComponent::Base
    def initialize(places:, operation_id:)
      @places = places
      @operation_id = operation_id
      super()
    end

    attr_reader :places, :operation_id

    def boards(place) = place.instruments.filter_map { |chrome| { id: chrome.fetch(:id), calm: chrome[:calm] } if chrome[:calm] }.to_json
  end
end
