# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"
require "support/pit_rig"

# **Who is already down when the match starts**, and where they can rest. The shifts are fitted
# parts — one at the face and one at the pit bottom to start with, bigger ones upgraded — dealt
# from the end of the roster, face first, so the first seats stay at bank. The pit bottom has its
# own refuge, room for one. See `design_sketches/roadway-shift.md`.
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

  # Counts come from the parts, so a retune of a shift or the lamp cabin moves nothing here.
  def shift_seats(part) = ReactorSim::Parts.fetch(part).stats.fetch(:advance_seats)
  def roster = ReactorSim::Parts.fetch(:lamp_cabin).stats.fetch(:crew_capacity)
  def seat_ids(range) = range.map { |i| :"crew_#{i}" }

  it "deals the face shift from the end of the roster and the pit bottom shift before it" do
    places = starting
    face = shift_seats(:advance_shift)
    bottom = shift_seats(:pit_bottom_shift)

    expect(seats(places, :district)).to eq(seat_ids((roster - face + 1)..roster))
    expect(seats(places, :pit_bottom)).to eq(seat_ids((roster - face - bottom + 1)..(roster - face)))
    expect(seats(places, :bank)).to eq(seat_ids(1..(roster - face - bottom)))
  end

  it "posts them to nothing, so where they work is still the first decision" do
    pit = build_pit(id: "s", seed: 5, loadout: { pit_bottom_shift: :pit_bottom_shift })

    expect(%i[crew_5 crew_8].map { |id| pit.state.dig(:minions, id, :station) }).to all(be_nil)
  end

  it "starts more hands below with the back shift and the underground stable" do
    expect(seats(starting(face_shift: :back_shift), :district).size)
      .to be > seats(starting, :district).size
    expect(seats(starting(pit_bottom_shift: :underground_stable), :pit_bottom).size)
      .to be > seats(starting, :pit_bottom).size
  end

  # The face is dealt first, the pit bottom gets what is left, and nobody is dealt twice.
  it "never deals more than the roster holds, the face first" do
    places = starting(face_shift: :back_shift, pit_bottom_shift: :underground_stable)
    face = [ shift_seats(:back_shift), roster ].min
    bottom = [ shift_seats(:underground_stable), roster - face ].min

    expect(seats(places, :district).size).to eq(face)
    expect(seats(places, :pit_bottom).size).to eq(bottom)
    expect(places.size).to eq(roster)
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
