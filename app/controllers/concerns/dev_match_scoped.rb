# frozen_string_literal: true

# There is exactly one match and one operation, so every controller under `/matches/:match_id`
# has to refuse anything else. A `before_action` rather than a guard clause in each action, so an
# action added later cannot forget it.
#
# TODO: expedient — this is the shape authorisation will take when there are real matches and
# real players: `before_action :require_dev_match` becomes a policy check on a found record. It is
# a filter today because there is nothing to find.
module DevMatchScoped
  extend ActiveSupport::Concern

  private

  def require_dev_match
    head :not_found unless params[:match_id] == DevMatch::ID
  end

  def require_dev_operation
    head :not_found unless params[:match_id] == DevMatch::ID &&
                           params[:operation_id] == DevMatch::OPERATION_ID.to_s
  end
end
