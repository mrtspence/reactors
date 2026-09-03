# frozen_string_literal: true

module ReactorSim
  module Operations
    # A stationary steam engine, in two historical flavours built from the same parts.
    #
    # This operation exists to answer a question about the architecture, not just to be
    # playable: *can an atmospheric engine and a high-pressure engine be the same operation
    # with different parts swapped in?* If yes, the abstractions are the right ones.
    #
    # They can, and the difference is three lines:
    #
    #   | | boiler relief | cylinder exhausts to | condenser |
    #   |---|---|---|---|
    #   | **Watt atmospheric** (1776)      | ~1.4 atm | the condenser | yes |
    #   | **Trevithick high-pressure** (1802) | ~6 atm | the atmosphere | no |
    #
    # Watt's engine works by making a vacuum and letting the sky push the piston; the
    # boiler barely needs to be above atmospheric, and the condenser is the whole point.
    # Trevithick threw the condenser away and pushed with boiler pressure instead — lighter,
    # far more powerful, and with a habit of exploding, which is why Watt thought he was mad.
    #
    # ## The chain
    #
    #   bunker ─stoker─➤ firebox ◄─damper─ atmosphere        (fuel meets air)
    #                    firebox ═heat═➤ boiler              (fire heats water)
    #   supply ─feed──➤ boiler ─throttle─➤ cylinder          (water becomes steam becomes work)
    #                            cylinder ═torque═➤ flywheel ═drive═➤ load
    #
    # Everything after the firebox is the same in both engines. Only the exhaust path moves.
    module SteamEngine
      TYPE = :steam_engine

      # A steam engine is a FAST machine — sixty revolutions a minute is interesting in real
      # time — so unlike a mine or a smelter it wants little or no time compression. At
      # `time_scale` 8 a single tick applies two seconds of full torque, which is enough to
      # take a flywheel from rest to past its burst speed before anything can respond.
      DEFAULT_TIME_SCALE = 1.0

      module_function

      def build(id:, seed:, variant: :high_pressure, time_scale: DEFAULT_TIME_SCALE,
                state: nil, rngs: nil, content: nil)
        # Symbolised because a restored snapshot brings it back from JSON as a string.
        variant = variant.to_sym
        spec = VARIANTS.fetch(variant) { raise Error, "unknown engine variant #{variant.inspect}" }

        Operation.new(
          id: id, type: TYPE, seed: seed, time_scale: time_scale,
          state: state, rngs: rngs, content: content,
          options: { variant: variant },
          nodes: nodes(spec), links: links(spec), thermal_links: thermal_links,
          drive_links: drive_links, control_points: control_points,
          diagnostics: diagnostics(spec), minions: crew
        )
      end

      VARIANTS = {
        # Low boiler pressure, exhaust into a vacuum. The condenser does the work.
        atmospheric: {
          relief_pa: 1.4 * Units::STANDARD_PRESSURE_PA,
          burst_pa: 4.0 * Units::STANDARD_PRESSURE_PA,
          exhausts_to: :condenser,
          condenser: true,
          # A smaller fire than Trevithick's, which is period-correct — Watt's engines were
          # low-pressure machines — and also as much as this one's condenser can swallow. Fed
          # the high-pressure draught it makes more steam than the condenser can lay down, and
          # the vacuum it exists to pull collapses. See the condenser note in current_progress.
          draught_kg_per_s: 4.0,
          bore_m: 1.3, stroke_m: 2.4,
          flywheel: { mass_kg: 24_000.0, radius_m: 2.8, friction: 40.0 }.freeze,
          load_inertia: 3_000.0, load_torque: 90_000.0
        }.freeze,
        # High boiler pressure, exhaust straight to the sky. No condenser at all.
        high_pressure: {
          relief_pa: 6.0 * Units::STANDARD_PRESSURE_PA,
          burst_pa: 14.0 * Units::STANDARD_PRESSURE_PA,
          exhausts_to: :atmosphere,
          condenser: false,
          draught_kg_per_s: 8.0,
          bore_m: 0.45, stroke_m: 1.1,
          flywheel: { mass_kg: 3_200.0, radius_m: 1.5, friction: 8.0 }.freeze,
          load_inertia: 400.0, load_torque: 5_500.0
        }.freeze
      }.freeze

      # --- nodes ---------------------------------------------------------------

      def nodes(spec)
        base = [
          Nodes::Atmosphere.new,
          fuel_bunker, stoker, damper(spec), firebox, flue,
          water_supply, feed_pump, boiler(spec), relief_valve(spec), throttle,
          cylinder(spec), flywheel(spec), load(spec)
        ]
        spec.fetch(:condenser) ? base + [ condenser, condensate_return ] : base
      end

      def fuel_bunker
        Nodes::Vessel.new(
          id: :bunker, label: "Fuel Bunker", volume_m3: 40.0,
          initial_contents: [ { resource: :coal, kg: 12_000.0 } ],
          ports: [ Port.new(id: :out, direction: :outlet, accepts: [ :fuel ], max_kg_per_s: 2.0) ]
        )
      end

      # A work station, not a valve. `stoking` is somebody's effort — how fast coal actually
      # reaches the grate is how hard they are shovelling. It behaves as an ordinary control
      # for now; when minions arrive they take over moving its `actual`, and nothing else
      # about this changes.
      def stoker
        Nodes::Conduit.new(
          id: :stoker, label: "Stoking Line", accepts: [ :fuel ],
          max_kg_per_s: 0.6, volume_m3: 0.5, heat_capacity: 2.0e3,
          control_id: :stoking
        )
      end

      def damper(spec)
        Nodes::Conduit.new(
          # Sized so a fully open damper roughly matches a fully stoked grate. Excess air
          # is not free: every kilogram of it has to be heated to firebox temperature and
          # then thrown up the chimney — and that is not theoretical, it is measurable. A
          # sweep of this number peaks here: at 12 kg/s the engine makes *less* power than
          # at 8, because the extra draught leaves as hot flue gas.
          #
          # Widened from 4.0 when ignition landed. The fire now has to raise steam on its own,
          # where before a permanently-held 2.5 MW igniter was quietly doing a third of it.
          # Note the firebox's own `air_in` port stays at 4.0: this makes the DELIVERY steadier
          # without over-airing the grate, and raising both together is worse than either.
          id: :damper, label: "Damper", accepts: [ :gas ],
          max_kg_per_s: spec.fetch(:draught_kg_per_s), volume_m3: 1.0, heat_capacity: 2.0e3,
          control_id: :damper_open
        )
      end

      # Where fuel and air meet. The igniter is a small, deliberate heat input — coal will
      # not catch below 700 K, so an engine has to be lit before it can be run.
      def firebox
        Nodes::Vessel.new(
          id: :firebox, label: "Firebox", volume_m3: 6.0,
          heat_capacity: 3.0e4, ambient_conductance: 60.0,
          reactions: %i[coal_combustion wood_combustion oil_combustion],
          # A match, not a furnace. The igniter used to be 2.5 MW, which is what it took to
          # drag six cubic metres of firebox over a bulk ignition threshold — and a player
          # quickly learned that the way to keep a fire alive was to leave it on, turning the
          # starting handle into a permanent heat source.
          #
          # It now sets a little fuel alight and adds a modest amount of heat, exactly like a
          # gas pilot: the fire's own combustion does the rest, or it does not catch.
          heater_control_id: :igniter, heater_watts: 1.2e5, igniter_kg_per_s: 0.02,
          ports: [
            Port.new(id: :fuel_in, direction: :inlet, accepts: [ :fuel ], max_kg_per_s: 2.0),
            Port.new(id: :air_in, direction: :inlet, accepts: [ :gas ], max_kg_per_s: 4.0),
            # Accepts any gas, not just combustion products. Air that has been drawn in
            # but not burnt has to be able to leave again — restricting this to :exhaust
            # meant unburnt draught piled up in the firebox and swallowed the fire's heat.
            Port.new(id: :flue_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 12.0)
          ]
        )
      end

      def flue
        Nodes::Conduit.new(
          id: :flue, label: "Chimney", accepts: [ :gas ],
          max_kg_per_s: 12.0, volume_m3: 3.0, heat_capacity: 5.0e3,
          ambient_conductance: 200.0
        )
      end

      def water_supply
        Nodes::Vessel.new(
          id: :supply, label: "Water Supply", volume_m3: 12.0,
          initial_contents: [ { resource: :water, kg: 6_000.0 } ],
          ambient_conductance: 50.0,
          ports: [
            Port.new(id: :out, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: 4.0),
            Port.new(id: :in, direction: :inlet, accepts: [ :liquid ], max_kg_per_s: 4.0)
          ]
        )
      end

      def feed_pump
        Nodes::Conduit.new(
          id: :feed_pump, label: "Feed Pump", accepts: [ :liquid ],
          max_kg_per_s: 2.5, volume_m3: 0.2, heat_capacity: 2.0e3,
          control_id: :feed
        )
      end

      # The dangerous part. Relief pressure is where it starts hurting itself; burst
      # pressure is where it stops being a boiler.
      def boiler(spec)
        Nodes::Vessel.new(
          id: :boiler, label: "Boiler", volume_m3: 5.0,
          heat_capacity: 6.0e5, ambient_conductance: 90.0,
          initial_contents: [ { resource: :water, kg: 2_000.0 } ],
          # The safety valve lifts at `relief_pa`; the boiler only starts hurting itself
          # well above that. Setting the two equal left no margin at all — the shell began
          # taking damage on the same tick the valve first cracked open.
          max_pressure_pa: spec.fetch(:relief_pa) * 1.5, stress_rate: 90.0,
          ports: [
            Port.new(id: :feed_in, direction: :inlet, accepts: [ :liquid ], max_kg_per_s: 2.5),
            Port.new(id: :steam_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 2.5),
            Port.new(id: :relief_out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 3.0)
          ]
        )
      end

      # Sized so it can pass rather more steam than the fire can raise, but not without
      # limit — a badly stoked boiler can still outrun it.
      def relief_valve(spec)
        Nodes::ReliefValve.new(
          id: :relief, label: "Safety Valve", senses: :boiler,
          relief_pressure_pa: spec.fetch(:relief_pa),
          accepts: [ :gas ], max_kg_per_s: 3.0, volume_m3: 0.2,
          heat_capacity: 1.0e3, ambient_conductance: 50.0
        )
      end

      def throttle
        Nodes::Conduit.new(
          id: :throttle, label: "Throttle Valve", accepts: [ :gas ],
          max_kg_per_s: 2.5, volume_m3: 0.3, heat_capacity: 3.0e3,
          control_id: :throttle_open
        )
      end

      def cylinder(spec)
        Nodes::Cylinder.new(
          id: :cylinder, label: "Cylinder",
          bore_m: spec.fetch(:bore_m), stroke_m: spec.fetch(:stroke_m),
          drives: :flywheel, exhausts_to: spec.fetch(:exhausts_to), supplied_by: :boiler,
          cutoff_control_id: :cutoff, efficiency: 0.82,
          inlet_kg_per_s: 2.5, exhaust_kg_per_s: 6.0
        )
      end

      def flywheel(spec)
        # A beam engine's wheel is a different object from a high-pressure engine's: vastly
        # heavier, larger, and turning far more slowly. It has to be, because a 1.3 m piston
        # working against a vacuum develops something like 160 kN·m.
        Nodes::Flywheel.new(
          id: :flywheel, label: "Flywheel",
          # Cast iron is strong in compression and weak in tension, which is exactly the
          # wrong way round for a flywheel. The strength and density come from content; the
          # safety factor is this part's own, because how far below the ideal figure a real
          # casting fails is a property of the casting.
          material: :cast_iron, safety_factor: 0.35,
          friction: spec.fetch(:flywheel).fetch(:friction),
          fatigue_rate: 25.0,
          mass_kg: spec.fetch(:flywheel).fetch(:mass_kg),
          radius_m: spec.fetch(:flywheel).fetch(:radius_m)
        )
      end

      def load(spec)
        Nodes::Load.new(
          id: :load, label: "Mill Drive", moment_of_inertia: spec.fetch(:load_inertia),
          max_torque: spec.fetch(:load_torque), control_id: :load_demand, friction: 3.0
        )
      end

      # Only on the atmospheric engine. Sitting in cold water, it drops the pressure below
      # atmospheric — and that vacuum is what actually drives a Watt engine.
      def condenser
        Nodes::Vessel.new(
          id: :condenser, label: "Condenser", volume_m3: 3.0,
          heat_capacity: 2.0e5, ambient_conductance: 600_000.0,
          ports: [
            Port.new(id: :in, direction: :inlet, max_kg_per_s: 14.0),
            Port.new(id: :drain, direction: :outlet, accepts: [ :liquid ], max_kg_per_s: 4.0)
          ]
        )
      end

      # Condensate back to the supply — closing the water loop, exactly the topology a
      # topological resolution order could not have handled.
      def condensate_return
        Nodes::Conduit.new(
          id: :hotwell, label: "Hotwell Return", accepts: [ :liquid ],
          max_kg_per_s: 4.0, volume_m3: 0.4, heat_capacity: 2.0e3,
          ambient_conductance: 400.0
        )
      end

      # --- wiring --------------------------------------------------------------

      def links(spec)
        base = [
          Link.new(from: [ :bunker, :out ],          to: [ :stoker, :inlet ]),
          Link.new(from: [ :stoker, :outlet ],       to: [ :firebox, :fuel_in ]),
          Link.new(from: [ :atmosphere, :intake ],   to: [ :damper, :inlet ]),
          Link.new(from: [ :damper, :outlet ],       to: [ :firebox, :air_in ]),
          Link.new(from: [ :firebox, :flue_out ],    to: [ :flue, :inlet ]),
          Link.new(from: [ :flue, :outlet ],         to: [ :atmosphere, :exhaust ]),
          Link.new(from: [ :supply, :out ],          to: [ :feed_pump, :inlet ]),
          Link.new(from: [ :feed_pump, :outlet ],    to: [ :boiler, :feed_in ]),
          Link.new(from: [ :boiler, :steam_out ],    to: [ :throttle, :inlet ]),
          Link.new(from: [ :boiler, :relief_out ],   to: [ :relief, :inlet ]),
          Link.new(from: [ :relief, :outlet ],       to: [ :atmosphere, :exhaust ]),
          Link.new(from: [ :throttle, :outlet ],     to: [ :cylinder, :inlet ])
        ]

        # The one line that decides which engine this is.
        if spec.fetch(:condenser)
          base + [
            Link.new(from: [ :cylinder, :exhaust ], to: [ :condenser, :in ]),
            Link.new(from: [ :condenser, :drain ],  to: [ :hotwell, :inlet ]),
            Link.new(from: [ :hotwell, :outlet ],   to: [ :supply, :in ])
          ]
        else
          base + [ Link.new(from: [ :cylinder, :exhaust ], to: [ :atmosphere, :exhaust ]) ]
        end
      end

      def thermal_links
        [ ThermalLink.new(a: :firebox, b: :boiler, conductance: 9_000.0) ]
      end

      def drive_links
        [ DriveLink.new(a: :flywheel, b: :load, stiffness: 9_000.0) ]
      end

      # --- controls ------------------------------------------------------------

      # Every lever here keeps the default `stiffness: Float::INFINITY`, so `actual` snaps to
      # `target` and the crew's rate multiplier is discarded before it is ever used.
      #
      # TODO: expedient — this is what makes the crew inert. Giving the work stations
      # (`:stoking`, `:feed`) a finite stiffness is the one-line change that makes minion
      # condition matter, and it is deliberately not made here: the skill gradient at
      # time_scale 1.0 (60/80/60 survives, 80/90/70 bursts the flywheel) was measured with
      # instant actuation, and a proper implementation re-measures it rather than assuming
      # a few ticks of lever travel are lost in the noise.
      def control_points
        [
          ControlPoint.new(id: :igniter, label: "Igniter", node: :firebox),
          ControlPoint.new(id: :stoking, label: "Stoking Effort", node: :stoker),
          ControlPoint.new(id: :damper_open, label: "Damper", node: :damper, default: 50.0),
          ControlPoint.new(id: :feed, label: "Feed Pump", node: :feed_pump),
          ControlPoint.new(id: :throttle_open, label: "Throttle", node: :throttle),
          ControlPoint.new(id: :cutoff, label: "Cut-off", node: :cylinder, default: 100.0),
          ControlPoint.new(id: :load_demand, label: "Mill Load", node: :load, default: 60.0)
        ]
      end

      # --- crew ----------------------------------------------------------------

      # Two, deliberately: one minion cannot demonstrate reassignment, and one station cannot
      # demonstrate the lookup. The other five levers are unmanned, which is harmless because
      # every lever here is frictionless (see `control_points` above).
      #
      # NOTE the ids. The obvious name for the person shovelling coal is `stoker`, and
      # `:stoker` is already the conduit that carries fuel to the firebox. Ids are shared
      # across nodes, levers, instruments and crew because they key one rng table, so that
      # collision would have handed two components the same stream. `validate_graph!` now
      # refuses it outright.
      #
      # TODO: expedient — this roster is fixed, so it stays out of `options:` and is rebuilt
      # from code like the node list. The moment a crew can be hired, injured or dismissed it
      # must move into `options:`, or a restored snapshot rebuilds a different crew. Exactly
      # the trap `variant:` is in `options:` to avoid.
      def crew
        [ Minion.new(id: :fireman, archetype: :fireman, station: :stoking),
          Minion.new(id: :yardhand, archetype: :yardhand, station: :damper_open) ]
      end
    end
  end
end
