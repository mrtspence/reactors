# frozen_string_literal: true

module ReactorSim
  # A whole game: every overseer's operation, advanced in lockstep.
  #
  # Match is the unit the runner owns, snapshots, and recovers. It reads no clock —
  # `dt` is simulated seconds handed in by the caller — and draws no entropy except
  # from the seed it was created with. Those two properties are what make
  # `seed + command log => this exact match` true, and everything in
  # docs/architecture.md §6 and §8 rests on it.
  class Match
    attr_reader :id, :seed, :tick, :operations, :couplings

    # A rope between two operations' shafts. Both ends name an operation and a node, so the
    # connection is declared rather than inferred — an operation may have several loads and only
    # one of them is sold.
    #
    #   Coupling.new(from: [ :engine, :load ], to: [ :consumer, :line_shaft ], ratio: 0.78)
    #
    # `ratio` is the `from` end's speed per unit of the `to` end's: the gearing. `stiffness` is the
    # rope's conductance in the `to` end's frame, and defaults to what that end declares.
    Coupling = Struct.new(:from, :to, :ratio, :stiffness, keyword_init: true) do
      def initialize(from:, to:, ratio: 1.0, stiffness: nil)
        super(from: from, to: to, ratio: ratio.to_f, stiffness: stiffness&.to_f)
      end

      def self.parse(raw)
        raw = raw.to_h { |k, v| [ k.to_sym, v ] }
        new(from: pair(raw.fetch(:from)), to: pair(raw.fetch(:to)),
            ratio: raw.fetch(:ratio, 1.0), stiffness: raw[:stiffness])
      end

      # Symbols as values do not survive JSON, and these are four of them.
      def self.pair(value) = Array(value).map(&:to_sym).freeze

      def from_operation = from.first
      def from_node      = from.last
      def to_operation   = to.first
      def to_node        = to.last

      def to_h = { from: from, to: to, ratio: ratio, stiffness: stiffness }.compact
    end

    def self.create(id:, seed:, operations:, couplings: [], time_scale: 1.0)
      built = operations.map do |spec|
        spec = spec.to_h { |k, v| [ k.to_sym, v ] }
        # Anything beyond id and type is passed through to the builder, so an operation
        # can be configured at creation — which variant of an engine, for instance.
        options = spec.reject { |k, _| %i[id type].include?(k) }

        Operations.fetch(spec.fetch(:type)).call(
          id: spec.fetch(:id).to_sym, seed: seed,
          **{ time_scale: time_scale }.merge(options)
        )
      end

      new(id: id, seed: seed, tick: 0, operations: built, couplings: couplings)
    end

    def initialize(id:, seed:, tick:, operations:, couplings: [])
      @id = id
      @seed = seed
      @tick = tick
      @operations = operations
      @couplings = Array(couplings).map { |c| c.is_a?(Coupling) ? c : Coupling.parse(c) }.freeze
      validate_couplings!
    end

    def operation(operation_id)
      @operations.find { |o| o.id == operation_id.to_sym }
    end

    # --- commands -----------------------------------------------------------

    # Applied at the tick barrier, before stepping. Returns a tally rather than
    # raising: the runner wants to log that four commands landed and one was junk,
    # not to have the match die because a client sent nonsense.
    def apply(commands)
      applied = 0
      rejected = []

      Array(commands).each do |raw|
        command = Command.parse(raw)

        if dispatch(command)
          applied += 1
        else
          rejected << command
        end
      end

      { applied: applied, rejected: rejected }
    end

    # --- tick ---------------------------------------------------------------

    # `dt` is simulated seconds. Left unset, each operation advances by its own
    # `time_scale`, so a slow plant and a fast one can share a match without sharing a
    # clock.
    def step!(dt: nil)
      @tick += 1
      exchange!

      @operations.flat_map do |operation|
        operation.step!(dt: dt, tick: @tick).map do |event|
          event.merge(tick: @tick, operation_id: operation.id)
        end
      end
    end

    # Both ends of every rope, at the tick barrier: each end hears the other's speed and clutch,
    # in its own frame, and receives the work the other end took off its shaft.
    #
    # **Every read happens before any write**, so what crosses is taken from the settled previous
    # tick and cannot depend on the order operations are visited in — the same rule a node obeys
    # reading N−1 (`invariants.md` §3). One tick of latency, as at every other hop.
    def exchange!
      return if @couplings.empty?

      moving = @couplings.filter_map do |coupling|
        source = operation(coupling.from_operation)
        sink = operation(coupling.to_operation)
        next unless source && sink

        [ coupling, source.rope_report(coupling.from_node), sink.rope_report(coupling.to_node),
          coupling.stiffness || sink.nodes.fetch(coupling.to_node).rope_conductance ]
      end

      moving.each do |coupling, from, to, conductance|
        ratio = coupling.ratio
        operation(coupling.to_operation)
          .rope_receive(coupling.to_node, omega: from.fetch(:omega) / ratio, grip: from.fetch(:grip),
                                          conductance: conductance, joules: from.fetch(:joules))
        operation(coupling.from_operation)
          .rope_receive(coupling.from_node, omega: to.fetch(:omega) * ratio, grip: to.fetch(:grip),
                                            conductance: conductance / (ratio**2),
                                            joules: to.fetch(:joules))
      end
    end

    # --- observation --------------------------------------------------------

    # What a client is sent. Never raw state: everything here has been through an
    # instrument, so ground truth stays inside the engine.
    def project(operation_id:, viewer: :player)
      find!(operation_id).project(viewer: viewer, tick: @tick)
    end

    # Instrument and lever chrome, sent once on subscribe.
    def panel(operation_id:) = find!(operation_id).panel

    # Raw truth, bypassing the instruments. Specs and the runner's stdout only.
    def telemetry(operation_id:) = find!(operation_id).telemetry

    def total_mass   = @operations.sum(&:total_mass)
    def total_joules = @operations.sum(&:total_joules)

    # --- serialisation ------------------------------------------------------

    def to_h
      {
        id: @id,
        seed: @seed,
        tick: @tick,
        operations: @operations.map(&:to_h),
        couplings: @couplings.map(&:to_h)
      }
    end

    def self.from_h(hash)
      hash = ReactorSim.deep_symbolize(hash)

      new(
        id: hash.fetch(:id),
        seed: hash.fetch(:seed),
        tick: hash.fetch(:tick),
        operations: hash.fetch(:operations).map { |o| Operation.from_h(o) },
        # Absent rather than empty in a snapshot taken before couplings existed.
        couplings: hash.fetch(:couplings, [])
      )
    end

    # Canonical fingerprint of the entire match. Two matches are identical iff their
    # digests are — this is what the determinism spec compares.
    def digest = ReactorSim.canonical(to_h)

    private

    def find!(operation_id)
      operation(operation_id) ||
        raise(Error, "no such operation: #{operation_id.inspect}")
    end

    # **Coupled operations must share a `time_scale`, and this is physics rather than tidiness.**
    #
    # A joule is a joule, but a *rate* is not: at `time_scale` 40 an operation lives 10 simulated
    # seconds per tick while one at 1.0 lives 0.25, so the fast side would need forty times the
    # energy per tick to run the same machines and would be starved 40:1 against a supplier that
    # looks, on its own instruments, to be delivering exactly what it promised.
    #
    # Scaling the transfer to compensate would mint energy. Two operations joined by a rope are
    # in the same world at the same time, so they run on the same clock — which means a coupled
    # consumer runs at its engine's rate, whatever `tick.md` says it might prefer alone.
    def validate_couplings!
      @couplings.each do |coupling|
        source = operation(coupling.from_operation)
        sink = operation(coupling.to_operation)
        next unless source && sink

        validate_rope_ends!(coupling, source, sink)
        next if (source.time_scale - sink.time_scale).abs <= 1e-9

        raise Error, "coupling #{coupling.from_operation} -> #{coupling.to_operation}: " \
                     "time_scale #{source.time_scale} and #{sink.time_scale} differ; " \
                     "coupled operations must share a clock"
      end
    end

    # Both ends must be able to hold a rope, and the rope must have a conductance from somewhere.
    def validate_rope_ends!(coupling, source, sink)
      [ [ source, coupling.from_node ], [ sink, coupling.to_node ] ].each do |op, node_id|
        node = op.nodes[node_id]
        next if node.respond_to?(:hear)

        raise Error, "coupling: #{op.id}.#{node_id} is not something a rope can be tied to"
      end
      raise Error, "coupling: ratio must be positive" unless coupling.ratio.positive?

      sink_end = sink.nodes.fetch(coupling.to_node)
      rope = coupling.stiffness || (sink_end.rope_conductance if sink_end.respond_to?(:rope_conductance))
      raise Error, "coupling: no stiffness, and #{sink.id}.#{coupling.to_node} declares none" if rope.nil?

      validate_rope_stiffness!(coupling, rope, source, sink)
    end

    # **A rope stiffer than an end's `I/dt` rings.** Each end sees the other's speed a tick late,
    # so the gap between them scales by `(I/dt − k)/(I/dt + k)` per tick and changes sign past
    # `k = I/dt`. Measured on an engine roped to a consumer: no reversal at the line shaft's `I/dt`, a
    # reversal every other tick at twice it. Checked against each end's own inertia, which is
    # conservative for an end drive-linked to a heavier wheel.
    def validate_rope_stiffness!(coupling, rope, source, sink)
      [ [ sink, coupling.to_node, rope ], [ source, coupling.from_node, rope / (coupling.ratio**2) ] ]
        .each do |op, node_id, conductance|
          limit = op.nodes.fetch(node_id).moment_of_inertia / (ReactorSim::DT * op.time_scale)
          next if conductance <= limit

          raise Error, "coupling: rope at #{op.id}.#{node_id} is #{conductance.round(1)} N·m·s/rad, " \
                       "past that end's I/dt of #{limit.round(1)} — it would ring"
        end
    end

    # An unknown type falls through to false and is counted as rejected, which is the same
    # treatment a well-formed command for a missing operation gets. Nothing here may raise.
    def dispatch(command)
      case command.type
      when Command::SET_CONTROL   then apply_set_control(command)
      when Command::ASSIGN_MINION then apply_assign_minion(command)
      when Command::DROP_MINION   then apply_drop_minion(command)
      else false
      end
    end

    def apply_assign_minion(command)
      found = operation(command.operation_id) if command.operation_id
      return false unless found

      # The destination rides on `control_point_id` rather than a member of its own, because a
      # station IS a control point — a second field would let the two disagree. **It may also name
      # a person**, which is a fetch order; the id spaces cannot collide, so one field still
      # cannot be ambiguous. Renaming it would make every command already in the log unparseable.
      found.assign_minion(command.minion_id, command.control_point_id)
    end

    # **Names the person being put down, not whoever is holding them.** That is what makes it
    # per-person and what makes it commutative under an at-least-once, unordered log.
    def apply_drop_minion(command)
      found = operation(command.operation_id) if command.operation_id
      return false unless found

      found.drop_minion(command.minion_id)
    end

    def apply_set_control(command)
      # A value that could not be read as a number is rejected here rather than clamped to
      # something plausible. Command.parse hands back nil for anything non-numeric, and
      # guessing what the sender meant is worse than counting the command as malformed —
      # which is what the caller already reports.
      return false if command.value.nil?

      found = operation(command.operation_id) if command.operation_id
      return false unless found

      found.set_control(command.control_point_id, command.value)
    end
  end
end
