# frozen_string_literal: true

require "reactor_sim"

# **Not `ReferenceCrew`**, and the reason is the gate. That fixture is flat 1.0 with *no tags at
# all*, which is exactly right for a steam engine and useless in a mine: hewing and timbering
# are gated on `mining_effectiveness` and `darkvision`, so a reference hand with neither cuts
# precisely nothing. A fixture with a pick and a lamp, and otherwise as boring as the original.
module MineCrew
  ARCHETYPE = { label: "Collier", strength: 1.0, toughness: 1.0, endurance: 1.0e6,
                intelligence: 1.0, dexterity: 1.0, charisma: 1.0,
                tags: { mining_effectiveness: 0.6, shovelling: 0.5,
                        darkvision: 0.8 } }.freeze

  MINIONS = (1..4).to_h { |i| [ :"hand_#{i}",
                                { name: "Hand #{i}", archetype: :collier,
                                  hireable: false } ] }.freeze

  CONTENT = ReactorSim::Content.default.merging(archetypes: { collier: ARCHETYPE },
                                                minions: MINIONS)

  CREW = (1..4).to_h { |i| [ :"crew_#{i}", { minion: :"hand_#{i}" } ] }.freeze

  def self.options = { crew: CREW }
end

# The mine, end to end.
#
# The second operation, and the first that **buys** its power: everything that costs anything
# hangs off one line shaft turned from somewhere else, so the interesting failures are all
# variations on "the supply went away".
#
# Driven from a steady supply rather than from a real engine — the coupling itself is proved in
# `coupling_spec`, and a mine spec that first has to raise steam is measuring the wrong machine.
#
# See `docs/design_sketches/mine.md` §4.6 stage C.
RSpec.describe "the mine" do
  before { allow(ReactorSim::Content).to receive(:default).and_return(MineCrew::CONTENT) }

  TOLERANCE = 1e-9

  # Comfortably more than the mine can spend, so what is measured is the mine rather than the
  # supply. `Import` caps what it will hold, so this does not accumulate.
  SUPPLY_J = 9.0e4

  def mine(**opts)
    ReactorSim::Match
      .create(id: "m", seed: 11,
              operations: [ { id: "pit", type: :mine,
                              # **Ordinary ground unless an example asks otherwise.** How gassy
                              # and how wet a pit is is drawn per match, so a spec that does not
                              # pin it measures the luck rather than the mine — the same
                              # argument that keeps `ReferenceCrew` out of `content/minions/`.
                              # `describe "the ground"` is where the drawing itself is tested.
                              ground: ReactorSim::Operations::Mine::Ground::ORDINARY,
                              **MineCrew.options, **opts } ])
      .operation(:pit)
  end

  # One tick of a mine that is being paid for.
  def run!(op, ticks, supply: SUPPLY_J, from: 0)
    ticks.times do |i|
      op.receive_supply(:line_shaft, supply)
      op.step!(tick: from + i + 1)
    end
    op
  end

  def held(op, node, resource)
    parcels = op.state.fetch(:nodes).fetch(node).fetch(:parcels)
    ReactorSim::Parcel.total_kg(parcels.select { |p| p[:resource] == resource })
  end

  def crew(op, seat) = op.state.fetch(:minions).fetch(seat)

  def omega(op) = op.state.fetch(:nodes).fetch(:line_shaft).fetch(:angular_momentum) / 900.0

  # Send the shift underground and open everything up.
  def work!(op)
    op.assign_minion(:crew_1, :hewing)
    op.assign_minion(:crew_2, :haulage)
    op.set_control(:hewing, 100)
    op.set_control(:haulage, 100)
    op.set_control(:winding, 100)
    op
  end

  it "builds with a shaft, a circuit, a seam and somewhere to stand" do
    op = mine

    expect(op.layout.places).to contain_exactly(:bank, :pit_bottom, :district)
    expect(op.control_points.keys).to include(:hewing, :haulage, :winding, :ventilation,
                                              :pumping, :quarters)
    expect(held(op, :seam, :coal)).to be > 0.0
  end

  describe "the shift has to get there" do
    # The claim the whole spatial release exists for. A mine is not an engine: the levers that
    # matter are at the far end of a shaft and a road, and nobody is at them yet.
    it "leaves nobody at the face on the tick they are sent" do
      op = work!(mine)

      expect(crew(op, :crew_1)[:posting]).to be(:hewing)
      expect(crew(op, :crew_1)[:station]).to be_nil
      expect(crew(op, :crew_1)[:place]).to be(:bank)
    end

    it "wins no coal at all until somebody is actually at the face" do
      op = run!(work!(mine), 200)

      expect(crew(op, :crew_1)[:station]).to be_nil
      expect(op.ledger.fetch(:mass_delivered)).to be > 0.0 # water, which needs nobody
      expect(held(op, :seam, :coal)).to eq(90_000.0)
    end

    it "puts them at their posts once the walk is done" do
      op = run!(work!(mine), 1_500)

      expect(crew(op, :crew_1)[:place]).to be(:district)
      expect(crew(op, :crew_1)[:station]).to be(:hewing)
      expect(crew(op, :crew_2)[:place]).to be(:pit_bottom)
      expect(crew(op, :crew_2)[:station]).to be(:haulage)
    end

    # **Except for the ones who are already down.** A pit whose every hand starts at bank is a
    # pit where the opening five minutes of a match are a walk, so the last seats are an advance
    # shift standing in the district when the whistle goes.
    describe "the advance shift" do
      it "is already in the district, posted to nothing" do
        op = mine
        below = op.state.fetch(:minions).select { |_, s| s[:place] == :district }

        expect(below.keys).to eq(%i[crew_8 crew_9 crew_10])
        expect(below.values.map { |s| s[:posting] }).to all(be_nil)
      end

      # The point of them: coal on the first tick they are told to cut, with no walk first.
      it "takes up a face post on the spot, where a hand at bank cannot" do
        op = mine
        op.assign_minion(:crew_8, :hewing)
        op.step!(tick: 1)

        expect(crew(op, :crew_8)[:station]).to be(:hewing)
        expect(crew(op, :crew_1)[:place]).to be(:bank)
      end
    end
  end

  describe "output" do
    it "cuts coal and sends it to the surface" do
      op = run!(work!(mine), 2_500)

      expect(held(op, :seam, :coal)).to be < 90_000.0
      expect(op.ledger.fetch(:mass_delivered)).to be > 0.0
      # **Not the winder's `carried_kg`**, which is what one tick happened to be carrying. A
      # winder's output is a cycle rather than a flow and there are always ticks with nothing on
      # the rope, so an instantaneous reading is a coin toss dressed as an assertion — it only
      # passed while the face was producing enough to keep the drum busy every tick. The ledger
      # is the measurement; `coal_raised` averages over twelve ticks for the same reason.
    end

    # A ratio rather than a figure: the shape is what is being asserted, not the balance.
    it "cuts more with the lever further over" do
      hard = run!(work!(mine), 2_500)
      easy = work!(mine)
      easy.set_control(:hewing, 40)
      easy = run!(easy, 2_500)

      expect(90_000.0 - held(hard, :seam, :coal))
        .to be > (90_000.0 - held(easy, :seam, :coal))
    end

    it "is the first thing in the game to write mass_delivered" do
      op = run!(work!(mine), 800)

      expect(op.ledger.fetch(:mass_delivered)).to be > 0.0
    end
  end

  describe "when the supply fails" do
    # The mine's signature failure, and the reason drainage is on the same shaft as everything
    # else: stop paying and the water starts winning.
    it "drowns the workings once the pump stops" do
      op = run!(work!(mine), 1_200)
      expect(held(op, :pit_bottom, :water)).to be < 5.0

      run!(op, 2_500, supply: 0.0, from: 1_200)

      expect(omega(op)).to be < 1.0
      expect(held(op, :pit_bottom, :water)).to be > 50.0
    end

    # A winding drum is positive displacement: it raises coal because it is turning, and at rest
    # raises none. Without `displacement:` on the fitting, `driven_by:` is only a *bill* — the
    # pump lifted its water 90 m for nothing with the shaft stopped, and the winder did the same.
    it "stops raising coal, because a drum that is not turning raises nothing" do
      op = run!(work!(mine), 1_500)
      # Long enough for the shaft to actually run down — it coasts on its own inertia for a
      # good while after the supply goes, which is the behaviour the buffer exists to give.
      run!(op, 3_000, supply: 0.0, from: 1_500)
      before = op.ledger.fetch(:mass_delivered)

      run!(op, 400, supply: 0.0, from: 4_500)

      expect(omega(op)).to be < 0.5
      expect(op.state.fetch(:nodes).fetch(:winder).fetch(:carried_kg)).to be < 0.01
      expect(op.ledger.fetch(:mass_delivered) - before).to be < 1.0
    end
  end

  describe "ventilation" do
    it "courses air from the downcast round the workings and out through the fan" do
      op = run!(mine, 400)

      expect(op.state.fetch(:nodes).fetch(:upcast).fetch(:carried_kg)).to be > 0.0
      expect(op.ledger.fetch(:mass_added)).to be > 0.0
      expect(op.ledger.fetch(:mass_vented)).to be > 0.0
    end
  end

  # **A pit whose numbers are identical every match is a pit you learn once.** How fiery a
  # panel is, how sour the waste runs and how wet the strata is are properties of the ground,
  # drawn when the match is made — so an overseer has to feel out which colliery they were
  # given rather than apply a remembered counter-measure.
  describe "the ground" do
    def ground(seed, node)
      ReactorSim::Match
        .create(id: "g", seed: seed, operations: [ { id: "pit", type: :mine } ])
        .operation(:pit).state.fetch(:nodes).fetch(node).fetch(:ground)
    end

    it "gives two matches different ground" do
      expect(ground(11, :blower)).not_to eq(ground(12, :blower))
    end

    # **Its own RNG stream per node**, so a fiery pit is not also a wet one — otherwise one
    # reading would tell a player everything and the variation would buy nothing.
    it "varies each seep independently of the others" do
      seeds = (1..12).map { |s| [ ground(s, :blower), ground(s, :goaf_seep) ] }
      firedamp, blackdamp = seeds.transpose

      expect(firedamp.each_with_index.max[1]).not_to eq(blackdamp.each_with_index.max[1])
    end

    # Entropy at `initial_state` only, which is what keeps it replayable: the same seed is the
    # same mine, every time, on any machine.
    it "is the same mine for the same seed" do
      expect(ground(7, :seepage)).to eq(ground(7, :seepage))
    end

    # The waste makes a little carbon monoxide on its own, and how much is the ground's
    # business too — a sour goaf is a pit where the canary is the only warning there will be.
    it "varies how sour the old workings are" do
      sour = (1..10).map do |seed|
        parcels = ReactorSim::Match
                  .create(id: "g", seed: seed, operations: [ { id: "pit", type: :mine } ])
                  .operation(:pit).state.fetch(:nodes).fetch(:goaf).fetch(:parcels)
        ReactorSim::Parcel.total_kg(parcels.select { |p| p[:resource] == :whitedamp })
      end

      expect(sour.uniq.length).to be > 1
      expect(sour.min).to be < sour.max
    end
  end

  describe "conservation" do
    # The spec that catches real physics bugs. It found two here: air reversing out of the
    # downcast into a port nothing was counting, and a pump lifting water for free with the
    # shaft stopped.
    it "holds through a full shift of cutting, winding and pumping" do
      op = work!(mine)
      mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

      run!(op, 3_000)

      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      expect((mass - mass0).abs / mass0.abs).to be < TOLERANCE, "mass drifted by #{mass - mass0}"
      expect((joules - joules0).abs / joules0.abs).to be < TOLERANCE,
        "energy drifted by #{joules - joules0}"
    end

    it "holds with the supply cut and the mine flooding" do
      op = work!(mine)
      mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)

      run!(op, 600)
      run!(op, 1_200, supply: 0.0, from: 600)

      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      expect((mass - mass0).abs / mass0.abs).to be < TOLERANCE
    end
  end

  it "runs a long shift at moderate settings with nothing to report" do
    op = work!(mine)
    op.set_control(:hewing, 50)
    op.set_control(:haulage, 50)

    events = Array.new(3_000) { |i|
      op.receive_supply(:line_shaft, SUPPLY_J)
      op.step!(tick: i + 1)
    }.flatten

    expect(events).to be_empty
  end

  describe "snapshot" do
    it "round-trips chassis, loadout and a shift part-way down the shaft" do
      op = run!(work!(mine), 300)

      restored = ReactorSim::Operation.from_h(
        ReactorSim.deep_symbolize(JSON.parse(JSON.generate(op.to_h)))
      )

      expect(restored.options.fetch(:chassis)).to be(:two_shaft)
      expect(restored.options.fetch(:loadout).fetch(:winder)).to be(:steam_whim)
      expect(restored.state.fetch(:minions).fetch(:crew_1)[:posting]).to be(:hewing)
      expect(ReactorSim.canonical(restored.to_h)).to eq(ReactorSim.canonical(op.to_h))
    end

    it "carries on identically after a restore" do
      op = run!(work!(mine), 300)
      restored = ReactorSim::Operation.from_h(
        ReactorSim.deep_symbolize(JSON.parse(JSON.generate(op.to_h)))
      )

      run!(op, 600, from: 300)
      run!(restored, 600, from: 300)

      expect(ReactorSim.canonical(restored.to_h)).to eq(ReactorSim.canonical(op.to_h))
    end
  end
end
