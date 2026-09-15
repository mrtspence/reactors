# frozen_string_literal: true

namespace :blueprints do
  desc "List the blueprint catalogue, derived from the simulation's registries"
  task catalogue: :environment do
    Blueprint::KINDS.each do |kind|
      entries = Blueprint.of_kind(kind)
      puts "#{kind} (#{entries.length})"
      entries.sort_by(&:blueprint_id).each do |b|
        bill = b.free? ? "free" : b.materials.map { |m, kg| "#{m} #{kg.round}" }.join(", ")
        gate = b.requires_achievement ? "  after #{b.requires_achievement}" : ""
        puts format("  %-34s %-30s %s%s", b.blueprint_id, b.label, bill, gate)
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

  # The dev affordance behind stage 5b. There is no players table and no workshop screen yet, so
  # this is how a part gets taken away and given back:
  #
  #   bin/rails "blueprints:revoke[part,ramsbottom_safety_valve]"
  #   bin/rails "blueprints:grant[part,ramsbottom_safety_valve]"
  #
  # Revoking a part that is currently fitted is allowed on purpose — the outfitting screen has to
  # be able to show you a machine holding something you no longer own, or the refusal it reports
  # would be impossible to act on.
  # Goes through the gates, so it is the path a player would take rather than a back door. With
  # nothing awarding achievements yet the gate always opens — but it is a live call site, and a
  # check that only ever runs in a spec rots.
  desc "Earn one blueprint for the dev player, gates enforced — blueprints:grant[kind,id]"
  task :grant, %i[kind id] => :environment do |_t, args|
    blueprint = Blueprint.fetch(args.fetch(:kind), args.fetch(:id))

    unless DevPlayer.earn(blueprint.kind, blueprint.blueprint_id)
      abort "#{blueprint.label} needs #{blueprint.requires_achievement} first."
    end

    bill = blueprint.free? ? "free" : blueprint.materials.map { |m, kg| "#{m} #{kg.round}" }
                                               .join(", ")
    puts "earned #{blueprint.kind} #{blueprint.blueprint_id} (#{blueprint.label}) — #{bill}"
  end

  desc "Revoke one blueprint from the dev player — blueprints:revoke[kind,id]"
  task :revoke, %i[kind id] => :environment do |_t, args|
    blueprint = Blueprint.fetch(args.fetch(:kind), args.fetch(:id))
    removed = DevPlayer.revoke(blueprint.kind, blueprint.blueprint_id)
    puts removed.any? ? "revoked #{blueprint.kind} #{blueprint.blueprint_id}" : "was not owned"
  end

  desc "What the dev player owns, and what they do not"
  task owned: :environment do
    owned = DevPlayer.unlocks.pluck(:kind, :blueprint_id).to_set

    Blueprint.known.sort_by { |b| [ b.kind.to_s, b.blueprint_id ] }.each do |b|
      mark = owned.include?([ b.kind.to_s, b.blueprint_id ]) ? "  " : "??"
      puts format("%s %-9s %-34s %s", mark, b.kind, b.blueprint_id, b.label)
    end
  end
end
