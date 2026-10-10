# frozen_string_literal: true

require "reactor_sim"
require "json"
require "support/pit_rig"

# **Carrying somebody out, and the weight of everything.**
#
# Two mechanics that turned out to be one. A rescue is a carrier posted to a *person* rather than
# to a lever, who picks them up on arrival and walks slower for it; and because gear has mass, the
# same arithmetic charges everybody for what they are wearing. One concept, two sources, and the
# arithmetic cannot tell them apart.
#
# Nearly everything here is a **relationship rather than a figure** — `Burden::LIFT_KG` and `DRAG`
# are first guesses and the shapes are the contract. The exceptions are the two refusals, which are
# about whether a thing can happen at all.
#
# See `docs/design_sketches/carrying.md`.
module Carriers
  # Three frames, so a comparison is a comparison of size. The figures are the content's rather
  # than invented ones: a kobold really is 25 kg at a `strength` of 0.7 in `races.yml`.
  #
  # **`strength` is a strength-to-weight ratio**, so the ogre's being the *lowest* here is the
  # point — he is worse pound-for-pound than the hand beside him and overwhelming anyway, because
  # `force` multiplies the ratio by half a tonne of body.
  SIZES = { hand: { mass: 70.0, strength: 1.0 },
            kobold: { mass: 25.0, strength: 0.7 },
            ogre: { mass: 500.0, strength: 0.65 } }.freeze

  def self.archetype(size)
    { label: size.to_s.capitalize, mass_kg: SIZES.fetch(size).fetch(:mass),
      strength: SIZES.fetch(size).fetch(:strength), toughness: 1.0, endurance: 1.0e6,
      intelligence: 1.0, dexterity: 1.0, charisma: 1.0,
      tags: { mining_effectiveness: 0.6, shovelling: 0.5, darkvision: 0.8 } }
  end

  CONTENT = ReactorSim::Content.default.merging(
    archetypes: SIZES.keys.to_h { |size| [ :"arch_#{size}", archetype(size) ] },
    minions: SIZES.keys.to_h { |size|
      [ :"a_#{size}", { name: size.to_s, archetype: :"arch_#{size}", hireable: false } ]
    }
  )
end

RSpec.describe ReactorSim::Burden do
  include PitRig

  before { allow(ReactorSim::Content).to receive(:default).and_return(Carriers::CONTENT) }

  def body(size, worn: 0.0, tags: {})
    ReactorSim::Minion.new(id: :"a_#{size}", name: size.to_s, worn_kg: worn, tags: tags,
                           **Carriers.archetype(size).slice(:mass_kg).merge(
                             stats: Carriers.archetype(size).slice(*ReactorSim::Sheet::STATS)
                           ))
  end

  def fresh(carrying: []) = { health: 1.0, fatigue: 0.0, carrying: carrying }

  describe "what a burden costs" do
    # **The upgrade axis mass exists to create.** Nothing here is about rescue: the same kit on a
    # smaller frame is a bigger burden, so a lighter tool that is worse at its job is a real
    # trade rather than a strictly worse choice. That is what lets a player specialise an account
    # full of kobolds.
    it "costs a small worker more pace than a large one for the identical kit" do
      kit = 6.5
      small = described_class.ratio(body(:kobold, worn: kit), fresh, {})
      large = described_class.ratio(body(:hand, worn: kit), fresh, {})

      expect(small).to be > large * 2.0
    end

    it "costs less in lighter gear that is otherwise the same" do
      heavy = described_class.ratio(body(:kobold, worn: 6.5), fresh, {})
      light = described_class.ratio(body(:kobold, worn: 4.0), fresh, {})

      expect(described_class.pace_factor(light)).to be > described_class.pace_factor(heavy)
    end

    it "slows nobody who is carrying nothing at all" do
      expect(described_class.pace_factor(described_class.ratio(body(:hand), fresh, {}))).to eq(1.0)
    end

    # Monotonic rather than pinned: the figure is a first guess, the direction is the contract.
    it "never speeds anybody up, however the load is made" do
      factors = [ 0.0, 0.1, 0.5, 1.0, 4.0, 40.0 ].map { |r| described_class.pace_factor(r) }

      expect(factors).to eq(factors.sort.reverse)
      expect(factors.last).to be_positive
    end
  end

  describe "what can be lifted" do
    # **The two cases the whole design is calibrated around**, and the only ones asserted as a
    # yes or a no rather than as a relationship — because "can this happen at all" is a different
    # kind of claim from "how much does it cost".
    it "lets a large worker take several small ones" do
      ogre = body(:ogre)
      six = (1..6).to_h { |i| [ :"k#{i}", body(:kobold) ] }
      state = fresh(carrying: six.keys)

      expect(described_class.load_kg(ogre, state, six)).to be <= described_class.lift_kg(ogre, fresh)
    end

    it "refuses a small worker a large one outright" do
      kobold = body(:kobold)

      expect(described_class.liftable?(kobold, fresh, {}, body(:ogre))).to be(false)
    end

    it "counts somebody's own gear against what they can still lift" do
      bare = described_class.liftable?(body(:hand), fresh, {}, body(:hand))
      laden = described_class.liftable?(body(:hand, worn: 70.0), fresh, {}, body(:hand))

      expect(bare).to be(true)
      expect(laden).to be(false)
    end

    # **The claim the whole refactor exists for.** An ogre is worse pound-for-pound than a hand —
    # a lower `strength` — and lifts far more anyway, because `force` multiplies the ratio by the
    # body. Asserting both halves together is what stops somebody "fixing" the ratio upward.
    it "lets a worse pound-for-pound worker lift far more, if there is more of them" do
      ogre = body(:ogre)
      hand = body(:hand)

      expect(ogre.strength).to be < hand.strength
      expect(described_class.lift_kg(ogre, fresh)).to be > described_class.lift_kg(hand, fresh) * 4
    end

    # **A large race can just rescue its own, and only just.** One ogre is inside an ogre's limit
    # by a slim margin; two are not, and nothing smaller can take one at all. Three claims about
    # one number, which is what makes the margin deliberate rather than incidental.
    it "lets a large worker carry one of its own kind and no more" do
      ogre = body(:ogre)
      two = { a: body(:ogre), b: body(:ogre) }

      expect(described_class.liftable?(ogre, fresh, {}, body(:ogre))).to be(true)
      expect(described_class.load_kg(ogre, fresh(carrying: two.keys), two))
        .to be > described_class.lift_kg(ogre, fresh)
      expect(described_class.liftable?(body(:hand), fresh, {}, body(:ogre))).to be(false)
    end

    # A stretcher is **gear rather than a fitting** — a tag and a mass in one of three slots,
    # competing with a lamp and a respirator, which is a decision rather than a free upgrade.
    it "lets a stretcher carry what bare hands cannot" do
      alone = described_class.lift_kg(body(:kobold), fresh)
      helped = described_class.lift_kg(body(:kobold, tags: { stretcher: 0.5 }), fresh)

      expect(helped).to be > alone
    end

    # `effective` rather than the raw stat, so this needs no code of its own.
    it "lets a hurt worker lift less than a sound one" do
      hurt = { health: 1.0, fatigue: 0.0, carrying: [], injury: :severe }

      expect(described_class.lift_kg(body(:hand), hurt))
        .to be < described_class.lift_kg(body(:hand), fresh)
    end
  end

  # **The bug this mechanic shipped with, in the one shape that catches it.**
  describe "carrying is not resting" do
    # Asserted with the LIGHTEST casualty available, deliberately. Accrual and recovery *net*, so
    # a heavy load out-accrues `BASE_RECOVERY` on its own and would pass with the recovery gate
    # missing entirely — it is only the light case that distinguishes a gate from a bigger number.
    it "tires somebody holding even the lightest casualty" do
      carrier = body(:hand)
      cargo = { k: body(:kobold) }
      state = { health: 1.0, fatigue: 0.5, carrying: [ :k ] }
      burden = described_class.ratio(carrier, state, cargo)

      after = ReactorSim::Fatigue.advance(carrier, state, control: nil, dt: 60.0, burden: burden)

      expect(after.fetch(:fatigue)).to be > state.fetch(:fatigue)
    end

    it "rests somebody standing in the same place with their hands empty" do
      carrier = body(:hand)
      state = { health: 1.0, fatigue: 0.5, carrying: [] }

      after = ReactorSim::Fatigue.advance(carrier, state, control: nil, dt: 60.0)

      expect(after.fetch(:fatigue)).to be < state.fetch(:fatigue)
    end

    # Armour you can rest off; a body you cannot. The gate keys on carrying a *person*, never on
    # the weight, which is the same split `ControlPoint#recovery` already draws.
    it "still rests somebody who is merely wearing something heavy" do
      carrier = body(:hand, worn: 25.0)
      state = { health: 1.0, fatigue: 0.5, carrying: [] }
      burden = described_class.ratio(carrier, state, {})

      after = ReactorSim::Fatigue.advance(carrier, state, control: nil, dt: 60.0, burden: burden)

      expect(after.fetch(:fatigue)).to be < state.fetch(:fatigue)
    end
  end

  # The loop, in a real pit, because everything above is arithmetic and none of it proves that a
  # posting can name a person.
  describe "a rescue" do
    before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

    # Somebody underground, and somebody at bank who can be sent to fetch them.
    #
    # **The carrier's journey is real and stays real** — a rescue *is* travel, so there is nothing
    # to construct there, only the mechanic. What is constructed is the **casualty's** arrival,
    # which is a precondition and used to cost 900 ticks of watching a hewer walk.
    #
    # **And the casualty is put at the pit bottom rather than the face**, which is the same claim
    # over a road a fifth as long: fetched on tick 168 and home at +292, against 835 and more than
    # 1,500 from the district. Note the carry back is slower than the walk out either way, because
    # carrying somebody is a burden — which is the point of the whole file.
    def pit_with_a_casualty
      casualty(build_pit(id: "c", seed: 3, loadout: { manriding: :cage_gear }))
    end

    # The tick number is tracked here rather than read back off the operation, which does not keep
    # one — and it has to keep counting across calls, or the replay example steps two runs through
    # different tick numbers and the digests cannot match.
    def casualty(op)
      ready = at_the_face(op, hewing: nil, haulage: :crew_1, timbering: nil)
      levers!(ready, winding: 100, man_winding: 100, haulage: 100)
      @tick = 0
      ready
    end

    def step_on!(op, ticks = 1)
      events = run!(op, ticks, from: @tick)
      @tick += ticks
      events
    end

    def walk_until(op, limit: 600)
      events = []
      limit.times do
        events.concat(step_on!(op))
        break if yield(op)
      end
      events
    end

    def crew_of(op, id) = op.state.fetch(:minions).fetch(id)

    it "fetches somebody, carries them out, and puts them down where it is told" do
      op = pit_with_a_casualty
      expect(crew_of(op, :crew_1)[:place]).to be(:pit_bottom)

      expect(op.assign_minion(:crew_2, :crew_1)).to be(true)
      events = walk_until(op) { |o| crew_of(o, :crew_2)[:carrying].any? }

      expect(crew_of(op, :crew_2)[:carrying]).to eq([ :crew_1 ])
      expect(events.map { |e| e[:type] }).to include(:minion_carried)

      # **The fetch order is consumed**, because holding somebody is not a job — a minion id left
      # in `station` reads as a lever to `tire` and as a post to the panel.
      expect(crew_of(op, :crew_2)[:posting]).to be_nil
      expect(crew_of(op, :crew_2)[:station]).to be_nil

      op.assign_minion(:crew_2, :quarters)
      walk_until(op) { |o| crew_of(o, :crew_2)[:place] == :bank }

      expect(crew_of(op, :crew_1)[:place]).to be(:bank), "the cargo came too"
      expect(op.drop_minion(:crew_1)).to be(true)
      expect(crew_of(op, :crew_2)[:carrying]).to be_empty
    end

    # **A casualty stops working the moment somebody has them.** Without this they hew all the way
    # to the pit bank and walk straight back to the face when set down.
    it "takes the casualty off their post" do
      op = pit_with_a_casualty
      op.assign_minion(:crew_2, :crew_1)
      walk_until(op) { |o| crew_of(o, :crew_2)[:carrying].any? }
      step_on!(op, 2)

      expect(crew_of(op, :crew_1)[:station]).to be_nil
      expect(crew_of(op, :crew_1)[:posting]).to be_nil
    end

    it "is refused where it would make no sense" do
      op = pit_with_a_casualty

      expect(op.assign_minion(:crew_2, :crew_2)).to be(false), "carrying yourself"
      expect(op.assign_minion(:crew_2, :nobody_at_all)).to be(false), "carrying a stranger"
      expect(op.drop_minion(:crew_1)).to be(false), "dropping somebody nobody holds"
    end

    # **Both halves of the protocol, which is why `drop_minion` names the person and not the
    # carrier.** The command log is at-least-once and unordered, so redelivery has to be a no-op.
    # **Seeded through the MATCH**, because `digest` fingerprints the match's own copy of its
    # operations — seeding the operation alone would leave the match holding a pit whose casualty
    # never went underground, and the digests would then agree about the wrong thing.
    it "replays bit for bit with a fetch and a drop delivered twice" do
      digests = Array.new(2) do
        built = build_match(id: "c", seed: 3, loadout: { manriding: :cage_gear })
        match = seed_match(built, :pit,
                           minions: at_the_face_minions(built.operation(:pit), hewing: nil,
                                                        haulage: :crew_1, timbering: nil))
        op = match.operation(:pit)
        levers!(op, winding: 100, man_winding: 100, haulage: 100)
        @tick = 0

        2.times { op.assign_minion(:crew_2, :crew_1) }
        walk_until(op) { |o| crew_of(o, :crew_2)[:carrying].any? }
        2.times { op.drop_minion(:crew_1) }
        step_on!(op, 50)
        match.digest
      end

      expect(digests.first).to eq(digests.last)
    end

    it "brings a carried minion back from a snapshot as a Symbol" do
      op = pit_with_a_casualty
      op.assign_minion(:crew_2, :crew_1)
      walk_until(op) { |o| crew_of(o, :crew_2)[:carrying].any? }

      restored = ReactorSim::Operation.from_h(
        ReactorSim.deep_symbolize(JSON.parse(JSON.generate(op.to_h)))
      )

      # `be`, never `eq`: `:crew_1` and `"crew_1"` are the same string to the digest, so only an
      # identity assertion finds the seventh instance of this trap.
      expect(restored.state.dig(:minions, :crew_2, :carrying).first).to be(:crew_1)
    end
  end
end
