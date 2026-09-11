# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A tank, vat, drum or reactor pressure vessel: something that holds material and lets
    # things happen to it.
    #
    # Vessels are **passive**. They declare no intent — conduits pull from them and push
    # into them, and a link's flow is set by whichever end is actively driving it. That is
    # the physical intuition (valves and pumps move fluid; tanks do not) and it means every
    # link has exactly one active end, which is what keeps settlement unambiguous.
    #
    # Everything interesting a vessel does — boiling, reacting, pressurising, failing — it
    # does through concerns and content, not through bespoke code here.
    class Vessel < Node
      include Concerns::Thermal
      include Concerns::Holds
      include Concerns::Obstructs
      include Concerns::Wearing
      include Concerns::Pressurized

      attr_reader :volume_m3, :heat_capacity, :ambient_conductance, :ambient_k,
                  :reactions, :heater_control_id, :heater_watts, :igniter_kg_per_s,
                  :max_pressure_pa, :max_temperature_k, :stress_rate

      def initialize(id:, label: nil, volume_m3:, ports: [],
                     heat_capacity: 5.0e5, ambient_conductance: 0.0,
                     ambient_k: Units::STANDARD_TEMPERATURE_K,
                     initial_temperature_k: nil, initial_contents: [], reactions: [],
                     heater_control_id: nil, heater_watts: 0.0, igniter_kg_per_s: 0.0,
                     obstruction_tags: [], void_fraction: 1.0,
                     max_pressure_pa: Float::INFINITY, max_temperature_k: Float::INFINITY,
                     stress_rate: 0.0)
        super(id: id, label: label, ports: ports)
        @volume_m3 = volume_m3.to_f
        # What clogs this vessel, and how much of it there is room for before it does. Empty
        # tags mean nothing obstructs anything, which is the case for almost every vessel — a
        # tank does not care what shape its contents are.
        @obstruction_tags = obstruction_tags.map(&:to_sym).freeze
        # The share of the volume that is open space the process needs. A grate is mostly gaps:
        # air has to reach the fuel through them, and ash filling them is what smothers a fire.
        @void_fraction = void_fraction.to_f
        @heat_capacity = heat_capacity.to_f
        @ambient_conductance = ambient_conductance.to_f
        @ambient_k = ambient_k.to_f
        @initial_temperature_k = (initial_temperature_k || ambient_k).to_f
        @initial_contents = initial_contents.freeze
        @reactions = reactions.map(&:to_sym).freeze
        @heater_control_id = heater_control_id&.to_sym
        @heater_watts = heater_watts.to_f
        @igniter_kg_per_s = igniter_kg_per_s.to_f
        @max_pressure_pa = max_pressure_pa.to_f
        @max_temperature_k = max_temperature_k.to_f
        @stress_rate = stress_rate.to_f
      end

      def initial_temperature_k = @initial_temperature_k

      attr_reader :obstruction_tags

      # The open space the process needs, which is a share of the vessel rather than all of it.
      def obstruction_volume_m3 = @volume_m3 * @void_fraction

      # **A choked bed reacts more slowly**, and this is the second thing `Obstructs` was
      # written for — the first being water in a cylinder, which shares none of this code and
      # none of its consequences. If the abstraction only ever had one caller it would not have
      # earned a file.
      #
      # Ash filling the gaps between the fuel is what smothers a fire: the air cannot reach what
      # is left to burn. Expressed as a slowdown rather than as a cap, because that is what
      # choking is — the fuel and the air are both still there, they are just no longer meeting.
      # Linear in the free void, and it reaches zero only when the bed is solid.
      def reaction_throttle(state, content)
        return 1.0 if @obstruction_tags.empty?

        [ 1.0 - occupancy(state, content), 0.0 ].max
      end


      # A vessel may start with something in it — a tank of feedwater, a hopper of ore, a
      # drum of reagent. Declared as `{resource:, kg:, temperature_k:}` and turned into parcels at
      # construction, so it snapshots like anything else.
      def holds_initial_state(_rng, content)
        { parcels: Parcel.normalise(@initial_contents.map { |spec|
            Parcel.build(resource: spec.fetch(:resource), kg: spec.fetch(:kg),
                         temperature_k: spec.fetch(:temperature_k, @initial_temperature_k),
                         content: content)
          }) }
      end

      # Passive by design — see the class comment.
      def plan(_state, _ctx) = Intent.none

      # The only thing a bare vessel does for itself is run its heater. Note this reads the
      # lever's *actual* position, so a dial a minion is still turning up delivers only the
      # power it has actually reached.
      def apply(state, ctx, _grant)
        if @heater_control_id.nil? || broken?(state)
          return state.merge(joules_injected: 0.0, ignition_seed_kg: 0.0)
        end

        fraction = (ctx.controls.fetch(@heater_control_id, 0.0) / 100.0).clamp(0.0, 1.0)
        joules = @heater_watts * fraction * ctx.dt

        # A pilot light sets a little fuel alight; it does not heat the whole firebox to
        # ignition. Recorded here and consumed in phase 5, the same way `joules_injected` is —
        # a node reports what it did and the tick decides what that means.
        state = state.merge(ignition_seed_kg: @igniter_kg_per_s * fraction * ctx.dt)
        return state.merge(joules_injected: 0.0) if joules <= 0.0

        # Recorded, not just applied. Energy entering the system is declared in the ledger
        # exactly like energy leaving it, which is what makes the conservation spec a real
        # statement rather than a tautology.
        add_joules(state, joules, ctx.content).merge(joules_injected: joules)
      end

      # Over-pressure and over-temperature both eat durability, and they compound. This is
      # the generic vessel failure model; a specific operation can override it entirely.
      def stress_per_second(state, ctx)
        return 0.0 if @stress_rate.zero?

        over_p = fraction_over(pressure_pa(state, ctx.content), @max_pressure_pa)
        over_t = fraction_over(temperature_k(state, ctx.content), @max_temperature_k)
        (over_p + over_t) * @stress_rate
      end

      def failure_type = :vessel_rupture

      def failure_detail(state, ctx)
        { temperature_k: temperature_k(state, ctx.content).round(2),
          pressure_pa: pressure_pa(state, ctx.content).round(1) }
      end

      private

      def fraction_over(value, limit)
        return 0.0 if limit.infinite? || value <= limit

        (value - limit) / limit
      end
    end
  end
end
