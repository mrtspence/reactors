# frozen_string_literal: true

module ReactorSim
  # One overseer's machine: a graph of nodes joined by links, plus the levers through which
  # a player experiences it.
  #
  # The tick is double-buffered. Every node is evaluated against a frozen snapshot of the
  # previous tick, and nothing is applied until every node has been evaluated. Three
  # consequences, all load-bearing:
  #
  #   * Evaluation order cannot affect the result, so there is no hidden dependence on the
  #     order nodes happen to be listed in — and no topological sort to be undefined.
  #   * **Closed loops just work.** A recirculation loop is a graph where following the
  #     edges returns you to the start; every node still reads N-1, so nothing special
  #     happens and nothing needs to.
  #   * A change at one end of a chain takes one tick per hop to be felt at the other. That
  #     is where delay comes from now. There is no `delay:` parameter anywhere. A hop is one
  #     `Path` — holder to holder — since conduits are resolved through, not stopped at.
  class Operation
    # The per-tick view a node sees. Lives on Tick, aliased here because operations and
    # specs refer to it by the name they already know.
    Context = Tick::Context

    attr_reader :id, :type, :nodes, :links, :paths, :thermal_links, :drive_links,
                :control_points, :diagnostics, :minions, :state, :content, :time_scale,
                :options, :rngs

    def initialize(id:, type:, nodes:, links: [], thermal_links: [], drive_links: [],
                   control_points: [], diagnostics: [], minions: [], seed:, content: nil,
                   time_scale: 1.0, options: {}, state: nil, rngs: nil)
      @id = id.to_sym
      @type = type
      @nodes = nodes.to_h { |n| [ n.id, n ] }.freeze
      @links = links.freeze
      @thermal_links = thermal_links.freeze
      @drive_links = drive_links.freeze
      @control_points = control_points.to_h { |c| [ c.id, c ] }.freeze
      @diagnostics = diagnostics.to_h { |d| [ d.id, d ] }.freeze
      @minions = minions.to_h { |m| [ m.id, m ] }.freeze
      @seed = seed
      @content = content || Content.default
      @time_scale = time_scale.to_f
      # How this operation was configured — which engine variant, which fuel. Snapshotted
      # and handed back to the builder on restore, because rebuilding an atmospheric engine
      # as a high-pressure one would be a silent and total divergence.
      @options = options.to_h { |k, v| [ k.to_sym, v ] }.freeze

      validate_graph!
      # Routes are derived from the graph, which is configuration rather than state, so this
      # is computed once here and never per tick.
      @paths = Path.resolve(nodes: @nodes, links: @links)
      @rngs = rngs || build_rngs(seed)
      @state = state ? restore(state) : build_initial_state
    end

    # --- commands ------------------------------------------------------------

    # Absolute set, clamped, idempotent by construction — which is what makes replaying the
    # command log safe. Commands touch `target` only; the lever's actual position is moved
    # inside the tick (docs/simulation_architecture.md §7).
    def set_control(control_point_id, value)
      cp = @control_points[control_point_id.to_sym]
      return false unless cp

      controls = @state.fetch(:controls)
      @state = @state.merge(
        controls: controls.merge(cp.id => cp.set_target(controls.fetch(cp.id), value).freeze).freeze
      ).freeze
      true
    end

    # Move a minion to a lever. Absolute and idempotent for the same reason `set_control` is —
    # it names the destination, not a direction — so it rides the same at-least-once log.
    #
    # An unknown minion or an unknown station is refused rather than clamped, because there is
    # nothing sane to clamp a station to: unlike a number out of range, a mistyped lever has no
    # nearest valid neighbour.
    def assign_minion(minion_id, station_id)
      minion = @minions[minion_id&.to_sym]
      return false unless minion

      station = station_id&.to_sym
      return false unless station.nil? || @control_points.key?(station)

      minions = @state.fetch(:minions)
      @state = @state.merge(
        minions: minions.merge(minion.id => minion.assign(minions.fetch(minion.id), station).freeze).freeze
      ).freeze
      true
    end

    # --- tick ----------------------------------------------------------------

    # The phases themselves live in Tick, which is where the ordering — the most
    # load-bearing and least obvious part of the engine — can be read in one sitting.
    # The new state is installed atomically, so a half-finished tick is never observable.
    def step!(tick:, dt: nil)
      @state = Tick.new(self, @state).call(tick: tick, dt: dt || (ReactorSim::DT * @time_scale))
      @state.fetch(:events)
    end

    # --- observation ---------------------------------------------------------

    # The projection. Pure: projecting the same tick twice yields the same view, however
    # many viewers there are — see the note in Diagnostic about why that matters.
    def project(viewer: :player, tick: nil)
      diag_states = @state.fetch(:diagnostics)

      gauges = {}
      flags = {}
      @diagnostics.each do |id, diagnostic|
        diag_state = diag_states.fetch(id)
        gauges[id] = viewer == :spectator ? diagnostic.truth(diag_state) : diagnostic.read(diag_state)
        instrument_flags = diagnostic.flags(diag_state)
        flags[id] = instrument_flags unless instrument_flags.empty? || viewer == :spectator
      end

      PlayerView.new(
        tick: tick, operation_id: @id, viewer: viewer,
        gauges: gauges.freeze, flags: flags.freeze,
        controls: @state.fetch(:controls).to_h { |id, s|
          [ id, { target: s.fetch(:target), actual: s.fetch(:actual) } ]
        }.freeze,
        incidents: @state.fetch(:events)
      )
    end

    # Sent once when a client subscribes, so it can draw the panel. Values stream after.
    def panel
      { operation_id: @id,
        instruments: @diagnostics.values.map(&:chrome),
        controls: @control_points.values.map { |c|
          { id: c.id, label: c.label, min: c.min, max: c.max, unit: c.unit }
        } }
    end

    # Raw truth, bypassing the instruments entirely. For specs and the runner's stdout —
    # never for a client, which sees only what #project shows it.
    def telemetry
      @nodes.to_h do |id, node|
        state = @state.fetch(:nodes).fetch(id)
        [ id, { temperature_k: (node.temperature_k(state, @content) if node.respond_to?(:temperature_k)),
                pressure_pa: (node.pressure_pa(state, @content) if node.respond_to?(:pressure_pa)),
                kg: (node.contents_kg(state) if node.respond_to?(:contents_kg)),
                durability: state[:durability],
                failure: state[:failure] }.compact ]
      end
    end

    def broken? = @state.fetch(:nodes).values.any? { |s| s[:failure] }

    def ledger = @state.fetch(:ledger)

    # Everything the operation currently contains. The conservation specs compare these
    # against the ledger; nothing else should need them.
    def total_mass
      @state.fetch(:nodes).values.sum { |s| Parcel.total_kg(s.fetch(:parcels, [])) }
    end

    # Thermal energy, the energy carried by the contents, AND rotational kinetic energy.
    # A spinning flywheel holds real energy, so leaving it out would make the conservation
    # spec read every acceleration as drift.
    def total_joules
      thermal = @state.fetch(:nodes).values.sum do |s|
        s.fetch(:joules, 0.0) + Parcel.total_joules(s.fetch(:parcels, []))
      end

      thermal + @nodes.sum { |id, node|
        node.respond_to?(:omega) ? node.kinetic_joules(@state.fetch(:nodes).fetch(id)) : 0.0
      }
    end

    # --- serialisation -------------------------------------------------------

    # Events are deliberately excluded: they are this tick's *output*, already published to
    # the event log, not durable state.
    def to_h
      { id: @id, type: @type, seed: @seed, time_scale: @time_scale, options: @options,
        state: @state.reject { |k, _| k == :events },
        rngs: @rngs.transform_values(&:state) }
    end

    def self.from_h(hash, registry: ReactorSim::Operations)
      registry.fetch(hash.fetch(:type).to_sym).call(
        id: hash.fetch(:id),
        seed: hash.fetch(:seed),
        time_scale: hash.fetch(:time_scale, 1.0),
        **hash.fetch(:options, {}),
        state: hash.fetch(:state),
        rngs: hash.fetch(:rngs).to_h { |name, s| [ name.to_sym, Rng.new(s) ] }
      )
    end

    private

    # --- phases --------------------------------------------------------------

    # Phase 0. Levers travel toward their targets. All actuation entropy belongs here,
    # inside the tick — never in command application, which would make replay diverge.

    # --- construction --------------------------------------------------------

    def validate_graph!
      # Nodes, levers, instruments and crew share one flat id namespace, because they share
      # one rng table — `build_rngs` keys every stream by component id. A collision hands two
      # components the same stream, which is silent, survives a snapshot, and quietly destroys
      # the order-independence the per-name streams exist to provide.
      #
      # Not hypothetical: the obvious name for a steam engine's fireman is `stoker`, and
      # `:stoker` is already the node that carries fuel to the firebox.
      ids = @nodes.keys + @control_points.keys + @diagnostics.keys + @minions.keys
      duplicates = ids.tally.select { |_, count| count > 1 }.keys
      raise Error, "duplicate component ids: #{duplicates.join(', ')}" if duplicates.any?

      @minions.each_value do |minion|
        station = minion.default_station
        next if station.nil? || @control_points.key?(station)

        raise Error, "minion #{minion.id}: no control point #{station}"
      end

      @links.each do |link|
        source = @nodes[link.from_node] or raise Error, "link #{link.id}: no node #{link.from_node}"
        sink   = @nodes[link.to_node]   or raise Error, "link #{link.id}: no node #{link.to_node}"
        raise Error, "link #{link.id}: #{link.from_port} is not an outlet" unless source.port(link.from_port).outlet?
        raise Error, "link #{link.id}: #{link.to_port} is not an inlet" unless sink.port(link.to_port).inlet?
      end

      # A transport node is resolved *through*, so `Path` has to know which single link
      # continues the route. More than one outlet is ambiguous and no inlet is a dead end;
      # both are caught here rather than surfacing as a confusing walk failure.
      @nodes.each_value do |node|
        next unless node.transport?
        next if node.inlets.length == 1 && node.outlets.length == 1

        raise Error, "transport node #{node.id} needs exactly one inlet and one outlet, " \
                     "has #{node.inlets.length} and #{node.outlets.length}"
      end

      @thermal_links.each do |link|
        [ link.a, link.b ].each do |id|
          raise Error, "thermal link #{link.id}: no node #{id}" unless @nodes.key?(id)
          raise Error, "thermal link #{link.id}: #{id} is not thermal" unless @nodes.fetch(id).respond_to?(:temperature_k)
        end
      end
    end

    # Every node, control point, instrument and minion gets its own named stream, so nothing
    # depends on the order they are evaluated in.
    #
    # Streams are derived from the NAME, never from position, which is why adding a crew to an
    # existing operation perturbs no stream that was already there — and therefore changes no
    # physics. That property is what made it safe to give the steam engine a crew without
    # re-tuning it.
    def build_rngs(seed)
      (@nodes.keys + @control_points.keys + @diagnostics.keys + @minions.keys)
        .to_h { |id| [ id, Rng.stream(seed, "#{@id}/#{id}") ] }
    end

    # A snapshot round-trips through JSON, which stringifies symbol keys — and only keys.
    # Resource ids live in parcels as *values*, so they come back as strings and then fail
    # to match anything, sort against symbols, or route by tag. Normalising them here, at
    # the single entry point for restored state, is what makes restore exact.
    #
    # Events are re-added because they are this tick's output rather than durable state and
    # are excluded from the snapshot; putting the key back beats making every reader defend
    # against its absence.
    def restore(state)
      nodes = state.fetch(:nodes).to_h do |id, node_state|
        restored = node_state
        restored = restored.merge(parcels: Parcel.normalise(restored.fetch(:parcels))) if restored.key?(:parcels)

        # A failure MODE is a symbol living as a value, so JSON hands it back as a string.
        # **Fifth instance of this trap**, and the nastiest yet: `broken?` is truthy either
        # way, so the part stays broken — in a mode nothing matches, with every `case` on it
        # falling to its else branch. A boiler that exploded comes back merely failed.
        restored = restored.merge(failure: restored[:failure]&.to_sym) if restored.key?(:failure)

        [ id, restored.freeze ]
      end

      # Instrument flags are symbols living in an array — values, not keys — so they come
      # back from JSON as strings for exactly the same reason resource ids do.
      diagnostics = state.fetch(:diagnostics, {}).to_h do |id, diag_state|
        [ id, diag_state.merge(flags: diag_state.fetch(:flags, []).map(&:to_sym).freeze).freeze ]
      end

      # `station` is a control point id living as a VALUE, so JSON hands it back as a string.
      # Third instance of this trap, after parcel resource ids and instrument flags — and the
      # quietest of the three: `Tick` would index the crew by "stoking" while looking them up
      # by :stoking, every lookup would miss, and the whole crew would silently stop working.
      #
      # The digest cannot catch it either. `canonical` runs through JSON.generate, where
      # :stoking and "stoking" are the same string, so a round-trip spec passes with the bug
      # present. Only an identity assertion finds it.
      minions = state.fetch(:minions, {}).to_h do |id, minion_state|
        [ id, minion_state.merge(station: minion_state[:station]&.to_sym).freeze ]
      end

      state.merge(nodes: nodes.freeze, diagnostics: diagnostics.freeze,
                  minions: minions.freeze, events: state.fetch(:events, [])).freeze
    end

    def build_initial_state
      { nodes: @nodes.to_h { |id, n| [ id, n.initial_state(@rngs.fetch(id), @content) ] }.freeze,
        controls: @control_points.to_h { |id, c| [ id, c.initial_state(@rngs.fetch(id)).freeze ] }.freeze,
        diagnostics: @diagnostics.to_h { |id, d| [ id, d.initial_state(@rngs.fetch(id)).freeze ] }.freeze,
        minions: @minions.to_h { |id, m| [ id, m.initial_state(@rngs.fetch(id)).freeze ] }.freeze,
        ledger: Ledger.initial.freeze,
        events: [] }.freeze
    end
  end
end
