# frozen_string_literal: true

# Idempotent, and run as often as you like — `bin/rails db:seed`, or automatically by
# `db:setup`.

# **The dev player owns the whole catalogue**, so the outfitting screen shows everything and the
# game plays exactly as it did before blueprints existed. That is stage 5a's acceptance
# criterion rather than a placeholder: the machinery is real, and enforcement (stage 5b) is what
# starts taking things away. See `docs/design_sketches/blueprints.md` §11.
DevPlayer.grant_everything!

# **The machines, and who owns them.** Idempotent and never touches an existing `owner_id`, so
# re-seeding cannot transfer a machine out from under whoever holds it.
DevMatch.provision!

Rails.logger.debug { "seeded #{DevPlayer.unlocks.count} unlocks for #{DevPlayer::ID}" }
Rails.logger.debug { "provisioned #{Operation.in_match(DevMatch::ID).count} operations" }
