# frozen_string_literal: true

module ReactorSim
  # A space that people and machinery are **in**.
  #
  # **A place owns nodes, and that is what makes exposure geometric rather than occupational.**
  # A hazard keyed by station says somebody was hurt because of the job they were doing; a vessel
  # letting go hurts whoever is in its room, including the person walking through it with no job
  # at all, and misses whoever was at its post and left two minutes ago. Keyed by place, a node's
  # `endangers:` names rooms and the arithmetic is unchanged.
  #
  # Things that are not rooms have no place and need none: rock is not a space. They key
  # their hazards by station, which is what leaves an operation with no geometry working exactly
  # as it did — see `docs/design_sketches/breathable-air.md` §5.
  #
  # Declared rather than scraped out of passage endpoints, so that a place has somewhere to carry
  # a label, so that a place nothing has been wired to yet is still legal to name, and so that a
  # `Layout` can refuse a passage or a station that names a place nobody declared.
  # `air:` names **which of its nodes is the air people in it breathe**, and is needed only
  # where more than one could be. A room holding exactly one gas volume says nothing; a room of
  # machinery may hold several — the room's air, and every vessel of gas in the machines — and
  # only one of them is a lungful. `Layout` infers it when it is unambiguous and refuses to
  # guess when it is not, because picking the first declared would be silent and wrong.
  #
  # `exposure:` is **how much of the weather reaches it**, 0 to 1: open ground is open to the sky,
  # a building keeps most of it out, and underground — the default — none at all. A node's
  # ambient follows the outdoor temperature by its place's exposure, and the sky's light and what
  # lies underfoot are offered to people there in proportion. Nil means it was not said, which a
  # merge treats as nothing so the room's own declaration wins.
  #
  # `open_air: true` is a place under the sky that **breathes the operation's `Atmosphere`**
  # without owning it — one atmosphere, and many places can be open to it.
  #
  # `carried_by:` names a node that carries the place about — a platform on whatever carries it — and
  # answers `place_at(state)`, the place it stands in. `shares:` is how much of a hazard on it
  # reaches the place it stands in, and of one there reaches it.
  #
  # `water:` names a holder answering `deep?(state, content)` — water a person there may be out of
  # their depth in. In deep water they tread it, and tire; exhausted, they go under, and the place
  # has no air for them (`Tick#tire`).
  Place = Struct.new(:id, :label, :nodes, :air, :exposure, :open_air, :carried_by, :shares, :water,
                     keyword_init: true) do
    def initialize(id:, label: nil, nodes: [], air: nil, exposure: nil, open_air: nil, carried_by: nil, shares: nil,
                   water: nil)
      super(id: id.to_sym, label: label || id.to_s.tr("_", " ").capitalize,
            nodes: Array(nodes).map(&:to_sym).uniq.freeze, air: air&.to_sym,
            exposure: exposure&.to_f, open_air: open_air, carried_by: carried_by&.to_sym, shares: shares&.to_f,
            water: water&.to_sym)
      raise Error, "place #{id}: air #{air.inspect} is not one of its nodes" if
        air && !nodes.map(&:to_sym).include?(air.to_sym)
      raise Error, "place #{id}: exposure #{exposure} is not between 0 and 1" if
        exposure && !(0.0..1.0).cover?(exposure.to_f)
      raise Error, "place #{id}: shares #{shares} is not between 0 and 1" if
        shares && !(0.0..1.0).cover?(shares.to_f)

      freeze
    end

    def exposed = exposure || 0.0

    def carried? = !carried_by.nil?

    def holds?(node_id) = nodes.include?(node_id&.to_sym)
  end
end
