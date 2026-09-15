# frozen_string_literal: true

# Everything the outfitting screen needs, and the act of committing it.
#
# **Two validators meet here and stay separate.** `ReactorSim::Assembly` answers *"will this build
# run?"* — a question about the machine, which is why it can be specced without a player and why
# it stays simple. This object answers the second question, *"is this yours?"*, which is about a
# person and belongs on this side of the boundary
# (`docs/design_sketches/blueprints.md` §2, §6). Nothing here reaches into the simulation; the
# simulation still knows nothing about players, ownership or cost.
#
# It takes **resolved arguments** — an owner id and a parts hash — never `params`, and never
# touches `session`, `request` or `flash`. That is what lets a rake task drive it and a spec
# exercise it without a request.
class Outfitting
  # Raised when the engine room cannot be reached. The store succeeded or it did not; either way
  # the caller has to decide what to tell the player, and that is a controller's business.
  class NotDelivered < StandardError; end

  attr_reader :owner_id, :chassis, :assembly

  # `parts` is nil for "show what is fitted" and a hash for "show this draft". They are not the
  # same: an empty hash means every slot explicitly empty, which is a stripped machine.
  #
  # A blank `chassis` falls back to what is stored, so an unrecognised one cannot silently become
  # a different machine — `assembly_for` raises on a frame it does not know, which is what we
  # want for a hand-typed id, but not for an empty select.
  def self.for(owner_id:, parts: nil, chassis: nil)
    new(owner_id: owner_id, parts: parts, chassis: chassis.presence&.to_sym || DevMatch.chassis)
  end

  # The keys a form may submit. Lives here rather than in the controller so the controller's
  # `permit` call does not have to know what a slot is.
  #
  # **Takes the chassis the form submitted, not the stored one.** The two differ for exactly one
  # request — the one where a player changes frame — and permitting against the old chassis would
  # drop the slots the new one has.
  def self.slot_ids(chassis = nil)
    DevMatch.outfitting(chassis: chassis.presence&.to_sym).slots.map { |slot| slot.id.to_s }
  end

  # Frames this machine can be built on, filtered the way parts are: what the player owns, plus
  # whatever is currently fitted even if they no longer own it.
  def self.chassis_choices(owner_id, current = nil)
    owned = Unlock.owned_ids(owner_id, :chassis)
    frames = ReactorSim::Operations.chassis_for(DevMatch::TYPE)

    frames.select { |frame| owned.include?(blueprint_id_for(frame)) || frame == current }
  end

  def self.blueprint_id_for(frame) = Blueprint.chassis_id(DevMatch::TYPE, frame)

  def initialize(owner_id:, chassis:, parts: nil)
    @owner_id = owner_id
    @chassis = chassis
    @assembly = DevMatch.outfitting(chassis: chassis, loadout: resolve(parts))
  end

  delegate :slots, :part, :loadout, to: :assembly

  # **Parts fitted that the owner does not own.** Refuses the build, and is reported apart from
  # the structural verdict because it is a different failure with a different fix: one is "this
  # machine cannot work", the other is "this machine is not yours".
  def locked
    @locked ||= slots.filter_map do |slot|
      fitted = part(slot.id)
      fitted if fitted && !owns?(fitted)
    end
  end

  # What the dropdown for a slot may offer. **A courtesy, not a gate** — the form is a plain POST
  # and anyone can submit any id, which is exactly why `locked` exists.
  def available(slot)
    candidates = ReactorSim::Parts.of_kind(slot.accepts).select { |p| owns?(p) }
    fitted = part(slot.id)
    # A locked part that is *already fitted* still appears, selected, so the screen tells the
    # truth about the machine rather than quietly showing a different one. It reads as an error
    # above; hiding it here would make that error impossible to act on.
    return candidates if fitted.nil? || candidates.include?(fitted)

    candidates + [ fitted ]
  end

  def locked?(part) = !owns?(part)

  # A frame is unlockable like anything else, and it is the larger purchase of the two — so it is
  # reported on its own line rather than folded in with the parts, which would read as though a
  # fitting were at fault.
  def chassis_locked?
    !owned_ids(:chassis).include?(self.class.blueprint_id_for(chassis))
  end

  def chassis_label = Blueprint.fetch(:chassis, self.class.blueprint_id_for(chassis)).label

  def chassis_choices = self.class.chassis_choices(owner_id, chassis)

  def errors = assembly.verdict.errors
  def warnings = assembly.verdict.warnings
  def ok? = locked.empty? && !chassis_locked? && assembly.verdict.ok?

  # Store, then tell the runner — and in that order, which is the whole design. A build that
  # cannot assemble never reaches the database, so a runner booting cold cannot inherit a machine
  # the validator already refused; and the loadout rides **inside** the reset command rather than
  # being referenced by it, so a reset racing a save cannot rebuild the previous machine.
  #
  # Caller checks `ok?` first. This does not re-check, because a method that silently did nothing
  # when asked to commit is worse than one that trusts its caller.
  def fit!
    Loadout.fit(match_id: DevMatch::ID, operation_id: DevMatch::OPERATION_ID,
                chassis: chassis, parts: loadout)
    CommandProducer.instance.produce(match_id: DevMatch::ID, command: DevMatch.reset_command)
  rescue StandardError => e
    Rails.logger.error("outfitting: fit failed: #{e.class}: #{e.message}")
    raise NotDelivered, e.message
  end

  private

  # Ownership is read through `owner_id`, never through `DevPlayer`. The stub happens to be the
  # only owner there is, but a service object that reached for it directly would have to be
  # rewritten the day there are real players — and its `owner_id` argument would have been
  # decorative in the meantime, which is how an argument quietly stops meaning anything.
  #
  # Memoised per kind: one query, then membership tests. The screen asks "do they own this?" about
  # every candidate in every slot, so a query per question would be several hundred round trips.
  def owned_ids(kind) = (@owned_ids ||= {})[kind] ||= Unlock.owned_ids(owner_id, kind)

  def owns?(part) = owned_ids(:part).include?(part.id.to_s)

  # **A slot the form offered and left empty is an explicit empty; a slot it never offered is not
  # mentioned at all.** Both halves matter and they pull opposite ways.
  #
  # `Assembly#resolve_loadout` falls back to `slot.default` for any slot the loadout does not
  # name. That is why an unfitted slot has to be submitted as an explicit nil — otherwise taking
  # the fusible plug off and saving would silently put it back.
  #
  # But when the **chassis changes**, the form that submitted was drawn for the old frame, so a
  # slot only the new frame has was never on it. Naming it anyway — as this method first did —
  # sends an explicit empty for a question the player was never asked, and switching to the
  # atmospheric frame refused itself with *"Condenser is required and nothing is fitted"*.
  #
  # So: carry through only the keys the submission actually contains. A same-frame save names
  # every slot, because the form renders every slot, and nothing re-defaults. A frame change
  # names the slots that existed before, and the genuinely new ones arrive with their defaults.
  #
  # `to_s` before `presence` so a non-String scalar becomes an id the validator can refuse by
  # name rather than an object `normalise_part_id` will call `to_sym` on — a JSON body can carry
  # `{"boiler": 1}`, and `Integer#to_sym` does not exist.
  def resolve(parts)
    return nil if parts.nil?

    DevMatch.outfitting(chassis: chassis).slots.filter_map { |slot|
      key = slot.id.to_s
      [ slot.id, parts[key].to_s.presence ] if parts.key?(key)
    }.to_h
  end
end
