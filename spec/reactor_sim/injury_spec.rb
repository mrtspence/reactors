# frozen_string_literal: true

require "reactor_sim"
require "json"
require "support/engine_rig"
require "support/reference_crew"

# The Danger Check, and the ladder a hurt minion climbs.
#
# **The design claim this file exists to prove is that no dice are thrown.** A minion's
# `resilience` is rolled once, at `initial_state`, from the stream every minion already had and
# never used — so every check afterwards is a deterministic comparison. If a roll ever leaks onto
# the tick path the determinism example here fails, and nothing else would notice.
#
# Assertions are on the TIER rather than on tuned numbers, for the same reason the failure specs
# assert modes rather than pressures: the curve is a sweep and will move.
RSpec.describe ReactorSim::Injury, crew: :reference do
  include EngineRig

  def worker(stats: {}, tags: {})
    base = { strength: 1.0, toughness: 1.0, endurance: 1.0, intelligence: 1.0,
             dexterity: 1.0, charisma: 1.0, agility: 1.0, combat_prowess: 1.0 }
    ReactorSim::Minion.new(id: :hand, name: "Hand", station: :lever,
                           mass_kg: ReferenceCrew::HUMAN_KG,
                           stats: base.merge(stats), tags: tags)
  end

  def fresh(minion, seed: 1) = minion.initial_state(ReactorSim::Rng.stream(seed, "rig/hand"))

  # **A catalogue of its own**, so nothing here moves when the shipped one is rewritten: every
  # kind, tier and variant, derating strength by tier.
  def catalogue
    left = { minor: 0.9, significant: 0.6, severe: 0.2, mortal: 0.0 }
    @catalogue ||= ReactorSim::Wounds::Catalogue.new(
      ReactorSim::Wounds::KINDS.to_h do |kind|
        [ kind, ReactorSim::Wounds::TIERS.to_h do |tier|
          [ tier, (1..3).to_h { |i| [ :"#{kind}_#{tier}_#{i}", { label: "#{kind} #{i}", weight: i, derates: { strength: left.fetch(tier) } } ] } ]
        end ]
      end
    )
  end

  def hazard(severity, wounds: { blast: 1.0 }, causes: [])
    { station: :lever, wounds: ReactorSim::Wounds.dealt(wounds, severity), causes: causes, sources: [ :boiler ] }
  end

  def check(minion, state, harm, die: 0.0) = described_class.check(minion, state, harm, catalogue: catalogue, die: die)

  def bite(minion, harm, kind) = harm.dig(:wounds, kind) - described_class.resisted(minion, harm, kind, harm.dig(:wounds, kind) / harm[:wounds].values.sum)

  def ctx_for(op)
    ReactorSim::Operation::Context.new(
      controls: {}, dt: ReactorSim::DT, tick: 1, content: op.content,
      nodes: op.nodes, states: op.state.fetch(:nodes)
    )
  end

  describe "resistance" do
    # One naming convention rather than a lookup table: a hazard tag `:x` is resisted by the
    # minion tag `:x_resistance`, so adding a kind or a cause means adding gear that names it.
    it "is reduced by gear that names the kind of wound" do
      clad = worker(tags: { blast_resistance: 0.5 })

      expect(bite(clad, hazard(2.0), :blast)).to be_within(1e-9).of(bite(worker, hazard(2.0), :blast) - 0.5)
    end

    it "is reduced by gear against what caused it" do
      fall = hazard(2.0, wounds: { crush: 1.0 }, causes: %i[rockfall])
      helmeted = worker(tags: { rockfall_resistance: 0.3 })

      expect(bite(helmeted, fall, :crush)).to be < bite(worker, fall, :crush)
    end

    it "ignores gear that resists something else entirely" do
      clad = worker(tags: { scald_resistance: 0.9 })

      expect(bite(clad, hazard(2.0), :blast)).to be_within(1e-9).of(bite(worker, hazard(2.0), :blast))
    end

    # **`clumsy` makes the bite worse**, which is what turns a day-labourer from merely useless
    # into genuinely dangerous to employ.
    it "is reduced by clumsiness rather than helped by it, and improved by a sense for danger" do
      expect(bite(worker(tags: { clumsy: 0.3 }), hazard(2.0), :blast)).to be > bite(worker, hazard(2.0), :blast)
      expect(bite(worker(tags: { hazard_sense: 0.3 }), hazard(2.0), :blast)).to be < bite(worker, hazard(2.0), :blast)
    end

    # **Each kind on its own**: red-hot scrap is a crush and a burn, and a helmet turns only one.
    it "resists each kind of a harm separately, and takes the same total as one kind would bare" do
      scrap = hazard(3.0, wounds: { crush: 0.5, burn: 0.5 })
      plated = worker(tags: { crush_resistance: 2.0 })
      _, _, wounds = check(plated, fresh(plated), scrap)
      split = bite(worker, scrap, :crush) + bite(worker, scrap, :burn)

      expect(wounds.map { |w| w.fetch(:kind) }).to eq(%i[burn])
      expect(split).to be_within(1e-9).of(bite(worker, hazard(3.0), :blast))
    end
  end

  describe "the ladder" do
    it "leaves somebody untouched by a hazard they out-resist" do
      hand = worker
      state, mode = check(hand, fresh(hand), hazard(0.5))

      expect(mode).to be_nil
      expect(state.fetch(:resilience)).to eq(fresh(hand).fetch(:resilience))
    end

    it "kills outright when one blow is big enough that what is left does not matter" do
      hand = worker
      _, mode = check(hand, fresh(hand), hazard(9.0))

      expect(mode).to be(:mortal)
    end

    # The gradient the whole release is for: the same blast, two different workers.
    it "downgrades the outcome for somebody tougher and better equipped" do
      weak = worker(stats: { toughness: 0.4 }, tags: { clumsy: 0.3 })
      kitted = worker(stats: { toughness: 1.2 }, tags: { blast_resistance: 0.5 })

      _, weak_mode = check(weak, fresh(weak), hazard(3.0))
      _, kitted_mode = check(kitted, fresh(kitted), hazard(3.0))

      expect(described_class::ORDER.index(weak_mode))
        .to be > described_class::ORDER.index(kitted_mode)
    end

    # **The flaw the wounds exist to fix**: a second harm no worse than the first still wounds.
    it "wounds again for a second harm of a lesser tier, and the wounds stack" do
      hand = worker
      hurt, = check(hand, fresh(hand), hazard(1.6))
      again, mode, = check(hand, hurt, hazard(1.3))

      expect(mode).to be(:minor)
      expect(again.fetch(:wounds).map { |w| w.fetch(:tier) }).to eq(%i[significant minor])
      expect(hand.rate_multiplier(again)).to be < hand.rate_multiplier(hurt)
    end

    # The accumulation route: many small harms take somebody out of a shift with no single one
    # being much, and enough of them kill.
    it "collapses somebody whose resilience runs out whatever their wounds, and kills them far past it" do
      hand = worker
      state = fresh(hand)
      modes = Array.new(30) do
        state, mode, = check(hand, state, hazard(1.3))
        mode
      end

      expect(modes.compact).to include(:minor, :severe, :mortal)
      expect(state.fetch(:wounds).map { |w| w.fetch(:tier) }.uniq).to eq(%i[minor])
    end

    # Being carried out clears the station, which is the whole mechanical consequence: whatever
    # that lever needed doing stops being done.
    it "stands a severely hurt minion down from their post" do
      hand = worker
      state, mode = check(hand, fresh(hand), hazard(2.8))

      expect(mode).to be(:severe)
      expect(state.fetch(:station)).to be_nil
    end

    it "leaves the walking wounded at their post, and a knock costs them less than a wound" do
      hand = worker
      wounded, mode = check(hand, fresh(hand), hazard(1.6))
      knocked, knock = check(hand, fresh(hand), hazard(1.3))

      expect(mode).to be(:significant)
      expect(knock).to be(:minor)
      expect(wounded.fetch(:station)).to be(:lever)
      expect(hand.rate_multiplier(knocked)).to be > hand.rate_multiplier(wounded)
      expect(hand.rate_multiplier(knocked)).to be < hand.rate_multiplier(fresh(hand))
    end

    it "names every wound a harm left" do
      hand = worker
      _, _, wounds = check(hand, fresh(hand), hazard(4.0, wounds: { crush: 0.5, burn: 0.5 }))

      expect(wounds.map { |w| w.fetch(:kind) }).to eq(%i[burn crush])
      expect(wounds).to all(include(:label, :tier, :depth, :variant))
    end
  end

  describe "the catalogue" do
    it "picks among a tier's variants by weight, the same each time from the same die" do
      picks = (0...60).map { |i| catalogue.pick(:crush, :severe, i / 60.0) }.tally

      expect(picks.keys.sort).to eq([ 0, 1, 2 ])
      expect(picks.fetch(2)).to be > picks.fetch(0)
      expect(catalogue.pick(:crush, :severe, 0.42)).to eq(catalogue.pick(:crush, :severe, 0.42))
    end

    it "refuses one missing a tier, a variant, or naming a stat that is not one" do
      complete = ReactorSim::Content.shipped_wounds
      short_a_tier = complete.merge(crush: complete.fetch(:crush).except(:mortal))
      short_a_variant = complete.merge(crush: complete.fetch(:crush).merge(minor: complete.dig(:crush, :minor).first(2).to_h))
      misnamed = complete.merge(crush: complete.fetch(:crush).merge(
        minor: complete.dig(:crush, :minor).transform_values { |e| e.merge(derates: { agilty: 0.5 }) }
      ))

      expect { ReactorSim::Wounds::Catalogue.new(short_a_tier) }.to raise_error(ReactorSim::Error, /crush has no mortal/)
      expect { ReactorSim::Wounds::Catalogue.new(short_a_variant) }.to raise_error(ReactorSim::Error, /2 variants/)
      expect { ReactorSim::Wounds::Catalogue.new(misnamed) }.to raise_error(ReactorSim::Error, /agilty/)
    end

    it "refuses a harm of no kind, an unknown kind, shares that do not sum, or an unknown cause" do
      expect { ReactorSim::Wounds.shares!("x", nil) }.to raise_error(ReactorSim::Error, /says nothing/)
      expect { ReactorSim::Wounds.shares!("x", { stab: 1.0 }) }.to raise_error(ReactorSim::Error, /stab/)
      expect { ReactorSim::Wounds.shares!("x", { crush: 0.5 }) }.to raise_error(ReactorSim::Error, /sum/)
      expect { ReactorSim::Wounds.causes!("x", %i[gremlins]) }.to raise_error(ReactorSim::Error, /gremlins/)
    end
  end

  describe "a harm that keeps working" do
    it "deepens one standing wound instead of adding one a tick" do
      state = fresh(worker)
      modes = Array.new(20) do
        state, mode, = described_class.endure(state, :heat, 0.1, catalogue: catalogue, die: 0.0)
        mode
      end

      expect(state.fetch(:wounds).map { |w| w.fetch(:kind) }).to eq(%i[heat])
      expect(state.fetch(:wounds).first.fetch(:depth)).to be_within(1e-9).of(2.0)
      expect(modes.compact).to include(:minor, :significant, :severe)
    end

    it "takes the standing wound to the tier it succumbs at" do
      state, mode, = described_class.succumb(fresh(worker), :severe, kind: :breath, catalogue: catalogue, die: 0.0)

      expect(mode).to be(:severe)
      expect(state.fetch(:wounds).map { |w| w.values_at(:kind, :tier) }).to eq([ %i[breath severe] ])
      expect(state.fetch(:station)).to be_nil
    end
  end

  describe "between matches" do
    it "brings wounds back, takes their depth off what they start with, and lets the healed go" do
      held = [ { kind: :crush, depth: 0.8, variant: 1, ref: 7 }, { kind: :burn, depth: 0.05, variant: 0 } ]
      start = fresh(worker)
      carried = described_class.carried(start, held, catalogue)

      expect(carried.fetch(:wounds).map { |w| w.values_at(:kind, :tier, :ref) }).to eq([ [ :crush, :significant, 7 ] ])
      expect(carried.fetch(:resilience)).to be_within(1e-9).of(start.fetch(:resilience) - 0.8)
    end

    it "never starts somebody already collapsed" do
      start = fresh(worker)
      carried = described_class.carried(start, [ { kind: :crush, depth: 2.9, variant: 0 } ], catalogue)

      expect(carried.fetch(:resilience)).to be >= start.fetch(:initial_resilience) * described_class::CARRIED_FLOOR
    end

    it "heals a flat depth a match, faster regenerating and slower for a slow healer, and never not at all" do
      plain = ReactorSim::Wounds.heal(2.0, {})

      expect(ReactorSim::Wounds.heal(2.0, { regeneration: 0.6 })).to be < plain
      expect(ReactorSim::Wounds.heal(2.0, { slow_healer: 0.1 })).to be > plain
      expect(ReactorSim::Wounds.heal(2.0, { slow_healer: 5.0 })).to be < 2.0
      expect(ReactorSim::Wounds.tier(ReactorSim::Wounds.heal(0.3, {}))).to be_nil
    end
  end

  describe "escalation" do
    # Forward only, for the reason a burst drum is never re-described as merely split: the
    # conditions that caused the worse outcome are gone *because* it happened.
    it "never relaxes back to a milder condition" do
      hand = worker
      hurt, = check(hand, fresh(hand), hazard(9.0))
      after, = check(hand, hurt, hazard(1.9))

      expect(after.fetch(:injury)).to be(:mortal)
    end

    it "marks only the top of the ladder as outliving the match" do
      expect(described_class.lasting?(:mortal)).to be(true)
      expect(described_class.lasting?(:severe)).to be(false)
      expect(described_class.lasting?(nil)).to be(false)
    end
  end

  describe "derating" do
    it "leaves an unhurt minion at full rate" do
      expect(described_class.derating({ injury: nil }, :strength)).to eq(1.0)
    end

    it "takes a severely hurt minion to nothing at a lever" do
      hand = worker
      hurt, = check(hand, fresh(hand), hazard(2.8))

      expect(hand.rate_multiplier(hurt)).to eq(0.0)
    end

    it "leaves the walking wounded working, badly" do
      hand = worker
      state, = check(hand, fresh(hand), hazard(1.6))

      expect(hand.rate_multiplier(state)).to be_between(0.01, 0.99).exclusive
    end
  end

  # The whole point of rolling at `initial_state` instead of at check time.
  describe "determinism" do
    def burst(seed)
      match = ReactorSim::Match.create(
        id: "i", seed: seed,
        # A fixture at the firehole, not anybody real: this example is about whether the same
        # seed hurts the same person the same way, and it must not start failing because
        # somebody tuned Jim.
        operations: [ { id: :eng, type: :steam_engine,
                        loadout: ReferenceCrew.loadout(fusible_plug: nil),
                        crew: { crew_1: { minion: :test_hand_a } } } ]
      )
      # **A crown-sheet explosion, built rather than boiled down to.** With no plug fitted, 400 kg
      # of water, the feed shut and a shell already worked, the drum lets go in a handful of ticks
      # — where the old form of this ran up to 7,000 waiting for 2,000 kg to boil away.
      #
      # Both figures are load-bearing and `crown_sheet_spec` records why: 400 kg and not less
      # because severity scales with the water left to flash (an emptier drum seam-splits), and a
      # worn shell because the erosion rate is that spec's claim rather than this one's.
      #
      # **Seeded through the MATCH**, because the snapshot example below fingerprints `match.to_h`
      # — seeding the operation alone leaves the match holding the cold engine.
      engine_op = match.operation(:eng)
      seeded = seed_match(match, :eng,
                          nodes: at_work_nodes(engine_op, water: 400.0)
                                   .merge(boiler: body(engine_op, :boiler, EngineRig::DRUM_K,
                                                       water: 400.0, steam: EngineRig::DRUM.fetch(:steam))
                                                    .merge(durability: 20.0)))
      op = seeded.operation(:eng)
      # **Deploy the shift, or there is nobody in range of the drum when it goes.** Crew start in
      # the quarters, so posting somebody to the firehole is the opening move — and it is also
      # what puts them beside the boiler, which is the whole point of this example.
      op.assign_minion(:crew_1, :stoking)
      { damper_open: 85, stoking: 70, feed: 0, igniter: 0, blower: 0,
        throttle_open: 60, load_demand: 80 }.each { |k, v| op.set_control(k, v) }

      events = []
      20.times do
        events.concat(seeded.step!)
        break if events.any? { |e| e[:type] == :minion_hurt }
      end
      [ seeded, events.select { |e| e[:type] == :minion_hurt } ]
    end

    it "hurts the same people the same way from the same seed" do
      _, first = burst(42)
      _, again = burst(42)

      expect(first).not_to be_empty, "nobody was hurt, so this proves nothing"
      expect(again.map { |e| ReactorSim.canonical(e) })
        .to eq(first.map { |e| ReactorSim.canonical(e) })
    end

    # **The injury mode is a Symbol held as a VALUE**, so JSON hands it back as a String — and
    # it is truthy either way, so the minion stays hurt in a mode nothing matches while every
    # derating quietly falls back to 1.0. A crew would come back from a snapshot completely
    # healed while still reading as injured. `be`, never `eq`.
    #
    # **Which tier is deliberately not asserted.** Whether a given blast leaves somebody walking
    # wounded or carried out is a balance question, and pinning it here would fail the day a
    # constant moves for a reason having nothing to do with serialisation. What must hold is that
    # whatever came back is a Symbol from the ladder.
    it "brings an injury back from a snapshot as a Symbol" do
      match, = burst(42)
      restored = ReactorSim::Match.from_h(JSON.parse(JSON.generate(match.to_h)))
      hurt = restored.operation(:eng).state.fetch(:minions).fetch(:crew_1)

      expect(hurt.fetch(:injury)).to be_a(Symbol)
      expect(described_class::ORDER).to include(hurt.fetch(:injury))
      expect(hurt.fetch(:wounds)).not_to be_empty
      hurt.fetch(:wounds).each do |wound|
        expect(wound.values_at(:kind, :tier, :id)).to all(be_a(Symbol))
      end
    end

    it "refuses a machine whose harm says nothing of the wounds it deals" do
      vessel = ReactorSim::Nodes::Vessel.new(id: :drum, label: "Drum", volume_m3: 1.0, heat_capacity: 1.0e4,
                                             endangers: { rupture: { tags: [ :scald ], stations: { lever: 1.0 } } })

      expect { ReactorSim::Operation.new(id: :rig, type: :test, seed: 1, nodes: [ vessel ]) }
        .to raise_error(ReactorSim::Error, /declare wounds/)
    end
  end

  # **A small steam escape is not a large one.** The station's figure is a WEIGHT — how exposed
  # that post is — and the magnitude comes from the part itself, read off the failure event's own
  # detail. A rig rather than the steam engine, because forcing two ruptures of different sizes
  # out of a real boiler costs thousands of ticks for something this states directly.
  describe "severity that scales with the event" do
    # `stress_rate:` is what makes this drum fail at all — `Vessel` has no `overload?`, it
    # depletes durability, and the default rate of zero is a vessel that never breaks however far
    # past its rating it goes.
    def rig(endangers:)
      vessel = ReactorSim::Nodes::Vessel.new(
        id: :drum, label: "Drum", volume_m3: 1.0, heat_capacity: 1.0e4,
        ambient_conductance: 0.0, max_pressure_pa: 1.0e5, stress_rate: 3_000.0,
        initial_contents: [ { resource: :water, kg: 50.0, temperature_k: 480.0 } ],
        endangers: endangers
      )

      ReactorSim::Operation.new(
        id: :rig, type: :test, seed: 1, nodes: [ vessel ],
        control_points: [ ReactorSim::ControlPoint.new(id: :lever, node: :drum) ],
        minions: [ ReactorSim::Minion.new(id: :hand, name: "Hand", station: :lever,
                                          mass_kg: ReferenceCrew::HUMAN_KG,
                                          stats: ReferenceCrew::PLAIN_STATS) ]
      )
    end

    def scaled(reference)
      rig(endangers: { rupture: { wounds: { scald: 1.0 }, scales_with: :pressure_pa,
                                  reference: reference, stations: { lever: 2.0 } } })
    end

    def hurt_in(op)
      events = []
      6.times { |i| events.concat(op.step!(tick: i + 1)) }
      events.find { |e| e[:type] == :minion_hurt }
    end

    # **Read off the failure event, not off the drum at rest.** The saturation solve settles the
    # liquid/vapour split on the first tick, so the pressure at rupture is not the pressure the
    # vessel was built with — calibrating against the latter made a scale of 2.0 come out as
    # something else entirely, and the test failed for a reason that had nothing to do with
    # what it was testing.
    def reported_pressure
      op = scaled(1.0)
      event = nil
      6.times { |i| event ||= op.step!(tick: i + 1).find { |e| e[:type] == :part_failed } }
      event.fetch(:detail).fetch(:pressure_pa)
    end

    it "hurts somebody worse when the part reports a bigger event" do
      # Same physics, same station weight, different magnitude — a reference at half the actual
      # pressure makes the rupture count double, and one at the pressure itself makes it count
      # once. That is the whole mechanism in two lines.
      at_rupture = reported_pressure
      big = hurt_in(scaled(at_rupture / 2.0))
      small = hurt_in(scaled(at_rupture))

      expect(big).not_to be_nil, "the rig never hurt anybody, so this proves nothing"
      expect(small).not_to be_nil, "the smaller event hurt nobody, so there is nothing to compare"
      expect(ReactorSim::Injury::ORDER.index(big[:mode]))
        .to be > ReactorSim::Injury::ORDER.index(small[:mode])
    end

    # A declaration with no `scales_with:` is flat, which is the right answer for most hazards —
    # a linkage snapping is a linkage snapping.
    it "falls back to the flat weight when nothing is declared to scale with" do
      op = rig(endangers: { rupture: { wounds: { scald: 1.0 }, stations: { lever: 9.0 } } })

      expect(hurt_in(op)[:mode]).to be(:mortal)
    end

    # A part that declares a scale and reports nothing must not silently become harmless — that
    # would be a hazard switched off by a typo. It falls back to flat and the machine-wide check
    # below is what catches the wiring mistake.
    it "falls back to flat rather than to nothing when the figure is missing" do
      op = rig(endangers: { rupture: { wounds: { scald: 1.0 }, scales_with: :nothing_reported,
                                       reference: 10.0, stations: { lever: 9.0 } } })

      expect(hurt_in(op)[:mode]).to be(:mortal)
    end
  end

  # Mirrors `failure_spec`'s inverse check: a hazard wired to a station or a place that does not
  # exist is inert and indistinguishable from a part meant to fail harmlessly.
  #
  # **Both keys are walked, and that is the point.** A node may endanger stations, places or
  # both, so a machine moved from one key to the other has two ways to lose a hazard without
  # anything failing — a typo'd place, or a declaration left in the namespace nobody looks up.
  describe "what every catalogued machine declares" do
    # Every frame, and every part fitted on its own in its slot — a hazard that arrives only with a
    # fitting nobody fits by default is a hazard this walk would otherwise never see.
    def every_build
      bare = [ {} ]
      ReactorSim::Operations.catalogued.flat_map do |type|
        ReactorSim::Operations.chassis_for(type).flat_map do |frame|
          slots = ReactorSim::Operations.assembly_for(type, chassis: frame).slots
          fittings = slots.flat_map do |slot|
            ReactorSim::Parts.of_kind(slot.accepts).map { |part| { slot.id => part.id } }
          end
          (bare + fittings).map { |loadout| [ type, frame, loadout ] }
        end
      end
    end

    # TODO: parts are registered by kind with no record of which operation they belong to, so a
    # mine's lamp cabin is offered to the steam engine's quarters slot and refuses to build there.
    # Until parts are scoped, a single fitting that will not build on a machine declares nothing on
    # it and is skipped; a machine's own default build failing still fails here.
    def build(type, frame, loadout)
      ReactorSim::Match
        .create(id: "x", seed: 1, operations: [ { id: :m, type: type, chassis: frame, loadout: loadout } ])
        .operation(:m)
    rescue ReactorSim::Error
      raise if loadout.empty?
    end

    it "endangers only stations, places and riders the machine actually has, for modes it can enter" do
      every_build.each do |type, frame, loadout|
        op = build(type, frame, loadout) or next

        op.nodes.each_value do |node|
          next unless node.respond_to?(:failure_hazards)

          # A failure's modes, the `:explosion` a node hosting a prompt reaction can have, and what
          # a mishap can make of it — a tub down the shaft.
          prompt = node.respond_to?(:prompt_modes) ? node.prompt_modes(op.content) : {}
          mishap = node.respond_to?(:mishap_modes) ? node.mishap_modes : {}
          node.failure_hazards.each do |mode, declared|
            expect(node.failure_modes.merge(prompt, mishap)).to have_key(mode),
                                                        "#{node.id} endangers on #{mode}, which it cannot enter"
            (declared[:stations] || {}).each_key do |station|
              expect(op.control_points).to have_key(station),
                                           "#{node.id} endangers #{station}, which does not exist"
            end

            (declared[:places] || {}).each_key do |place|
              expect(op.layout.declared?(place)).to be(true),
                                                    "#{node.id} endangers #{place}, " \
                                                    "which is not a declared place"
            end

            # Ridden in a cage (`via` the hoist) or on the rods of a powered way (`riding` what
            # drives it).
            carriers = op.layout.passages.flat_map { |p| [ p.hoist, (p.driven_by if p.powered?) ] }
            (declared[:riders] || {}).each_key do |carrier|
              expect(carriers).to include(carrier),
                                  "#{node.id} endangers riders of #{carrier}, which nobody rides"
            end

            # A hazard that runs down a passage reaches people by where on it they are, so its ends
            # must be places and the stations it places or roams must exist.
            if (run = declared[:along])
              run.slice(:from, :to).each do |end_of_run, place|
                expect(op.layout.declared?(place)).to be(true),
                                                      "#{node.id} runs #{end_of_run} #{place}, which is not a place"
              end
              (run.fetch(:positions, {}).keys + Array(run[:roaming])).each do |station|
                expect(op.control_points).to have_key(station),
                                             "#{node.id} runs past #{station}, which does not exist"
              end
            end

            expect(declared.values_at(:stations, :places, :riders, :along).compact).not_to be_empty,
                                                                                  "#{node.id} endangers " \
                                                                                  "nobody on #{mode}"

            # A part that declares a scale and then never reports the figure falls back to
            # flat — which is safe, and silent. This is the check that stops it being silent.
            next unless declared[:scales_with]

            reported = if prompt.key?(mode)
              ReactorSim::Concerns::PromptReaction::EXPLOSION_DETAIL
            else
              node.failure_detail(op.state.fetch(:nodes).fetch(node.id), ctx_for(op)).keys
            end
            expect(reported).to include(declared[:scales_with]),
                                "#{node.id} scales on #{declared[:scales_with]}, which it never reports"
          end
        end
      end
    end
  end
end
