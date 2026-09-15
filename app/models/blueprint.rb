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

  attr_reader :kind, :blueprint_id, :label, :detail, :materials, :requires_achievement

  def initialize(kind:, blueprint_id:, label:, detail: nil, materials: {},
                 requires_achievement: nil)
    @kind = kind.to_sym
    @blueprint_id = blueprint_id.to_s
    @label = label
    @detail = detail
    # Resource id => kilograms. Empty means genuinely free; a blueprint with no entry in
    # `config/blueprints.yml` does not get here at all, because that is an error rather than a
    # free part.
    @materials = materials.freeze
    @requires_achievement = requires_achievement
    freeze
  end

  def free? = @materials.empty?

  # Nothing can pay a bill of materials yet — there is no resource ledger, because a match reward
  # cannot be designed against a single steam engine. So this is the achievement gate only, and
  # the resource gate joins it here when there is something to spend.
  def obtainable_by?(owner_id)
    @requires_achievement.nil? ||
      Achievement.earned?(@requires_achievement, owner_id: owner_id)
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
    def reload!
      @catalogue = nil
      @costs = nil
    end

    private

    # Memoised rather than built at boot. Building it reads the content YAML, and
    # `config/initializers/reactor_sim.rb` deliberately leaves that lazy so a `rails console`
    # or a rake task pays nothing — forcing it here would quietly undo that for the sake of
    # moving an error a few seconds earlier. `rake blueprints:audit` builds it on demand.
    def catalogue
      @catalogue ||= (operations + chassis + parts + minions).index_by(&:key).freeze
    end

    # `config/blueprints.yml`, indexed the way the catalogue is. Delivery tier, deliberately —
    # the simulation has no concept of value and must not acquire one (§7).
    def costs
      @costs ||= YAML.safe_load_file(Rails.root.join("config/blueprints.yml"))
                     .flat_map { |kind, entries|
                       entries.map { |id, spec| [ [ kind.to_sym, id ], spec || {} ] }
                     }.to_h.freeze
    end

    # **A blueprint with no entry is an error, not a free one**, and a material or achievement it
    # names that nothing knows is an error too. Same rule as everywhere else in this system, for
    # the same reason: a lookup that silently misses is a feature silently switched off, and a
    # price that defaults to zero is the same bug wearing different clothes.
    def gates_for(kind, blueprint_id)
      spec = costs.fetch([ kind, blueprint_id ]) do
        raise Ungated, "no entry in config/blueprints.yml for #{kind} #{blueprint_id.inspect}"
      end

      materials = (spec["materials"] || {}).to_h { |id, kg| [ id.to_sym, Float(kg) ] }
      materials.each_key { |id| ReactorSim::Content.default.resource(id) }

      requires = spec["requires"]&.to_sym
      if requires && !Achievement.known?(requires)
        raise Ungated, "#{kind} #{blueprint_id.inspect} requires unknown achievement " \
                       "#{requires.inspect}"
      end

      { materials: materials, requires_achievement: requires }
    end

    def build(kind, blueprint_id, label:, detail: nil)
      new(kind: kind, blueprint_id: blueprint_id, label: label, detail: detail,
          **gates_for(kind, blueprint_id.to_s))
    end

    def operations
      ReactorSim::Operations.catalogued.map do |type|
        build(:operation, type, label: humanize(type))
      end
    end

    def chassis
      ReactorSim::Operations.catalogued.flat_map do |type|
        ReactorSim::Operations.chassis_for(type).map do |frame|
          build(:chassis, chassis_id(type, frame),
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
        build(:part, id, label: part.label, detail: part.description)
      end
    end

    # **This models the wrong noun and is known to.** It enumerates content archetypes —
    # `fireman`, `yardhand` — which are **jobs a minion performs**, not minions. What a player
    # actually unlocks is an individual: Jim, who is human and starts with certain stats and tags,
    # or Elowynne, who is an elf. Each is their own template, upgradable by further blueprints
    # (certification courses that grant stat bumps or new tags), and each carries equipment in
    # three slots — tool set, gear, utility — whose blueprints are unlocked *per minion*.
    #
    # Left in place rather than ripped out because the *mechanism* is right and the entities are
    # not: minions are unlockable, these are simply not the minions. Nothing enforces minion
    # ownership, so the wrong model cannot yet mislead a player. See
    # `docs/design_sketches/minion-sketch.md`, and do not build on this.
    def minions
      ReactorSim::Content.default.minions.map do |id, spec|
        build(:minion, id, label: spec.fetch(:label, humanize(id)))
      end
    end

    def humanize(id) = id.to_s.tr("_", " ").split.map(&:capitalize).join(" ")
  end

  # Raised rather than returning nil, because a blueprint that silently misses is a feature
  # silently switched off — the same rule that makes `Parts.fetch` raise and `content_spec`
  # refuse a material with no temperature rating.
  class Unknown < StandardError; end

  # A blueprint the cost catalogue does not price, or one whose bill names a material or
  # achievement nothing knows. Fails the whole catalogue rather than that one entry: a partly
  # built catalogue is how a part goes quietly missing from the workshop.
  class Ungated < StandardError; end
end
