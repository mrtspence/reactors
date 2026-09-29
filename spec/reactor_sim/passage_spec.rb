# frozen_string_literal: true

require "reactor_sim"

# **Where somebody is, and how long it takes them to be somewhere else.**
#
# Until this landed a reassignment was instantaneous, free and unconstrained: `assign_minion`
# merged a symbol into a hash. A mine cannot be built on that — getting people in and out is
# most of what a mine actually does, and a man engine that saves nobody any time is not a
# purchase anyone would make.
#
# On a rig, because the claim is about the movement model rather than about any one mine, and
# because the mine does not exist yet.
#
# The load-bearing claim is the first one: **an operation that declares no passages is
# bit-identical to one from before this existed.** Geometry is opt-in, so the steam engine did
# not acquire a walk to the firehole.
#
# See `docs/design_sketches/mine.md` §4.2 and §4.3.
module PassageRig
  TIRELESS = 1.0e6

  ARCHETYPES = {
    walker: { label: "Walker", strength: 1.0, toughness: 1.0, endurance: TIRELESS,
              intelligence: 1.0, dexterity: 1.0, charisma: 1.0, tags: {} },
    # Same person, one tag different — so a spec comparing them is comparing the gate and
    # nothing else.
    wiry: { label: "Wiry", strength: 1.0, toughness: 1.0, endurance: TIRELESS,
            intelligence: 1.0, dexterity: 1.0, charisma: 1.0, tags: { wiry: true } },
    # Slower than the other two, and nothing else changed — `pace` blends strength and
    # toughness, so halving both halves the walk.
    plodder: { label: "Plodder", strength: 0.5, toughness: 0.5, endurance: TIRELESS,
               intelligence: 1.0, dexterity: 1.0, charisma: 1.0, tags: {} }
  }.freeze

  MINIONS = { walker: { name: "Walker", archetype: :walker, hireable: false },
              wiry: { name: "Wiry", archetype: :wiry, hireable: false },
              plodder: { name: "Plodder", archetype: :plodder, hireable: false } }.freeze

  CONTENT = ReactorSim::Content.default.merging(archetypes: ARCHETYPES, minions: MINIONS)

  CREW = { crew_1: { minion: :walker }, crew_2: { minion: :wiry },
           crew_3: { minion: :plodder } }.freeze

  # A pit in miniature: quarters at bank, a shaft, a long road in, and a crawl to the face that
  # only somebody wiry can get through.
  #
  #   quarters -40m@1.2- pit_top -60m@0.4- pit_bottom -400m@1.2- district -30m@0.6- face
  #                              (ladderway)                              (requires :wiry)
  def self.passages
    [
      ReactorSim::Passage.new(a: :bank, b: :pit_top, metres: 40.0, speed_m_s: 1.2),
      ReactorSim::Passage.new(a: :pit_top, b: :pit_bottom, metres: 60.0, speed_m_s: 0.4,
                              label: "Ladderway"),
      ReactorSim::Passage.new(a: :pit_bottom, b: :district, metres: 400.0, speed_m_s: 1.2),
      ReactorSim::Passage.new(a: :district, b: :face, metres: 30.0, speed_m_s: 0.6,
                              requires: :wiry, label: "Crawl")
    ]
  end

  def self.control_points
    [
      ReactorSim::ControlPoint.new(id: :quarters, label: "Crew Quarters", place: :bank),
      ReactorSim::ControlPoint.new(id: :banking, label: "Banking", place: :pit_top),
      ReactorSim::ControlPoint.new(id: :onsetting, label: "Onsetting", place: :pit_bottom),
      ReactorSim::ControlPoint.new(id: :hewing, label: "Hewing", place: :face)
    ]
  end

  def self.nodes
    [ ReactorSim::Nodes::Vessel.new(id: :store, volume_m3: 1.0, ambient_conductance: 0.0) ]
  end
end

ReactorSim::Operations.register(:passage_rig, harness: true) do |id:, seed:, **opts|
  crew = ReactorSim::Crew.normalise(opts.fetch(:crew, PassageRig::CREW), capacity: 3)
  content = opts[:content] || ReactorSim::Content.default

  ReactorSim::Operation.new(
    id: id, type: :passage_rig, seed: seed, content: content,
    time_scale: opts.fetch(:time_scale, 20.0), state: opts[:state], rngs: opts[:rngs],
    options: { crew: crew },
    nodes: PassageRig.nodes,
    passages: opts.fetch(:flat, false) ? [] : PassageRig.passages,
    control_points: PassageRig.control_points,
    minions: crew.map { |seat, posting|
      sheet = ReactorSim::Crew.resolve(posting, content: content)
      ReactorSim::Minion.new(id: seat, station: :quarters, place: :bank,
                             name: sheet.fetch(:name), minion: sheet.fetch(:minion),
                             archetype: sheet.fetch(:archetype), stats: sheet.fetch(:stats),
                             tags: sheet.fetch(:tags))
    }
  )
end

RSpec.describe "passages and minion travel" do
  before { allow(ReactorSim::Content).to receive(:default).and_return(PassageRig::CONTENT) }

  # `time_scale` rides in the operation spec rather than on `Match.create`, because that one
  # applies to every operation and is explicitly passed — so a builder default would be
  # overridden by it rather than filling in for it.
  def rig(time_scale: 20.0, **opts)
    ReactorSim::Match
      .create(id: "p", seed: 3,
              operations: [ { id: "pit", type: :passage_rig, time_scale: time_scale, **opts } ])
      .operation(:pit)
  end

  def crew(op, seat) = op.state.fetch(:minions).fetch(seat)

  # Seconds of walking before `seat` is actually working `station`, to the nearest tick.
  def seconds_to_arrive(op, seat, station, limit: 4000)
    op.assign_minion(seat, station)
    limit.times do |i|
      op.step!(tick: i + 1)
      return (i + 1) * ReactorSim::DT * op.time_scale if crew(op, seat)[:station] == station
    end
    nil
  end

  describe "an operation with no passages" do
    # The claim the whole design rests on: geometry is opt-in and costs nothing where it is not
    # declared. The steam engine must not have acquired a walk to the firehole.
    it "assigns instantly, exactly as before" do
      op = rig(flat: true)
      expect(op.layout.spatial?).to be(false)

      op.assign_minion(:crew_1, :hewing)

      expect(crew(op, :crew_1)[:station]).to be(:hewing)
      expect(crew(op, :crew_1)[:posting]).to be(:hewing)
    end
  end

  describe "a posting somewhere else" do
    it "takes the minion off their post at once, and they are not there yet" do
      op = rig
      op.assign_minion(:crew_1, :onsetting)

      expect(crew(op, :crew_1)[:posting]).to be(:onsetting)
      expect(crew(op, :crew_1)[:station]).to be_nil
      expect(crew(op, :crew_1)[:place]).to be(:bank)
    end

    it "arrives after the distance has actually been walked" do
      op = rig
      # bank -> pit_top is 40 m at 1.2 m/s. A capability-1.0 walker takes 33.3 s.
      expect(seconds_to_arrive(op, :crew_1, :banking)).to be_within(6.0).of(33.3)
    end

    # The route is two hops and the middle place has no lever on it at all — proving the walk
    # follows the passage graph rather than jumping between stations.
    it "routes through an intermediate place" do
      op = rig
      # 40/1.2 + 60/0.4 = 33.3 + 150 = 183.3 s
      expect(seconds_to_arrive(op, :crew_1, :onsetting)).to be_within(6.0).of(183.3)
    end

    it "puts them down at each place along the way" do
      op = rig
      op.assign_minion(:crew_1, :onsetting)
      seen = []
      60.times { |i| op.step!(tick: i + 1); seen << crew(op, :crew_1)[:place] }

      expect(seen.uniq).to eq(%i[bank pit_top pit_bottom])
    end
  end

  describe "who can get where" do
    it "refuses a posting this minion cannot reach" do
      op = rig
      expect(op.assign_minion(:crew_1, :hewing)).to be(false)
      expect(crew(op, :crew_1)[:posting]).to be(:quarters)
    end

    it "allows it for somebody who can take the gated passage" do
      op = rig
      expect(op.assign_minion(:crew_2, :hewing)).to be(true)
      # Bank to face is all four passages: 40/1.2 + 60/0.4 + 400/1.2 + 30/0.6 = 566.7 s.
      expect(seconds_to_arrive(op, :crew_2, :hewing)).to be_within(10.0).of(566.7)
    end

    it "still refuses a station that does not exist at all" do
      op = rig
      expect(op.assign_minion(:crew_1, :nowhere)).to be(false)
    end
  end

  describe "pace" do
    # `pace` runs through `capability`, so the same things that make somebody worse at a shovel
    # make them slower on a road. Asserted as a RATIO, never as a figure.
    it "is slower for a weaker minion" do
      brisk = seconds_to_arrive(rig, :crew_1, :banking)
      slow = seconds_to_arrive(rig, :crew_3, :banking)

      expect(slow).to be > brisk
    end

    # The zero case is asserted on `pace` directly rather than through a tick, because phase 6c
    # runs first and a minion off post recovers — so somebody who arrives at a tick spent has
    # already rested a little by the time 6d asks how far they can walk. They stop, briefly,
    # and then go on, which is the right behaviour and a poor assertion.
    it "is exactly zero for a minion with nothing left" do
      minion = rig.minions.fetch(:crew_1)
      state = { health: 1.0, fatigue: 1.0, injury: nil }

      expect(minion.pace(state)).to eq(0.0)
    end

    it "slows a walk the more tired the walker is" do
      minion = rig.minions.fetch(:crew_1)
      fresh = minion.pace({ health: 1.0, fatigue: 0.0, injury: nil })
      tired = minion.pace({ health: 1.0, fatigue: 0.6, injury: nil })

      expect(tired).to be < fresh
      expect(fresh).to be_within(1e-9).of(1.0)
    end
  end

  # A high `time_scale` means a single tick can be minutes of walking, so a tick has to be able
  # to cross a whole passage and keep going. Discarding the remainder at each place would cap
  # travel at one passage per tick however long the tick was.
  it "carries distance over between passages within one tick" do
    op = rig(time_scale: 400.0)
    op.assign_minion(:crew_1, :onsetting)
    op.step!(tick: 1)

    # dt = 100 s, which is past bank -> pit_top (33.3 s) and well into the ladderway.
    expect(crew(op, :crew_1)[:place]).to be(:pit_top)
    expect(crew(op, :crew_1)[:progress]).to be > 0.0
  end

  # **A walk of several minutes has to look like one.** `progress` is metres into the passage
  # currently being walked and resets at every place, so a bar drawn from it runs backwards
  # three times on the way to the face. `journey` and `remaining` are the whole route.
  describe "how far along they are" do
    def fraction(op, seat)
      op.minions.fetch(seat).journey_fraction(crew(op, seat))
    end

    it "is nothing at all for somebody standing at their post" do
      op = rig
      expect(fraction(op, :crew_1)).to eq(0.0)
      expect(crew(op, :crew_1)[:remaining]).to eq(0.0)
    end

    it "counts down the whole route rather than the passage being walked" do
      op = rig
      op.assign_minion(:crew_1, :onsetting)
      op.step!(tick: 1)

      # bank -> pit_top -> pit_bottom is 40 m and then 60 m.
      expect(crew(op, :crew_1)[:journey]).to be_within(1e-6).of(100.0)
    end

    # The claim the design exists for: crossing into pit_top does not restart the bar.
    it "rises without ever going backwards, across a route with a place in the middle" do
      op = rig
      op.assign_minion(:crew_1, :onsetting)
      seen = (1..40).map { |i| op.step!(tick: i); [ fraction(op, :crew_1), crew(op, :crew_1)[:station] ] }
      walking = seen.take_while { |_, station| station.nil? }.map(&:first)

      expect(crew(op, :crew_1)[:place]).to be(:pit_bottom)   # the middle place was crossed
      expect(walking.each_cons(2).all? { |a, b| b >= a }).to be(true)
      expect(walking.first).to be < 0.2
      expect(walking.last).to be > 0.9
    end

    it "clears when they take up the post" do
      op = rig
      seconds_to_arrive(op, :crew_1, :banking)

      expect(crew(op, :crew_1)[:journey]).to eq(0.0)
      expect(crew(op, :crew_1)[:remaining]).to eq(0.0)
    end

    # Sent somewhere farther mid-walk, the bar has to start again rather than read past full —
    # which is what the high-water mark buys, and it needs no memory of where they set off from.
    it "starts again for somebody re-ordered farther on" do
      op = rig
      op.assign_minion(:crew_1, :banking)
      # Four ticks of a forty-metre walk, so they are most of the way there and not yet posted.
      4.times { |i| op.step!(tick: i + 1) }
      near = fraction(op, :crew_1)

      op.assign_minion(:crew_1, :onsetting)
      op.step!(tick: 20)

      expect(near).to be > 0.5
      expect(fraction(op, :crew_1)).to be < near
      expect(fraction(op, :crew_1)).to be <= 1.0
    end
  end

  describe "the command contract" do
    # `assign_minion` still names a DESTINATION and never a step, which is what lets it ride an
    # at-least-once log with no dedup table (invariants.md §4).
    it "is idempotent when replayed mid-journey" do
      once = rig
      twice = rig
      once.assign_minion(:crew_1, :onsetting)
      twice.assign_minion(:crew_1, :onsetting)

      12.times { |i| once.step!(tick: i + 1); twice.step!(tick: i + 1) }
      twice.assign_minion(:crew_1, :onsetting)
      twice.assign_minion(:crew_1, :onsetting)
      8.times { |i| once.step!(tick: 20 + i); twice.step!(tick: 20 + i) }

      expect(twice.state.fetch(:minions)).to eq(once.state.fetch(:minions))
    end

    it "does not send a walker back to the start when their orders change" do
      op = rig
      op.assign_minion(:crew_1, :onsetting)
      12.times { |i| op.step!(tick: i + 1) }
      part_way = crew(op, :crew_1)

      op.assign_minion(:crew_1, :banking)

      expect(crew(op, :crew_1)[:place]).to be(part_way[:place])
      expect(crew(op, :crew_1)[:progress]).to eq(part_way[:progress])
    end
  end

  describe "snapshot" do
    it "round-trips a journey in progress without losing a symbol" do
      op = rig
      op.assign_minion(:crew_1, :onsetting)
      10.times { |i| op.step!(tick: i + 1) }

      restored = ReactorSim::Operation.from_h(ReactorSim.deep_symbolize(JSON.parse(JSON.generate(op.to_h))))
      state = restored.state.fetch(:minions).fetch(:crew_1)

      # Symbols as values do not survive JSON, and a journey carries three of them.
      expect(state[:posting]).to be(:onsetting)
      expect(state[:place]).to be(:pit_top).or be(:bank)
      expect(state[:station]).to be_nil
      expect(restored.state.fetch(:minions)).to eq(op.state.fetch(:minions))
    end

    it "keeps walking to the same place after a restore" do
      op = rig
      op.assign_minion(:crew_1, :onsetting)
      10.times { |i| op.step!(tick: i + 1) }
      restored = ReactorSim::Operation.from_h(ReactorSim.deep_symbolize(JSON.parse(JSON.generate(op.to_h))))

      40.times { |i| op.step!(tick: 20 + i); restored.step!(tick: 20 + i) }

      expect(restored.state.fetch(:minions)).to eq(op.state.fetch(:minions))
      expect(crew(restored, :crew_1)[:station]).to be(:onsetting)
    end
  end
end
