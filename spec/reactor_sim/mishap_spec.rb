# frozen_string_literal: true

require "json"
require "reactor_sim"

# **A peril whose consequence is the machine.** The clumsy banksman letting a tub into the shaft
# is unhurt; the shaft is not. A peril may name a `mishap:`, and when it is the accident picked the
# phase 6d event names the part, which suffers it on the next tick's `stress`.
#
# Generic on purpose — nothing here knows about mines. Every example is one or two ticks on a rig,
# and the constructed states go out through JSON and back, which is the snapshot path. A pending
# mishap lives in `state[:mishaps]` rather than in the events, because events are not snapshotted:
# waiting there it would vanish across a restore.
RSpec.describe "mishaps" do
  let(:hazard_class) do
    Class.new(ReactorSim::Node) do
      def initialize(perils:, **opts)
        @perils = perils.freeze
        super(**opts)
        freeze
      end

      attr_reader :perils
    end
  end

  def drum
    ReactorSim::Nodes::Vessel.new(
      id: :drum, label: "Drum", volume_m3: 10.0, heat_capacity: 1.0e4,
      ports: [ ReactorSim::Port.new(id: :vent, direction: :inlet, accepts: [ :gas ]) ],
      initial_contents: [ { resource: :air, kg: 12.0 } ]
    )
  end

  def knock(node: :drum, kind: :damage, share: 0.25)
    ReactorSim::Peril.new(id: :knock, rate: 50.0, places: %i[yard],
                          mishap: { node: node, kind: kind, share: share })
  end

  def rig(peril: knock, minions: [], state: nil)
    ReactorSim::Operation.new(
      id: :rig, type: :test, seed: 1, state: state,
      nodes: [ drum, hazard_class.new(id: :bench, perils: [ peril ]) ],
      places: [ ReactorSim::Place.new(id: :yard, nodes: %i[drum bench]) ],
      minions: minions
    )
  end

  # The same rig, from a state that has been through JSON and had `patch` applied to it.
  def through_json(op, peril: knock, minions: [])
    raw = ReactorSim.deep_symbolize(JSON.parse(JSON.generate(op.to_h))).fetch(:state)
    rig(peril: peril, minions: minions, state: yield(raw))
  end

  def pending(share) = [ { node: :drum, kind: :damage, share: share } ]

  def durability(op) = op.state.dig(:nodes, :drum, :durability)

  def hand
    ReactorSim::Minion.new(id: :crew_1, mass_kg: 70.0, place: :yard,
                           stats: ReactorSim::Sheet::STATS.to_h { |s| [ s, 1.0 ] })
  end

  # Somebody in the yard on the very edge of their margin, so they cross on the first tick.
  def on_the_edge
    through_json(rig(minions: [ hand ]), minions: [ hand ]) do |s|
      s.merge(minions: s.fetch(:minions).merge(crew_1: s.dig(:minions, :crew_1).merge(margin: 1.0e-9)))
    end
  end

  it "is suffered by the part it names, on the next tick" do
    op = rig
    before = durability(op)
    waiting = through_json(op) { |s| s.merge(mishaps: pending(0.25)) }

    waiting.step!(tick: 1)

    initial = op.state.dig(:nodes, :drum, :initial_durability)
    expect(durability(waiting)).to be_within(1e-9).of(before - (0.25 * initial))
  end

  it "breaks a part it wears through, and says a person did it" do
    waiting = through_json(rig) { |s| s.merge(mishaps: pending(2.0)) }

    events = waiting.step!(tick: 1)

    failed = events.find { |e| e[:type] == :part_failed }
    expect(failed).to include(node: :drum, cause: :mishap)
  end

  it "refuses a mishap aimed at something that cannot suffer that kind of thing" do
    expect { rig(peril: knock(kind: :obstruction)) }.to raise_error(ReactorSim::Error, /cannot suffer/)
  end

  # End to end, two ticks: somebody on the edge of their margin crosses on the first, the event
  # is the mishap rather than an injury, and the part suffers it on the second.
  it "is what a thin margin produces where the only danger is to the machine" do
    edge = on_the_edge
    before = durability(edge)

    first = edge.step!(tick: 1)
    edge.step!(tick: 2)

    expect(first.map { |e| e[:type] }).to include(:minion_mishap)
    expect(first.map { |e| e[:type] }).not_to include(:minion_hurt)
    expect(durability(edge)).to be < before
  end

  # **The trap this state key exists to close.** Snapshotted between the mishap and its
  # consequence, the restored rig must do exactly what the one that ran straight through did —
  # and the part it names must come back as a Symbol, or the lookup misses and nothing happens.
  it "survives a snapshot taken between the mishap and its consequence" do
    straight = on_the_edge
    2.times { |i| straight.step!(tick: i + 1) }

    paused = on_the_edge
    paused.step!(tick: 1)
    resumed = through_json(paused, minions: [ hand ]) { |s| s }

    expect(resumed.state.fetch(:mishaps).first.fetch(:node)).to be(:drum)
    resumed.step!(tick: 2)
    expect(ReactorSim.canonical(resumed.state.fetch(:nodes)))
      .to eq(ReactorSim.canonical(straight.state.fetch(:nodes)))
  end
end
