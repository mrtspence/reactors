# frozen_string_literal: true

module ApplicationCable
  # TODO: expedient — no identification at all, so every connection is anonymous and equal.
  # A proper implementation identifies the player here (`identified_by :current_player`) and
  # the channel below uses it to decide which operations they may watch, and as which viewer.
  class Connection < ActionCable::Connection::Base
  end
end
