# frozen_string_literal: true

# One unlockable thing, and the catalogue of all of them.
#
# A blueprint is the permanent half of the progression model: owning one is the right to mint a
# **fresh instance** of that thing into any match. It is never consumed by using it, two matches
# may mint the same boiler at once, and nothing an instance accumulates comes back —
# `docs/design_sketches/blueprints.md` §1.
#
# **The catalogue is derived, never hand-written.** Every registered part is a part blueprint,
# every registered operation an operation blueprint, and so on. That is deliberate: a
# hand-maintained list of "things you can unlock" drifts the first time somebody registers a part
# without looking, and it would drift *silently* — the new part would simply be unreachable.
# `docs/CLAUDE.md` calls this out as the difference between an inventory list and a derivation.
#
# **It lives on this side of the boundary.** The simulation knows nothing about players,
# progression or ownership, and must not: `Assembly` answers "will this build run?" and the
# delivery tier answers "are you allowed this part?" (§2, §6). Nothing here is reachable from a
# tick.
class Blueprint
  # The four kinds, in the order a player meets them: you get a machine, then a frame for it,
  # then parts to hang on the frame, then people to work it.
  KINDS = %i[operation chassis part minion].freeze

  attr_reader :kind, :blueprint_id, :label, :detail

  def initialize(kind:, blueprint_id:, label:, detail: nil)
    @kind = kind.to_sym
    @blueprint_id = blueprint_id.to_s
    @label = label
    @detail = detail
    freeze
  end

  # The pair is the identity; neither half is unique on its own.
  def key = [ @kind, @blueprint_id ]

  def ==(other) = other.is_a?(Blueprint) && other.key == key
  alias eql? ==
  def hash = key.hash

  class << self
    def known = catalogue.values

    def of_kind(kind) = catalogue.values.select { |b| b.kind == kind.to_sym }

    def key?(kind, blueprint_id) = catalogue.key?([ kind.to_sym, blueprint_id.to_s ])

    def fetch(kind, blueprint_id)
      catalogue.fetch([ kind.to_sym, blueprint_id.to_s ]) do
        raise Unknown, "no #{kind} blueprint #{blueprint_id.inspect}"
      end
    end

    # A chassis has no standalone existence — it is a frame *for* an operation — and two
    # machines could each name a frame `standard`. Scoping the id keeps unlocking one from
    # silently unlocking the other, which is the kind of collision this codebase pays for
    # elsewhere by keeping ids in one flat namespace and refusing duplicates outright.
    def chassis_id(operation_type, chassis) = "#{operation_type}/#{chassis}"

    # Specs build throwaway part registries; without this the catalogue memoised from the real
    # one leaks into them. Same reason `ReactorSim::Parts.reset!` exists.
    def reload! = @catalogue = nil

    private

    # Memoised rather than built at boot. Building it reads the content YAML, and
    # `config/initializers/reactor_sim.rb` deliberately leaves that lazy so a `rails console`
    # or a rake task pays nothing — forcing it here would quietly undo that for the sake of
    # moving an error a few seconds earlier. `rake blueprints:audit` builds it on demand.
    def catalogue
      @catalogue ||= (operations + chassis + parts + minions).index_by(&:key).freeze
    end

    def operations
      ReactorSim::Operations.known.map do |type|
        new(kind: :operation, blueprint_id: type, label: humanize(type))
      end
    end

    def chassis
      ReactorSim::Operations.known.flat_map do |type|
        ReactorSim::Operations.chassis_for(type).map do |frame|
          new(kind: :chassis, blueprint_id: chassis_id(type, frame),
              label: humanize(frame), detail: humanize(type))
        end
      end
    end

    # Parts carry their own label and description, so this adds nothing but the kind — which is
    # exactly the point. A part's story stays in `parts.rb` beside the sweep that chose its
    # numbers.
    def parts
      ReactorSim::Parts.known.map do |id|
        part = ReactorSim::Parts.fetch(id)
        new(kind: :part, blueprint_id: id, label: part.label, detail: part.description)
      end
    end

    # A minion blueprint is an **archetype**, not a person. You unlock the template; the minion
    # in a match is minted from it and their health, fatigue and station live and die there —
    # the same rule every other instance follows.
    def minions
      ReactorSim::Content.default.minions.map do |id, spec|
        new(kind: :minion, blueprint_id: id, label: spec.fetch(:label, humanize(id)))
      end
    end

    def humanize(id) = id.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
  end

  # Raised rather than returning nil, because a blueprint that silently misses is a feature
  # silently switched off — the same rule that makes `Parts.fetch` raise and `content_spec`
  # refuse a material with no temperature rating.
  class Unknown < StandardError; end
end
