# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"
require "support/pit_rig"

# **Water sprays on the cutter.** Fed from the sump, they wet the picks so that the sparks they strike
# cannot fire gas, and lay most of the dust; a sump pumped bare stops them. See
# `design_sketches/mine-accidents-unit4.md` §6.
RSpec.describe "cutter sprays" do
  include Constructed
  include PitRig

  AMBIENT_K = PitRig::AMBIENT_K
  BOTTOM_AIR_KG = PitRig::BOTTOM_AIR_KG

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  # A safe light, so the only thing in the district that could fire it is the cutter.
  def pit(sprays: :water_sprays)
    build_pit(id: "s", seed: 5, loadout: { cutting: :coal_cutter, lighting: :electric_lamps, cutter_sprays: sprays })
  end

  def turning(op)
    shaft = op.nodes.fetch(:line_shaft)
    { line_shaft: { angular_momentum: shaft.moment_of_inertia * shaft.rated_omega } }
  end

  def rated_spray_kg = ReactorSim::Operations::Mine::SPRAY_KG_PER_S * ReactorSim::DT

  def ctx_for(op, states, controls)
    ReactorSim::Tick::Context.new(controls: controls, dt: ReactorSim::DT, tick: 1, content: op.content,
                                  nodes: op.nodes, states: states)
  end

  it "lay most of the cutter's dust" do
    op = pit
    states = op.state.fetch(:nodes)
    wet = states.merge(spray_line: states.fetch(:spray_line).merge(carried_kg: rated_spray_kg))
    line = op.nodes.fetch(:dust_line)
    made = ->(nodes) { line.throughput_kg(nodes.fetch(:dust_line), ctx_for(op, nodes, { hewing: 100.0 })) }

    expect(made.(wet)).to be_within(1e-9).of(made.(states) * (1.0 - ReactorSim::Operations::Mine::DustLine::LAID_WET))
  end

  # A sump with a foot of water in it, against one pumped bare.
  def sump(op, water_kg) = { pit_bottom: bottom_mix(op).merge(parcels: parcels_at(AMBIENT_K, air: BOTTOM_AIR_KG, water: water_kg)) }

  def wetting(op) = op.nodes.fetch(:spray_line).wetting(op.state.dig(:nodes, :spray_line), ReactorSim::DT)

  # The seepage still trickles into a sump pumped bare, and a trickle does not wet the face.
  it "wet the face from the sump, and not from one pumped bare" do
    running = seed(pit, nodes: turning(pit).merge(sump(pit, 800.0)))
    dry = seed(pit, nodes: turning(pit).merge(sump(pit, 0.0)))
    [ running, dry ].each { |op| run!(op, 4) }

    expect(wetting(running)).to eq(1.0)
    expect(wetting(dry)).to be < 0.5
  end

  # Gas in the band and a hewer cutting, the sprays already running where they are fitted.
  describe "a cutter in firedamp" do
    def cutting_in_gas(sprays)
      op = seed(pit(sprays: sprays), nodes: turning(pit(sprays: sprays)).merge(sump(pit(sprays: sprays), 800.0)))
      run!(op, 2)
      cutter = seed(op, nodes: { district: district_mix(op, firedamp: gas_kg(4.0)) },
                        minions: at_the_face_minions(op, haulage: nil, timbering: nil))
      levers!(cutter, hewing: 100)
      cutter
    end

    def exploded?(events) = events.any? { |e| e[:type] == :explosion }

    it "fires it with no sprays, and not while they wet the face" do
      expect(exploded?(run!(cutting_in_gas(nil), 6))).to be(true)
      expect(exploded?(run!(cutting_in_gas(:water_sprays), 6))).to be(false)
    end
  end
end
