# frozen_string_literal: true

require "reactor_sim"
require "json"

# The roster: who is standing at each lever, and how they got there.
#
# **This is the file that guards the change with the quietest failure mode in the release.** A
# crew that can be hired, injured or dismissed is a loadout by another name, so it has to ride in
# `options:` — and everything in `options:` goes through JSON, where every id is a String and
# every deliberately-empty equipment slot is a missing key. A roster that fails to normalise
# restores a different crew, wearing different kit, without raising anything.
#
# `definition.rb` carried the warning for a release before it was acted on: *"the moment a crew
# can be hired, injured or dismissed it must move into `options:`, or a restored snapshot
# rebuilds a different crew."*
RSpec.describe ReactorSim::Crew do
  def engine(crew: {}, seed: 42)
    ReactorSim::Match.create(
      id: "c", seed: seed,
      operations: [ { id: :eng, type: :steam_engine, crew: crew } ]
    )
  end

  def round_trip(match) = ReactorSim::Match.from_h(JSON.parse(JSON.generate(match.to_h)))

  describe "resolving a posting" do
    let(:content) { ReactorSim::Content.default }

    # Four layers, each offsetting the last: race, individual, training, equipment.
    it "folds all four layers into one sheet" do
      sheet = described_class.resolve(
        { minion: :jim, training: [ :hot_work_ticket ], tool: :stokers_shovel,
          gear: :leather_apron }, content: content
      )

      # human 1.0 + Jim 0.15 + shovel 0.2
      expect(sheet[:stats][:strength]).to be_within(1e-9).of(1.35)
      # human 1.0 + the ticket's 0.2
      expect(sheet[:stats][:toughness]).to be_within(1e-9).of(1.2)
      # the ticket's 0.2 and the apron's 0.3, added rather than maxed
      expect(sheet[:tags][:heat_resistance]).to be_within(1e-9).of(0.5)
    end

    it "carries a tag that only one layer supplies" do
      sheet = described_class.resolve({ minion: :jim, tool: :stokers_shovel }, content: content)

      expect(sheet[:tags]).to include(practised: true, shovelling: 0.5)
    end

    # **An unfilled role is not an empty one.** Somebody turns up — which is what makes a slot
    # nobody chose and a minion on the injury list the same thing to the engine.
    it "fills an empty posting with the standin" do
      sheet = described_class.resolve({}, content: content)

      expect(sheet[:minion]).to be(described_class::STANDIN)
      expect(sheet[:tags]).to include(:clumsy, :unlicensed)
    end

    it "treats a nil posting the same way" do
      expect(described_class.resolve(nil, content: content)[:minion])
        .to be(described_class::STANDIN)
    end

    # The standin is drawn in any number, and four crew all called "Day-Labourer" reads as one
    # entry repeated rather than as a gang of people.
    it "lets a name be overridden without changing who they are" do
      sheet = described_class.resolve({ name: "Grib" }, content: content)

      expect(sheet[:name]).to eq("Grib")
      expect(sheet[:minion]).to be(described_class::STANDIN)
    end

    # Checking only that the slot *exists* would let a pair of gloves be posted as a tool and
    # silently grant its bonus from the wrong place — and a pre-match screen offering the wrong
    # list would then be wrong in a way nothing complained about.
    it "refuses an item fitted in a slot it does not belong to" do
      expect { described_class.resolve({ tool: :leather_apron }, content: content) }
        .to raise_error(ReactorSim::Error, /is gear and cannot be fitted as tool/)
    end

    # Clamping between layers would make their ORDER matter: a penalty floored at zero before a
    # bonus landed would give a different worker from the same kit applied the other way round.
    it "settles a stat at zero rather than letting it go negative" do
      sheet = described_class.resolve({ minion: described_class::STANDIN, gear: :fettlers_gloves },
                                      content: content)

      expect(sheet[:stats].values).to all(be >= 0.0)
    end

    # `clumsy: -0.15` on the amulet means *less* clumsy, and the floor is what stops it becoming
    # anti-clumsiness. One signed key rather than a second vocabulary for penalties.
    it "reduces a penalty tag toward zero and no further" do
      bare = described_class.resolve({ minion: described_class::STANDIN }, content: content)
      lucky = described_class.resolve(
        { minion: described_class::STANDIN, utility: :lucky_amulet }, content: content
      )

      expect(lucky[:tags][:clumsy]).to be < bare[:tags][:clumsy]
      expect(lucky[:tags][:clumsy]).to be >= 0.0
    end
  end

  describe "the roster in options" do
    it "names every seat, including the ones nobody was posted to" do
      roster = engine(crew: { crew_1: { minion: :jim } }).operation(:eng).options.fetch(:crew)

      expect(roster.keys).to contain_exactly(:crew_1, :crew_2)
    end

    it "puts the resolved crew on the operation" do
      op = engine(crew: { crew_1: { minion: :elowynne }, crew_2: { minion: :galathas } })
           .operation(:eng)

      expect(op.minions.fetch(:crew_1).name).to eq("Elowynne")
      expect(op.minions.fetch(:crew_2).name).to eq("Galathas")
    end

    # Two elves, and not the same worker. The entire argument for an individual layer.
    it "separates two members of one race" do
      op = engine(crew: { crew_1: { minion: :elowynne }, crew_2: { minion: :galathas } })
           .operation(:eng)

      expect(op.minions.fetch(:crew_2).strength)
        .to be > op.minions.fetch(:crew_1).strength
      expect(op.minions.fetch(:crew_2).dexterity)
        .to be < op.minions.fetch(:crew_1).dexterity
    end

    # **The rule the whole release exists for, and it has to be structural.** A machine that lets
    # an effort station be a starting post hands the player a shift already at the face for free.
    it "starts every seat in the quarters, never at a working station" do
      op = engine(crew: { crew_1: { minion: :jim } }).operation(:eng)

      op.minions.each_value do |minion|
        expect(minion.default_station).to be(:quarters)
        expect(op.control_points.fetch(minion.default_station)).not_to be_effort
      end
    end

    # Capacity is bought, not decided by the machine — so a roster naming more seats than the
    # fitted quarters has is a real mismatch and is refused rather than quietly truncated.
    it "refuses a roster naming more seats than the quarters has" do
      expect { engine(crew: { crew_1: {}, crew_2: {}, crew_3: { minion: :jim } }) }
        .to raise_error(ReactorSim::Error, /crew_3/)
    end
  end

  describe "snapshot and restore" do
    let(:posting) do
      { crew_1: { minion: :elowynne, training: [ :boilermans_course ], utility: :ear_defenders },
        crew_2: { minion: :galathas, gear: :fettlers_gloves } }
    end

    it "rebuilds the same crew, not a different one" do
      original = engine(crew: posting)
      20.times { original.step! }
      restored = round_trip(original)

      original.operation(:eng).minions.each do |id, before|
        after = restored.operation(:eng).minions.fetch(id)
        expect(after.name).to eq(before.name)
        expect(after.stats).to eq(before.stats)
        expect(after.tags).to eq(before.tags)
      end
    end

    # **The symbols-as-values trap, and this is the seventh instance.** `deep_symbolize` converts
    # KEYS only, so a minion id, a course id and an item id all come back from JSON as Strings.
    # Identity assertions, never `eq` — the digest cannot catch this, because `canonical` runs
    # through `JSON.generate` where `:jim` and `"jim"` are the same string.
    it "brings every id back as a Symbol" do
      roster = round_trip(engine(crew: posting)).operation(:eng).options.fetch(:crew)

      expect(roster.fetch(:crew_1).fetch(:minion)).to be(:elowynne)
      expect(roster.fetch(:crew_1).fetch(:training).first).to be(:boilermans_course)
      expect(roster.fetch(:crew_1).fetch(:utility)).to be(:ear_defenders)
      expect(roster.fetch(:crew_2).fetch(:gear)).to be(:fettlers_gloves)
    end

    it "keeps the digest identical across the round trip" do
      original = engine(crew: posting)
      20.times { original.step! }

      expect(ReactorSim.canonical(round_trip(original).operation(:eng).to_h))
        .to eq(ReactorSim.canonical(original.operation(:eng).to_h))
    end

    # A slot a player deliberately emptied must not quietly refill itself, which is the same
    # rule `Assembly#loadout` follows for parts — and the reason every seat is named in the
    # stored roster rather than only the ones somebody chose.
    it "does not grow kit back into a slot that was left empty" do
      restored = round_trip(engine(crew: { crew_1: { minion: :jim, tool: :stokers_shovel } }))
      seat = restored.operation(:eng).options.fetch(:crew).fetch(:crew_1)

      expect(seat).not_to have_key(:gear)
      expect(seat).not_to have_key(:utility)
    end

    it "restores the standin for a seat nobody filled" do
      restored = round_trip(engine(crew: { crew_1: { minion: :jim } }))

      expect(restored.operation(:eng).minions.fetch(:crew_2).minion)
        .to be(described_class::STANDIN)
    end
  end
end
