# frozen_string_literal: true

# The one player this prototype has, and the owner of every unlock.
#
# TODO: expedient — there is exactly one hardcoded player, exactly as there is exactly one
# hardcoded match. No accounts, no sessions, no authentication. A proper implementation has an
# owner per session and this module becomes `current_player`. The shape is chosen so that is the
# only change: nothing outside here knows the id is a constant.
#
# **Everything is granted at stage 5a and that is the acceptance criterion, not an oversight.**
# The machinery is real — real rows, real validation, real revocation — and the dev player simply
# owns the whole catalogue, so the outfitting screen looks exactly as it did before. Enforcement
# is stage 5b, and it wants something to revoke *down to*: every part registered today is a
# mid-tier part, and the starting tier the design calls for does not exist yet
# (`docs/design_sketches/blueprints.md` §1).
module DevPlayer
  ID = "dev"

  module_function

  def unlocks = Unlock.owned_by(ID)

  def owned_ids(kind) = Unlock.owned_ids(ID, kind)

  def unlocked?(kind, blueprint_id)
    unlocks.exists?(kind: kind.to_s, blueprint_id: blueprint_id.to_s)
  end

  # **Acquire a blueprint the way a player would: through its gates.** Returns the `Unlock`, or
  # nil — changing nothing — when a prerequisite is unmet.
  #
  # Distinct from `grant` on purpose. Earning is the real path and is checked; granting is a
  # development override and says so by being a different word. Conflating them would mean the
  # gate had no live call site and would rot — which is what happens to every check that only
  # ever runs in a spec.
  def earn(kind, blueprint_id)
    blueprint = Blueprint.fetch(kind, blueprint_id)
    return unless blueprint.obtainable_by?(ID)

    grant(blueprint.kind, blueprint.blueprint_id)
  end

  # Every blueprint in the catalogue, **gates ignored**. Idempotent, so it is safe to call from a
  # seed, a rake task, or a spec's setup as often as you like.
  #
  # Bypassing the gates is the point: this is the stage 5a baseline where the dev player owns
  # everything so the game plays as it did, and nothing awards an achievement yet.
  def grant_everything!
    Blueprint.known.each do |blueprint|
      Unlock.grant(owner_id: ID, kind: blueprint.kind, blueprint_id: blueprint.blueprint_id)
    end
  end

  def grant(kind, blueprint_id)
    Unlock.grant(owner_id: ID, kind: kind, blueprint_id: blueprint_id)
  end

  def revoke(kind, blueprint_id)
    Unlock.revoke(owner_id: ID, kind: kind, blueprint_id: blueprint_id)
  end
end
