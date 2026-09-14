# frozen_string_literal: true

# The crew, and where each of them is standing.
#
# TODO: expedient — the roster is read from a rebuilt Match, like the panel, and is correct for
# the same reason (configuration, not state). But a minion's STATION is state and can change,
# so the current posting is filled in from the projection rather than rendered here.
class CrewComponent < ViewComponent::Base
  def initialize(minions:, controls:)
    @minions = minions
    @controls = controls
    super()
  end

  attr_reader :minions, :controls
end
