# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"
require "support/pit_rig"

# **Furnace ventilation, and the front that travels.** A coal fire at the upcast foot warms the foot,
# and a warm foot draws the whole upcast by buoyancy, with no power at all. Its air is the return's,
# so return gas in its range fires at the furnace, and the front runs back into the workings; a dumb
# drift feeds it intake instead. See `design_sketches/mine-accidents-unit4.md` §7.
RSpec.describe "ventilating furnaces" do
  include Constructed
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  AMBIENT = PitRig::AMBIENT_K

  # A safe light, so the only flame in the pit is the furnace.
  def pit(furnace: :brick_furnace, drift: nil)
    build_pit(id: "f", seed: 5, loadout: { furnace: furnace, dumb_drift: drift, lighting: :electric_lamps })
  end

  def furnaceman = { crew_1: { place: :pit_bottom, posting: :furnace_stoking, station: :furnace_stoking } }

  def upcast_kg(op) = op.state.dig(:nodes, :upcast, :carried_kg)

  # The furnace burning and the upcast foot warm from it, as a furnace an hour lit leaves them.
  def burning(op, furnace_k: 900.0, foot_k: 420.0)
    { furnace: body(op, :furnace, furnace_k, air: 36.0, coal: 200.0),
      upcast_foot: body(op, :upcast_foot, foot_k, air: 300.0) }
  end

  describe "the draught" do
    # The fan stopped with the line shaft: nothing turns, and the supply is cut.
    def unpowered(op, nodes = {}) = seed(op, nodes: nodes, minions: furnaceman).tap { |o| run!(o, 20, supply: 0.0) }

    it "draws the pit with the line shaft stopped" do
      fired = unpowered(pit, burning(pit))
      none = unpowered(pit(furnace: nil))

      expect(upcast_kg(fired)).to be > 5.0 * upcast_kg(none)
    end

    it "follows its fire" do
      roaring = unpowered(pit, burning(pit, furnace_k: 1_100.0, foot_k: 480.0))
      low = unpowered(pit, burning(pit, furnace_k: 600.0, foot_k: 340.0))

      expect(upcast_kg(roaring)).to be > upcast_kg(low)
    end
  end

  # The return in its range: the district, and the furnace the return feeds.
  describe "firedamp in the return" do
    def gassy(drift: nil)
      op = pit(drift: drift)
      gas = { district: district_mix(op, firedamp: gas_kg(4.0)),
              furnace: gas_mix(op, :furnace, air: 36.0, firedamp: gas_kg(4.0, air: 36.0)).merge(
                joules: op.nodes.fetch(:furnace).heat_capacity * AMBIENT
              ) }
      seed(op, nodes: gas, minions: furnaceman)
    end

    def exploded(events) = events.select { |e| e[:type] == :explosion }.map { |e| e.fetch(:node) }

    it "fires at the furnace, and the front runs back into the district that fed it" do
      events = run!(gassy, 4)

      expect(exploded(events)).to eq(%i[furnace district])
      expect(events.find { |e| e[:type] == :explosion && e[:node] == :district })
        .to include(cause: :front_from_neighbour, detail: a_hash_including(from: :furnace))
    end

    it "is kept off the flame by a dumb drift, which feeds the fire from the intake" do
      op = gassy(drift: :dumb_drift)
      op = seed(op, nodes: { furnace: body(op, :furnace, AMBIENT, air: 36.0) })

      expect(exploded(run!(op, 4))).to be_empty
    end
  end

  # Which holders a front can reach, at zero ticks.
  it "reaches every holder sharing a gas path, and none that share only coal" do
    neighbours = pit.gas_neighbours

    expect(neighbours.fetch(:district)).to include(:pit_bottom, :upcast_foot, :furnace)
    expect(neighbours.fetch(:pit_bottom)).not_to include(:cage_deck)
  end
end
