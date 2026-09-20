# **Who is asking, and what they are allowed to touch.**
#
# Every controller used to answer that by comparing a path segment against `DevMatch::ID` — four
# copies of a rule with no owner, and the reason a second operation could not exist. The rule
# lives here now and the model decides it.
#
# See docs/design_sketches/operator_identity.md §4.
class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  private

  # **The single line that becomes a session lookup the day accounts exist.** Nothing outside
  # here may learn that the id is a constant — that has been `DevPlayer`'s stated contract since
  # it was written, and it is what keeps auth a one-file change.
  def current_player = DevPlayer::ID

  # What this request is addressing, or nil. Memoised per request because three filters and a
  # view can all ask.
  def current_operation
    return @current_operation if defined?(@current_operation)

    @current_operation = Operation.locate(params[:match_id], params[:operation_id])
  end

  # **404 for something you cannot see, 403 for something you can see but may not touch.**
  #
  # Not leaking existence is the right default for a machine you have no relationship with. Once
  # spectating lands, a spectator who reaches for a lever should be told *"not yours"* rather
  # than *"no such thing"* — they can see it on their screen, so a 404 would read as a bug.
  def require_viewer!
    head :not_found unless current_operation&.viewable_by?(current_player)
  end

  def require_operator!
    return head :not_found unless current_operation&.viewable_by?(current_player)

    head :forbidden unless current_operation.operable_by?(current_player)
  end

  # **Match-level, for a reset.** Rebuilding a match restarts every operation in it, so the rule
  # is "you operate something here" rather than "you operate this one" — which is the honest
  # answer while a match has one owner and the conservative one when it has several. A match
  # nobody can be found to operate is a 404, for the §2.3 reason.
  def require_match_operator!
    visible = match_operations.select { |op| op.viewable_by?(current_player) }
    return head :not_found if visible.none?

    head :forbidden if visible.none? { |op| op.operable_by?(current_player) }
  end

  def match_operations
    @match_operations ||= Operation.in_match(params[:match_id]).to_a
  end
end
