# frozen_string_literal: true

namespace :blueprints do
  desc "List the blueprint catalogue, derived from the simulation's registries"
  task catalogue: :environment do
    Blueprint::KINDS.each do |kind|
      entries = Blueprint.of_kind(kind)
      puts "#{kind} (#{entries.length})"
      entries.sort_by(&:blueprint_id).each do |b|
        puts format("  %-34s %s", b.blueprint_id, b.label)
      end
      puts
    end
  end

  # **The guard against a rename, which is the drift that actually happens.**
  #
  # Stage 3 of the modularisation renamed `:stock_boiler` to `:locomotive_boiler`. Nothing stops
  # that, and an `unlocks` row left pointing at the old id is not a crash — it is a player
  # quietly missing a part they earned. Validation refuses to *create* one; this finds the ones a
  # rename left behind.
  #
  # Deliberately not a boot check. Building the catalogue reads the content YAML, and
  # `config/initializers/reactor_sim.rb` keeps that lazy on purpose so no process pays for it at
  # boot; a boot-time database read would be worse still. Run this after renaming anything.
  desc "Report unlock rows naming a blueprint the catalogue no longer has"
  task audit: :environment do
    stale = Unlock.stale

    if stale.empty?
      puts "#{Unlock.count} unlock(s) checked against #{Blueprint.known.length} blueprints: all resolve."
      next
    end

    warn "#{stale.length} stale unlock(s) — these name a blueprint that no longer exists:"
    stale.each { |row| warn "  #{row.owner_id}  #{row.kind}  #{row.blueprint_id}" }
    abort "Rename them or delete them; a player is currently missing what these stood for."
  end

  desc "Grant the whole catalogue to the dev player"
  task grant_all: :environment do
    DevPlayer.grant_everything!
    puts "#{DevPlayer.unlocks.count} blueprint(s) owned by #{DevPlayer::ID}."
  end
end
