# frozen_string_literal: true

module ApplicationHelper
  # **Tailwind cannot build a class from a runtime string.** It scans source text for literals,
  # so `"text-#{colour}-400"` produces a class that is never generated and silently renders
  # unstyled. Every mapping from a simulation symbol to a class therefore lives here, spelled
  # out — the same rule `LampComponent::COLOURS` follows.
  SLOT_GROUPS = {
    fire: { label: "Fire and draught",
            blurb: "What burns, what feeds it, and what pulls the air through.",
            accent: "text-amber-300", rule: "border-amber-900/60" },
    water: { label: "Water and steam raising",
             blurb: "The drum, what fills it, and what stands between it and you.",
             accent: "text-sky-300", rule: "border-sky-900/60" },
    steam: { label: "Steam to the engine",
             blurb: "Where the regulator meets the valve gear.",
             accent: "text-teal-300", rule: "border-teal-900/60" },
    engine: { label: "The engine itself",
              blurb: "What turns, what it drives, and what vents when it goes wrong.",
              accent: "text-violet-300", rule: "border-violet-900/60" },
    other: { label: "Other", blurb: "", accent: "text-slate-300", rule: "border-slate-800" }
  }.freeze

  def slot_group(group) = SLOT_GROUPS.fetch(group, SLOT_GROUPS.fetch(:other))

  # Part stats are a display hash and nothing in the simulation reads them, so they can be
  # anything a part author found worth saying. Render them without pretending to know more.
  def part_stat(value)
    case value
    when Float then format("%g", value)
    when true then "yes"
    when false then "no"
    else value.to_s
    end
  end
end
