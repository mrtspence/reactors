# frozen_string_literal: true

require "reactor_sim"

# **What pays for a head.** `Conduit#head_pa` was a pressure source with a lever on it and nobody
# paying the bill; a driven fitting charges the shaft it hangs off for the hydraulic power it
# actually delivered.
#
# On a rig rather than on a machine, because the claim is about the adapter rather than about any
# particular pump — and because a sump lifting water out of a mine is the consumer this was built
# for and there is no mine yet.
#
# See `docs/design_sketches/driven_transport.md` §3.
RSpec.describe "a driven conduit" do
  let(:content) { ReactorSim::Content.default }

  # A shaft with a great deal of inertia, so a single tick's drag does not dominate the speed and
  # the drag figures can be read as rates rather than as transients.
  def rig(lift_m: 0.0, efficiency: 1.0, head_pa: 0.0, driven_by: :shaft, rated_omega: nil,
          initial_omega: 20.0, valve: 100.0, delivers_to: :work)
    pump = ReactorSim::Nodes::Conduit.new(
      id: :pump, label: "Sump Pump", accepts: [ :liquid ],
      max_kg_per_s: 4.0, heat_capacity: 1.0e4, ambient_conductance: 0.0,
      control_id: :valve, driven_by: driven_by, lift_m: lift_m,
      efficiency: efficiency, head_pa: head_pa, rated_omega: rated_omega,
      delivers_to: delivers_to
    )

    ReactorSim::Operation.new(
      id: :rig, type: :rig, seed: 1, content: content,
      nodes: [
        ReactorSim::Nodes::Flywheel.new(id: :shaft, mass_kg: 4.0e5, radius_m: 1.0,
                                        initial_omega: initial_omega),
        sump, pump, discharge
      ],
      links: [
        ReactorSim::Link.new(from: [ :sump, :out ],    to: [ :pump, :inlet ]),
        ReactorSim::Link.new(from: [ :pump, :outlet ], to: [ :surface, :in ])
      ],
      control_points: [
        ReactorSim::ControlPoint.new(id: :valve, label: "Pump Valve", node: :pump,
                                     default: valve)
      ]
    )
  end

  def sump
    ReactorSim::Nodes::Vessel.new(
      id: :sump, volume_m3: 40.0, ambient_conductance: 0.0,
      initial_contents: [ { resource: :water, kg: 8_000.0 } ],
      ports: [ ReactorSim::Port.new(id: :out, direction: :outlet, accepts: [ :liquid ],
                                    max_kg_per_s: 4.0) ]
    )
  end

  def discharge
    ReactorSim::Nodes::Vessel.new(
      id: :surface, volume_m3: 40.0, ambient_conductance: 0.0,
      ports: [ ReactorSim::Port.new(id: :in, direction: :inlet, accepts: [ :liquid ],
                                    max_kg_per_s: 4.0) ]
    )
  end

  def ctx_for(op)
    ReactorSim::Operation::Context.new(
      controls: op.state.fetch(:controls).transform_values { |s| s.fetch(:actual) },
      dt: ReactorSim::DT, tick: 1, content: op.content,
      nodes: op.nodes, states: op.state.fetch(:nodes)
    )
  end

  def omega(op) = op.nodes.fetch(:shaft).omega(op.state.fetch(:nodes).fetch(:shaft))
  def lifted(op) = op.nodes.fetch(:surface).contents_kg(op.state.fetch(:nodes).fetch(:surface))
  def drag(op) = op.nodes.fetch(:pump).drag_conductances(op.state.fetch(:nodes).fetch(:pump),
                                                         ctx_for(op))

  describe "the throughput a conduit is charged for" do
    # A conduit is resolved THROUGH, so it is never a flow's endpoint and its `Grant` is empty.
    # Before this it had no way to learn its own throughput at all, which is why `Tick#advect`
    # records what crossed each wall.
    it "learns what it actually passed, by mass and by volume" do
      op = rig
      5.times { |t| op.step!(tick: t + 1) }
      wall = op.state.fetch(:nodes).fetch(:pump)

      expect(wall.fetch(:carried_kg)).to be > 0.0
      expect(wall.fetch(:carried_m3)).to be > 0.0
      # Water, so the two should agree on roughly 1000 kg/m³.
      expect(wall.fetch(:carried_kg) / wall.fetch(:carried_m3)).to be_within(60.0).of(1000.0)
    end

    # **The stale-figure trap.** A conduit nothing crossed this tick would otherwise keep last
    # tick's number and go on charging its shaft for a flow that has stopped.
    it "reports zero on a tick nothing crossed, rather than last tick's figure" do
      op = rig(lift_m: 100.0)
      5.times { |t| op.step!(tick: t + 1) }
      expect(op.state.fetch(:nodes).fetch(:pump).fetch(:carried_kg)).to be > 0.0

      op.set_control(:valve, 0.0)
      5.times { |t| op.step!(tick: t + 10) }

      expect(op.state.fetch(:nodes).fetch(:pump).fetch(:carried_kg)).to eq(0.0)
    end
  end

  describe "what the shaft is charged" do
    it "charges nothing at all for a conduit that names no shaft" do
      op = rig(driven_by: nil, lift_m: 100.0)
      5.times { |t| op.step!(tick: t + 1) }

      expect(drag(op)).to be_empty
    end

    # The behaviour §3.1 exists for: both terms collapse to zero with no flow, so a pump against
    # a shut valve costs its shaft almost nothing.
    it "charges nothing for a pump against a shut valve" do
      op = rig(lift_m: 100.0, valve: 0.0)
      5.times { |t| op.step!(tick: t + 1) }

      expect(drag(op)).to be_empty
      expect(omega(op)).to be_within(1e-9).of(20.0)
    end

    it "charges the shaft once it is actually lifting" do
      op = rig(lift_m: 100.0)
      5.times { |t| op.step!(tick: t + 1) }

      expect(drag(op).values.sum).to be > 0.0
      expect(omega(op)).to be < 20.0
    end

    # `ρ·g·h` is linear in height, and the drag conductance is linear in the power — so doubling
    # the lift doubles the bill. Asserted as a RATIO, never as a figure.
    it "charges twice as much to lift twice as high" do
      shallow = rig(lift_m: 50.0).tap { |o| 5.times { |t| o.step!(tick: t + 1) } }
      deep = rig(lift_m: 100.0).tap { |o| 5.times { |t| o.step!(tick: t + 1) } }

      expect(drag(deep).values.sum / drag(shallow).values.sum).to be_within(0.05).of(2.0)
    end

    # A worse pump costs more shaft for the same water, which is what makes the fitting a
    # decision rather than a constant.
    it "charges a less efficient pump more for the same work" do
      good = rig(lift_m: 100.0, efficiency: 0.8).tap { |o| 5.times { |t| o.step!(tick: t + 1) } }
      poor = rig(lift_m: 100.0, efficiency: 0.4).tap { |o| 5.times { |t| o.step!(tick: t + 1) } }

      expect(drag(poor).values.sum / drag(good).values.sum).to be_within(0.05).of(2.0)
    end

    it "hangs its drag on the shaft it names" do
      op = rig(lift_m: 100.0)

      expect(op.nodes.fetch(:pump).drag_shaft).to be(:shaft)
    end

    # **The two halves of the bill are different claims.** A sump pump's hydraulic half leaves
    # with the water it lifted (`:work`, on the ledger); what it wasted heats the pump. Booking
    # the whole thing one way would either ledger a fan's losses as delivered work or bury a
    # mine's output in a machine's metal.
    it "splits the bill between what it delivered and what it wasted" do
      op = rig(lift_m: 100.0, efficiency: 0.5, delivers_to: :work)
      5.times { |t| op.step!(tick: t + 1) }

      shares = drag(op)
      expect(shares.keys).to contain_exactly(:work, :pump)
      # Half the shaft power reaches the water at 0.5 efficiency, so the two halves are equal.
      expect(shares.fetch(:work)).to be_within(1e-9).of(shares.fetch(:pump))
    end

    # The default, and it is right for a fan: the air stays in the operation, so the pressure
    # the fan put into it dissipates into the stream rather than leaving.
    it "heats the fitting itself when no destination is named" do
      op = rig(lift_m: 100.0, efficiency: 0.5, delivers_to: nil)
      5.times { |t| op.step!(tick: t + 1) }

      expect(drag(op).keys).to eq([ :pump ])
    end
  end

  describe "head from a shaft" do
    # Head goes as ω², so a machine at half speed supplies a quarter of its head. That is what
    # makes a driven blower fail the way a real one does rather than merely more slowly.
    it "supplies a quarter of its head at half its rated speed" do
      full = rig(head_pa: 600.0, rated_omega: 20.0, initial_omega: 20.0)
      half = rig(head_pa: 600.0, rated_omega: 20.0, initial_omega: 10.0)

      expect(full.nodes.fetch(:pump).head_pa(ctx_for(full))).to be_within(1e-6).of(600.0)
      expect(half.nodes.fetch(:pump).head_pa(ctx_for(half))).to be_within(1e-6).of(150.0)
    end

    it "supplies nothing at all from a stopped shaft" do
      stopped = rig(head_pa: 600.0, rated_omega: 20.0, initial_omega: 0.0)

      expect(stopped.nodes.fetch(:pump).head_pa(ctx_for(stopped))).to eq(0.0)
    end

    # An undriven conduit must be bit-identical to before, which is what lets this land without
    # touching the chimney, the damper or the blower.
    it "leaves an undriven conduit's head exactly as it was" do
      op = rig(driven_by: nil, head_pa: 600.0)

      expect(op.nodes.fetch(:pump).head_pa(ctx_for(op))).to be_within(1e-6).of(600.0)
    end
  end

  describe "conservation" do
    # The class of change `conservation_spec` exists to catch: a driven conduit moves energy out
    # of a shaft and into flow, and the shaft's loss has to land somewhere on the books.
    it "keeps mass and energy balanced while the pump is working" do
      op = rig(lift_m: 120.0, efficiency: 0.55)
      before_mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.state.fetch(:ledger))
      before_joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.state.fetch(:ledger))

      200.times { |t| op.step!(tick: t + 1) }

      expect(ReactorSim::Ledger.mass_balance(op.total_mass, op.state.fetch(:ledger)))
        .to be_within(1e-6).of(before_mass)
      expect(ReactorSim::Ledger.energy_balance(op.total_joules, op.state.fetch(:ledger)))
        .to be_within(1.0).of(before_joules)
    end

    it "actually moves the water it is being charged for" do
      op = rig(lift_m: 120.0, efficiency: 0.55)
      200.times { |t| op.step!(tick: t + 1) }

      expect(lifted(op)).to be > 0.0
      expect(omega(op)).to be < 20.0
    end
  end
end
