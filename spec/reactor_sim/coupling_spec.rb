# frozen_string_literal: true

require "reactor_sim"
require "support/conservation"
require "support/constructed"

# **Work crossing between two operations**, which is the first thing that has ever done so.
#
# Everything else in the engine settles inside one operation; a coupling is the one place two
# of them meet. The claims worth proving are therefore not about any particular machine: that
# energy is conserved across the boundary, that the transfer cannot depend on the order
# operations are visited in, and that a starved shaft winds down rather than switching off.
#
# On rigs rather than on machines, for the same reason `driven_transport_spec` is — the claim is
# about the adapter, and the mine that consumes it does not exist yet.
#
# See `docs/design_sketches/mine.md` §4.1 and §4.6 stage A.
RSpec.describe "a coupling between operations" do
  # A spinning mass with a brake on it — a steam engine with the boiler left off. The brake's
  # absorbed work is what leaves, exactly as the mill drive's does on the real machine.
  ReactorSim::Operations.register(:coupling_source_rig, harness: true) do |id:, seed:, **opts|
    ReactorSim::Operation.new(
      id: id, type: :coupling_source_rig, seed: seed,
      time_scale: opts.fetch(:time_scale, 1.0), state: opts[:state], rngs: opts[:rngs],
      content: opts[:content],
      nodes: [
        ReactorSim::Nodes::Flywheel.new(id: :shaft, mass_kg: 8.0e4, radius_m: 1.0,
                                        initial_omega: 40.0),
        ReactorSim::Nodes::Load.new(id: :load, max_torque: 4.0e3, rated_omega: 40.0,
                                    moment_of_inertia: 2.0e3, curve: :viscous,
                                    control_id: :demand)
      ],
      drive_links: [ ReactorSim::DriveLink.new(a: :shaft, b: :load, stiffness: 5.0e3) ],
      control_points: [
        ReactorSim::ControlPoint.new(id: :demand, label: "Load", node: :load, default: 100.0)
      ]
    )
  end

  # A line shaft with nothing on it but its own windage, so what it does with the supply reads as
  # speed rather than being eaten by a load.
  ReactorSim::Operations.register(:coupling_sink_rig, harness: true) do |id:, seed:, **opts|
    ReactorSim::Operation.new(
      id: id, type: :coupling_sink_rig, seed: seed,
      time_scale: opts.fetch(:time_scale, 1.0), state: opts[:state], rngs: opts[:rngs],
      content: opts[:content],
      nodes: [
        ReactorSim::Nodes::Import.new(id: :line_shaft, label: "Line Shaft",
                                      rated_torque_nm: 2.0e3, rated_omega: 30.0,
                                      moment_of_inertia: 1.0e3, friction: 50.0, control_id: :clutch)
      ],
      control_points: [
        ReactorSim::ControlPoint.new(id: :clutch, label: "Clutch", node: :line_shaft, default: 100.0)
      ]
    )
  end

  def coupled(order: %i[source sink], couplings: default_couplings, sink_time_scale: 1.0)
    specs = { source: { id: "source", type: :coupling_source_rig },
              sink: { id: "sink", type: :coupling_sink_rig, time_scale: sink_time_scale } }

    ReactorSim::Match.create(id: "x", seed: 1, operations: order.map { |k| specs.fetch(k) },
                             couplings: couplings)
  end

  def default_couplings = [ { from: %w[source load], to: %w[sink line_shaft] } ]

  def shaft(match) = match.operation(:sink).state.fetch(:nodes).fetch(:line_shaft)

  def balance(op) = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

  # The magnitude the tolerance is relative to: what this operation is actually holding and has
  # moved, rather than what it happened to start with.
  def scale(op) = [ balance(op).abs, op.total_joules.abs, 1.0 ].max

  it "carries the source's delivered work into the sink's shaft" do
    match = coupled
    10.times { match.step! }

    expect(match.operation(:sink).ledger.fetch(:joules_imported)).to be > 0.0
    expect(shaft(match).fetch(:angular_momentum)).to be > 0.0
  end

  it "conserves energy across the boundary" do
    match = coupled
    start = match.operations.sum { |op| balance(op) }
    magnitude = match.operations.sum { |op| scale(op) }

    200.times { match.step! }

    drift = match.operations.sum { |op| balance(op) } - start
    expect(drift.abs / magnitude).to be < Conservation::TOLERANCE,
      "match drifted by #{drift} J"
  end

  # Both sides must close independently as well as together: the source pays out through
  # `joules_to_work` and the sink takes it in through `joules_imported`, so neither operation's
  # own books are disturbed by the transfer.
  it "leaves each operation's own balance closed" do
    match = coupled
    before = match.operations.to_h { |op| [ op.id, balance(op) ] }

    200.times { match.step! }

    match.operations.each do |op|
      drift = balance(op) - before.fetch(op.id)
      expect(drift.abs / scale(op)).to be < Conservation::TOLERANCE,
        "#{op.id} drifted by #{drift} J"
    end
  end

  # The exchange reads every source before writing any sink, so the order operations happen to
  # sit in cannot change what crosses (`invariants.md` §3).
  it "does not depend on the order operations are visited in" do
    forward = coupled(order: %i[source sink])
    reversed = coupled(order: %i[sink source])

    50.times { forward.step! }
    50.times { reversed.step! }

    expect(shaft(forward).fetch(:angular_momentum))
      .to be_within(1e-9).of(shaft(reversed).fetch(:angular_momentum))
  end

  describe "when the supply fails" do
    # **Throwing either clutch slackens the rope.** The sink's torque is gone a tick later — the
    # far end's clutch is heard at the barrier — and the shaft coasts down on its own inertia
    # against its windage, rather than stopping dead. Measured on these rigs: 95% after five
    # ticks, 79% after twenty, 62% after forty.
    it "coasts the shaft down rather than stopping it dead" do
      match = coupled
      120.times { match.step! }
      running = shaft(match).fetch(:angular_momentum)
      expect(running).to be > 0.0

      match.operation(:source).set_control(:demand, 0)
      trace = Array.new(40) do
        match.step!
        [ shaft(match).fetch(:torque), shaft(match).fetch(:angular_momentum) ]
      end
      torque = trace.map(&:first)
      speed = trace.map(&:last)

      expect(torque.drop(1)).to all(eq(0.0))
      expect(speed.each_cons(2).all? { |a, b| b < a }).to be(true), "it did not coast down"
      expect(speed.fetch(4)).to be > running * 0.9
      expect(speed.last).to be_between(running * 0.4, running * 0.8)
    end

    it "spins up no shaft at all with nothing coupled to it" do
      match = coupled(couplings: [])
      50.times { match.step! }

      expect(shaft(match).fetch(:supply_joules)).to eq(0.0)
      expect(shaft(match).fetch(:angular_momentum)).to eq(0.0)
    end
  end

  it "refuses a coupling between operations on different clocks" do
    expect { coupled(sink_time_scale: 40.0) }
      .to raise_error(ReactorSim::Error, /must share a clock/)
  end

  # **Both ends feel each other.** Each end treats the other's last-tick speed as a reservoir: a
  # driver below it, a brake above it. Everything below is a claim that would be false of a
  # one-way supply.
  describe "the rope" do
    include Constructed

    def sink_omega(match) = match.operation(:sink).nodes.fetch(:line_shaft).omega(shaft(match))

    def source_omega(match)
      op = match.operation(:source)
      op.nodes.fetch(:shaft).omega(op.state.fetch(:nodes).fetch(:shaft))
    end

    describe "one end, as arithmetic" do
      let(:rope_end) do
        ReactorSim::Nodes::Import.new(id: :line_shaft, rated_torque_nm: 2.0e3, rated_omega: 30.0,
                                      moment_of_inertia: 1.0e3)
      end
      let(:ctx) { ReactorSim::Tick::Context.new(controls: {}, dt: 0.25) }

      def at(omega, far:, supply: 1.0e5, grip: 1.0)
        state = rope_end.initial_state(ReactorSim::Rng.new(1), ReactorSim::Content.default)
        rope_end.hear(state, omega: far, grip: grip, conductance: 100.0)
                .merge(angular_momentum: omega * 1.0e3, supply_joules: supply)
      end

      it "drives below the far end's speed, and does not brake" do
        state = at(10.0, far: 20.0)

        expect(rope_end.rope_torque(state, ctx, conductance: 100.0, reservoir: 20.0)).to eq(1_000.0)
        expect(rope_end.rope_drags(state, ctx)).to be_empty
      end

      it "brakes above it, and does not drive" do
        state = at(20.0, far: 10.0)

        expect(rope_end.rope_torque(state, ctx, conductance: 100.0, reservoir: 10.0)).to eq(0.0)
        expect(rope_end.rope_drags(state, ctx).fetch(:rope)).to be_within(1e-9).of(50.0)
      end

      it "does nothing at it" do
        state = at(20.0, far: 20.0)

        expect(rope_end.rope_torque(state, ctx, conductance: 100.0, reservoir: 20.0)).to eq(0.0)
        expect(rope_end.rope_drags(state, ctx)).to be_empty
      end

      it "goes slack when either clutch is out" do
        slack = at(20.0, far: 10.0, grip: 0.0)

        expect(rope_end.rope_drags(slack, ctx)).to be_empty
        expect(rope_end.rope_torque(at(10.0, far: 20.0, grip: 0.0), ctx, conductance: 100.0, reservoir: 20.0))
          .to eq(0.0)
      end
    end

    # The chain the rope exists for: the sink throws its clutch and the source, which was being
    # held back by it, is not.
    it "lets a load rejection at the far end be felt by the source" do
      held = coupled
      shed = coupled
      [ held, shed ].each { |m| 60.times { m.step! } }

      shed.operation(:sink).set_control(:clutch, 0)
      [ held, shed ].each { |m| 20.times { m.step! } }

      expect(source_omega(shed)).to be > source_omega(held)
    end

    # A stiff rope and a 1:1 ratio, so the sink is pulled up toward the source's 40 rad/s — past
    # its own rated 30. Geared 2:1 it settles near half the source's speed instead.
    it "delivers a supplier's speed through the gearing, overspeed and all" do
      direct = coupled(couplings: [ default_couplings.first.merge(stiffness: 3_000.0) ])
      geared = coupled(couplings: [ default_couplings.first.merge(stiffness: 3_000.0, ratio: 2.0) ])
      [ direct, geared ].each { |m| 40.times { m.step! } }

      expect(sink_omega(direct)).to be > 30.0
      expect(sink_omega(geared)).to be_within(2.0).of(source_omega(geared) / 2.0)
    end

    # Overrunning the source, the sink becomes the brake and sends work back up the rope.
    it "lets the far end drive the source when it overruns it" do
      match = coupled
      match = seed_match(match, :sink, nodes: { line_shaft: { angular_momentum: 80.0 * 1.0e3 } })
      2.times { match.step! }

      expect(shaft(match).fetch(:joules_roped)).to be > 0.0
      expect(match.operation(:source).state.dig(:nodes, :load, :supply_joules)).to be > 0.0
    end

    it "refuses a rope stiff enough to ring" do
      expect { coupled(couplings: [ default_couplings.first.merge(stiffness: 1.0e5) ]) }
        .to raise_error(ReactorSim::Error, /would ring/)
    end

    it "refuses an end a rope cannot be tied to" do
      expect { coupled(couplings: [ { from: %w[source shaft], to: %w[sink line_shaft] } ]) }
        .to raise_error(ReactorSim::Error, /not something a rope can be tied to/)
    end
  end

  describe "snapshot" do
    it "round-trips the couplings and the unspent supply" do
      match = coupled
      20.times { match.step! }

      restored = ReactorSim::Match.from_h(JSON.parse(JSON.generate(match.to_h)))

      expect(restored.digest).to eq(match.digest)
      # Symbols as values do not survive JSON, and a coupling carries four of them.
      expect(restored.couplings.first.to_node).to be(:line_shaft)
      expect(restored.couplings.first.from_operation).to be(:source)
      expect(restored.operation(:sink).state.fetch(:nodes).fetch(:line_shaft)
                     .fetch(:supply_joules))
        .to be_within(1e-9).of(shaft(match).fetch(:supply_joules))
    end

    it "keeps carrying work after a restore" do
      match = coupled
      20.times { match.step! }

      restored = ReactorSim::Match.from_h(JSON.parse(JSON.generate(match.to_h)))
      20.times { match.step!; restored.step! }

      expect(restored.digest).to eq(match.digest)
    end
  end
end
