# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"
require "support/conservation"

# **The roof, and the post whose entire output is nothing going wrong.**
#
# Roof falls killed far more miners than every explosion put together, and they are undramatic in
# exactly the way that makes them hard to design around: nothing goes wrong suddenly, somebody
# simply did not set enough timber. Hewing advances the face and exposes fresh ground; timbering
# supports it. Run the one without the other and the roof takes up the difference.
#
# Against a crew of four and five jobs, that is the triage the whole operation is built to create:
# **timbering wins no coal**, so it is the post nobody can spare somebody for, right up until the
# road comes in on the putter.
#
# ## Built, not waited for
#
# The road erodes at a rate set by the unsupported advance, so a fall from a sound road is 6,000
# ticks away — which measures the **rate** rather than the fall. The gradient is therefore read off
# `integrity` after 200 ticks, and the fall itself from a road **seeded part-worn**, which is the
# state a district that has been driven all shift is really in.
#
# See `docs/design_sketches/mine.md` §4.6 stage F and `design_sketches/suite-runtime.md` §7.
RSpec.describe "the roof" do
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  # A road with almost nothing left, so an unsupported face brings it in inside 150 ticks.
  def worn_road = 20.0

  # **A full hand face**: five hewers, and the two timbermen it takes to keep up with them, since
  # one props three hewers' advance. A single hewer opens too little ground to wear the road.
  HEWERS = %i[crew_1 crew_4 crew_5 crew_6 crew_7].freeze
  TIMBERMEN = %i[crew_3 crew_8].freeze

  # A working district with the shift in place. Returns the operation and every event, so an
  # example never has to see the walk.
  def working(hewing:, timbering:, worn: nil, ticks: 200)
    pit = build_pit(id: "r", seed: 3, crew: PitRig.gang_crew(8), loadout: { winder: :cage_gear })
    op = at_the_face(seed(pit, nodes: worn ? { tub_road: { durability: worn } } : {}),
                     hewing: HEWERS, timbering: TIMBERMEN)
    levers!(op, hewing: hewing, haulage: 100, timbering: timbering,
                coal_winding: 100, pumping: 100, ventilation: 100)

    [ op, run!(op, ticks) ]
  end

  def integrity(op)
    road = op.state.fetch(:nodes).fetch(:tub_road)
    road.fetch(:durability) / road.fetch(:initial_durability)
  end

  def fall(events) = events.find { |e| e[:type] == :part_failed && e[:node] == :tub_road }

  describe "the gradient" do
    # What the guide asks every operation for: a setting that survives indefinitely, a setting
    # that produces far more and then destroys the machine, and a band between them.
    #
    # **Read off `integrity` rather than off a fall**, because the gradient is the erosion rate and
    # a fall is where it ends up.
    it "never loses a thread of the road on a fully timbered face" do
      op, events = working(hewing: 100, timbering: 100)

      expect(integrity(op)).to eq(1.0)
      expect(fall(events)).to be_nil
    end

    it "wears it away on a face nobody is supporting" do
      op, events = working(hewing: 100, timbering: 0)

      expect(integrity(op)).to be < 1.0
      expect(fall(events)).to be_nil, "200 ticks should wear it, not bring it in"
    end

    it "lasts longer the more of the advance is supported" do
      wear = [ 0, 60, 100 ].map { |timbering| integrity(working(hewing: 100, timbering: timbering).first) }

      expect(wear.each_cons(2).all? { |worse, better| better > worse }).to be(true), wear.inspect
    end

    # **The difference, not the ratio.** A slow face nobody is timbering and a fast one partly
    # propped leave the same ground unpropped, and have to behave the same: a ratio would make an
    # idle face consume timber to stand still. The timbering that makes the two match is worked
    # out from the face and the props rather than written down, so a retune moves nothing here.
    it "cares about how far the face has run ahead, not how hard it is worked" do
      slow = 40.0
      probe, = working(hewing: 100, timbering: 0, ticks: 1)
      cut = probe.state.dig(:nodes, :pick_line, :carried_kg) / ReactorSim::DT
      prop = ReactorSim::Operations::Mine::Roadway::TIMBERED_KG_PER_S *
             probe.minions.fetch(TIMBERMEN.first).capability(probe.state.dig(:minions, TIMBERMEN.first),
                                                             effort: probe.control_points.fetch(:timbering).effort,
                                                             gated_by: probe.control_points.fetch(:timbering).gated_by) *
             TIMBERMEN.size
      timbering = 100.0 * cut * (1.0 - (slow / 100.0)) / prop

      expect(integrity(working(hewing: slow, timbering: 0).first))
        .to be_within(1e-6).of(integrity(working(hewing: 100, timbering: timbering).first))
    end
  end

  describe "when it comes in" do
    it "chokes the road rather than sealing it" do
      op, = working(hewing: 100, timbering: 0, worn: worn_road, ticks: 150)
      road = op.nodes.fetch(:tub_road)

      expect(op.state.fetch(:nodes).fetch(:tub_road)[:failure]).to be(:roof_fall)
      expect(road.failure_modes.dig(:roof_fall, :derates, :throughput)).to be > 0.0
    end

    # **The pair that makes the timbering post worth a seat.** The same part-worn road, and the
    # only difference is whether anybody is setting timber.
    it "stays up on the same worn road if somebody is timbering it" do
      _, events = working(hewing: 100, timbering: 100, worn: worn_road, ticks: 150)

      expect(fall(events)).to be_nil
    end

    # The putter is on the road and takes the worst of it; the hewer is at the far end of it and
    # still does not get away with it.
    it "catches the people under it" do
      _op, events = working(hewing: 100, timbering: 0, worn: worn_road, ticks: 150)
      hurt = events.select { |e| e[:type] == :minion_hurt }

      expect(hurt.map { |e| e[:node] }).to include(:crew_2)
      expect(hurt).not_to be_empty
    end

    # `scales_with: :unsupported` — how far the face had run ahead when it went decides how bad it
    # is, so the same fall is worse on a face that was being driven hard.
    # **Asserted as an ordering, not as a tier.** Which band a given fall lands in is a balance
    # figure and moves whenever capability does — naming `:mortal` here broke the day hewing became
    # gated, for no reason connected to what this guards. Measured: rank 13 against 7.
    it "is worse the further the face had run ahead" do
      _, reckless = working(hewing: 100, timbering: 0, worn: worn_road, ticks: 150)
      _, careless = working(hewing: 100, timbering: 60, worn: worn_road, ticks: 150)

      rank = ->(evs) {
        evs.select { |e| e[:type] == :minion_hurt }
           .sum { |e| ReactorSim::Injury::ORDER.index(e[:mode]).to_i + 1 }
      }

      expect(rank.call(reckless)).to be > rank.call(careless)
    end
  end

  it "conserves mass and energy through a fall" do
    op, = working(hewing: 100, timbering: 0, worn: worn_road, ticks: 0)
    mass0 = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules0 = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)

    run!(op, 200)

    mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
    joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
    expect((mass - mass0).abs / mass0.abs).to be < Conservation::TOLERANCE,
                                              "mass drifted by #{mass - mass0}"
    expect((joules - joules0).abs / joules0.abs).to be < Conservation::TOLERANCE,
                                                    "energy drifted by #{joules - joules0}"
  end
end
