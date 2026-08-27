# frozen_string_literal: true

module ReactorSim
  # An instrument: somewhere to read from, a chain of distortions, and a way to show it.
  #
  #   Source  ->  Filters  ->  Display
  #
  # The base class does almost nothing on purpose. In v0 it carried lag, noise, history and
  # clamping for *every* instrument, so an indicator lamp inherited machinery it could never
  # use, and `pegged?` existed with no way to reach the player. Here the class enforces a
  # shape and the behaviour lives in composable pieces.
  #
  #   Diagnostic.new(
  #     id:      :vessel_temp,
  #     source:  Sources::Derived.new(:boiler, :temperature_k),
  #     filters: [ Filters::Lag.new(2), Filters::Noise.new(1.5), Filters::Range.new(273, 873) ],
  #     display: Displays::Needle.new(unit: "°C", convert: :k_to_c)
  #   )
  #
  # The critical property is that **recording and reading are separate**. `record` runs once
  # per tick and is the only thing allowed to draw entropy; `read` is a pure lookup. A tick
  # may be projected any number of times — player, spectator, a resync of either — and if
  # reading drew noise, how many people happened to be watching would change the match.
  class Diagnostic
    attr_reader :id, :label, :source, :filters, :display, :observer

    def initialize(id:, source:, filters: [], display: nil, label: nil, observer: nil)
      @id = id.to_sym
      @label = label || @id.to_s.tr("_", " ").capitalize
      @source = source
      @filters = filters.freeze
      @display = display || Displays::Needle.new
      # Reserved for minions: whoever is watching this instrument will drive the parameters
      # of the filters above (docs/simulation_architecture.md §7). Carried now so the seam
      # exists before there is anything to put in it.
      @observer = observer&.to_sym
      freeze
    end

    def initial_state(rng)
      { filters: @filters.map { |f| f.initial_state(rng).freeze }.freeze,
        # A second, parallel chain carrying the undistorted value — see #record.
        truth_filters: @filters.map { |f| f.initial_state(rng).freeze }.freeze,
        truth: nil, value: nil, flags: [].freeze, available: false }
    end

    # Phase 7. Sample the source and run the chain — twice.
    #
    # The player's pass runs every filter. The spectator's pass runs only the ones that
    # change what the number *means* (a rate, a band) and skips the ones that merely make
    # it worse (lag, noise, clamping). Simply reporting the raw sample as "truth" was wrong:
    # a rate instrument then showed a temperature of 300 in a box labelled K/s.
    #
    # Both chains need their own state because a stateful transform sees different inputs
    # on each — the rate of a noisy signal is not the noisy rate. The undistorted pass is
    # cheap and, crucially, draws NO entropy, because only distorting filters ever do.
    #
    # This is also the only method here allowed to draw at all. Reading is a pure lookup.
    def record(state, nodes, states, ctx, rng)
      reading = @source.sample(nodes, states, ctx.content)
      unless reading.available
        return state.merge(truth: nil, value: nil, flags: [ :offline ].freeze, available: false)
      end

      filters, value, flags = run_chain(state.fetch(:filters), reading.value, rng, ctx,
                                        distortions: true)
      truth_filters, truth, = run_chain(state.fetch(:truth_filters), reading.value, nil, ctx,
                                        distortions: false)

      { filters: filters, truth_filters: truth_filters, truth: truth, value: value,
        flags: flags, available: true }
    end

    # Pure. What the player sees — distorted, delayed, occasionally wrong.
    def read(state)
      return nil unless state.fetch(:available)

      @display.render(state.fetch(:value), state.fetch(:flags))
    end

    # Pure. What a spectator sees: the number itself, undelayed and undistorted, but still
    # routed through the display rather than escaping as raw state. Keeps the door open for
    # a shadow-a-player spectator mode without reworking the path.
    def truth(state)
      return nil unless state.fetch(:available)

      @display.render(state.fetch(:truth), [].freeze)
    end

    def flags(state) = state.fetch(:flags)

    # Sent once on subscribe so the client can draw the instrument; values stream after.
    def chrome = @display.chrome.merge(id: @id, label: @label)

    private

    # Returns [filter_states, value, flags]. A skipped filter keeps its state untouched.
    def run_chain(filter_states, value, rng, ctx, distortions:)
      flags = []

      next_states = @filters.each_with_index.map do |filter, index|
        current = filter_states.fetch(index)
        next current if !distortions && filter.distortion?

        result = filter.apply(current, value, rng, ctx)
        value = result.value
        flags.concat(result.flags) if distortions
        result.state.freeze
      end

      [ next_states.freeze, value, flags.freeze ]
    end
  end
end
