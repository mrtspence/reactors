# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **An ignition source belongs to the room it is in.** A vessel names no igniters; whatever stands
# in its place and answers `ignition` offers itself to the air there, through
# `Tick#ignition_sources`. A tick or so per example, because what is claimed is the wiring rather
# than the chemistry — `district_fire_spec` owns what a flame does to a mixture.
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

      flame = ReactorSim::Operations::Mine::OPEN_FLAME
      expect(offered).to eq(kg_per_s: flame.fetch(:igniter_kg_per_s) * 0.5,
                            watts: flame.fetch(:flame_watts) * 0.5, cause: :naked_flame)
    end

    it "offers nothing from a safe tier in still air, however hard it is lit" do
      expect(sconces(:gauze_lanterns).ignition({}, { safe_light: 100.0 })).to be_nil
      expect(sconces(:electric_lamps).ignition({}, { safe_light: 100.0 })).to be_nil
    end

    # **A gauze passes its flame in a fast enough draught**, and says so in the cause.
    it "lets a gauze lamp's flame through once the air past it is quick enough" do
      gauze = sconces(:gauze_lanterns)
      still = gauze.ignition({ draught_m_s: 1.0 }, { safe_light: 100.0 })
      gale = gauze.ignition({ draught_m_s: 2.5 }, { safe_light: 100.0 })

      expect(still).to be_nil
      expect(gale).to include(cause: :gauze)
      expect(sconces(:electric_lamps).ignition({ draught_m_s: 2.5 }, { safe_light: 100.0 })).to be_nil
    end
  end

  describe "the coal cutter" do
    def pick_line(part)
      ReactorSim::Operations::Mine.build(id: "m", seed: 1, ground: 1.0, loadout: { cutting: part })
                                  .nodes.fetch(:pick_line)
    end

    it "strikes sparks while it is cutting, and a hand pick never does" do
      cutter = pick_line(:coal_cutter)

      expect(cutter.ignition({ cutting: 0.0 }, {})).to be_nil
      expect(cutter.ignition({ cutting: 0.8 }, {})).to include(cause: :cutter_sparks)
      expect(pick_line(:hand_picks).ignition({ cutting: 0.8 }, {})).to be_nil
    end
  end

  # **A man's own naked light is the commonest igniter of all**: anybody carrying `open_flame`
  # offers it to the air where they stand, with no lamp on the wall lit at all.
  describe "a naked light in somebody's hand" do
    include PitRig

    def collier(flame)
      tags = PitRig::COLLIER[:tags].merge(flame ? { open_flame: true } : {})
      PitRig.content(PitRig::COLLIER.merge(tags: tags))
    end

    def lit?(flame:)
      allow(ReactorSim::Content).to receive(:default).and_return(collier(flame))
      op = build_pit(id: "h", seed: 1, chassis: :single_shaft)
      op = seed(op, nodes: { district: district_mix(op, firedamp: gas_kg(4.0)) },
                    minions: { crew_1: { place: :district, posting: nil, station: nil } })
      run!(op, 4).any? { |e| e[:type] == :fire_lit && e[:node] == :district }
    end

    it "lights gas in the band where the same hand without one does not" do
      expect([ lit?(flame: true), lit?(flame: false) ]).to eq([ true, false ])
    end
  end

  # **The second caller: the shaft's signal bell**, which sparks at the pit bottom as it rings the
  # cage away. The chemistry is the real pit's, so this group runs a few ticks of it.
  describe "the signal bell" do
    include PitRig

    before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

    def caged(bells) = build_pit(id: "b", seed: 1, chassis: :single_shaft,
                                 loadout: { winder: :cage_gear, signals: bells })

    it "sparks only while it is ringing, and a flameproof one never does" do
      bell = caged(:electric_bells).nodes.fetch(:signal_bell)

      expect(bell.ignition({ ringing: true }, {})).to include(cause: :signal_bell)
      expect(bell.ignition({ ringing: false }, {})).to be_nil
      expect(caged(:flameproof_bells).nodes.fetch(:signal_bell).ignition({ ringing: true }, {})).to be_nil
    end

    it "rings as the cage moves off the pit bottom" do
      op = seed(caged(:electric_bells),
                nodes: { cage_drive: { position_m: 89.5, angular_momentum: -2.0 / 1.5 * 4_000.0 } })
      run!(op, 1)

      expect(op.state.dig(:nodes, :signal_bell, :ringing)).to be(true)
    end

    # 4% firedamp by mass is about 7% by volume, inside the limits.
    it "lights gas at the pit bottom when it rings there, where a flameproof bell does not" do
      lit = %i[electric_bells flameproof_bells].map do |bells|
        op = caged(bells)
        gassy = bottom_mix(op, firedamp: gas_kg(4.0, air: PitRig::BOTTOM_AIR_KG))
        op = seed(op, nodes: { pit_bottom: gassy, signal_bell: { ringing: true } })
        run!(op, 4).any? { |e| e[:type] == :fire_lit && e[:node] == :pit_bottom }
      end

      expect(lit).to eq([ true, false ])
    end
  end
end
