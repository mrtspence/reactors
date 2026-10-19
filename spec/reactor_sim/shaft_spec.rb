# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **The shaft, and the frame it decides.**
#
# The starting pit has one shaft carrying the ways up and down and both halves of the air, divided
# by a brattice — so what chokes the shaft traps the shift and what breaches the brattice
# short-circuits the ventilation. Two shafts is the upgrade, and the second shaft is a second way
# out. Every example is arithmetic or a constructed state.
RSpec.describe "the shaft" do
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  def pit(chassis, **opts) = build_pit(id: "s", seed: 1, chassis: chassis, **opts)

  describe "the frames" do
    it "starts a pit on a single shaft" do
      expect(ReactorSim::Operations.chassis_for(:mine).first).to be(:single_shaft)
    end

    it "partitions a single shaft with a brattice, and gives two shafts a second way out instead" do
      single = pit(:single_shaft)
      double = pit(:two_shaft)

      expect(single.nodes).to include(:brattice, :upcast_foot)
      expect(single.layout.passages.map(&:label)).not_to include("Upcast Ladders")
      expect(double.nodes).not_to include(:brattice)
      expect(double.layout.passages.map(&:label)).to include("Upcast Ladders")
    end
  end

  describe "the brattice" do
    def leak(part) = pit(:single_shaft, loadout: { brattice: part }).nodes.fetch(:brattice).leak_fraction

    it "leaks most as canvas, less creosoted, least as concrete" do
      expect(leak(:canvas_brattice)).to be > leak(:creosoted_brattice)
      expect(%i[canvas_brattice creosoted_brattice timber_brattice].map { |b| leak(b) })
        .to all(be > leak(:concrete_brattice))
    end

    # Breached, the fan pulls the air down one side and straight back up the other.
    it "starves the district once breached" do
      sound = pit(:single_shaft)
      breached = seed(pit(:single_shaft), nodes: { brattice: { failure: :breached } })
      [ sound, breached ].each { |op| run!(op, 20) }

      district_air = ->(op) { op.state.dig(:nodes, :main_road, :carried_kg) }
      expect(district_air.call(breached)).to be < district_air.call(sound) * 0.75
    end
  end

  describe "choked" do
    it "closes every way up and down a single shaft, and leaves the second shaft's open" do
      expect(pit(:single_shaft).layout.next_hop(:district, :bank, [], [ :shaft ])).to be_nil
      expect(pit(:two_shaft).layout.next_hop(:district, :bank, [], [ :shaft ])).to be(:bank)
    end

    it "sends somebody the long way round when the short one is closed" do
      [ [ :single_shaft, false ], [ :two_shaft, true ] ].each do |frame, escapes|
        op = seed(pit(frame), nodes: { shaft: { failure: :choked } },
                              minions: { crew_1: { place: :district, posting: nil, station: nil } })
        op.assign_minion(:crew_1, :quarters)
        run!(op, 5)

        expect(op.state.dig(:minions, :crew_1, :progress).positive?).to be(escapes), frame.to_s
      end
    end

    it "takes the short way while it is open" do
      expect(pit(:two_shaft).layout.next_hop(:district, :bank, [])).to be(:pit_bottom)
    end
  end

  # **Something lodged in the shaft.** It closes every way through, a cage running down onto it
  # hangs while the drum pays out slack, and when it gives the cage falls the slack onto its rope.
  describe "something lodged in it" do
    def cage_pit = pit(:single_shaft, loadout: { winder: :cage_gear }, crew: PitRig::WOUND_CREW)
    def lodged(hold = ReactorSim::Operations::Mine::Shaft::HOLD_NS) = { shaft: { jam_m: 25.0, hold: hold } }
    def drum(op) = op.state.dig(:nodes, :cage_drive)

    it "snatches the rope at twice the cage's weight with no slack, and harder the more there is" do
      weight = 1_650.0 * ReactorSim::Units::GRAVITY_M_PER_S2
      snatch = ->(slack) { ReactorSim::Nodes::Rope.snatch_n(1_650.0, slack, 8.0e5) }

      expect(snatch.call(0.0)).to be_within(1e-6).of(2.0 * weight)
      expect([ 0.2, 1.0, 3.0 ].map(&snatch)).to eq([ 0.2, 1.0, 3.0 ].map(&snatch).sort)
    end

    def suffered(cage_at)
      op = seed(cage_pit, nodes: { cage_drive: { position_m: cage_at } })
      ctx = ReactorSim::Tick::Context.new(controls: {}, dt: 0.25, nodes: op.nodes, states: op.state[:nodes])
      tub = { node: :shaft, kind: :obstruction, share: 1.0 }
      op.nodes.fetch(:shaft).suffer(op.state.dig(:nodes, :shaft), tub, ctx).first
    end

    it "lodges a tub let in at bank, unless the cage is below where it would lodge" do
      expect(suffered(0.0)[:jam_m]).to eq(ReactorSim::Operations::Mine::Shaft::LODGE_M)
      expect(suffered(40.0)[:jam_m]).to be_nil
    end

    it "closes the ladderway while it is lodged" do
      op = seed(pit(:single_shaft), nodes: lodged)
      op.assign_minion(:crew_1, :haulage)
      run!(op, 5)

      expect(op.layout.next_hop(:bank, :pit_bottom, [], [ :shaft ])).to be_nil
      expect(op.state.dig(:minions, :crew_1, :progress)).to eq(0.0)
    end

    it "hangs a cage running down onto it, while the drum goes on paying out" do
      op = seed(cage_pit, nodes: { cage_drive: { position_m: 23.0, angular_momentum: 2.0 / 1.5 * 4_000.0 },
                                   line_shaft: { angular_momentum: 900.0 * 22.0 } }.merge(lodged),
                          controls: { cage_forward: { target: 100.0, actual: 100.0 },
                                      cage_brake_release: { target: 100.0, actual: 100.0 } })
      run!(op, 8)

      expect(op.nodes.fetch(:cage_drive).cage_m(drum(op))).to eq(25.0)
      expect(drum(op)[:slack_m]).to be > 2.0
      expect(op.project.gauges.fetch(:slack_rope)).not_to eq("taut")
    end

    it "works loose faster with a cage resting on it than with nothing" do
      resting = seed(cage_pit, nodes: { cage_drive: { position_m: 27.0, slack_m: 2.0 } }.merge(lodged))
      empty = seed(cage_pit, nodes: lodged)
      [ resting, empty ].each { |op| run!(op, 4) }

      spent = ->(op) { ReactorSim::Operations::Mine::Shaft::HOLD_NS - op.state.dig(:nodes, :shaft, :hold) }
      expect(spent.call(resting)).to be > spent.call(empty) * 5.0
    end

    # Four metres of slack is far past what any rope survives.
    it "drops the cage its slack when it gives, and the rope takes the snatch" do
      op = seed(cage_pit, nodes: { cage_drive: { position_m: 29.0, slack_m: 4.0 } }.merge(lodged(1.0)),
                          minions: { crew_1: { via: :cage_drive, place: :bank, posting: nil, station: nil } })
      events = run!(op, 4)

      expect(op.state.dig(:nodes, :shaft, :jam_m)).to be_nil
      expect(events.find { |e| e[:node] == :winding_rope }).to include(mode: :parted)
      expect(events.find { |e| e[:node] == :winding_rope }.dig(:detail, :tension_kn))
        .to be > op.nodes.fetch(:winding_rope).breaking_kn
    end

    def banksman_on_the_edge(loadout = {})
      op = build_pit(id: "b", seed: 1, chassis: :single_shaft, crew: PitRig::WOUND_CREW,
                     loadout: { winder: :cage_gear }.merge(loadout))
      # A laden deck standing at bank, with him running the tubs off it.
      op = seed(op, nodes: { cage_deck: { parcels: parcels_at(292.0, coal: 800.0) } },
                    minions: { crew_1: { place: :bank, posting: :banking, station: :banking, margin: 1.0e-9 } })
      [ op, run!(op, 3) ]
    end

    it "is lodged by a banksman who lets a tub into the shaft" do
      op, events = banksman_on_the_edge

      expect(events.map { |e| e[:type] }).to include(:minion_mishap)
      expect(op.state.dig(:nodes, :shaft, :jam_m)).to eq(ReactorSim::Operations::Mine::Shaft::LODGE_M)
    end

    # Bought down rather than removed: whether a gate saves it is the bank's safety equipment,
    # gated on whoever is there seeing to it.
    it "is guarded against at bank by shaft gates" do
      gates = pit(:single_shaft, loadout: { shaft_gates: :shaft_gates }).nodes.fetch(:shaft_gates)

      expect(gates.safety_equipment).to eq(bank: 0.7)
    end
  end

  # **A part with no wear of its own is wrecked by what lets go beside it.** Emptied by
  # `spread_damage`, it fails on its next evaluation rather than waiting for a stress it never has.
  it "chokes when something beside it takes its durability" do
    op = seed(pit(:single_shaft), nodes: { shaft: { durability: 0.0 } })
    events = run!(op, 1)

    expect(op.state.dig(:nodes, :shaft, :failure)).to be(:choked)
    expect(events.find { |e| e[:node] == :shaft }).to include(cause: :damage)
  end
end
