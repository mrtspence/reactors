# frozen_string_literal: true

module ReactorSim
  module Resources
    # **What happens faster than a tick is resolved, not integrated** — the same call phase change
    # makes. A reaction declaring `prompt: { kind: }` names one of these; each kind answers
    # `triggered?` and `resolve` over a node's parcels, and `Concerns::PromptReaction` runs them in
    # sequence. See `docs/design_sketches/prompt-reactions.md`.
    module Prompt
      # TODO: first callers beyond `:deflagration` are a fuel–coolant interaction (molten metal
      # into water, the foundry) and prompt criticality (the reactor). Only `:deflagration` is
      # registered or tested; the next kind is the first to exercise the table.
      KINDS = { deflagration: Deflagration }.freeze

      module_function

      def kind(spec) = KINDS.fetch(spec.dig(:prompt, :kind).to_sym)

      def validate!(id, spec)
        kind = spec.dig(:prompt, :kind)&.to_sym
        raise Error, "reaction #{id}: unknown prompt kind #{kind.inspect}" unless KINDS.key?(kind)

        KINDS.fetch(kind).validate!(id, spec)
      end
    end
  end
end
