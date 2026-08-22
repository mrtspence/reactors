# frozen_string_literal: true

module ReactorSim
  module Operations
    # The v0 operation. Two reagents are pumped down delayed lines into a reaction
    # vessel; the reaction makes heat, the heat makes steam, the steam drives a
    # turbine, and the turbine is the only thing that pays.
    #
    # Four levers, eight gauges, and three ways to destroy it. The levers pull against
    # each other on purpose:
    #
    #   * The reagents only react in balanced pairs, so feeding one hard while the
    #     other lags just banks unreacted slurry — which then all reacts at once when
    #     the second finally arrives.
    #   * Coolant protects the vessel and throws away the heat you are paid for.
    #   * Throttle converts pressure to power, so venting hard keeps the vessel safe
    #     but overspeeds the turbine.
    #
    # None of it is legible instantly: the feed lines run two ticks behind, the steam
    # line one, and the slurry gauges two. The overseer is always steering a machine
    # they can only see the recent past of.
    module ChemicalVats
      TYPE = :chemical_vats

      def self.build(id:, seed:, state: nil, rngs: nil)
        Operation.new(
          id: id,
          type: TYPE,
          seed: seed,
          state: state,
          rngs: rngs,
          mechanisms: mechanisms,
          buffers: buffers,
          control_points: control_points,
          diagnostics: diagnostics,
          power_source: [ :turbine, :power ]
        )
      end

      def self.mechanisms
        [
          Mechanisms::ReagentFeed.new(
            id: :feed_a, label: "Vitriol Feed",
            control_id: :feed_a_rate, out_buffer: :line_a
          ),
          Mechanisms::ReagentFeed.new(
            id: :feed_b, label: "Quicklime Feed",
            control_id: :feed_b_rate, out_buffer: :line_b
          ),
          Mechanisms::ReactionVessel.new(
            id: :vessel, label: "Reaction Vessel",
            control_id: :coolant, in_buffers: [ :line_a, :line_b ], out_buffer: :steam_line
          ),
          Mechanisms::Turbine.new(
            id: :turbine, label: "Turbine",
            control_id: :throttle, in_buffer: :steam_line
          )
        ]
      end

      def self.buffers
        [
          Buffer.new(id: :line_a, from: :feed_a, to: :vessel,
                     resource: :vitriol, capacity: 60.0, delay: 2),
          Buffer.new(id: :line_b, from: :feed_b, to: :vessel,
                     resource: :quicklime, capacity: 60.0, delay: 2),
          Buffer.new(id: :steam_line, from: :vessel, to: :turbine,
                     resource: :steam, capacity: 400.0, delay: 1)
        ]
      end

      def self.control_points
        [
          ControlPoint.new(id: :feed_a_rate, label: "Vitriol Rate",   mechanism: :feed_a),
          ControlPoint.new(id: :feed_b_rate, label: "Quicklime Rate", mechanism: :feed_b),
          ControlPoint.new(id: :coolant,     label: "Coolant Valve",  mechanism: :vessel),
          ControlPoint.new(id: :throttle,    label: "Turbine Throttle", mechanism: :turbine)
        ]
      end

      # Ranges are chosen so a badly-run vessel can peg its own gauges. A pegged
      # instrument is itself information, and widening the scale is an upgrade.
      def self.diagnostics
        [
          Diagnostic.new(id: :vessel_temp, label: "Vessel Temperature", mechanism: :vessel,
                         field: :temperature, unit: "°C", min: 0.0, max: 600.0,
                         noise: 1.5, delay: 1),
          Diagnostic.new(id: :vessel_pressure, label: "Vessel Pressure", mechanism: :vessel,
                         field: :pressure, unit: "kPa", min: 0.0, max: 1200.0,
                         noise: 6.0, delay: 1),
          Diagnostic.new(id: :slurry_a, label: "Unreacted Vitriol", mechanism: :vessel,
                         field: :slurry_a, unit: "u", min: 0.0, max: 200.0,
                         noise: 0.5, delay: 2),
          Diagnostic.new(id: :slurry_b, label: "Unreacted Quicklime", mechanism: :vessel,
                         field: :slurry_b, unit: "u", min: 0.0, max: 200.0,
                         noise: 0.5, delay: 2),
          Diagnostic.new(id: :turbine_rpm, label: "Turbine Speed", mechanism: :turbine,
                         field: :rpm, unit: "rpm", min: 0.0, max: 4000.0,
                         noise: 15.0, delay: 0),
          Diagnostic.new(id: :power_output, label: "Power Output", mechanism: :turbine,
                         field: :power, unit: "kW", min: 0.0, max: 3200.0,
                         noise: 0.0, delay: 0),
          Diagnostic.new(id: :vitriol_level, label: "Vitriol Reservoir", mechanism: :feed_a,
                         field: :reservoir, unit: "u", min: 0.0, max: 900.0,
                         noise: 0.0, delay: 0),
          Diagnostic.new(id: :quicklime_level, label: "Quicklime Reservoir", mechanism: :feed_b,
                         field: :reservoir, unit: "u", min: 0.0, max: 900.0,
                         noise: 0.0, delay: 0)
        ]
      end
    end

    register(ChemicalVats::TYPE) do |id:, seed:, state: nil, rngs: nil|
      ChemicalVats.build(id: id, seed: seed, state: state, rngs: rngs)
    end
  end
end
