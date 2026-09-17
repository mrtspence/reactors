# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A hole that is not there until it is — how a failed part spills.
    #
    # It exists because **a node cannot open a path in its own graph**: `Path.resolve` and
    # `validate_graph!` run at construction, `options:` must reproduce the shape from a snapshot,
    # and a failed part must not change the node list under a running tick. So the hole is built
    # with the machine, shut, and waits. That costs nothing — `Arbiter.gas_coupling` rejects a
    # conductance at or below zero and `throughput_kg` is zero, so a shut breach is on no solve
    # of either kind.
    #
    # It reads a latch that never clears on its own, so it cannot heal; when in-match repair
    # clears `failure` it shuts again with no repair-side code, being a pure function of what it
    # senses. It is **damage**, not a safety device, which is why it books `mass_spilled` where a
    # `FusiblePlug` books `mass_vented` — one number for both would make every efficiency figure
    # built on the ledger a lie.
    #
    # **`opens_by:` is per mode.** A seam split weeps and lets the machine limp on; a shell
    # letting go empties the drum. A mode it does not name opens nothing, which lets one part
    # carry several breaches of escalating size.
    #
    # **Where it spills is a link, not a setting.** The destination is the outlet's link, so
    # pointing a breach at a room rather than the sky later changes nothing here.
    #
    # **Whose failure opens it and what it drains are separate questions.** `senses:` is the part
    # that broke; the inlet link is the holder that empties. That is what makes a *conduit*
    # rupture expressible at all, since a conduit holds nothing and has no contents to lose — and
    # which holder it drains says where along the line the rupture is: upstream, and the leak
    # continues whatever the driver shuts; downstream, and closing the valve isolates it.
    #
    # > **Never express the leak as a throughput derating on the conduit.** A hole does not
    # > narrow a bore, and material a conduit declines to pass does not spill — it stays upstream
    # > as back-pressure. Nothing reaches `Atmosphere`, nothing lands on `mass_spilled`, and the
    # > loss hides inside a term where it can be neither sized nor pointed anywhere. A rupture
    # > may *also* derate what the damaged pipe delivers, but that is a separate effect.
    #
    # See `docs/design_sketches/failure_model.md` §9–§10.
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
      # trim, and a hole in a casting has neither — isolating a burst section is done with a
      # valve elsewhere on the line, which is its own part on its own path.
      #
      # Reads the sensed node's previous tick, so it is order-independent.
      def open_fraction(ctx)
        mode = ctx.node_state(@senses)&.fetch(:failure, nil)
        return 0.0 if mode.nil?

        @opens_by.fetch(mode, 0.0)
      end

      def open?(ctx) = open_fraction(ctx).positive?

      # **No `apply`, and no ledger line of its own.** A breach is a transport node, so `Path`
      # resolves through it and the mass never stops here to be counted; `Atmosphere` books what
      # arrives by the port it arrives on, which is why the link goes to `:spill`. A breach
      # spilling into another node inside the graph therefore writes no ledger line at all,
      # which is right: the contents are somewhere inconvenient, not gone.
    end
  end
end
