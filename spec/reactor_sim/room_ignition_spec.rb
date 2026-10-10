# frozen_string_literal: true

require "reactor_sim"

# **An ignition source belongs to the room it is in.** A vessel names no igniters; whatever stands
# in its place and answers `ignition` offers itself to the air there, through
# `Tick#ignition_sources`. One tick per example, because what is claimed is the wiring rather than
# the chemistry — `district_fire_spec` owns what a flame does to a mixture.
RSpec.describe "ignition as a property of the room" do
  # Something alight, offering a fixed seed and heat, naming itself as the cause.
  let(:flame_class) do
    Class.new(ReactorSim::Node) do
      def initialize(kg_per_s:, watts: 0.0, **opts)
        @offered = { kg_per_s: kg_per_s, watts: watts }
        super(**opts)
        freeze
      end

      def ignition(_state, _levers) = @offered.merge(cause: id)
    end
  end

  def flame(id, kg_per_s, watts: 0.0) = flame_class.new(id: id, kg_per_s: kg_per_s, watts: watts)

  def air(id)
    ReactorSim::Nodes::Vessel.new(
      id: id, label: id.to_s, volume_m3: 10.0, heat_capacity: 1.0e4,
      ports: [ ReactorSim::Port.new(id: :vent, direction: :inlet, accepts: [ :gas ]) ],
      initial_contents: [ { resource: :air, kg: 12.0 } ]
    )
  end

  def rig(flames)
    ReactorSim::Operation.new(
      id: :rig, type: :test, seed: 1,
      nodes: [ air(:room), air(:yard), *flames ],
      places: [ ReactorSim::Place.new(id: :room, nodes: [ :room, *flames.map(&:id) ]),
                ReactorSim::Place.new(id: :yard, nodes: [ :yard ]) ]
    )
  end

  def after_one_tick(op)
    op.step!(tick: 1)
    op.state.fetch(:nodes)
  end

  it "seeds the air of the room it stands in, and no other" do
    nodes = after_one_tick(rig([ flame(:candle, 4.0e-4, watts: 1.2e3) ]))

    expect(nodes.dig(:room, :ignition_seed_kg)).to be_within(1e-12).of(4.0e-4 * ReactorSim::DT)
    expect(nodes.dig(:room, :joules_injected)).to be_within(1e-9).of(1.2e3 * ReactorSim::DT)
    expect(nodes.dig(:yard, :ignition_seed_kg)).to eq(0.0)
  end

  it "sums two sources in one room" do
    nodes = after_one_tick(rig([ flame(:candle, 4.0e-4), flame(:bell, 1.0e-4) ]))

    expect(nodes.dig(:room, :ignition_seed_kg)).to be_within(1e-12).of(5.0e-4 * ReactorSim::DT)
  end

  # Sources are summed, and a float sum depends on its order — so the walk is by id, and an
  # operation that happened to declare its nodes the other way round must light identically.
  it "does not depend on the order the sources were declared in" do
    flames = [ flame(:candle, 4.0e-4), flame(:bell, 1.0e-4), flame(:lamp, 3.0e-7) ]

    forward = after_one_tick(rig(flames))
    backward = after_one_tick(rig(flames.reverse))

    expect(ReactorSim.canonical(backward)).to eq(ReactorSim.canonical(forward))
  end

  describe "the mine's lighting" do
    def sconces(part)
      ReactorSim::Operations::Mine.build(id: "m", seed: 1, ground: 1.0, loadout: { lighting: part })
                                  .nodes.fetch(:sconces)
    end

    it "offers a flame that goes with the lever, named for it" do
      offered = sconces(:tallow_candles).ignition({}, { naked_flame: 50.0 })

      expect(offered).to eq(kg_per_s: 2.0e-4, watts: 600.0, cause: :naked_flame)
    end

    it "offers nothing from a safe tier, however hard it is lit" do
      expect(sconces(:gauze_lanterns).ignition({}, { safe_light: 100.0 })).to be_nil
      expect(sconces(:electric_lamps).ignition({}, { safe_light: 100.0 })).to be_nil
    end
  end
end
