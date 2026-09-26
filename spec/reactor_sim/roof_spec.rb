# frozen_string_literal: true

require "reactor_sim"

# **The roof, and the post whose entire output is nothing going wrong.**
#
# Roof falls killed far more miners than every explosion put together, and they are undramatic
# in exactly the way that makes them hard to design around: nothing goes wrong suddenly,
# somebody simply did not set enough timber. Hewing advances the face and exposes fresh ground;
# timbering supports it. Run the one without the other and the roof takes up the difference.
#
# Against a crew of four and five jobs, that is the triage the whole operation is built to
# create: **timbering wins no coal**, so it is the post nobody can spare somebody for, right up
# until the road comes in on the putter.
#
# See `docs/design_sketches/mine.md` §4.6 stage F.
module RoofCrew
  ARCHETYPE = { label: "Collier", strength: 1.0, toughness: 1.0, endurance: 1.0e6,
                intelligence: 1.0, dexterity: 1.0, charisma: 1.0,
                # Hewing and timbering are **gated** on light: with no lamp this crew would
                # neither cut nor prop, and the roof would never come in for the wrong reason.
                tags: { mining_effectiveness: 0.6, shovelling: 0.5,
                        darkvision: 0.8 } }.freeze

  MINIONS = (1..4).to_h { |i| [ :"hand_#{i}",
                                { name: "Hand #{i}", archetype: :collier,
                                  hireable: false } ] }.freeze

  CONTENT = ReactorSim::Content.default.merging(archetypes: { collier: ARCHETYPE },
                                                minions: MINIONS)

  CREW = (1..4).to_h { |i| [ :"crew_#{i}", { minion: :"hand_#{i}" } ] }.freeze
end

RSpec.describe "the roof" do
  before { allow(ReactorSim::Content).to receive(:default).and_return(RoofCrew::CONTENT) }

  SUPPLY_J = 9.0e4
  # Long enough for the shift to reach their posts by cage before anything is asked of them.
  SETTLE = 600

  # A working district with the shift in place. Returns the operation and every event after
  # the settling period, so an example never has to see the walk.
  def working(hewing:, timbering:, ticks: 6_000)
    op = ReactorSim::Match
         .create(id: "r", seed: 3,
                 operations: [ { id: "pit", type: :mine,
                                 loadout: { manriding: :cage_gear },
                                 crew: RoofCrew::CREW } ])
         .operation(:pit)
    op.set_control(:winding, 100)
    op.set_control(:man_winding, 100)
    op.assign_minion(:crew_1, :hewing)
    op.assign_minion(:crew_2, :haulage)
    op.assign_minion(:crew_3, :timbering)
    SETTLE.times { |i| op.receive_supply(:line_shaft, SUPPLY_J); op.step!(tick: i + 1) }

    op.set_control(:man_winding, 0)
    op.set_control(:hewing, hewing)
    op.set_control(:haulage, 100)
    op.set_control(:timbering, timbering)

    events = []
    ticks.times do |i|
      op.receive_supply(:line_shaft, SUPPLY_J)
      events.concat(op.step!(tick: SETTLE + i + 1))
    end
    [ op, events ]
  end

  def integrity(op)
    road = op.state.fetch(:nodes).fetch(:tub_road)
    road.fetch(:durability) / road.fetch(:initial_durability)
  end

  def fall(events) = events.find { |e| e[:type] == :part_failed && e[:node] == :tub_road }

  describe "the gradient" do
    # What the guide asks every operation for: a setting that survives indefinitely, a setting
    # that produces far more and then destroys the machine, and a band between them.
    it "never falls in on a fully timbered face" do
      op, events = working(hewing: 100, timbering: 100)

      expect(integrity(op)).to eq(1.0)
      expect(fall(events)).to be_nil
    end

    it "comes in quickly on a face nobody is supporting" do
      _op, events = working(hewing: 100, timbering: 0)

      expect(fall(events)).not_to be_nil
    end

    it "lasts longer the more of the advance is supported" do
      _, unsupported = working(hewing: 100, timbering: 0)
      _, partly = working(hewing: 100, timbering: 60)

      expect(fall(partly)[:tick]).to be > fall(unsupported)[:tick]
    end

    # **The difference, not the ratio.** Cutting at 40 with nobody timbering is the same
    # exposure as cutting at 100 with the face 60% supported, and it has to behave the same —
    # a ratio would make an idle face consume timber to stand still.
    it "cares about how far the face has run ahead, not how hard it is worked" do
      _, slow = working(hewing: 40, timbering: 0)
      _, fast = working(hewing: 100, timbering: 60)

      expect(fall(slow)[:tick]).to eq(fall(fast)[:tick])
    end
  end

  describe "when it comes in" do
    it "chokes the road rather than sealing it" do
      op, = working(hewing: 100, timbering: 0)
      road = op.nodes.fetch(:tub_road)

      expect(op.state.fetch(:nodes).fetch(:tub_road)[:failure]).to be(:roof_fall)
      expect(road.failure_modes.dig(:roof_fall, :derates, :throughput)).to be > 0.0
    end

    # The putter is on the road and takes the worst of it; the hewer is at the far end of it and
    # still does not get away with it.
    it "catches the people under it" do
      _op, events = working(hewing: 100, timbering: 0)
      hurt = events.select { |e| e[:type] == :minion_hurt }

      expect(hurt.map { |e| e[:node] }).to include(:crew_2)
      expect(hurt).not_to be_empty
    end

    # `scales_with: :unsupported` — how far the face had run ahead when it went decides how bad
    # it is, so the same fall is worse on a face that was being driven hard.
    # **Asserted as an ordering, not as a tier.** Which band a given fall lands in is a balance
    # figure and moves whenever capability does — naming `:mortal` here broke the day hewing
    # became gated, for no reason connected to what this guards. The shape is what is claimed:
    # the further the face had run ahead, the worse it is for whoever was under it.
    it "is worse the further the face had run ahead" do
      _, reckless = working(hewing: 100, timbering: 0)
      _, careless = working(hewing: 100, timbering: 60)

      rank = ->(evs) {
        evs.select { |e| e[:type] == :minion_hurt }
           .sum { |e| ReactorSim::Injury::ORDER.index(e[:mode]).to_i + 1 }
      }

      expect(rank.call(reckless)).to be > rank.call(careless)
    end
  end

  it "conserves mass and energy through a fall" do
    op = ReactorSim::Match
         .create(id: "r", seed: 3,
                 operations: [ { id: "pit", type: :mine, crew: RoofCrew::CREW } ])
         .operation(:pit)
    op.set_control(:winding, 100)
    op.assign_minion(:crew_1, :hewing)
    op.assign_minion(:crew_2, :haulage)
    mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

    op.set_control(:hewing, 100)
    op.set_control(:haulage, 100)
    6_000.times { |i| op.receive_supply(:line_shaft, SUPPLY_J); op.step!(tick: i + 1) }

    mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    expect((mass - mass0).abs / mass0.abs).to be < 1e-9, "mass drifted by #{mass - mass0}"
    expect((joules - joules0).abs / joules0.abs).to be < 1e-9,
      "energy drifted by #{joules - joules0}"
  end
end
