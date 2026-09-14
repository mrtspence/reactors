# frozen_string_literal: true

module ReactorSim
  # Slots plus a loadout, resolved into the flat lists an `Operation` is built from.
  #
  # **This runs once, at build, and leaves no trace in the tick.** After `#fragment` the
  # operation holds the same `nodes:`/`links:`/`control_points:`/`diagnostics:` arrays it has
  # always held; nothing here is reachable from `Tick`, `Arbiter` or any node, and no
  # `Context` method takes a slot id. A node that needed to ask "what is fitted over there"
  # would be putting assembly structure on the hot path and weakening the double buffer's
  # guarantees for a lookup that could have been decided at build. See
  # `operations/CLAUDE.md`.
  #
  # ## Two verdicts, not two severities
  #
  # `errors` refuse the build. `warnings` do not, and the difference is the game's whole
  # risk/reward axis: an engine with no fusible plug is a legal thing to build, and the hazard
  # sitting underneath the safety is what makes going without one a decision rather than a
  # strictly-worse choice. A validator that refused it would be deleting the mechanic in order
  # to be helpful. See `docs/design_sketches/modular_components.md` §7.
  class Assembly
    Verdict = Struct.new(:errors, :warnings) do
      def ok? = errors.empty?
      def to_s = (errors.map { |e| "error: #{e}" } + warnings.map { |w| "warning: #{w}" }).join("\n")
    end

    attr_reader :slots, :loadout

    def initialize(slots:, loadout: {}, spec: {}, fixtures: Fragment.empty,
                   instruments: {}, routes: [], advisories: [], registry: Parts)
      @slots = slots.freeze
      @spec = spec
      @fixtures = fixtures
      # Insertion-ordered, and that order is the panel's order. Selecting from it rather than
      # concatenating per part is what keeps the gauge layout stable however the slots are
      # arranged.
      @instruments = instruments
      @routes = routes.freeze
      @advisories = advisories.freeze
      @registry = registry
      @given = (loadout || {}).to_h { |slot_id, part_id| [ slot_id.to_sym, part_id ] }.freeze
      @loadout = resolve_loadout.freeze
    end

    # The `Part` fitted in a slot, or nil. `#loadout` is the same thing by id — every slot,
    # defaults filled in, empty ones present as nil.
    def part(slot_id)
      id = @loadout[slot_id.to_sym]
      id && @registry.key?(id) ? @registry.fetch(id) : nil
    end

    def fragment
      @fragment ||= @slots.reduce(@fixtures) { |acc, slot| acc.merge(built(slot)) }
    end

    # In catalogue order, never in slot order, so the panel does not rearrange itself when a
    # slot list is reordered for some unrelated reason.
    def diagnostics
      wanted = fitted_parts.flat_map(&:instruments)

      @instruments.values.select { |d| wanted.include?(d.id) }
    end

    def verdict
      @verdict ||= begin
        errors = slot_errors
        # Everything below reads the assembled graph, which cannot be assembled at all while
        # the slots are wrong. Reporting "no route for fuel" on top of "no stoker fitted"
        # buries the one error that matters.
        errors.concat(graph_errors) if errors.empty?
        Verdict.new(errors.freeze, advisory_warnings.freeze).freeze
      end
    end

    def build!
      v = verdict
      raise Error, "cannot assemble operation:\n  #{v.errors.join("\n  ")}" unless v.ok?

      fragment
    end

    private

    # **Every slot appears in the result, empty ones included, and that is what makes a restore
    # exact.** A slot the player deliberately left empty has to be distinguishable from one
    # they simply did not mention, because the second falls back to `slot.default` — so a
    # loadout that recorded only what was fitted would grow the missing parts back the first
    # time a snapshot was restored. Silent, total, and exactly the divergence `options:` exists
    # to prevent. `nil` means empty on purpose; `:none` is the spelling a player-facing form
    # can send for it.
    #
    # The VALUES are symbolised here and it is the other reason this method exists: `options:`
    # round-trips through JSON, `deep_symbolize` converts keys ONLY, and a part id that came
    # back as `"locomotive"` misses every `Parts.fetch`. That is not a nil — it is a different
    # machine. Fourth instance of this trap after parcel resource ids, instrument flags and a
    # minion's station, and **the digest cannot catch any of them**: `canonical` runs through
    # `JSON.generate`, where `:locomotive` and `"locomotive"` are the same string. Only an
    # identity assertion finds it.
    def resolve_loadout
      @slots.to_h do |slot|
        [ slot.id, normalise_part_id(@given.fetch(slot.id, slot.default)) ]
      end
    end

    def normalise_part_id(part_id)
      return nil if part_id.nil?

      id = part_id.to_sym
      id == :none ? nil : id
    end

    def fitted_parts = @slots.filter_map { |slot| part(slot.id) }

    # Built once per slot and reused: the validator needs every part's ids and the fragment
    # needs its nodes, and building twice would hand the graph different objects from the ones
    # that were checked.
    #
    # An empty slot contributes nothing — except, when the run has to survive without it, the
    # link that closes the gap.
    def built(slot)
      @built ||= {}
      @built[slot.id] ||= begin
        fitted_part = part(slot.id)
        if fitted_part
          fitted_part.build(@spec)
        else
          link = slot.bypass_link
          link ? Fragment.new(links: [ link ]) : Fragment.empty
        end
      end
    end

    def slot_errors
      errors = []
      known = @slots.to_h { |s| [ s.id, s ] }

      # Checked against what was ASKED for, not against the resolved loadout — the resolved one
      # is keyed by slot by construction, so it could never disagree and the check would be
      # inert. A silent off switch, and this engine has already paid for five of those.
      (@given.keys - known.keys).each do |unknown|
        errors << "no slot #{unknown.inspect} on this chassis " \
                  "(slots: #{known.keys.join(', ')})"
      end

      @slots.each do |slot|
        part_id = @loadout[slot.id]

        if part_id.nil?
          errors << "#{slot.label} is required and nothing is fitted" if slot.required?
          next
        end

        unless @registry.key?(part_id)
          errors << "#{slot.label}: no such part #{part_id.inspect}"
          next
        end

        fitted = @registry.fetch(part_id)
        if fitted.kind != slot.accepts
          errors << "#{slot.label} takes a #{slot.accepts}, but #{fitted.label} is a #{fitted.kind}"
        end
      end

      errors.concat(id_collisions) if errors.empty?
      errors
    end

    # Ids are ONE FLAT NAMESPACE across nodes, levers, gauges and crew, because they key one
    # rng table — a collision hands two components the same stream, survives a snapshot and
    # destroys the order-independence the per-name streams exist to provide. `validate_graph!`
    # has always refused duplicates, but assembly makes them likely for the first time (two
    # parts both naming a node `:pump`), so it is worth saying WHICH SLOTS collided rather
    # than only which id.
    def id_collisions
      errors = []
      seen = {}

      @slots.each do |slot|
        fitted = part(slot.id)
        next if fitted.nil?

        pieces = built(slot)
        ids = pieces.nodes.map(&:id) + pieces.control_points.map(&:id) + fitted.instruments

        ids.each do |id|
          if seen.key?(id)
            errors << "#{slot.label} and #{seen.fetch(id)} both define #{id.inspect}"
          else
            seen[id] = slot.label
          end
        end

        missing = fitted.provides - pieces.nodes.map(&:id)
        next if missing.empty?

        errors << "#{fitted.label} declares it provides #{missing.join(', ')} but does not build " \
                  "#{missing.length == 1 ? 'it' : 'them'}"
      end

      errors.concat(unknown_instruments)
      errors
    end

    def unknown_instruments
      fitted_parts
        .flat_map { |p| p.instruments.map { |i| [ p, i ] } }
        .reject { |_, id| @instruments.key?(id) }
        .map { |p, id| "#{p.label} names an instrument #{id.inspect} the panel does not define" }
    end

    # Reachability: the only check that catches "assembles fine, cannot possibly work".
    #
    # Asked through the REAL router rather than a second model of the graph, for the same
    # reason `Operation#validate_graph!` is left to do its own job — a parallel implementation
    # of path resolution would be one more thing to keep honest, and would disagree eventually.
    def graph_errors
      nodes = fragment.nodes.to_h { |n| [ n.id, n ] }

      dangling = dangling_links(nodes)
      return dangling if dangling.any?

      paths = resolved_paths(nodes)
      return [ @resolve_error ] if paths.nil?

      @routes.filter_map do |route|
        next if reachable?(paths, nodes, route.fetch(:from), route.fetch(:to), route.fetch(:carrying))

        route.fetch(:as, "#{route.fetch(:carrying)} cannot get from " \
                         "#{route.fetch(:from)} to #{route.fetch(:to)}")
      end
    end

    # `Path.resolve` raises on a graph it cannot walk — a conduit whose outlet goes nowhere, a
    # ring of transport nodes with no holder in it. Those are verdicts rather than crashes: the
    # outfitting screen has to be able to show a player what they did.
    def resolved_paths(nodes)
      Path.resolve(nodes: nodes, links: fragment.links)
    rescue Error => e
      @resolve_error = e.message
      nil
    end

    # `Path.resolve` walks links without checking they land anywhere, so a bypass pointing at
    # a port that no longer exists would surface as a `KeyError` from deep inside the walk.
    def dangling_links(nodes)
      fragment.links.flat_map do |link|
        [ [ link.from_node, link.from_port ], [ link.to_node, link.to_port ] ].filter_map do |id, port|
          node = nodes[id]
          next "link #{link.id}: no node #{id}" if node.nil?
          next if node.ports.key?(port)

          "link #{link.id}: #{id} has no port #{port}"
        end
      end
    end

    def reachable?(paths, nodes, from, to, tag)
      onward = Hash.new { |h, k| h[k] = [] }
      paths.each do |path|
        onward[path.from_node] << path.to_node if path_carries?(path, nodes, tag)
      end

      seen = { from => true }
      queue = [ from ]
      until queue.empty?
        current = queue.shift
        return true if current == to

        onward[current].each do |nxt|
          next if seen[nxt]

          seen[nxt] = true
          queue << nxt
        end
      end
      false
    end

    # Material has to satisfy EVERY port on the route, not just the two ends — one dry tag in
    # the middle of a wet line silently repeals whatever depended on it, which is exactly how
    # the chimney and the steam line each lost their condensate once.
    def path_carries?(path, nodes, tag)
      path.links.all? do |link|
        accepts?(nodes.fetch(link.from_node).port(link.from_port), tag) &&
          accepts?(nodes.fetch(link.to_node).port(link.to_port), tag)
      end
    end

    def accepts?(port, tag) = port.accepts.empty? || port.accepts.include?(tag)

    def advisory_warnings
      @advisories.filter_map do |advisory|
        next if @loadout[advisory.fetch(:slot).to_sym]

        advisory.fetch(:says)
      end
    end
  end
end
