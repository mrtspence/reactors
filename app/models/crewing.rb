# frozen_string_literal: true

# The pre-match crew screen: how many hands the operation can field, who is in each seat, and
# what they can carry.
#
# **Seats, not jobs.** `crew_1` is "the first person you brought", and where they stand is a
# decision made during the match rather than a field on this form — everybody starts in the crew
# quarters and is sent somewhere. How many seats there are comes from the fitted quarters, so
# capacity is something a player buys.
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

  attr_reader :owner_id, :operation_id, :crew

  def self.for(owner_id:, operation_id: DevMatch::PRIMARY, crew: nil, standin: nil)
    new(owner_id: owner_id, operation_id: operation_id, crew: crew, standin: standin)
  end

  # Lives here rather than in the controller so `permit` does not have to know what a seat is —
  # the same division `Outfitting.slot_ids` exists for.
  def self.seat_ids(operation_id: DevMatch::PRIMARY)
    new(owner_id: nil, operation_id: operation_id).seats.map(&:to_s)
  end

  # Who the labour exchange sends when a seat is left empty. Not a person a player owns — the
  # sim resolves an unnamed posting to `Crew::STANDIN` — but the gear they are handed is.
  STANDIN = ReactorSim::Crew::STANDIN

  def initialize(owner_id:, operation_id: DevMatch::PRIMARY, crew: nil, standin: nil)
    @owner_id = owner_id.to_s
    @operation_id = operation_id.to_sym
    # nil means "show what is stored"; a hash means "show this draft", and an empty hash means
    # every seat deliberately unfilled — which is a legitimate machine crewed by day-labourers.
    @crew = resolve(crew)
    @standin = standin&.to_h { |k, v| [ k.to_sym, v ] }
  end

  # From the fitted quarters, through the registry — so this screen never names a concrete
  # operation and a better mess room is what buys another pair of hands.
  def capacity = DevMatch.outfitting(operation_id: operation_id).crew_capacity

  def seats = ReactorSim::Crew.seats(capacity)

  def posting(seat_id) = @crew.fetch(seat_id.to_sym, {})

  # **Where this seat's hand starts the match**, which is not the quarters for all of them: a
  # mine puts an advance shift in the district so there is work to do before anybody has walked
  # anywhere. Nil for a machine with no geometry, and nil is the common case.
  #
  # A property of the SEAT rather than of who is in it, so a draft never changes the answer.
  # Nil also for the ordinary seats that begin in the quarters, so the line only ever calls out
  # a seat that is somewhere else.
  def starts_in(seat_id)
    place, station = origins[seat_id.to_sym]
    return nil if station == quarters_station

    place_labels[place]
  end

  # Who this player could put in this seat. Everybody they own, plus whoever is already posted
  # even if they have since become unavailable — hiding a fitted choice would report an error
  # about something the player cannot see, which is the rule `Outfitting#available` follows.
  # **Filtered to people the catalogue still knows.** A rename leaves `unlocks` rows pointing at
  # ids that no longer exist — the drift `Unlock.stale` exists to find, and it happened
  # immediately here: rows granted when `fireman` was a *minion* rather than a job outlived the
  # noun correction. A stale row is a player quietly missing somebody they earned, which is bad;
  # a stale row that raises is a crew screen that will not render at all, which is worse.
  # `rake blueprints:audit` is what finds them.
  def candidates(seat_id)
    fitted = posting(seat_id)[:minion]
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
  def equipment_for(seat_id, slot)
    minion = posting(seat_id)[:minion] or return []

    kit_for(minion, slot)
  end

  # --- the labour exchange ------------------------------------------------------------------
  #
  # **One kit for every seat nobody was posted to**, because it is the pit's gear rather than
  # anybody's: a rack in the lamp cabin that whoever turns up is issued from. Without it a
  # day-labourer is a hewer with no pick and no light, and `gated_by:` scores that at exactly
  # zero however many of them you field.
  #
  # Stored beside the roster rather than copied into each empty seat, so raising the standard
  # re-equips them all at once instead of only the ones saved since.

  # nil means "show what is stored", exactly as `crew:` does.
  def standin_posting = @standin_posting ||= @standin || stored_standin

  def standin_equipment(slot) = kit_for(STANDIN, slot)

  # Nothing to choose from in any slot means nothing to show. A player who has bought no gear
  # for the exchange should see the section explain itself, not three empty dropdowns.
  def standin_kit_offered?
    ReactorSim::Equipment::SLOTS.any? { |slot| standin_equipment(slot).any? }
  end

  def training_for(seat_id)
    minion = posting(seat_id)[:minion] or return []

    ReactorSim::Training.known.map { |id| ReactorSim::Training.fetch(id) }
                        .select { |course| owns?(:training, "#{minion}/#{course.id}") }
  end

  # **The crew a player has posted somebody unavailable into is not a valid crew**, and the
  # screen says so rather than silently substituting. Substituting is what happens at BUILD, for
  # a seat left empty — which is a different statement and should feel different.
  def unavailable
    seats.filter_map do |seat|
      id = posting(seat)[:minion] or next
      found = candidate(id)
      found unless found.available?
    end
  end

  def ok? = unavailable.empty?

  # Every seat named, including the empty ones, so a seat a player deliberately left to the
  # standin does not re-default on the next render.
  def to_sim = seats.to_h { |seat| [ seat, posting(seat) ] }

  # **Store, then build the command, then advance, then produce.** The roster has to be written
  # before the command is built, or the command carries the previous crew; and the clock advances
  # after the command is built, so somebody whose last match this was is still out for the
  # machine being built now.
  def fit!
    Roster.fit(match_id: DevMatch::ID, operation_id: operation_id, crew: to_sim,
               standin: standin_posting)
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

    ReactorSim::Crew.normalise(given, capacity: capacity)
  end

  def kit_for(minion, slot)
    ReactorSim::Equipment.of_slot(slot).select { |item| owns?(:equipment, "#{minion}/#{item.id}") }
  end

  def stored_standin
    Roster.find_by(match_id: DevMatch::ID, operation_id: operation_id.to_s)&.standin_kit || {}
  end

  # **A stored roster can name more seats than the fitted quarters has**, because a player may
  # have downgraded since. `Crew.normalise` refuses that outright, which is right at build and
  # wrong here: it would leave the crew screen unrenderable with no way back. Drop the seats that
  # no longer exist for *display*, and let the fit refuse if the player tries to keep them.
  def stored
    row = Roster.find_by(match_id: DevMatch::ID, operation_id: operation_id.to_s)
    return {} if row.nil?

    ReactorSim::Crew.normalise(row.to_sim.slice(*seats.map(&:to_s), *seats), capacity: capacity)
  end

  # One query per kind, then membership tests — the shape `Unlock.owned_ids` exists for. This
  # screen asks "do they own this?" about every item in every slot for every role.
  def owned_ids(kind) = (@owned_ids ||= {})[kind] ||= Unlock.owned_ids(owner_id, kind)

  def owns?(kind, blueprint_id) = owned_ids(kind).include?(blueprint_id.to_s)

  def owned_minions = @owned_minions ||= owned_ids(:minion).to_a

  def conditions
    @conditions ||= MinionCondition.remaining_for(owner_id)
  end

  # Both read off a built machine, because where a shift starts is decided by the operation and
  # the fitted quarters rather than by anything on this screen.
  def origins
    @origins ||= DevMatch.crew(operation_id: operation_id)
                         .to_h { |m| [ m.id, [ m.default_place, m.default_station ] ] }
  end

  def quarters_station
    @quarters_station ||= DevMatch.outfitting(operation_id: operation_id).crew_origin
  end

  def place_labels
    @place_labels ||= DevMatch.panel(operation_id: operation_id)
                              .fetch(:places, [])
                              .to_h { |place| [ place.fetch(:id), place.fetch(:label) ] }
  end
end
