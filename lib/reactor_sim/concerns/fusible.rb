# frozen_string_literal: true

module ReactorSim
  module Concerns
    # A part made of something with a melting point, given more heat than it can shed.
    #
    # **This is what bounds a runaway, and it does it with physics rather than a clamp.** A part
    # with nowhere to put its heat climbs until conduction to ambient matches what is going in —
    # which for a seized bearing is the whole output of the engine driving it, and lands wherever
    # the arithmetic happens to land. A real one stops climbing because its metal melts and runs
    # out, and the melt takes its latent heat with it.
    #
    #   config: fusible_kg, and a `material:` that declares a latent heat of fusion
    #   state:  fusible_remaining_kg
    #
    # **The lining is a separate inventory from `Holds`.** A bearing's oil is cargo it can be
    # refilled with; its white metal is what it is made of. Putting the lining in `parcels` would
    # make it drawable down a pipe and would let an oil round pour babbitt back in.
    #
    # **Which temperature melts it is the part's business.** A bearing melts at its own bulk
    # temperature. A fusible plug is screwed *through* the crown sheet, so the plate's temperature
    # is the one that matters and its own bulk is beside the point — it overrides
    # `fusible_temperature_k` to say so.
    module Fusible
      def fusible_initial_state(_rng, _content)
        { fusible_remaining_kg: fusible_kg }
      end

      def fusible_kg = 0.0

      # How much has run out, 0.0 sound and 1.0 nothing left. Never shown as a number — it is
      # banded into prose the way integrity is.
      def melted_fraction(state)
        return 0.0 unless fusible_kg.positive?

        1.0 - (state.fetch(:fusible_remaining_kg, fusible_kg) / fusible_kg).clamp(0.0, 1.0)
      end

      def melted_out?(state)
        fusible_kg.positive? && state.fetch(:fusible_remaining_kg, fusible_kg) <= 0.0
      end

      # Melts whatever the excess heat pays for, and returns the state with that energy gone.
      #
      # **Latent heat only, and mass is deliberately not booked.** A part's substance is its
      # `heat_capacity`, and structure mass has never been part of `Operation#total_mass` — only
      # parcels are. Reporting `mass_consumed` for melted metal would therefore declare mass
      # leaving that was never counted as present, and every conservation spec would fail with
      # the ledger blaming the wrong thing. What *is* tracked is the energy, so that is what
      # leaves: the latent heat goes out with the melt through `joules_discarded`.
      #
      # That is also the whole mechanism. Energy which would have raised the part past its
      # melting point turns solid into liquid instead, so the temperature stops climbing — the
      # same trick `Resources::Saturation` uses for the boiling plateau.
      def run_melt(state, ctx)
        kg = melt_kg(state, ctx)
        return state if kg <= 0.0

        joules = kg * latent_heat_j_per_kg(ctx.content)

        state.merge(
          fusible_remaining_kg: state.fetch(:fusible_remaining_kg, fusible_kg) - kg,
          joules: state.fetch(:joules, 0.0) - joules,
          joules_discarded: state.fetch(:joules_discarded, 0.0) + joules
        )
      end

      # What this tick's excess heat can melt, bounded three ways: by how far past the melting
      # point the part is, by how much lining is left, and by **how much energy the part actually
      # holds**. The last one matters for a part melted by somebody else's heat — a plug reads the
      # crown sheet's temperature, not its own, and without the bound would melt itself using
      # energy it does not have and go below absolute zero doing it.
      #
      # `total_heat_capacity` rather than the bare figure, because a bearing full of oil takes
      # more energy per kelvin than an empty one.
      def melt_kg(state, ctx)
        remaining = state.fetch(:fusible_remaining_kg, fusible_kg)
        return 0.0 unless remaining.positive?

        over = fusible_temperature_k(state, ctx) - melting_point_k(ctx.content)
        return 0.0 unless over.positive?

        latent = latent_heat_j_per_kg(ctx.content)
        return 0.0 if latent.infinite? || !latent.positive?

        affordable = [ state.fetch(:joules, 0.0), 0.0 ].max / latent
        [ over * total_heat_capacity(state, ctx.content) / latent, remaining, affordable ].min
      end

      # The temperature that decides whether this melts. Its own, unless the part says otherwise.
      def fusible_temperature_k(state, ctx) = temperature_k(state, ctx.content)

      def melting_point_k(content) = rated_temperature_k(content)

      def latent_heat_j_per_kg(content)
        material.nil? ? Float::INFINITY : content.latent_heat_of_fusion_j_per_kg(material)
      end
    end
  end
end
