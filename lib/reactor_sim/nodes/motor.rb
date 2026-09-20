# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A small engine that carries its own rotor: a donkey engine, a standby set, a compressor's
    # prime mover.
    #
    # **It exists so a fitting can be driven by something other than the main engine.** A blower
    # has to work on a black start — before there is any steam — so it cannot hang off the
    # drivetrain it is trying to bring to life. This burns its own fuel and turns its own shaft,
    # and a driven `Conduit` then names it with `driven_by:`.
    #
    # ## It burns its charge properly rather than converting fuel to torque by fiat
    #
    # `Thermal` + `Holds` + `Rotating`, with `reactions:` running the ordinary combustion
    # machinery over what it holds — so it needs **air** as well as fuel, puts its exhaust out
    # like anything else, and audits through `conservation_spec` with no special case. A node
    # that turned kilograms of oil into joules of shaft work directly would be a second energy
    # path outside the reaction system, which is exactly what the mass-balance check on reactions
    # exists to prevent.
    #
    # > **Its own charge, deliberately, rather than sharing the firebox.** `oil_combustion` is
    # > already in the steam engine's firebox reaction list, so a fuel-oil line routed there
    # > would let a player burn the donkey's fuel in the main fire. Holding its own tank makes
    # > that unexpressible rather than merely discouraged.
    #
    # ## What makes it go
    #
    # It makes `rated_torque_nm` with its charge alight, shed as it nears `rated_omega`. The
    # torque is applied through `Tick#transmit_torque` exactly as a cylinder's is, so it is
    # **paid for out of the node's own charge** and cannot manufacture work it has not released
    # — which is why a donkey engine is hot and noisy and wastes most of what it burns.
    #
    # `drives` returns its own id, which `transmit_torque` handles: one lump of machinery rather
    # than an engine belted to a separate flywheel.
    class Motor < Node
      include Concerns::Thermal
      include Concerns::Holds
      include Concerns::Pressurized
      include Concerns::Rotating
      include Concerns::Wearing

      attr_reader :heat_capacity, :ambient_conductance, :ambient_k, :volume_m3,
                  :moment_of_inertia, :reactions, :control_id, :rated_torque_nm,
                  :rated_omega, :friction, :material, :max_temperature_k, :stress_rate,
                  :radius_m, :fuel_charge_kg, :igniter_kg_per_s, :swept_m3

      def initialize(id:, label: nil, volume_m3: 0.05, ports: [], fuel_charge_kg: 0.01,
                     swept_m3: 0.002, moment_of_inertia: 0.4, radius_m: 0.15,
                     reactions: [], control_id: nil, rated_torque_nm: 40.0,
                     rated_omega: 60.0, friction: 0.02, igniter_kg_per_s: 0.002,
                     heat_capacity: 8.0e3, ambient_conductance: 25.0,
                     ambient_k: Units::STANDARD_TEMPERATURE_K,
                     initial_temperature_k: nil, initial_contents: [],
                     material: nil, max_temperature_k: Float::INFINITY, stress_rate: 0.0,
                     damages: {}, endangers: {})
        super(id: id, label: label, ports: ports)
        @volume_m3 = volume_m3.to_f
        # How much fuel it keeps in the chamber at full throttle. Small: this is a burner's
        # standing charge, not a tank, and the tank is a separate node so that running dry is
        # something a player can watch happen.
        @fuel_charge_kg = fuel_charge_kg.to_f
        # What its pistons shift per revolution. This is what lets it breathe — see `plan`.
        @swept_m3 = swept_m3.to_f
        @moment_of_inertia = moment_of_inertia.to_f
        @radius_m = radius_m.to_f
        @reactions = Array(reactions).map(&:to_sym).freeze
        @control_id = control_id&.to_sym
        # What it makes with its charge fully alight and well below rated speed. **Efficiency is
        # emergent rather than declared**: the reaction decides how fast fuel goes, this decides
        # how much work comes out, and the ratio between them is what a thermal efficiency is.
        # Declaring both would let them disagree.
        @rated_torque_nm = rated_torque_nm.to_f
        # The speed it settles at when running freely — what its governor holds it to. Torque is
        # shed as it approaches, so it does not accelerate without limit on a light load.
        @rated_omega = rated_omega.to_f
        @friction = friction.to_f
        @igniter_kg_per_s = igniter_kg_per_s.to_f
        @heat_capacity = heat_capacity.to_f
        @ambient_conductance = ambient_conductance.to_f
        @ambient_k = ambient_k.to_f
        @initial_temperature_k = initial_temperature_k&.to_f
        @initial_contents = initial_contents.freeze
        @material = material&.to_sym
        @max_temperature_k = max_temperature_k.to_f
        @stress_rate = stress_rate.to_f
        @damages = damages.freeze
        @endangers = endangers.freeze
        freeze
      end

      def initial_temperature_k = @initial_temperature_k || @ambient_k

      def holds_initial_state(_rng, content)
        { parcels: Parcel.normalise(@initial_contents.map { |spec|
            Parcel.build(resource: spec.fetch(:resource), kg: spec.fetch(:kg),
                         temperature_k: spec.fetch(:temperature_k, initial_temperature_k),
                         content: content)
          }) }
      end

      # `Node#initial_state` already folds in every concern's fragment, so this adds only what
      # is this class's own.
      def base_initial_state(rng, content)
        super.merge(torque: 0.0, joules_from_reactions: 0.0)
      end

      # It carries its own rotor, so it drives itself.
      def drives = id

      # **Throttle, as a fuel draw rather than as a multiplier on the output.** The lever says
      # how much oil to admit; what comes of that is combustion's business, so a motor with the
      # throttle wide open and an empty tank does nothing at all.
      #
      # **It breathes by DISPLACEMENT, and that is the whole reason it makes useful power.** A
      # chamber left to exchange gas by thermal cycling alone runs air-starved: measured at
      # 380 W against the ~3 kW a blower wants, and no amount of chamber volume fixes it,
      # because with no pressure difference there is no flow to bring fresh air in. A
      # reciprocating engine pumps its own charge — `Cylinder#displacement_kg` is the same idea
      # and the same arithmetic.
      #
      # Scavenging is therefore proportional to **speed**, which gives the behaviour a real
      # engine has: it breathes harder as it spins up, so it has to be got turning before it
      # will make power, and it cannot make power while stalled.
      def plan(state, ctx)
        return Intent.none unless ports.key?(:fuel)

        wanted = @fuel_charge_kg * fill_fraction(ctx)
        draws = { fuel: [ wanted - fuel_kg(state, ctx), 0.0 ].max }
        draws[:air] = scavenge_kg(ctx) if ports.key?(:air)

        Intent.new(draws: draws, pushes: exhaust_push(state, ctx))
      end

      # What the pistons shift in a tick, at the density of what they are drawing.
      def scavenge_kg(ctx)
        revolutions = omega_now(ctx) / (2.0 * Math::PI) * ctx.dt
        revolutions * @swept_m3 * Units::AIR_DENSITY_KG_PER_M3
      end

      # And it puts the same volume out the other side, or the chamber simply fills. Pushed
      # rather than drawn because nothing downstream wants exhaust — the engine is what moves it.
      def exhaust_push(state, ctx)
        return {} unless ports.key?(:exhaust)

        held = contents_kg(state)
        return {} unless held.positive?

        { exhaust: [ scavenge_kg(ctx), held ].min }
      end

      # This tick's speed, read from the rotor it carries — which is itself, so no cross-node
      # read and no lag.
      def omega_now(ctx)
        state = ctx.node_state(id)
        state ? omega(state) : 0.0
      end

      # **Torque comes from FIRING, not from an energy quotient.** An engine makes its rated
      # torque when its charge is alight and none when it is not, which is why this reads the
      # ignited fraction rather than the joules released.
      #
      # > Deriving torque as `power / ω` is the obvious thing and it is wrong at rest: with any
      # > floor on ω, a full charge catching on tick one asks for **kilonewton-metres**. Measured
      # > before this was fixed — the rotor reached 262 rad/s on a 0.4 kg·m² inertia and then
      # > drained its own thermal mass, 700 K to 334 K, paying 1.88 MJ of friction out of a
      # > 154 kJ burn. `transmit_torque` bounds the work against the charge, so nothing was
      # > created; it was simply a heat engine eating its own block.
      #
      # Shed as it approaches rated speed — a governor expressed as a curve rather than as a
      # controller, so a light load does not run it away. `Tick#transmit_torque` then bills the
      # work against what the charge actually holds, exactly as it does a cylinder's.
      def apply(state, ctx, _grant)
        state = seed_ignition(state, ctx)
        firing = lit_fraction(state)
        return state.merge(torque: 0.0) unless firing.positive?

        governed = [ 1.0 - (omega(state) / @rated_omega), 0.0 ].max

        state.merge(torque: @rated_torque_nm * firing * governed)
      end

      # How much of what it holds is alight, 0..1. `Resources::Ignition` tracks the lit mass and
      # the reaction's own kinetics decide it, so an engine starved of air or out of fuel loses
      # its fire and its torque together rather than through a second mechanism.
      def lit_fraction(state)
        lit = @reactions.sum { |r| state.fetch(:ignition, {}).fetch(r, nil)&.fetch(:kg, 0.0) || 0.0 }
        return 0.0 unless lit.positive?

        charge = @fuel_charge_kg
        charge.positive? ? (lit / charge).clamp(0.0, 1.0) : 0.0
      end

      # **It lights itself while the throttle is open.** A donkey engine is swung on a starting
      # handle rather than lit with a match, so needing a separate igniter lever would be a
      # ritual with no decision in it — the interesting failure is running out of fuel, not
      # failing to strike.
      #
      # Seeded rather than heated, exactly as a pilot light is: recorded here and consumed by
      # `Tick#advance_ignition` in phase 5.
      def seed_ignition(state, ctx)
        state.merge(ignition_seed_kg: @igniter_kg_per_s * fill_fraction(ctx) * ctx.dt)
      end

      # What it can pay for, which is what stops it inventing work from nothing. Same bound as
      # `Cylinder#extractable_joules`: it may not drive its charge below ambient.
      def extractable_joules(state)
        [ total_joules(state) - (@heat_capacity * @ambient_k), 0.0 ].max
      end

      def stress_per_second(state, ctx)
        return 0.0 if @stress_rate.zero?

        over = temperature_k(state, ctx.content) - rated_temperature_k(ctx.content)
        over.positive? ? over * @stress_rate : 0.0
      end

      def failure_modes = { seized: { derates: { throughput: 0.0 } } }
      def failure_damages = @damages
      def failure_hazards = @endangers

      private

      # How wide the throttle is. No lever means wide open, which is what an unattended standby
      # engine does.
      def fill_fraction(ctx)
        return 1.0 if @control_id.nil?

        (ctx.controls.fetch(@control_id, 0.0) / 100.0).clamp(0.0, 1.0)
      end

      # What it holds of things it can burn, which is what the throttle rations. Measured
      # against the FUEL rather than against everything in the chamber: air and exhaust share
      # that volume, so a total would have the throttle shut itself the moment it fired.
      def fuel_kg(state, ctx)
        state.fetch(:parcels, []).sum do |parcel|
          ctx.content.tags(parcel.fetch(:resource)).include?(:fuel) ? parcel.fetch(:kg) : 0.0
        end
      end
    end
  end
end
