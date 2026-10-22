# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"
require "support/pit_rig"

# **Rope haulage, and runaway sets.** A haulage engine off the line shaft draws sets on a rope at
# four times a putter's rate; the road rises from the pit bottom to the district, so a set the rope
# lets go runs back down to the shaft. What it does to somebody is where on the road they are — the
# district end little, the trapper near the foot much, everybody at the pit bottom most — and those
# working the road are somewhere along it. See `design_sketches/mine-accidents-unit4.md` §4 and §9.3.
RSpec.describe "rope haulage" do
  include Constructed
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  let(:rope_class) { ReactorSim::Operations::Mine::HaulageRope }

  def pit(haulage = :rope_haulage) = build_pit(id: "r", seed: 5, loadout: { haulage: haulage })

  def rope(op) = op.state.dig(:nodes, :haulage_rope)

  def coal_in_district(op) = { district: district_mix(op).merge(parcels: parcels_at(293.15, air: 1_700.0, coal: 3_000.0)) }

  # The line shaft at its working speed, so a driven haulage is hauling from the first tick.
  def turning(op)
    shaft = op.nodes.fetch(:line_shaft)
    { line_shaft: { angular_momentum: shaft.moment_of_inertia * shaft.rated_omega } }
  end

  # A road being hauled: coal at the face, the shaft turning, a hand on the road.
  def working(op, nodes: {}, minions: {})
    worked = seed(op, nodes: coal_in_district(op).merge(turning(op)).merge(nodes), minions: hauler.merge(minions))
    levers!(worked, haulage: 100)
    worked
  end

  def hauler = { crew_1: { place: :pit_bottom, posting: :haulage, station: :haulage } }

  def ctx_for(op)
    ReactorSim::Tick::Context.new(controls: {}, dt: ReactorSim::DT, tick: 1, content: op.content,
                                  nodes: op.nodes, states: op.state.fetch(:nodes))
  end

  it "draws a set's weight down the incline" do
    tension = rope_class::SET_KG * ReactorSim::Units::GRAVITY_M_PER_S2 *
              ((ReactorSim::Operations::Mine::ROAD_RISE_M / ReactorSim::Operations::Mine::ROAD_M) +
               rope_class::ROLLING)

    expect(rope_class.tension_n).to be_within(1e-9).of(tension)
  end

  it "carries several times what putting does, and nothing with the shaft stopped" do
    hauled = working(pit)
    put = working(pit(:hand_putting))
    stopped = working(pit, nodes: { line_shaft: { angular_momentum: 0.0 } })
    [ hauled, put ].each { |op| run!(op, 4) }
    run!(stopped, 4, supply: 0.0)

    carried = ->(op) { op.state.dig(:nodes, :tub_road, :carried_kg) }
    expect(carried.(hauled)).to be > 2.0 * carried.(put)
    expect(carried.(stopped)).to be < carried.(hauled) * 0.1
  end

  it "parts a worn rope when a set is started, where a sound one holds" do
    node = pit.nodes.fetch(:haulage_rope)
    hauling = rope(pit).merge(traffic: 0.5)

    expect(node.overload?(hauling, nil, 0.2)).to be(true)
    expect(node.overload?(hauling, nil, 1.0)).to be(false)
    expect(node.overload?(hauling.merge(traffic: 0.0), nil, 0.2)).to be(false)
  end

  it "breaks away when a set is coupled without its backstay" do
    op = pit
    node = op.nodes.fetch(:haulage_rope)
    broken, = node.suffer(rope(op), { kind: :breakaway }, ctx_for(op))

    expect(broken.fetch(:failure)).to be(:parted)
  end

  describe "a runaway" do
    # A rope at the edge of parting under a working road, and people placed along it. It parts on
    # the second tick: the first hauls, and the rope reads the traffic a tick behind.
    def runaway(minions)
      op = pit
      working(op, nodes: { haulage_rope: { durability: 1.0 } }, minions: minions)
    end

    def resilience_lost(before, after, id) = before.dig(:minions, id, :resilience) - after.dig(:minions, id, :resilience)

    it "hits the pit bottom far harder than the district end" do
      op = runaway(crew_2: { place: :pit_bottom, posting: :onsetting, station: :onsetting },
                   crew_3: { place: :district, posting: nil, station: nil })
      before = op.state
      events = run!(op, 3)

      expect(events.map { |e| [ e[:type], e[:node] ] }).to include([ :part_failed, :haulage_rope ])
      expect(resilience_lost(before, op.state, :crew_2)).to be > 3.0 * resilience_lost(before, op.state, :crew_3)
    end

    it "wrecks the haulage door and stops the haulage until it is spliced" do
      op = runaway({})
      run!(op, 3)

      expect(op.state.dig(:nodes, :door, :failure)).not_to be_nil
      expect(op.nodes.fetch(:tub_road).throughput_kg(op.state.dig(:nodes, :tub_road), ctx_for(op))).to eq(0.0)
    end

    it "is spliced by the hauling hands" do
      op = seed(pit, nodes: { haulage_rope: { failure: :parted, durability: 0.0, splicing: 0.9999 } }, minions: hauler)
      levers!(op, haulage: 100)
      run!(op, 2)

      expect(rope(op).fetch(:failure)).to be_nil
      expect(rope(op).fetch(:durability)).to eq(rope(op).fetch(:initial_durability))
    end
  end

  # A catch near the top of the incline stops most runaways before they gather speed.
  describe "a runaway catch" do
    def runaway_past(catch, minions = {})
      op = build_pit(id: "r", seed: 5, loadout: { haulage: :rope_haulage, runaway_catch: catch })
      working(op, nodes: { haulage_rope: { durability: 1.0 } }, minions: minions)
    end

    def onsetter = { crew_2: { place: :pit_bottom, posting: :onsetting, station: :onsetting } }

    def lost(op)
      before = op.state.dig(:minions, :crew_2, :resilience)
      run!(op, 3)
      before - op.state.dig(:minions, :crew_2, :resilience)
    end

    it "spares the pit bottom most of the same runaway" do
      expect(lost(runaway_past(:catch_points, onsetter))).to be < 0.5 * lost(runaway_past(nil, onsetter))
    end

    it "keeps a caught set off the haulage door" do
      op = runaway_past(:drags)
      run!(op, 3)

      expect(rope(op).fetch(:failure)).to be(:parted)
      expect(op.state.dig(:nodes, :door, :failure)).to be_nil
    end

    it "cuts the share below it and leaves the one above it" do
      op = pit
      tick = ReactorSim::Tick.new(op, op.state)
      run = ReactorSim::Operations::Mine::RUNAWAY.fetch(:along).merge(catch: { at: 0.15, holds: 0.8 })

      expect(tick.send(:past_the_catch, run, 1.0)).to be_within(1e-9).of(0.2)
      expect(tick.send(:past_the_catch, run, 0.1)).to eq(0.1)
    end
  end

  # Where on the run somebody is, at zero ticks, through the tick's own reading of it.
  describe "where on the road" do
    let(:run) { ReactorSim::Operations::Mine::RUNAWAY.fetch(:along) }

    def share_of(minion_state)
      op = pit
      tick = ReactorSim::Tick.new(op, op.state)
      tick.send(:run_share, run, op.minions.fetch(:crew_1), op.state.dig(:minions, :crew_1).merge(minion_state))
    end

    it "is everybody at the foot, little at the top, and the trapper near the foot" do
      expect(share_of(place: :pit_bottom, station: nil)).to eq([ 1.0, false ])
      expect(share_of(place: :district, station: nil)).to eq([ run.fetch(:top_share), false ])
      expect(share_of(place: :pit_bottom, station: :trapping)).to eq([ 0.9, false ])
    end

    it "puts the hands working the road somewhere along it" do
      share, on_road = share_of(place: :pit_bottom, station: :haulage)

      expect(on_road).to be(true)
      expect(share).to be_between(0.0, 1.0)
    end

    it "is nobody away from the road" do
      expect(share_of(place: :bank, station: nil)).to be_nil
    end

    # The worst of it: pinned by a fast set, which is heavier than being struck and named for itself.
    it "crushes somebody caught well down the road, heavier than a blow and named for it" do
      op = pit
      tick = ReactorSim::Tick.new(op, op.state)
      declared = ReactorSim::Operations::Mine::RUNAWAY
      struck = tick.send(:run_hit, run, declared, 0.8, false, :haulage_rope)
      crushed = tick.send(:run_hit, run, declared, 0.8, true, :haulage_rope)

      expect(crushed.fetch(:severity)).to eq(struck.fetch(:severity) * run.dig(:crushed, :factor))
      expect(crushed).to include(cause: :crushed_by_runaway)
      expect(crushed.fetch(:tags)).to include(:crush)
    end

    it "catches somebody far oftener the further down the road they are" do
      op = pit
      tick = ReactorSim::Tick.new(op, op.state)
      tick.instance_variable_set(:@fates, { crew_1: { caught: 0.2 } })
      hand = op.minions.fetch(:crew_1)
      state = op.state.dig(:minions, :crew_1)

      expect(tick.send(:caught?, run, hand, state, 0.9)).to be(true)
      expect(tick.send(:caught?, run, hand, state, 0.3)).to be(false)
    end

    # Seeing it coming and getting clear: the same hand, slowed, is caught where they were not.
    it "catches somebody who cannot get out of the way oftener than somebody who can" do
      op = pit
      tick = ReactorSim::Tick.new(op, op.state)
      tick.instance_variable_set(:@fates, { crew_1: { caught: 0.2 } })
      hand = op.minions.fetch(:crew_1)
      state = op.state.dig(:minions, :crew_1)
      share = (1..9).map { |n| n / 10.0 }.reject { |s| tick.send(:caught?, run, hand, state, s) }.max or
        raise "the hand is caught everywhere on the road"

      expect(tick.send(:caught?, run, hand, state.merge(fatigue: 0.9), share)).to be(true)
    end
  end
end
