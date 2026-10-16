# frozen_string_literal: true

module ReactorSim
  module Concerns
    # **A node where something can happen faster than a tick.** Inert unless the node hosts a
    # reaction declaring `prompt:`; then each tick, before its reactions run at their rates, phase 5
    # asks whether any of those would complete inside the tick, and if so resolves it here from what
    # the node holds (`Resources::Prompt`).
    #
    # **Resolved in sequence**: after each, every prompt reaction not yet resolved this tick is
    # asked again against the node as it now is — its products, its heat, the air it left — and a
    # front that has passed lights every other fuel in range. Declaration order breaks ties, and
    # each reaction resolves at most once a tick, which is what bounds the loop.
    module PromptReaction
      # What an `:explosion` reports in its `detail:`, which a hazard keyed on it may scale with.
      EXPLOSION_DETAIL = %i[reactions fuel_kg joules].freeze

      # **A blast hurts whoever is in it at the moment it happens**: `endangers: { explosion: … }`
      # on the node, spent in phase 6b off the `:explosion` event exactly as a failure's hazard is
      # off its `:part_failed`. Only a node hosting a prompt reaction can enter it.
      def prompt_modes(content)
        reactions.any? { |id| content.reaction(id)&.key?(:prompt) } ? { explosion: {} } : {}
      end

      # Returns [state, resolved reaction ids, events]. The state's `joules_from_reactions`
      # accumulates what was released, as `Tick#run_reactions` does.
      def resolve_prompt(state, ctx)
        content = ctx.content
        prompt = reactions.select { |id| content.reaction(id)&.key?(:prompt) }
        resolved = []
        fuel_kg = 0.0
        released = 0.0

        while (id = next_prompt(prompt - resolved, state, ctx, front: resolved.any?))
          spec = content.reaction(id)
          parcels, joules, burnt = Resources::Prompt.kind(spec).resolve(spec, state.fetch(:parcels),
                                                                       content: content,
                                                                       share: carried(state, content, id))
          resolved << id
          fuel_kg += burnt
          released += joules
          state = rebalance(state.merge(parcels: parcels, joules: state.fetch(:joules) + joules,
                                        joules_from_reactions: state.fetch(:joules_from_reactions, 0.0) + joules,
                                        ignition: unlit(state, id)), content)
        end

        [ state, resolved, explosion(resolved, fuel_kg, released, ctx) ]
      end

      private

      # **What the node's throttle means for something with no rate**: the share of the mixture a
      # front can carry through. A dust cloud that is two-thirds stone carries none.
      def carried(state, content, id) = reaction_throttle(state, content, id).clamp(0.0, 1.0)

      def next_prompt(candidates, state, ctx, front:)
        candidates.find do |id|
          next false if carried(state, ctx.content, id) <= Parcel::EPSILON

          spec = ctx.content.reaction(id)
          ignition = state.fetch(:ignition, {}).fetch(id, nil) || Resources::Ignition.initial_state
          Resources::Prompt.kind(spec).triggered?(spec, ignition, state.fetch(:parcels),
                                                  dt: ctx.dt, content: ctx.content, front: front)
        end
      end

      # What a front burnt is gone; anything of that fuel left over is out of its range and unlit.
      def unlit(state, id)
        ignition = state.fetch(:ignition, {})
        held = ignition.fetch(id, nil) || Resources::Ignition.initial_state
        ignition.merge(id => held.merge(kg: 0.0).freeze).freeze
      end

      def explosion(resolved, fuel_kg, joules, ctx)
        return [] if resolved.empty? || fuel_kg <= Parcel::EPSILON

        [ Event.build(type: :explosion, node: id, label: label, severity: :critical, tick: ctx.tick,
                      mode: :explosion, cause: ctx.room_ignition(id)&.fetch(:cause, nil) || :self_ignition,
                      detail: { reactions: resolved, fuel_kg: fuel_kg.round(3), joules: joules.round }) ]
      end
    end
  end
end
