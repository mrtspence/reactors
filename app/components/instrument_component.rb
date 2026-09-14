# frozen_string_literal: true

# Picks the right instrument for a piece of chrome.
#
# A collection plus a dispatcher rather than slots: `panel[:instruments]` is a flat list of
# data, and slots are for a caller composing named regions, which is not what is happening.
class InstrumentComponent < ViewComponent::Base
  KINDS = {
    needle: Instruments::NeedleComponent,
    digital: Instruments::DigitalComponent,
    prose: Instruments::ProseComponent,
    lamp: Instruments::LampComponent
  }.freeze

  # `with_collection` would otherwise pass each element as `instrument:`, derived from the
  # class name. The argument is a chrome hash, so it is named for what it is.
  with_collection_parameter :chrome

  def initialize(chrome:)
    @chrome = chrome
    super()
  end

  # Raising on an unknown kind is correct. A gauge silently vanishing from a control panel is
  # the worst failure this page has — the player would be flying without an instrument and
  # would have no way to know it.
  def call
    kind = @chrome[:kind]&.to_sym
    component = KINDS.fetch(kind) do
      raise ArgumentError, "no instrument for #{kind.inspect} (have #{KINDS.keys.join(', ')})"
    end

    render component.new(chrome: @chrome)
  end
end
