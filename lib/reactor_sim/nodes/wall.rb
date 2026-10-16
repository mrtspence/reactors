# frozen_string_literal: true

module ReactorSim
  module Nodes
    # **A room's walls, at their own temperature** — the rock round a roadway, a furnace's lining.
    # The gas in a room and the face it touches are different temperatures, so they are different
    # nodes; a `ThermalLink` between them carries the exchange, convection and radiation from hot
    # gas both.
    #
    # The wall is a **skin** of its `material:`, `skin_m` deep, backed by conduction into the body
    # behind it — which for strata is the ambient reservoir itself. One skin has both limits a
    # semi-infinite solid has: at short times it takes a blast's heat at the face, at long times it
    # passes it on, with a time constant of `ρ c skin² / k`. Holds nothing and has no ports.
    class Wall < Node
      include Concerns::Thermal

      attr_reader :material, :area_m2, :skin_m, :heat_capacity, :ambient_conductance, :ambient_k,
                  :initial_temperature_k

      def initialize(id:, material:, area_m2:, skin_m:, content:, label: nil,
                     ambient_k: Units::STANDARD_TEMPERATURE_K, initial_temperature_k: nil)
        super(id: id, label: label)
        @material = material.to_sym
        @area_m2 = area_m2.to_f
        @skin_m = skin_m.to_f
        @heat_capacity = @area_m2 * @skin_m * content.density(@material) * content.specific_heat(@material)
        @ambient_conductance = @area_m2 * content.thermal_conductivity_w_per_m_k(@material) / @skin_m
        @ambient_k = ambient_k.to_f
        @initial_temperature_k = (initial_temperature_k || ambient_k).to_f
        freeze
      end
    end
  end
end
