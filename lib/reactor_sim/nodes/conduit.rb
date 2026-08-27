# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A join that earned its place in the graph.
    #
    # Most joins are edges and cost nothing. A join becomes a node when it is *interesting*
    # — it carries a control point, it can fail, or it restricts flow
    # (docs/simulation_architecture.md §5). A valve, a pump, a section of pipe that can
    # rupture: all of these are Conduits.
    #
    # This is also where control points naturally live. The fitting between two vessels is
    # exactly where a real plant puts a valve, and putting the lever here rather than on
    # the vessel disperses complexity out of the mechanisms and into the joins around them.
    #
    # A Conduit holds what passes through it for one tick, which is where its hop of delay
    # comes from. Nothing is configured; it is a consequence of reading the previous tick.
    class Conduit < Node
      include Concerns::Thermal
      include Concerns::Holds
      include Concerns::Wearing
      include Concerns::Pressurized

      attr_reader :volume_m3, :heat_capacity, :ambient_conductance, :ambient_k,
                  :control_id, :max_temperature_k, :stress_rate

      def initialize(id:, label: nil, accepts: [], max_kg_per_s:, volume_m3:,
                     heat_capacity: 1.0e4, ambient_conductance: 0.0,
                     ambient_k: Units::STANDARD_TEMPERATURE_K, control_id: nil,
                     max_temperature_k: Float::INFINITY, stress_rate: 0.0)
        super(
          id: id, label: label,
          ports: [
            Port.new(id: :inlet,  direction: :inlet,  accepts: accepts,
                     max_kg_per_s: max_kg_per_s),
            Port.new(id: :outlet, direction: :outlet, accepts: accepts,
                     max_kg_per_s: max_kg_per_s)
          ]
        )
        @volume_m3 = volume_m3.to_f
        @heat_capacity = heat_capacity.to_f
        @ambient_conductance = ambient_conductance.to_f
        @ambient_k = ambient_k.to_f
        @control_id = control_id&.to_sym
        @max_temperature_k = max_temperature_k.to_f
        @stress_rate = stress_rate.to_f
      end

      def initial_temperature_k = @ambient_k

      # A duct is limited by how fast things move THROUGH it, never by how much it can
      # hold — that is what `max_kg_per_s` is for, and it is the distinction the old
      # `Buffer` failed to make. Pressure-capping a pipe by its own volume throttles it to
      # roughly a kilogram of gas per cubic metre, which is far below any useful flow.
      #
      # Containment limits belong to vessels, whose job is to contain.
      def gas_headroom_kg(_state, _target_pa, _content, _resource) = Float::INFINITY

      # Draw in at whatever the valve is open to; send on everything already held.
      #
      # A broken conduit does neither, which is what makes a failure propagate as a
      # blockage rather than as a leak — the line backs up behind it all the way to the
      # source, and the player feels it as rising pressure upstream.
      def plan(state, ctx)
        return Intent.none if broken?(state)

        # Draw only what there is room to move THROUGH. A pipe already full of something it
        # has not discharged cannot take more, and a conduit that ignores this becomes an
        # infinite sink — draining its source every tick and holding it at nothing, so
        # whatever it feeds never receives anything at all.
        held = contents_kg(state)

        Intent.new(
          draws:  { inlet: [ throughput_kg(ctx) - held, 0.0 ].max },
          pushes: { outlet: held }
        )
      end

      # Over-temperature is the generic failure mode. A conduit with no rated temperature
      # never wears out, which is the right default for plumbing that is not interesting.
      def stress_per_second(state, ctx)
        return 0.0 if @stress_rate.zero? || @max_temperature_k.infinite?

        over = temperature_k(state, ctx.content) - @max_temperature_k
        over.positive? ? (over / @max_temperature_k) * @stress_rate : 0.0
      end

      def failure_type = :conduit_rupture

      def failure_detail(state, ctx)
        { temperature_k: temperature_k(state, ctx.content).round(2) }
      end

      private

      # Fully open unless a lever says otherwise. `ctx.controls` carries the *actual* lever
      # position, not the target, so a valve that a minion is still cranking open restricts
      # flow to where it has actually got to.
      def throughput_kg(ctx)
        fraction = @control_id ? ctx.controls.fetch(@control_id, 0.0) / 100.0 : 1.0
        port(:outlet).capacity_kg(ctx.dt) * fraction.clamp(0.0, 1.0)
      end
    end
  end
end
