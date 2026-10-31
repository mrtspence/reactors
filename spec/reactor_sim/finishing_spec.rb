# frozen_string_literal: true

require "support/open_pit_rig"
require "support/conservation"

# **Finishing**: washed ore calcined with small coal in a clamp or a shaft kiln — real chemistry in a
# coal fire, limonite to hematite and steam only hot, monoxide short of air, a draw that takes what
# lies at the bottom calcined or not — and the goal counting only what was finished. Zero ticks for
# the chemistry, a few from a kiln at work for the rest. Relational — no figure here is a tuning
# target.
RSpec.describe ReactorSim::Operations::OpenPit do
  before { allow(ReactorSim::Content).to receive(:default).and_return(OpenPitRig::CONTENT) }

  def pit(loadout = {}) = OpenPitRig.build(id: :pit, seed: 1, loadout: loadout)
  def tick(op, ticks = 1) = OpenPitRig.tick(op, ticks)
  def state(op, id) = OpenPitRig.node_state(op, id)
  def kg(op, id, resource) = state(op, id).fetch(:parcels).sum { |p| p.fetch(:resource) == resource ? p.fetch(:kg) : 0.0 }
  def signal(op) = described_class::Kiln::SIGNALS.keys.fetch(state(op, :kiln).fetch(:signal))
  def temperature(op) = op.nodes.fetch(:kiln).temperature_k(state(op, :kiln), op.content)
  def gauge(op, id) = op.project(viewer: :player).to_h.dig(:gauges, id)
  def seats(from, count) = (from...(from + count)).map { |i| :"crew_#{i}" }

  # Volume share of `resource` in what a node holds as gas.
  def gas_share(op, id, resource)
    gases = ReactorSim::Parcel.matching(state(op, id).fetch(:parcels), [ :gas ], op.content)
    of = gases.select { |p| p.fetch(:resource) == resource }
    ReactorSim::Parcel.total_volume(of, op.content) / ReactorSim::Parcel.total_volume(gases, op.content)
  end

  # The kiln at work, its gangs at it and washed ore to charge.
  def at_work(loadout = {}, **levers)
    op = pit(loadout)
    gang = op.nodes.fetch(:kiln_charging).control_id
    drawers = op.nodes.fetch(:kiln_drawing).control_id
    op = OpenPitRig.posted(op, **{ gang => seats(1, 3) }, **(drawers == gang ? {} : { drawers => seats(4, 3) }))
    op = OpenPitRig.seed(op, nodes: { washed_ore: { parcels: OpenPitRig.parcels_at(293.15, limonite: 5_000.0) } })
    levers.each { |id, value| op.set_control(id, value) }
    op
  end

  describe "calcining" do
    it "turns limonite to hematite and steam only hot, the mass whole, and the heat it takes the steam's" do
      content = pit.content
      spec = content.reaction(:limonite_calcining)
      ore = ->(kelvin) { OpenPitRig.parcels_at(kelvin, limonite: 100.0) }
      advance = ->(kelvin) { ReactorSim::Resources::Reaction.advance(spec, ore.(kelvin), temperature_k: kelvin, dt: 60.0, content: content) }
      hot, released = advance.(700.0)
      cold, = advance.(500.0)
      sensible = ->(parcels) { parcels.sum { |p| p.fetch(:joules) - (p.fetch(:kg) * content.resource(p.fetch(:resource)).fetch(:formation_enthalpy_j_per_kg, 0.0)) } }

      expect(hot.map { |p| p.fetch(:resource) }).to include(:hematite, :steam)
      expect(ReactorSim::Parcel.total_kg(hot)).to be_within(1e-9).of(100.0)
      expect(released).to eq(0.0)
      expect(sensible.(hot)).to be < sensible.(ore.(700.0))
      expect(cold).to eq(ore.(500.0))
    end

    it "calcines in a kiln at work, and says it is burning well" do
      op = tick(at_work, 4)

      expect(kg(op, :kiln, :hematite) + kg(op, :finished_ore, :hematite)).to be > kg(at_work, :kiln, :hematite)
      expect(signal(op)).to be(:burning)
    end

    it "burns its coal to monoxide short of air, and the board says so" do
      starved = tick(at_work(eyes_open: 0.0), 8)
      drawing = tick(at_work, 8)

      expect(gas_share(starved, :kiln, :whitedamp)).to be > gas_share(drawing, :kiln, :whitedamp)
      expect(signal(starved)).to be(:short_of_air)
    end

    it "runs hotter for more coal in the charge" do
      expect(temperature(tick(at_work(coal_in_charge: 100.0), 20))).to be > temperature(tick(at_work(coal_in_charge: 0.0), 20))
    end

    it "burns down with no coal coming, and says so" do
      op = tick(OpenPitRig.seed(at_work, nodes: { coal_stock: { parcels: [] } }), 8)

      expect(kg(op, :kiln, :coal)).to be < kg(tick(at_work, 8), :kiln, :coal)
      expect(signal(op)).to be(:no_coal)
    end
  end

  describe "the draw" do
    it "takes what lies at the bottom, calcined or not, in the kiln's own mix" do
      op = tick(at_work, 6)
      drawn = kg(op, :finished_ore, :limonite) / kg(op, :finished_ore, :hematite)
      held = kg(op, :kiln, :limonite) / kg(op, :kiln, :hematite)

      expect(kg(op, :finished_ore, :limonite)).to be_positive
      expect(drawn).to be_within(0.1 * held).of(held)
    end

    it "burns whoever draws it hot, and only while they draw it" do
      drawing = pit.nodes.fetch(:kiln_drawing)
      hot = state(tick(at_work, 2), :kiln_drawing)

      expect(drawing.perils.map(&:scales_with)).to all(be(:drawing_hot))
      expect(drawing.activity(hot, :drawing_hot, 0.25)).to be_positive
      expect(drawing.activity(hot.merge(working: 0.0), :drawing_hot, 0.25)).to eq(0.0)
      expect(drawing.activity(hot.merge(hot: 0.0), :drawing_hot, 0.25)).to eq(0.0)
    end
  end

  describe "the kiln top" do
    it "gasses whoever charges a kiln choked with coal for its air, and not one burning well" do
      starved = tick(at_work(eyes_open: 20.0, coal_in_charge: 100.0), 40)
      drawing = tick(at_work, 40)
      fatigue = ->(op) { seats(1, 3).sum { |seat| op.state.dig(:minions, seat, :fatigue) } }

      expect(gas_share(drawing, :kiln_top, :air)).to be > ReactorSim::Breath::SAFE
      expect(fatigue.(starved)).to be > fatigue.(drawing)
    end

    it "is cleared the faster in a wind" do
      breeze = pit.nodes.fetch(:kiln_breeze)
      sky = ->(wind) { Struct.new(:sky).new({ wind_m_s: wind }) }

      expect(breeze.head_pa(sky.(8.0))).to be > breeze.head_pa(sky.(0.0))
      expect(breeze.head_pa(sky.(0.0))).to be_positive
    end
  end

  describe "the tiers" do
    it "finishes more for its coal in a shaft kiln than a clamp" do
      made = lambda { |loadout|
        op = at_work(loadout)
        hematite = ->(o) { kg(o, :kiln, :hematite) + kg(o, :finished_ore, :hematite) }
        before = [ hematite.(op), kg(op, :coal_stock, :coal) ]
        tick(op, 20)
        (hematite.(op) - before.first) / (before.last - kg(op, :coal_stock, :coal))
      }

      expect(made.({ kiln: :shaft_kiln })).to be > made.({ kiln: :open_clamp })
    end

    it "lays a shaft kiln's charging and drawing on gangs of their own, and a clamp's on one" do
      clamp = pit.nodes
      shaft = pit({ kiln: :shaft_kiln }).nodes

      expect(clamp.fetch(:kiln_charging).control_id).to eq(clamp.fetch(:kiln_drawing).control_id)
      expect(shaft.fetch(:kiln_charging).control_id).not_to eq(shaft.fetch(:kiln_drawing).control_id)
      expect(shaft.fetch(:kiln_charging).perils.map(&:id)).to include(:fell_into_the_kiln)
    end
  end

  describe "the goal" do
    it "counts the hematite drawn, and not ore drawn half done" do
      finished = lambda { |parcels|
        gauge(tick(OpenPitRig.seed(pit, nodes: { finished_ore: { parcels: parcels } }), 4), :finished_tons).to_f
      }

      expect(finished.(OpenPitRig.parcels_at(293.15, limonite: 2_000.0))).to eq(0.0)
      expect(finished.(OpenPitRig.parcels_at(293.15, hematite: 2_000.0))).to be_positive
    end
  end

  describe "the books" do
    it "closes mass and energy through a burning kiln" do
      op = at_work
      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      tick(op, 20)

      expect((ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger) - mass).abs / mass.abs).to be < Conservation::TOLERANCE
      expect((ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger) - joules).abs / joules.abs)
        .to be < Conservation::TOLERANCE
    end

    it "replays bit for bit through a snapshot" do
      straight = tick(at_work, 8)
      resumed = OpenPitRig.seed(tick(at_work, 4))
      4.times do |t|
        resumed.receive_supply(:line_shaft, OpenPitRig::SUPPLY_J)
        resumed.step!(tick: t + 5)
      end

      expect(ReactorSim.canonical(resumed.state)).to eq(ReactorSim.canonical(straight.state))
    end
  end
end
