# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"
require "support/conservation"

# **The hoist: a drum, two balanced cages, a brake, and an engineman.**
#
# Gravity on what is in cage A is a torque source inside the drive solve, so a brake holds a laden
# cage and an unbraked one runs; the player names a destination and the engineman works the clutches
# and the brake to reach it; riders are committed to the cage from boarding to the far landing. The
# hoist does not know whether anybody is winding it — with the post empty, its levers hold where they
# were left and every other force still acts.
#
# Constructed states throughout, a handful of ticks each.
RSpec.describe ReactorSim::Nodes::Hoist do
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  def pit
    build_pit(id: "h", seed: 5, loadout: { manriding: :cage_gear }, crew: PitRig::WOUND_CREW)
  end

  def drum(op) = op.nodes.fetch(:cage_drive)
  def drum_state(op) = op.state.dig(:nodes, :cage_drive)
  def position(op) = drum(op).position_m(drum_state(op))
  def speed(op) = drum(op).speed_m_s(drum_state(op))

  # Hands aboard, wherever the cage is.
  def aboard(place, seats = %i[crew_1 crew_2 crew_3 crew_4])
    seats.to_h { |seat| [ seat, { via: :cage_drive, place: place, posting: nil, station: nil } ] }
  end

  def lever(op, id) = op.state.dig(:controls, id, :actual)

  def levers_at(forward: 0.0, reverse: 0.0, release: 0.0)
    { cage_forward: { target: forward, actual: forward },
      cage_reverse: { target: reverse, actual: reverse },
      cage_brake_release: { target: release, actual: release } }
  end

  describe "gravity" do
    let(:ctx) { ReactorSim::Tick::Context.new(controls: {}, dt: 0.25, cargo: { cage_drive: 280.0 }) }

    it "pulls on the drum by what is in cage A, and not at all when it is empty" do
      hoist = drum(pit)
      empty = ReactorSim::Tick::Context.new(controls: {}, dt: 0.25)

      expect(hoist.drive_torque({}, ctx))
        .to be_within(1e-9).of(ReactorSim::Units::GRAVITY_M_PER_S2 * hoist.radius_m * 280.0)
      expect(hoist.drive_torque({}, empty)).to eq(0.0)
    end

    it "runs a laden cage down with the brake off and nothing driving it" do
      op = seed(pit, nodes: { cage_drive: { position_m: 45.0 } }, minions: aboard(:bank),
                     controls: levers_at(release: 100.0))
      run!(op, 10)

      expect(speed(op)).to be > 1.0
      expect(position(op)).to be > 45.0
    end

    it "is held by the brake with the brake on" do
      op = seed(pit, nodes: { cage_drive: { position_m: 45.0 } }, minions: aboard(:bank))
      run!(op, 10)

      expect(position(op)).to be_within(1e-3).of(45.0)
    end

    it "closes the books while it lowers and while it raises" do
      [ [ 0.0, 100 ], [ 90.0, 0 ] ].each do |from, to|
        op = seed(pit, nodes: { cage_drive: { position_m: from } },
                       minions: aboard(from.zero? ? :bank : :pit_bottom))
        engineman!(op)
        op.set_control(:man_winding, to)
        start = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
        run!(op, 20)
        drift = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - start

        expect(drift.abs / op.total_joules.abs).to be < Conservation::TOLERANCE
      end
    end
  end

  describe "the engineman" do
    let(:winding) { ReactorSim::Operations::Mine::Winding.new(hoist: :cage_drive, forward: :f, reverse: :r, brake_release: :b) }

    # Cage A going down at 4 m/s, three metres short of the mark: a hand who knows the job has
    # started braking; one out of their depth has not.
    def at(lateness, frozen: false)
      hoist = drum(pit)
      state = { angular_momentum: 4.0 / hoist.radius_m * hoist.moment_of_inertia, position_m: 87.0 }
      winding.govern(destination: 100.0, drum: hoist, drum_state: state, lateness: lateness,
                     frozen: frozen, held: { f: 100.0, r: 0.0, b: 100.0 })
    end

    it "brakes earlier when he knows the job" do
      expect(at(1.0)).to eq(f: 0.0, r: 0.0, b: 0.0)
      expect(at(2.2)).to eq(f: 100.0, r: 0.0, b: 100.0)
    end

    it "leaves the levers where they are while he is frozen" do
      expect(at(1.0, frozen: true)).to eq(f: 100.0, r: 0.0, b: 100.0)
    end

    it "is not commanded by the player" do
      op = pit

      expect(op.set_control(:cage_brake_release, 100)).to be(false)
      expect(op.panel.fetch(:controls).map { |c| c[:id] }).not_to include(:cage_brake_release)
    end
  end

  # **The hoist does not know whether anybody is winding it.**
  describe "with nobody at the post" do
    it "holds the levers where they were left" do
      op = seed(pit, controls: levers_at(forward: 100.0, release: 100.0))
      run!(op, 5)

      expect([ lever(op, :cage_forward), lever(op, :cage_brake_release) ]).to eq([ 100.0, 100.0 ])
    end

    it "lets a cage left braked at a landing stay there" do
      op = seed(pit, minions: aboard(:bank))
      run!(op, 5)

      expect(position(op)).to be_within(1e-3).of(0.0)
    end

    it "lets a cage left driving mid-wind run on" do
      op = seed(pit, nodes: { cage_drive: { position_m: 40.0 } },
                     controls: levers_at(forward: 100.0, release: 100.0))
      run!(op, 20)

      expect(position(op)).to be > 41.0
    end
  end

  describe "riding it" do
    it "keeps a rider wherever the cage is, and aboard mid-shaft whatever they are told" do
      op = seed(pit, nodes: { cage_drive: { position_m: 45.0 } }, minions: aboard(:bank, [ :crew_1 ]))
      op.assign_minion(:crew_1, :quarters)
      run!(op, 10)

      rider = op.state.dig(:minions, :crew_1)
      expect(rider[:via]).to be(:cage_drive)
      expect(rider[:progress]).to be_within(0.5).of(45.0)
    end

    it "boards only when the cage is at their landing and stopped" do
      away = seed(pit, nodes: { cage_drive: { position_m: 90.0 } })
      here = pit
      [ away, here ].each do |op|
        engineman!(op)
        op.assign_minion(:crew_1, :haulage)
        run!(op, 3)
      end

      expect(away.state.dig(:minions, :crew_1, :via)).to be_nil
      expect(here.state.dig(:minions, :crew_1, :via)).to be(:cage_drive)
    end

    # A cage with no power behind it is not a way down: a rider in it at their own landing gets out,
    # where one in a cage whose shaft is turning waits to be wound.
    it "steps off a cage that has stopped running at the landing they got on at" do
      waiting = aboard(:bank, [ :crew_1 ]).transform_values { |s| s.merge(posting: :haulage) }
      shaft = pit.nodes.fetch(:line_shaft)
      turning = { line_shaft: { angular_momentum: shaft.moment_of_inertia * 20.0 } }

      running = seed(pit, nodes: turning, minions: waiting)
      dead = seed(pit, minions: waiting)
      [ running, dead ].each do |op|
        engineman!(op)
        run!(op, 2, supply: op.equal?(dead) ? 0.0 : PitRig::SUPPLY_J)
      end

      expect(running.state.dig(:minions, :crew_1, :via)).to be(:cage_drive)
      expect(dead.state.dig(:minions, :crew_1, :via)).to be_nil
    end
  end
end
