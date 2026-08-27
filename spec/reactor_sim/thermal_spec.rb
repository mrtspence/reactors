# frozen_string_literal: true

require "reactor_sim"
require "support/loop_rig"

# Time compression is a dial the designer turns (docs/simulation_architecture.md §7), so
# nothing in the physics may depend on dt being small. These specs are what make that
# claim checkable.
#
# Explicit Euler fails all of them: at dt=100 s the two-body case here returns a
# temperature of -500 K. That is why the thermal model is closed-form.
RSpec.describe "thermal integration" do
  let(:content) { ReactorSim::Content.default }

  # A minimal two-node rig with one thermal link and nothing else happening, so the
  # integrator is the only thing under test.
  def pair(t_a:, t_b:, conductance: 200.0, capacity: 5.0e4)
    a = ReactorSim::Nodes::Vessel.new(id: :a, volume_m3: 1.0, heat_capacity: capacity,
                                      initial_temperature_k: t_a)
    b = ReactorSim::Nodes::Vessel.new(id: :b, volume_m3: 1.0, heat_capacity: capacity,
                                      initial_temperature_k: t_b)
    ReactorSim::Operation.new(
      id: :pair, type: :pair, seed: 1, nodes: [ a, b ],
      thermal_links: [ ReactorSim::ThermalLink.new(a: :a, b: :b, conductance:) ]
    )
  end

  def temperatures(op)
    op.nodes.transform_values { |n| n.temperature_k(op.state.fetch(:nodes).fetch(n.id), content) }
  end

  describe "a single link" do
    it "converges on the shared equilibrium instead of overshooting it" do
      [ 0.1, 1.0, 20.0, 100.0, 1000.0 ].each do |dt|
        op = pair(t_a: 500.0, t_b: 300.0)
        op.step!(tick: 1, dt: dt)
        t = temperatures(op)

        # Equal heat capacities, so equilibrium is the midpoint. Neither body may cross it.
        expect(t[:a]).to be_between(400.0, 500.0), "node a overshot at dt=#{dt}: #{t[:a]}"
        expect(t[:b]).to be_between(300.0, 400.0), "node b overshot at dt=#{dt}: #{t[:b]}"
      end
    end

    it "conserves energy exactly at every timestep" do
      [ 0.1, 1.0, 100.0, 1000.0 ].each do |dt|
        op = pair(t_a: 500.0, t_b: 300.0)
        before = op.total_joules
        op.step!(tick: 1, dt: dt)

        expect(op.total_joules).to be_within(before.abs * 1e-12).of(before),
          "energy changed at dt=#{dt}"
      end
    end

    it "reaches equilibrium rather than diverging when the timestep is enormous" do
      op = pair(t_a: 500.0, t_b: 300.0)
      op.step!(tick: 1, dt: 1_000_000.0)
      t = temperatures(op)

      expect(t[:a]).to be_within(0.01).of(400.0)
      expect(t[:b]).to be_within(0.01).of(400.0)
    end
  end

  # The case that motivated routing heat through the arbiter. Pairwise closed form alone
  # conserves energy but lets each link independently move most of the way to *its own*
  # equilibrium, so contributions stack: three 600 K bodies drove one small 300 K body to
  # 1067 K. Capping the total is what makes networks behave.
  describe "several links converging on one small node" do
    def star(dt:)
      cold = ReactorSim::Nodes::Vessel.new(id: :cold, volume_m3: 1.0, heat_capacity: 1.0e3,
                                           initial_temperature_k: 300.0)
      hots = (1..3).map do |i|
        ReactorSim::Nodes::Vessel.new(id: :"hot#{i}", volume_m3: 1.0, heat_capacity: 5.0e4,
                                      initial_temperature_k: 600.0)
      end
      op = ReactorSim::Operation.new(
        id: :star, type: :star, seed: 1, nodes: [ cold ] + hots,
        thermal_links: hots.map { |h| ReactorSim::ThermalLink.new(a: h.id, b: :cold, conductance: 200.0) }
      )
      op.step!(tick: 1, dt: dt)
      op
    end

    it "never drives the cold node past its hottest neighbour" do
      [ 0.1, 1.0, 10.0, 100.0 ].each do |dt|
        t = temperatures(star(dt: dt))
        expect(t[:cold]).to be <= 600.001,
          "cold node reached #{t[:cold].round(2)} K at dt=#{dt}, above every source"
      end
    end

    it "still conserves energy exactly while bounded" do
      op = star(dt: 10.0)
      expected = (1.0e3 * 300.0) + (3 * 5.0e4 * 600.0)

      expect(op.total_joules).to be_within(expected * 1e-12).of(expected)
    end

    it "settles at the true multi-body equilibrium when left to run" do
      cold = ReactorSim::Nodes::Vessel.new(id: :cold, volume_m3: 1.0, heat_capacity: 1.0e3,
                                           initial_temperature_k: 300.0)
      hots = (1..3).map do |i|
        ReactorSim::Nodes::Vessel.new(id: :"hot#{i}", volume_m3: 1.0, heat_capacity: 5.0e4,
                                      initial_temperature_k: 600.0)
      end
      op = ReactorSim::Operation.new(
        id: :star, type: :star, seed: 1, nodes: [ cold ] + hots,
        thermal_links: hots.map { |h| ReactorSim::ThermalLink.new(a: h.id, b: :cold, conductance: 200.0) }
      )
      60.times { |i| op.step!(tick: i + 1, dt: 5.0) }

      expected = ((1.0e3 * 300.0) + (3 * 5.0e4 * 600.0)) / (1.0e3 + (3 * 5.0e4))
      temperatures(op).each_value { |t| expect(t).to be_within(0.5).of(expected) }
    end
  end

  describe "phase change" do
    # Pressure and the liquid/vapour split are coupled. Solving them in sequence — boil at
    # last tick's pressure, then recompute pressure — oscillates violently: 0 kg of steam
    # on even ticks and 51 kg on odd ones, with pressure swinging 101 kPa to 2.5 MPa.
    it "does not oscillate between phases on alternating ticks" do
      op = ReactorSim::Match
           .create(id: "p", seed: 7, operations: [ { id: "rig", type: :loop_rig } ], time_scale: 4.0)
           .operation(:rig)
      op.set_control(:burner, 50)
      # Sealed, so the only thing that can change the steam mass is the phase solve itself.
      # With the valve open steam legitimately leaves and the mass is no longer monotonic,
      # which would hide the very thing this is watching for.
      op.set_control(:steam_valve, 0)

      steam = (1..160).map do |t|
        op.step!(tick: t)
        parcel = op.state.fetch(:nodes).fetch(:boiler).fetch(:parcels)
                   .find { |p| p.fetch(:resource) == :steam }
        parcel ? parcel.fetch(:kg) : 0.0
      end

      # Monotonic while heating: every tick must produce at least as much steam as the last.
      drops = steam.each_cons(2).count { |a, b| b < a - 1e-6 }
      expect(drops).to eq(0), "steam mass fell on #{drops} ticks — phase solve is oscillating"
    end

    it "boils at a higher temperature when the vessel is pressurised" do
      water = ReactorSim::Content.default.resource(:water)
      at_1_atm = ReactorSim::Resources::Saturation.saturation_temperature_k(water, 101_325.0)
      at_10_atm = ReactorSim::Resources::Saturation.saturation_temperature_k(water, 1_013_250.0)

      expect(at_1_atm).to be_within(0.5).of(373.15)
      expect(at_10_atm).to be > at_1_atm + 60
    end

    it "conserves energy exactly across the liquid/vapour boundary" do
      content = ReactorSim::Content.default
      parcels = [ ReactorSim::Parcel.build(resource: :water, kg: 400.0,
                                           temperature_k: 441.0, content: content) ]
      before = ReactorSim::Parcel.total_joules(parcels)

      after, = ReactorSim::Resources::Saturation.solve(:water, :steam, parcels,
                                                       volume_m3: 4.0, content: content)

      expect(ReactorSim::Parcel.total_joules(after)).to be_within(before.abs * 1e-12).of(before)
      expect(ReactorSim::Parcel.total_kg(after)).to be_within(1e-9).of(400.0)
    end
  end
end
