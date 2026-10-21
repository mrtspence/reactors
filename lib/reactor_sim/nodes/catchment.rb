# frozen_string_literal: true

module ReactorSim
  module Nodes
    # **Ground the rain drains off**: a yard round a shaft collar, a pit's benches. What falls on
    # `area_m2` — rain, and snow as it melts (`Outdoors#runoff`) — arrives here from the sky each
    # tick, and drains out through `:out` to wherever it is linked, which for a mine is the shaft
    # and so the sump.
    #
    # **A boundary, so what arrives is booked as added** (`mass_injected`, `joules_injected`), the
    # way `Atmosphere` books the air it supplies. It holds whatever has not yet drained, which is
    # what makes it a holder a path can draw from.
    class Catchment < Node
      include Concerns::Thermal
      include Concerns::Holds

      # Water reaching the drains is never colder than this: below freezing it would be ice, and
      # ice is not modelled yet.
      COLDEST_RUNOFF_K = 273.65

      attr_reader :area_m2, :volume_m3, :heat_capacity, :ambient_k, :ambient_conductance

      def initialize(id:, area_m2:, label: "Catchment", max_kg_per_s: 100.0)
        super(id: id, label: label,
              ports: [ Port.new(id: :out, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: max_kg_per_s) ])
        @area_m2 = area_m2.to_f
        @volume_m3 = 50.0
        @heat_capacity = 1.0
        @ambient_k = Units::STANDARD_TEMPERATURE_K
        @ambient_conductance = 0.0
        freeze
      end

      def initial_temperature_k = @ambient_k

      def holds_initial_state(_rng, _content) = { parcels: [].freeze }

      def plan(_state, _ctx) = Intent.none

      def apply(state, ctx, _grant)
        kg = ctx.sky.fetch(:runoff, 0.0) * @area_m2 * ctx.dt
        return state.merge(mass_injected: 0.0, joules_injected: 0.0) unless kg.positive?

        fallen = Parcel.build(resource: :water, kg: kg, content: ctx.content,
                              temperature_k: [ ctx.sky.fetch(:outdoor_k), COLDEST_RUNOFF_K ].max)
        state.merge(parcels: Parcel.normalise(state.fetch(:parcels) + [ fallen ]),
                    mass_injected: kg, joules_injected: Parcel.total_joules([ fallen ]))
      end
    end
  end
end
