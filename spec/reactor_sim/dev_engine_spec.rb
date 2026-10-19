# frozen_string_literal: true

require "reactor_sim"
require "support/conservation"

RSpec.describe ReactorSim::Operations::DevEngine do
  # A line shaft whose only load is its own windage — about 24 kW at speed.
  ReactorSim::Operations.register(:dev_engine_sink_rig, harness: true) do |id:, seed:, **opts|
    ReactorSim::Operation.new(
      id: id, type: :dev_engine_sink_rig, seed: seed,
      time_scale: opts.fetch(:time_scale, 1.0), state: opts[:state], rngs: opts[:rngs],
      content: opts[:content],
      nodes: [ ReactorSim::Nodes::Import.new(id: :line_shaft, rated_torque_nm: 5.4e3,
                                             rated_omega: 22.0, moment_of_inertia: 900.0,
                                             friction: 50.0) ]
    )
  end

  def roped(range:, setting:)
    match = ReactorSim::Match.create(
      id: "x", seed: 1,
      operations: [ { id: "bench", type: :dev_engine }, { id: "sink", type: :dev_engine_sink_rig } ],
      couplings: [ { from: %w[bench drive], to: %w[sink line_shaft] } ]
    )
    match.apply([ { type: "set_control", operation_id: "bench", control_point_id: "range", value: range },
                  { type: "set_control", operation_id: "bench", control_point_id: "setting",
                    value: setting } ])
    match
  end

  def drive(match) = match.operation(:bench).state.fetch(:nodes).fetch(:drive)

  def balance(op) = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

  it "sets setting × 10^range watts, between 1 kW and 1 GW" do
    node = described_class::Drive.new(id: :drive)

    expect(node.setting_w({ range: 3.0, setting: 35.0 })).to eq(35_000.0)
    expect(node.setting_w({ range: 7.0, setting: 100.0 })).to eq(1.0e9)
    expect(node.setting_w({ range: 1.0, setting: 1.0 })).to eq(1.0e3)
  end

  it "is never a machine a player can own" do
    expect(ReactorSim::Operations.catalogued).not_to include(described_class::TYPE)
  end

  it "delivers exactly its setting when the load wants more" do
    match = roped(range: 3.0, setting: 1.0)
    10.times { match.step! }

    expect(drive(match).fetch(:shaft_power_w)).to be_within(1e-6).of(1_000.0)
  end

  it "holds its speed when the setting is more than the load wants, and its books close" do
    match = roped(range: 7.0, setting: 100.0)
    before = match.operations.to_h { |op| [ op.id, balance(op) ] }
    10.times { match.step! }

    expect(match.operation(:bench).nodes.fetch(:drive).omega(drive(match)))
      .to be_within(1e-9).of(described_class::RATED_OMEGA)
    match.operations.each do |op|
      drift = balance(op) - before.fetch(op.id)
      expect(drift.abs).to be <= Conservation::TOLERANCE * [ op.total_joules.abs, 1.0 ].max
    end
  end
end
