# frozen_string_literal: true

module ReactorSim
  # A space that people and machinery are **in**.
  #
  # **A place owns nodes, and that is what makes exposure geometric rather than occupational.**
  # A hazard keyed by station says somebody was hurt because of the job they were doing; a boiler
  # letting go hurts whoever is in the engine room, including the person walking through it with
  # no job at all, and misses the fireman who left two minutes ago. Keyed by place, a node's
  # `endangers:` names rooms and the arithmetic is unchanged.
  #
  # Things that are not rooms have no place and need none: a seam is rock, not a space. They key
  # their hazards by station, which is what leaves an operation with no geometry working exactly
  # as it did — see `docs/design_sketches/breathable-air.md` §5.
  #
  # Declared rather than scraped out of passage endpoints, so that a place has somewhere to carry
  # a label, so that a place nothing has been wired to yet is still legal to name, and so that a
  # `Layout` can refuse a passage or a station that names a place nobody declared.
  # `air:` names **which of its nodes is the air people in it breathe**, and is needed only
  # where more than one could be. A district holds exactly one gas volume and says nothing; an
  # engine house holds five — the room, the firebox, the drum, the injector, the steam chest —
  # and only one of them is a lungful. `Layout` infers it when it is unambiguous and refuses to
  # guess when it is not, because picking the first declared would be silent and wrong.
  #
  # `exposure:` is **how much of the weather reaches it**, 0 to 1: a pit bank is open to the sky,
  # an engine house keeps most of it out, and underground — the default — none at all. A node's
  # ambient follows the outdoor temperature by its place's exposure, and the sky's light and what
  # lies underfoot are offered to people there in proportion. Nil means it was not said, which a
  # merge treats as nothing so the room's own declaration wins.
  Place = Struct.new(:id, :label, :nodes, :air, :exposure, keyword_init: true) do
    def initialize(id:, label: nil, nodes: [], air: nil, exposure: nil)
      super(id: id.to_sym, label: label || id.to_s.tr("_", " ").capitalize,
            nodes: Array(nodes).map(&:to_sym).uniq.freeze, air: air&.to_sym,
            exposure: exposure&.to_f)
      raise Error, "place #{id}: air #{air.inspect} is not one of its nodes" if
        air && !nodes.map(&:to_sym).include?(air.to_sym)
      raise Error, "place #{id}: exposure #{exposure} is not between 0 and 1" if
        exposure && !(0.0..1.0).cover?(exposure.to_f)

      freeze
    end

    def exposed = exposure || 0.0

    def holds?(node_id) = nodes.include?(node_id&.to_sym)
  end
end
