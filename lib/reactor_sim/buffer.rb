# frozen_string_literal: true

module ReactorSim
  # An edge between two mechanisms: a store with finite capacity and a transport delay.
  #
  # The delay is the whole point. Without it a change at the top of the chain reaches
  # the bottom within one tick and the operation becomes trivially reactive; with it,
  # the overseer is always steering something they cannot see the current state of.
  # See docs/architecture.md §4.
  #
  # Buffers are only ever mutated in the operation's commit phase, after every
  # mechanism has computed against the previous tick's state. That is what makes the
  # tick double-buffered.
  class Buffer
    attr_reader :id, :from, :to, :resource, :capacity, :delay

    def initialize(id:, from:, to:, resource:, capacity:, delay:)
      @id = id
      @from = from
      @to = to
      @resource = resource
      @capacity = capacity.to_f
      @delay = delay
      raise Error, "delay must be >= 0" if delay.negative?
    end

    def initial_state(_rng)
      { contents: 0.0, transit: Array.new(@delay, 0.0), arrived: 0.0, spilled: 0.0 }
    end

    # What the consuming mechanism can draw this tick.
    def available(state) = state.fetch(:contents)

    def commit(state, drawn:, pushed:)
      transit = state.fetch(:transit)

      if @delay.zero?
        arrived = pushed
        new_transit = []
      else
        arrived = transit.fetch(@delay - 1)
        new_transit = [ pushed ] + transit[0, @delay - 1]
      end

      raw = state.fetch(:contents) - drawn + arrived
      spilled = raw > @capacity ? raw - @capacity : 0.0

      {
        contents: raw.clamp(0.0, @capacity),
        transit: new_transit,
        arrived: arrived,
        spilled: spilled
      }
    end
  end
end
