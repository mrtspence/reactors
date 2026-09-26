# frozen_string_literal: true

module ReactorSim
  module Nodes
    # **Where the operation's output goes.** Screens at the pit bank, a gas main, a pipeline
    # outlet, a wagon on the weighbridge.
    #
    # Shaped like `Atmosphere` — a bottomless sink that resets to empty each tick and books what
    # crossed from the grant rather than from a before/after delta — and separate from it for one
    # reason: **what leaves here left because the operation did its job.** Venting a relief valve
    # and sending a shift's coal to the surface must not be the same number, which is the same
    # argument that gives `Atmosphere` two inlets rather than one.
    #
    # It is the first and only writer of `mass_delivered`, the ledger line reserved for this
    # since driven transport landed.
    #
    # **It is not a pressure reference and not a source.** An operation that wants the outside
    # world still needs an `Atmosphere`; this is the loading dock, not the sky.
    class Delivery < Node
      include Concerns::Thermal
      include Concerns::Holds

      attr_reader :volume_m3, :heat_capacity, :ambient_k

      def initialize(id:, label: nil, accepts: [], ambient_k: Units::STANDARD_TEMPERATURE_K)
        super(
          id: id, label: label,
          ports: [ Port.new(id: :in, direction: :inlet, accepts: accepts) ]
        )
        @ambient_k = ambient_k.to_f
        # Bottomless, for the same reason `Atmosphere` is: a sink that can back up is a
        # restriction, and the restriction belongs on the conduit feeding it.
        @volume_m3 = 1.0e9
        @heat_capacity = 1.0e12
        freeze
      end

      def initial_temperature_k = @ambient_k

      def holds_initial_state(_rng, _content) = { parcels: [].freeze }

      def room_m3(_state, _content) = Float::INFINITY

      def gas_headroom_kg(_state, _target_pa, _content, _resource) = Float::INFINITY

      def mole_capacity_per_pa(_state, _content)
        @volume_m3 / (Units::GAS_CONSTANT * @ambient_k)
      end

      def plan(_state, _ctx) = Intent.none

      # Empty again, and the load is on the books.
      #
      # **The structure's energy is reset alongside the parcels**, exactly as `Atmosphere` learnt
      # to: at a heat capacity this large, warm material arriving moves the temperature by a
      # millionth of a degree and leaves megajoules sitting in `joules` that nothing ledgered.
      def apply(state, _ctx, grant)
        state.merge(
          parcels: [].freeze,
          joules: heat_capacity * @ambient_k,
          mass_delivered: grant.received_kg(:in),
          joules_discarded: grant.total_received_joules
        )
      end
    end
  end
end
