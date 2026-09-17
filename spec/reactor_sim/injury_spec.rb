# frozen_string_literal: true

require "reactor_sim"
require "json"
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
  def worker(stats: {}, tags: {})
    base = { strength: 1.0, toughness: 1.0, intelligence: 1.0, dexterity: 1.0, charisma: 1.0 }
    ReactorSim::Minion.new(id: :hand, name: "Hand", station: :lever,
                           stats: base.merge(stats), tags: tags)
  end

  def fresh(minion, seed: 1) = minion.initial_state(ReactorSim::Rng.stream(seed, "rig/hand"))

  def hazard(severity, tags: [ :blast ])
    { station: :lever, severity: severity, tags: tags, sources: [ :boiler ] }
  end

  def ctx_for(op)
    ReactorSim::Operation::Context.new(
      controls: {}, dt: ReactorSim::DT, tick: 1, content: op.content,
      nodes: op.nodes, states: op.state.fetch(:nodes)
    )
  end

  describe "resistance" do
    # One naming convention rather than a lookup table: a hazard tag `:x` is resisted by the
    # minion tag `:x_resistance`, so adding a hazard kind means adding gear that names it and
    # nothing else.
    it "is reduced by gear that names the hazard's own tag" do
      bare = described_class.resistance(worker, hazard(2.0))
      clad = described_class.resistance(worker(tags: { blast_resistance: 0.5 }), hazard(2.0))

      expect(clad).to be_within(1e-9).of(bare + 0.5)
    end

    it "ignores gear that resists something else entirely" do
      clad = worker(tags: { scald_resistance: 0.9 })

      expect(described_class.resistance(clad, hazard(2.0, tags: [ :blast ])))
        .to be_within(1e-9).of(described_class.resistance(worker, hazard(2.0)))
    end

    # **`clumsy` makes the bite worse**, which is what turns a day-labourer from merely useless
    # into genuinely dangerous to employ — and it is the hook the unlit / no-rails / cramped
    # operation upgrades will hang on.
    it "is reduced by clumsiness rather than helped by it" do
      expect(described_class.resistance(worker(tags: { clumsy: 0.3 }), hazard(2.0)))
        .to be < described_class.resistance(worker, hazard(2.0))
    end

    it "is improved by a sense for danger" do
      expect(described_class.resistance(worker(tags: { hazard_sense: 0.3 }), hazard(2.0)))
        .to be > described_class.resistance(worker, hazard(2.0))
    end
  end

  describe "the ladder" do
    it "leaves somebody untouched by a hazard they out-resist" do
      hand = worker
      state, mode = described_class.check(hand, fresh(hand), hazard(0.5))

      expect(mode).to be_nil
      expect(state.fetch(:resilience)).to eq(fresh(hand).fetch(:resilience))
    end

    it "kills outright when one blow is big enough that what is left does not matter" do
      hand = worker
      _, mode = described_class.check(hand, fresh(hand), hazard(9.0))

      expect(mode).to be(:mortal)
    end

    # The gradient the whole release is for: the same blast, two different workers.
    it "downgrades the outcome for somebody tougher and better equipped" do
      weak = worker(stats: { toughness: 0.4 }, tags: { clumsy: 0.3 })
      kitted = worker(stats: { toughness: 1.2 }, tags: { blast_resistance: 0.5 })

      _, weak_mode = described_class.check(weak, fresh(weak), hazard(3.0))
      _, kitted_mode = described_class.check(kitted, fresh(kitted), hazard(3.0))

      expect(described_class::ORDER.index(weak_mode))
        .to be > described_class::ORDER.index(kitted_mode)
    end

    # The accumulation route, and `Wearing`'s fatigue half: a long shift in a hot place tells
    # eventually, even when no single moment was dramatic.
    it "grinds somebody down over repeated small hazards" do
      hand = worker
      state = fresh(hand)
      modes = Array.new(12) do
        state, mode = described_class.check(hand, state, hazard(1.2))
        mode
      end

      expect(state.fetch(:resilience)).to be < fresh(hand).fetch(:resilience)
      expect(modes.compact).to include(:minor)
    end

    # Being carried out clears the station, which is the whole mechanical consequence: whatever
    # that lever needed doing stops being done.
    it "stands a severely hurt minion down from their post" do
      hand = worker(stats: { toughness: 0.5 })
      state, mode = described_class.check(hand, fresh(hand), hazard(2.2))

      expect(mode).to be(:severe)
      expect(state.fetch(:station)).to be_nil
    end

    it "leaves the walking wounded at their post" do
      hand = worker
      state, mode = described_class.check(hand, fresh(hand), hazard(1.6))

      expect(mode).to be(:minor)
      expect(state.fetch(:station)).to be(:lever)
    end
  end

  describe "escalation" do
    # Forward only, for the reason a burst drum is never re-described as merely split: the
    # conditions that caused the worse outcome are gone *because* it happened.
    it "never relaxes back to a milder injury" do
      hand = worker
      hurt, = described_class.check(hand, fresh(hand), hazard(9.0))
      after, mode = described_class.check(hand, hurt, hazard(1.9))

      expect(after.fetch(:injury)).to be(:mortal)
      expect(mode).to be_nil
    end

    # Emitted on a TRANSITION only. Re-deciding every tick would announce the same injury at the
    # tick rate forever — the discipline `break_part` already follows.
    it "says nothing when the tier has not changed" do
      hand = worker(stats: { toughness: 0.5 })
      hurt, first = described_class.check(hand, fresh(hand), hazard(2.2))
      _, again = described_class.check(hand, hurt, hazard(2.2))

      expect(first).to be(:severe)
      expect(again).to be_nil
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
      hand = worker(stats: { toughness: 0.5 })
      hurt, = described_class.check(hand, fresh(hand), hazard(2.2))

      expect(hand.rate_multiplier(hurt)).to eq(0.0)
    end

    it "leaves the walking wounded working, badly" do
      hand = worker
      state, = described_class.check(hand, fresh(hand), hazard(1.6))

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
        operations: [ { id: :eng, type: :steam_engine, loadout: { fusible_plug: nil },
                        crew: { fireman: { minion: :test_hand_a } } } ]
      )
      op = match.operation(:eng)
      { igniter: 100, blower: 100, damper_open: 85, stoking: 70, feed: 0 }
        .each { |k, v| op.set_control(k, v) }

      events = []
      (1..7_000).each do |t|
        op.set_control(:igniter, 0) if t == 300
        events.concat(match.step!)
        break if events.any? { |e| e[:type] == :minion_hurt }
      end
      [ match, events.select { |e| e[:type] == :minion_hurt } ]
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
      hurt = restored.operation(:eng).state.fetch(:minions).fetch(:fireman)

      expect(hurt.fetch(:injury)).to be_a(Symbol)
      expect(described_class::ORDER).to include(hurt.fetch(:injury))
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
                                          stats: { strength: 1.0, toughness: 1.0,
                                                   intelligence: 1.0, dexterity: 1.0,
                                                   charisma: 1.0 }) ]
      )
    end

    def scaled(reference)
      rig(endangers: { rupture: { tags: [ :scald ], scales_with: :pressure_pa,
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
      op = rig(endangers: { rupture: { tags: [ :scald ], stations: { lever: 9.0 } } })

      expect(hurt_in(op)[:mode]).to be(:mortal)
    end

    # A part that declares a scale and reports nothing must not silently become harmless — that
    # would be a hazard switched off by a typo. It falls back to flat and the machine-wide check
    # below is what catches the wiring mistake.
    it "falls back to flat rather than to nothing when the figure is missing" do
      op = rig(endangers: { rupture: { tags: [ :scald ], scales_with: :nothing_reported,
                                       reference: 10.0, stations: { lever: 9.0 } } })

      expect(hurt_in(op)[:mode]).to be(:mortal)
    end
  end

  # Mirrors `failure_spec`'s inverse check: a hazard wired to a station that does not exist is
  # inert and indistinguishable from a part meant to fail harmlessly.
  describe "what every catalogued machine declares" do
    it "endangers only stations the machine actually has, for modes its parts can enter" do
      ReactorSim::Operations.catalogued.each do |type|
        ReactorSim::Operations.chassis_for(type).each do |frame|
          op = ReactorSim::Match
               .create(id: "x", seed: 1,
                       operations: [ { id: :m, type: type, chassis: frame } ])
               .operation(:m)

          op.nodes.each_value do |node|
            next unless node.respond_to?(:failure_hazards)

            node.failure_hazards.each do |mode, declared|
              expect(node.failure_modes).to have_key(mode),
                                            "#{node.id} endangers on #{mode}, which it cannot enter"
              (declared[:stations] || {}).each_key do |station|
                expect(op.control_points).to have_key(station),
                                             "#{node.id} endangers #{station}, which does not exist"
              end

              # A part that declares a scale and then never reports the figure falls back to
              # flat — which is safe, and silent. This is the check that stops it being silent.
              next unless declared[:scales_with]

              expect(node.failure_detail(op.state.fetch(:nodes).fetch(node.id), ctx_for(op)))
                .to have_key(declared[:scales_with]),
                    "#{node.id} scales on #{declared[:scales_with]}, which it never reports"
            end
          end
        end
      end
    end
  end
end
