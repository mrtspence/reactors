# frozen_string_literal: true

module ReactorSim
  module Nodes
    # **A bed of fuel on a grate**: the fuel, its ash and the gas among them, at the bed's own
    # temperature. A fire is two bodies — the bed and the space over it — because a banked bed
    # stays hot under its green coal while the gas over it cools, and one lumped body cannot say so.
    #
    # It hosts the fuel's reactions and takes the air from below, through a `Nodes::Grate`; its gas
    # goes on to whatever holder is over it.
    #
    # - **Its volume holds a tick's air.** A holder reacts with what it holds, so a bed sized to the
    #   gaps between its lumps would starve on any draught: the volume is the bed and the flame just
    #   over it.
    # - **Only what is alight glows** (`radiant_share`): a radiant `ThermalLink` from it carries its
    #   T⁴ term in proportion to the share of its fuel alight, so a fresh charge darkens the fire and
    #   a banked bed under green coal barely radiates.
    # - **Its depth** is its solids at their content density spread over `grate_area_m2`, which is
    #   what its grate's draught falls with.
    # - `laid:` starts it alight, as a bed made up before the match: `{ kelvin:, contents:, alight: }`,
    #   kilograms by resource and lit kilograms by reaction, the gas among it air at the outside
    #   pressure.
    class FuelBed < Vessel
      attr_reader :grate_area_m2

      def initialize(grate_area_m2:, laid: nil, **opts)
        @grate_area_m2 = grate_area_m2.to_f
        @laid = laid&.freeze
        super(**opts)
      end

      def initial_state(rng, content = nil)
        state = super
        return state if @laid.nil?

        kelvin = @laid.fetch(:kelvin)
        held = @laid.fetch(:contents).map do |resource, kg|
          Parcel.build(resource: resource, kg: kg, temperature_k: kelvin, content: content)
        end
        lit = @laid.fetch(:alight).to_h { |reaction, kg| [ reaction, { kg: kg, oxidiser_kg: 0.0 } ] }
        # `alight:` too, so a fire already burning does not announce that it caught.
        state.merge(parcels: Parcel.normalise(held + [ air_at(kelvin, held, content) ]),
                    joules: heat_capacity * kelvin, ignition: state.fetch(:ignition).merge(lit), alight: true)
      end

      def depth_m(state, content)
        solids = Parcel.matching(state.fetch(:parcels), [ :solid ], content)
        solids.sum { |p| Parcel.volume_m3(p, content) } / @grate_area_m2
      end

      def radiant_share(state, content)
        fuel = Parcel.total_kg(Parcel.matching(state.fetch(:parcels), [ :fuel ], content))
        return 0.0 if fuel <= Parcel::EPSILON

        (state.fetch(:ignition, {}).values.sum { |i| i.fetch(:kg, 0.0) } / fuel).clamp(0.0, 1.0)
      end

      private

      def air_at(kelvin, held, content)
        free = volume_m3 - held.sum { |p| Parcel.volume_m3(p, content) }
        kg = Units::STANDARD_PRESSURE_PA * free * content.resource(:air).fetch(:molar_mass_g_per_mol) /
             1_000.0 / (Units::GAS_CONSTANT * kelvin)
        Parcel.build(resource: :air, kg: kg, temperature_k: kelvin, content: content)
      end
    end
  end
end
