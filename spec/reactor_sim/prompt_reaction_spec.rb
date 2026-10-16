# frozen_string_literal: true

require "reactor_sim"
require "support/conservation"
require "support/ignition_rig"

# **What happens faster than a tick is resolved, not integrated.** A flame alight in a mixture
# inside its range is a front, and on the next tick the front passes through the whole mixture:
# every kilogram of fuel burns, its products set by the mixture's own air, and a dust cloud in its
# range goes with it. On the sealed `IgnitionRig` district, so what comes out is the chemistry and
# nothing else. See `design_sketches/prompt-reactions.md`.
RSpec.describe "prompt reactions" do
  include IgnitionRig

  let(:content) { ReactorSim::Content.default }
  let(:firedamp) { content.reaction(:firedamp_combustion) }

  def fired(fraction, spark: 4.0e-4, coal_dust: 0.0, ticks: 2)
    op = rig(firedamp: fraction, coal_dust: coal_dust, igniter_kg_per_s: spark)
    events = light!(op, ticks: ticks)
    { op: op, explosions: events.select { |e| e[:type] == :explosion } }
  end

  def all_held(op)
    %i[firedamp air flue_gas whitedamp coal_dust].to_h { |r| [ r, held(op, r) ] }
  end

  it "goes off on the tick after a flame is laid in a mixture inside its range" do
    expect(fired(0.09, ticks: 1).fetch(:explosions)).to be_empty

    boom = fired(0.09).fetch(:explosions)
    expect(boom.size).to eq(1)
    expect(boom.first).to include(tick: 2, node: :district, severity: :critical)
    expect(boom.first.dig(:detail, :reactions)).to eq(%i[firedamp_combustion])
  end

  it "does not go off below the lean limit, however long the flame is held there" do
    expect(fired(0.04, ticks: 40).fetch(:explosions)).to be_empty
  end

  # **The reason the concern exists.** Integrated at its rate, the same ignition made three times
  # the carbon monoxide from a different spark, because the spark only moved where the burn fell on
  # the tick grid.
  it "makes the same products whatever spark lit it" do
    candle = all_held(fired(0.12, spark: 4.0e-4).fetch(:op))
    flame_cap = all_held(fired(0.12, spark: 1.0e-6).fetch(:op))

    candle.each { |resource, kg| expect(flame_cap.fetch(resource)).to be_within(1e-3).of(kg), resource.to_s }
  end

  describe "products by the mixture's own air" do
    def clean_air = firedamp.dig(:consumes, :air)

    def rich_air = firedamp.dig(:alternatives, 0, :consumes, :air)

    def co_per_kg = firedamp.dig(:alternatives, 0, :produces, :whitedamp)

    it "burns a lean mixture clean, with air to spare" do
      op = fired(0.06).fetch(:op)

      expect(held(op, :firedamp)).to be < 1e-6
      expect(held(op, :whitedamp)).to eq(0.0)
      expect(held(op, :air)).to be > 0.0
    end

    # The split that spends the air exactly: `x·a₁ + (E − x)·a₂ = A`.
    it "burns a rich one to carbon monoxide in proportion to how rich it is" do
      before = rig(firedamp: 0.12)
      fuel = held(before, :firedamp)
      air = held(before, :air)
      clean = (air - (fuel * rich_air)) / (clean_air - rich_air)
      op = fired(0.12).fetch(:op)

      expect(held(op, :firedamp)).to be < 1e-6
      expect(held(op, :air)).to be < 1e-6
      expect(held(op, :whitedamp)).to be_within(0.01 * fuel).of(co_per_kg * (fuel - clean))
    end

    it "leaves fuel unburnt where even the rich pathway cannot afford it all" do
      before = rig(firedamp: 0.14)
      op = fired(0.14).fetch(:op)

      expect(held(op, :air)).to be < 1e-6
      expect(held(op, :firedamp)).to be_within(0.01).of(held(before, :firedamp) - (held(before, :air) / rich_air))
    end
  end

  describe "in sequence" do
    it "takes a dust cloud in its range with the gas front, on the air the gas left" do
      boom = fired(0.09, coal_dust: 200.0).fetch(:explosions)

      expect(boom.size).to eq(1)
      expect(boom.first.dig(:detail, :reactions)).to eq(%i[firedamp_combustion coal_dust_combustion])
    end

    # The candle still burns the few grains it lights, one for one.
    it "does not take dust too thin to carry a flame" do
      shot = fired(0.09, coal_dust: 0.01)

      expect(shot.fetch(:explosions).first.dig(:detail, :reactions)).to eq(%i[firedamp_combustion])
      expect(held(shot.fetch(:op), :coal_dust)).to be > 0.009
    end

    it "does nothing to a dust cloud with no flame near it" do
      op = rig(coal_dust: 200.0)
      events = 4.times.flat_map { |i| op.step!(tick: i + 1) }

      expect(events.map { |e| e[:type] }).not_to include(:explosion)
      expect(held(op, :coal_dust)).to eq(200.0)
    end
  end

  it "conserves mass and energy through a resolution" do
    op = rig(firedamp: 0.12, coal_dust: 50.0)
    mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    light!(op, ticks: 4)

    mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    expect((mass - mass0).abs / mass0.abs).to be < Conservation::TOLERANCE
    expect((joules - joules0).abs / joules0.abs).to be < Conservation::TOLERANCE
  end

  it "leaves a node hosting no prompt reaction exactly as it was" do
    vessel = ReactorSim::Nodes::Vessel.new(id: :bed, volume_m3: 1.0, heat_capacity: 1.0e3,
                                           initial_contents: [ { resource: :coal, kg: 5.0 } ],
                                           reactions: %i[coal_combustion])
    state = vessel.initial_state(ReactorSim::Rng.stream(1, :bed), content)
    ctx = ReactorSim::Tick::Context.new(content: content, dt: 0.25, tick: 1)

    expect(vessel.resolve_prompt(state, ctx)).to eq([ state, [], [] ])
  end

  describe "its content" do
    def registry(prompt:, ignition: {})
      ReactorSim::Content.build(
        resources: { gas: { tags: %i[gas fuel], specific_heat_j_per_kg_k: 1, density_kg_per_m3: 1,
                            molar_mass_g_per_mol: 16 },
                     smoke: { tags: %i[gas], specific_heat_j_per_kg_k: 1, density_kg_per_m3: 1,
                              molar_mass_g_per_mol: 30 } },
        reactions: { burn: { consumes: { gas: 1.0 }, produces: { smoke: 1.0 }, rate_per_s: 1.0,
                             enthalpy_j_per_unit: -1.0, ignition: ignition, prompt: prompt } }
      )
    end

    it "refuses a kind nobody resolves" do
      expect { registry(prompt: { kind: :detonation }, ignition: { lean_fraction: 0.05 }) }
        .to raise_error(ReactorSim::Error, /burn: unknown prompt kind :detonation/)
    end

    it "refuses a deflagration with no flammable range to run through" do
      expect { registry(prompt: { kind: :deflagration }, ignition: { spread_per_s: 1.0 }) }
        .to raise_error(ReactorSim::Error, /burn: a deflagration needs an ignition block with a flammable range/)
    end
  end
end
