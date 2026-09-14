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
    attr_reader :id, :seed, :tick, :operations

    def self.create(id:, seed:, operations:, time_scale: 1.0)
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

      new(id: id, seed: seed, tick: 0, operations: built)
    end

    def initialize(id:, seed:, tick:, operations:)
      @id = id
      @seed = seed
      @tick = tick
      @operations = operations
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

      @operations.flat_map do |operation|
        operation.step!(dt: dt, tick: @tick).map do |event|
          event.merge(tick: @tick, operation_id: operation.id)
        end
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
        operations: @operations.map(&:to_h)
      }
    end

    def self.from_h(hash)
      hash = ReactorSim.deep_symbolize(hash)

      new(
        id: hash.fetch(:id),
        seed: hash.fetch(:seed),
        tick: hash.fetch(:tick),
        operations: hash.fetch(:operations).map { |o| Operation.from_h(o) }
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

    # An unknown type falls through to false and is counted as rejected, which is the same
    # treatment a well-formed command for a missing operation gets. Nothing here may raise.
    def dispatch(command)
      case command.type
      when Command::SET_CONTROL   then apply_set_control(command)
      when Command::ASSIGN_MINION then apply_assign_minion(command)
      else false
      end
    end

    def apply_assign_minion(command)
      found = operation(command.operation_id) if command.operation_id
      return false unless found

      # The destination rides on `control_point_id` rather than a member of its own, because a
      # station IS a control point — a second field would let the two disagree.
      found.assign_minion(command.minion_id, command.control_point_id)
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
