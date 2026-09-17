# frozen_string_literal: true

# The pre-match crew screen: which jobs the machine has, who is available for each, and what
# they can carry.
#
# **`Outfitting`'s twin**, down to the shape of the arguments. It takes resolved values and never
# `params`, so the controller stays routing and this stays testable without one; it answers what
# a *draft* would be as readily as what is stored, because the screen previews every change; and
# ownership is read through `owner_id` rather than reaching for `DevPlayer`, so the argument is
# not decorative the day there is real auth.
#
# See docs/design_sketches/minions.md §8.
class Crewing
  # Somebody unavailable is not somebody who does not exist — they are on the injury list, and
  # the screen has to say so rather than quietly omitting them. That is the moment the standin
  # stops being an abstraction.
  Candidate = Struct.new(:id, :name, :archetype, :unavailable_for, keyword_init: true) do
    def available? = unavailable_for.to_i.zero?
  end

  attr_reader :owner_id, :crew

  def self.for(owner_id:, crew: nil)
    new(owner_id: owner_id, crew: crew)
  end

  # Lives here rather than in the controller so `permit` does not have to know what a role is —
  # the same division `Outfitting.slot_ids` exists for.
  def self.role_ids = ReactorSim::Operations::SteamEngine.crew_roles.map { |role| role.id.to_s }

  def initialize(owner_id:, crew: nil)
    @owner_id = owner_id.to_s
    # nil means "show what is stored"; a hash means "show this draft", and an empty hash means
    # every role deliberately unfilled — which is a legitimate machine crewed by day-labourers.
    @crew = resolve(crew)
  end

  def roles = ReactorSim::Operations::SteamEngine.crew_roles

  def posting(role_id) = @crew.fetch(role_id.to_sym, {})

  # Who this player could put in this job. Everybody they own, plus whoever is already posted
  # even if they have since become unavailable — hiding a fitted choice would report an error
  # about something the player cannot see, which is the rule `Outfitting#available` follows.
  # **Filtered to people the catalogue still knows.** A rename leaves `unlocks` rows pointing at
  # ids that no longer exist — the drift `Unlock.stale` exists to find, and it happened
  # immediately here: rows granted when `fireman` was a *minion* rather than a job outlived the
  # noun correction. A stale row is a player quietly missing somebody they earned, which is bad;
  # a stale row that raises is a crew screen that will not render at all, which is worse.
  # `rake blueprints:audit` is what finds them.
  def candidates(role_id)
    fitted = posting(role_id)[:minion]
    ids = (owned_minions | [ fitted&.to_s ].compact).select { |id| known?(id) }

    ids.sort.map { |id| candidate(id) }
  end

  def known?(id) = ReactorSim::Content.default.minions.key?(id.to_sym)

  def candidate(id)
    spec = ReactorSim::Content.default.minion(id)

    Candidate.new(id: id.to_s, name: spec.fetch(:name),
                  archetype: ReactorSim::Content.default.archetype(spec.fetch(:archetype))
                                                .fetch(:label),
                  unavailable_for: conditions.fetch(id.to_s, 0))
  end

  # What this player owns for this minion, in this slot. Scoped ids are what make ownership
  # per-minion without a migration: `jim/leather_apron`.
  def equipment_for(role_id, slot)
    minion = posting(role_id)[:minion] or return []

    ReactorSim::Equipment.of_slot(slot).select do |item|
      owns?(:equipment, "#{minion}/#{item.id}")
    end
  end

  def training_for(role_id)
    minion = posting(role_id)[:minion] or return []

    ReactorSim::Training.known.map { |id| ReactorSim::Training.fetch(id) }
                        .select { |course| owns?(:training, "#{minion}/#{course.id}") }
  end

  # **The crew a player has posted somebody unavailable into is not a valid crew**, and the
  # screen says so rather than silently substituting. Substituting is what happens at BUILD, for
  # a role left empty — which is a different statement and should feel different.
  def unavailable
    roles.filter_map do |role|
      id = posting(role.id)[:minion] or next
      found = candidate(id)
      found unless found.available?
    end
  end

  def ok? = unavailable.empty?

  # Every role named, including the empty ones, so a role a player deliberately left to the
  # standin does not re-default on the next render.
  def to_sim = roles.to_h { |role| [ role.id, posting(role.id) ] }

  # **Store, then build the command, then advance, then produce.** The roster has to be written
  # before the command is built, or the command carries the previous crew; and the clock advances
  # after the command is built, so somebody whose last match this was is still out for the
  # machine being built now.
  def fit!
    Roster.fit(match_id: DevMatch::ID, operation_id: DevMatch::OPERATION_ID, crew: to_sim)
    command = DevMatch.reset_command
    DevMatch.start!
    CommandProducer.instance.produce(match_id: DevMatch::ID, command: command)
  rescue StandardError => e
    Rails.logger.error("crewing: fit failed: #{e.class}: #{e.message}")
    raise Outfitting::NotDelivered, e.message
  end

  private

  def resolve(given)
    return stored if given.nil?

    ReactorSim::Crew.normalise(given, roles: roles)
  end

  def stored
    row = Roster.find_by(match_id: DevMatch::ID, operation_id: DevMatch::OPERATION_ID)
    return {} if row.nil?

    ReactorSim::Crew.normalise(row.to_sim, roles: roles)
  end

  # One query per kind, then membership tests — the shape `Unlock.owned_ids` exists for. This
  # screen asks "do they own this?" about every item in every slot for every role.
  def owned_ids(kind) = (@owned_ids ||= {})[kind] ||= Unlock.owned_ids(owner_id, kind)

  def owns?(kind, blueprint_id) = owned_ids(kind).include?(blueprint_id.to_s)

  def owned_minions = @owned_minions ||= owned_ids(:minion).to_a

  def conditions
    @conditions ||= MinionCondition.remaining_for(owner_id)
  end
end
