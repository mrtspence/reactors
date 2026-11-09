# frozen_string_literal: true

require "support/open_pit_rig"
require "support/conservation"

# **Light for night work**: `Nodes::Lighting`, the colliery's sconces lifted into the library, and
# the open pit's two areas lit by fire baskets, Wells lights or arc lamps; and darkness underfoot.
# Zero ticks for the arithmetic, a few from a constructed night for the rest. Relational — no
# figure here is a tuning target.
RSpec.describe ReactorSim::Nodes::Lighting do
  before { allow(ReactorSim::Content).to receive(:default).and_return(OpenPitRig::CONTENT) }

  def night = { season: :summer, start_hour: 1.0 }
  def noon = { season: :summer, start_hour: 12.0 }

  def pit(loadout = {}, conditions: night) = OpenPitRig.build(id: :pit, seed: 1, loadout: loadout, conditions: conditions)
  def tick(op, ticks = 1) = OpenPitRig.tick(op, ticks)
  def state(op, id) = OpenPitRig.node_state(op, id)
  def board(op) = described_class::SIGNALS.keys.fetch(state(op, :pit_lights).fetch(:signal))
  def lit(op) = state(op, :pit_lights).fetch(:lit)

  # The ore gang at their face, a night's lights on or off.
  def at_the_face(loadout = {}, lamps: 100.0, conditions: night, posts: {})
    op = OpenPitRig.posted(pit(loadout, conditions: conditions), ore_getters: %i[crew_1 crew_2], **posts)
    op.set_control(:pit_lights_lamps, lamps)
    op
  end

  def got(op) = state(op, :ore_getting).fetch(:carried_kg)

  # The baskets burning well, as after an hour lit: their coal alight at their working heat.
  def burning(op)
    bed = op.nodes.fetch(:pit_lights_baskets)
    OpenPitRig.seed(op, nodes: {
                      pit_lights_baskets: { parcels: OpenPitRig.parcels_at(700.0, coal: 17.0, air: 0.4),
                                            joules: bed.heat_capacity * 700.0,
                                            ignition: { coal_combustion: { kg: 17.0, oxidiser_kg: 0.0 } } },
                      pit_lights: { fire_share: 1.0 }
                    })
  end

  describe "a light, as arithmetic" do
    let(:lamp) do
      described_class.new(id: :lamp, illumination: 0.8, control_id: :lamp_lever, max_torque: 0.0, rated_omega: 0.0,
                          curve: :viscous)
    end
    let(:dynamo) do
      described_class.new(id: :lamp, illumination: 1.0, control_id: :lamp_lever, max_torque: 10.0, rated_omega: 20.0,
                          curve: :viscous, moment_of_inertia: 1.0)
    end

    it "gives its light by its lever, and none turned off" do
      expect(lamp.lit({}, { lamp_lever: 100.0 })).to be > lamp.lit({}, { lamp_lever: 50.0 })
      expect(lamp.lit({}, { lamp_lever: 0.0 })).to eq(0.0)
    end

    it "gives a dynamo's light by its shaft's speed, and none with the shaft stopped" do
      turning = dynamo.lit({ angular_momentum: 20.0 }, { lamp_lever: 100.0 })
      slow = dynamo.lit({ angular_momentum: 10.0 }, { lamp_lever: 100.0 })

      expect(turning).to be > slow
      expect(dynamo.lit({ angular_momentum: 0.0 }, { lamp_lever: 100.0 })).to eq(0.0)
    end

    it "is dark with its carbons spent through" do
      arcs = described_class.new(id: :lamp, illumination: 1.0, control_id: :lamp_lever, max_torque: 0.0, rated_omega: 0.0,
                                 curve: :viscous, burns_s: 100.0)

      expect(arcs.lit({ spent: 0.5 }, { lamp_lever: 100.0 })).to be_positive
      expect(arcs.lit({ spent: 1.0 }, { lamp_lever: 100.0 })).to eq(0.0)
    end
  end

  describe "the colliery's lights, lifted" do
    it "is the same node, its tiers configured onto it" do
      mine = ReactorSim::Operations::Mine.build(id: :m, seed: 1)

      expect(mine.nodes.fetch(:sconces)).to be_a(described_class)
    end
  end

  describe "the pit at night" do
    it "lets a lit area's gang work in the dark, where an unlit one wins nothing" do
      unlit = tick(at_the_face, 4)
      lit_up = tick(at_the_face({ pit_lighting: :arc_lamps }), 4)

      expect(got(unlit)).to eq(0.0)
      expect(got(lit_up)).to be_positive
    end

    it "is dark with the lever off" do
      expect(got(tick(at_the_face({ pit_lighting: :arc_lamps }, lamps: 0.0), 4))).to eq(0.0)
    end

    it "lights its own area and not the other" do
      op = at_the_face({ pit_lighting: :arc_lamps }, posts: { bay_1_hands: %i[crew_3 crew_4] })
      op = OpenPitRig.seed(op, nodes: { ore_bin: { parcels: OpenPitRig.parcels_at(293.15, limonite: 500.0, clay: 1_500.0) } })
      tick(op, 4)

      expect(got(op)).to be_positive
      expect(state(op, :bay_1_feed).fetch(:carried_kg)).to eq(0.0)
    end

    it "gives a brighter tier's gang more" do
      dim = tick(burning(at_the_face({ pit_lighting: :fire_baskets })), 4)
      bright = tick(at_the_face({ pit_lighting: :arc_lamps }), 4)

      expect(lit(bright)).to be > lit(dim)
      expect(got(bright)).to be > got(dim)
    end
  end

  describe "the tiers" do
    it "lights fire baskets slowly, as coal catches, and burns them down unfed" do
      op = tick(at_the_face({ pit_lighting: :fire_baskets }), 40)
      catching = state(op, :pit_lights).fetch(:fire_share)
      tick(op, 40)

      expect(state(op, :pit_lights).fetch(:fire_share)).to be > catching

      unfed = burning(at_the_face({ pit_lighting: :fire_baskets }, lamps: 0.0))
      well = state(tick(unfed, 4), :pit_lights).fetch(:fire_share)
      tick(unfed, 40)
      expect(state(unfed, :pit_lights).fetch(:fire_share)).to be < well
    end

    it "puts Wells lights out with their tank dry, and says so" do
      op = at_the_face({ pit_lighting: :wells_lights })
      tick(op, 40)
      expect(board(op)).to be(:lit)

      op = tick(OpenPitRig.seed(op, nodes: { pit_lights_tank: { parcels: [] } }), 12)

      expect(board(op)).to be(:running_dry)
      expect(lit(op)).to be < 0.1
    end

    it "darkens arc lamps with the shaft stopped, and says so" do
      op = at_the_face({ pit_lighting: :arc_lamps })
      op = OpenPitRig.seed(op, nodes: { line_shaft: { angular_momentum: 0.0 }, pit_lights: { angular_momentum: 0.0 } })
      OpenPitRig.tick(op, 4, supply: 0.0)

      expect(lit(op)).to eq(0.0)
      expect(board(op)).to be(:dark_shaft)
    end

    it "spends arc lamps' carbons while lit, and the lamp man trims them back" do
      worn = { pit_lights: { spent: 0.8 } }
      left = tick(OpenPitRig.seed(at_the_face({ pit_lighting: :arc_lamps }, conditions: noon), nodes: worn), 8)
      trimmed = tick(OpenPitRig.seed(at_the_face({ pit_lighting: :arc_lamps }, conditions: noon,
                                                 posts: { pit_lights_lamp_man: [ :crew_5 ] }), nodes: worn), 8)

      expect(state(left, :pit_lights).fetch(:spent)).to be > 0.8
      expect(state(trimmed, :pit_lights).fetch(:spent)).to be < 0.8
    end

    it "starts its carbons part spent from last night, a pinned ground fresh" do
      drawn = OpenPitRig.build(id: :pit, seed: 1, ground: nil, loadout: { pit_lighting: :arc_lamps })

      expect(state(drawn, :pit_lights).fetch(:spent)).to be_between(0.0, 0.9)
      expect(state(pit({ pit_lighting: :arc_lamps }), :pit_lights).fetch(:spent)).to eq(0.0)
    end
  end

  describe "darkness underfoot" do
    let(:slip) { ReactorSim::Peril.new(id: :slip, wounds: { impact: 1.0 }, severity: 1.0, underfoot: { dark: 4.0 }) }

    it "makes footing worse the less there is to see by, and no worse from a lamp's worth up" do
      expect(slip.footing({}, sight: 0.0)).to be > slip.footing({}, sight: 0.25)
      expect(slip.footing({}, sight: 0.25)).to be > slip.footing({}, sight: 0.5)
      expect(slip.footing({}, sight: 0.5)).to eq(1.0)
      expect(slip.footing({}, sight: 1.0)).to eq(1.0)
    end

    # A navvy carries no lamp, so all his light is the place's — and none of it reaches him on the
    # rods or in a cage, whatever place he set out from.
    it "sees by the place's light, but carried along a way only by a lamp of one's own" do
      op = pit
      navvy = op.minions.values.first
      daylight = { darkvision: 1.0 }

      expect(ReactorSim::Blunder.sight(navvy, {}, daylight)).to eq(1.0)
      expect(ReactorSim::Blunder.sight(navvy, { riding: :man_engine }, daylight)).to eq(0.0)
      expect(ReactorSim::Blunder.sight(navvy, { via: :cage_drive }, daylight)).to eq(0.0)
    end

    it "is on the pit's footing perils and the colliery's" do
      pit_op = pit({ kiln: :shaft_kiln })
      mine = ReactorSim::Operations::Mine.build(id: :m, seed: 1, loadout: { manriding: :man_engine })
      dark = ->(op) { op.nodes.values.flat_map(&:perils).select { |p| p.underfoot.key?(:dark) }.map(&:id) }

      expect(dark.(pit_op)).to include(:fell_off_the_stripping_ramp, :fell_off_the_ore_ramp, :into_the_water,
                                       :fell_into_the_kiln)
      expect(dark.(mine)).to include(:slipped_on_the_deck, :tub_into_shaft, :misstep)
    end
  end

  describe "the books" do
    def lit_night
      op = at_the_face({ pit_lighting: :fire_baskets, bank_lighting: :arc_lamps })
      op.set_control(:bank_lights_lamps, 100.0)
      tick(op, 8)
    end

    it "closes mass and energy with baskets burning and the dynamo turning" do
      op = lit_night
      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      tick(op, 20)

      expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass).abs / mass.abs).to be < Conservation::TOLERANCE
      expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules).abs / joules.abs)
        .to be < Conservation::TOLERANCE
    end

    it "replays bit for bit through a snapshot" do
      straight = tick(lit_night, 8)
      resumed = OpenPitRig.seed(tick(lit_night, 4))
      4.times do |t|
        resumed.receive_supply(:line_shaft, OpenPitRig::SUPPLY_J)
        resumed.step!(tick: t + 5)
      end

      expect(ReactorSim.canonical(resumed.state)).to eq(ReactorSim.canonical(straight.state))
    end
  end
end
