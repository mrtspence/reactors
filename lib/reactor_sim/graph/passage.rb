# frozen_string_literal: true

module ReactorSim
  # A way between two places that **people** use.
  #
  # The fourth kind of edge, beside `Link` (material), `ThermalLink` (heat) and `DriveLink`
  # (momentum), and declared the same way. It is separate from all three on purpose: a roadway
  # carries air *and* men, but what limits the air is a conductance and what limits the men is
  # how far it is and who is walking it.
  #
  #   metres       how far. The whole cost of a journey, and why a far district is expensive
  #   speed_m_s    the pace a competent, unaided human manages HERE — a road is not a ladder
  #   requires     a minion tag without which this way cannot be taken at all
  #   control_id   a lever that scales it: a cage nobody has called does not move
  #   driven_by    a shaft that scales it, against `rated_omega`. **A way that costs power.**
  #
  # Two-way. A passage that is genuinely one-way is a different thing (a chute, a fall) and can
  # have its own declaration when something needs one.
  #
  # **A powered way is the point of the whole spatial release.** Ladders are free and slow; a
  # cage is quick and costs a shaft. That is the trade a man engine was built to make, and a
  # passage that can be driven is what lets a player buy their way out of it.
  Passage = Struct.new(:a, :b, :metres, :speed_m_s, :requires, :control_id, :driven_by,
                       :rated_omega, :label, keyword_init: true) do
    def initialize(a:, b:, metres:, speed_m_s: 1.2, requires: nil, control_id: nil,
                   driven_by: nil, rated_omega: nil, label: nil)
      super(a: a.to_sym, b: b.to_sym, metres: metres.to_f, speed_m_s: speed_m_s.to_f,
            requires: requires&.to_sym, control_id: control_id&.to_sym,
            driven_by: driven_by&.to_sym, rated_omega: rated_omega&.to_f, label: label)
      raise Error, "passage #{a}->#{b}: metres must be positive" unless metres.to_f.positive?
      raise Error, "passage #{a}->#{b}: speed must be positive" unless speed_m_s.to_f.positive?

      freeze
    end

    # What this way is good for **right now**. A cage with no lever pulled and no shaft turning
    # is not a slow way down, it is not a way down at all — and a shift underground when the
    # winder stops is exactly the situation the ladderway exists for.
    def speed_in(ctx)
      speed = speed_m_s
      speed *= lever(ctx) if control_id
      speed *= drive(ctx) if driven_by && rated_omega&.positive?
      speed
    end

    def powered? = !control_id.nil? || !driven_by.nil?

    def lever(ctx) = (ctx.controls.fetch(control_id, 0.0) / 100.0).clamp(0.0, 1.0)

    def drive(ctx) = (ctx.node_omega(driven_by).to_f / rated_omega).clamp(0.0, 1.0)

    def ends = [ a, b ]

    def other(place) = place == a ? b : a

    def touches?(place) = a == place || b == place

    # Seconds for a competent, unaided human. What a particular minion manages is this divided
    # by their pace, which is where fatigue and injury get their say.
    def nominal_seconds = metres / speed_m_s
  end

  # Where everything is, and how to get between any two of them.
  #
  # Build-time only, like `Assembly` — nothing here is reachable from a node, and the routing
  # tables are computed once rather than searched per tick. **An operation that declares no
  # passages has no geometry at all** and every minion is always already wherever they are sent,
  # which is what keeps the steam engine bit-identical to before this existed.
  class Layout
    attr_reader :passages, :places

    def initialize(passages: [], control_points: [], places: [], nodes: {})
      @passages = Array(passages).freeze
      @stations = Array(control_points).to_h { |cp| [ cp.id, cp.place ] }.freeze
      @declared = merge_places(Array(places)).freeze
      @places = derive_places.freeze
      @node_places = derive_node_places.freeze
      validate!(nodes.to_h)
      @breathes = derive_breathes(nodes.to_h).freeze
      @adjacency = derive_adjacency.freeze
      @routes = {}
      freeze
    end

    # Does this operation have geometry? One passage is enough to mean yes.
    def spatial? = !@passages.empty?

    # Which place a lever stands in. Nil for a control that has not been placed, which in a
    # spatial operation means it can be worked from anywhere.
    def place_of(station_id) = @stations[station_id&.to_sym]

    # Which place a node sits in, or nil for the things that are not in a room at all. A seam is
    # rock and a strata is water behind rock; neither is anywhere a person can stand.
    def place_of_node(node_id) = @node_places[node_id&.to_sym]

    def place(place_id) = @declared[place_id&.to_sym]

    def declared?(place_id) = @declared.key?(place_id&.to_sym)

    # Which node holds the air in this place — the volume somebody standing here is breathing.
    def breathes(place_id) = @breathes[place_id&.to_sym]

    # **Every** way between two places, not the first one. Two places can be joined more than
    # once — a shaft has a ladderway *and* a cage — and which of them somebody takes depends on
    # what is running, which is a question only the tick can answer. `Tick#step` picks the
    # fastest; returning one here would silently pin everybody to whichever was declared first.
    def passages_between(from, to)
      @passages.select { |p| p.touches?(from) && p.touches?(to) && p.a != p.b }
    end

    # The first step from `from` toward `to`, for somebody carrying `capabilities`.
    #
    # Precomputed per capability set rather than searched per tick, and memoised on the set
    # rather than on the minion because most of a shift shares one. Nil when there is no way
    # through, which `Operation#assign_minion` treats as a refusal rather than as a minion who
    # walks into a wall.
    def next_hop(from, to, capabilities)
      table_for(capabilities).dig(from&.to_sym, to&.to_sym)
    end

    def reachable?(from, to, capabilities)
      return true if from == to

      !next_hop(from, to, capabilities).nil?
    end

    # Every table this layout will ever need, built once. Called at operation build so nothing
    # is computed during a tick.
    def precompute!(capability_sets)
      capability_sets.each { |set| table_for(set) }
      self
    end

    private

    def table_for(capabilities)
      key = Array(capabilities).map(&:to_sym).uniq.sort.freeze
      @routes[key] ||= build_table(key).freeze
    end

    # Breadth-first from every place, recording the first step toward each destination. Passages
    # are walked in declaration order so the table is deterministic where two routes tie.
    def build_table(capabilities)
      usable = @adjacency.transform_values do |neighbours|
        neighbours.select { |_, passage| passable?(passage, capabilities) }.keys.freeze
      end

      @places.to_h { |origin| [ origin, first_steps(origin, usable) ] }
    end

    def first_steps(origin, usable)
      steps = {}
      queue = usable.fetch(origin, []).map { |n| [ n, n ] }
      queue.each { |place, step| steps[place] ||= step }

      until queue.empty?
        place, step = queue.shift
        usable.fetch(place, []).each do |neighbour|
          next if neighbour == origin || steps.key?(neighbour)

          steps[neighbour] = step
          queue << [ neighbour, step ]
        end
      end

      steps.freeze
    end

    def passable?(passage, capabilities)
      passage.requires.nil? || capabilities.include?(passage.requires)
    end

    # **A room is named once and furnished by whoever brings the furniture.** The chassis
    # declares the pit bank; fitting a cage puts its drive there. Same id, node lists unioned,
    # first label wins — the same concatenate-don't-replace rule `Fragment#merge` follows, and
    # the reason a fitting need not know what else is in the room it is installed in.
    def merge_places(places)
      places.each_with_object({}) do |place, acc|
        known = acc[place.id]
        acc[place.id] = known.nil? ? place : Place.new(id: place.id, label: known.label,
                                                       nodes: known.nodes + place.nodes)
      end
    end

    def derive_places
      (@declared.keys + @passages.flat_map(&:ends) + @stations.values.compact).uniq
    end

    def derive_node_places
      @declared.values.each_with_object({}) do |place, acc|
        place.nodes.each { |node_id| acc[node_id] = place.id }
      end
    end

    # **A room's air is its own volume, never a pipe crossing it.** Derived from membership
    # rather than declared a second time: the one node in this place that holds gas and is not
    # transport. The fan and the blower are conduits and carry air *through*; what somebody
    # standing here breathes is what the room holds.
    def derive_breathes(nodes)
      @declared.keys.to_h do |place_id|
        holders = @declared.fetch(place_id).nodes.filter_map { |id| nodes[id] }
                           .select { |node| breathable_volume?(node) }
        [ place_id, holders.first&.id ]
      end
    end

    def breathable_volume?(node)
      !node.transport? && node.respond_to?(:parcels) &&
        node.ports.values.any? { |port| port.accepts.include?(:gas) }
    end

    # **Silence must never be the safe answer**, which is the whole reason places are declared
    # rather than scraped: a hazard that names a place nobody declared, a node that two rooms
    # both claim, or a room whose air nobody modelled would all resolve to nothing at all and be
    # indistinguishable from a place that is simply safe. An operation that declares no places
    # skips this entirely and behaves exactly as it did before they existed.
    def validate!(nodes)
      return if @declared.empty?

      claimed = Hash.new { |h, k| h[k] = [] }
      @declared.each_value { |place| place.nodes.each { |n| claimed[n] << place.id } }

      claimed.each do |node_id, owners|
        raise Error, "place #{owners.first}: no node #{node_id.inspect}" if
          nodes.any? && !nodes.key?(node_id)
        raise Error, "node #{node_id} is in more than one place: #{owners.join(', ')}" if
          owners.length > 1
      end

      undeclared = (@places - @declared.keys)
      raise Error, "undeclared place(s): #{undeclared.join(', ')}" if undeclared.any?

      validate_air!(nodes)
    end

    def validate_air!(nodes)
      return if nodes.empty?

      @declared.each_value do |place|
        holders = place.nodes.filter_map { |id| nodes[id] }.select { |n| breathable_volume?(n) }
        raise Error, "place #{place.id} has no air: nothing in it holds gas" if holders.empty?
        raise Error, "place #{place.id} holds gas in more than one node: " \
                     "#{holders.map(&:id).join(', ')}" if holders.length > 1
      end
    end

    def derive_adjacency
      @places.to_h do |place|
        neighbours = @passages.select { |p| p.touches?(place) && p.other(place) != place }
                              .to_h { |p| [ p.other(place), p ] }
        [ place, neighbours.freeze ]
      end
    end
  end
end
