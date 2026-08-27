# frozen_string_literal: true

require "reactor_sim"
require "support/loop_rig"

# "Lossy is fine, silent is not" (docs/simulation_architecture.md §8).
#
# The old engine destroyed ten units of steam across two ticks with nothing recording it.
# These specs exist so that cannot happen again: everything entering or leaving is on the
# books, so the totals must balance to float precision no matter what the operation does.
#
# This is the strongest available guard against a whole class of bug — a leak in advection,
# a phase change that loses latent heat, an arbiter that grants more than it takes — none
# of which announce themselves any other way.
RSpec.describe "conservation" do
  # Relative, because absolute energies here are ~1e9 J and float epsilon scales with
  # magnitude. Anything real is orders of magnitude bigger than this.
  TOLERANCE = 1e-9

  def rig(seed: 7, time_scale: 4.0)
    ReactorSim::Match
      .create(id: "c", seed: seed, operations: [ { id: "rig", type: :loop_rig } ], time_scale:)
      .operation(:rig)
  end

  def balances(op)
    [ ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger),
      ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) ]
  end

  def expect_balanced(op, mass0, joules0, context)
    mass, joules = balances(op)
    expect((mass - mass0).abs / [ mass0.abs, 1.0 ].max).to be < TOLERANCE,
      "mass drifted by #{mass - mass0} kg #{context}"
    expect((joules - joules0).abs / [ joules0.abs, 1.0 ].max).to be < TOLERANCE,
      "energy drifted by #{joules - joules0} J #{context}"
  end

  it "conserves mass and energy through boiling, condensing and recirculation" do
    op = rig
    op.set_control(:burner, 30)
    mass0, joules0 = balances(op)

    400.times { |i| op.step!(tick: i + 1) }

    expect_balanced(op, mass0, joules0, "over 400 ticks of normal operation")
  end

  # The same assertion at 40x compression. If any integrator were dt-sensitive this is
  # where it would show, which is exactly why the thermal and reaction models are
  # closed-form rather than explicit Euler.
  it "conserves them identically under heavy time compression" do
    op = rig(time_scale: 40.0)
    op.set_control(:burner, 30)
    mass0, joules0 = balances(op)

    200.times { |i| op.step!(tick: i + 1) }

    expect_balanced(op, mass0, joules0, "at time_scale 40 (dt = 10 s)")
  end

  it "conserves them while a valve is shut and the system backs up" do
    op = rig
    op.set_control(:burner, 100)
    op.set_control(:steam_valve, 0)
    mass0, joules0 = balances(op)

    300.times { |i| op.step!(tick: i + 1) }

    expect_balanced(op, mass0, joules0, "with the steam valve shut")
  end

  # Shut in, with the fire lit. Gases are limited by what the walls can stand rather than
  # by volume arithmetic, so a boiler that can vent freely simply will not burst — it has
  # to be given nowhere to put the steam.
  it "conserves them after a node has failed" do
    op = rig
    op.set_control(:burner, 100)
    op.set_control(:steam_valve, 0)
    events = []
    600.times { |i| events.concat(op.step!(tick: i + 1)) }

    expect(events.map { |e| e[:type] }).to include(:vessel_rupture)
    mass, = balances(op)
    expect(mass).to be_within(1e-6).of(400.0)
  end

  describe "the ledger" do
    it "accounts for burner energy as an input rather than as drift" do
      op = rig
      op.set_control(:burner, 100)
      100.times { |i| op.step!(tick: i + 1) }

      # 3 MW at 100% for 100 ticks of 1 simulated second.
      expect(op.ledger.fetch(:joules_added)).to be_within(1.0).of(3.0e6 * 100)
    end

    it "records waste heat leaving through the walls" do
      op = rig
      op.set_control(:burner, 30)
      100.times { |i| op.step!(tick: i + 1) }

      expect(op.ledger.fetch(:joules_to_ambient)).to be > 0.0
    end

    # Every gram is either still in the operation or written down. There is no third place
    # for it to be, and that is the entire point.
    it "leaves nothing unaccounted for" do
      op = rig
      op.set_control(:burner, 50)
      200.times { |i| op.step!(tick: i + 1) }

      held = op.total_mass
      out = ReactorSim::Ledger.mass_out(op.ledger)
      added = ReactorSim::Ledger.mass_in(op.ledger)

      expect(held + out - added).to be_within(1e-9).of(400.0)
    end
  end
end
