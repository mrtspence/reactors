# frozen_string_literal: true

module Instruments
  # A dial with a scale.
  #
  # `min`/`max` are fetched rather than defaulted: a needle without a scale has no way to
  # position itself, so a chrome missing them is a bug in the diagnostic, not something to
  # paper over with 0..100. Digital and Prose never ask for them, which is what makes it safe
  # for chrome kinds to carry different fields.
  class NeedleComponent < BaseComponent
    def min = chrome.fetch(:min).to_f
    def max = chrome.fetch(:max).to_f
  end
end
