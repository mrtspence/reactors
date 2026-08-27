# frozen_string_literal: true

module ReactorSim
  module Nodes
    # The outside world: an unlimited reservoir at fixed pressure and temperature.
    #
    # Three distinct jobs, which is why it earns a node rather than a constant:
    #
    #   * a **source** of whatever the outside supplies — air, most often,
    #   * a **sink** for anything an operation vents or exhausts,
    #   * a **pressure reference** for machinery that works against ambient.
    #
    # The third is the one that could not be done any other way. A machine driven by the
    # difference between atmospheric pressure and a vacuum needs "atmosphere" to be
    # something it can be wired to, not a number buried in a formula.
    #
    # ## Conservation
    #
    # Everything crossing this boundary is written to the ledger — air drawn in counts as
    # `mass_added`, flue gas dumped counts as `mass_vented`. The node resets to its baseline
    # every tick, so the difference between what it holds and what it should hold is exactly
    # what crossed, and nothing can leak in or out unrecorded. This is the ledger design
    # doing the job it exists for (docs/simulation_architecture.md §8).
    class Atmosphere < Node
      include Concerns::Thermal
      include Concerns::Holds

      # Large enough that draw and room are effectively unlimited at any sane flow rate,
      # small enough that the totals stay readable in a spec failure.
      BASELINE_KG = 1.0e6

      attr_reader :volume_m3, :heat_capacity, :ambient_k, :pressure_pa_setting, :composition

      def initialize(id: :atmosphere, label: "Atmosphere",
                     ambient_k: Units::STANDARD_TEMPERATURE_K,
                     pressure_pa: Units::STANDARD_PRESSURE_PA,
                     composition: { air: BASELINE_KG }, ports: nil)
        super(
          id: id, label: label,
          ports: ports || [
            Port.new(id: :intake, direction: :outlet, accepts: [ :gas ]),
            Port.new(id: :exhaust, direction: :inlet)
          ]
        )
        @ambient_k = ambient_k.to_f
        @pressure_pa_setting = pressure_pa.to_f
        @composition = composition.freeze
        @volume_m3 = 1.0e9
        @heat_capacity = 1.0e12 # so nothing an operation does moves the outside temperature
        freeze
      end

      def initial_temperature_k = @ambient_k

      def holds_initial_state(_rng, content) = { parcels: baseline(content) }

      # Fixed by definition. The outside world does not pressurise because you vented into
      # it, and anything working against ambient needs this to be a dependable constant.
      def pressure_pa(_state, _content) = @pressure_pa_setting

      # Unlimited, by volume and by pressure alike. Whatever an operation pushes at the
      # sky, the sky takes.
      def room_m3(_state, _content) = Float::INFINITY

      def gas_headroom_kg(_state, _target_pa, _content, _resource) = Float::INFINITY

      def plan(_state, _ctx) = Intent.none

      # Restore the baseline and record what crossed. Positive delta means the operation
      # took air from outside; negative means it dumped something into it.
      #
      # **The structure's own energy is reset too, not just the contents.** That is not a
      # detail: this node has an enormous heat capacity so its temperature never budges, so
      # anything hot vented into it warmed it by about a millionth of a degree — which, at
      # 10¹² J/K, is nearly two megajoules a tick sitting in `joules` that nothing ledgered
      # and nothing could see. Resetting the parcels alone left it there to accumulate.
      def apply(state, ctx, _grant)
        held = state.fetch(:parcels)
        restored = baseline(ctx.content)
        baseline_joules = heat_capacity * @ambient_k

        mass_delta = Parcel.total_kg(restored) - Parcel.total_kg(held)
        joules_delta = (baseline_joules + Parcel.total_joules(restored)) -
                       (state.fetch(:joules) + Parcel.total_joules(held))

        state.merge(
          parcels: restored,
          joules: baseline_joules,
          mass_injected: [ mass_delta, 0.0 ].max,
          mass_vented: [ -mass_delta, 0.0 ].max,
          joules_injected: [ joules_delta, 0.0 ].max,
          joules_discarded: [ -joules_delta, 0.0 ].max
        )
      end

      private

      def baseline(content)
        Parcel.normalise(@composition.map { |resource, kg|
          Parcel.build(resource: resource, kg: kg, temperature_k: @ambient_k, content: content)
        })
      end
    end
  end
end
