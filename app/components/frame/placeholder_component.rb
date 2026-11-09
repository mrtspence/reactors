# frozen_string_literal: true

class Frame
  # **Room kept for a region not built yet**, labelled, so the layout can be judged by looking at
  # it. Each names what fills it (`docs/reference/layout.md`).
  class PlaceholderComponent < ViewComponent::Base
    # TODO: the minimap and each place's schematic are not scheduled (the UI overhaul, §2).
    REGIONS = {
      minimap: [ "The works", "a schematic, to pick a place from — not yet built" ],
      schematic: [ "This place", "a schematic of it — not yet built" ]
    }.freeze

    def initialize(region:)
      @title, @note = REGIONS.fetch(region)
      @region = region
      super()
    end

    def call
      tag.section(class: "frame-placeholder frame-placeholder-#{@region}", aria: { label: @title }) do
        safe_join([ tag.h2(@title, class: "text-[11px] uppercase tracking-wide text-slate-500"),
                    tag.p(@note, class: "text-xs text-slate-600 italic") ])
      end
    end
  end
end
