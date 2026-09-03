# frozen_string_literal: true

module Instruments
  # What every instrument shares: its identity on the page.
  #
  # The `data-` attributes are the whole contract with Stimulus. Chrome is rendered ONCE, here,
  # and only values stream afterwards — so the client finds each gauge by id and writes into it
  # rather than re-rendering anything (docs/architecture.md §7).
  class BaseComponent < ViewComponent::Base
    attr_reader :chrome

    def initialize(chrome:)
      @chrome = chrome
      super()
    end

    def id = chrome.fetch(:id)
    def label = chrome.fetch(:label)
    def unit = chrome[:unit].presence

    # Written by Stimulus on every update; `--` until the first projection arrives, which is
    # honest — the page has genuinely not been told anything yet.
    def placeholder = "—"
  end
end
