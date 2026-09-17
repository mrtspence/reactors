# frozen_string_literal: true

# The crew, and where each of them is standing.
#
# The roster is read from a rebuilt Match, like the panel, and is correct for the same reason:
# who holds which job, and what they are called, is **configuration** resolved at build from the
# roster in `options:`.
#
# A minion's STATION and any INJURY are state, so both are filled in from the projection rather
# than rendered here. That is now true rather than merely intended — `PlayerView#crew` carries
# them. It did not for a release, and the consequence was a control that always rendered at its
# first option however the crew were actually posted.
class CrewComponent < ViewComponent::Base
  def initialize(minions:, controls:)
    @minions = minions
    @controls = controls
    super()
  end

  attr_reader :minions, :controls
end
