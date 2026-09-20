# frozen_string_literal: true

require "reactor_sim"

# A small engine that carries its own rotor.
#
# **It exists so a blower can work on a black start.** A fitting driven by the main drivetrain
# cannot help bring that drivetrain to life, so the donkey engine burns its own fuel and turns
# its own shaft, and a driven `Conduit` then names it with `driven_by:`.
#
# On a rig, because the claim is about the node rather than about the steam engine — and the
# thing most likely to be got wrong is that it turns fuel into torque **through combustion**
# rather than by fiat, which is what keeps it inside the conservation books.
RSpec.describe ReactorSim::Nodes::Motor do
  let(:content) { ReactorSim::Content.default }

  def rig(fuel_kg: 40.0, throttle: 100.0, rated_torque_nm: 200.0, rated_omega: 60.0)
    motor = described_class.new(
      id: :donkey, label: "Donkey Engine", volume_m3: 0.15, fuel_charge_kg: 0.0002,
      swept_m3: 0.004, moment_of_inertia: 0.4, reactions: %i[oil_combustion],
      control_id: :donkey_throttle, rated_torque_nm: rated_torque_nm,
      rated_omega: rated_omega, heat_capacity: 8.0e3, ambient_conductance: 25.0,
      initial_temperature_k: 700.0,
      ports: [
        ReactorSim::Port.new(id: :fuel, direction: :inlet, accepts: [ :fuel ],
                             max_kg_per_s: 0.2),
        ReactorSim::Port.new(id: :air, direction: :inlet, accepts: [ :gas ],
                             max_kg_per_s: 2.0),
        ReactorSim::Port.new(id: :exhaust, direction: :outlet, accepts: [ :gas ],
                             max_kg_per_s: 2.0)
      ]
    )

    ReactorSim::Operation.new(
      id: :rig, type: :rig, seed: 1, content: content,
      nodes: [ motor, tank(fuel_kg), ReactorSim::Nodes::Atmosphere.new(id: :air_supply),
               fuel_line, air_line, flue ],
      links: [
        ReactorSim::Link.new(from: [ :tank, :out ],          to: [ :fuel_line, :inlet ]),
        ReactorSim::Link.new(from: [ :fuel_line, :outlet ],  to: [ :donkey, :fuel ]),
        ReactorSim::Link.new(from: [ :air_supply, :intake ], to: [ :air_line, :inlet ]),
        ReactorSim::Link.new(from: [ :air_line, :outlet ],   to: [ :donkey, :air ]),
        ReactorSim::Link.new(from: [ :donkey, :exhaust ],    to: [ :flue, :inlet ]),
        ReactorSim::Link.new(from: [ :flue, :outlet ],       to: [ :air_supply, :exhaust ])
      ],
      control_points: [
        ReactorSim::ControlPoint.new(id: :donkey_throttle, label: "Donkey Throttle",
                                     node: :donkey, default: throttle)
      ]
    )
  end

  def tank(kg)
    ReactorSim::Nodes::Vessel.new(
      id: :tank, volume_m3: 0.5, ambient_conductance: 0.0,
      initial_contents: [ { resource: :fuel_oil, kg: kg } ],
      ports: [ ReactorSim::Port.new(id: :out, direction: :outlet, accepts: [ :fuel ],
                                    max_kg_per_s: 0.2) ]
    )
  end

  def fuel_line
    ReactorSim::Nodes::Conduit.new(id: :fuel_line, accepts: [ :fuel ], max_kg_per_s: 0.2,
                                   heat_capacity: 50.0, ambient_conductance: 0.0)
  end

  def air_line
    ReactorSim::Nodes::Conduit.new(id: :air_line, accepts: [ :gas ], max_kg_per_s: 2.0,
                                   conductance: 0.02, heat_capacity: 200.0,
                                   ambient_conductance: 0.0)
  end

  def flue
    ReactorSim::Nodes::Conduit.new(id: :flue, accepts: [ :gas ], max_kg_per_s: 2.0,
                                   conductance: 0.02, heat_capacity: 200.0,
                                   ambient_conductance: 0.0)
  end

  def run(op, ticks)
    ticks.times { |t| op.step!(tick: t + 1) }
    op
  end

  def omega(op) = op.nodes.fetch(:donkey).omega(op.state.fetch(:nodes).fetch(:donkey))
  def tank_kg(op) = op.nodes.fetch(:tank).contents_kg(op.state.fetch(:nodes).fetch(:tank))

  describe "running" do
    it "turns its own rotor without anything else driving it" do
      op = run(rig, 400)

      expect(omega(op)).to be > 0.0
    end

    it "burns the fuel it turns on, rather than making torque from nothing" do
      op = rig
      before = tank_kg(op)
      run(op, 400)

      expect(tank_kg(op)).to be < before
      expect(op.state.fetch(:ledger).fetch(:joules_from_reactions)).to be > 0.0
    end

    # The governor, expressed as a curve rather than as a controller: torque is shed as it
    # approaches its rated speed, so a light load does not run it away.
    it "settles near its rated speed instead of accelerating without limit" do
      op = run(rig(rated_omega: 60.0), 2_000)

      expect(omega(op)).to be_between(30.0, 60.0)
    end

    it "spins up faster on a bigger engine, for the same fuel" do
      small = run(rig(rated_torque_nm: 40.0), 60)
      big = run(rig(rated_torque_nm: 200.0), 60)

      expect(omega(big)).to be > omega(small)
    end

    # **It has to be got turning before it will make power**, because it breathes by
    # displacement — which is what a starting handle is for and what makes a stalled engine
    # stay stalled rather than restarting itself.
    it "draws no air at all while it is stopped" do
      op = rig
      ctx = ReactorSim::Operation::Context.new(
        controls: { donkey_throttle: 100.0 }, dt: ReactorSim::DT, tick: 1,
        content: content, nodes: op.nodes, states: op.state.fetch(:nodes)
      )

      expect(op.nodes.fetch(:donkey).scavenge_kg(ctx)).to eq(0.0)
    end
  end

  describe "running out" do
    # The whole point of a separate tank: running dry is something a player can watch happen.
    it "stops making torque once the tank is empty" do
      op = run(rig(fuel_kg: 0.05), 3_000)

      expect(tank_kg(op)).to be_within(1e-6).of(0.0)
      expect(op.state.fetch(:nodes).fetch(:donkey).fetch(:torque)).to eq(0.0)
    end

    it "does nothing at all with the throttle shut" do
      op = rig(throttle: 0.0)
      before = tank_kg(op)
      run(op, 400)

      expect(omega(op)).to eq(0.0)
      expect(tank_kg(op)).to be_within(1e-9).of(before)
    end
  end

  describe "conservation" do
    # **The claim that matters.** A node turning kilograms of oil into joules of shaft work
    # directly would be a second energy path outside the reaction system; this one burns its
    # charge through the ordinary combustion machinery and balances like anything else.
    it "keeps mass and energy balanced while it runs" do
      op = rig
      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.state.fetch(:ledger))
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.state.fetch(:ledger))

      run(op, 800)

      expect(ReactorSim::Ledger.mass_balance(op.total_mass, op.state.fetch(:ledger)))
        .to be_within(1e-6).of(mass)
      expect(ReactorSim::Ledger.energy_balance(op.total_joules, op.state.fetch(:ledger)))
        .to be_within(1.0).of(joules)
    end

    # It may not drive its own charge below ambient, which is the same bound
    # `Cylinder#extractable_joules` enforces and the reason a starved engine stops rather than
    # inventing work.
    it "cannot deliver more work than its charge holds" do
      op = run(rig(fuel_kg: 0.02), 2_000)
      state = op.state.fetch(:nodes).fetch(:donkey)

      expect(op.nodes.fetch(:donkey).extractable_joules(state)).to be >= 0.0
      expect(op.nodes.fetch(:donkey).temperature_k(state, content)).to be > 0.0
    end
  end
end
