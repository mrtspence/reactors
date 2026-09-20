# frozen_string_literal: true

# Who is crewing a machine, and what they are carrying.
#
# **Not the authority during a match.** The runner is handed the roster inside the reset command
# that rebuilds the operation, so it never reads this table at a moment when the web process
# might just have written it. This is what a cold runner boots from and what the screen edits —
# exactly the division `Loadout` documents, and for exactly the same race.
class Roster < ApplicationRecord
  validates :match_id, :operation_id, presence: true
  validates :operation_id, uniqueness: { scope: :match_id }

  # **The fifth time this trap has been paid for.** `crew` is jsonb, so everything in it comes
  # back as a String: role ids, minion ids, course ids, equipment ids. The simulation wants
  # Symbols throughout and `Crew.normalise` does the final pass, but handing it strings where it
  # expects a shape is how a roster silently becomes a crew of day-labourers.
  #
  # Arrays stay arrays — `training` is a list, and a list of one is not the same as a scalar.
  def to_sim
    crew.to_h do |role_id, posting|
      [ role_id.to_sym, (posting || {}).to_h { |key, value| [ key.to_sym, symbolise(key, value) ] } ]
    end
  end

  # Upserted, because the crew form is idempotent by construction: it submits the whole roster
  # every time, exactly as a command does.
  def self.fit(match_id:, operation_id:, crew:)
    record = find_or_initialize_by(match_id: match_id.to_s, operation_id: operation_id.to_s)
    record.crew = crew.to_h { |role_id, posting| [ role_id.to_s, stringify(posting) ] }
    record.save!
    record
  end

  # A whole roster, back to the shape that travels over Kafka. JSON has no symbols, so a command
  # payload carries strings and `Crew.normalise` symbolises again at build — doing it in both
  # directions through one pair of methods is what stops the two sides disagreeing about what an
  # empty posting looks like.
  def self.stringify_crew(crew)
    crew.to_h { |role_id, posting| [ role_id.to_s, stringify(posting) ] }
  end

  def self.stringify(posting)
    (posting || {}).to_h do |key, value|
      [ key.to_s, value.is_a?(Array) ? value.map(&:to_s) : value&.to_s.presence ]
    end
  end

  private

  def symbolise(key, value)
    return Array(value).map(&:to_sym) if key.to_s == "training"
    # A name is prose, not an id — symbolising it would turn "Grib" into a constant nobody can
    # look up. Everything else in a posting IS an id.
    return value if key.to_s == "name"

    value.presence&.to_sym
  end
end
