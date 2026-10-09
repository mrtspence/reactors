# frozen_string_literal: true

require "yaml"

module ReactorSim
  # The only place in the simulation that touches the filesystem.
  #
  # Substance properties, phase boundaries and reaction stoichiometry are *content*, not
  # code: diffable, rebalanceable without a migration, and validated at boot
  # (docs/architecture.md §5). Adding a coolant is a file; adding a new kind of physics is
  # a module.
  #
  # Loading happens once, explicitly, at boot. The tick path never reads a file — which is
  # what keeps the purity rule ("no I/O in the simulation") honest. A registry can also be
  # built in memory and injected, which is what the specs do.
  module Content
    ROOT = File.expand_path("../../content", __dir__)

    class << self
      # Memoised so the tick path never pays for it, and so every Operation in a process
      # shares one frozen registry.
      def default
        @default ||= load(ROOT)
      end

      def load(dir)
        Registry.new(
          resources: read_all(File.join(dir, "resources")),
          reactions: read_all(File.join(dir, "reactions")),
          archetypes: read_all(File.join(dir, "archetypes")),
          minions: read_all(File.join(dir, "minions"))
        ).freeze
      end

      # Test seam: build a registry from literals with no filesystem involved. Every keyword
      # defaults, so a spec asks for the one table it cares about and gets empty ones for the
      # rest — which is what keeps an unrelated substance from boiling mid-test.
      def build(resources: {}, reactions: {}, archetypes: {}, minions: {})
        Registry.new(resources: deep_sym(resources), reactions: deep_sym(reactions),
                     archetypes: deep_sym(archetypes), minions: deep_sym(minions)).freeze
      end

      # Public because `Registry#merging` needs it — a caller handing in literals should get the
      # same key treatment a YAML file gets, or a fixture written with string keys would be a
      # different shape from every other entry in the table.
      def deep_symbolize(obj) = deep_sym(obj)

      private

      def read_all(dir)
        return {} unless Dir.exist?(dir)

        Dir.glob(File.join(dir, "*.yml")).sort.each_with_object({}) do |path, acc|
          parsed = YAML.safe_load_file(path, permitted_classes: [], aliases: true) || {}
          acc.merge!(deep_sym(parsed))
        end
      end

      def deep_sym(obj)
        case obj
        when Hash  then obj.to_h { |k, v| [ k.to_sym, deep_sym(v) ] }
        when Array then obj.map { |v| deep_sym(v) }
        else obj
        end
      end
    end

    # Frozen lookup tables. Validation is deliberately eager and loud: a typo in a content
    # file is otherwise a miserable class of bug that surfaces mid-match as a nil.
    class Registry
      REQUIRED_RESOURCE_KEYS  = %i[specific_heat_j_per_kg_k density_kg_per_m3].freeze
      REQUIRED_REACTION_KEYS  = %i[consumes produces rate_per_s enthalpy_j_per_unit].freeze
      # An alternative pathway is a whole reaction bar the rate, which it shares with the
      # preferred one — a fire is one fire whatever it is making.
      REQUIRED_PATHWAY_KEYS   = %i[consumes produces enthalpy_j_per_unit].freeze
      # An individual is a name and a race. Everything else is an offset and may be omitted.
      REQUIRED_MINION_KEYS    = %i[name archetype].freeze

      # An archetype declares all five, because it is the baseline every other layer offsets and
      # a missing one would surface mid-match as a nil inside an arithmetic expression. The list
      # itself lives in `Sheet`, with the folding rules it belongs to.
      REQUIRED_ARCHETYPE_KEYS = ([ :label ] + Sheet::STATS).freeze

      attr_reader :resources, :reactions, :archetypes, :minions

      def initialize(resources:, reactions:, archetypes: {}, minions: {})
        @resources = resources.freeze
        @reactions = reactions.freeze
        @archetypes = archetypes.freeze
        @minions = minions.freeze
        @phase_pairs = index_phase_pairs.freeze
        @tags = @resources.to_h { |id, spec| [ id, spec.fetch(:tags, []).map(&:to_sym).freeze ] }.freeze
        validate!
        # Resolved AFTER validation, because resolving reaches for an archetype by name and a
        # minion naming one that does not exist should say so rather than raise a KeyError from
        # inside the arithmetic.
        @sheets = @minions.keys.to_h { |id| [ id, build_sheet(id) ] }.freeze
      end

      def resource(id)
        @resources.fetch(id.to_sym) { raise Error, "unknown resource: #{id.inspect}" }
      end

      def reaction(id)
        @reactions.fetch(id.to_sym) { raise Error, "unknown reaction: #{id.inspect}" }
      end

      def archetype(id)
        @archetypes.fetch(id.to_sym) { raise Error, "unknown archetype: #{id.inspect}" }
      end

      def minion(id)
        @minions.fetch(id.to_sym) { raise Error, "unknown minion: #{id.inspect}" }
      end

      # Everybody a player could come to own. The last-resort standin exists and is excluded,
      # because it cannot be unlocked — that is the whole of what makes it a last resort. The
      # delivery tier derives its catalogue from this rather than from `minions`, so a
      # non-hireable individual never appears as something to buy.
      def hireable = @minions.reject { |_, spec| spec[:hireable] == false }

      # An individual's stats and tags with their race already folded in — layers one and two of
      # the four in `content/archetypes/races.yml`. Training and equipment are layers three and
      # four and are applied at build by the delivery tier, because they are things a player
      # OWNS and ownership is not something this library is allowed to know about.
      #
      # Precomputed at construction for the same reason resource tags are: this is read while
      # building an operation and there is no reason to fold the same three hashes every time.
      def sheet(id)
        @sheets.fetch(id.to_sym) { raise Error, "unknown minion: #{id.inspect}" }
      end

      # This registry plus a few more entries, as a new frozen registry.
      #
      # **Exists for test fixtures, and the reason is worth stating.** A spec that runs a machine
      # has to say who is working it, and pinning that to a real individual — Jim — makes every
      # balance change to Jim's stats break specs that are not about Jim. Fixtures with flat,
      # deliberately boring numbers keep a reference machine a reference machine.
      #
      # Resources and reactions are not extendable here on purpose: a spec wanting different
      # physics wants `Content.build`, which starts from nothing and says so.
      def merging(archetypes: {}, minions: {})
        self.class.new(resources: @resources, reactions: @reactions,
                       archetypes: @archetypes.merge(Content.deep_symbolize(archetypes)),
                       minions: @minions.merge(Content.deep_symbolize(minions))).freeze
      end

      # Precomputed. This is called once per parcel per port per link per tick, and the
      # naive version allocated a fresh array every time.
      def tags(id) = @tags.fetch(id.to_sym) { raise Error, "unknown resource: #{id.inspect}" }

      # The liquid/vapour pair a resource belongs to, from EITHER side.
      #
      # Looking the pair up only from the liquid was a real bug: a condenser holding
      # nothing but steam had no liquid parcel to discover the pair from, so it never
      # condensed and quietly filled with vapour forever.
      def phase_pair(id) = @phase_pairs[id.to_sym]

      attr_reader :phase_pairs

      def specific_heat(id) = resource(id).fetch(:specific_heat_j_per_kg_k).to_f
      def density(id)       = resource(id).fetch(:density_kg_per_m3).to_f

      # Mechanical properties, for resources used as the material something is MADE of
      # rather than something that flows through it. Only required on those, so a resource
      # nobody builds with need not declare a tensile strength — but asking for one that
      # is missing fails loudly rather than returning nil into a stress calculation.
      def tensile_strength_pa(id)
        resource(id).fetch(:tensile_strength_pa) do
          raise Error, "resource #{id.inspect} has no tensile_strength_pa; it cannot be " \
                       "used as a structural material"
        end.to_f
      end

      # How hot a part made of this may get before it stops being structural — **not** its
      # melting point. See `content/resources/materials.yml`.
      #
      # Returns infinity when the material does not declare one, and that is deliberately the
      # opposite policy from `tensile_strength_pa` above. A missing tensile strength is always a
      # mistake, because the only reason to ask is that something is spinning. A missing
      # temperature rating is the ordinary case for the great majority of resources — coal and
      # steam are not built out of — and a node only consults this when it has been *given* a
      # `material:`, which is already a deliberate act.
      #
      # Infinity is nonetheless a silent off switch, which is exactly how over-temperature
      # fatigue sat unused since the day it was written. If you add a structural material, rate
      # it; `content_spec` asserts that everything tagged `:structural` carries one.
      def max_temperature_k(id)
        value = resource(id)[:max_temperature_k]
        value.nil? ? Float::INFINITY : value.to_f
      end

      # What it costs to melt a kilogram of this, once it is already at its melting point.
      #
      # **Infinity means "does not melt in this model"**, not "melts for free" — a part made of
      # something with no figure declared simply keeps heating, which is the behaviour every
      # material had before any of them declared one. Zero would mean the opposite and would
      # vaporise a part's whole substance in a single tick.
      def latent_heat_of_fusion_j_per_kg(id)
        value = resource(id)[:latent_heat_of_fusion_j_per_kg]
        value.nil? ? Float::INFINITY : value.to_f
      end

      # Enthalpy of formation relative to the 0 K reference, per kg. This is what makes
      # phase change conserve energy exactly: boiling 1 kg of water at constant
      # temperature costs precisely the latent heat, no more and no less.
      def formation_enthalpy(id) = resource(id).fetch(:formation_enthalpy_j_per_kg, 0.0).to_f

      def phase(id) = resource(id)[:phase]

      def freeze
        @resources.freeze
        @reactions.freeze
        @minions.freeze
        super
      end

      private

      # Indexed from both sides, eagerly, so the registry can stay frozen.
      def index_phase_pairs
        @resources.each_with_object({}) do |(id, spec), acc|
          next unless spec[:phase]

          vapour = spec.fetch(:phase).fetch(:vapour).to_sym
          acc[id] = acc[vapour] = [ id, vapour ].freeze
        end
      end

      def validate!
        @resources.each do |id, spec|
          missing = REQUIRED_RESOURCE_KEYS.reject { |k| spec.key?(k) }
          raise Error, "resource #{id}: missing #{missing.join(', ')}" if missing.any?
        end

        @reactions.each do |id, spec|
          missing = REQUIRED_REACTION_KEYS.reject { |k| spec.key?(k) }
          raise Error, "reaction #{id}: missing #{missing.join(', ')}" if missing.any?

          validate_stoichiometry!(id, spec)
          validate_pathways!(id, spec)
        end


        @archetypes.each do |id, spec|
          missing = REQUIRED_ARCHETYPE_KEYS.reject { |k| spec.key?(k) }
          raise Error, "archetype #{id}: missing #{missing.join(', ')}" if missing.any?
        end

        @minions.each do |id, spec|
          missing = REQUIRED_MINION_KEYS.reject { |k| spec.key?(k) }
          raise Error, "minion #{id}: missing #{missing.join(', ')}" if missing.any?

          # An individual naming a race that does not exist is a person with no stats at all.
          # Caught here rather than at the moment somebody tries to work a lever with them.
          archetype = spec.fetch(:archetype).to_sym
          next if @archetypes.key?(archetype)

          raise Error, "minion #{id}: unknown archetype #{archetype.inspect}"
        end
      end

      # An unbalanced reaction creates or destroys matter every time it fires, which would break
      # the conservation spec from inside the content files — somewhere nobody would think to
      # look. Cheaper to reject it at boot. Runs once per pathway, because an alternative is a
      # whole reaction and has to balance on its own.
      def validate_stoichiometry!(id, spec, label = nil)
        where = [ "reaction #{id}", label ].compact.join(" ")

        (spec.fetch(:consumes).keys + spec.fetch(:produces).keys).each do |r|
          raise Error, "#{where}: unknown resource #{r}" unless @resources.key?(r)
        end

        consumed = spec.fetch(:consumes).values.sum(&:to_f)
        produced = spec.fetch(:produces).values.sum(&:to_f)
        return if (consumed - produced).abs <= 1e-9

        raise Error, "#{where}: mass not conserved — consumes #{consumed}, produces #{produced}"
      end

      # **Alternatives are other fates for the same kilogram of fuel**, and this is what makes
      # that true rather than merely intended. Every pathway must consume the same quantity of
      # everything the preferred one does, except the reagent whose scarcity picks between them
      # — otherwise their extents are not commensurable and splitting one between them is
      # arithmetic about nothing.
      #
      # A pathway may still name reagents the preferred one does not; see
      # `Resources::Reaction.extra_reagent_cap`, which is a seam.
      def validate_pathways!(id, spec)
        alternatives = Array(spec[:alternatives])
        return if alternatives.empty?

        gate = spec[:limited_by]&.to_sym
        raise Error, "reaction #{id}: alternatives need limited_by" if gate.nil?

        anchors = spec.fetch(:consumes).reject { |resource, _| resource == gate }
        unless spec.fetch(:consumes).key?(gate)
          raise Error, "reaction #{id}: limited_by #{gate}, which it does not consume"
        end
        if anchors.empty?
          raise Error, "reaction #{id}: consumes nothing but #{gate}, so nothing sets its extent"
        end

        validate_alternatives!(id, spec, alternatives, gate, anchors)
      end

      def validate_alternatives!(id, spec, alternatives, gate, anchors)
        # Ordered most-of-the-gated-reagent first, because the cascade spends supply on the
        # cleanest pathway that can still afford the rest and reads them in order. Declaring
        # them the other way round would quietly never reach the cheap one.
        appetite = spec.fetch(:consumes)[gate].to_f

        alternatives.each_with_index do |pathway, i|
          label = "alternative #{i + 1}"
          missing = REQUIRED_PATHWAY_KEYS.reject { |k| pathway.key?(k) }
          raise Error, "reaction #{id} #{label}: missing #{missing.join(', ')}" if missing.any?

          validate_stoichiometry!(id, pathway, label)
          validate_anchors!(id, label, pathway, anchors)

          wants = pathway.fetch(:consumes)[gate].to_f
          if wants > appetite
            raise Error, "reaction #{id} #{label}: wants #{wants} #{gate} where the pathway " \
                         "before it wants #{appetite} — alternatives run most-first"
          end

          appetite = wants
        end
      end

      def validate_anchors!(id, label, pathway, anchors)
        anchors.each do |resource, ratio|
          got = pathway.fetch(:consumes)[resource].to_f
          next if (got - ratio).abs <= 1e-9

          raise Error, "reaction #{id} #{label}: consumes #{got} #{resource} where the " \
                       "preferred pathway consumes #{ratio} — every pathway is a different " \
                       "fate for the same #{resource}, so only limited_by may vary"
        end
      end

      # Layers one and two: a race's baseline, offset by the individual's own sheet.
      #
      # **Deliberately NOT settled here.** Training and equipment are layers three and four and
      # are folded at build by `Crew`, so clamping now would make the order of the layers matter
      # — a penalty floored at zero before a bonus landed would give a different worker from the
      # same kit in a different order. `Sheet.settle` runs once, after all four.
      # **`mass_kg` is fetched without a default on purpose.** A race that does not say what its
      # people weigh raises here, at boot, rather than being quietly taken for a human — see
      # `Sheet::MIN_MASS_KG`. The individual's entry is an *offset* and so is optional: absent
      # means they weigh what their race weighs.
      def build_sheet(id)
        spec = @minions.fetch(id)
        base = archetype(spec.fetch(:archetype))
        baseline = Sheet::STATS.to_h { |stat| [ stat, base.fetch(stat).to_f ] }
        mass = base.fetch(:mass_kg) { raise Error, missing_mass(spec) }.to_f

        { name: spec.fetch(:name),
          archetype: spec.fetch(:archetype).to_sym,
          mass_kg: mass + spec.fetch(:mass_kg, 0.0).to_f,
          stats: Sheet.add_stats(baseline, spec.fetch(:stats, {})).freeze,
          tags: Sheet.add_tags(base.fetch(:tags, {}), spec.fetch(:tags, {})).freeze }.freeze
      end

      def missing_mass(spec)
        "archetype #{spec.fetch(:archetype).inspect}: no mass_kg. Every race declares what its " \
          "people weigh, in kilograms — it is read by the lift limit and the burden ratio, and a " \
          "default would be invisible in the content."
      end
    end
  end
end
