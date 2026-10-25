# frozen_string_literal: true

module ReactorSim
  # **What a machine built more than once calls its pieces, and where they stand.** Ids are one
  # flat namespace per operation, so the second shovel in a pit must name everything it builds
  # differently from the first: `names.(:boiler)` is `:boiler` on the steam engine and
  # `:shovel_1_boiler` on the first shovel. `place` is the room its levers stand in.
  #
  # Build-time only, like the assembly that hands it out.
  class Names
    attr_reader :prefix, :place

    def initialize(prefix = nil, place:)
      @prefix = prefix&.to_sym
      @place = place.to_sym
      freeze
    end

    def call(id) = @prefix ? :"#{@prefix}_#{id}" : id.to_sym
  end
end
