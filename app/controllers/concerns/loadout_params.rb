# frozen_string_literal: true

# Reading a submitted loadout off the wire. Shared by the two controllers that accept one —
# fitting a loadout and drafting one — because permitting is the one piece of real work a
# controller is allowed to keep, and doing it twice would mean two places to get it wrong.
module LoadoutParams
  extend ActiveSupport::Concern

  private

  # **`permit` with the slot ids, never `permit!`.** Brakeman flags the latter as mass
  # assignment, and it was hiding a second, worse problem: `permit` also admits only *scalars*.
  # Under `permit!`, `loadout[boiler][]=x` arrived as an Array and reached
  # `Assembly#normalise_part_id`, where `Array#to_sym` raises — a 500 on the draft action, which
  # has no rescue, instead of the "no such part" the validator exists to report.
  #
  # `loadout` may not be a parameter hash at all: `?loadout=x` makes it a String, which does not
  # respond to `permit`. Anything that is not a hash is treated as an empty submission, which
  # comes back as a stripped machine the validator refuses rather than as a crash.
  def submitted_parts
    submitted = params[:loadout]
    return {} unless submitted.is_a?(ActionController::Parameters)

    # Against the **submitted** chassis, not the stored one. They differ for exactly one request —
    # the one where a player changes frame — and permitting against the old chassis would drop
    # the slots only the new one has.
    submitted.permit(*Outfitting.slot_ids(submitted_chassis)).to_h
  end

  # A bare scalar, so `permit` is not involved; anything that is not a String is nothing
  # submitted, and `Outfitting` falls back to the stored frame rather than raising on it.
  def submitted_chassis
    value = params[:chassis]
    value.is_a?(String) ? value : nil
  end
end
