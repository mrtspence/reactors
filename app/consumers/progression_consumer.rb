# frozen_string_literal: true

# `match.events` → a player's permanent record.
#
# Deliberately thin: everything that decides anything lives in `ProgressionDigest`, which takes
# a decoded Hash and needs no broker. That split is what lets the fold be specced properly —
# a consumer spec that has to stand up Kafka gets written once and then avoided.
class ProgressionConsumer < ApplicationConsumer
  def consume
    messages.each do |message|
      record = decode(message) or next

      MatchRun.observe!(run_id: record.fetch("run_id"), match_id: record.fetch("match_id"))
      # Two questions about the same stream, kept apart: what this player has achieved, and who
      # they can field next time.
      injuries.call(record)
      awarded = digest.call(record)
      next if awarded.empty?

      Rails.logger.info("progression: awarded #{awarded.join(', ')} " \
                        "from #{record['type'] || record['kind']}")
    end
  end

  private

  def injuries = @injuries ||= InjuryList.new(owner_id: DevPlayer::ID)

  # One per batch rather than one per message: it holds no per-record state, and the owner is
  # fixed until there is auth.
  #
  # TODO: `DevPlayer::ID` is the only owner there is, so every award lands on one placeholder
  # player. "Does the gate work" is testable; "does it gate the right person" is not. Real
  # attribution arrives with Devise + OmniAuth, and the column is already there for it.
  def digest = @digest ||= ProgressionDigest.new(owner_id: DevPlayer::ID)
end
