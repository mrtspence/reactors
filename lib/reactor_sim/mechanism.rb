# frozen_string_literal: true

module ReactorSim
  # Base class for the machinery of an operation.
  #
  # A Mechanism is *configuration and behaviour only* — it holds no mutable state.
  # All state lives in the Operation's state hash and is passed in frozen. This is
  # what makes the double buffer enforceable rather than merely intended: a mechanism
  # physically cannot write to the tick it is reading from.
  #
  # Subclasses implement #initial_state and #step.
  class Mechanism
    # What a mechanism returns from #step. It never applies its own draws and pushes;
    # the Operation commits them once every mechanism has been evaluated.
    Result = Struct.new(:state, :draws, :pushes, :events, keyword_init: true) do
      def initialize(state:, draws: {}, pushes: {}, events: [])
        super
      end
    end

    # Everything a mechanism is allowed to see. Note the absence of a clock: `dt` is
    # simulated seconds, not elapsed real time.
    #
    # `available` is how much each buffer holds; `room` is how much space each has
    # left. Both are read from the previous tick. Exposing `room` is what lets a
    # mechanism feel back-pressure from a downstream buffer that is backing up.
    Context = Struct.new(:controls, :available, :room, :rng, :dt, :tick, keyword_init: true)

    attr_reader :id, :label

    def initialize(id:, label:)
      @id = id
      @label = label
    end

    def initial_state(_rng) = raise NotImplementedError

    def step(_state, _ctx) = raise NotImplementedError

    private

    # Shared incident model: mechanisms accumulate wear deterministically from their
    # operating conditions and fail when it crosses a threshold rolled from the match
    # seed at construction. Deliberately not a per-tick dice roll — see
    # docs/architecture.md §4. The player's uncertainty comes from the threshold being
    # hidden and the gauges being noisy, not from the machine behaving arbitrarily.
    def roll_threshold(rng) = rng.between(0.85, 1.15)

    def failure_event(state, kind, detail = {})
      {
        type: kind,
        mechanism: @id,
        label: @label,
        severity: :critical,
        detail:,
        wear: state.fetch(:wear)
      }
    end
  end
end
