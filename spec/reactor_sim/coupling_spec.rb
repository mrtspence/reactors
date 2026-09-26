# frozen_string_literal: true

require "reactor_sim"

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
  # Relative to the energy actually being handled, never to the starting balance: a sink starts
  # empty, so normalising against its opening figure turns a relative tolerance into an absolute
  # one and fails on ordinary float noise at 1e7 J.
  TOLERANCE = 1e-9

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
                                      moment_of_inertia: 1.0e3, friction: 50.0)
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
    expect(drift.abs / magnitude).to be < TOLERANCE, "match drifted by #{drift} J"
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
      expect(drift.abs / scale(op)).to be < TOLERANCE, "#{op.id} drifted by #{drift} J"
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
    # The whole reason this is a shaft rather than a number on a ledger: an engine that cannot
    # deliver leaves a shaft winding down, not a switch flipped.
    it "winds the shaft down rather than stopping it dead" do
      match = coupled
      120.times { match.step! }
      running = shaft(match).fetch(:angular_momentum)
      expect(running).to be > 0.0

      match.operation(:source).set_control(:demand, 0)
      trace = Array.new(1400) do
        match.step!
        [ shaft(match).fetch(:supply_joules), shaft(match).fetch(:angular_momentum) ]
      end
      supply = trace.map(&:first)
      speed = trace.map(&:last)

      expect(supply.each_cons(2).all? { |a, b| b <= a + 1e-9 }).to be(true), "supply rose again"
      # Spent out, to float noise. **Not `eq(0.0)`**: `Import#add_joules` is deliberately
      # unclamped so a genuinely mis-computed bill shows up as a negative balance, which means
      # the last tick's rounding lands either side of zero rather than exactly on it.
      expect(supply.last.abs).to be < 1e-6

      # **The claim, and the reason this is a shaft rather than a number on a ledger.** The
      # shaft does not drop when the supply does — it holds its equilibrium against its own
      # windage, spending what is already in hand, and only fades once that is gone. Measured:
      # it ran on at full speed for the better part of a thousand ticks.
      # How long the run-on lasts is set by `Import`'s `holds_seconds:` — ten seconds of rated
      # output — so this is "many ticks, at speed", not a figure. A switch would be one tick.
      emptied = supply.index { |j| j.abs < 1e-6 }
      expect(emptied).to be > 50
      expect(speed.fetch(emptied - 1)).to be > running * 0.9

      # And then it genuinely winds down, rather than the torque simply switching off.
      expect(speed.last).to be < running * 0.05
      expect(speed.fetch(emptied)).to be > speed.last
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
