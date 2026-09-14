# frozen_string_literal: true

require "reactor_sim"

# Guards for the failure class documented in docs/design_sketches/flow_through_issue_draft.md.
#
# A conduit used to hold what passed through it for one tick, which made its inventory obey
# `h -> T - h` — an involution with eigenvalue exactly -1, so it oscillated forever and could
# not damp. Nothing in the suite noticed: conservation held perfectly throughout, no exception
# was raised, and the only symptom was that things downstream quietly starved.
#
# These are the specs that would have caught it.
RSpec.describe "transport" do
  # Inert so nothing can boil, react or condense — the only thing under test is how material
  # moves.
  let(:content) do
    ReactorSim::Content.build(resources: {
      water: { tags: [ :liquid ], specific_heat_j_per_kg_k: 4181, density_kg_per_m3: 997 }
    })
  end

  def tank(id, kg, volume: 40.0, rate: 4.0)
    ReactorSim::Nodes::Vessel.new(
      id: id, volume_m3: volume, initial_temperature_k: 300.0,
      initial_contents: kg.zero? ? [] : [ { resource: :water, kg: kg, temperature_k: 300.0 } ],
      ports: [ ReactorSim::Port.new(id: :in, direction: :inlet, max_kg_per_s: rate),
               ReactorSim::Port.new(id: :out, direction: :outlet, max_kg_per_s: rate) ]
    )
  end

  def pipe(id, rate) = ReactorSim::Nodes::Conduit.new(id: id, max_kg_per_s: rate)

  # source -> [feed] -> middle -> [drain] -> sink
  #
  # `middle` is the flow-through node: material passes through it continuously, which is
  # exactly the shape that starved the firebox of air on alternate ticks.
  def flow_rig(feed_rate: 2.0, drain_rate: 2.0)
    ReactorSim::Operation.new(
      id: :flow, type: :flow, seed: 1, content: content,
      nodes: [ tank(:source, 1000.0), pipe(:feed, feed_rate),
               tank(:middle, 0.0), pipe(:drain, drain_rate), tank(:sink, 0.0) ],
      links: [ ReactorSim::Link.new(from: [ :source, :out ], to: [ :feed, :inlet ]),
               ReactorSim::Link.new(from: [ :feed, :outlet ], to: [ :middle, :in ]),
               ReactorSim::Link.new(from: [ :middle, :out ], to: [ :drain, :inlet ]),
               ReactorSim::Link.new(from: [ :drain, :outlet ], to: [ :sink, :in ]) ]
    )
  end

  def series(op, node, ticks)
    (1..ticks).map { |t| op.step!(tick: t); op.telemetry.fetch(node)[:kg].to_f }
  end

  describe "a conduit is not a bucket" do
    it "holds no material at all" do
      op = flow_rig
      20.times { |i| op.step!(tick: i + 1) }

      %i[feed drain].each do |id|
        expect(op.state.fetch(:nodes).fetch(id)).not_to have_key(:parcels)
      end
    end

    # The regression that started all of this. `middle` alternated between a slug and nothing
    # at all, indefinitely, and any node reading it instantaneously concluded it had starved.
    it "does not leave a flow-through node alternating between two values" do
      values = series(flow_rig, :middle, 40).last(20)

      alternating = values.each_cons(3).count do |a, b, c|
        (a - c).abs < 1e-9 && (a - b).abs > 1e-6
      end

      expect(alternating).to eq(0), "middle alternates: #{values.map { |v| v.round(4) }.inspect}"
    end

    # A conduit used to deliver about HALF its rating, because it spent every other tick
    # drawing instead of pushing. Nothing measured it, so the steam engine's constants were
    # quietly tuned around a factor of two.
    it "delivers its full rated throughput, not half of it" do
      op = flow_rig(feed_rate: 2.0, drain_rate: 0.0)
      dt = ReactorSim::DT

      series(op, :middle, 12)
      before = op.telemetry.fetch(:middle)[:kg].to_f
      op.step!(tick: 13)
      delivered = op.telemetry.fetch(:middle)[:kg].to_f - before

      expect(delivered).to be_within(1e-9).of(2.0 * dt)
    end
  end

  describe "path resolution" do
    it "resolves through a conduit to the holders on either side" do
      path = flow_rig.paths.find { |p| p.conduits == [ :feed ] }

      expect(path.from_node).to eq(:source)
      expect(path.to_node).to eq(:middle)
    end

    it "collapses a chain of conduits into a single path" do
      op = ReactorSim::Operation.new(
        id: :chain, type: :chain, seed: 1, content: content,
        nodes: [ tank(:a, 100.0), pipe(:p1, 2.0), pipe(:p2, 2.0), tank(:b, 0.0) ],
        links: [ ReactorSim::Link.new(from: [ :a, :out ], to: [ :p1, :inlet ]),
                 ReactorSim::Link.new(from: [ :p1, :outlet ], to: [ :p2, :inlet ]),
                 ReactorSim::Link.new(from: [ :p2, :outlet ], to: [ :b, :in ]) ]
      )

      expect(op.paths.length).to eq(1)
      expect(op.paths.first.conduits).to eq(%i[p1 p2])
      # Two conduits, still one hop: material crosses the whole chain in one tick.
      op.step!(tick: 1)
      expect(op.telemetry.fetch(:b)[:kg].to_f).to be > 0.0
    end

    it "is limited by the narrowest conduit on the chain" do
      op = ReactorSim::Operation.new(
        id: :narrow, type: :narrow, seed: 1, content: content,
        nodes: [ tank(:a, 100.0), pipe(:wide, 4.0), pipe(:narrow, 1.0), tank(:b, 0.0) ],
        links: [ ReactorSim::Link.new(from: [ :a, :out ], to: [ :wide, :inlet ]),
                 ReactorSim::Link.new(from: [ :wide, :outlet ], to: [ :narrow, :inlet ]),
                 ReactorSim::Link.new(from: [ :narrow, :outlet ], to: [ :b, :in ]) ]
      )
      op.step!(tick: 1)

      expect(op.telemetry.fetch(:b)[:kg].to_f).to be_within(1e-9).of(1.0 * ReactorSim::DT)
    end

    # A conduit holds nothing, so a line that goes nowhere does not back up — it swallows
    # whatever is put into it. Better to refuse the graph than to lose mass quietly.
    it "refuses a conduit whose outlet goes nowhere" do
      expect {
        ReactorSim::Operation.new(
          id: :dead, type: :dead, seed: 1, content: content,
          nodes: [ tank(:a, 100.0), pipe(:nowhere, 2.0) ],
          links: [ ReactorSim::Link.new(from: [ :a, :out ], to: [ :nowhere, :inlet ]) ]
        )
      }.to raise_error(ReactorSim::Error, /cannot be a dead end/)
    end

    it "refuses a ring of conduits with no holder to settle against" do
      expect {
        ReactorSim::Operation.new(
          id: :ring, type: :ring, seed: 1, content: content,
          nodes: [ tank(:a, 100.0), pipe(:p1, 2.0), pipe(:p2, 2.0) ],
          links: [ ReactorSim::Link.new(from: [ :a, :out ], to: [ :p1, :inlet ]),
                   ReactorSim::Link.new(from: [ :p1, :outlet ], to: [ :p2, :inlet ]),
                   ReactorSim::Link.new(from: [ :p2, :outlet ], to: [ :p1, :inlet ]) ]
        )
      }.to raise_error(ReactorSim::Error, /cycle with no holder/)
    end
  end

  describe "a conduit is still a real part" do
    # Removing the residence must not remove the thermal contact, or a chimney would stop
    # cooling its flue gas and a hot line could never rupture.
    it "takes up the temperature of what crosses it" do
      op = ReactorSim::Operation.new(
        id: :hot, type: :hot, seed: 1, content: content,
        nodes: [ tank(:a, 0.0), pipe(:line, 4.0), tank(:b, 0.0) ],
        links: [ ReactorSim::Link.new(from: [ :a, :out ], to: [ :line, :inlet ]),
                 ReactorSim::Link.new(from: [ :line, :outlet ], to: [ :b, :in ]) ]
      )
      hot = ReactorSim::Parcel.build(resource: :water, kg: 20.0, temperature_k: 450.0,
                                     content: content)
      nodes = op.state.fetch(:nodes)
      op.instance_variable_set(:@state,
                               op.state.merge(nodes: nodes.merge(a: nodes.fetch(:a).merge(parcels: [ hot ]))))

      before = op.nodes[:line].temperature_k(op.state.fetch(:nodes).fetch(:line), content)
      op.step!(tick: 1)
      after = op.nodes[:line].temperature_k(op.state.fetch(:nodes).fetch(:line), content)

      expect(before).to be_within(0.1).of(293.15)
      expect(after).to be > 320.0
    end

    it "passes nothing once it has broken" do
      op = flow_rig
      nodes = op.state.fetch(:nodes)
      op.instance_variable_set(
        :@state, op.state.merge(nodes: nodes.merge(feed: nodes.fetch(:feed).merge(broken: true)))
      )
      before = op.telemetry.fetch(:middle)[:kg].to_f
      5.times { |i| op.step!(tick: i + 1) }

      expect(op.telemetry.fetch(:middle)[:kg].to_f).to be_within(1e-9).of(before)
    end
  end

  # Gas moves down a pressure gradient through `Relaxation`'s network solve. These guard the
  # solver itself rather than the graph, and the first one is the direct regression test for
  # the worst physics bug the engine has had.
  describe "pressure-driven gas" do
    let(:air) do
      ReactorSim::Content.build(resources: {
        air: { tags: [ :gas ], specific_heat_j_per_kg_k: 1005,
               density_kg_per_m3: 1.225, molar_mass_g_per_mol: 28.96 }
      })
    end

    # Two vessels, one pipe. Whatever the conductance, they must arrive at a common pressure.
    def vessels(conductance, a_kg: 6.0, b_kg: 1.0)
      ReactorSim::Operation.new(
        id: :pair, type: :pair, seed: 1, content: air,
        nodes: [
          ReactorSim::Nodes::Vessel.new(
            id: :a, volume_m3: 2.0, heat_capacity: 1.0e4,
            initial_contents: [ { resource: :air, kg: a_kg } ],
            ports: [ ReactorSim::Port.new(id: :out, direction: :outlet, accepts: [ :gas ]) ]
          ),
          ReactorSim::Nodes::Conduit.new(id: :pipe, accepts: [ :gas ], max_kg_per_s: 1.0e9,
                                         conductance: conductance),
          ReactorSim::Nodes::Vessel.new(
            id: :b, volume_m3: 2.0, heat_capacity: 1.0e4,
            initial_contents: [ { resource: :air, kg: b_kg } ],
            ports: [ ReactorSim::Port.new(id: :in, direction: :inlet, accepts: [ :gas ]) ]
          )
        ],
        links: [ ReactorSim::Link.new(from: [ :a, :out ], to: [ :pipe, :inlet ]),
                 ReactorSim::Link.new(from: [ :pipe, :outlet ], to: [ :b, :in ]) ]
      )
    end

    def pressure(op, id) = op.nodes.fetch(id).pressure_pa(op.state.fetch(:nodes).fetch(id), air)

    # **The one that was broken, and the reason mass moved to an implicit network solve.**
    #
    # Under the old explicit law plus its per-node bound, this passed only while `dt < τ`. At
    # any stiffer conductance the two vessels SWAPPED CONTENTS on tick 1 and stayed swapped
    # forever — 6 kg/1 kg became 1 kg/6 kg, 42 kPa against 252 kPa, unchanged after 200 ticks.
    # The bound moved the sender all the way to the receiver's *current* pressure, ignoring
    # that the receiver rises as it fills, which overshoots by exactly 2x for equal capacities.
    #
    # It went unnoticed because every gas coupling in the steam engine has `Atmosphere` on one
    # end, whose capacity is so large the receiver never rises.
    it "equalises two vessels at every conductance, however stiff" do
      [ 0.001, 0.01, 0.1, 1.0, 100.0 ].each do |k|
        op = vessels(k)
        400.times { |i| op.step!(tick: i + 1) }

        expect(pressure(op, :a)).to be_within(1.0).of(147_287.0), "vessel a wrong at k=#{k}"
        expect(pressure(op, :b)).to be_within(1.0).of(147_287.0), "vessel b wrong at k=#{k}"
      end
    end

    it "conserves mass exactly while doing it" do
      op = vessels(1.0)
      before = op.total_mass
      400.times { |i| op.step!(tick: i + 1) }

      expect(op.total_mass).to be_within(before * 1e-12).of(before)
    end

    # A path has a nominal direction; the gradient does not have to agree with it. Backflow
    # used to be structurally impossible — `moles_to_kg` discarded negative transfers before
    # anything could act on them — so a network of one-way couplings had no equilibrium to
    # reach and a single overshoot latched permanently.
    it "runs a path backwards when the gradient is against it" do
      op = vessels(0.1, a_kg: 1.0, b_kg: 6.0)
      20.times { |i| op.step!(tick: i + 1) }

      expect(op.telemetry.fetch(:a)[:kg]).to be > 1.0
      expect(pressure(op, :a)).to be_within(1.0).of(pressure(op, :b))
    end

    it "refuses to run a check valve backwards" do
      op = ReactorSim::Operation.new(
        id: :check, type: :check, seed: 1, content: air,
        nodes: [
          ReactorSim::Nodes::Vessel.new(
            id: :a, volume_m3: 2.0, heat_capacity: 1.0e4,
            initial_contents: [ { resource: :air, kg: 1.0 } ],
            ports: [ ReactorSim::Port.new(id: :out, direction: :outlet, accepts: [ :gas ]) ]
          ),
          ReactorSim::Nodes::Conduit.new(id: :pipe, accepts: [ :gas ], max_kg_per_s: 1.0e9,
                                         conductance: 0.1, one_way: true),
          ReactorSim::Nodes::Vessel.new(
            id: :b, volume_m3: 2.0, heat_capacity: 1.0e4,
            initial_contents: [ { resource: :air, kg: 6.0 } ],
            ports: [ ReactorSim::Port.new(id: :in, direction: :inlet, accepts: [ :gas ]) ]
          )
        ],
        links: [ ReactorSim::Link.new(from: [ :a, :out ], to: [ :pipe, :inlet ]),
                 ReactorSim::Link.new(from: [ :pipe, :outlet ], to: [ :b, :in ]) ]
      )
      20.times { |i| op.step!(tick: i + 1) }

      expect(op.telemetry.fetch(:a)[:kg]).to be_within(1e-9).of(1.0)
    end

    # `time_scale` is a design dial, so the same simulated interval must give the same answer
    # however it is cut up. An explicit scheme fails this outright at the conductances the
    # steam engine actually uses.
    it "reaches the same equilibrium at any timestep" do
      settled = [ 0.25, 2.5, 25.0 ].map do |dt|
        op = vessels(1.0)
        (100.0 / dt).ceil.times { |i| op.step!(tick: i + 1, dt: dt) }
        pressure(op, :a)
      end

      expect(settled).to all(be_within(1.0).of(147_287.0))
    end
  end
end
