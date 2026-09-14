# frozen_string_literal: true

module ReactorSim
  # Registry of parts, keyed by id, exactly as `Operations` is keyed by type.
  #
  # **Parts are code, permanently, and that is a decision rather than an expedient.** The
  # obvious alternative is content YAML alongside materials and reactions, and its real pull
  # was never diffability — it was letting someone outside this repository add a part. That is
  # ruled out: authorship stays in-house. What is left of the YAML case is a split between a
  # number and the sweep that chose it, paid for nothing, on a codebase whose most valuable
  # property is that `damper_conductance: 0.35` ships with the seven-point measurement above
  # it.
  #
  # The one real cost — comparing eight boilers means reading eight methods — is answered by
  # DERIVING a table from `Part#stats` rather than hand-maintaining one, so it cannot drift
  # from the constructors.
  #
  # See `docs/design_sketches/modular_components.md` §3.
  module Parts
    @parts = {}

    class << self
      def register(id, kind:, label: nil, description: nil, stats: {},
                   provides: [], instruments: [], wip: false, &builder)
        part = Part.new(id: id, kind: kind, label: label, description: description,
                        stats: stats, provides: provides, instruments: instruments,
                        wip: wip, &builder)

        # Ids are the address a loadout uses, so a silent overwrite would mean a snapshot
        # rebuilding a different machine from the same name.
        if @parts.key?(part.id) && !@parts.fetch(part.id).equal?(part)
          raise Error, "part #{part.id} is already registered (as kind " \
                       "#{@parts.fetch(part.id).kind})"
        end

        @parts[part.id] = part
      end

      def fetch(id)
        @parts.fetch(id.to_sym) do
          raise Error, "unknown part: #{id.inspect} (known: #{known.sort.join(', ')})"
        end
      end

      def key?(id) = @parts.key?(id.to_sym)

      # Everything that fits a given slot kind. The outfitting screen's list of alternatives.
      def of_kind(kind) = @parts.values.select { |p| p.kind == kind.to_sym }

      def known = @parts.keys

      # Specs build throwaway registries; without this they leak into each other.
      def reset! = @parts = {}
    end
  end
end
