# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"
require "support/pit_rig"

# **Belt conveyors, and the intake fire.** A belt carries with nobody on the road; fed past what its
# drum grips it stalls, and the drum turns on under it. The drum lights the spillage packed round the
# drive head, and the burning spillage lights the belt. The belt road is an intake, so the smoke goes
# inbye to the face. Fire-resistant belting does not carry the fire. See
# `design_sketches/mine-accidents-unit4.md` §5 and §5a.
RSpec.describe "belt conveyors" do
  include Constructed
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  def pit(haulage = :belt_conveyor) = build_pit(id: "c", seed: 5, loadout: { haulage: haulage })

  def turning(op)
    shaft = op.nodes.fetch(:line_shaft)
    { line_shaft: { angular_momentum: shaft.moment_of_inertia * shaft.rated_omega } }
  end

  # Coal waiting at the loading point, the shaft turning, and nobody posted anywhere.
  def loaded(op, feed:, nodes: {})
    coal = { district: district_mix(op).merge(parcels: parcels_at(293.15, air: 1_700.0, coal: 3_000.0)) }
    belt = seed(op, nodes: coal.merge(turning(op)).merge(nodes))
    levers!(belt, haulage: feed)
    belt
  end

  def drum_k(op) = op.nodes.fetch(:belt_drive).temperature_k(op.state.dig(:nodes, :belt_drive), op.content)

  def carried(op) = op.state.dig(:nodes, :tub_road, :carried_kg)

  it "carries with nobody on the road" do
    op = loaded(pit, feed: 70)
    run!(op, 4)

    expect(op.state.fetch(:minions).values.map { |m| m[:station] }).not_to include(:haulage)
    expect(carried(op)).to be > 0.0
  end

  it "stalls fed past its grip, and its drum heats, where a feed it can pull does not" do
    stalled = loaded(pit, feed: 100)
    sound = loaded(pit, feed: 70)
    [ stalled, sound ].each { |op| run!(op, 20) }

    expect(carried(stalled)).to eq(0.0)
    expect(drum_k(stalled)).to be > drum_k(sound) + 3.0
    expect(carried(sound)).to be > 0.0
  end

  it "loses its grip to a wet pit bottom" do
    op = loaded(pit, feed: 70)
    belt = op.nodes.fetch(:tub_road)
    states = op.state.fetch(:nodes)
    flooded = states.merge(pit_bottom: bottom_mix(op).merge(
      parcels: parcels_at(293.15, air: PitRig::BOTTOM_AIR_KG, water: ReactorSim::Operations::Mine::Sump::FLOOD_KG)
    ))
    ctx = ->(nodes) {
      ReactorSim::Tick::Context.new(controls: { haulage: 70.0 }, dt: ReactorSim::DT, tick: 1, content: op.content,
                                    nodes: op.nodes, states: nodes)
    }

    expect(belt.stalled?(ctx.(states))).to be(false)
    expect(belt.stalled?(ctx.(flooded))).to be(true)
  end

  def deposit(op) = held(op, :drive_head, :coal)

  def with_deposit(op, coal_kg, temperature_k: 293.15) = { drive_head: body(op, :drive_head, temperature_k, air: 24.5, coal: coal_kg) }

  describe "the spillage at the drive head" do
    it "builds while the belt runs" do
      op = loaded(pit, feed: 70)
      run!(op, 20)

      expect(deposit(op)).to be > 0.0
    end

    it "is shovelled back onto the coal by the belt attendant" do
      attendant = { crew_1: { place: :pit_bottom, posting: :belt_attending, station: :belt_attending } }
      attended = seed(pit, nodes: with_deposit(pit, 5.0), minions: attendant)
      left = seed(pit, nodes: with_deposit(pit, 5.0))
      [ attended, left ].each { |op| run!(op, 20) }

      expect(deposit(attended)).to be < deposit(left) - 0.5
    end
  end

  # A drum past the deposit's 483 K and short of rubber belting's own 672.
  describe "a stalled drum" do
    def warm_drum(op) = wall(op, :belt_drive, 500.0)

    it "lights the spillage packed round it, as an incident" do
      op = seed(pit, nodes: warm_drum(pit).merge(with_deposit(pit, 20.0)))
      events = run!(op, 3)

      expect(events).to include(a_hash_including(type: :fire_lit, node: :drive_head, severity: :critical))
    end

    it "lights nothing at a clean drive head" do
      op = seed(pit, nodes: warm_drum(pit))
      events = run!(op, 3)

      expect(events.map { |e| e[:type] }).not_to include(:fire_lit)
    end
  end

  # A drive head hot from its burning deposit, past both belts' ignition points.
  describe "a burning drive head" do
    def burning_head(haulage)
      op = pit(haulage)
      seed(op, nodes: with_deposit(op, 0.0, temperature_k: 800.0))
    end

    def lit_kg(op, reaction) = op.state.dig(:nodes, :belt_road, :ignition, reaction, :kg)

    it "lights the belt lying over it, as an incident" do
      events = run!(burning_head(:belt_conveyor), 3)

      expect(events).to include(a_hash_including(type: :fire_lit, node: :belt_road, severity: :critical))
    end

    # Lit where it lies, PVC goes out: it cannot carry the fire along itself.
    it "lights a rubber belt to a spreading fire, and a fire-resistant one to no more than where it touches" do
      rubber = burning_head(:belt_conveyor)
      pvc = burning_head(:fire_resistant_conveyor)
      [ rubber, pvc ].each { |op| run!(op, 20) }

      expect(lit_kg(rubber, :belt_combustion)).to be > 3.0 * lit_kg(pvc, :fire_resistant_belt_combustion)
    end
  end

  # Burning at about its air limit, with the fan drawing the intake past it, against the same road
  # unlit.
  it "sends a belt fire's smoke inbye to the district" do
    burning = { belt_road: { ignition: { belt_combustion: { kg: 0.4, oxidiser_kg: 1.0 } } } }
    lit = seed(pit, nodes: turning(pit).merge(burning).merge(with_deposit(pit, 0.0, temperature_k: 800.0)))
    dark = seed(pit, nodes: turning(pit))
    [ lit, dark ].each { |op| run!(op, 20) }

    expect(held(lit, :district, :flue_gas)).to be > held(dark, :district, :flue_gas) + 0.2
  end
end
