# frozen_string_literal: true

require "reactor_sim"
require "support/loop_rig"

# The graph model: closed loops, order-independence, emergent delay, back-pressure and tag
# routing. Between them these are the reasons the engine looks the way it does.
RSpec.describe "the operation graph" do
  def rig(seed: 7, time_scale: 4.0)
    ReactorSim::Match
      .create(id: "g", seed: seed, operations: [ { id: "rig", type: :loop_rig } ], time_scale:)
      .operation(:rig)
  end

  # The single most important property. Recirculation loops, condensate return and backup
  # lines are the normal topology for the operations this engine exists to run, and a
  # topological resolution order has no answer for them. Double buffering does not care.
  describe "closed loops" do
    it "runs a recirculating loop with no ordering, sorting or special case" do
      op = rig
      op.set_control(:burner, 30)

      expect { 200.times { |i| op.step!(tick: i + 1) } }.not_to raise_error
      op.telemetry.each_value do |node|
        expect(node[:temperature_k]).to be_finite if node[:temperature_k]
      end
    end

    it "actually circulates — mass leaves the boiler and comes back round" do
      op = rig
      op.set_control(:burner, 50)
      100.times { |i| op.step!(tick: i + 1) }

      # Only holders are counted: `steam_line` and `return_line` are conduits, and a conduit
      # stops nothing on its way past.
      in_loop = op.telemetry.fetch(:condenser)[:kg].to_f

      expect(in_loop).to be > 0.0, "nothing ever left the boiler"
      expect(op.telemetry.fetch(:boiler)[:kg]).to be < 400.0
    end
  end

  describe "order-independence" do
    # Shuffling the order nodes are declared in must not change a single bit. This is what
    # the double buffer buys, and it is worth asserting directly rather than trusting it.
    it "produces an identical result when nodes are declared in a different order" do
      digests = [ false, true ].map do |shuffled|
        nodes = shuffled ? LoopRig.nodes.reverse : LoopRig.nodes
        op = ReactorSim::Operation.new(
          id: :rig, type: :loop_rig, seed: 7, time_scale: 4.0, nodes: nodes,
          links: LoopRig.links, thermal_links: LoopRig.thermal_links,
          control_points: LoopRig.control_points
        )
        op.set_control(:burner, 50)
        60.times { |i| op.step!(tick: i + 1) }
        ReactorSim.canonical(op.to_h)
      end

      expect(digests.first).to eq(digests.last)
    end

    it "produces an identical result when links are declared in a different order" do
      digests = [ false, true ].map do |shuffled|
        op = ReactorSim::Operation.new(
          id: :rig, type: :loop_rig, seed: 7, time_scale: 4.0, nodes: LoopRig.nodes,
          links: shuffled ? LoopRig.links.reverse : LoopRig.links,
          thermal_links: LoopRig.thermal_links, control_points: LoopRig.control_points
        )
        op.set_control(:burner, 50)
        60.times { |i| op.step!(tick: i + 1) }
        ReactorSim.canonical(op.to_h)
      end

      expect(digests.first).to eq(digests.last)
    end
  end

  # There is no `delay:` parameter anywhere. Delay is a consequence of graph shape, one
  # tick per hop, and the latency budget is therefore a design decision made by choosing
  # topology (docs/simulation_architecture.md §5).
  describe "delay emerges from hop count" do
    # A hop is now one PATH, not one node. Conduits are resolved through rather than stopped
    # at, so `a -> [pipe] -> b -> [pipe] -> c` is two hops and takes two ticks — where it used
    # to be four. Holders are the only thing that can be observed, which is the point: they
    # are the only thing that ever really held anything.
    it "takes one tick per hop for material to travel down the chain" do
      tank = lambda do |id, contents|
        ReactorSim::Nodes::Vessel.new(
          id: id, volume_m3: 4.0, initial_temperature_k: 300.0, initial_contents: contents,
          ports: [ ReactorSim::Port.new(id: :in, direction: :inlet, max_kg_per_s: 2.0),
                   ReactorSim::Port.new(id: :out, direction: :outlet, max_kg_per_s: 2.0) ]
        )
      end
      pipe = ->(id) { ReactorSim::Nodes::Conduit.new(id: id, max_kg_per_s: 2.0) }

      op = ReactorSim::Operation.new(
        id: :chain, type: :chain, seed: 1,
        nodes: [ tank.call(:a, [ { resource: :water, kg: 100.0, temperature_k: 300.0 } ]),
                 pipe.call(:ab), tank.call(:b, []), pipe.call(:bc), tank.call(:c, []) ],
        links: [ ReactorSim::Link.new(from: [ :a, :out ],   to: [ :ab, :inlet ]),
                 ReactorSim::Link.new(from: [ :ab, :outlet ], to: [ :b, :in ]),
                 ReactorSim::Link.new(from: [ :b, :out ],   to: [ :bc, :inlet ]),
                 ReactorSim::Link.new(from: [ :bc, :outlet ], to: [ :c, :in ]) ]
      )

      first_nonzero = {}
      watched = %i[b c]
      (1..10).each do |t|
        op.step!(tick: t)
        watched.each { |id| first_nonzero[id] ||= t if op.telemetry.fetch(id)[:kg].to_f > 1e-6 }
      end

      expect(first_nonzero[:b]).to eq(1)
      expect(first_nonzero[:c]).to eq(2)
    end
  end

  # Rejection is what makes a blocked line back up to its source instead of quietly
  # annihilating mass. The old engine got this wrong and destroyed ten units of steam
  # without recording it.
  describe "back-pressure" do
    it "keeps material with the sender when the downstream valve is shut" do
      op = rig
      op.set_control(:burner, 100)
      op.set_control(:steam_valve, 0)
      200.times { |i| op.step!(tick: i + 1) }

      expect(op.telemetry.fetch(:condenser)[:kg].to_f).to be_within(1e-9).of(0.0)
      expect(op.telemetry.fetch(:boiler)[:kg].to_f).to be_within(1e-9).of(400.0)
    end

    it "drives pressure up in the vessel that cannot vent" do
      shut, open = [ 0, 100 ].map do |valve|
        op = rig
        op.set_control(:burner, 100)
        op.set_control(:steam_valve, valve)
        150.times { |i| op.step!(tick: i + 1) }
        op.telemetry.fetch(:boiler)[:pressure_pa]
      end

      expect(shut).to be > open
    end
  end

  # Tags govern what may be *transported*, not what may *exist*. Steam that condenses
  # inside a cooling pipe is liquid water in a gas-only conduit, and that is correct — it
  # is why real plants need steam traps. What must never happen is a link carrying a
  # resource its ports reject.
  describe "tag routing" do
    # Inert substances with no phase model, so nothing can turn into anything else and the
    # only thing under test is the tag filter. Also exercises injecting a content registry
    # rather than loading one off disk.
    let(:inert) do
      ReactorSim::Content.build(resources: {
        brine: { tags: [ :liquid ], specific_heat_j_per_kg_k: 3900, density_kg_per_m3: 1100 },
        vapour: { tags: [ :gas ], specific_heat_j_per_kg_k: 1900,
                  density_kg_per_m3: 0.7, molar_mass_g_per_mol: 20.0 }
      })
    end

    def two_tanks(contents, content)
      source = ReactorSim::Nodes::Vessel.new(
        id: :source, volume_m3: 4.0, initial_contents: contents, initial_temperature_k: 300.0,
        ports: [ ReactorSim::Port.new(id: :out, direction: :outlet, accepts: [ :gas ], max_kg_per_s: 5.0) ]
      )
      # A holder, not a conduit: the tag filter under test lives on the port either way, and
      # only a holder has contents to assert on.
      sink = ReactorSim::Nodes::Vessel.new(
        id: :sink, volume_m3: 4.0, initial_temperature_k: 300.0,
        ports: [ ReactorSim::Port.new(id: :inlet, direction: :inlet, accepts: [ :gas ],
                                      max_kg_per_s: 5.0) ]
      )
      op = ReactorSim::Operation.new(
        id: :tags, type: :tags, seed: 1, nodes: [ source, sink ], content: content,
        links: [ ReactorSim::Link.new(from: [ :source, :out ], to: [ :sink, :inlet ]) ]
      )
      5.times { |i| op.step!(tick: i + 1, dt: 1.0) }
      op
    end

    it "will not carry a resource the ports reject" do
      op = two_tanks([ { resource: :brine, kg: 100.0, temperature_k: 300.0 } ], inert)

      expect(op.telemetry.fetch(:sink)[:kg].to_f).to be_within(1e-9).of(0.0)
      expect(op.telemetry.fetch(:source)[:kg].to_f).to be_within(1e-9).of(100.0)
    end

    it "carries a resource the ports do accept" do
      op = two_tanks([ { resource: :vapour, kg: 2.0, temperature_k: 400.0 } ], inert)

      expect(op.telemetry.fetch(:sink)[:kg].to_f).to be > 0.0
    end
  end

  describe "wiring validation" do
    it "rejects a link to a node that does not exist" do
      expect {
        ReactorSim::Operation.new(
          id: :bad, type: :bad, seed: 1, nodes: LoopRig.nodes,
          links: [ ReactorSim::Link.new(from: [ :boiler, :steam ], to: [ :nowhere, :inlet ]) ]
        )
      }.to raise_error(ReactorSim::Error, /no node nowhere/)
    end

    it "rejects a link that runs into an outlet" do
      expect {
        ReactorSim::Operation.new(
          id: :bad, type: :bad, seed: 1, nodes: LoopRig.nodes,
          links: [ ReactorSim::Link.new(from: [ :boiler, :steam ], to: [ :condenser, :drain ]) ]
        )
      }.to raise_error(ReactorSim::Error, /not an inlet/)
    end
  end
end
