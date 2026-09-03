# frozen_string_literal: true

module Instruments
  # On or off.
  #
  # Built even though the steam engine has no lamp: the panel is data-driven, the loop_rig has
  # one, and a missing kind would take down the whole panel rather than one gauge.
  class LampComponent < BaseComponent
    # Tailwind cannot generate classes from runtime strings, so the mapping has to be explicit
    # in Ruby rather than interpolated into a class attribute.
    COLOURS = { amber: "bg-amber-400", red: "bg-red-500", green: "bg-emerald-400" }.freeze

    def colour_class = COLOURS.fetch(chrome[:colour]&.to_sym, "bg-slate-400")
  end
end
