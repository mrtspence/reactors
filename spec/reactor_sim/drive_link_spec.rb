# frozen_string_literal: true

require "reactor_sim"
require "support/conservation"

# **A drive link may be geared and clutched.** Geared, `b` is pulled toward `ratio × ω_a` and `a`
# gives up `ratio` times the momentum `b` gains, because a gear multiplies torque; a reverser is
# `ratio: -1`. Clutched, the lever scales the conductance and a disengaged link drops out. This is
# what lets a winding drum be driven both ways off a line shaft that turns one way.
RSpec.describe ReactorSim::DriveLink do
  def solve(link, inertias, speeds, dt: 0.25)
    ReactorSim::Relaxation.settle([ link ], inertias, speeds, dt)
  end

  # Advance two bodies by the solver alone: arithmetic, no tick.
  def run(link, inertias, speeds, steps)
    steps.times.reduce(speeds) do |omega, _|
      moved = solve(link, inertias, omega).fetch(link.id)
      { a: omega.fetch(:a) - (link.ratio * moved / inertias.fetch(:a)),
        b: omega.fetch(:b) + (moved / inertias.fetch(:b)) }
    end
  end

  describe "geared" do
    it "pulls the driven end toward the ratio times the driver" do
      link = described_class.new(a: :a, b: :b, stiffness: 50.0, ratio: 2.0)
      settled = run(link, { a: 1.0e6, b: 10.0 }, { a: 10.0, b: 0.0 }, 200)

      expect(settled.fetch(:b)).to be_within(0.01).of(2.0 * settled.fetch(:a))
    end

    it "turns the driven end backwards through a reverser" do
      link = described_class.new(a: :a, b: :b, stiffness: 50.0, ratio: -1.0)
      settled = run(link, { a: 1.0e6, b: 10.0 }, { a: 10.0, b: 0.0 }, 200)

      expect(settled.fetch(:b)).to be_within(0.01).of(-settled.fetch(:a))
    end

    # Momentum is not conserved across a gear and is not meant to be. Energy is never created:
    # what the driven end gains is at most what the driver gave up, the rest being slip.
    it "creates no energy in a step, at any ratio" do
      [ 2.0, -1.0, 0.5 ].each do |ratio|
        link = described_class.new(a: :a, b: :b, stiffness: 400.0, ratio: ratio)
        inertias = { a: 30.0, b: 10.0 }
        before = { a: 12.0, b: -3.0 }
        after = run(link, inertias, before, 1)
        energy = ->(w) { w.sum { |id, omega| 0.5 * inertias.fetch(id) * (omega**2) } }

        expect(energy.call(after)).to be <= energy.call(before) + 1e-9
      end
    end

    it "is bit for bit an ungeared link at a ratio of one" do
      plain = Struct.new(:id, :a, :b, :conductance).new(:"a=b", :a, :b, 123.0)
      geared = described_class.new(a: :a, b: :b, stiffness: 123.0, ratio: 1.0)
      inertias = { a: 7.0, b: 3.0 }
      speeds = { a: 4.5, b: -1.25 }

      expect(solve(geared, inertias, speeds)).to eq(solve(plain, inertias, speeds))
    end
  end

  describe "clutched" do
    let(:link) { described_class.new(a: :a, b: :b, stiffness: 80.0, control_id: :clutch) }

    it "drops out when the clutch is out" do
      expect(link.engaged({ clutch: 0.0 })).to be_nil
    end

    it "carries a share of its conductance as the clutch comes in" do
      expect(link.engaged({ clutch: 50.0 }).conductance).to eq(40.0)
    end

    it "is always in when it has no clutch" do
      plain = described_class.new(a: :a, b: :b, stiffness: 80.0)

      expect(plain.engaged({})).to be(plain)
    end
  end

  # One short operation, so the gear's momentum reaches the tick's own bookkeeping: a reverser
  # driven by a spinning wheel, with the clutch in.
  describe "in an operation" do
    def reverser(clutch)
      op = ReactorSim::Operation.new(
        id: :rig, type: :test, seed: 1,
        nodes: [ ReactorSim::Nodes::Flywheel.new(id: :wheel, mass_kg: 2.0e3, radius_m: 1.0,
                                                 initial_omega: 20.0),
                 ReactorSim::Nodes::Flywheel.new(id: :drum, mass_kg: 200.0, radius_m: 0.5) ],
        drive_links: [ described_class.new(id: :reverse, a: :wheel, b: :drum, stiffness: 300.0,
                                           ratio: -1.0, control_id: :clutch) ],
        control_points: [ ReactorSim::ControlPoint.new(id: :clutch, node: :drum, default: clutch) ]
      )
      start = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      20.times { |i| op.step!(tick: i + 1) }
      [ op, start ]
    end

    def drum_omega(op) = op.nodes.fetch(:drum).omega(op.state.dig(:nodes, :drum))

    it "drives the drum backwards with the clutch in, and not at all with it out" do
      engaged, = reverser(100.0)
      slack, = reverser(0.0)

      expect(drum_omega(engaged)).to be < -1.0
      expect(drum_omega(slack)).to eq(0.0)
    end

    it "closes the books" do
      op, start = reverser(100.0)
      drift = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - start

      expect(drift.abs / op.total_joules.abs).to be < Conservation::TOLERANCE
    end
  end
end
