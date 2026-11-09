# frozen_string_literal: true

class Frame
  # **The feed**, the right column on every page: what has gone wrong, newest first, kept across
  # navigation between this machine's screens.
  #
  # TODO: an entry opens a dialog with the event's detail (a fight's report, a shot's), the UI
  # overhaul's U6. Entries are plain list items until then.
  class FeedComponent < ViewComponent::Base
    def initialize(frame:)
      @frame = frame
      super()
    end

    attr_reader :frame
  end
end
