# frozen_string_literal: true

require "reactor_sim"
require "json"

# The crew, and specifically the one thing nothing else in the suite can prove.
#
# Every steam engine lever has infinite stiffness, so `ControlPoint#actuate` snaps `actual` to
# `target` and throws the rate multiplier away untouched. The engine's own specs therefore pass
# whether or not a minion is ever consulted — which is exactly what makes a bare rig with a
# STIFF lever the only honest test of the seam.
RSpec.describe ReactorSim::Minion do
  # A crew of one at a lever that is genuinely hard to move.
  def rig(health: 1.0, fatigue: 0.0, strength: 1.0, stiffness: 20.0, station: :valve)
    content = ReactorSim::Content.build(
      resources: { water: { tags: [ :liquid ], specific_heat_j_per_kg_k: 4181,
                            density_kg_per_m3: 997 } }
    )

    op = ReactorSim::Operation.new(
      id: :rig, type: :test, seed: 1, content: content,
      nodes: [ ReactorSim::Nodes::Conduit.new(id: :pipe, label: "Pipe", accepts: [ :liquid ],
                                              max_kg_per_s: 1.0) ],
      control_points: [ ReactorSim::ControlPoint.new(id: :valve, node: :pipe,
                                                     stiffness: stiffness) ],
      # **Stats arrive FOLDED.** A `Minion` used to hold an archetype id and reach into content
      # for `strength` on every call; all four layers are resolved at build now, by `Crew`, which
      # is the only thing that knows a player owns anything. Nothing on the tick path looks a
      # stat up, so this rig hands one over directly.
      minions: [ described_class.new(id: :worker, name: "Hand", station: station,
                                     stats: { strength: strength }) ]
    )

    # Reach past the command path to set condition directly — nothing advances health or
    # fatigue yet, so there is no legitimate way to arrive at a tired minion.
    state = op.state
    worn = state.fetch(:minions).merge(
      worker: state.fetch(:minions).fetch(:worker).merge(health: health, fatigue: fatigue)
    )
    op.instance_variable_set(:@state, state.merge(minions: worn).freeze)
    op
  end

  def travel(op, ticks: 1)
    op.set_control(:valve, 100.0)
    ticks.times { |i| op.step!(tick: i + 1) }
    op.state.fetch(:controls).fetch(:valve).fetch(:actual)
  end

  describe "#rate_multiplier" do
    it "is the archetype's strength for a fresh minion" do
      op = rig(strength: 0.5)
      minion = op.minions.fetch(:worker)

      expect(minion.rate_multiplier(op.state.fetch(:minions).fetch(:worker), op.content))
        .to eq(0.5)
    end

    it "falls with health and with fatigue" do
      op = rig(health: 0.5, fatigue: 0.5)
      minion = op.minions.fetch(:worker)

      expect(minion.rate_multiplier(op.state.fetch(:minions).fetch(:worker), op.content))
        .to eq(0.25)
    end

    it "never goes negative, so a lever cannot be driven away from its target" do
      op = rig(fatigue: 2.0)
      minion = op.minions.fetch(:worker)

      expect(minion.rate_multiplier(op.state.fetch(:minions).fetch(:worker), op.content))
        .to eq(0.0)
    end
  end

  # THE seam test. If `rate_multiplier` ever stops reaching ControlPoint#actuate, this is the
  # only example in the suite that notices.
  describe "the actuation seam" do
    it "moves a stiff lever further for a healthy minion than a degraded one" do
      fresh = travel(rig(health: 1.0))
      tired = travel(rig(health: 0.25))

      expect(fresh).to be > tired
      expect(tired).to be > 0.0
    end

    it "does not move the lever at all for a minion with nothing left" do
      expect(travel(rig(health: 0.0))).to eq(0.0)
    end

    # Documents present behaviour rather than endorsing it, so the TODO in Tick#crew_multiplier
    # becomes a visible diff when someone decides what an unattended lever should do.
    it "moves an unmanned lever at full rate, for now" do
      unmanned = travel(rig(station: nil))
      manned = travel(rig(health: 1.0))

      expect(unmanned).to eq(manned)
    end

    it "follows the minion when they are reassigned" do
      op = rig(health: 0.25, station: nil)
      slow_when_unmanned = travel(op)

      op = rig(health: 0.25, station: nil)
      op.assign_minion(:worker, :valve)

      expect(travel(op)).to be < slow_when_unmanned
    end
  end

  describe "assignment" do
    it "is idempotent, so redelivery from the log is harmless" do
      op = rig
      2.times { op.assign_minion(:worker, :valve) }

      expect(op.state.fetch(:minions).fetch(:worker).fetch(:station)).to eq(:valve)
    end

    it "refuses a station that is not a control point" do
      op = rig

      expect(op.assign_minion(:worker, :nonexistent)).to be(false)
    end

    it "refuses an unknown minion" do
      expect(rig.assign_minion(:nobody, :valve)).to be(false)
    end
  end

  describe "snapshot and restore" do
    # `station` is a control point id stored as a VALUE, so JSON returns it as a String and
    # every crew lookup in Tick then misses in silence.
    #
    # `be`, not `eq` — and the distinction is the entire point of the example, because
    # "stoking" == :stoking is false but eq would still be the wrong assertion to trust here.
    # Note also that the DIGEST cannot catch this: `canonical` runs through JSON.generate,
    # where :stoking and "stoking" are the same string.
    it "brings station back as a Symbol, not a String" do
      match = ReactorSim::Match.create(
        id: "m", seed: 42, operations: [ { id: "eng", type: :steam_engine } ]
      )
      restored = ReactorSim::Match.from_h(JSON.parse(JSON.generate(match.to_h)))
      station = restored.operation(:eng).state.fetch(:minions).fetch(:fireman).fetch(:station)

      expect(station).to be(:stoking)
    end

    it "survives a round trip with the crew intact" do
      match = ReactorSim::Match.create(
        id: "m", seed: 42, operations: [ { id: "eng", type: :steam_engine } ]
      )
      match.apply([ { type: "assign_minion", operation_id: "eng",
                      minion_id: "yardhand", control_point_id: "feed" } ])
      restored = ReactorSim::Match.from_h(JSON.parse(JSON.generate(match.to_h)))

      expect(restored.digest).to eq(match.digest)
      expect(restored.operation(:eng).state.fetch(:minions).fetch(:yardhand).fetch(:station))
        .to be(:feed)
    end
  end

  describe "the shared id namespace" do
    # The obvious name for the person shovelling coal is `stoker`, and `:stoker` is already
    # the conduit feeding the firebox. Ids key one flat rng table, so the collision would have
    # handed two components the same stream — silently, and through a snapshot.
    it "refuses a minion whose id collides with a node" do
      expect {
        ReactorSim::Operation.new(
          id: :rig, type: :test, seed: 1,
          nodes: [ ReactorSim::Nodes::Conduit.new(id: :stoker, accepts: [], max_kg_per_s: 1.0) ],
          control_points: [ ReactorSim::ControlPoint.new(id: :valve, node: :stoker) ],
          minions: [ described_class.new(id: :stoker, archetype: :hand, station: :valve) ]
        )
      }.to raise_error(ReactorSim::Error, /duplicate component ids: stoker/)
    end

    it "refuses a minion posted to a station that does not exist" do
      expect {
        ReactorSim::Operation.new(
          id: :rig, type: :test, seed: 1,
          nodes: [ ReactorSim::Nodes::Conduit.new(id: :pipe, accepts: [], max_kg_per_s: 1.0) ],
          minions: [ described_class.new(id: :worker, archetype: :hand, station: :nowhere) ]
        )
      }.to raise_error(ReactorSim::Error, /no control point nowhere/)
    end
  end
end
