# frozen_string_literal: true

module ReactorSim
  # One overseer's machine: a chain of mechanisms joined by delayed buffers, plus the
  # levers and gauges through which a player experiences it.
  #
  # The tick here is double-buffered. Every mechanism is evaluated against a frozen
  # snapshot of the previous tick and returns its next state along with the draws and
  # pushes it *wants*; nothing is applied until every mechanism has been evaluated.
  # Two consequences worth stating plainly:
  #
  #   * Evaluation order cannot affect the result, so the chain has no hidden
  #     dependence on the order mechanisms happen to be listed in.
  #   * A change at the top of the chain takes several ticks to be felt at the bottom,
  #     which is the whole source of tension in overseeing one of these.
  class Operation
    attr_reader :id, :type, :mechanisms, :buffers, :control_points, :diagnostics, :state

    def initialize(id:, type:, mechanisms:, buffers:, control_points:, diagnostics:,
                   power_source:, seed:, state: nil, rngs: nil)
      @id = id
      @type = type
      @mechanisms = mechanisms
      @buffers = buffers
      @control_points = control_points
      @diagnostics = diagnostics
      @power_source = power_source # [mechanism_id, field]
      @seed = seed

      @rngs = rngs || build_rngs(seed)
      # A restored state carries no events (see #to_h), so put the key back rather
      # than making every reader defend against its absence.
      @state = state ? state.merge(events: state.fetch(:events, [])).freeze : build_initial_state
    end

    # --- commands -----------------------------------------------------------

    # Absolute set, clamped. Idempotent by construction, which is what makes replaying
    # the command log safe (docs/architecture.md §6).
    def set_control(control_point_id, value)
      cp = @control_points.find { |c| c.id == control_point_id }
      return false unless cp

      controls = @state.fetch(:controls).merge(
        cp.id => cp.set(@state.fetch(:controls).fetch(cp.id), value)
      )
      @state = @state.merge(controls: controls).freeze
      true
    end

    # --- tick ---------------------------------------------------------------

    def step!(dt:, tick:)
      read_mechanisms = @state.fetch(:mechanisms)
      read_buffers    = @state.fetch(:buffers)

      controls  = control_values
      available = @buffers.to_h { |b| [ b.id, b.available(read_buffers.fetch(b.id)) ] }.freeze
      room      = @buffers.to_h { |b| [ b.id, b.capacity - b.available(read_buffers.fetch(b.id)) ] }.freeze

      results = @mechanisms.map do |mechanism|
        ctx = Mechanism::Context.new(
          controls: controls, available: available, room: room,
          rng: @rngs.fetch(mechanism.id), dt: dt, tick: tick
        )
        [ mechanism, mechanism.step(read_mechanisms.fetch(mechanism.id), ctx) ]
      end

      next_mechanisms = results.to_h { |m, r| [ m.id, r.state.freeze ] }.freeze
      next_buffers    = commit_buffers(read_buffers, results)
      next_diagnostics = record_diagnostics(next_mechanisms)
      events = results.flat_map { |_m, r| r.events }

      @state = {
        mechanisms: next_mechanisms,
        buffers: next_buffers,
        controls: @state.fetch(:controls),
        diagnostics: next_diagnostics,
        events:
      }.freeze

      events
    end

    # --- projection ---------------------------------------------------------

    # Pure: projecting the same tick twice yields the same view, however many viewers
    # there are. See the note in Diagnostic.
    def project(viewer:, tick:)
      diag_state = @state.fetch(:diagnostics)

      gauges = @diagnostics.to_h do |d|
        state = diag_state.fetch(d.id)
        [ d.id, viewer == :spectator ? d.truth(state) : d.reading(state) ]
      end

      PlayerView.new(
        tick:,
        operation_id: @id,
        viewer:,
        gauges:,
        controls: control_values,
        incidents: @state.fetch(:events),
        power:
      )
    end

    def power
      mechanism_id, field = @power_source
      @state.fetch(:mechanisms).fetch(mechanism_id).fetch(field)
    end

    def failed? = @state.fetch(:mechanisms).values.any? { |s| s[:failed] }

    # --- serialisation ------------------------------------------------------

    # Events are deliberately excluded: they are this tick's *output*, already
    # published to the event log, not durable state. Leaving them out keeps a snapshot
    # to a bag of numbers and avoids round-tripping event symbols through JSON.
    def to_h
      {
        id: @id,
        type: @type,
        seed: @seed,
        state: @state.reject { |k, _| k == :events },
        rngs: @rngs.transform_values(&:state)
      }
    end

    def self.from_h(hash, registry: ReactorSim::Operations)
      builder = registry.fetch(hash.fetch(:type))
      builder.call(
        id: hash.fetch(:id),
        seed: hash.fetch(:seed),
        state: hash.fetch(:state),
        rngs: hash.fetch(:rngs).to_h { |name, s| [ name, Rng.new(s) ] }
      )
    end

    private

    def control_values
      @control_points.to_h { |cp| [ cp.id, cp.value(@state.fetch(:controls).fetch(cp.id)) ] }.freeze
    end

    def commit_buffers(read_buffers, results)
      drawn  = Hash.new(0.0)
      pushed = Hash.new(0.0)

      results.each do |_mechanism, result|
        result.draws.each  { |id, amount| drawn[id]  += amount }
        result.pushes.each { |id, amount| pushed[id] += amount }
      end

      @buffers.to_h do |buffer|
        next_state = buffer.commit(
          read_buffers.fetch(buffer.id),
          drawn: drawn[buffer.id], pushed: pushed[buffer.id]
        )
        [ buffer.id, next_state.freeze ]
      end.freeze
    end

    def record_diagnostics(next_mechanisms)
      current = @state.fetch(:diagnostics)

      @diagnostics.to_h do |d|
        truth = next_mechanisms.fetch(d.mechanism).fetch(d.field)
        [ d.id, d.record(current.fetch(d.id), truth, @rngs.fetch(d.id)).freeze ]
      end.freeze
    end

    # Every mechanism and diagnostic gets its own named stream, so nothing depends on
    # the order they are evaluated in.
    def build_rngs(seed)
      (@mechanisms + @diagnostics).to_h { |c| [ c.id, Rng.stream(seed, "#{@id}/#{c.id}") ] }
    end

    def build_initial_state
      {
        mechanisms:  @mechanisms.to_h    { |m| [ m.id, m.initial_state(@rngs.fetch(m.id)).freeze ] }.freeze,
        buffers:     @buffers.to_h       { |b| [ b.id, b.initial_state(nil).freeze ] }.freeze,
        controls:    @control_points.to_h { |c| [ c.id, c.initial_state(nil).freeze ] }.freeze,
        diagnostics: @diagnostics.to_h   { |d| [ d.id, d.initial_state(nil).freeze ] }.freeze,
        events: []
      }.freeze
    end
  end
end
