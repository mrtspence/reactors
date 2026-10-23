# frozen_string_literal: true

require "reactor_sim"

# **The weather, the light, and what they do.** A match's sky is drawn once from the seed and read
# as a pure function of what was drawn and the clock, so it replays exactly; every claim here is a
# relationship rather than a figure, so retuning a climate moves nothing.
# See `docs/design_sketches/conditions.md`.
module ConditionsSpec
  # Just enough of a tick for the outdoors node to advance on its own.
  Ctx = Struct.new(:dt, :content, :tick)
end

RSpec.describe "conditions" do
  let(:content) { ReactorSim::Content.default }
  let(:conditions) { ReactorSim::Conditions }

  def drawn(seed, season: :winter, **given)
    setup = conditions.setup(season: season, **given)
    [ setup, conditions.draw(ReactorSim::Rng.stream(seed, "sky"), setup, content) ]
  end

  def run_outdoors(node, seconds, dt: 60.0)
    state = node.initial_state(ReactorSim::Rng.stream(3, "sky"), content)
    events = []
    (seconds / dt).to_i.times do |t|
      state, out = node.apply(state, ConditionsSpec::Ctx.new(dt, content, t + 1), nil)
      events.concat(out)
    end
    [ state, events ]
  end

  describe "the schedule" do
    it "draws the same sky from the same seed, and a different one from another" do
      setup, a = drawn(7)
      _, b = drawn(7)
      _, c = drawn(8)

      expect(conditions.read(setup, a, 1800.0, content)).to eq(conditions.read(setup, b, 1800.0, content))
      expect(conditions.read(setup, a, 1800.0, content)).not_to eq(conditions.read(setup, c, 1800.0, content))
    end

    it "gives every operation in a match the same sky" do
      match = ReactorSim::Match.create(id: "m", seed: 4, operations: [
        { id: "pit", type: :mine, conditions: { season: :winter } },
        { id: "engine", type: :steam_engine, conditions: { season: :winter } }
      ])
      skies = match.operations.map { |op| op.state.dig(:nodes, :outdoors).slice(*ReactorSim::Nodes::Outdoors::SKY) }

      expect(skies.uniq.size).to eq(1)
    end

    it "reads the standard sky for ever with no conditions" do
      node = ReactorSim::Nodes::Outdoors.new
      state, = run_outdoors(node, 3600.0)

      expect(state.slice(*conditions::STANDARD.keys)).to eq(conditions::STANDARD)
    end

    it "is warmer in summer than in winter, on the same seed and hour" do
      w_setup, w = drawn(5, season: :winter, start_hour: 12.0, severity: 1.0)
      s_setup, s = drawn(5, season: :summer, start_hour: 12.0, severity: 1.0)

      expect(conditions.read(s_setup, s, 0.0, content).fetch(:outdoor_k))
        .to be > conditions.read(w_setup, w, 0.0, content).fetch(:outdoor_k)
    end

    it "is dark at midnight and light at noon" do
      night_setup, night = drawn(5, start_hour: 0.0)
      noon_setup, noon = drawn(5, start_hour: 12.0)

      expect(conditions.read(night_setup, night, 0.0, content).fetch(:daylight))
        .to be < conditions.read(noon_setup, noon, 0.0, content).fetch(:daylight)
    end
  end

  describe "the outdoors node" do
    # Once per change of spell, and never on a tick that changed nothing.
    it "reports a change of weather on the transition, not every tick" do
      node = ReactorSim::Nodes::Outdoors.new(setup: { season: :autumn })
      state, events = run_outdoors(node, 3 * 3600.0)
      turns = events.count { |e| e[:type] == :weather_turned }

      expect(turns).to be < (3 * 3600.0 / 60.0)
      expect(state.fetch(:clock_s)).to be_within(1e-6).of(3 * 3600.0)
    end

    it "falls dark once across a winter dusk" do
      node = ReactorSim::Nodes::Outdoors.new(setup: { season: :winter, start_hour: 15.0 })
      _, events = run_outdoors(node, 2 * 3600.0)

      expect(events.count { |e| e[:type] == :nightfall }).to eq(1)
    end

    it "feels colder in a wind than the air is, and no different in a warm one" do
      cold = 268.0
      expect(ReactorSim::Nodes::Outdoors.feels_k(cold, 10.0)).to be < ReactorSim::Nodes::Outdoors.feels_k(cold, 1.0)
      expect(ReactorSim::Nodes::Outdoors.feels_k(295.0, 10.0)).to eq(295.0)
    end
  end

  describe "what reaches a node" do
    let(:pipe) { ReactorSim::Nodes::Conduit.new(id: :pipe, max_kg_per_s: 1.0) }

    def ctx(outdoor_k, exposure)
      ReactorSim::Tick::Context.new(outdoors: conditions::STANDARD.merge(outdoor_k: outdoor_k),
                                    exposure: { pipe: exposure })
    end

    it "cools an exposed node's ambient on a cold day, as far as it is exposed" do
      open = ctx(263.0, 1.0).ambient_k_of(pipe)
      sheltered = ctx(263.0, 0.3).ambient_k_of(pipe)

      expect(open).to be < sheltered
      expect(sheltered).to be < pipe.ambient_k
    end

    it "leaves every ambient exactly as declared under the standard sky" do
      expect(ctx(conditions::STANDARD_K, 1.0).ambient_k_of(pipe)).to eq(pipe.ambient_k)
    end
  end

  describe "rain" do
    it "drains what falls on a yard as water, booked as added" do
      yard = ReactorSim::Nodes::Catchment.new(id: :yard, area_m2: 1_000.0)
      state = yard.initial_state(ReactorSim::Rng.stream(1, "yard"), content)
      wet = ReactorSim::Tick::Context.new(dt: 1.0, content: content,
                                          outdoors: conditions::STANDARD.merge(runoff: 1.0e-3))
      after = yard.apply(state, wet, nil)

      expect(ReactorSim::Parcel.total_kg(after.fetch(:parcels))).to be > 0.0
      expect(after.fetch(:mass_injected)).to eq(ReactorSim::Parcel.total_kg(after.fetch(:parcels)))
    end
  end

  describe "what it does to people" do
    def hand(cold_resistance: 0.0)
      ReactorSim::Minion.new(id: :hand, mass_kg: 70.0, stats: { toughness: 1.0 },
                             tags: { cold_resistance: cold_resistance })
    end

    it "grinds somebody in bitter cold, costs nothing in mild air, and less in a greatcoat" do
      bitter = 245.0

      expect(ReactorSim::Chill.rate(285.0, hand)).to eq(0.0)
      expect(ReactorSim::Chill.rate(bitter, hand)).to be > 0.0
      expect(ReactorSim::Chill.rate(bitter, hand(cold_resistance: 0.5))).to be < ReactorSim::Chill.rate(bitter, hand)
    end

    it "makes work cost more in heat, and nothing more in comfort" do
      expect(ReactorSim::Chill.strain(305.0)).to be > ReactorSim::Chill.strain(298.0)
      expect(ReactorSim::Chill.strain(290.0)).to eq(1.0)
    end

    it "makes a slip likelier on a wet deck and far likelier on an icy one" do
      slip = ReactorSim::Peril.new(id: :slip, severity: 1.0, wounds: { impact: 1.0 }, causes: %i[fall],
                                   places: %i[deck], underfoot: { wet: 1.0, icy: 8.0 })

      expect(slip.footing({ wet: 1.0 })).to be > slip.footing({})
      expect(slip.footing({ icy: 1.0 })).to be > slip.footing({ wet: 1.0 })
    end
  end

  describe "the panel" do
    def pit(**loadout) = ReactorSim::Operations::Mine.build(id: :pit, seed: 1, loadout: loadout)

    it "carries the banksman's guesses, and the numbers only with an instrument fitted" do
      bare = pit.panel.fetch(:instruments).map { |i| i[:id] }
      fitted = pit(weather_instruments: :barometer).panel.fetch(:instruments).map { |i| i[:id] }

      expect(bare).to include(:how_it_feels, :the_knee)
      expect(bare).not_to include(:barometer)
      expect(fitted).to include(:barometer, :thermometer, :the_glass)
    end
  end

  it "conserves mass and energy under a hard winter" do
    match = ReactorSim::Match.create(id: "c", seed: 9, operations: [
      { id: "engine", type: :steam_engine, conditions: { season: :winter, severity: 1.6 } }
    ])
    op = match.operation(:engine)
    mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    40.times { match.step! }

    expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass0).abs / mass0.abs).to be < 1e-9
    expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules0).abs / joules0.abs).to be < 1e-9
  end
end
