# frozen_string_literal: true

require "reactor_sim"
require "json"

# The failure model's contract, independent of any one machine.
#
# `Concerns::Wearing` records what a part BECAME, not merely that it broke — see
# docs/design_sketches/failure_model.md. The hazard that buys is that the mode is a Symbol held
# as a VALUE, which is the trap this codebase has now paid for five times.
RSpec.describe "failure modes" do
  def engine
    ReactorSim::Match.create(id: "m", seed: 42, operations: [ { id: "eng", type: :steam_engine } ])
  end

  def wound(match, node, mode)
    op = match.operation(:eng)
    nodes = op.state.fetch(:nodes)
    op.instance_variable_set(
      :@state, op.state.merge(nodes: nodes.merge(node => nodes.fetch(node).merge(failure: mode)))
    )
    match
  end

  def round_trip(match) = ReactorSim::Match.from_h(JSON.parse(JSON.generate(match.to_h)))

  describe "snapshot and restore" do
    # **Fifth instance of the symbols-as-values trap**, after parcel resource ids, instrument
    # flags, minion stations and loadout part ids. `deep_symbolize` converts KEYS only.
    #
    # This one is the nastiest of the five, because it half-works: "explosion" is truthy, so
    # `broken?` still answers correctly and the part stays broken. What is lost is *which*
    # failure it was — every `case` on the mode falls to its else branch, so a drum that
    # exploded comes back merely failed and every consequence keyed to the mode goes quiet.
    #
    # `be`, not `eq` — "explosion" == :explosion is false, but eq is still the wrong assertion
    # to trust here. And note the DIGEST cannot catch it: `canonical` runs through
    # JSON.generate, where :explosion and "explosion" are the same string, so a round-trip
    # digest comparison passes with the bug fully present.
    it "brings a failure mode back as a Symbol, not a String" do
      restored = round_trip(wound(engine, :boiler, :explosion))
      failure = restored.operation(:eng).state.fetch(:nodes).fetch(:boiler).fetch(:failure)

      expect(failure).to be(:explosion)
    end

    it "leaves a sound part with no failure recorded" do
      restored = round_trip(engine)
      failure = restored.operation(:eng).state.fetch(:nodes).fetch(:flywheel).fetch(:failure)

      expect(failure).to be_nil
    end

    it "survives a round trip with the failure intact" do
      match = wound(engine, :flywheel, :burst)
      restored = round_trip(match)

      expect(restored.digest).to eq(match.digest)
      expect(restored.operation(:eng).broken?).to be(true)
    end
  end

  describe "broken? is derived from the mode" do
    # A node that never included `Wearing` is asked this too — `Arbiter.settle_drive` checks
    # both ends of every drive link, and a `Load` carries no durability at all. It must answer
    # without carrying a key it has no use for.
    it "answers false for a node that cannot wear out" do
      op = engine.operation(:eng)
      load = op.nodes.fetch(:load)

      expect(load.broken?(op.state.fetch(:nodes).fetch(:load))).to be(false)
    end

    it "answers true for any mode at all" do
      op = wound(engine, :boiler, :seam_split).operation(:eng)

      expect(op.nodes.fetch(:boiler).broken?(op.state.fetch(:nodes).fetch(:boiler))).to be(true)
      expect(op.broken?).to be(true)
    end
  end

  # **A capability nothing exercises is indistinguishable from one that does not work.** That
  # rule is already written down in `nodes/CLAUDE.md` about `rated_temperature_k`, where every
  # node in the repository shipped the infinite default and two `stress_per_second`
  # implementations had therefore never once fired in any operation.
  #
  # `Wearing::GENERIC_FAILURE` is the same shape of silent off switch: a node that can be
  # destroyed but never says what it becomes will fail to `:failed` forever, and nothing
  # downstream can tell that apart from a part whose author decided `:failed` was right. So it
  # is not allowed to be a default anybody keeps — this walks every machine a player can
  # actually be handed and insists each part that can break has a story for breaking.
  describe "every part that can break names what it becomes" do
    # `catalogued`, not `known` — a spec rig is not a machine anyone is handed, and building
    # every registered type would rope in `spec/support/loop_rig.rb` the moment a full-suite
    # run loads it. Every chassis, though: a frame is separately unlockable, so a part that
    # only appears on one of them still has to answer for itself.
    def wearing_nodes
      ReactorSim::Operations.catalogued.flat_map do |type|
        ReactorSim::Operations.chassis_for(type).flat_map do |chassis|
          op = ReactorSim::Operations.fetch(type).call(id: :probe, seed: 1, chassis: chassis)
          op.nodes.values.select { |node| node.respond_to?(:apply_wear) }
        end
      end
    end

    it "finds parts to check at all" do
      expect(wearing_nodes).not_to be_empty
    end

    it "declares a non-empty mode table for every one" do
      undeclared = wearing_nodes.reject { |node| node.failure_modes.any? }

      expect(undeclared.map(&:id)).to be_empty
    end

    it "leaves no part on the generic fallback" do
      generic = wearing_nodes.select do |node|
        node.failure_modes.key?(ReactorSim::Concerns::Wearing::GENERIC_FAILURE)
      end

      expect(generic.map(&:id)).to be_empty
    end
  end

  describe "a part that fails names its mode" do
    def ctx_for(op)
      ReactorSim::Operation::Context.new(
        controls: {}, dt: ReactorSim::DT, tick: 1, content: op.content,
        nodes: op.nodes, states: op.state.fetch(:nodes)
      )
    end

    def node_and_state(op, id) = [ op.nodes.fetch(id), op.state.fetch(:nodes).fetch(id) ]

    it "records the mode the node names, spends its durability, and says why" do
      op = engine.operation(:eng)
      flywheel, state = node_and_state(op, :flywheel)

      broken, events = flywheel.break_part(state, ctx_for(op), :overload)

      expect(broken.fetch(:failure)).to be(:burst)
      expect(broken.fetch(:durability)).to eq(0.0)
      expect(events.first).to include(type: :flywheel_burst, cause: :overload, mode: :burst)
    end

    # The first failure escalated from nothing, so saying so would be noise.
    it "omits escalated_from on a first failure" do
      op = engine.operation(:eng)
      flywheel, state = node_and_state(op, :flywheel)

      _, events = flywheel.break_part(state, ctx_for(op), :overload)

      expect(events.first).not_to have_key(:escalated_from)
    end

    # **The same drum, destroyed two ways, is the case that rules out hanging the mode off the
    # cause or off the concern that noticed the stress.** What separates a split from an
    # explosion is how much superheated water is behind the metal, which no amount of knowing
    # the cause would tell you — so the causes below are deliberately the opposite way round
    # from the intuitive pairing, and change nothing.
    #
    # Both assert their own precondition on the flash expansion, so neither can pass for the
    # wrong reason if the drum's geometry or the threshold moves.
    def watered(op, kg, temperature_k)
      boiler = op.nodes.fetch(:boiler)
      parcels = [ ReactorSim::Parcel.build(resource: :water, kg: kg, temperature_k: temperature_k,
                                           content: op.content) ]
      settled, = ReactorSim::Resources::Saturation.solve(
        :water, :steam, parcels, volume_m3: boiler.volume_m3, content: op.content
      )
      boiler.rebalance(op.state.fetch(:nodes).fetch(:boiler).merge(parcels: settled), op.content)
    end

    def threshold = ReactorSim::Nodes::Boiler::FLASH_EXPANSION_FOR_RUPTURE

    it "calls it an explosion when there is real water at real pressure behind the plate" do
      op = engine.operation(:eng)
      boiler = op.nodes.fetch(:boiler)
      state = watered(op, 2_000.0, 433.0)

      expect(boiler.flash_expansion(state, ctx_for(op))).to be > threshold
      expect(boiler.failure_mode(state, ctx_for(op), :fatigue)).to be(:explosion)
    end

    # A cold drum has no superheat to release, so opening it is a leak rather than a blast.
    # This is the only regime in which a boiler goes quietly.
    it "calls it a seam split when there is no superheat to release, whatever the cause" do
      op = engine.operation(:eng)
      boiler, state = node_and_state(op, :boiler)

      expect(boiler.flash_expansion(state, ctx_for(op))).to be < threshold
      expect(boiler.failure_mode(state, ctx_for(op), :overload)).to be(:seam_split)
    end

    # **Flash fraction against the steam tables.** At 609 kPa water boils at about 159 °C; drop
    # it to atmospheric and that 59 K of superheat buys `c_p·ΔT / h_fg` ≈ 11% of the mass as
    # steam, instantly. Held to a wide tolerance because the engine's Clausius–Clapeyron curve
    # is a two-point fit rather than a steam table — what must not drift is the order of
    # magnitude, because that is what makes the drum dangerous.
    it "flashes about a tenth of the water at working pressure" do
      op = engine.operation(:eng)
      boiler = op.nodes.fetch(:boiler)
      state = watered(op, 2_000.0, 433.0)

      expect(boiler.pressure_pa(state, op.content)).to be_within(80_000).of(600_000)
      expect(boiler.flash_steam_kg(state, ctx_for(op)) / 2_000.0).to be_within(0.03).of(0.11)
    end
  end

  # A breach is how a failed holder actually spills. Its whole trick is that it is built with
  # the machine and shut, because the graph is configuration and **a node cannot open a path in
  # its own graph** — see docs/design_sketches/failure_model.md §7.
  describe "a breach" do
    let(:content) do
      ReactorSim::Content.build(resources: {
        steam: { tags: [ :gas ], specific_heat_j_per_kg_k: 2080, molar_mass_g_per_mol: 18.0,
                 density_kg_per_m3: 0.6 },
        # `Atmosphere` fills itself with air by default, so the registry has to know about it.
        air: { tags: [ :gas ], specific_heat_j_per_kg_k: 1005, molar_mass_g_per_mol: 29.0,
               density_kg_per_m3: 1.2 }
      })
    end

    # drum -> [breach] -> sky, and nothing else. A pressure-driven path, so the breach's
    # conductance is the whole restriction.
    def rig(opens_by: { seam_split: 0.01, explosion: 1.0 })
      drum = ReactorSim::Nodes::Vessel.new(
        id: :drum, volume_m3: 5.0, initial_temperature_k: 450.0,
        initial_contents: [ { resource: :steam, kg: 40.0, temperature_k: 450.0 } ],
        ports: [ ReactorSim::Port.new(id: :breach_out, direction: :outlet) ]
      )
      breach = ReactorSim::Nodes::Breach.new(
        id: :hole, senses: :drum, opens_by: opens_by,
        max_kg_per_s: 60.0, conductance: 1.0, heat_capacity: 1.0
      )
      ReactorSim::Operation.new(
        id: :rig, type: :rig, seed: 1, content: content,
        nodes: [ drum, breach, ReactorSim::Nodes::Atmosphere.new ],
        links: [ ReactorSim::Link.new(from: [ :drum, :breach_out ], to: [ :hole, :inlet ]),
                 ReactorSim::Link.new(from: [ :hole, :outlet ], to: [ :atmosphere, :spill ]) ]
      )
    end

    def held(op) = op.nodes.fetch(:drum).contents_kg(op.state.fetch(:nodes).fetch(:drum))

    def fail_drum!(op, mode)
      nodes = op.state.fetch(:nodes)
      op.instance_variable_set(
        :@state, op.state.merge(nodes: nodes.merge(drum: nodes.fetch(:drum).merge(failure: mode)))
      )
    end

    def run(op, ticks = 20) = ticks.times { |i| op.step!(tick: i + 1) }

    # The whole reason this design is affordable: a breach that is built but shut costs nothing,
    # because `Arbiter.gas_coupling` rejects a conductance at or below zero and `throughput_kg`
    # is zero too. It is on neither solve.
    it "holds everything in while the part is sound" do
      op = rig
      before = held(op)
      run(op)

      expect(held(op)).to be_within(1e-9).of(before)
      expect(op.ledger.fetch(:mass_spilled)).to be_within(1e-9).of(0.0)
    end

    # **It empties to ambient, not to nothing.** 40 kg of steam in 5 m³ at 450 K is about
    # 6 atmospheres; once the drum is level with the sky roughly 2.4 kg is still in there, and it
    # stays. A breach is a hole, not a vacuum pump — anything asserting the drum goes to zero
    # would be asserting a bug.
    it "opens once the part it watches fails" do
      op = rig
      before = held(op)
      fail_drum!(op, :explosion)
      run(op)

      expect(held(op)).to be < before * 0.1
      expect(held(op)).to be > 1.0
      expect(op.ledger.fetch(:mass_spilled)).to be > 30.0
    end

    # The spectrum is the point of the whole failure model: a seam weeping and a shell letting
    # go must not be the same event.
    # Two traps here, both of which produced a passing-looking wrong answer first.
    #
    # **The sizes have to be orders apart to be distinguishable**: at 0.01 of bore this drum
    # emptied in twenty ticks just as completely as at 1.0, so the first version compared
    # 37.56 kg against 37.56 kg and called the spectrum proven. A weep is *orders* smaller than
    # a shell opening.
    #
    # **And total spill saturates, so it is the wrong measure.** A full-bore breach finishes
    # inside a couple of ticks; comparing twenty-tick totals compares "done" against "still
    # going" and understates the gap badly (3× for a 10,000× difference in hole size). What is
    # left in the drum is the honest comparison, and it is also the one that matters in play —
    # after the same time, has the driver still got steam?
    it "opens by the size the mode names" do
      sizes = { seam_split: 1.0e-4, explosion: 1.0 }
      split = rig(opens_by: sizes).tap { |op| fail_drum!(op, :seam_split) }
      burst = rig(opens_by: sizes).tap { |op| fail_drum!(op, :explosion) }
      run(split)
      run(burst)

      expect(split.ledger.fetch(:mass_spilled)).to be > 0.0
      expect(held(split)).to be > held(burst) * 5.0
    end

    # A part can carry several breaches of different sizes reading the same latch, so a hole
    # that does not recognise the mode has to stay shut rather than guess.
    it "stays shut for a mode it does not name" do
      op = rig(opens_by: { explosion: 1.0 })
      fail_drum!(op, :seam_split)
      before = held(op)
      run(op)

      expect(held(op)).to be_within(1e-9).of(before)
    end

    # **`mass_spilled` had no writer at all before this** — `settlement.md` carried it as
    # reserved. A safety valve lifting and a drum bursting must not be the same number, which is
    # why `Atmosphere` books its two inlets apart.
    it "books damage as spilled rather than as deliberate discharge" do
      op = rig
      fail_drum!(op, :explosion)
      run(op)

      expect(op.ledger.fetch(:mass_spilled)).to be > 30.0
      expect(op.ledger.fetch(:mass_vented)).to be_within(1e-9).of(0.0)
    end

    # The change most likely to be quietly wrong, because it puts mass on a ledger line nothing
    # has ever summed.
    it "conserves mass and energy exactly across the burst" do
      op = rig
      mass = ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)
      joules = ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger)
      fail_drum!(op, :explosion)
      run(op, 40)

      expect(ReactorSim::Ledger.mass_balance(op.total_mass, op.ledger)).to be_within(1e-6).of(mass)
      expect(ReactorSim::Ledger.energy_balance(op.total_joules, op.ledger))
        .to be_within(1e-3).of(joules)
    end
  end

  # §6: a bursting part throws its shell at whatever is near it, and that matters in exactly two
  # places — it breaks adjacent machinery and it injures nearby crew. **Fiat, deliberately.**
  # There is no release-energy term and no blast model; a mode names its casualties and the
  # engine spends that as durability. Nothing is created, so conservation is untouched by
  # construction rather than by a clamp.
  describe "collateral damage" do
    it "is wiring rather than physics, so it is configured on the part" do
      op = engine.operation(:eng)

      expect(op.nodes.fetch(:boiler).failure_damages)
        .to include(explosion: hash_including(:cylinder))
      # A generic `Nodes::Vessel` cannot know a cylinder exists, so an unconfigured one hurts
      # nobody. That is the line between the class and the machine.
      expect(op.nodes.fetch(:steam_chest).failure_damages).to be_empty
    end

    # A part rated so far below what it holds that it fatigues through its durability in a few
    # ticks — the point is the transition, not how long it takes to get there.
    def doomed_rig
      content = ReactorSim::Content.build(resources: {
        steam: { tags: [ :gas ], specific_heat_j_per_kg_k: 2080, molar_mass_g_per_mol: 18.0,
                 density_kg_per_m3: 0.6 }
      })
      victim = ReactorSim::Nodes::Vessel.new(
        id: :victim, volume_m3: 1.0, initial_temperature_k: 500.0,
        initial_contents: [ { resource: :steam, kg: 20.0, temperature_k: 500.0 } ],
        max_pressure_pa: 1.0, stress_rate: 1.0e7, damages: { rupture: { witness: 0.5 } }
      )
      witness = ReactorSim::Nodes::Vessel.new(id: :witness, volume_m3: 1.0)
      ReactorSim::Operation.new(id: :rig, type: :rig, seed: 1, content: content,
                                nodes: [ victim, witness ], links: [])
    end

    it "spends a share of what the bystander started with, when the part actually fails" do
      op = doomed_rig
      start = op.state.fetch(:nodes).fetch(:witness)
      10.times { |i| op.step!(tick: i + 1) }
      after = op.state.fetch(:nodes).fetch(:witness)

      expect(op.state.fetch(:nodes).fetch(:victim).fetch(:failure)).to be(:rupture)
      expect(after.fetch(:durability))
        .to be_within(1e-6).of(start.fetch(:durability) - (start.fetch(:initial_durability) * 0.5))
    end

    # It is spent on the transition, not every tick the part is broken — otherwise a failed
    # part would grind its neighbours to nothing at the tick rate.
    it "is spent once, not every tick afterwards" do
      op = doomed_rig
      10.times { |i| op.step!(tick: i + 1) }
      once = op.state.fetch(:nodes).fetch(:witness).fetch(:durability)
      40.times { |i| op.step!(tick: i + 11) }

      expect(op.state.fetch(:nodes).fetch(:witness).fetch(:durability)).to be_within(1e-6).of(once)
    end
  end

  # §5 of the sketch, and the reason the early return in `apply_wear` had to go: an early,
  # mild failure must never immunise a part against a catastrophic one. A cracked pipe that
  # goes on being fed should be able to tear open; a reactor that has lost a seal must still be
  # able to melt down.
  describe "escalation" do
    let(:boiler) { engine.operation(:eng).nodes.fetch(:boiler) }

    it "moves forward through the declared order" do
      expect(boiler.escalate_to(:seam_split, :explosion)).to be(:explosion)
    end

    # Without this a drum that had exploded would be re-described as merely split the moment
    # its own hole took the pressure away — the conditions that destroyed it are gone precisely
    # *because* it was destroyed.
    it "never moves back, however the conditions change afterwards" do
      expect(boiler.escalate_to(:explosion, :seam_split)).to be(:explosion)
    end

    it "treats a mode the table does not name as the worst thing available" do
      expect(boiler.escalate_to(:explosion, :something_unmodelled)).to be(:something_unmodelled)
    end

    it "emits nothing when the mode has not changed" do
      op = engine.operation(:eng)
      flywheel = op.nodes.fetch(:flywheel)
      already = op.state.fetch(:nodes).fetch(:flywheel).merge(failure: :burst)
      ctx = ReactorSim::Operation::Context.new(
        controls: {}, dt: ReactorSim::DT, tick: 1, content: op.content,
        nodes: op.nodes, states: op.state.fetch(:nodes)
      )

      state, events = flywheel.break_part(already, ctx, :overload)

      expect(events).to be_empty
      expect(state).to be(already)
    end
  end
end
