# frozen_string_literal: true

# **What a match is played under, chosen before it starts.** The season, so far: which it is
# decides the weather a player outfits their workers and their rig for, and only its extremes and
# its spells are left to the seed.
#
# **Not the authority during a match**, for the reason `Loadout` is not: the runner is handed the
# conditions inside the reset command that rebuilds the match.
class MatchSetup < ApplicationRecord
  # The climate every match is played in, until there is more than one.
  CLIMATE = :northern_coalfield

  # Spring, unless a player has chosen otherwise: the mildest, so a first match is not a blizzard.
  DEFAULT_SEASON = "spring"

  validates :match_id, presence: true, uniqueness: true
  validates :season, inclusion: { in: ->(_) { seasons } }

  # The seasons the climate offers, from the simulation's own content rather than a list here.
  def self.seasons = ReactorSim::Content.default.climate(CLIMATE).fetch(:seasons).keys.map(&:to_s)

  def self.for(match_id) = find_or_initialize_by(match_id: match_id.to_s) { |setup| setup.season = DEFAULT_SEASON }

  # The sky's setup as the simulation takes it.
  def to_sim = { climate: CLIMATE, season: season.to_sym }
end
