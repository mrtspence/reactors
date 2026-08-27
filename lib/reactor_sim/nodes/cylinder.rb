# frozen_string_literal: true

module ReactorSim
  module Nodes
    # Where a gas pressure difference becomes shaft torque.
    #
    # Generic: nothing here knows what the working fluid is. Steam, compressed air, hot flue
    # gas — the cylinder cares only that something on the inlet side is at higher pressure
    # than whatever it exhausts into.
    #
    # ## Torque, not power
    #
    # Work is computed as a TORQUE from the pressure difference across the piston:
    #
    #     torque = ΔP × piston_area × crank_radius × efficiency
    #
    # which is independent of how fast it is turning. That matters enormously. Deriving
    # torque from a power figure means dividing by ω, which is infinite at rest — and a
    # machine that cannot be started from standstill is not much use. This way a stalled
    # cylinder has full torque and `power = torque × ω` correctly comes out as zero.
    #
    # ## Self-starting and self-limiting, with no special cases
    #
    #     at rest    inlet open → charge builds → pressure rises → torque → it turns
    #     spinning   exhaust flow ∝ ω → charge drops → pressure falls → torque falls → settles
    #
    # It finds its own operating point because turning faster means breathing harder. That
    # is also where the danger lives: shed the load and ω climbs, which admits more working
    # fluid, which pushes ω higher still. Nothing stands between that loop and a burst
    # rotating mass except a governor and an operator.
    #
    # ## What it exhausts into decides what kind of machine it is
    #
    # Wired to exhaust into a condenser held near vacuum, it is driven by the difference
    # between its supply and that vacuum. Wired to exhaust into the open air, it is driven
    # by however far its supply exceeds ambient. Same node, same formula, different graph —
    # which is what lets one definition cover machines that look nothing alike.
    class Cylinder < Node
      include Concerns::Thermal
      include Concerns::Holds
      include Concerns::Pressurized
      include Concerns::Wearing

      attr_reader :volume_m3, :heat_capacity, :ambient_conductance, :ambient_k,
                  :bore_m, :stroke_m, :crank_radius_m, :efficiency, :drives,
                  :cutoff_control_id, :clearance_fraction, :max_pressure_pa, :stress_rate,
                  :exhausts_to, :supplied_by, :default_working_fluid

      def initialize(id:, label: nil, bore_m:, stroke_m:, drives:, exhausts_to:, supplied_by:,
                     crank_radius_m: nil, efficiency: 0.85, clearance_fraction: 0.08,
                     heat_capacity: 6.0e4, ambient_conductance: 25.0,
                     ambient_k: Units::STANDARD_TEMPERATURE_K, cutoff_control_id: nil,
                     inlet_kg_per_s: 8.0, exhaust_kg_per_s: 12.0, working_fluid: :steam,
                     max_pressure_pa: Float::INFINITY, stress_rate: 0.0)
        @bore_m = bore_m.to_f
        @stroke_m = stroke_m.to_f
        # Half the stroke, unless the crank is geared otherwise.
        @crank_radius_m = (crank_radius_m || (@stroke_m / 2.0)).to_f
        @efficiency = efficiency.to_f
        @clearance_fraction = clearance_fraction.to_f
        # Swept volume plus the clearance the piston never sweeps.
        @swept_m3 = Math::PI * ((@bore_m / 2.0)**2) * @stroke_m
        @volume_m3 = @swept_m3 * (1.0 + @clearance_fraction)

        super(
          id: id, label: label,
          ports: [
            Port.new(id: :inlet, direction: :inlet, accepts: [ :gas ], max_kg_per_s: inlet_kg_per_s),
            Port.new(id: :exhaust, direction: :outlet, max_kg_per_s: exhaust_kg_per_s)
          ]
        )
        @drives = drives.to_sym
        # Declared rather than discovered from the link graph, so the cylinder knows what
        # it is working against without having to inspect topology it does not own. This is
        # the one line that decides what kind of machine this cylinder ends up being.
        @exhausts_to = exhausts_to.to_sym
        @supplied_by = supplied_by.to_sym
        @default_working_fluid = working_fluid.to_sym
        @heat_capacity = heat_capacity.to_f
        @ambient_conductance = ambient_conductance.to_f
        @ambient_k = ambient_k.to_f
        @cutoff_control_id = cutoff_control_id&.to_sym
        @max_pressure_pa = max_pressure_pa.to_f
        @stress_rate = stress_rate.to_f
      end

      def initial_temperature_k = @ambient_k

      def piston_area_m2 = Math::PI * ((@bore_m / 2.0)**2)

      def swept_volume_m3 = @swept_m3

      # Admit working fluid through the inlet, and breathe out at a rate set by how fast it
      # is turning. The exhaust term is what makes the cylinder self-limiting.
      def plan(state, ctx)
        return Intent.none if broken?(state)

        cutoff = @cutoff_control_id ? (ctx.controls.fetch(@cutoff_control_id, 100.0) / 100.0).clamp(0.0, 1.0) : 1.0

        # Fluid flows in only while the supply is above the charge already held, and only as
        # far as would equalise the two. Both halves are needed: the first stops it inhaling
        # from a source it has already out-pressurised, and the second stops it blowing past
        # that source inside a single tick.
        #
        # It caps itself rather than relying on the arbiter because the pipe between it and
        # its supply is a duct, not a container — a duct reports whatever pressure its own
        # small volume implies, which is not the pressure actually driving the flow.
        supply = ctx.node_pressure(@supplied_by) || Units::STANDARD_PRESSURE_PA
        headroom = supply > pressure_pa(state, ctx.content) ?
          gas_headroom_kg(state, supply, ctx.content, working_fluid(ctx)) : 0.0

        Intent.new(
          draws: { inlet: [ port(:inlet).capacity_kg(ctx.dt) * cutoff, headroom ].min },
          pushes: { exhaust: [ contents_kg(state) * breathing_fraction(ctx), 0.0 ].max }
        )
      end

      # Work out the torque the charge is exerting, and declare it.
      #
      # The energy transfer itself is NOT done here. The shaft's kinetic energy gain from a
      # given impulse is not exactly `torque × ω × dt` — there is a second-order term that
      # grows with the timestep — so the Operation applies the impulse, measures what the
      # shaft actually gained, and bills the charge for precisely that. Doing it here with
      # the first-order figure would leak energy at large `time_scale`, which is the one
      # place this simulation refuses to be approximate.
      def apply(state, ctx, _grant)
        return state.merge(torque: 0.0, indicated_power_w: 0.0) if broken?(state)

        exhaust_pressure = ctx.node_pressure(@exhausts_to) || Units::STANDARD_PRESSURE_PA
        delta_p = pressure_pa(state, ctx.content) - exhaust_pressure
        torque = delta_p * piston_area_m2 * @crank_radius_m * @efficiency
        torque = 0.0 if torque.negative? # a cylinder pushes; it does not pull the crank back

        omega = ctx.node_omega(@drives) || 0.0
        state.merge(torque: torque, indicated_power_w: torque * omega)
      end

      # Whatever gas the supply is actually offering, so the headroom calculation uses the
      # right molar mass. Falls back to a configured default for the first tick, when there
      # is nothing upstream yet to look at. Hardcoding a fluid here was the last thing in
      # this class that assumed what kind of machine it belonged to.
      def working_fluid(ctx)
        upstream = ctx.node_state(@supplied_by)
        gas = upstream&.fetch(:parcels, [])&.find { |p|
          ctx.content.tags(p.fetch(:resource)).include?(:gas)
        }

        gas ? gas.fetch(:resource) : @default_working_fluid
      end

      # How much energy this cylinder can give up before its charge would be colder than
      # the outside world. Stops a starved cylinder inventing work from nothing.
      def extractable_joules(state)
        [ total_joules(state) - (@heat_capacity * @ambient_k), 0.0 ].max
      end

      # Fraction of the charge swept out per tick. One full displacement per revolution,
      # capped so a fast machine cannot exhaust more than it holds.
      def breathing_fraction(ctx)
        omega = ctx.node_omega(@drives) || 0.0
        revolutions = omega / (2.0 * Math::PI) * ctx.dt
        (revolutions * (@swept_m3 / @volume_m3)).clamp(0.0, 1.0)
      end

      # Gas is compressible; liquid is not. If enough liquid collects in the clearance
      # volume the piston has nowhere to go and something has to give — the classic way a
      # priming supply destroys the machine it feeds.
      #
      # Detected and reported here; the consequence is deliberately not modelled yet.
      def liquid_fraction(state, content)
        held = parcels(state)
        return 0.0 if held.empty?

        liquid = held.reject { |p| content.tags(p.fetch(:resource)).include?(:gas) }
        return 0.0 if liquid.empty?

        Parcel.total_volume(liquid, content) / (@volume_m3 * @clearance_fraction)
      end

      def stress_per_second(state, ctx)
        return 0.0 if @stress_rate.zero? || @max_pressure_pa.infinite?

        over = pressure_pa(state, ctx.content) - @max_pressure_pa
        over.positive? ? (over / @max_pressure_pa) * @stress_rate : 0.0
      end

      def failure_type = :cylinder_failure
    end
  end
end
