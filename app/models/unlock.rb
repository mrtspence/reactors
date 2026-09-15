# frozen_string_literal: true

# One blueprint, owned by one player, permanently.
#
# There is no quantity and no condition here on purpose. Owning a blueprint is the right to mint
# a fresh instance whenever you build a machine; it is not a part sitting in a shed, and using it
# does not consume it. See `docs/design_sketches/blueprints.md` §1.
class Unlock < ApplicationRecord
  validates :owner_id, :kind, :blueprint_id, presence: true
  validates :kind, inclusion: { in: Blueprint::KINDS.map(&:to_s),
                                message: "is not a blueprint kind" }
  validates :blueprint_id, uniqueness: { scope: %i[owner_id kind] }
  validate :blueprint_must_exist

  scope :owned_by, ->(owner_id) { where(owner_id: owner_id.to_s) }

  def blueprint = Blueprint.fetch(kind, blueprint_id)

  def key = [ kind.to_sym, blueprint_id ]

  # Idempotent, because "grant everything" runs on every boot of a dev environment and because a
  # double-submitted form must not be an error. The unique index is the backstop.
  def self.grant(owner_id:, kind:, blueprint_id:)
    find_or_create_by!(owner_id: owner_id.to_s, kind: kind.to_s,
                       blueprint_id: blueprint_id.to_s)
  end

  def self.revoke(owner_id:, kind:, blueprint_id:)
    owned_by(owner_id).where(kind: kind.to_s, blueprint_id: blueprint_id.to_s).destroy_all
  end

  # Every blueprint id one owner holds of one kind, as a Set of Strings. **One query, then
  # membership tests** — the outfitting screen asks "do they own this?" about every candidate in
  # every slot, which is twenty-odd slots times however many parts fit each, so a query per
  # question would be several hundred round trips on one page render.
  def self.owned_ids(owner_id, kind)
    owned_by(owner_id).where(kind: kind.to_s).pluck(:blueprint_id).to_set
  end

  # **Rows that name a blueprint the catalogue no longer has.**
  #
  # This is the drift that actually happens, and it has happened already: stage 3 of the
  # modularisation renamed `:stock_boiler` to `:locomotive_boiler`. Nothing stops a rename, so
  # the guard is to be able to *find* the wreckage afterwards rather than to pretend it cannot
  # occur — a stale row is not a crash, it is a player quietly missing a part they earned.
  #
  # Validation refuses to create one; this finds any that a rename left behind.
  # `rake blueprints:audit` is the thing that calls it.
  def self.stale(owner_id = nil)
    scope = owner_id ? owned_by(owner_id) : all
    scope.reject { |row| Blueprint.key?(row.kind, row.blueprint_id) }
  end

  private

  # Silent when the kind is already wrong, so one mistake produces one message. "gubbins is not a
  # blueprint kind" and "is not a known gubbins blueprint" are the same complaint twice, and the
  # second is the less useful half.
  def blueprint_must_exist
    return if blueprint_id.blank? || errors.include?(:kind)
    return if Blueprint.key?(kind, blueprint_id)

    errors.add(:blueprint_id, "is not a known #{kind} blueprint")
  end
end
