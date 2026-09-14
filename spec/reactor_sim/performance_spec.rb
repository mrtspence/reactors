# frozen_string_literal: true

require "reactor_sim"

# ~100 nodes is the stated upper bound for an operation — an RBMK modelled as clusters,
# with feedwater pumps, backup lines, relief paths and control rods, but never per-channel
# (docs/simulation_architecture.md §1).
#
# A guard rather than a benchmark. It exists so that a change which quietly makes the tick
# an order of magnitude slower — reintroducing allocation into the phase solve, say, or
# substepping something that used to be closed-form — fails here instead of being noticed
# months later as "the game feels laggy".
RSpec.describe "tick performance" do
  # 25 stages of vessel + conduit + vessel + conduit, wired into one long recirculating
  # loop. 100 nodes, 100 mass links, 25 thermal links.
  def big_operation
    nodes = []
    links = []
    thermal = []

    25.times do |i|
      vessel = ReactorSim::Nodes::Vessel.new(
        id: :"vessel_#{i}", volume_m3: 3.0, heat_capacity: 2.0e5,
        ambient_conductance: 30.0, initial_temperature_k: 320.0 + i,
        initial_contents: [ { resource: :water, kg: 40.0, temperature_k: 320.0 + i } ],
        ports: [
          ReactorSim::Port.new(id: :in, direction: :inlet, max_kg_per_s: 4.0),
          ReactorSim::Port.new(id: :out, direction: :outlet, max_kg_per_s: 4.0)
        ]
      )
      pipe_a = ReactorSim::Nodes::Conduit.new(
        id: :"pipe_a_#{i}", max_kg_per_s: 4.0,
        heat_capacity: 1.0e4, ambient_conductance: 8.0
      )
      drum = ReactorSim::Nodes::Vessel.new(
        id: :"drum_#{i}", volume_m3: 2.0, heat_capacity: 1.0e5,
        ambient_conductance: 20.0, initial_temperature_k: 310.0,
        ports: [
          ReactorSim::Port.new(id: :in, direction: :inlet, max_kg_per_s: 4.0),
          ReactorSim::Port.new(id: :out, direction: :outlet, max_kg_per_s: 4.0)
        ]
      )
      pipe_b = ReactorSim::Nodes::Conduit.new(
        id: :"pipe_b_#{i}", max_kg_per_s: 4.0,
        heat_capacity: 1.0e4, ambient_conductance: 8.0
      )

      nodes.concat([ vessel, pipe_a, drum, pipe_b ])
      links.concat([
        ReactorSim::Link.new(from: [ vessel.id, :out ],  to: [ pipe_a.id, :inlet ]),
        ReactorSim::Link.new(from: [ pipe_a.id, :outlet ], to: [ drum.id, :in ]),
        ReactorSim::Link.new(from: [ drum.id, :out ],    to: [ pipe_b.id, :inlet ]),
        ReactorSim::Link.new(from: [ pipe_b.id, :outlet ], to: [ :"vessel_#{(i + 1) % 25}", :in ])
      ])
      thermal << ReactorSim::ThermalLink.new(a: vessel.id, b: pipe_a.id, conductance: 500.0)
    end

    ReactorSim::Operation.new(id: :big, type: :big, seed: 3, nodes:, links:,
                              thermal_links: thermal, time_scale: 4.0)
  end

  it "builds a hundred-node operation wired into a closed loop" do
    op = big_operation

    expect(op.nodes.size).to eq(100)
    expect(op.links.size).to eq(100)
  end

  it "steps a hundred nodes fast enough to stay well inside the 250 ms budget" do
    op = big_operation
    op.step!(tick: 0) # warm up, so the first-call cost is not what gets measured

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    40.times { |i| op.step!(tick: i + 1) }
    per_tick_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 40 * 1000

    # Deliberately loose. The runner has 250 ms per tick and hosts many matches, so the
    # number to care about is the order of magnitude, not the digit.
    expect(per_tick_ms).to be < 120.0,
      format("%.1f ms per tick at 100 nodes — measured ~55 ms; something got much slower", per_tick_ms)
  end

  # The rig above has 25 thermal components of two nodes each, which is the shape most
  # operations have and the cheap case for `Relaxation`. This is the expensive one: ONE
  # connected network spanning every node, so the elimination is a single 100×100 system
  # rather than 25 tiny ones.
  #
  # Worth guarding separately, because the two differ by more than 4×: measured 13.2 ms for
  # one 100-node component against 3.0 ms for the same nodes as 50 pairs. Nothing in the game
  # is wired this way today — it is the bound, not the expectation.
  it "solves one fully connected 100-node thermal network inside the budget" do
    nodes = (0...100).map do |i|
      ReactorSim::Nodes::Vessel.new(
        id: :"chain_#{i}", volume_m3: 3.0, heat_capacity: 2.0e5,
        ambient_conductance: 30.0, initial_temperature_k: 320.0 + i,
        initial_contents: [ { resource: :water, kg: 40.0, temperature_k: 320.0 + i } ]
      )
    end
    thermal = (0...99).map do |i|
      ReactorSim::ThermalLink.new(a: :"chain_#{i}", b: :"chain_#{i + 1}", conductance: 500.0)
    end
    op = ReactorSim::Operation.new(id: :chain, type: :chain, seed: 3, nodes: nodes,
                                   thermal_links: thermal, time_scale: 4.0)
    op.step!(tick: 0)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    20.times { |i| op.step!(tick: i + 1) }
    per_tick_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) / 20 * 1000

    expect(per_tick_ms).to be < 150.0,
      format("%.1f ms per tick for one 100-node network — measured ~52 ms", per_tick_ms)
  end

  it "still conserves mass exactly at a hundred nodes" do
    op = big_operation
    before = op.total_mass
    40.times { |i| op.step!(tick: i + 1) }

    expect(ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger))
      .to be_within(before * 1e-9).of(before)
  end
end
