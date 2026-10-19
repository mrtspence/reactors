# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"
require "support/pit_rig"

# **The waste behind the face, and a gob fire.** A match inherits what the last workings left — often
# nothing, otherwise a zone of coal already part-way to firing. Air leaking through it is taken up by
# the coal, which warms; past coal's ignition point it lights of itself, smoulders to carbon monoxide,
# breaks out at the face and fires the district's gas. Sealing starves it. See
# `design_sketches/mine-accidents-unit3b.md` §7 and decisions 17–18.
RSpec.describe "the waste" do
  include Constructed
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  let(:gob_class) { ReactorSim::Operations::Mine::Gob }
  let(:content) { PitRig::CONTENT }

  def pit = build_pit(id: "w", seed: 3)

  def waste(op) = op.state.dig(:nodes, :gob)

  def temperature(op) = op.nodes.fetch(:gob).temperature_k(waste(op), op.content)

  def fire_k(reaction = :coal_combustion) = content.reaction(reaction).dig(:ignition, :autoignition_k)

  # The waste at `kelvin`, holding `coal_kg` of heating coal and `air_kg`.
  def waste_at(op, kelvin: PitRig::AMBIENT_K, coal_kg: 3_000.0, air_kg: 360.0, **state)
    seed(op, nodes: { gob: body(op, :gob, kelvin, coal: coal_kg, air: air_kg).merge(state) })
  end

  describe "what the last workings left" do
    def draws(count = 2_000)
      node = pit.nodes.fetch(:gob)
      (1..count).map { |seed| node.left_behind(ReactorSim::Rng.stream(seed, :gob), content) }
    end

    it "is nothing heating in about a quarter of pits" do
      none = draws.count { |w| w.fetch(:coal_kg).zero? }

      expect(none / 2_000.0).to be_within(0.04).of(gob_class::NONE_SHARE)
    end

    # The start temperature is what brings the zone to coal's ignition point in the drawn time, by
    # Newton's law of cooling against the design heat — so inverting it gives the drawn time back.
    it "starts the waste at the temperature that fires it when the draw says" do
      node = pit.nodes.fetch(:gob)
      capacity = node.heat_capacity + (3_000.0 * 1_260.0)
      settles = node.ambient_k + (gob_class::DESIGN_HEAT_W / node.ambient_conductance)
      start = node.start_k(3_600.0, capacity, content)
      fires_in = -(capacity / node.ambient_conductance) * Math.log((fire_k - settles) / (start - settles))

      expect(fires_in).to be_within(1.0).of(3_600.0)
    end

    it "is a waste already part-way to firing where there is one, and never past it" do
      starts = draws(400).reject { |w| w.fetch(:coal_kg).zero? }.map { |w| w.fetch(:temperature_k) }

      expect(starts.min).to be >= PitRig::AMBIENT_K
      expect(starts.max).to be < fire_k
      expect(starts.sort[starts.size / 2]).to be > 500.0
    end

    it "inherits nothing heating for a spec that pins the ground" do
      expect(held(pit, :gob, :coal)).to eq(0.0)
    end
  end

  it "warms where there is air for the coal to take up, and not where it is starved of it" do
    breathing = waste_at(pit, sealed: 1.0)
    starved = waste_at(pit, air_kg: 1.0, sealed: 1.0)
    before = temperature(breathing)
    [ breathing, starved ].each { |op| run!(op, 20) }

    expect(temperature(breathing) - before).to be > 0.1
    expect(temperature(starved) - before).to be < (temperature(breathing) - before) / 50.0
    expect(held(breathing, :gob, :blackdamp)).to be > 0.0
  end

  it "takes a trickle of air off the intake, which sealing shuts off" do
    open = waste_at(pit)
    sealed = waste_at(pit, sealed: 1.0)
    [ open, sealed ].each { |op| run!(op, 20) }

    expect(open.state.dig(:nodes, :waste_in, :carried_kg)).to be > 0.0
    expect(sealed.state.dig(:nodes, :waste_in, :carried_kg))
      .to be < open.state.dig(:nodes, :waste_in, :carried_kg) / 1_000.0
  end

  it "is sealed by somebody building stoppings" do
    op = seed(pit, minions: { crew_1: { posting: :sealing, station: :sealing, place: :district } })
    run!(op, 20)

    expect(waste(op).fetch(:sealed)).to be_positive
  end

  it "lights of itself past coal's ignition point, and not below it" do
    hot = waste_at(pit, kelvin: fire_k + 10.0)
    warm = waste_at(pit, kelvin: fire_k - 50.0)
    [ hot, warm ].each { |op| run!(op, 4) }

    expect(waste(hot).dig(:ignition, :coal_combustion, :kg)).to be > 0.0
    expect(waste(warm).dig(:ignition, :coal_combustion, :kg).to_f).to eq(0.0)
  end

  # **Short of air, it smoulders to carbon monoxide**, and the leak carries it to the face. An
  # established fire — five kilograms alight — in a waste with little air left in it.
  it "makes whitedamp alight and starved of air" do
    op = waste_at(pit, kelvin: fire_k + 10.0, air_kg: 10.0,
                       ignition: { coal_combustion: { kg: 5.0, oxidiser_kg: 0.0 } })
    run!(op, 4)

    expect(held(op, :gob, :whitedamp) + held(op, :district, :whitedamp)).to be > 0.0
  end

  it "breaks out at the face past its rating, hurting whoever is there" do
    op = waste_at(pit, kelvin: 1_010.0)
    op = seed(op, minions: { crew_1: { place: :district, posting: nil, station: nil, progress: 0.0,
                                       remaining: 0.0, journey: 0.0 } })
    events = run!(op, 4)

    expect(events.find { |e| e[:type] == :part_failed && e[:node] == :gob }).to include(mode: :rupture)
    expect(events.map { |e| e[:type] }).to include(:minion_hurt)
  end

  # **The gob-fire explosion**: a waste past firedamp's ignition point fires gas at the face with no
  # flame near it, where a cool one leaves the same gas alone.
  it "fires the district's gas when it is hot enough, and not when it is not" do
    gassy = ->(kelvin) { waste_at(seed(pit, nodes: { district: district_mix(pit, firedamp: gas_kg(8.0)) }), kelvin: kelvin) }
    hot = gassy.(fire_k(:firedamp_combustion) + 30.0)
    cool = gassy.(fire_k + 10.0)
    [ hot, cool ].each { |op| levers!(op, naked_flame: 0) }
    hot_events = run!(hot, 6)
    cool_events = run!(cool, 6)

    expect(hot_events.select { |e| e[:node] == :district }.map { |e| e[:type] }).to include(:fire_lit)
    expect(cool_events.select { |e| e[:node] == :district }.map { |e| e[:type] }).not_to include(:fire_lit)
  end

  it "smells of fire to the timberman as it heats" do
    op = waste_at(at_the_face(pit), kelvin: 450.0)
    run!(op, 12)

    expect(op.project(viewer: :player).to_h.dig(:gauges, :fire_stink)).to eq("fire stink")
  end
end
