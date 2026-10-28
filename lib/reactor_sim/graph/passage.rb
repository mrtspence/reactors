# frozen_string_literal: true

module ReactorSim
  # A way between two places that **people** use.
  #
  # The fourth kind of edge, beside `Link` (material), `ThermalLink` (heat) and `DriveLink`
  # (momentum), and declared the same way. It is separate from all three on purpose: a road can
  # carry air *and* people, but what limits the air is a conductance and what limits the people is
  # how far it is and who is walking it.
  #
  #   metres       how far. The whole cost of a journey, and why a far place is expensive
  #   speed_m_s    the pace a competent, unaided human manages HERE — a road is not a ladder
  #   requires     a minion tag without which this way cannot be taken at all
  #   control_id   a lever that scales it: a conveyance nobody has called does not move
  #   driven_by    a shaft that scales it, against `rated_omega`. **A way that costs power.**
  #   hoist        a drum whose conveyance you **ride**: you board at your landing when it is
  #                there and stopped, you are wherever it is, and you get off at the far
  #                landing. `staffed_by` is the post that works it, and with nobody there it is
  #                not running at all. `a` is the landing at the top of the drum's travel.
  #   through      the nodes this way runs through. Any one of them blocking closes the way,
  #                and routing finds another if there is one.
  #   rated_kg     what a ridden way's conveyance is rated to carry. Only a marshal enforces it.
  #   marshals     `{ landing => station }`: who stands at each landing and stops boarding at the
  #                rating. With nobody there, everybody waiting gets on.
  #
  # Two-way. A passage that is genuinely one-way is a different thing (a chute, a fall) and can
  # have its own declaration when something needs one.
  #
  # **A powered way is the point of the whole spatial release.** Walking is free and slow; a
  # ridden or driven way is quick and costs power. A passage that can be driven is what lets a
  # player buy their way out of the walk.
  Passage = Struct.new(:a, :b, :metres, :speed_m_s, :requires, :control_id, :driven_by,
                       :rated_omega, :label, :hoist, :staffed_by, :through, :rated_kg, :marshals,
                       keyword_init: true) do
    def initialize(a:, b:, metres:, speed_m_s: 1.2, requires: nil, control_id: nil,
                   driven_by: nil, rated_omega: nil, label: nil, hoist: nil, staffed_by: nil,
                   through: nil, rated_kg: nil, marshals: {})
      super(a: a.to_sym, b: b.to_sym, metres: metres.to_f, speed_m_s: speed_m_s.to_f,
            requires: requires&.to_sym, control_id: control_id&.to_sym,
            driven_by: driven_by&.to_sym, rated_omega: rated_omega&.to_f, label: label,
            hoist: hoist&.to_sym, staffed_by: staffed_by&.to_sym,
            through: Array(through).map(&:to_sym).freeze,
            rated_kg: rated_kg&.to_f,
            marshals: marshals.to_h { |landing, station| [ landing.to_sym, station.to_sym ] }.freeze)
      raise Error, "passage #{a}->#{b}: metres must be positive" unless metres.to_f.positive?
      raise Error, "passage #{a}->#{b}: speed must be positive" unless speed_m_s.to_f.positive?

      freeze
    end

    def ridden? = !hoist.nil?

    # Where on the drum's travel a landing is: `a` at the top, `b` at the bottom.
    def landing_m(place) = place == a ? 0.0 : metres

    # What this way is good for **right now**. A powered way with no lever pulled and no shaft
    # turning is not a slow way, it is not a way at all — and a crew beyond it when it stops is
    # exactly the situation a way on foot beside it exists for.
    #
    # A ridden way runs at its rated speed whenever it is in service; whether its conveyance is
    # here is the rider's business, not the route's.
    def speed_in(ctx)
      return speed_m_s if ridden?

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

    def closed_by?(closed) = through.intersect?(Array(closed))

    # Seconds for a competent, unaided human. What a particular minion manages is this divided
    # by their pace, which is where fatigue and injury get their say.
    def nominal_seconds = metres / speed_m_s
  end

  # Where everything is, and how to get between any two of them.
  #
  # Build-time only, like `Assembly` — nothing here is reachable from a node, and the routing
  # tables are computed once rather than searched per tick. **An operation that declares no
  # passages has no geometry at all** and every minion is always already wherever they are sent,
  # which is what leaves an operation without geometry exactly as it would be with none of this.
  class Layout
    attr_reader :passages, :places

    def initialize(passages: [], control_points: [], places: [], nodes: {})
      @passages = Array(passages).freeze
      @stations = Array(control_points).to_h { |cp| [ cp.id, cp.place ] }.freeze
      @declared = merge_places(Array(places)).freeze
      @places = derive_places.freeze
      @node_places = derive_node_places.freeze
      @node_exposure = @node_places.filter_map { |node_id, place_id|
        share = exposure(place_id)
        [ node_id, share ] if share.positive?
      }.to_h.freeze
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

    # Which place a node sits in, or nil for the things that are not in a room at all — rock, or
    # water behind rock, is nowhere a person can stand.
    def place_of_node(node_id) = @node_places[node_id&.to_sym]

    def place(place_id) = @declared[place_id&.to_sym]

    def declared?(place_id) = @declared.key?(place_id&.to_sym)

    # Which node holds the air in this place — the volume somebody standing here is breathing.
    def breathes(place_id) = @breathes[place_id&.to_sym]

    # How much of the weather reaches a place, and the places it reaches at all.
    def exposure(place_id) = @declared[place_id&.to_sym]&.exposed || 0.0

    def exposed_places = @declared.values.select { |place| place.exposed.positive? }.map(&:id)

    # Places something carries about, sorted by id so whatever walks them sums in one order.
    def carried_places = @declared.values.select(&:carried?).sort_by(&:id)

    # Places with water somebody can be out of their depth in, sorted by id.
    def watered_places = @declared.values.select(&:water).sort_by(&:id)

    # **Every node the weather reaches, and how much**: those in exposed places. Configuration,
    # so the tick reads it rather than walking the places.
    attr_reader :node_exposure

    # **Every** way between two places, not the first one. Two places can be joined more than
    # once — a way on foot *and* a ridden one beside it — and which of them somebody takes depends on
    # what is running, which is a question only the tick can answer. `Tick#step` picks the
    # fastest; returning one here would silently pin everybody to whichever was declared first.
    def passages_between(from, to)
      @passages.select { |p| p.touches?(from) && p.touches?(to) && p.a != p.b }
    end

    # The first step from `from` toward `to`, for somebody carrying `capabilities`, avoiding every
    # passage that runs `through:` a node in `closed` — a way choked with wreckage.
    #
    # Computed per distinct (capability set, closed set) and memoised, never searched per tick:
    # most of a shift shares one capability set, and the closed set changes only when something
    # in the way of a passage fails. Nil when there is no way through, which
    # `Operation#assign_minion` treats as a refusal rather than as a minion who walks into a wall.
    def next_hop(from, to, capabilities, closed = [])
      table_for(capabilities, closed).dig(from&.to_sym, to&.to_sym)&.first
    end

    # How far it is, following the route `next_hop` actually takes. Nil when there is no way
    # through, and zero for somewhere you are already standing.
    #
    # **Geometry, not duration** — a ridden way and the way on foot beside it are the same distance
    # and only one of them is quick, so what a walk *costs* is this divided by what is running. Precomputed
    # with the routing table, so asking is a lookup.
    def route_metres(from, to, capabilities, closed = [])
      return 0.0 if from == to

      table_for(capabilities, closed).dig(from&.to_sym, to&.to_sym)&.last
    end

    def reachable?(from, to, capabilities, closed = [])
      return true if from == to

      !next_hop(from, to, capabilities, closed).nil?
    end

    # The nodes some passage runs through, which are the only ones whose failure can close a way.
    def through_nodes = @passages.flat_map(&:through).uniq

    # Every table this layout will ever need, built once. Called at operation build so nothing
    # is computed during a tick.
    def precompute!(capability_sets)
      capability_sets.each { |set| table_for(set) }
      self
    end

    private

    def table_for(capabilities, closed = [])
      key = [ Array(capabilities).map(&:to_sym).uniq.sort, Array(closed).map(&:to_sym).uniq.sort ]
      @routes[key] ||= build_table(*key).freeze
    end

    def build_table(capabilities, closed)
      usable = @adjacency.transform_values do |neighbours|
        neighbours.select { |_, passage| passable?(passage, capabilities, closed) }.freeze
      end

      @places.to_h { |origin| [ origin, first_steps(origin, usable) ] }
    end

    # `{ destination => [first step, metres] }` along the **shortest** route by length, so a long
    # way round — an escape up the far shaft — is taken only when the short one is closed. Settled
    # nearest-first; ties break on declaration order, which keeps the table deterministic.
    def first_steps(origin, usable)
      steps = {}
      # `[metres, order, place, first step]`; `order` is unique, so the nearest entry is too.
      frontier = [ [ 0.0, 0, origin, nil ] ]
      order = 0

      until frontier.empty?
        nearest = frontier.min_by { |metres, seq, _, _| [ metres, seq ] }
        frontier.delete(nearest)
        metres, _, place, step = nearest
        next if steps.key?(place)

        steps[place] = [ step, metres ] unless place == origin
        usable.fetch(place, {}).each do |neighbour, passage|
          next if neighbour == origin || steps.key?(neighbour)

          order += 1
          frontier << [ metres + passage.metres, order, neighbour, step || neighbour ]
        end
      end

      steps.freeze
    end

    def passable?(passage, capabilities, closed)
      (passage.requires.nil? || capabilities.include?(passage.requires)) &&
        !passage.closed_by?(closed)
    end

    # **A room is named once and furnished by whoever brings the furniture.** The chassis
    # declares the room; a fitting puts its gear there. Same id, node lists unioned,
    # first label and first declared air win — the same concatenate-don't-replace rule
    # `Fragment#merge` follows, and the reason a fitting need not know what else is in the room
    # it is installed in.
    def merge_places(places)
      places.each_with_object({}) do |place, acc|
        known = acc[place.id]
        acc[place.id] = known.nil? ? place : Place.new(id: place.id, label: known.label,
                                                       nodes: known.nodes + place.nodes,
                                                       air: known.air || place.air,
                                                       exposure: known.exposure || place.exposure,
                                                       open_air: known.open_air || place.open_air,
                                                       carried_by: known.carried_by || place.carried_by,
                                                       shares: known.shares || place.shares,
                                                       water: known.water || place.water)
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
      sky = atmosphere(nodes)
      @declared.keys.to_h do |place_id|
        place = @declared.fetch(place_id)
        next [ place_id, place.air ] if place.air
        next [ place_id, sky ] if place.open_air

        holders = place.nodes.filter_map { |id| nodes[id] }
                       .select { |node| breathable_volume?(node) }
        [ place_id, holders.first&.id ]
      end
    end

    def atmosphere(nodes) = nodes.values.find { |node| node.is_a?(Nodes::Atmosphere) }&.id

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

      validate_marshals!
      validate_air!(nodes)
      validate_carried!(nodes)
      validate_water!(nodes)
    end

    # Water that cannot say whether it is deep would drown nobody.
    def validate_water!(nodes)
      return if nodes.empty?

      watered_places.each do |place|
        raise Error, "place #{place.id}: water #{place.water.inspect}, which cannot say whether it is deep" unless
          nodes[place.water].respond_to?(:deep?)
      end
    end

    # A carried place whose carrier cannot say where it is would share its hazards with nowhere.
    def validate_carried!(nodes)
      return if nodes.empty?

      carried_places.each do |place|
        carrier = nodes[place.carried_by]
        raise Error, "place #{place.id}: carried by #{place.carried_by.inspect}, which cannot say where it is" unless
          carrier.respond_to?(:place_at)
      end
    end

    # A marshal who is not a station at that landing stops nobody.
    def validate_marshals!
      @passages.each do |passage|
        passage.marshals.each do |landing, station|
          next if passage.touches?(landing) && @stations[station] == landing

          raise Error, "passage #{passage.label || passage.a}: marshal #{station} is not a station " \
                       "at #{landing}"
        end
      end
    end

    def validate_air!(nodes)
      return if nodes.empty?

      @declared.each_value do |place|
        if place.open_air && !place.air
          raise Error, "place #{place.id} is open air and the operation has no atmosphere" unless atmosphere(nodes)

          next
        end

        holders = place.nodes.filter_map { |id| nodes[id] }.select { |n| breathable_volume?(n) }
        raise Error, "place #{place.id} has no air: nothing in it holds gas" if holders.empty?
        next if place.air

        raise Error, "place #{place.id} holds gas in more than one node " \
                     "(#{holders.map(&:id).join(', ')}) and does not say which is its air" if
          holders.length > 1
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
