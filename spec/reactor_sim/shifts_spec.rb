# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"
require "support/pit_rig"

# **Who is already down when the match starts**, and where they can rest. The shifts are fitted
# parts — three at the face and three at the pit bottom to start with, five of either upgraded —
# dealt from the end of the roster, face first, so the first seats stay at bank. The pit bottom has
# its own refuge, room for one. See `design_sketches/roadway-shift.md`.
RSpec.describe "shifts" do
  include Constructed
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

  def starting(loadout = {})
    shifts = { face_shift: :advance_shift, pit_bottom_shift: :pit_bottom_shift }.merge(loadout)
    pit = build_pit(id: "s", seed: 5, loadout: shifts)
    pit.state.fetch(:minions).to_h { |id, s| [ id, s.fetch(:place) ] }
  end

  def seats(places, place) = places.select { |_, at| at == place }.keys

  it "starts three at the face and three at the pit bottom, from the end of the roster" do
    places = starting

    expect(seats(places, :district)).to eq(%i[crew_8 crew_9 crew_10])
    expect(seats(places, :pit_bottom)).to eq(%i[crew_5 crew_6 crew_7])
    expect(seats(places, :bank)).to eq(%i[crew_1 crew_2 crew_3 crew_4])
  end

  it "posts them to nothing, so where they work is still the first decision" do
    pit = build_pit(id: "s", seed: 5, loadout: { pit_bottom_shift: :pit_bottom_shift })

    expect(%i[crew_5 crew_8].map { |id| pit.state.dig(:minions, id, :station) }).to all(be_nil)
  end

  it "starts five of either with the back shift and the underground stable" do
    expect(seats(starting(face_shift: :back_shift), :district).size).to eq(5)
    expect(seats(starting(pit_bottom_shift: :underground_stable), :pit_bottom).size).to eq(5)
  end

  # Ten seats and ten places underground: the face is dealt first, and nobody is left at bank.
  it "never deals more than the roster holds, the face first" do
    places = starting(face_shift: :back_shift, pit_bottom_shift: :underground_stable)

    expect(seats(places, :district)).to eq(%i[crew_6 crew_7 crew_8 crew_9 crew_10])
    expect(seats(places, :pit_bottom)).to eq(%i[crew_1 crew_2 crew_3 crew_4 crew_5])
  end

  it "starts everybody at bank with no shift fitted" do
    expect(starting(face_shift: nil, pit_bottom_shift: nil).values.uniq).to eq([ :bank ])
  end

  describe "the pit bottom refuge" do
    def tired(seat) = { seat => { place: :pit_bottom, fatigue: 0.6 } }

    it "is a rest post at the pit bottom with room for one" do
      pit = build_pit(id: "s", seed: 5)
      post = pit.control_points.fetch(:pit_bottom_rest)

      expect([ post.place, post.capacity ]).to eq([ :pit_bottom, 1 ])
      expect(pit.assign_minion(:crew_1, :pit_bottom_rest)).to be(true)
      expect(pit.assign_minion(:crew_2, :pit_bottom_rest)).to be(false)
    end

    it "rests somebody faster than standing at the pit bottom posted to nothing" do
      resting = seed(build_pit(id: "s", seed: 5), minions: tired(:crew_1))
      idle = seed(build_pit(id: "s", seed: 5), minions: tired(:crew_1))
      resting.assign_minion(:crew_1, :pit_bottom_rest)
      [ resting, idle ].each { |op| run!(op, 20) }

      expect(resting.state.dig(:minions, :crew_1, :fatigue)).to be < idle.state.dig(:minions, :crew_1, :fatigue)
    end
  end
end
