# frozen_string_literal: true

# One control point the player can move.
#
# Renders BOTH the target (the slider) and the actual (a ghost marker). They are always equal
# today because every steam engine lever is frictionless — but the simulation reports the pair
# separately precisely so a valve still travelling can be shown, and putting the markup in now
# means the minion seam becomes visible without re-templating.
class LeverComponent < ViewComponent::Base
  attr_reader :control

  # See InstrumentComponent: the collection parameter is named for the data, not the class.
  with_collection_parameter :control

  def initialize(control:)
    @control = control
    super()
  end

  def id = control.fetch(:id)
  def label = control.fetch(:label)
  def min = control.fetch(:min).to_f
  def max = control.fetch(:max).to_f
  def unit = control[:unit].presence
end
