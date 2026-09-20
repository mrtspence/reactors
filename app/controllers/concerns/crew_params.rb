# frozen_string_literal: true

# Reading a submitted roster out of `params`, safely.
#
# `CrewParams` is `LoadoutParams` for people, and it makes the same two refusals. **Never
# `permit!`** — the shapes that admits (an Array, a Hash, a bare String where a scalar was
# expected) each reached `String#to_sym` and 500'd the draft action, which has no rescue.
module CrewParams
  extend ActiveSupport::Concern

  private

  # `{ seat_id => { minion:, training: [], tool:, gear:, utility: } }`, and every id is a scalar
  # except `training`, which is genuinely a list.
  def submitted_crew
    submitted = params[:crew]
    return {} unless submitted.is_a?(ActionController::Parameters)

    Crewing.seat_ids(operation_id: current_operation.operation_id)
           .to_h { |seat| [ seat.to_sym, posting_for(submitted[seat]) ] }
  end

  def posting_for(given)
    return {} unless given.is_a?(ActionController::Parameters)

    permitted = given.permit(:minion, *ReactorSim::Equipment::SLOTS, training: []).to_h

    # `compact_blank` rather than `compact`: an unselected `<select>` submits an empty string,
    # and "" is not nil. Left in, it would reach `to_sym` and become `:""` — a posting for
    # somebody with no name, which resolves to nobody and is not the same as an empty slot.
    permitted.compact_blank
  end
end
