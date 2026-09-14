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
    fitted = params.fetch(:loadout, {}).permit!.to_h

    DevMatch.outfitting.slots.to_h do |slot|
      chosen = fitted[slot.id.to_s]
      [ slot.id, chosen.presence ]
    end
  end

  # `nil` means "nothing submitted, show what is fitted". An empty hash would mean something
  # quite different — every slot explicitly empty — so the two must not be conflated.
  def draft_loadout = params[:loadout] ? submitted_loadout : nil
end
