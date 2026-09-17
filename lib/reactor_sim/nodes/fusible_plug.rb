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
    # **Generic, despite the name.** Anything that senses a quantity elsewhere and fails
    # permanently open fits: a rupture disc, a shear pin, a thermal cut-out. `senses_key:` and
    # `melts_above:` carry no units — the sensed node decides what the number means.
    #
    # **It senses a recorded state KEY, not a method, unlike `ReliefValve`.** `node_reading` calls
    # `node.public_send(quantity, state, content)`, which works for anything a node derives from
    # its own contents and cannot work for a quantity that is itself a cross-node read:
    # `Boiler#crown_temperature_k` needs the tick context and has the wrong arity entirely. So the
    # boiler records the value in its own state and this reads the key. One node owns the
    # derivation, everyone else reads the number, at the usual cost of one tick of lag.
    class FusiblePlug < Conduit
      attr_reader :senses, :senses_key, :melts_above

      # Always a check valve. Steam goes out through a blown plug; the firebox must never push
      # flue gas back into the drum through one.
      def initialize(id:, senses:, senses_key:, melts_above:, **options)
        super(id: id, one_way: true, **options)
        @senses = senses.to_sym
        @senses_key = senses_key.to_sym
        @melts_above = melts_above.to_f
        freeze
      end

      def initial_state(rng, content)
        super.merge(melted: false).freeze
      end

      # Shut until it has melted, then open for good. Reads its **own** previous-tick state,
      # because `open_fraction` is handed only the context. `super` keeps whatever lever the
      # conduit carries, so a plug can be isolated by a valve in the same line — but no lever can
      # un-melt it.
      def open_fraction(ctx)
        return 0.0 unless ctx.node_state(id)&.fetch(:melted, false)

        super
      end

      # The latch. Reads the previous tick, so it is order-independent.
      def apply(state, ctx, _grant)
        return state if state.fetch(:melted, false)

        sensed = sensed_value(ctx)
        return state if sensed.nil? || sensed <= @melts_above

        [ state.merge(melted: true),
          [ Event.build(type: :fusible_plug_melted, node: id, label: label, severity: :warning,
                        tick: ctx.tick,
                        detail: { senses: @senses, key: @senses_key,
                                  reading: sensed.round(2), melts_above: @melts_above }) ] ]
      end

      def sensed_value(ctx) = ctx.node_state(@senses)&.fetch(@senses_key, nil)

      def melted?(state) = state.fetch(:melted, false)
    end
  end
end
