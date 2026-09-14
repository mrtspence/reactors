# frozen_string_literal: true

module Instruments
  # A numeric readout with no scale.
  #
  # Deliberately has no min/max: `Displays::Digital#chrome` does not carry them, on the grounds
  # that a readout with no range gives no sense of how bad a number is. Do not invent one here
  # — that decision belongs to the diagnostic.
  class DigitalComponent < BaseComponent
  end
end
