# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A bung of soft metal that melts, and having melted **stays melted**.
    #
    # Screwed through the crown sheet of every locomotive boiler of the period. While water
    # covers the plate the plug is cooled with it; uncover the plate and the plug is the first
    # thing to go, dumping steam down onto the fire. It is loud, it is filthy, it puts the fire
    # out, and it is very much better than the alternative.
    #
    # ## Why this is not a `ReliefValve`
    #
    # It looks like one — it senses a quantity on another node and opens above a threshold — and
    # it was very nearly written as one. But a relief valve **re-seats**, and that single
    # difference is the whole character of the part. A safety valve is a control: it holds a
    # pressure, it lifts and shuts a hundred times a shift, and a driver works with it. A fusible
    # plug is a *fuse*: it operates once, it cannot be undone from the footplate, and the engine
    # is out of service until somebody fits a new one.
    #
    # Modelling it as a reversible valve would have given a boiler that quietly healed itself the
    # moment the water came back over the plate — which is exactly the reassuring, consequence-free
    # behaviour the low-water hazard exists to not have. **A device whose defining property is
    # that it is irreversible must not be built on one that is reversible**, however similar the
    # opening rule looks.
    #
    # So the melt is latched in state. `melted` goes true and never goes back, and the path opens
    # and stays open. Snapshot-safe, because it is one boolean in the node's own state.
    #
    # ## Generic, despite the name
    #
    # Anything that senses a quantity elsewhere and fails permanently open fits this: a rupture
    # disc on a chemical reactor, a shear pin, a thermal cut-out. `senses_key:` and
    # `melts_above:` carry no units of their own — the sensed node decides what the number means.
    #
    # ## It senses a recorded state KEY, not a method, unlike `ReliefValve`
    #
    # `ReliefValve` takes `senses_quantity:` and `Context#node_reading` calls that method as
    # `node.public_send(quantity, state, content)`. That works for anything a node can derive
    # from its own contents — a pressure, a temperature — and it **cannot** work for a quantity
    # that is itself a cross-node read. The crown sheet's temperature depends on the firebox, so
    # `Boiler#crown_temperature_k` needs the tick context and has the wrong arity for
    # `node_reading` entirely; handing it `content` where it expects `ctx` fails at the first
    # call.
    #
    # So the boiler records the value in its own state and this reads the key, which is the same
    # thing `Conduit#blast_pa` already does with the cylinder's `exhaust_kg`. One node owns the
    # derivation, everyone else reads the number. The cost is the usual one tick of lag, which is
    # the standard cross-node contract here and not a special case.
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

      # Shut until it has melted, then open for good.
      #
      # Reads its **own** previous-tick state, because `open_fraction` is handed only the context
      # — the latch has to live somewhere both this and `apply` can see, and state is that place.
      # `super` keeps whatever lever the conduit carries, so a plug can still be isolated by a
      # valve in the same line; nothing about a lever can un-melt it.
      def open_fraction(ctx)
        return 0.0 unless ctx.node_state(id)&.fetch(:melted, false)

        super
      end

      # The latch. Reads the previous tick through `ctx` exactly as every other cross-node read
      # does, so it is order-independent: whether the boiler has already been evaluated this tick
      # cannot change the answer.
      def apply(state, ctx, _grant)
        return state if state.fetch(:melted, false)

        sensed = sensed_value(ctx)
        return state if sensed.nil? || sensed <= @melts_above

        [ state.merge(melted: true),
          [ { type: :fusible_plug_melted, node: id, label: label, severity: :warning,
              tick: ctx.tick,
              detail: { senses: @senses, key: @senses_key,
                        reading: sensed.round(2), melts_above: @melts_above } } ] ]
      end

      def sensed_value(ctx) = ctx.node_state(@senses)&.fetch(@senses_key, nil)

      def melted?(state) = state.fetch(:melted, false)
    end
  end
end
