# frozen_string_literal: true

# The outfitting screen: what the machine is built from, and what else it could be.
#
# This is the eventual player-facing screen rather than a dev harness with a nicer skin, which
# is why the verdict and the warning copy are rendered properly rather than dumped as an array.
# See `docs/design_sketches/modular_components.md` §11.
#
# **It renders configuration only, exactly as the console does.** Nothing here reads simulation
# state — `Assembly` answers every question on this page without building an operation, because
# most of what it shows is about builds nobody has chosen.
class ComponentsController < ApplicationController
  # **GET renders a DRAFT, not just what is fitted.** Changing a dropdown submits this form back
  # to itself into a Turbo frame, so the stats and — more importantly — the *verdict* follow the
  # selection before anything is committed. The verdict is the reason this is a round trip
  # rather than a few lines of JavaScript: only the simulation can say whether a build
  # assembles, and a screen that showed stale warnings while the player edited would be worse
  # than one that showed none.
  def show
    return head :not_found unless addressed_to_dev_match?

    @chassis = DevMatch.chassis
    @assembly = DevMatch.outfitting(loadout: draft_loadout)
    outfit_from_workshop
  end

  # Fit parts, then take it out.
  #
  # The order is deliberate and it is the whole reason this is not two buttons: validate, then
  # store, then produce the reset **carrying the loadout**. A build that cannot assemble never
  # reaches the database, so a runner that later boots cold cannot inherit a machine the
  # validator already refused.
  def fit
    return head :not_found unless addressed_to_dev_match?

    @chassis = DevMatch.chassis
    @assembly = DevMatch.outfitting(loadout: submitted_loadout)

    return render :show, status: :unprocessable_content unless @assembly.verdict.ok?

    Loadout.fit(match_id: DevMatch::ID, operation_id: DevMatch::OPERATION_ID,
                chassis: @chassis, parts: @assembly.loadout)
    CommandProducer.instance.produce(match_id: DevMatch::ID,
                                     command: MatchesController.reset_command)

    redirect_to console_path(match_id: DevMatch::ID, operation_id: DevMatch::OPERATION_ID),
                notice: "Fitted. The engine is being rebuilt — she will be cold."
  rescue StandardError => e
    Rails.logger.error("components: fit failed: #{e.class}: #{e.message}")
    redirect_to components_path(match_id: DevMatch::ID, operation_id: DevMatch::OPERATION_ID),
                alert: "Could not reach the engine room. Nothing was changed."
  end

  private

  def addressed_to_dev_match?
    params[:match_id] == DevMatch::ID && params[:operation_id] == DevMatch::OPERATION_ID.to_s
  end

  # **An unchecked box is an empty slot, not a missing key**, and the distinction is the one
  # `Assembly#resolve_loadout` exists to protect: a slot the form did not mention falls back to
  # its default, so a partial submission would silently refit the parts a player just removed.
  # Every slot on the chassis is therefore named explicitly, with `nil` where nothing is fitted.
  #
  # Values are left as Strings here on purpose — `Assembly` symbolises them, and doing it in two
  # places would mean two places to forget.
  def submitted_loadout
    slots = DevMatch.outfitting.slots
    fitted = permitted_loadout(slots)

    slots.to_h do |slot|
      # `to_s` before `presence` so a non-String scalar becomes a part id the validator can
      # refuse by name rather than an object `Assembly#normalise_part_id` will call `to_sym` on.
      # A JSON body can carry `{"boiler": 1}`, and `Integer#to_sym` does not exist.
      [ slot.id, fitted[slot.id.to_s].to_s.presence ]
    end
  end

  # **`permit` with the slot ids, never `permit!`** — flagged by Brakeman as mass assignment, and
  # it was hiding a second, worse problem.
  #
  # Naming the keys is the obvious half: this method reads nothing but slot ids, so there was
  # never a reason to admit anything else. The half that actually bites is that `permit` also
  # admits only **scalars**. Under `permit!`, `loadout[boiler][]=x` arrives as an Array, reaches
  # `Assembly#normalise_part_id`, and `Array#to_sym` raises — a 500 on the *preview* action,
  # which has no rescue, instead of the "no such part" the validator would have reported.
  #
  # `loadout` is attacker-shaped and may not be a parameter hash at all: `?loadout=x` makes it a
  # String, which does not respond to `permit`. Anything that is not a hash is treated as nothing
  # submitted, which the validator then reports as a stripped machine rather than a crash.
  def permitted_loadout(slots)
    submitted = params[:loadout]
    return {} unless submitted.is_a?(ActionController::Parameters)

    submitted.permit(*slots.map { |slot| slot.id.to_s })
  end

  # `nil` means "nothing submitted, show what is fitted". An empty hash would mean something
  # quite different — every slot explicitly empty — so the two must not be conflated.
  def draft_loadout = params[:loadout] ? submitted_loadout : nil
end
