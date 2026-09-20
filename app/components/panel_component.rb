# frozen_string_literal: true

# The whole console: instruments, levers and crew.
#
# Driven entirely by `Operation#panel`, never by a hardcoded list — the high-pressure engine has
# twelve instruments and the atmospheric one thirteen, and a new gauge must appear here without
# anybody touching the view layer.
#
# TODO: expedient — instruments are laid out in the order the operation happens to declare them.
# `panel.rb` carries no grouping or layout information, so there is nothing here that puts the
# fire gauges together and the engine gauges together. A proper implementation either adds
# grouping to the panel data or authors a layout per operation.
class PanelComponent < ViewComponent::Base
  def initialize(panel:, minions: [])
    @panel = panel
    @minions = minions
    super()
  end

  def instruments = @panel.fetch(:instruments)
  def controls = @panel.fetch(:controls)

  # Everywhere a person can be posted, which is a longer list than the levers: the crew quarters
  # is somewhere to stand with nothing to set.
  def stations = @panel.fetch(:stations)
  attr_reader :minions
end
