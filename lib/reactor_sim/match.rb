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

    def self.create(id:, seed:, operations:)
      built = operations.map do |spec|
        spec = spec.to_h { |k, v| [ k.to_sym, v ] }
        Operations.fetch(spec.fetch(:type)).call(id: spec.fetch(:id).to_sym, seed: seed)
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

        if command.type == Command::SET_CONTROL && apply_set_control(command)
          applied += 1
        else
          rejected << command
        end
      end

      { applied: applied, rejected: rejected }
    end

    # --- tick ---------------------------------------------------------------

    def step!(dt: ReactorSim::DT)
      @tick += 1

      @operations.flat_map do |operation|
        operation.step!(dt: dt, tick: @tick).map do |event|
          event.merge(tick: @tick, operation_id: operation.id)
        end
      end
    end

    # --- projection ---------------------------------------------------------

    def project(operation_id:, viewer: :player)
      found = operation(operation_id)
      raise Error, "no such operation: #{operation_id.inspect}" unless found

      found.project(viewer: viewer, tick: @tick)
    end

    def total_power = @operations.sum(&:power)

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

    def apply_set_control(command)
      found = operation(command.operation_id) if command.operation_id
      return false unless found

      found.set_control(command.control_point_id, command.value)
    end
  end
end
