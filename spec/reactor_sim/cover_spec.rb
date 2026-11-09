# frozen_string_literal: true

require "support/open_pit_rig"
require "support/conservation"

# **The blast warning and taking cover**: a shot that waits on its warning, the places it calls to
# cover, people who heed it or do not, shelters and cabs, and what cover keeps off. Zero ticks for
# the arithmetic, a few from a charged hole for the rest. Relational — no figure here is a tuning
# target.
RSpec.describe ReactorSim::Cover do
  before { allow(ReactorSim::Content).to receive(:default).and_return(OpenPitRig::CONTENT) }

  def pit(loadout = {}) = OpenPitRig.build(id: :pit, seed: 3, loadout: { blasting: :jumper_holes, **loadout })
  def tick(op, ticks = 1) = OpenPitRig.tick(op, ticks)
  def hole(op) = OpenPitRig.node_state(op, :stripping_shot_hole)
  def status(op) = ReactorSim::Nodes::ShotHole::STATUSES.fetch(hole(op).fetch(:status))
  def covered(op) = op.state.fetch(:minions).select { |_, s| ReactorSim::Cover.taken?(s) }.keys

  # The whole shift at work and the stripping face's hole charged, its fire lever just pulled.
  def charged(loadout = {}, posts: {})
    op = OpenPitRig.at_work(pit(loadout))
    op = OpenPitRig.posted(op, **posts) unless posts.empty?
    op = OpenPitRig.seed(op, nodes: { stripping_shot_hole: { charged: true } })
    op.set_control(:stripping_fire, 100.0)
    op
  end

  def at(op, *stations) = op.state.fetch(:minions).select { |_, s| stations.include?(s[:station]) }.keys

  describe "the shot" do
    it "fires on the lever with no warning, and after the warning with one" do
      bare = tick(charged, 4)
      warned = tick(charged({ blast_warning: :horn }), 4)

      expect(status(bare)).to be(:fired)
      expect(status(warned)).to be(:warning)

      tick(warned, 30 * 4)
      expect(status(warned)).to be(:fired)
    end

    it "fires at once and calls nobody, warned unwarned on purpose" do
      op = charged({ blast_warning: :horn })
      op = OpenPitRig.seed(op, nodes: { stripping_shot_hole: { unwarned_pending: true } })
      tick(op, 4)

      expect(status(op)).to be(:fired)
      expect(covered(op)).to be_empty
    end
  end

  describe "who takes cover" do
    it "stops everybody in reach who heeds it, and sets them back to work at the all clear" do
      op = tick(charged({ blast_warning: :horn }), 8)
      under = covered(op)

      expect(under).not_to be_empty
      expect(under).to all(satisfy { |id| op.state.dig(:minions, id, :station) })
      expect(OpenPitRig.node_state(op, :stripping_getting).fetch(:carried_kg))
        .to be < OpenPitRig.node_state(tick(charged, 8), :stripping_getting).fetch(:carried_kg)

      tick(op, 40 * 4)
      expect(covered(op)).to be_empty
      expect(OpenPitRig.node_state(op, :stripping_getting).fetch(:carried_kg)).to be_positive
    end

    it "reaches only the face a shout comes from, and the whole pit for a horn" do
      shout = tick(charged({ blast_warning: :shout }), 8)
      horn = tick(charged({ blast_warning: :horn }), 8)
      ore_gang = at(shout, :ore_getters, :ore_barrowmen)

      expect(covered(shout) & ore_gang).to be_empty
      expect(covered(horn) & at(horn, :ore_getters, :ore_barrowmen)).not_to be_empty
    end

    it "reaches the bank only while the sentries are posted" do
      unposted = tick(charged({ blast_warning: :horn_and_sentries }), 8)
      posted = tick(charged({ blast_warning: :horn_and_sentries }, posts: { blast_sentries: [ :crew_14 ] }), 12)

      expect(covered(unposted) & at(unposted, :bay_1_hands)).to be_empty
      expect(covered(posted) & at(posted, :bay_1_hands)).not_to be_empty
    end

    it "heeds it by a die against how readily somebody misjudges, once a call" do
      expect(described_class.taken(nil, 0.9, 0.2, nil)).to eq(described_class::CROUCH)
      expect(described_class.taken(nil, 0.1, 0.2, nil)).to eq(0.0)
      expect(described_class.taken(0.0, 0.9, 0.2, nil)).to eq(0.0)
      expect(described_class.taken(described_class::CROUCH, 0.1, 0.2, nil)).to eq(described_class::CROUCH)
    end

    it "is less heeded by a boneheaded hand than a sound one" do
      daft = OpenPitRig.content(OpenPitRig::NAVVY.merge(tags: OpenPitRig::NAVVY.fetch(:tags).merge(boneheaded: 1.0)))
      sound_pit = OpenPitRig.build(id: :pit, seed: 3)
      daft_pit = OpenPitRig.build(id: :pit, seed: 3, content: daft)
      misjudges = lambda { |op|
        op.minions.values.first.misjudges(op.state.dig(:minions, op.minions.keys.first), ambient: { darkvision: 1.0 })
      }
      heeded = ->(m) { (0...100).count { |i| described_class.taken(nil, i / 100.0, m, nil).positive? } }

      expect(heeded.(misjudges.(daft_pit))).to be < heeded.(misjudges.(sound_pit))
    end
  end

  describe "what keeps it off" do
    let(:flyrock) { ReactorSim::Peril.new(id: :rocks, wounds: { impact: 1.0 }, severity: 1.0, rate: 100.0, sheltered: true) }
    let(:slip) { ReactorSim::Peril.new(id: :slip, wounds: { impact: 1.0 }, severity: 1.0, rate: 100.0) }

    def spent(peril, cover)
      op = pit
      minion = op.minions.values.first
      ReactorSim::Blunder.spend({ peril => 1.0 }, minion, op.state.dig(:minions, minion.id), 0.25, cover: cover).first
    end

    it "keeps a sheltered peril off by its cover, and nothing else" do
      expect(spent(flyrock, described_class::CROUCH)).to be < spent(flyrock, 0.0)
      expect(spent(flyrock, ReactorSim::Nodes::Shelter::TIMBER)).to be < spent(flyrock, described_class::CROUCH)
      expect(spent(slip, ReactorSim::Nodes::Shelter::TIMBER)).to eq(spent(slip, 0.0))
    end

    it "seats a shelter's share of those taking cover, and the rest crouch" do
      op = tick(charged({ blast_warning: :horn, blast_shelters: :timber_shelters }), 8)
      bench = op.state.fetch(:minions).select { |_, s| s[:place] == :stripping_bench && described_class.taken?(s) }
      sheltered = bench.count { |_, s| s.fetch(:cover) > described_class::CROUCH }

      expect(sheltered).to be <= ReactorSim::Parts.fetch(:timber_shelters).stats.fetch(:seats)
      expect(sheltered).to be_positive
    end

    it "leaves an engine's crew at their posts under its cab, a better cab the more cover" do
      shovel = { stripping_shovel_dipper: :yard_dipper }
      op = OpenPitRig.posted(pit({ blast_warning: :horn, **shovel }), stripping_getters: %i[crew_1 crew_2])
      op = OpenPitRig.seed(op, nodes: { stripping_shot_hole: { charged: true } })
      op.set_control(:stripping_fire, 100.0)
      tick(op, 8)
      crew = at(op, :stripping_shovel_stoking, :stripping_shovel_driving)
      cover = ->(cab) { pit({ **shovel, stripping_shovel_cab: cab }).nodes.fetch(:stripping_shovel_cab).cover }

      expect(crew).not_to be_empty
      expect(covered(op) & crew).to be_empty
      expect(cover.(:open_cab)).to be > described_class::CROUCH
      expect(cover.(:wooden_cab)).to eq(ReactorSim::Nodes::Shelter::TIMBER)
      expect(cover.(:steel_cab)).to eq(ReactorSim::Nodes::Shelter::STEEL)
    end
  end

  describe "the books" do
    it "replays bit for bit through a warning and its shot" do
      loadout = { blast_warning: :shout }
      straight = tick(charged(loadout), 80)
      resumed = OpenPitRig.seed(tick(charged(loadout), 40))
      40.times do |t|
        resumed.receive_supply(:line_shaft, OpenPitRig::SUPPLY_J)
        resumed.step!(tick: t + 41)
      end

      expect(ReactorSim.canonical(resumed.state)).to eq(ReactorSim.canonical(straight.state))
    end
  end
end
