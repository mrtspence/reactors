# frozen_string_literal: true

module ReactorSim
  # A mounting point on a chassis.
  #
  # A slot answers exactly one question the graph cares about: **when nothing is fitted here,
  # what happens to the wiring?** There are two answers.
  #
  #   when_empty: :omit     the part IS the run, so nothing flows — the fitting's links leave
  #                         with it and the host's port is simply blanked off
  #                         (safety valve, fusible plug, cylinder cocks)
  #   when_empty: :bypass   the run has to survive without the part, so the two ends it sat
  #                         between are joined directly
  #                         (blastpipe, boiler tubes)
  #
  # **An earlier draft classified slots by topology instead — `:core`, `:branch`, `:inline` —
  # and it was wrong twice over.** It named shapes rather than consequences, and it did not
  # even get the shapes right: of the four parts filed under `:branch`, only two terminate. A
  # fusible plug discharges *onto the fire*, which is the entire function of the part, and the
  # condenser runs on to a hotwell and back into the water supply, closing a loop. Renaming it
  # `:terminator` would have made it confidently wrong rather than vaguely unhelpful.
  #
  # `:core` disappeared with it. A boiler slot is just a slot with no `bypass:` whose part
  # contributes holders that other slots' links reference by id — `provides:` is what
  # guarantees those ids exist. Two fewer names, and each remaining one is named after its
  # effect.
  #
  # Note what is NOT here: `:omit` needs no machinery at all. An unfitted part contributes no
  # fragment, so its links leave with it for free. Only `:bypass` needs the slot to know
  # anything about topology, which is why it is the only shape that has to be declared.
  class Slot
    WHEN_EMPTY = %i[omit bypass].freeze

    attr_reader :id, :accepts, :label, :group, :default, :when_empty, :bypass

    # `group:` is presentation, and the only thing here that is. An outfitting screen reads down
    # a machine by system — fire, then water, then steam, then the engine — because that is how
    # somebody thinks about a machine, and alphabetical or graph order would scatter the four
    # fittings on the boiler across the page. Nothing in the simulation reads it.
    def initialize(id:, accepts:, label: nil, group: :other, required: false, default: nil,
                   when_empty: :omit, bypass: nil)
      @id = id.to_sym
      @accepts = accepts.to_sym
      @label = label || @id.to_s.tr("_", " ").capitalize
      @group = group.to_sym
      @required = required
      @default = default&.to_sym
      @when_empty = when_empty.to_sym
      @bypass = normalise_bypass(bypass)

      validate!
      freeze
    end

    def required? = @required

    # The two links this slot makes around a fitted part, given where the part's own run
    # begins and ends. Returns nothing when the slot declares no bypass, because then the
    # part's fragment is carrying its own links.
    def bypass_link
      return nil unless @bypass

      Link.new(from: @bypass.first, to: @bypass.last)
    end

    private

    def normalise_bypass(pair)
      return nil if pair.nil?

      unless pair.is_a?(Array) && pair.length == 2 &&
             pair.all? { |e| e.is_a?(Array) && e.length == 2 }
        raise Error, "slot #{@id}: bypass must be [[node, port], [node, port]], got #{pair.inspect}"
      end

      pair.map { |node, port| [ node.to_sym, port.to_sym ] }.freeze
    end

    def validate!
      unless WHEN_EMPTY.include?(@when_empty)
        raise Error, "slot #{@id}: when_empty must be one of #{WHEN_EMPTY.join(', ')}, " \
                     "got #{@when_empty.inspect}"
      end

      # A required slot cannot be empty, so describing what happens when it is would be a
      # statement that can never be checked — and an unchecked statement in a config file is
      # how a silent off switch gets written. Five of those have already cost this engine real
      # time; see `current_progress.md`.
      if @required && @bypass
        raise Error, "slot #{@id}: a required slot is never empty, so it cannot declare a bypass"
      end

      if @when_empty == :bypass && @bypass.nil?
        raise Error, "slot #{@id}: when_empty: :bypass needs the two ends to join — " \
                     "bypass: [[node, port], [node, port]]"
      end

      return unless @when_empty == :omit && @bypass

      raise Error, "slot #{@id}: bypass: given but when_empty is :omit, so it would never be used"
    end
  end
end
