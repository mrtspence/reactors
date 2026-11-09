# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **The haulage door.** Where the road crosses from intake to return there is a door, and every set
# of tubs opens it. A trapper shuts it after them; a self-closing door shuts itself; left open, the
# air takes the short way back to the fan and the district starves. An explosion blows it out.
# Constructed states, a handful of ticks each.
RSpec.describe "the haulage door" do
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  def pit(door = :plain_door) = build_pit(id: "d", seed: 1, chassis: :single_shaft, loadout: { door: door })
  def open(op) = op.state.dig(:nodes, :door, :open)
  def door(op) = op.nodes.fetch(:door)

  # One tick of the door's own rule, against a road whose traffic is given as of last tick — as a
  # share of a full gang's — and a trapper working at `trapping` percent.
  def after_a_tick(op, open:, tubs: 0.0, trapping: 0.0)
    road = op.nodes.fetch(:tub_road)
    carried = tubs * road.full_crew_kg_per_s * ReactorSim::DT
    states = op.state[:nodes].merge(tub_road: op.state.dig(:nodes, :tub_road).merge(carried_kg: carried))
    ctx = ReactorSim::Tick::Context.new(controls: { trapping: trapping }, dt: ReactorSim::DT,
                                        nodes: op.nodes, states: states)
    door(op).apply(op.state.dig(:nodes, :door).merge(open: open), ctx, nil).fetch(:open)
  end

  it "is pushed open by the tubs, and stays open with nobody to shut it" do
    expect(after_a_tick(pit, open: 0.0, tubs: 1.0)).to be > 0.0
    expect(after_a_tick(pit, open: 0.6)).to eq(0.6)
  end

  it "is shut by a trapper" do
    expect(after_a_tick(pit, open: 0.6, tubs: 1.0, trapping: 100.0)).to be < 0.6
  end

  it "shuts itself as a self-closing door, with nobody there" do
    op = seed(pit(:self_closing_door), nodes: { door: { open: 0.6 } })
    run!(op, 4)

    expect(open(op)).to be < 0.6
  end

  # An air lock is two doors, so the way through is open only when both are.
  it "lets far less through as an air lock at the same opening" do
    one = door(pit(:self_closing_door)).opening(open: 0.5)
    two = door(pit(:air_lock)).opening(open: 0.5)

    expect(two).to be < one
  end

  # Measured on a working single-shaft pit over 120 ticks: 1.48 kg/tick into the district with the
  # door open, against 2.21 with it shut.
  it "starves the district standing open" do
    shut = seed(pit, nodes: { door: { open: 0.0 } })
    wide = seed(pit, nodes: { door: { open: 1.0 } })
    [ shut, wide ].each { |op| run!(op, 20) }

    district_air = ->(op) { op.state.dig(:nodes, :main_road, :carried_kg) }
    expect(district_air.call(wide)).to be < district_air.call(shut) * 0.85
  end

  it "is blown out when the district goes up" do
    expect(pit.nodes.fetch(:district).failure_damages.fetch(:rupture)).to include(door: 1.0)
    blown = door(pit).gas_conductance({ failure: :blown_out, open: 0.0 }, nil)
    shut = door(pit).gas_conductance({ failure: nil, open: 0.0 }, nil)

    expect(blown).to be > shut * 10.0
  end

  # **Small hands are better at it**: a kobold is `diminutive`, which aids the trapper's station.
  it "is worked better by somebody small" do
    trapping = pit.control_points.fetch(:trapping)
    kobold = ReactorSim::Content.default.sheet(:kobold_temp)

    expect(Array(trapping.aided_by)).to include(:diminutive)
    expect(kobold.fetch(:tags)).to include(diminutive: 0.6)
  end
end
