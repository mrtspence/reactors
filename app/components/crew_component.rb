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
# **`stations`, not `controls`.** Somewhere a person can stand is not the same list as things a
# player can move: the crew quarters is a posting with nothing to set, so it belongs in this
# dropdown and not on the lever strip.
class CrewComponent < ViewComponent::Base
  def initialize(minions:, stations:)
    @minions = minions
    @stations = stations
    super()
  end

  attr_reader :minions, :stations
end
