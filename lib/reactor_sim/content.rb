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
          minions: read_all(File.join(dir, "minions"))
        ).freeze
      end

      # Test seam: build a registry from literals with no filesystem involved. Every keyword
      # defaults, so a spec asks for the one table it cares about and gets empty ones for the
      # rest — which is what keeps an unrelated substance from boiling mid-test.
      def build(resources: {}, reactions: {}, minions: {})
        Registry.new(resources: deep_sym(resources), reactions: deep_sym(reactions),
                     minions: deep_sym(minions)).freeze
      end

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
      REQUIRED_RESOURCE_KEYS = %i[specific_heat_j_per_kg_k density_kg_per_m3].freeze
      REQUIRED_REACTION_KEYS = %i[consumes produces rate_per_s enthalpy_j_per_unit].freeze
      REQUIRED_MINION_KEYS   = %i[label strength].freeze

      attr_reader :resources, :reactions, :minions

      def initialize(resources:, reactions:, minions: {})
        @resources = resources.freeze
        @reactions = reactions.freeze
        @minions = minions.freeze
        @phase_pairs = index_phase_pairs.freeze
        @tags = @resources.to_h { |id, spec| [ id, spec.fetch(:tags, []).map(&:to_sym).freeze ] }.freeze
        validate!
      end

      def resource(id)
        @resources.fetch(id.to_sym) { raise Error, "unknown resource: #{id.inspect}" }
      end

      def reaction(id)
        @reactions.fetch(id.to_sym) { raise Error, "unknown reaction: #{id.inspect}" }
      end

      def minion_archetype(id)
        @minions.fetch(id.to_sym) { raise Error, "unknown minion archetype: #{id.inspect}" }
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

          (spec.fetch(:consumes).keys + spec.fetch(:produces).keys).each do |r|
            raise Error, "reaction #{id}: unknown resource #{r}" unless @resources.key?(r)
          end

          # An unbalanced reaction creates or destroys matter every time it fires, which
          # would break the conservation spec from inside the content files — somewhere
          # nobody would think to look. Cheaper to reject it at boot.
          consumed = spec.fetch(:consumes).values.sum(&:to_f)
          produced = spec.fetch(:produces).values.sum(&:to_f)
          next if (consumed - produced).abs <= 1e-9

          raise Error, "reaction #{id}: mass not conserved — consumes #{consumed}, produces #{produced}"
        end

        @minions.each do |id, spec|
          missing = REQUIRED_MINION_KEYS.reject { |k| spec.key?(k) }
          raise Error, "minion #{id}: missing #{missing.join(', ')}" if missing.any?
        end
      end
    end
  end
end
