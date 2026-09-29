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

    # Which severities reach the player's incident feed. See `#incidents`.
    REPORTED_SEVERITIES = %i[warning critical].freeze

    attr_reader :id, :type, :nodes, :links, :paths, :thermal_links, :drive_links, :layout,
                :control_points, :diagnostics, :minions, :state, :content, :time_scale,
                :options, :rngs, :routing

    def initialize(id:, type:, nodes:, links: [], thermal_links: [], drive_links: [],
                   passages: [], places: [], control_points: [], diagnostics: [], minions: [],
                   seed:, content: nil, time_scale: 1.0, options: {}, state: nil, rngs: nil)
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

      # Where everything is, and who can get between any two of them. Configuration, like the
      # paths below — the routing tables are built here so nothing searches a graph in a tick.
      @layout = Layout.new(passages: passages, control_points: control_points,
                           places: places, nodes: @nodes)
      @routing = build_routing

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
    # **An unreachable station is refused, not attempted.** Where there is geometry a posting can
    # be impossible for *this* minion — a narrow crawl they cannot fit through, a ladderway they
    # cannot climb — and walking them into a wall for the rest of the match is worse than saying
    # no. Reachability is per-minion because the gates are.
    def assign_minion(minion_id, station_id)
      minion = @minions[minion_id&.to_sym]
      return false unless minion

      station = station_id&.to_sym
      return false unless station.nil? || @control_points.key?(station)

      minions = @state.fetch(:minions)
      current = minions.fetch(minion.id)
      return false unless can_reach?(minion, current, station)

      assigned = minion.assign(current, station, arrived: standing_at?(minion, current, station))
      @state = @state.merge(minions: minions.merge(minion.id => assigned.freeze).freeze).freeze
      true
    end

    # Is this minion already standing where that posting is worked? Always true without geometry,
    # and true for a control that declares no `place:` — a lever nobody has placed can be worked
    # from wherever they happen to be.
    def standing_at?(minion, state, station)
      return true unless @layout.spatial?

      destination = @layout.place_of(station)
      destination.nil? || destination == minion.place(state)
    end

    def can_reach?(minion, state, station)
      return true unless @layout.spatial?

      destination = @layout.place_of(station)
      return true if destination.nil?

      @layout.reachable?(minion.place(state), destination, @routing.fetch(minion.id, []))
    end

    # Which gated passages each minion may use, decided once from tags that cannot change during
    # a match. `Layout` memoises a routing table per distinct set, so a shift that shares a
    # capability shares a table.
    def build_routing
      gates = @layout.passages.filter_map(&:requires).uniq.freeze
      routing = @minions.transform_values { |m| m.capabilities(gates) }.freeze
      @layout.precompute!(routing.values.uniq)
      routing
    end

    # --- coupling ------------------------------------------------------------
    #
    # Two operations meet here and nowhere else. Both sides are applied at the match's tick
    # barrier, outside any tick, exactly as a command is — so neither can observe the other
    # mid-tick and phase order is untouched.

    # What a `Load` delivered on the tick just finished, ready to be handed to whoever is
    # coupled to it. Already booked to this operation's `joules_to_work`, so reading it moves
    # nothing and double-counts nothing — the exchange is only deciding where it lands next.
    def exported_joules(node_id)
      @state.fetch(:nodes).dig(node_id.to_sym, :joules_extracted).to_f
    end

    # Work arriving from another operation, into the buffer an `Import` shaft spends from.
    # Ledgered on entry, because from this operation's point of view it is energy appearing
    # from outside — the mirror of the `joules_to_work` the other side already paid out.
    def receive_supply(node_id, joules)
      node = @nodes[node_id.to_sym]
      return false unless node.respond_to?(:receive)
      return true if joules.zero?

      nodes = @state.fetch(:nodes)
      received, wasted = node.receive(nodes.fetch(node.id), joules)

      # Booked in full on arrival and the overflow booked straight back out as friction, rather
      # than never booking the overflow at all: it has already left the supplier as
      # `joules_to_work`, so anything this operation declines to count is energy destroyed
      # between two sets of books that each look correct.
      @state = @state.merge(
        nodes: nodes.merge(node.id => received.freeze).freeze,
        ledger: Ledger.add(@state.fetch(:ledger),
                           joules_imported: joules, joules_to_friction: wasted).freeze
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
        incidents: incidents,
        crew: crew_view
      )
    end

    # Where each of the crew is standing, and what has happened to them.
    #
    # **This closes a seam that was dead and was lying about it.** `CrewComponent` renders a
    # station dropdown per minion and its own comment claimed the posting "arrives on the
    # projection" — it did not, so the control always rendered at its first option whatever the
    # real posting was, and a reassignment, a reset or a restore was never reflected back.
    #
    # Only what CHANGES belongs here. A minion's name, job and race are configuration and reach
    # the client once, with the panel; station and injury are state.
    # `posting` rather than `station` is what the crew screen's control binds to: a minion walking
    # to the far face has been *sent* there, and snapping their dropdown back to blank for the
    # three minutes it takes would read as the order having been lost. `station` rides along
    # beside it so the panel can show that they are not there yet.
    def crew_view
      @state.fetch(:minions).to_h do |id, minion_state|
        # `asphyxia` is a rescue timer, not a status: somebody down in bad air is being lost at
        # a rate the player can still do something about, and a bar is the only way to say so.
        #
        # `travel` is the same argument for a walk that takes minutes: "sent to the far face" is
        # not a state a player should have to take on trust for five minutes, so how far along
        # they are goes on the projection beside where they have got to.
        [ id, { station: minion_state[:station], posting: minion_state[:posting],
                place: minion_state[:place], injury: minion_state[:injury],
                fatigue: minion_state[:fatigue], asphyxia: minion_state[:asphyxia],
                travel: @minions[id]&.journey_fraction(minion_state) || 0.0,
                remaining_m: minion_state[:remaining] } ]
      end.freeze
    end

    # **The feed is curated; the log is complete.** Every event this tick goes to the durable
    # record, but the panel's incident list is "what has gone wrong" — putting `fire_lit` and
    # `steam_raised` in it would bury a burst flywheel under the ordinary business of driving an
    # engine. Filtered here rather than in the client, so the client stays dumb and a second
    # consumer of the projection cannot forget to do it.
    def incidents
      @state.fetch(:events).select { |e| REPORTED_SEVERITIES.include?(e[:severity]) }.freeze
    end

    # Sent once when a client subscribes, so it can draw the panel. Values stream after.
    def panel
      # **`controls` is what a player can move; `stations` is where a person can stand.** They
      # were one list until the crew quarters, which is a posting with nothing to set — rendering
      # it as a lever puts a slider on the panel that does nothing, and leaving it out of
      # `stations` makes the one place crew start unreachable from the crew screen.
      { operation_id: @id,
        instruments: @diagnostics.values.map(&:chrome),
        controls: @control_points.values.select(&:lever?).map { |c|
          { id: c.id, label: c.label, min: c.min, max: c.max, unit: c.unit }
        },
        stations: @control_points.values.map { |c| { id: c.id, label: c.label } },
        # **Empty for an operation with no geometry**, which is what makes the panel's "where
        # are they" line nil-accepting rather than a mine-only feature: the steam engine ships
        # no places and the client renders nothing.
        places: @layout.places.filter_map { |id|
          place = @layout.place(id)
          { id: id, label: place.label } if place
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
      # `supply_joules` is imported work this operation is holding but has not yet spent. It is
      # energy in hand exactly as a parcel's enthalpy is, so it is counted here — leave it out
      # and an exchange reads as creation on one side and destruction on the other.
      thermal = @state.fetch(:nodes).values.sum do |s|
        s.fetch(:joules, 0.0) + s.fetch(:supply_joules, 0.0) +
          Parcel.total_joules(s.fetch(:parcels, []))
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
      # `injury` is the same trap as `station` one field along, and nastier in the same way a
      # node's `failure` mode is: a String is truthy, so the minion stays hurt — in a mode
      # nothing matches, with every derating falling back to 1.0. A crew that came back from a
      # snapshot would be quietly, completely healed while still reading as injured.
      # `posting` and `place` are the same trap again, one and two fields along — a posting that
      # comes back as a String never matches the station it names, so the whole shift is
      # permanently walking toward somewhere that does not exist.
      minions = state.fetch(:minions, {}).to_h do |id, minion_state|
        [ id, minion_state.merge(station: minion_state[:station]&.to_sym,
                                 posting: minion_state[:posting]&.to_sym,
                                 place: minion_state[:place]&.to_sym,
                                 injury: minion_state[:injury]&.to_sym).freeze ]
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
