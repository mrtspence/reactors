# frozen_string_literal: true

module Instruments
  # Words, not numbers.
  #
  # `Displays::Prose#chrome` withholds its phrase list on purpose, and this must not try to
  # recover it. Knowing the vocabulary would tell the player that "hairline cracks showing" is
  # the worst of five — for a gauge that is twelve ticks stale and misreads 15% of the time by
  # design. So: no scale, no ordering, no colour ramp, no severity inferred from position.
  #
  # TODO: if severity styling is ever wanted it must arrive as an explicit field on the chrome
  # from the simulation. Inferring it client-side would reconstruct exactly the information the
  # display exists to withhold.
  class ProseComponent < BaseComponent
  end
end
