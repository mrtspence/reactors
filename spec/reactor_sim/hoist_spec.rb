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
    build_pit(id: "h", seed: 5, loadout: { winder: :cage_gear }, crew: PitRig::WOUND_CREW)
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

  def badly_hurt(events)
    badly = %i[severe mortal]
    events.select { |e| e[:type] == :minion_hurt && badly.include?(e[:mode]) }
  end

  def levers_at(forward: 0.0, reverse: 0.0, release: 0.0)
    { cage_forward: { target: forward, actual: forward },
      cage_reverse: { target: reverse, actual: reverse },
      cage_brake_release: { target: release, actual: release } }
  end

  describe "gravity" do
    let(:ctx) do
      ReactorSim::Tick::Context.new(controls: {}, dt: 0.25, cargo: { cage_drive: 280.0 }, states: {})
    end

    it "pulls on the drum by what is in cage A, and not at all when it is empty" do
      hoist = drum(pit)
      empty = ReactorSim::Tick::Context.new(controls: {}, dt: 0.25, states: {})

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
      expect(at(2.2)).to include(r: 0.0, b: 100.0)
      expect(at(2.2)[:f]).to be_positive
    end

    # By speed, not clutch position: running faster than he wants near the mark, he lets the clutch
    # out from where it was; a laden cage running slow gets more of it.
    it "eases the clutch near the mark and takes it up when the cage is slow" do
      hoist = drum(pit)
      creeping = { angular_momentum: 0.1 / hoist.radius_m * hoist.moment_of_inertia, position_m: 30.0 }
      slow = winding.govern(destination: 100.0, drum: hoist, drum_state: creeping, lateness: 1.0,
                            frozen: false, held: { f: 40.0, r: 0.0, b: 100.0 })

      expect(at(2.2)[:f]).to be < 100.0
      expect(slow[:f]).to be > 40.0
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

  # **The ends of the shaft.** Cage A coming up fast with the clutch in, the brake off and nobody
  # at the post, so what stops it is whatever the fitting has — or the headframe.
  describe "the ends of the shaft" do
    def pit_with(cage) = build_pit(id: "e", seed: 5, loadout: { winder: cage }, crew: PitRig::WOUND_CREW)

    def running_up(cage, from_m:)
      seed(pit_with(cage),
           nodes: { cage_drive: { position_m: from_m, angular_momentum: -4.0 / 1.5 * 4_000.0 },
                    line_shaft: { angular_momentum: 900.0 * 22.0 } },
           minions: aboard(:pit_bottom, %i[crew_1 crew_2]),
           controls: levers_at(reverse: 100.0, release: 100.0))
    end

    def ended(op) = op.state.dig(:nodes, :cage_drive, :failure)
    def hurt(events) = events.select { |e| e[:type] == :minion_hurt }.map { |e| e[:node] }

    it "puts a plain cage through the headframe, and hurts the men in it" do
      op = running_up(:cage_gear, from_m: -3.0)
      events = run!(op, 10)

      expect(ended(op)).to be(:overwound)
      expect(hurt(events)).to include(:crew_1, :crew_2)
    end

    it "hangs a hooked cage in the catch plate, and hurts nobody in it badly" do
      op = running_up(:hooked_cage, from_m: -3.0)
      events = run!(op, 10)

      expect(ended(op)).to be(:caught)
      expect(badly_hurt(events)).to be_empty
    end

    it "throws the brake on past the mark with a trip, and stops it short of the headframe" do
      op = running_up(:tripped_cage, from_m: 2.0)
      run!(op, 20)

      expect(ended(op)).to be_nil
      expect(position(op)).to be_between(-drum(op).clearance_m, 0.0)
    end

    it "crashes a cage that goes down past the bottom landing too fast" do
      op = seed(pit_with(:cage_gear),
                nodes: { cage_drive: { position_m: 92.0, angular_momentum: 4.0 / 1.5 * 4_000.0 } },
                minions: aboard(:bank, %i[crew_1]), controls: levers_at(release: 100.0))
      events = run!(op, 10)

      expect(ended(op)).to be(:crashed)
      expect(hurt(events)).to include(:crew_1)
    end

    # What goes through the headframe goes down the shaft.
    it "sends wreckage down the shaft when it goes through the headframe" do
      op = running_up(:cage_gear, from_m: -3.0)
      before = op.state.dig(:nodes, :shaft, :durability)
      run!(op, 10)

      expect(op.state.dig(:nodes, :shaft, :durability)).to be < before
    end

    it "lets the men out of a wrecked cage at the nearest landing" do
      op = running_up(:hooked_cage, from_m: -3.0)
      run!(op, 12)

      expect(op.state.dig(:minions, :crew_1).values_at(:via, :place)).to eq([ nil, :bank ])
    end
  end

  # **The brake.** The spring's rod fatigues with every second it is applied and parts in the end;
  # the lining fades as it heats and glazes past a point it does not come back from.
  describe "the brake failing" do
    def brake(op) = op.nodes.fetch(:cage_brake)

    it "fades as the lining heats" do
      hot = brake(pit)

      expect([ 300.0, 450.0, 550.0, 650.0 ].map { |k| hot.fade(k) }).to eq([ 1.0, 1.0, hot.fade(550.0), 0.35 ])
      expect(hot.fade(550.0)).to be_between(0.35, 1.0).exclusive
    end

    it "stops a running cage less well hot than cold" do
      ends = [ 293.0, 620.0 ].map do |kelvin|
        op = seed(pit, nodes: { cage_drive: { position_m: 20.0, angular_momentum: 4.0 / 1.5 * 4_000.0 },
                                cage_brake: { joules: 5.0e4 * kelvin } },
                       minions: aboard(:bank))
        run!(op, 3)
        speed(op)
      end

      # Measured: 0.93 m/s cold against 2.10 hot, three ticks after it is thrown on.
      expect(ends.last).to be > ends.first * 2.0
    end

    it "lets a laden cage run once the rod has parted" do
      op = seed(pit, nodes: { cage_drive: { position_m: 45.0 },
                              cage_brake: { failure: :rod_parted, durability: 0.0 } },
                     minions: aboard(:bank))
      run!(op, 10)

      expect(speed(op)).to be > 2.0
    end

    it "glazes when it is run past its limit, and holds less for good" do
      op = seed(pit, nodes: { cage_brake: { joules: 5.0e4 * 720.0 } })
      run!(op, 1)

      expect(op.state.dig(:nodes, :cage_brake, :failure)).to be(:glazed)
      expect(brake(op).derating(op.state.dig(:nodes, :cage_brake), :grip)).to eq(0.6)
    end

    it "wears its rod while it is on, and not while it is held off" do
      on = pit
      off = seed(pit, controls: levers_at(release: 100.0))
      [ on, off ].each { |op| run!(op, 20) }

      integrity = ->(op) { brake(op).integrity(op.state.dig(:nodes, :cage_brake)) }
      expect(integrity.call(on)).to be < 1.0
      expect(integrity.call(off)).to eq(1.0)
    end
  end

  # **The rope.** It parts when what it carries passes what is left of its breaking strain; bending,
  # corrosion and a hot sheave wear it, and recapping and re-roping are what the bank can do back.
  describe "the rope" do
    def rope(op) = op.nodes.fetch(:winding_rope)
    def rope_state(op) = op.state.dig(:nodes, :winding_rope)
    def parted?(op) = rope_state(op)[:failure] == :parted

    # Just under a laden cage's weight, and well over an empty one's.
    def near_its_end(op, minions: {}, cage: nil)
      worn = 0.115 * rope_state(op).fetch(:initial_durability)
      seed(op, nodes: { cage_drive: { position_m: 30.0 }.merge(cage.to_h), winding_rope: { durability: worn } },
               minions: minions)
    end

    def with_cage(cage) = build_pit(id: "r", seed: 5, loadout: { winder: cage }, crew: PitRig::WOUND_CREW)

    it "parts under a laden cage near its end, and carries the empty one" do
      laden = near_its_end(pit, minions: aboard(:bank))
      empty = near_its_end(pit)
      [ laden, empty ].each { |op| run!(op, 4) }

      expect(parted?(laden)).to be(true)
      expect(parted?(empty)).to be(false)
      expect(drum(laden).load_torque(drum_state(laden))).to eq(0.0)
    end

    it "drops a cage with no catches down the shaft, and holds one that has them" do
      plain = near_its_end(with_cage(:cage_gear), minions: aboard(:bank))
      caught = near_its_end(with_cage(:hooked_cage), minions: aboard(:bank))
      bad = [ plain, caught ].map do |op|
        badly_hurt(run!(op, 4)).count
      end

      expect(bad.first).to be_positive
      expect(bad.last).to eq(0)
      expect(plain.state.dig(:minions, :crew_1).values_at(:via, :place)).to eq([ nil, :pit_bottom ])
    end

    it "wears faster over a hot sheave than a cool one" do
      worn = [ 300.0, 450.0 ].map do |kelvin|
        op = pit
        sheave = op.state.dig(:nodes, :sheave)
        hot = sheave.fetch(:joules) * kelvin / op.nodes.fetch(:sheave).temperature_k(sheave, op.content)
        op = seed(op, nodes: { sheave: { joules: hot } })
        run!(op, 20)
        1.0 - rope(op).integrity(rope_state(op))
      end

      expect(worn.last).to be > worn.first * 10.0
    end

    def recapping(spare_m)
      op = seed(pit, nodes: { winding_rope: { durability: 400.0, spare_m: spare_m } })
      op.assign_minion(:crew_1, :recapping)
      run!(op, 8)
      op
    end

    it "is made good by recapping at bank, and gets shorter every time" do
      op = recapping(20.0)

      expect(rope_state(op)[:durability]).to be > 400.0
      expect(rope_state(op)[:spare_m]).to be < 20.0
    end

    it "is not made good by recapping once there is nothing left to cut" do
      expect(rope_state(recapping(0.0))[:durability]).to be <= 400.0
    end

    def reroping(loadout)
      op = build_pit(id: "n", seed: 5, loadout: loadout, crew: PitRig::WOUND_CREW)
      near_done = ReactorSim::Nodes::Rope::RENEW_S - 1.0
      op = seed(op, nodes: { winding_rope: { durability: 0.0, failure: :parted, renewing_s: near_done } })
      op.assign_minion(:crew_1, :reroping)
      run!(op, 8)
      op
    end

    it "is renewed from the spare by re-roping, even once it has parted" do
      op = reroping(winder: :cage_gear, spare_rope: :spare_rope)

      expect(rope_state(op).values_at(:failure, :renewed)).to eq([ nil, 1 ])
      expect(op.state.dig(:nodes, :spare_rope, :in_store)).to be(false)
    end

    it "cannot be renewed with no spare in store" do
      expect(parted?(reroping(winder: :cage_gear))).to be(true)
    end
  end

  # **Coal rides the hoist.** The onsetter runs tubs onto the deck at the bottom, the banksman runs
  # them off at bank, and only with the cage standing at their landing; the deck's coal is the drum's
  # load like anybody in it. With `coal_winding` on, the engineman shuttles — and men come first.
  describe "coal on the hoist" do
    def deck_kg(op) = ReactorSim::Parcel.total_kg(op.state.dig(:nodes, :cage_deck, :parcels))
    def coal(kg) = parcels_at(292.0, coal: kg)

    def marshals(onsetter: true, banksman: true)
      { crew_3: ({ place: :pit_bottom, posting: :onsetting, station: :onsetting } if onsetter),
        crew_4: ({ place: :bank, posting: :banking, station: :banking } if banksman) }.compact
    end

    def turning(op)
      line = op.nodes.fetch(:line_shaft)
      { angular_momentum: line.moment_of_inertia * line.rated_omega }
    end

    it "loads the deck only at the bottom, with the cage standing there and the onsetter posted" do
      loaded = ->(position, onsetter) do
        op = seed(pit, nodes: { pit_bottom: { parcels: coal(500.0) }, cage_drive: { position_m: position } },
                       minions: marshals(onsetter: onsetter, banksman: false))
        run!(op, 5)
        deck_kg(op)
      end

      expect(loaded.call(90.0, true)).to be > 0.0
      expect(loaded.call(45.0, true)).to eq(0.0)
      expect(loaded.call(90.0, false)).to eq(0.0)
    end

    it "empties the deck only at bank" do
      emptied = ->(position) do
        op = seed(pit, nodes: { cage_deck: { parcels: coal(200.0) }, cage_drive: { position_m: position } },
                       minions: marshals(onsetter: false))
        run!(op, 5)
        200.0 - deck_kg(op)
      end

      expect(emptied.call(0.0)).to be > 0.0
      expect(emptied.call(45.0)).to eq(0.0)
    end

    it "makes the deck's coal the drum's load" do
      op = seed(pit, nodes: { cage_deck: { parcels: coal(600.0) } })
      ctx = ReactorSim::Tick::Context.new(controls: {}, dt: 0.25, nodes: op.nodes, states: op.state[:nodes])

      expect(drum(op).cargo_kg(ctx)).to be_within(1e-9).of(600.0)
    end

    def shuttling(nodes, minions = {})
      op = seed(pit, nodes: { line_shaft: turning(pit) }.merge(nodes),
                     minions: marshals.merge(crew_5: { place: :bank, posting: :man_winding,
                                                       station: :man_winding }).merge(minions))
      op.set_control(:coal_winding, 100.0)
      op
    end

    # A full deck at the bottom goes up; an empty one at bank with coal waiting comes down.
    it "shuttles a full deck up and an empty one down" do
      full = shuttling(cage_drive: { position_m: 90.0 }, cage_deck: { parcels: coal(960.0) })
      empty = shuttling(pit_bottom: { parcels: coal(500.0) })
      [ full, empty ].each { |op| run!(op, 12) }

      expect(position(full)).to be < 89.0
      expect(position(empty)).to be > 1.0
    end

    # **Men first**: somebody waiting at bank to go down turns a deck being loaded at the bottom
    # into a trip to fetch them.
    it "comes for a man waiting at a landing before it finishes loading" do
      waiting = { crew_1: { place: :bank, posting: :haulage, station: nil, via: nil } }
      op = shuttling({ cage_drive: { position_m: 90.0 }, pit_bottom: { parcels: coal(800.0) },
                       cage_deck: { parcels: coal(100.0) } }, waiting)
      run!(op, 12)

      expect(position(op)).to be < 89.0
    end

    # **Riding the kibble**: an unguided bucket swings, worse the faster it goes, and the peril
    # reaches whoever is in it. The cage has no such peril.
    it "puts the men riding a kibble at a peril that grows with its speed" do
      kibble = build_pit(id: "k", seed: 5, loadout: { winder: :steam_whim }).nodes.fetch(:cage_drive)
      slow = { angular_momentum: 0.5 / kibble.radius_m * kibble.moment_of_inertia, position_m: 40.0 }
      fast = { angular_momentum: 2.0 / kibble.radius_m * kibble.moment_of_inertia, position_m: 40.0 }

      expect(kibble.perils.map(&:id)).to eq(%i[riding_the_kibble])
      expect(kibble.perils.first.reaches?(nil, :bank, :cage_drive)).to be(true)
      expect(kibble.activity(fast, :swing, 0.25)).to be > kibble.activity(slow, :swing, 0.25)
      expect(drum(pit).perils).to be_empty
    end

    it "closes the books through a wind with coal on the deck" do
      op = shuttling(cage_drive: { position_m: 90.0 }, cage_deck: { parcels: coal(960.0) })
      mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      run!(op, 20)

      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      expect((mass - mass0).abs / mass0.abs).to be < Conservation::TOLERANCE
      expect((joules - joules0).abs / joules0.abs).to be < Conservation::TOLERANCE
    end
  end

  it "shows where the cage is on the depth indicator" do
    op = seed(pit, nodes: { cage_drive: { position_m: 45.0 } })
    run!(op, 3)

    expect(op.project.gauges.fetch(:cage_depth)).to be_within(1.0).of(45.0)
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

    # **A marshal at the landing stops the cage being loaded past its rating**; with nobody there,
    # everybody waiting gets on. The kibble is rated for three hands, so four overload it.
    def crowd_at_bank(banksman:)
      waiting = %i[crew_1 crew_2 crew_3 crew_4].to_h do |seat|
        [ seat, { via: nil, place: :bank, posting: :haulage, station: nil } ]
      end
      posts = { crew_5: { place: :bank, posting: :man_winding, station: :man_winding } }
      posts[:crew_6] = { place: :bank, posting: :banking, station: :banking } if banksman
      kibble = build_pit(id: "k", seed: 5, loadout: { winder: :steam_whim }, crew: PitRig::WOUND_CREW)
      shaft = kibble.nodes.fetch(:line_shaft)
      op = seed(kibble, nodes: { line_shaft: { angular_momentum: shaft.moment_of_inertia * 20.0 } },
                        minions: waiting.merge(posts))
      run!(op, 2)
      %i[crew_1 crew_2 crew_3 crew_4].select { |seat| op.state.dig(:minions, seat, :via) == :cage_drive }
    end

    it "lets on only what the cage is rated for while the banksman is at the landing" do
      expect(crowd_at_bank(banksman: true)).to eq(%i[crew_1 crew_2 crew_3])
    end

    it "lets everybody on with nobody at the landing" do
      expect(crowd_at_bank(banksman: false)).to eq(%i[crew_1 crew_2 crew_3 crew_4])
    end

    # **Winding on the bell.** A rider takes a few seconds to get in; a posted marshal rings the
    # engineman away only once they have, and winding away before then catches them.
    describe "the signals" do
      def getting_in(seats = [ :crew_1 ]) = aboard(:pit_bottom, seats).transform_values { |s| s.merge(boarding_s: 3.0) }

      def at_the_bottom(minions, marshal: nil, crew: PitRig::WOUND_CREW)
        posts = { crew_5: { place: :bank, posting: :man_winding, station: :man_winding } }
        posts[:crew_4] = { place: :pit_bottom, posting: :onsetting, station: :onsetting } if marshal
        op = build_pit(id: "s", seed: 5, loadout: { winder: :cage_gear }, crew: crew)
        shaft = op.nodes.fetch(:line_shaft)
        op = seed(op, nodes: { cage_drive: { position_m: 90.0 },
                               line_shaft: { angular_momentum: shaft.moment_of_inertia * 20.0 } },
                      minions: minions.merge(posts))
        op.set_control(:man_winding, 0.0)
        op
      end

      def caught(events) = events.select { |e| e[:type] == :minion_hurt && e[:cause] == :caught_boarding }

      it "holds the cage at a marshalled landing until the rider is in, then winds" do
        op = at_the_bottom(getting_in, marshal: true)
        run!(op, 6)
        held = position(op)
        events = run!(op, 14, from: 6)

        expect(held).to be_within(0.5).of(90.0)
        expect(position(op)).to be < 88.0
        expect(caught(events)).to be_empty
      end

      it "catches a rider still getting in when nobody is marshalling the landing" do
        op = at_the_bottom(getting_in)
        events = run!(op, 6)

        expect(caught(events).map { |e| e[:node] }).to eq([ :crew_1 ])
        expect(op.state.dig(:minions, :crew_1).values_at(:via, :place)).to eq([ nil, :pit_bottom ])
      end

      # **A false ready.** A rider who never finishes getting in, so the only way the cage leaves is
      # the marshal ringing it away anyway; a sound one never does, and a 1.0 bonehead slips about
      # every twenty ticks.
      it "is rung away by a marshal who slips, and never by one who does not" do
        dolt = PitRig::COLLIER.merge(label: "Dolt", tags: PitRig::COLLIER[:tags].merge(boneheaded: 1.0))
        content = PitRig::CONTENT.merging(archetypes: { dolt: dolt },
                                          minions: { dolt: { name: "Dolt", archetype: :dolt, hireable: false } })
        allow(ReactorSim::Content).to receive(:default).and_return(content)
        never_in = aboard(:pit_bottom, [ :crew_1 ]).transform_values { |s| s.merge(boarding_s: 1.0e6) }

        rung = [ PitRig::WOUND_CREW, PitRig::WOUND_CREW.merge(crew_4: { minion: :dolt }) ].map do |crew|
          caught(run!(at_the_bottom(never_in, marshal: true, crew: crew), 100)).any?
        end

        expect(rung).to eq([ false, true ])
      end
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
