# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A hole that is not there until it is.
    #
    # This is how a failed part actually spills, and it exists because **a node cannot open a
    # path in its own graph**. The graph is configuration: `Path.resolve` and `validate_graph!`
    # both run at construction, `options:` has to reproduce the shape from a snapshot, and a
    # failed part must not change the node list under a running tick. So the hole is built with
    # the machine, shut, and waits.
    #
    # That costs nothing. `Arbiter.gas_coupling` rejects any conductance at or below zero, so a
    # shut breach is not on any pressure solve; `throughput_kg` is zero, so it is on no rate
    # solve either. It is inert until the part it watches fails, exactly as `FusiblePlug` is
    # inert until the plate goes bare.
    #
    # ## Why it is not a `ReliefValve`, and barely a `FusiblePlug`
    #
    # Same defence as the plug, and for the same reason: **a device whose defining property is
    # that it is irreversible must not be built on one that is reversible.** A breach reads a
    # latch that never clears on its own, so it cannot heal — and when in-match repair arrives
    # and clears `failure`, it shuts again with no repair-side code at all, because it is a pure
    # function of what it senses.
    #
    # The difference from the plug is what the two *mean*. A fusible plug is a safety device
    # that operates deliberately and is meant to save the boiler. A breach is damage. That is
    # why they book to different ledger lines: a plug discharging is `mass_vented`, a breach is
    # `mass_spilled`, and reporting them as one number would make every efficiency figure built
    # on the ledger a lie.
    #
    # ## Size is per mode, because that is the whole spectrum
    #
    # `opens_by:` maps each of the sensed part's failure modes to the fraction of full bore it
    # opens. A seam split weeps and lets the machine limp on; a shell letting go empties the
    # drum. **A mode this does not name opens nothing**, which is what lets one part carry
    # several breaches of different sizes — escalating damage is simply a second, larger hole
    # naming the worse mode.
    #
    # ## Where it spills is a link, not a setting
    #
    # There is no `to:` here on purpose. The destination is the outlet's link, which is already
    # how every other route in this engine is expressed, so pointing a breach at a room rather
    # than at the sky later changes nothing about this class. Today they all link to
    # `Atmosphere`'s `:spill` inlet. See docs/design_sketches/failure_model.md §9–§10.
    class Breach < Conduit
      attr_reader :senses, :opens_by

      # Always a check valve. A hole lets contents out; the graph must never breathe in
      # through one.
      def initialize(id:, senses:, opens_by:, **options)
        super(id: id, one_way: true, **options)
        @senses = senses.to_sym
        @opens_by = opens_by.to_h { |mode, fraction| [ mode.to_sym, fraction.to_f ] }.freeze
        freeze
      end

      # **No `super`, unlike `FusiblePlug`.** A conduit's `open_fraction` applies its lever and
      # its trim, and a hole in a casting has neither — there is nothing on the footplate that
      # closes it. Isolating a burst section is a real thing a driver can do, but it is done
      # with a valve *elsewhere on the line*, which is its own part on its own path.
      #
      # Reads the sensed node's previous tick through `ctx`, like every other cross-node read,
      # so it is order-independent: whether the boiler has already been evaluated this tick
      # cannot change the answer.
      def open_fraction(ctx)
        mode = ctx.node_state(@senses)&.fetch(:failure, nil)
        return 0.0 if mode.nil?

        @opens_by.fetch(mode, 0.0)
      end

      def open?(ctx) = open_fraction(ctx).positive?

      # **No `apply`, and no ledger writing of its own.** A breach is a transport node, so
      # `Path` resolves straight through it and the mass goes from the failed holder to
      # whatever is on the far side — it never stops here to be counted. `Atmosphere` books
      # what arrives by the port it arrives on, which is why the link goes to `:spill`.
      #
      # That also means a breach spilling into another node *inside* the graph — a room, once
      # there is such a thing — correctly writes no ledger line at all, because nothing has
      # left the operation. The contents are somewhere inconvenient, not gone.
    end
  end
end
