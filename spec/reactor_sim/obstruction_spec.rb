# frozen_string_literal: true

require "reactor_sim"

# Incompressible matter where it should not be.
#
# `Concerns::Obstructs` exists because volume occupancy had only two consequences in this
# engine and both are about *room* — `Holds#room_m3` caps what a node will accept, and
# `Pressurized#free_volume` raises the pressure of the gas that is left. Neither says anything
# about a deposit getting in the **way** of a mechanism, which is what water in a cylinder, ash
# on a grate, tar in a line and scale in a tube all are.
RSpec.describe "obstruction" do
  let(:content) { ReactorSim::Content.default }
  let(:rng) { ReactorSim::Rng.stream(1, :obstruction) }

  def cylinder(**overrides)
    ReactorSim::Nodes::Cylinder.new(
      id: :cylinder, bore_m: 0.45, stroke_m: 1.1, drives: :flywheel,
      exhausts_to: :atmosphere, supplied_by: :chest, **overrides
    )
  end

  def charged(node, water_kg:, steam_kg: 0.2)
    parcels = [ ReactorSim::Parcel.build(resource: :steam, kg: steam_kg,
                                         temperature_k: 420.0, content: content) ]
    if water_kg.positive?
      parcels << ReactorSim::Parcel.build(resource: :water, kg: water_kg,
                                          temperature_k: 400.0, content: content)
    end
    node.rebalance(node.initial_state(rng, content).merge(parcels: parcels), content)
  end

  # A context is the only way to ask a node about its neighbours, and every hazard here is
  # graded by shaft speed, so the specs need one. The chest has to be here too: a cylinder's
  # diagram takes its admission pressure from `supplied_by`, so without a supply node above
  # ambient the mean effective pressure is correctly zero and every torque assertion is vacuous.
  def context(node, omega:, controls: {}, chest_water: 0.0, wheel_kg: 3_200.0)
    flywheel = ReactorSim::Nodes::Flywheel.new(id: :flywheel, mass_kg: wheel_kg, radius_m: 1.5)
    chest = ReactorSim::Nodes::Vessel.new(id: :chest, volume_m3: 1.0)
    held = [ ReactorSim::Parcel.build(resource: :steam, kg: 2.0,
                                      temperature_k: 430.0, content: content) ]
    if chest_water.positive?
      held << ReactorSim::Parcel.build(resource: :water, kg: chest_water,
                                       temperature_k: 430.0, content: content)
    end
    chest_state = chest.rebalance(
      chest.initial_state(rng, content).merge(parcels: held), content
    )

    ReactorSim::Tick::Context.new(
      controls: controls, dt: 0.25, tick: 1, content: content,
      nodes: { cylinder: node, flywheel: flywheel, chest: chest,
               atmosphere: ReactorSim::Nodes::Atmosphere.new },
      states: { flywheel: { angular_momentum: omega * flywheel.moment_of_inertia },
                chest: chest_state,
                atmosphere: ReactorSim::Nodes::Atmosphere.new.initial_state(rng, content) }
    )
  end

  describe "occupancy is measured against a characteristic volume" do
    # **The whole reason this is a concern rather than a method.** The water that destroys this
    # cylinder is 7% of its total volume, so against the node's own volume the hazard is
    # invisible. What matters is the clearance space the piston must fit into at the top of its
    # stroke.
    it "measures a cylinder against its clearance, not its volume" do
      node = cylinder
      expect(node.obstruction_volume_m3).to be_within(1e-9).of(node.volume_m3 - node.swept_volume_m3)
      expect(node.obstruction_volume_m3 / node.volume_m3).to be < 0.08
    end

    it "reads 1.0 when the clearance space is exactly full of water" do
      node = cylinder
      full = node.obstruction_volume_m3 * content.density(:water)

      expect(node.occupancy(charged(node, water_kg: full), content)).to be_within(1e-6).of(1.0)
      expect(node.occupancy(charged(node, water_kg: full / 2.0), content)).to be_within(1e-6).of(0.5)
    end

    # Steam in a cylinder is the working fluid; water is the hazard. The tag filter is part of
    # the mechanism, not a convenience.
    it "ignores the gas it is there to work with" do
      node = cylinder
      expect(node.occupancy(charged(node, water_kg: 0.0, steam_kg: 5.0), content)).to eq(0.0)
    end

    it "is not clamped above 1.0, because how far past the limit decides how hard it fails" do
      node = cylinder
      full = node.obstruction_volume_m3 * content.density(:water)

      expect(node.occupancy(charged(node, water_kg: full * 2.0), content)).to be > 1.9
    end
  end

  describe "the pressure at top dead centre" do
    # `pressure_pa` reports the charge spread over the WHOLE cylinder, so filling the clearance
    # with enough water to destroy the engine moves it by about 7%. The pressure that matters is
    # one a lumped body never experiences, and it has to be reconstructed — exactly as
    # `mean_effective_pressure` reconstructs a diagram this model never draws.
    it "rises steeply with occupancy while the plain vessel pressure barely moves" do
      node = cylinder
      full = node.obstruction_volume_m3 * content.density(:water)

      dry = charged(node, water_kg: 0.0)
      wet = charged(node, water_kg: full * 0.9)

      plain_ratio = node.pressure_pa(wet, content) / node.pressure_pa(dry, content)
      tdc_ratio = node.compression_pressure_pa(wet, content) / node.compression_pressure_pa(dry, content)

      expect(plain_ratio).to be < 1.5
      expect(tdc_ratio).to be > 10.0
    end

    it "is monotone in occupancy" do
      node = cylinder
      full = node.obstruction_volume_m3 * content.density(:water)

      readings = (0..20).map { |i| node.compression_pressure_pa(charged(node, water_kg: full * i / 21.0), content) }

      expect(readings.each_cons(2)).to all(satisfy { |a, b| b >= a })
    end

    it "is an ordinary compression cushion when dry" do
      node = cylinder
      dry = charged(node, water_kg: 0.0)

      ratio = node.compression_pressure_pa(dry, content) / node.pressure_pa(dry, content)
      expect(ratio).to be_between(1.5, 4.0)
    end
  end

  # **How the water gets in, which is the half that was arithmetically impossible.**
  #
  # A positive-displacement machine swallows a *volume* and gets whatever is in it. `admission_kg`
  # used to price the swept volume at the working fluid's **gas** density, so it asked for the
  # mass that volume would hold *if the supply were dry* — and a steam chest full of primed water
  # handed the piston a few hundred grams of it. Hydraulic lock at speed was not tuned out, it
  # was unreachable: the cylinder never asked for a slug.
  describe "swallowing what the supply actually holds" do
    let(:node) { cylinder(cutoff_control_id: :cutoff) }

    it "asks for a far heavier charge when the chest is full of water" do
      controls = { cutoff: 40.0 }
      dry = node.admission_kg(charged(node, water_kg: 0.0),
                              context(node, omega: 14.0, controls: controls))
      wet = node.admission_kg(charged(node, water_kg: 0.0),
                              context(node, omega: 14.0, controls: controls, chest_water: 300.0))

      expect(wet).to be > dry * 50
    end

    # The figure the geometry implies, not merely "more". Per revolution the piston takes
    # `cutoff × swept_volume` of whatever the supply is, so the mass is that volume times the
    # supply's mean density — and at a flooded chest that is a slug, in one tick.
    it "takes the swept volume times the supply's mean density" do
      controls = { cutoff: 100.0 }
      ctx = context(node, omega: 14.0, controls: controls, chest_water: 500.0)
      revolutions = 14.0 / (2.0 * Math::PI) * ctx.dt
      # 502 kg of steam and water in a 1 m³ chest.
      expected = revolutions * node.swept_volume_m3 * 502.0

      expect(node.displacement_kg(ctx)).to be_within(expected * 0.02).of(expected)
    end

    it "is unchanged by the mechanism while the supply is dry" do
      ctx = context(node, omega: 14.0, controls: { cutoff: 40.0 })

      expect(node.supply_bulk_density(ctx))
        .to be_within(node.supply_gas_density(ctx) * 0.05).of(node.supply_gas_density(ctx))
    end

    # A slug is a matter of a revolution or two, which is the whole difference between this and
    # the condensation route: the water arrives already liquid and no heat has to be shed for it.
    it "can fill the clearance from a flooded chest inside a few revolutions" do
      ctx = context(node, omega: 14.0, controls: { cutoff: 60.0 }, chest_water: 400.0)
      clearance_kg = node.obstruction_volume_m3 * content.density(:water)
      per_tick = node.admission_kg(charged(node, water_kg: 0.0), ctx)

      expect(per_tick * 20).to be > clearance_kg
    end
  end

  describe "hydraulic lock" do
    # Graded by the energy the driveline carries, which is what the sources describe and what
    # makes this a predicament rather than an invisible timer: a heavy wheel at speed bends a
    # rod, a light or slow one stalls, and a stopped engine fills quietly and can still be
    # drained.
    let(:node) { cylinder }
    let(:full) { node.obstruction_volume_m3 * content.density(:water) }

    it "does not break a stopped engine, however full it is" do
      state = charged(node, water_kg: full * 1.5)

      expect(node.overload?(state, context(node, omega: 0.0), 1.0)).to be false
    end

    it "destroys a cylinder that is turning when it locks" do
      state = charged(node, water_kg: full * 1.5)

      expect(node.overload?(state, context(node, omega: 15.0), 1.0)).to be true
    end

    # A stopped, flooded cylinder is recoverable — that is the whole point of the grading, and
    # it is why a driver opens the cocks BEFORE moving off rather than after.
    it "leaves a slow engine to stall rather than breaking it" do
      state = charged(node, water_kg: full * 1.5)
      slow = context(node, omega: 1.0)

      expect(node.overload?(state, slow, 1.0)).to be false
      expect(node.apply(state, slow, ReactorSim::Grant.none).fetch(:torque)).to be < 0.0
    end

    it "drives normally when it is not locked" do
      state = charged(node, water_kg: full * 0.1)

      expect(node.apply(state, context(node, omega: 15.0), ReactorSim::Grant.none)
                 .fetch(:torque)).to be > 0.0
    end

    it "gives way sooner when it is already worn" do
      state = charged(node, water_kg: full * 0.6)
      ctx = context(node, omega: 15.0)

      expect(node.overload?(state, ctx, 1.0)).to be false
      expect(node.overload?(state, ctx, 0.5)).to be true
    end

    # **The distinctive claim of the energy rule, and the reason it replaced a speed threshold.**
    # What drives the piston into the water is the rotating mass's stored energy, so the same
    # slug at the same speed wrecks a heavy wheel and merely stops a light one. A declared
    # `lock_omega` could not express this at all — and worse, it was unreachable on a real
    # engine, because filling needs a standstill and it only destroyed above a speed a locked
    # cylinder can never reach (a lock makes negative torque, so it cannot accelerate into it).
    it "breaks under a heavy wheel and stalls under a light one, at the same speed" do
      state = charged(node, water_kg: full * 1.5)

      expect(node.overload?(state, context(node, omega: 15.0, wheel_kg: 3_200.0), 1.0)).to be true
      expect(node.overload?(state, context(node, omega: 15.0, wheel_kg: 150.0), 1.0)).to be false
    end

    # The comparison is against a real quantity of work, not a scaled threshold: as the clearance
    # fills, the space left collapses and the work needed to reach top dead centre runs away.
    it "costs steeply more work to compress as the clearance fills" do
      work = [ 0.25, 0.5, 0.9 ].map { |f|
        node.compression_work_joules(charged(node, water_kg: full * f), content)
      }

      expect(work).to eq(work.sort)
      expect(work.last).to be > work.first * 3
    end
  end

  describe "a relief valve has to be pointed at the pressure that does the damage" do
    # **A valve sensing `pressure_pa` here would look like protection and be none.** The charge
    # spread over the whole cylinder barely moves as the clearance fills, so the plain vessel
    # pressure gives no warning at all of the thing that destroys it.
    it "lifts on the compression pressure well before the cylinder would break" do
      node = cylinder
      full = node.obstruction_volume_m3 * content.density(:water)
      valve = ReactorSim::Nodes::ReliefValve.new(
        id: :relief, senses: :cylinder, senses_quantity: :compression_pressure_pa,
        relief_pressure_pa: 900_000.0, max_kg_per_s: 2.0, conductance: 0.02
      )
      nodes = { cylinder: node, relief: valve }

      lifting = lambda { |water|
        states = { cylinder: charged(node, water_kg: water) }
        ctx = ReactorSim::Tick::Context.new(
          controls: {}, dt: 0.25, tick: 1, content: content, nodes: nodes, states: states
        )
        valve.lifting?(ctx)
      }

      expect(lifting.call(0.0)).to be false
      expect(lifting.call(full * 0.7)).to be true
    end

    it "stays shut on the same state when it senses the plain vessel pressure instead" do
      node = cylinder
      full = node.obstruction_volume_m3 * content.density(:water)
      blind = ReactorSim::Nodes::ReliefValve.new(
        id: :relief, senses: :cylinder, relief_pressure_pa: 900_000.0,
        max_kg_per_s: 2.0, conductance: 0.02
      )
      ctx = ReactorSim::Tick::Context.new(
        controls: {}, dt: 0.25, tick: 1, content: content,
        nodes: { cylinder: node, relief: blind },
        states: { cylinder: charged(node, water_kg: full * 0.7) }
      )

      expect(blind.lifting?(ctx)).to be false
    end
  end

  # The test the abstraction had to pass to earn a file: a second caller with a different
  # characteristic volume, a different tag filter and a completely different consequence.
  describe "a bed is choked by its own waste" do
    def grate(**overrides)
      ReactorSim::Nodes::Vessel.new(
        id: :grate, volume_m3: 6.0, obstruction_tags: [ :waste ], void_fraction: 0.12,
        reactions: [ :coal_combustion ], **overrides
      )
    end

    def with_ash(node, kg)
      parcels = [ ReactorSim::Parcel.build(resource: :coal, kg: 100.0,
                                           temperature_k: 900.0, content: content) ]
      if kg.positive?
        parcels << ReactorSim::Parcel.build(resource: :ash, kg: kg,
                                            temperature_k: 900.0, content: content)
      end
      node.rebalance(node.initial_state(rng, content).merge(parcels: parcels), content)
    end

    it "measures against the void between the fuel, not the whole firebox" do
      node = grate
      expect(node.obstruction_volume_m3).to be_within(1e-9).of(6.0 * 0.12)
    end

    it "slows the fire as ash fills the gaps the air comes through" do
      node = grate
      clear = node.reaction_throttle(with_ash(node, 0.0), content)
      banked = node.reaction_throttle(with_ash(node, 300.0), content)

      expect(clear).to eq(1.0)
      expect(banked).to be < 0.5
      expect(banked).to be >= 0.0
    end

    it "ignores the fuel, which is solid but is not the obstruction" do
      node = grate

      expect(node.reaction_throttle(with_ash(node, 0.0), content)).to eq(1.0)
    end

    # Almost every vessel is a tank that does not care what shape its contents are.
    it "leaves an ordinary vessel unthrottled" do
      plain = ReactorSim::Nodes::Vessel.new(id: :tank, volume_m3: 6.0)

      expect(plain.reaction_throttle(with_ash(plain, 300.0), content)).to eq(1.0)
    end
  end
end
