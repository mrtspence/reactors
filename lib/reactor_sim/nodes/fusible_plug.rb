# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A bung of soft metal that melts, and having melted **stays melted**. While water covers the
    # crown sheet the plug is cooled with it; uncover the plate and this is the first thing to
    # go, dumping steam onto the fire.
    #
    # **Not a `ReliefValve`, because a relief valve re-seats**, and that single difference is the
    # whole character of the part. A safety valve is a control a driver works with; a plug is a
    # fuse that operates once and puts the engine out of service. Built on the reversible one, a
    # boiler would quietly heal itself the moment the water came back over the plate — exactly the
    # consequence-free behaviour the low-water hazard exists to prevent. **A device whose defining
    # property is irreversibility must not be built on one that is reversible**, however similar
    # the opening rule looks. The melt is latched in state instead: one boolean, snapshot-safe.
    #
    # **It actually melts**, through `Concerns::Fusible` — a real mass of soft alloy with a real
    # latent heat, which runs out and cannot come back. It used to be a boolean latched against a
    # configured threshold, and the conversion deleted the threshold (the alloy's own melting
    # point replaces it), the boolean (an inventory replaces it) and a whole failure mode where
    # the two could disagree with the material they were supposed to describe.
    #
    # **`senses:` is physics, not a workaround.** A plug is screwed *through* the crown sheet, so
    # the plate's temperature is the one that melts it and its own bulk temperature is beside the
    # point. That is why it overrides `fusible_temperature_k` rather than using its own.
    #
    # **It senses a recorded state KEY, not a method, unlike `ReliefValve`.** `node_reading` calls
    # `node.public_send(quantity, state, content)`, which works for anything a node derives from
    # its own contents and cannot work for a quantity that is itself a cross-node read:
    # `Boiler#crown_temperature_k` needs the tick context and has the wrong arity entirely. So the
    # boiler records the value in its own state and this reads the key. One node owns the
    # derivation, everyone else reads the number, at the usual cost of one tick of lag.
    class FusiblePlug < Conduit
      include Concerns::Fusible

      attr_reader :senses, :senses_key, :plug_kg

      # Always a check valve. Steam goes out through a blown plug; the firebox must never push
      # flue gas back into the drum through one.
      #
      # `material:` carries the melting point now, so there is no `melts_above:` to disagree with
      # it — a plug made of `fusible_alloy` melts at what `fusible_alloy` melts at.
      def initialize(id:, senses:, senses_key:, plug_kg: 0.05, **options)
        super(id: id, one_way: true, **options)
        @senses = senses.to_sym
        @senses_key = senses_key.to_sym
        @plug_kg = plug_kg.to_f
        freeze
      end

      def fusible_kg = @plug_kg

      def initial_state(rng, content)
        super.merge(melted: false).freeze
      end

      # The plate's temperature, not its own. See the class comment.
      def fusible_temperature_k(_state, ctx) = sensed_value(ctx).to_f

      # **Opens as it melts, rather than all at once.** A plug does not vanish on a threshold; it
      # runs, and a partly-run plug passes part of what a gone one does. `super` keeps whatever
      # lever the conduit carries, so a plug can still be isolated by a valve in the same line —
      # but no lever can un-melt it, because the metal is gone.
      def open_fraction(ctx)
        melted = melted_fraction(ctx.node_state(id) || {})
        melted.positive? ? super * melted : 0.0
      end

      # Melts whatever the plate's heat pays for. **The event fires on the first drop**, not on
      # the last: a plug that has started to go has already failed at its job of staying put, and
      # a driver needs telling then rather than when it finishes.
      def apply(state, ctx, _grant)
        before = state.fetch(:fusible_remaining_kg, fusible_kg)
        melted = run_melt(state, ctx)
        # `melted:` is kept in state because the panel's `plug_blown` lamp is a `Sources::Flag`,
        # which reads a state key and cannot call a method. Derived here rather than stored as
        # the truth — the metal left is the truth.
        melted = melted.merge(melted: melted_fraction(melted).positive?)
        return melted unless before >= fusible_kg && melted.fetch(:fusible_remaining_kg) < before

        [ melted,
          [ Event.build(type: :fusible_plug_melted, node: id, label: label, severity: :warning,
                        tick: ctx.tick,
                        detail: { senses: @senses, key: @senses_key,
                                  reading: sensed_value(ctx).to_f.round(2),
                                  melts_at: melting_point_k(ctx.content).round(2) }) ] ]
      end

      def sensed_value(ctx) = ctx.node_state(@senses)&.fetch(@senses_key, nil)

      def melted?(state) = melted_fraction(state).positive?
    end
  end
end
