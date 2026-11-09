# frozen_string_literal: true

module ReactorSim
  module Nodes
    # **Where deliveries come in**: a holder the outside world fills on a timetable — a consignment of
    # `consignment_kg` of `resource` every `every_s`, the first after `first_s` — and whatever the
    # operation links to `:out` empties. A consignment due while there is no room for it waits until
    # there is, as a train waits outside a full siding.
    #
    # **A boundary, so what arrives is booked as added** (`mass_injected`, `joules_injected`), the way
    # `Catchment` books the rain. It arrives at the outside air's temperature.
    #
    # TODO: the timetable is the part's own; the first caller of a consignment another operation
    # sends is the colliery's raised coal, sent to the open pit by rail. Untested until then.
    #
    #   state: parcels, due_s, arrived_kg
    class Siding < Node
      include Concerns::Thermal
      include Concerns::Holds

      attr_reader :resource, :consignment_kg, :every_s, :first_s, :volume_m3, :heat_capacity, :ambient_k,
                  :ambient_conductance

      def initialize(id:, resource:, consignment_kg:, every_s:, volume_m3:, accepts:, first_s: nil, label: "Siding",
                     max_kg_per_s: 100.0)
        super(id: id, label: label,
              ports: [ Port.new(id: :out, direction: :outlet, accepts: accepts, max_kg_per_s: max_kg_per_s) ])
        @resource = resource.to_sym
        @consignment_kg = consignment_kg.to_f
        @every_s = every_s.to_f
        @first_s = (first_s || every_s).to_f
        @volume_m3 = volume_m3.to_f
        @heat_capacity = 1.0e3
        @ambient_k = Units::STANDARD_TEMPERATURE_K
        @ambient_conductance = 0.0
        freeze
      end

      def initial_temperature_k = @ambient_k

      def holds_initial_state(_rng, _content) = { parcels: [].freeze, due_s: @first_s, arrived_kg: 0.0 }

      def plan(_state, _ctx) = Intent.none

      def apply(state, ctx, _grant)
        due = state.fetch(:due_s) - ctx.dt
        idle = state.merge(due_s: [ due, 0.0 ].max, mass_injected: 0.0, joules_injected: 0.0)
        return idle if due.positive?

        consignment = Parcel.build(resource: @resource, kg: @consignment_kg, content: ctx.content,
                                   temperature_k: ctx.sky.fetch(:outdoor_k, @ambient_k))
        return idle if room_m3(state, ctx.content) < Parcel.total_volume([ consignment ], ctx.content)

        state.merge(parcels: Parcel.normalise(state.fetch(:parcels) + [ consignment ]), due_s: due + @every_s,
                    arrived_kg: state.fetch(:arrived_kg) + @consignment_kg,
                    mass_injected: @consignment_kg, joules_injected: Parcel.total_joules([ consignment ]))
      end
    end
  end
end
