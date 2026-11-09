# frozen_string_literal: true

class Frame
  # **The state strip**, under the nav row on every page: the sky as this machine's people tell
  # it, and what this machine makes. Instruments like any other, painted from the same view.
  class StripComponent < ViewComponent::Base
    def initialize(frame:)
      @frame = frame
      super()
    end

    attr_reader :frame
  end
end
