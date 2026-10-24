# frozen_string_literal: true

require "json"
require "reactor_sim"
require "support/reference_crew"

# **Grudges, tempers, and what people do to each other**, with the combat figures and the
# distraction they are fought and watched through. See
# `docs/design_sketches/animosity-and-distraction.md`.
#
# Functions are asserted with no ticks; behaviour from a constructed state in one or two. Every
# claim is a relationship — more callous does more harm, a boss averts some and never all — and no
# tuning figure is pinned.
RSpec.describe "animosity" do
  let(:bench_class) do
    Class.new(ReactorSim::Node) do
      def initialize(perils:, **opts)
        @perils = perils.freeze
        super(**opts)
        freeze
      end

      attr_reader :perils
    end
  end

  def animosity = ReactorSim::Animosity
  def combat = ReactorSim::Combat

  def drum(id = :drum)
    ReactorSim::Nodes::Vessel.new(
      id: id, label: "Drum", volume_m3: 10.0, heat_capacity: 1.0e4,
      ports: [ ReactorSim::Port.new(id: :vent, direction: :inlet, accepts: [ :gas ]) ],
      initial_contents: [ { resource: :air, kg: 12.0 } ]
    )
  end

  # Able to see in the yard, which nothing lights.
  def person(id, place: :yard, stats: {}, tags: {}, mass_kg: ReferenceCrew::HUMAN_KG, archetype: :hand, **rest)
    ReactorSim::Minion.new(id: id, minion: id, archetype: archetype, mass_kg: mass_kg, place: place,
                           stats: ReferenceCrew::PLAIN_STATS.merge(stats), tags: { darkvision: 1.0 }.merge(tags),
                           **rest)
  end

  # A brute and somebody who cannot get out of the way: whatever is tried between them lands.
  def brute(id, stats: {}, **rest) = person(id, stats: { strength: 3.0 }.merge(stats), mass_kg: 500.0, **rest)
  def sitting_duck(id, stats: {}, **rest) = person(id, stats: { agility: 0.01, combat_prowess: 0.0 }.merge(stats), **rest)

  # And the other way round: nothing tried by the first lands on the second.
  def weakling(id, stats: {}, **rest) = person(id, stats: { strength: 0.05, combat_prowess: 0.0 }.merge(stats), mass_kg: 5.0, **rest)
  def wary(id, stats: {}, tags: {}, **rest)
    person(id, stats: { agility: 3.0, combat_prowess: 3.0 }.merge(stats), tags: { defence: 1.0 }.merge(tags), **rest)
  end

  # Two rooms and a way between them, a post with whatever openings a spec gives it, and perhaps
  # a boss over one room.
  def rig(minions, openings: [], perils: [], oversees: nil, state: nil, rngs: nil, seed: 1)
    posts = [ ReactorSim::ControlPoint.new(id: :post, place: :yard, effort: { dexterity: 1.0 },
                                           default: 100.0, capacity: 3, openings: openings),
              ReactorSim::ControlPoint.new(id: :shed_post, place: :shed, effort: { dexterity: 1.0 },
                                           default: 100.0, capacity: 3) ]
    if oversees
      posts << ReactorSim::ControlPoint.new(id: :bossing, place: :yard, effort: { charisma: 1.0 },
                                            default: 100.0, capacity: 1, oversees: oversees)
    end
    ReactorSim::Operation.new(
      id: :rig, type: :test, seed: seed, state: state, rngs: rngs,
      nodes: [ drum, drum(:shed_air), bench_class.new(id: :bench, perils: perils) ],
      places: [ ReactorSim::Place.new(id: :yard, nodes: %i[drum bench]),
                ReactorSim::Place.new(id: :shed, nodes: %i[shed_air]) ],
      passages: [ ReactorSim::Passage.new(a: :yard, b: :shed, metres: 10.0, speed_m_s: 1.0) ],
      control_points: posts, minions: minions
    )
  end

  # The same rig from its own snapshot, through JSON, with some minions' fields replaced.
  def with(op, minions, seed: 1, **fields)
    snapshot = ReactorSim.deep_symbolize(JSON.parse(JSON.generate(op.to_h)))
    raw = snapshot.fetch(:state)
    patched = raw.merge(minions: raw.fetch(:minions).to_h { |id, s| [ id, s.merge(fields.fetch(id, {})) ] })
    rig(minions, openings: op.control_points.fetch(:post).openings, seed: seed,
                 perils: op.nodes.fetch(:bench).perils, oversees: op.control_points[:bossing]&.oversees,
                 state: patched, rngs: snapshot.fetch(:rngs).to_h { |name, s| [ name, ReactorSim::Rng.new(s) ] })
  end

  def held(op, holder, target) = op.state.dig(:minions, holder, :grudges, target).to_f

  def types(events) = events.map { |e| e[:type] }

  describe "grudges" do
    it "adds the race's, the person's, who resents them and the account's, and caps at a whole grudge" do
      dwarf = person(:urist, archetype: :dwarf, grudges: { elf: 0.4, galathas: 0.3 })
      elf = person(:galathas, archetype: :elf, resented_by: { dwarf: 0.2 })
      table = animosity.table([ dwarf, elf ], { urist: { galathas: 0.2 } })

      expect(table.dig(:urist, :galathas)).to eq(1.0)
      expect(animosity.table([ dwarf, elf ]).dig(:urist, :galathas)).to be < 1.0
      expect(table.dig(:galathas, :urist)).to be_nil
    end

    it "refuses a grudge against a race or a person nobody has heard of" do
      human = { label: "Human", mass_kg: 70.0, tags: {}, grudges: { goblin: 0.4 },
                **ReactorSim::Sheet::STATS.to_h { |s| [ s, 1.0 ] } }

      expect { ReactorSim::Content.build(archetypes: { human: human }) }.to raise_error(ReactorSim::Error, /goblin/)
    end

    it "fades between matches, slower for the spiteful and faster for the forgiving" do
      neutral = animosity.faded(0.5, {})

      expect(animosity.faded(0.5, { spiteful: 0.5 })).to be > neutral
      expect(animosity.faded(0.5, { forgiving: 0.5 })).to be < neutral
    end
  end

  describe "temperament" do
    it "reads each trait against its opposite, steeply" do
      short = person(:a, tags: { short_tempered: 0.5 })
      calm = person(:b, tags: { even_tempered: 0.5 })

      expect(animosity.temper(short)).to be > animosity.temper(person(:c))
      expect(animosity.temper(person(:c))).to be > animosity.temper(calm)
    end

    it "is willing to do more harm the deeper the grudge and the more callous, and violence feeds both" do
      callous = person(:a, tags: { callous: 0.5 })
      kindly = person(:b, tags: { kindly: 0.5 })
      violent = person(:c, tags: { violent_nature: 0.5 })

      expect(animosity.ceiling(callous, 0.5)).to be > animosity.ceiling(kindly, 0.5)
      expect(animosity.ceiling(person(:d), 0.8)).to be > animosity.ceiling(person(:d), 0.4)
      expect(animosity.temper(violent)).to be > animosity.temper(person(:d))
      expect(animosity.ceiling(violent, 0.5)).to be > animosity.ceiling(person(:d), 0.5)
    end

    it "brawls with somebody they hold nothing against, and may draw, only when violent" do
      violent = person(:a, tags: { violent_nature: 0.3 })
      plain = person(:b)

      expect(animosity.willing?(violent, 0.0, animosity::BRAWL_HARM, 0)).to be(true)
      expect(animosity.willing?(plain, 0.0, animosity::BRAWL_HARM, 0)).to be(false)
      expect(animosity.escalation(violent, 0.0)).to be_positive
      expect(animosity.escalation(plain, 0.0)).to eq(0.0)
      expect(animosity.escalation(violent, 0.4)).to be > animosity.escalation(plain, 0.4)
    end

    it "makes an exception of somebody hated, however kind they are to everybody else" do
      kindly = person(:a, tags: { kindly: 0.3 })

      expect(animosity.callousness(kindly, 0.8)).to be > animosity.callousness(kindly)
      expect(animosity.ceiling(kindly, 0.8)).to be > 2.0 * animosity.ceiling(kindly, 0.4)
    end

    it "takes an opening a kindly hand declines when callous, and a conscientious one spares bystanders" do
      harm = animosity.ceiling(person(:n), 1.0)

      expect(animosity.willing?(person(:a, tags: { callous: 0.5 }), 1.0, harm, 0)).to be(true)
      expect(animosity.willing?(person(:b, tags: { kindly: 0.5 }), 1.0, harm, 0)).to be(false)

      careful = person(:c, tags: { conscientious: 0.5, callous: 1.0 })
      expect(animosity.willing?(careful, 1.0, harm, 0)).to be(true)
      expect(animosity.willing?(careful, 1.0, harm, 3)).to be(false)
    end

    it "balks at no harm to somebody they want dead, and still minds who else it catches" do
      murderous = person(:a)
      crushing = 10.0 * animosity::LETHAL

      expect(animosity.ceiling(murderous, 1.0)).to be >= animosity::LETHAL
      expect(animosity.willing?(murderous, 1.0, crushing, 0)).to be(true)
      expect(animosity.willing?(murderous, 1.0, crushing, 3)).to be(false)
      expect(animosity.willing?(murderous, 0.5, crushing, 0)).to be(false)
    end

    it "lets a bonehead do what they would never do, by taking it for harmless" do
      kindly = person(:a, tags: { kindly: 1.0 })

      expect(animosity.willing?(kindly, 0.1, 5.0, 4)).to be(false)
      expect(animosity.willing?(kindly, 0.1, 5.0, 4, harmless: true)).to be(true)
    end
  end

  describe "combat" do
    let(:state) { person(:x).initial_state(ReactorSim::Rng.stream(1, "x")) }

    it "raises attack and defence together with prowess" do
      scrapper = person(:a, stats: { combat_prowess: 2.5 })
      green = person(:b, stats: { combat_prowess: 0.5 })

      expect(scrapper.attack(state)).to be > green.attack(state)
      expect(scrapper.defend(state)).to be > green.defend(state)
    end

    def profile(swing:, precision:, edge: 0.0, wounds: { puncture: 1.0 })
      ReactorSim::Equipment.weapon_profile("spec", { handling: { swing: swing, precision: precision },
                                                     edge: edge, wounds: wounds })
    end

    let(:brute) { person(:a, stats: { strength: 3.0, agility: 0.5, dexterity: 0.5 }, mass_kg: 300.0) }
    let(:quick) { person(:b, stats: { agility: 1.5, dexterity: 1.5 }) }

    # Bulk tells half on whether a blow lands: a brute is no more accurate than a quicker hand.
    it "lands blows by swing and precision together" do
      expect(quick.strike(state)).to be > person(:c).strike(state)
      expect(brute.strike(state) / quick.strike(state)).to be < brute.swing(state) / quick.swing(state)
    end

    # **A weapon asks what it asks of the hand**: a pick the swing, a blade the precision.
    it "hits with a swung weapon by the swing and a placed one by the precision" do
      pick = profile(swing: 0.8, precision: 0.2)
      knife = profile(swing: 0.2, precision: 0.8)

      expect(brute.hits(state, pick)).to be > brute.hits(state, knife)
      expect(quick.hits(state, knife)).to be > quick.hits(state, pick)
      expect(quick.precision(state)).to be > person(:c).precision(state)
    end

    it "makes a better weapon of handling that sums past one, and bare hands a poor one" do
      plain = profile(swing: 0.8, precision: 0.2)
      fine = profile(swing: 1.0, precision: 0.3)

      expect(person(:c).hits(state, fine)).to be > person(:c).hits(state, plain)
      expect(person(:c).hits(state, ReactorSim::Equipment::UNARMED)).to be < person(:c).hits(state, plain)
    end

    # An edge cuts whoever holds it: the same blow, landed, is worse by it.
    it "adds a weapon's edge to the blow whoever holds it" do
      blunt = combat.blow_severity(0.3, 0.0, 0.5, 1.0)

      expect(combat.blow_severity(0.3, 0.3, 0.5, 1.0)).to be > blunt
      expect(combat.blow_severity(0.3, 0.3, 0.5, 0.5)).to be < combat.blow_severity(0.3, 0.3, 0.5, 1.0)
    end

    it "swings one weapon at a time, whichever suits the hand, and only when it means to" do
      pick = profile(swing: 0.8, precision: 0.2, wounds: { puncture: 0.6, impact: 0.4 })
      knife = profile(swing: 0.2, precision: 0.8, wounds: { puncture: 1.0 })
      quick_armed = person(:k, stats: { agility: 1.5, dexterity: 1.5 }, weapons: [ pick, knife ])

      expect(quick_armed.wielding(state, armed: true)).to eq(knife)
      expect(quick_armed.wielding(state)).to eq(ReactorSim::Equipment::UNARMED)
      expect(quick_armed.attack(state, armed: true)).to be > quick_armed.attack(state)
      expect(quick_armed.wounds(state, armed: true)).to eq(puncture: 1.0)
    end

    it "refuses a weapon whose handling names something that is not a stat" do
      expect { ReactorSim::Equipment.weapon_profile("x", { handling: { grip: 1.0 }, wounds: { impact: 1.0 } }) }
        .to raise_error(ReactorSim::Error, /grip/)
    end

    # Precision is a figure a station can ask for, as it can `force` or `swing`.
    it "lets a station work by precision" do
      cutting = { precision: 1.0 }

      expect(quick.capability(state, effort: cutting)).to be > person(:c).capability(state, effort: cutting)
      expect { ReactorSim::ControlPoint.new(id: :rope, effort: cutting) }.not_to raise_error
    end

    it "sums defensive gear" do
      expect(person(:a, tags: { defence: 0.6 }).defend(state)).to be > person(:b, tags: { defence: 0.3 }).defend(state)
    end

    it "grades a blow from glancing to clean by how far the strike beat the defence" do
      expect(combat.landed(1.0, 1.0)).to eq(0.0)
      expect(combat.landed(0.5, 1.0)).to eq(0.0)
      expect(combat.landed(1.2, 1.0)).to be_between(0.0, 1.0).exclusive
      expect(combat.landed(10.0, 1.0)).to eq(1.0)
    end

    it "makes a critical of a strike well past a clean hit's margin, and nothing less" do
      expect(combat::CRITICAL_AT).to be > combat::FULL_AT
      expect(combat.critical?(combat::CRITICAL_AT, 1.0)).to be(true)
      expect(combat.critical?(combat::CRITICAL_AT * 0.95, 1.0)).to be(false)
    end

    # The gap round the armour: past the kit, and through only part of the body's toughness — so a
    # tougher body still takes a piercing blow better than a frail one.
    it "lets a blow that pierces pass the armour and meet only part of the toughness" do
      tough = person(:t, stats: { toughness: 2.0 }, tags: { impact_resistance: 0.5 })
      frail = person(:f, stats: { toughness: 0.5 })
      blow = { wounds: { impact: 2.0 } }
      pierced = blow.merge(pierces: combat::CRITICAL_TOUGHNESS)
      check = ->(minion, harm) { ReactorSim::Injury.check(minion, state, harm, catalogue: ReactorSim::Content.default.wounds, die: 0.0) }
      resisted = ->(minion, harm) { ReactorSim::Injury.resisted(minion, harm, :impact, 1.0) }

      expect(check.(tough, blow)[1]).to be_nil
      expect(check.(tough, pierced).first.fetch(:resilience)).to be < state.fetch(:resilience)
      expect(resisted.(tough, pierced)).to be < resisted.(tough, blow)
      expect(resisted.(tough, pierced)).to be > resisted.(frail, pierced)
    end

    # **A bell, not a tail**: most rolls near the middle, the far ones rare, and the median the
    # figure itself.
    it "rolls most dice near the figure and few far from it" do
      dice = (1..999).map { |i| i / 1000.0 }
      within = Math.exp(combat::CONTEST_SPREAD)
      near = dice.count { |d| combat.rolled(1.0, d).between?(1.0 / within, within) }

      expect(combat.rolled(1.0, 0.5)).to be_within(1e-9).of(1.0)
      expect(near).to be > dice.length * 0.6
      expect(combat.rolled(1.0, 0.999)).to be > combat.rolled(1.0, 0.9)
    end

    # **No race is safe from any other.** Over every pair of dice, a kobold's blow sometimes beats an
    # orc's guard; the orc's beats the kobold's far more often.
    it "leaves even the biggest fighter some risk from the smallest" do
      content = ReactorSim::Content.default
      sheet = ->(id) { content.sheet(id).slice(:stats, :tags, :mass_kg) }
      kobold = ReactorSim::Minion.new(id: :k, **sheet.(:kobold_temp))
      orc = ReactorSim::Minion.new(id: :o, **sheet.(:dalthu))
      dice = (1..49).map { |i| i / 50.0 }
      lit = { darkvision: 1.0 }
      lands = lambda do |from, to|
        dice.product(dice).count do |a, d|
          combat.landed(combat.rolled(from.strike(state), a), combat.rolled(to.defend(state, ambient: lit), d)).positive?
        end
      end

      expect(lands.(kobold, orc)).to be_positive
      expect(lands.(orc, kobold)).to be > lands.(kobold, orc) * 2
    end

    it "needs both the wits to see it coming and the agility to get clear" do
      expect(person(:a, stats: { agility: 0.0 }).avoid(state)).to eq(0.0)
      expect(person(:b, stats: { intelligence: 0.0, dexterity: 0.0 }).avoid(state)).to eq(0.0)
      expect(person(:c).avoid(state, burden: 0.5)).to be < person(:c).avoid(state)
      expect(person(:c).avoid(state, ambient: { distracting: 0.5 })).to be < person(:c).avoid(state)
    end

    it "walks the agile faster, and a load slows them both" do
      quick = person(:a, stats: { agility: 1.3 })

      expect(quick.pace(state)).to be > person(:b).pace(state)
      expect(quick.pace(state, burden: 0.5)).to be < quick.pace(state)
    end

    it "takes the margin of somebody who can get out of the way less readily" do
      careless = ReactorSim::Blunder.susceptibility(person(:a), state, avoid: 0.5)

      expect(ReactorSim::Blunder.susceptibility(person(:a), state, avoid: 1.5)).to be < careless
    end

    it "makes a fight hard work with no rest in it" do
      brawling = state.merge(fight: { melee: :m, clock_s: 0.0, owed: {} })
      worked = ReactorSim::Fatigue.advance(person(:a), state, control: nil, dt: 1.0,
                                                              fighting: animosity.exertion(person(:a), brawling))
      rested = ReactorSim::Fatigue.advance(person(:a), state.merge(fatigue: 0.5), control: nil, dt: 1.0)

      expect(worked.fetch(:fatigue)).to be > state.fetch(:fatigue)
      expect(rested.fetch(:fatigue)).to be < 0.5
      expect(animosity.exertion(person(:a), state)).to eq(0.0)
    end

    # **A weapon is a weight to swing**, against the force behind it: the same pick tires a small
    # weak body far more than a big strong one, and bare hands cost no more than the fight.
    it "tires a fighter by the weight of the weapon against their force" do
      pick = ReactorSim::Equipment.weapon_profile("pick", { handling: { swing: 0.8 }, wounds: { impact: 1.0 } }, mass_kg: 3.0)
      armed = state.merge(fight: { melee: :m, clock_s: 0.0, owed: {}, armed: true })
      fists = state.merge(fight: { melee: :m, clock_s: 0.0, owed: {} })
      small = person(:s, stats: { strength: 0.7 }, mass_kg: 25.0, weapons: [ pick ])
      big = person(:g, stats: { strength: 0.65 }, mass_kg: 500.0, weapons: [ pick ])

      expect(animosity.exertion(small, armed)).to be > animosity.exertion(small, fists)
      expect(animosity.exertion(small, armed)).to be > animosity.exertion(big, armed)
      expect(animosity.exertion(big, fists)).to eq(animosity.exertion(small, fists))
    end

    it "helps a knife job with a knife" do
      knife = person(:a, tags: { cutting: 0.3 })

      expect(knife.capability(state, effort: { dexterity: 1.0 }, aided_by: :cutting))
        .to be > person(:b).capability(state, effort: { dexterity: 1.0 }, aided_by: :cutting)
    end
  end

  describe "distraction" do
    def tick_for(op) = ReactorSim::Tick.new(op, op.state)

    def wits_of(op, id)
      minion = op.minions.fetch(id)
      state = op.state.dig(:minions, id)
      minion.wits(state, ambient: tick_for(op).send(:ambient_for, minion, state))
    end

    let(:arunessa) { person(:arunessa, stats: { charisma: 1.8 }, tags: { distracting: 0.7 }) }

    it "dulls the wits of everybody in the room but the one doing it" do
      beside = rig([ arunessa, person(:hand) ])
      apart = rig([ person(:arunessa, place: :shed, stats: { charisma: 1.8 }, tags: { distracting: 0.7 }), person(:hand) ])

      expect(wits_of(beside, :hand)).to be < wits_of(apart, :hand)
      expect(wits_of(beside, :arunessa)).to eq(wits_of(rig([ arunessa ]), :arunessa))
    end

    it "is worse the more charming and the more there is of it, and blinkers shut it out" do
      state = arunessa.initial_state(ReactorSim::Rng.stream(1, "a"))
      skimpy = person(:s, stats: { charisma: 1.8 }, tags: { distracting: 0.9 })

      expect(skimpy.allure(state)).to be > arunessa.allure(state)
      expect(person(:c, stats: { charisma: 2.5 }, tags: { distracting: 0.7 }).allure(state)).to be > arunessa.allure(state)
      expect(person(:f, tags: { focused: 0.5 }).distraction({ distracting: 1.0 }))
        .to be < person(:g).distraction({ distracting: 1.0 })
    end
  end

  describe "patience" do
    def patience(op, id) = op.state.dig(:minions, id, :patience)

    it "wears only while somebody resented is in the room, and faster for a short temper" do
      together = rig([ person(:a, grudges: { b: 0.5 }), person(:b) ])
      short = rig([ person(:a, grudges: { b: 0.5 }, tags: { short_tempered: 0.5 }), person(:b) ])
      apart = rig([ person(:a, grudges: { b: 0.5 }), person(:b, place: :shed) ])
      before = patience(together, :a)
      [ together, short, apart ].each { |op| op.step!(tick: 1) }

      expect(patience(together, :a)).to be < before
      expect(before - patience(short, :a)).to be > before - patience(together, :a)
      expect(patience(apart, :a)).to be >= patience(together, :a)
    end

    it "wears faster beside somebody annoying and slower beside somebody calming, grudge or none" do
      ops = { annoying: 0.5, calming: 0.5, nil => 0.0 }.to_h do |tag, value|
        [ tag, rig([ person(:a), person(:b, tags: tag ? { tag => value } : {}) ]) ]
      end
      before = patience(ops.fetch(nil), :a)
      ops.each_value { |op| op.step!(tick: 1) }
      spent = ops.transform_values { |op| before - patience(op, :a) }

      expect(spent.fetch(:annoying)).to be > spent.fetch(nil)
      expect(spent.fetch(nil)).to be > spent.fetch(:calming)
    end

    it "wears by the worst of them, not by how many of them there are" do
      one = rig([ person(:a, grudges: { b: 0.5 }), person(:b), person(:c) ])
      two = rig([ person(:a, grudges: { b: 0.5, c: 0.5 }), person(:b), person(:c) ])
      before = patience(one, :a)
      [ one, two ].each { |op| op.step!(tick: 1) }

      expect(before - patience(two, :a)).to be_within(1.0e-12).of(before - patience(one, :a))
    end

    it "spends faster on a deeper grudge" do
      deep = rig([ person(:a, grudges: { b: 0.9 }), person(:b) ])
      shallow = rig([ person(:a, grudges: { b: 0.2 }), person(:b) ])
      before = patience(deep, :a)
      [ deep, shallow ].each { |op| op.step!(tick: 1) }

      expect(before - patience(deep, :a)).to be > before - patience(shallow, :a)
    end

    it "goes for the most resented most often and never only for them" do
      scored = [ [ :b, 3.0 ], [ :c, 1.0 ] ]
      picks = (0...100).map { |i| animosity.pick(scored, i / 100.0) }.tally

      expect(picks.fetch(:b)).to be > picks.fetch(:c)
      expect(picks.fetch(:c)).to be_positive
    end

    # In a fight with each other that is going on: both still angry.
    def busy_with(other) = { patience: 0.0, fight: { melee: :m, clock_s: 100.0, owed: {} } }.merge(other)

    it "joins the fight of somebody already in one, or heckles it, and never starts another" do
      crew = [ brute(:a, grudges: { b: 0.9 }), person(:b, grudges: { d: 0.5 }), person(:d, grudges: { b: 0.5 }) ]
      runs = (1..10).map do |seed|
        op = with(rig(crew, seed: seed), crew, seed: seed, a: { patience: 1.0e-9 }, b: busy_with({}), d: busy_with({}))
        mode = op.step!(tick: 1).find { |e| e[:type] == :quarrel && e[:node] == :a }&.fetch(:mode)
        [ mode, op.state.dig(:minions, :a, :fight, :melee) ]
      end

      expect(runs.map(&:first) - %i[joined heckle]).to be_empty
      expect(runs).to include([ :joined, :m ])
    end

    it "heckles somebody already in a fight from the sidelines, and leaves them in it" do
      crew = [ person(:a, grudges: { b: 0.3 }, tags: { kindly: 0.5 }), person(:b, grudges: { d: 0.5 }), person(:d, grudges: { b: 0.5 }) ]
      op = with(rig(crew), crew, a: { patience: 1.0e-9 }, b: busy_with({}), d: busy_with({}))
      events = op.step!(tick: 1)

      expect(events.find { |e| e[:type] == :quarrel && e[:node] == :a }).to include(mode: :heckle)
      expect(op.state.dig(:minions, :a, :fight)).to include(with: :b)
      expect(op.state.dig(:minions, :b, :fight, :melee)).to be(:m)
      expect(held(op, :b, :a)).to be_positive
    end

    it "comes to a quarrel when it runs out, which stops the two of them" do
      crew = [ person(:a, grudges: { b: 0.5 }), person(:b) ]
      op = with(rig(crew), crew, a: { patience: 1.0e-9 })
      events = op.step!(tick: 1)

      expect(types(events)).to include(:quarrel)
      expect(op.state.dig(:minions, :a, :fight)).not_to be_nil
      expect(op.state.dig(:minions, :b, :fight)).not_to be_nil
    end
  end

  describe "the fight" do
    # Everybody given is in one melee, the exchange due; `fight:` is added to the first one's.
    def melee(crew, seed: 1, **states)
      fight = { melee: :m, clock_s: 0.0, owed: {} }
      fields = crew.to_h { |m| [ m.id, { fight: fight } ] }
      fields.each_key { |id| fields[id] = fields[id].merge(states.fetch(id, {})) }
      with(rig(crew, seed: seed), crew, seed: seed, **fields)
    end

    # As a brawl starts: the one who started it with nothing left of their patience.
    def fighting(holder, target, **fight)
      melee([ holder, target ], holder.id => { patience: 0.0, fight: { melee: :m, clock_s: 0.0, owed: {} }.merge(fight) })
    end

    def in_fight?(op, id) = !op.state.dig(:minions, id, :fight).nil?

    it "lands blows, and leaves a grudge for a wound that carried them out once it is over" do
      op = fighting(brute(:a, grudges: { b: 0.3 }), sitting_duck(:b, stats: { toughness: 0.2 }))
      before = op.state.dig(:minions, :b, :resilience)
      op.step!(tick: 1)

      expect(op.state.dig(:minions, :b, :resilience)).to be < before
      expect(animosity::WOUND_GRUDGE).to have_key(op.state.dig(:minions, :b, :injury))
      op.step!(tick: 2)
      expect(in_fight?(op, :b)).to be(false)
      expect(held(op, :b, :a)).to be_positive
    end

    it "goes on while anybody in it is still willing, whoever started it" do
      crew = [ person(:a), person(:b, grudges: { a: 0.5 }) ]
      full = rig(crew).state.dig(:minions, :a, :patience_full)
      op = melee(crew, a: { patience: full }, b: { patience: 0.0 })
      op.step!(tick: 1)

      expect(in_fight?(op, :a)).to be(true)
      expect(in_fight?(op, :b)).to be(true)
    end

    it "lets somebody nobody wants and who wants nobody step out" do
      crew = [ person(:a, grudges: { b: 0.5 }), person(:b), person(:c) ]
      op = melee(crew, a: { patience: 0.0 })
      before = op.state.dig(:minions, :c, :resilience)
      op.step!(tick: 1)

      expect(in_fight?(op, :c)).to be(false)
      expect(op.state.dig(:minions, :c, :resilience)).to eq(before)
      expect(in_fight?(op, :b)).to be(true)
    end

    it "stops once the one they all hated is carried out, and does not turn on itself" do
      dwarves = %i[a b c].map { |id| person(id, grudges: { x: 0.3 }) }
      op = melee(dwarves + [ person(:x) ], **dwarves.to_h { |d| [ d.id, { patience: 0.0 } ] }, x: { injury: :severe })
      op.step!(tick: 1)

      expect(%i[a b c x].map { |id| in_fight?(op, id) }).to all(be(false))
    end

    it "keeps the violent at each other once nobody they hate is left" do
      crew = [ person(:a, tags: { violent_nature: 0.7 }), person(:b, tags: { violent_nature: 0.7 }) ]
      op = melee(crew, a: { patience: 0.0 }, b: { patience: 0.0 })
      op.step!(tick: 1)

      expect(in_fight?(op, :a) && in_fight?(op, :b)).to be(true)
    end

    it "puts the boot in on somebody carried out when they hate him enough, well short of wanting him dead" do
      kicker = person(:a, grudges: { x: 0.5 })
      scrapper = person(:a, grudges: { x: 0.3 })
      down = { injury: :severe, resilience: 0.0 }
      kicking = melee([ kicker, person(:x) ], a: { patience: 0.0 }, x: down)
      spared = melee([ scrapper, person(:x) ], a: { patience: 0.0 }, x: down)
      [ kicking, spared ].each { |op| op.step!(tick: 1) }

      expect(in_fight?(kicking, :a)).to be(true)
      expect(in_fight?(spared, :a)).to be(false)
      expect(animosity.ceiling(kicker, 0.5)).to be < animosity::LETHAL
    end

    it "kicks a man on the ground bare-handed, and only somebody who wants him dead takes a weapon to him" do
      pick = [ ReactorSim::Equipment.weapon_profile("pick", { handling: { swing: 1.5 }, edge: 1.0, wounds: { puncture: 0.6, impact: 0.4 } }) ]
      armed = { patience: 0.0, fight: { melee: :m, clock_s: 0.0, owed: {}, armed: true } }
      left = ->(grudge) {
        (1..10).flat_map do |seed|
          op = melee([ person(:a, grudges: { x: grudge }, weapons: pick), person(:x) ], seed: seed,
                     a: armed, x: { injury: :severe, resilience: 0.0 })
          op.step!(tick: 1)
          op.state.dig(:minions, :x, :wounds).map { |w| w.fetch(:kind) }
        end
      }

      expect(animosity.ceiling(person(:a), 0.5)).to be < animosity::LETHAL
      expect(animosity.ceiling(person(:a), 1.0)).to be >= animosity::LETHAL
      expect(left.(0.5)).to all(be(:impact))
      expect(left.(1.0)).to include(:puncture)
    end

    it "lets a man on the ground still cover up, so a wary one takes less of a kicking than a sitting duck" do
      kicked = ->(target) {
        (1..20).sum do |seed|
          op = melee([ brute(:a, grudges: { x: 0.5 }), target ], seed: seed,
                     a: { patience: 0.0 }, x: { injury: :severe, resilience: 0.0 })
          op.step!(tick: 1)
          -op.state.dig(:minions, :x, :resilience)
        end
      }

      expect(kicked.(wary(:x))).to be < kicked.(sitting_duck(:x))
    end

    describe "spreading" do
      # A fight between `fighters` with `onlookers` standing by in none; each chance is made certain
      # by its figure, so what is asserted is who it can take and who it never does.
      def watched(fighters, onlookers, seed: 1, oversees: nil, **states)
        fight = { melee: :m, clock_s: 0.0, owed: {} }
        crew = fighters + onlookers
        fields = crew.to_h do |m|
          [ m.id, (fighters.include?(m) ? { fight: fight } : {}).merge(states.fetch(m.id, {})) ]
        end
        with(rig(crew, seed: seed, oversees: oversees), crew, seed: seed, **fields)
      end

      def melee_of(op, id) = op.state.dig(:minions, id, :fight, :melee)

      it "drags in somebody watching whom they hate, who resents it, and a peaceable fighter never does" do
        stub_const("ReactorSim::Animosity::DRAG_IN", 10.0)
        hateful = watched([ person(:a, grudges: { b: 0.5, c: 1.0 }), person(:b) ], [ person(:c) ], a: { patience: 0.0 })
        peaceable = watched([ person(:a, grudges: { b: 0.5 }), person(:b) ], [ person(:c) ], a: { patience: 0.0 })
        [ hateful, peaceable ].each { |op| op.step!(tick: 1) }

        expect(melee_of(hateful, :c)).to be(:m)
        expect(held(hateful, :c, :a)).to be > 0.0
        expect(in_fight?(peaceable, :c)).to be(false)
      end

      it "drags in a heckler, and not the quiet man beside him" do
        stub_const("ReactorSim::Animosity::DRAG_IN", 10.0)
        op = watched([ person(:a, grudges: { b: 0.5 }), person(:b) ], [ person(:h), person(:q) ],
                     a: { patience: 0.0 }, h: { fight: { with: :a, clock_s: 30.0 } })
        op.step!(tick: 1)

        expect(melee_of(op, :h)).to be(:m)
        expect(in_fight?(op, :q)).to be(false)
      end

      it "lets somebody violent pile in, their patience halved, and never somebody gentle" do
        stub_const("ReactorSim::Animosity::SPOILING", 100.0)
        op = watched([ person(:a, grudges: { b: 0.5 }), person(:b) ],
                     [ person(:v, tags: { violent_nature: 1.0 }), person(:g, tags: { gentle: 1.0 }) ],
                     a: { patience: 0.0 }, v: { patience: 1.0, patience_full: 1.0 })
        op.step!(tick: 1)

        expect(melee_of(op, :v)).to be(:m)
        expect(op.state.dig(:minions, :v, :patience)).to be < 1.0
        expect(in_fight?(op, :g)).to be(false)
      end

      it "pulls in somebody near the end of their tether who hates a man in it, and not somebody calm who hates him as much" do
        stub_const("ReactorSim::Animosity::ON_EDGE", 100.0)
        op = watched([ person(:a, grudges: { b: 0.5 }), person(:b) ],
                     [ person(:e, grudges: { b: 0.5 }), person(:c, grudges: { b: 0.5 }) ],
                     a: { patience: 0.0 }, e: { patience: 0.1, patience_full: 1.0 },
                     c: { patience: 1.0, patience_full: 1.0 })
        op.step!(tick: 1)

        expect(melee_of(op, :e)).to be(:m)
        expect(in_fight?(op, :c)).to be(false)
      end

      it "is stopped some of the time by a boss over the place, and never all of it" do
        stub_const("ReactorSim::Animosity::SPOILING", 100.0)
        boss = person(:boss, stats: { charisma: 3.0, intelligence: 2.0, strength: 0.2 })
        runs = (1..40).map do |seed|
          op = watched([ person(:a, grudges: { b: 0.5 }), person(:b) ], [ person(:v, tags: { violent_nature: 1.0 }), boss ],
                       seed: seed, oversees: %i[yard], a: { patience: 0.0 }, boss: { station: :bossing, posting: :bossing })
          op.step!(tick: 1)
        end
        stopped = runs.count { |events| events.any? { |e| e[:type] == :quarrel_averted && e[:mode] == :pile_in } }

        expect(stopped).to be_between(1, runs.length - 1)
      end
    end

    it "is harder to defend against several at once" do
      landed = ->(attackers) {
        (1..20).sum do |seed|
          crew = Array.new(attackers) { |i| person(:"a#{i}", grudges: { x: 0.5 }) } + [ person(:x) ]
          op = melee(crew, seed: seed, **crew.first(attackers).to_h { |m| [ m.id, { patience: 0.0 } ] })
          before = op.state.dig(:minions, :x, :resilience)
          op.step!(tick: 1)
          (before - op.state.dig(:minions, :x, :resilience)) / attackers
        end
      }

      expect(landed.(3)).to be > landed.(1)
    end

    it "lets the one set upon off steam too, and a fighter it has hurt far more" do
      crew = [ person(:a, grudges: { b: 0.5 }), person(:b) ]
      calm = fighting(*crew)
      knocked = with(calm, crew, b: { injury: :minor })
      low = { patience: 0.1 }
      calm = with(calm, crew, b: low)
      knocked = with(knocked, crew, b: low)
      [ calm, knocked ].each { |op| op.step!(tick: 1) }

      expect(calm.state.dig(:minions, :b, :patience)).to be > 0.1
      expect(knocked.state.dig(:minions, :b, :patience)).to be > calm.state.dig(:minions, :b, :patience)
    end

    it "stops once nobody in it is willing, whether or not anything landed, and leaves nothing new" do
      crew = [ weakling(:a, grudges: { b: 0.5 }), wary(:b) ]
      op = fighting(*crew)
      full = op.state.dig(:minions, :a, :patience_full)
      op = with(op, crew, a: { patience: full * animosity::SATED * 0.999 })
      2.times { |i| op.step!(tick: i + 1) }

      expect(in_fight?(op, :a)).to be(false)
      expect(in_fight?(op, :b)).to be(false)
      expect(held(op, :b, :a)).to eq(0.0)
    end

    it "works nothing while it lasts, and holds an order to go elsewhere until it is over" do
      crew = [ person(:a, grudges: { b: 0.5 }), person(:b) ]
      op = fighting(*crew, clock_s: 100.0)
      op.assign_minion(:a, :post)
      op.assign_minion(:b, :shed_post)
      2.times { |i| op.step!(tick: i + 1) }

      expect(op.state.dig(:minions, :b)).to include(posting: :shed_post, place: :yard)
      expect(ReactorSim::Tick.new(op, op.state).send(:crews)).not_to have_key(:post)
    end

    it "reaches for what is in hand far more readily the more willing to kill" do
      orc = person(:o, tags: { callous: 0.2, violent_nature: 0.3 })

      expect(animosity.escalation(orc, 0.8)).to be > animosity.escalation(orc, 0.4)
      expect(animosity.escalation(orc, 0.4)).to be_between(0.0, 1.0).exclusive
      expect(animosity.escalation(person(:k, tags: { kindly: 0.5 }), 0.4)).to be < animosity.escalation(orc, 0.4)
    end

    it "answers a weapon drawn on them in kind, whatever their temper" do
      gentle = person(:g, tags: { kindly: 0.5, gentle: 0.5 })

      expect(animosity.escalation(gentle, 0.0)).to eq(0.0)
      expect(animosity.escalation(gentle, 0.0, threatened: true)).to be >= animosity::ANSWER
      expect(animosity.escalation(gentle, 0.4, threatened: true)).to be > animosity.escalation(gentle, 0.4)
    end

    it "draws on somebody who drew on them at an earlier exchange, and not on somebody who did not" do
      knife = [ ReactorSim::Equipment.weapon_profile("knife", { handling: { precision: 1.0 }, wounds: { puncture: 1.0 } }) ]
      answered = ->(threat) {
        (1..20).count do |seed|
          crew = [ person(:a, grudges: { b: 0.5 }, weapons: knife), person(:b, tags: { gentle: 0.5 }, weapons: knife) ]
          op = melee(crew, seed: seed, a: { patience: 0.0, fight: { melee: :m, clock_s: 0.0, owed: {}, armed: threat } })
          op.step!(tick: 1).any? { |e| e[:type] == :quarrel && e[:mode] == :armed && e[:node] == :b }
        end
      }

      expect(answered.(true)).to be_positive
      expect(answered.(false)).to eq(0)
    end

    it "fights armed when the hatred is deep and callous, and on fists when kind" do
      pick = [ ReactorSim::Equipment.weapon_profile("pick", { handling: { swing: 1.5 }, edge: 1.0, wounds: { puncture: 0.6, impact: 0.4 } }) ]
      callous = fighting(brute(:a, grudges: { b: 1.0 }, tags: { callous: 1.0 }, weapons: pick), sitting_duck(:b, stats: { toughness: 3.0 }))
      kindly = fighting(brute(:a, grudges: { b: 1.0 }, tags: { kindly: 1.0 }, weapons: pick), sitting_duck(:b, stats: { toughness: 3.0 }))
      before = callous.state.dig(:minions, :b, :resilience)
      [ callous, kindly ].each { |op| op.step!(tick: 1) }

      expect(before - callous.state.dig(:minions, :b, :resilience))
        .to be > before - kindly.state.dig(:minions, :b, :resilience)
    end

    it "replays bit for bit from a snapshot taken mid-brawl, the fight still naming who" do
      crew = [ person(:a, grudges: { b: 0.5 }), person(:b) ]
      straight = fighting(*crew, clock_s: 0.3)
      paused = fighting(*crew, clock_s: 0.3)
      3.times { |i| straight.step!(tick: i + 1) }
      paused.step!(tick: 1)
      resumed = with(paused, crew)

      expect(resumed.state.dig(:minions, :a, :fight, :melee)).to be(:m)
      2.times { |i| resumed.step!(tick: i + 2) }
      expect(ReactorSim.canonical(resumed.state.fetch(:minions))).to eq(ReactorSim.canonical(straight.state.fetch(:minions)))
    end
  end

  describe "sabotage" do
    let(:damage) { ReactorSim::Animosity::Opening.new(id: :spoil, harm: 1.0, places: %i[shed], mishap: { node: :drum, kind: :damage, share: 0.5 }) }
    let(:hold) { ReactorSim::Animosity::Opening.new(id: :hold, harm: 1.0, places: %i[shed], slip: :freeze) }

    # The target is in the shed, reachable only through the post; somebody stands in the yard so
    # there is a temper to lose.
    def at_the_post(holder, target, opening)
      crew = [ holder, target, person(:c) ]
      base = rig(crew, openings: [ opening ])
      with(base, crew, holder.id => { patience: 1.0e-9, station: :post, posting: :post })
    end

    def ruthless(id) = brute(id, grudges: { b: 1.0 }, tags: { callous: 1.0, short_tempered: 1.0 })

    it "does to the part what the post lets them, and the part suffers it the tick after" do
      op = at_the_post(ruthless(:a), sitting_duck(:b, place: :shed), damage)
      before = op.state.dig(:nodes, :drum, :durability)
      events = op.step!(tick: 1)
      op.step!(tick: 2)

      expect(events.find { |e| e[:type] == :quarrel }).to include(mode: :sabotage, cause: :spoil)
      expect(op.state.dig(:nodes, :drum, :durability)).to be < before
      expect(types(events)).not_to include(:grudge_formed)
    end

    it "holds a lever on purpose with a slip of their own" do
      op = at_the_post(ruthless(:a), sitting_duck(:b, place: :shed), hold)
      op.step!(tick: 1)

      expect(op.state.fetch(:spite)).to include(control: :post, slip: :freeze)
      op.step!(tick: 2)
      expect(op.state.dig(:controls, :post, :slip)).to be(:freeze)
    end

    it "does nothing when the target sees it coming, and the target knows who it was" do
      op = at_the_post(weakling(:a, grudges: { b: 1.0 }, tags: { callous: 1.0 }), wary(:b, place: :shed), damage)
      events = op.step!(tick: 1)

      expect(events.find { |e| e[:type] == :quarrel }).to include(mode: :sabotage)
      expect(events.find { |e| e[:type] == :quarrel }.dig(:detail, :foiled)).to be(true)
      expect(op.state.fetch(:mishaps)).to be_empty
      expect(held(op, :b, :a)).to be_positive
    end

    it "refuses an opening aimed at a part that cannot suffer it" do
      wrong = ReactorSim::Animosity::Opening.new(id: :x, harm: 1.0, mishap: { node: :drum, kind: :obstruction })

      expect { rig([], openings: [ wrong ]) }.to raise_error(ReactorSim::Error, /cannot suffer/)
    end
  end

  describe "a shove" do
    let(:edge) { ReactorSim::Peril.new(id: :edge, wounds: { impact: 1.0 }, causes: %i[fall], severity: 3.0, places: %i[yard], opportunity: true) }

    it "gives the target the peril in full, on the seeds where that is what was chosen" do
      crew = [ brute(:a, grudges: { b: 1.0 }, tags: { callous: 1.0 }), sitting_duck(:b) ]
      shoves = (1..40).filter_map do |seed|
        op = with(rig(crew, perils: [ edge ], seed: seed), crew, seed: seed, a: { patience: 1.0e-9 })
        events = op.step!(tick: 1)
        events if events.any? { |e| e[:type] == :quarrel && e[:mode] == :shove }
      end

      expect(shoves).not_to be_empty
      expect(shoves).to all(include(include(type: :minion_hurt, cause: :edge)))
    end
  end

  describe "the boss" do
    def quarrels(oversees, boss, **states) = stopped(oversees, boss, **states).map(&:last)

    # `[[op, events]]` a seed each, the boss posted over `oversees` and `a` about to snap at `b`.
    def stopped(oversees, boss, a: {}, boss_state: {})
      snapping = { patience: 1.0e-9 }.merge(a)
      posted = { station: :bossing, posting: :bossing }.merge(boss_state)
      (1..40).map do |seed|
        crew = [ person(:a, grudges: { b: 0.5 }), person(:b), boss ]
        op = with(rig(crew, oversees: oversees, seed: seed), crew, seed: seed, a: snapping, boss.id => posted)
        [ op, op.step!(tick: 1) ]
      end
    end

    def put_in_line(runs)
      runs.filter_map do |op, events|
        next unless types(events).include?(:quarrel_averted)

        state = op.state.dig(:minions, :a)
        state.fetch(:patience) / state.fetch(:patience_full)
      end
    end

    def averted(runs) = runs.count { |events| types(events).include?(:quarrel_averted) }

    let(:talker) { person(:boss, stats: { charisma: 3.0, intelligence: 2.0, strength: 0.2 }) }
    let(:ogre) { person(:boss, stats: { strength: 1.0, charisma: 0.1, intelligence: 0.1 }, mass_kg: 500.0) }

    it "steps into some quarrels in the place they oversee, never all, and none elsewhere" do
      watched = quarrels(%i[yard], talker)

      expect(averted(watched)).to be_between(1, watched.length - 1)
      expect(averted(quarrels(%i[shed], talker))).to eq(0)
    end

    it "is resented for staring them down, and not for talking them round" do
      stared = quarrels(%i[yard], ogre).select { |events| types(events).include?(:quarrel_averted) }
      talked = quarrels(%i[yard], talker).select { |events| types(events).include?(:quarrel_averted) }

      expect(stared).not_to be_empty
      expect(stared).to all(include(include(type: :grudge_formed, detail: include(target: :boss))))
      expect(talked.flatten.select { |e| e[:type] == :grudge_formed }).to be_empty
    end

    it "resents a stare-down less the more they already hate him" do
      gained = ->(held) {
        stopped(%i[yard], ogre, a: { grudges: { boss: held } }).sum do |op, events|
          types(events).include?(:quarrel_averted) ? op.state.dig(:minions, :a, :grudges, :boss) - held : 0.0
        end
      }

      expect(gained.(0.8)).to be < gained.(0.0)
    end

    it "puts somebody in line with patience back, more by a stare than by talking them round" do
      stared = put_in_line(stopped(%i[yard], ogre))
      talked = put_in_line(stopped(%i[yard], talker))

      expect(stared).not_to be_empty
      expect(talked).not_to be_empty
      expect(stared.min).to be > talked.max
      expect(talked.min).to be > animosity::RELEASE.fetch(:averted)
    end

    it "keeps an eye on the rest while rowing with somebody, and not while in a brawl" do
      rowing = quarrels(%i[yard], talker, boss_state: { fight: { with: :b, clock_s: 30.0 } })
      brawling = quarrels(%i[yard], talker, boss_state: { fight: { melee: :n, clock_s: 5.0, owed: {} } })

      expect(averted(rowing)).to be_positive
      expect(averted(brawling)).to eq(0)
    end
  end

  it "draws its dice from a stream of its own beside each person's" do
    op = rig([ person(:a) ])

    expect(op.rngs).to have_key(animosity.stream(:a))
    expect(op.rngs).to have_key(:a)
  end
end
