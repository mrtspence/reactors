# frozen_string_literal: true

require "reactor_sim"

# Slots, parts and the validator that stands between a player and a machine that cannot run.
#
# The two halves of this file test different things and the split is deliberate. The first
# builds a deliberately tiny registry, because the mechanism has to be testable without the
# steam engine's twenty parts obscuring which rule fired. The second points the same machinery
# at the real engine, because a mechanism that works on a toy and not on the thing it was
# built for has proved nothing.
RSpec.describe ReactorSim::Assembly do
  # Constants are qualified rather than mixed in: `include ReactorSim` would reach method
  # lookup but not constant lookup, which is lexical, and including it at top level would
  # pollute `Object` for every other spec sharing the process.
  Fragment = ReactorSim::Fragment
  Slot = ReactorSim::Slot
  Part = ReactorSim::Part
  Link = ReactorSim::Link
  Port = ReactorSim::Port
  Nodes = ReactorSim::Nodes
  SteamEngine = ReactorSim::Operations::SteamEngine

  # A two-vessel rig: a tank, a pipe to somewhere, and an optional filter in between. Enough
  # to exercise every verdict without being enough to distract.
  def registry
    reg = Module.new do
      @parts = {}
      class << self
        def register(id, **kwargs, &) = @parts[id] = ReactorSim::Part.new(id: id, **kwargs, &)
        def fetch(id) = @parts.fetch(id.to_sym) { raise ReactorSim::Error, "unknown part #{id}" }
        def key?(id) = @parts.key?(id.to_sym)
      end
    end

    # Permissive ports at both ends, so the PIPE is the only tag gate on the route and the
    # reachability examples below turn on the one thing they are about. That is also the
    # property worth demonstrating: material has to satisfy every port along a path, so one dry
    # tag in the middle of a wet line silently repeals it — which is how the chimney and the
    # steam line each lost their condensate once.
    reg.register(:plain_tank, kind: :tank, provides: %i[tank]) do |_spec|
      Fragment.new(nodes: [ vessel(:tank, []) ])
    end
    reg.register(:plain_sink, kind: :sink, provides: %i[sink]) do |_spec|
      Fragment.new(nodes: [ vessel(:sink, []) ])
    end
    reg.register(:straight_pipe, kind: :pipe, provides: %i[pipe]) do |_spec|
      Fragment.new(
        nodes: [ Nodes::Conduit.new(id: :pipe, accepts: [ :liquid ], max_kg_per_s: 1.0) ],
        links: [ Link.new(from: [ :tank, :out ], to: [ :pipe, :inlet ]),
                 Link.new(from: [ :pipe, :outlet ], to: [ :sink, :in ]) ]
      )
    end
    # A gas-only pipe, so the route check has something to refuse that is structurally fine.
    reg.register(:gas_pipe, kind: :pipe, provides: %i[pipe]) do |_spec|
      Fragment.new(
        nodes: [ Nodes::Conduit.new(id: :pipe, accepts: [ :gas ], max_kg_per_s: 1.0) ],
        links: [ Link.new(from: [ :tank, :out ], to: [ :pipe, :inlet ]),
                 Link.new(from: [ :pipe, :outlet ], to: [ :sink, :in ]) ]
      )
    end
    reg.register(:liar, kind: :tank, provides: %i[tank extra]) { |_s| Fragment.new(nodes: []) }
    reg.register(:squatter, kind: :sink, provides: %i[sink]) do |_spec|
      # Names a node the tank already owns. The collision the flat id namespace exists to catch.
      Fragment.new(nodes: [ vessel(:sink, []), vessel(:tank, []) ])
    end
    reg
  end

  def vessel(id, accepts)
    Nodes::Vessel.new(
      id: id, volume_m3: 1.0,
      ports: [ Port.new(id: :in, direction: :inlet, accepts: accepts, max_kg_per_s: 1.0),
               Port.new(id: :out, direction: :outlet, accepts: accepts, max_kg_per_s: 1.0) ]
    )
  end

  def slots(pipe_required: true)
    [ Slot.new(id: :tank, accepts: :tank, required: true, default: :plain_tank),
      Slot.new(id: :pipe, accepts: :pipe, required: pipe_required, default: :straight_pipe),
      Slot.new(id: :sink, accepts: :sink, required: true, default: :plain_sink) ]
  end

  def assemble(loadout: {}, **kwargs)
    described_class.new(slots: slots(**kwargs.slice(:pipe_required)), loadout: loadout,
                        registry: registry, **kwargs.except(:pipe_required))
  end

  describe "the loadout" do
    it "fills every unmentioned slot from its default" do
      expect(assemble.loadout).to eq({ tank: :plain_tank, pipe: :straight_pipe,
                                       sink: :plain_sink })
    end

    # The trap that makes a restore rebuild a different machine. `options:` goes through JSON,
    # `deep_symbolize` converts keys only, so a part id arrives back as a String and misses
    # every lookup — and `canonical` cannot see the difference, because JSON.generate makes
    # :plain_tank and "plain_tank" the same string. Only identity finds it.
    it "symbolises part ids that arrived as strings" do
      loadout = assemble(loadout: { "pipe" => "straight_pipe" }).loadout

      expect(loadout.fetch(:pipe)).to be(:straight_pipe)
    end

    # A loadout recording only what is fitted would fall back to the default on restore and
    # quietly grow the part back. Every slot is named, empty ones included.
    it "names every slot, so a deliberately empty one stays empty" do
      loadout = assemble(loadout: { pipe: nil }, pipe_required: false).loadout

      expect(loadout).to have_key(:pipe)
      expect(loadout.fetch(:pipe)).to be_nil
    end

    it "reads :none as empty, for a form that cannot send nil" do
      expect(assemble(loadout: { pipe: :none }, pipe_required: false).loadout.fetch(:pipe))
        .to be_nil
    end
  end

  describe "errors — these refuse the build" do
    it "refuses a required slot with nothing in it" do
      verdict = assemble(loadout: { pipe: nil }).verdict

      expect(verdict).not_to be_ok
      expect(verdict.errors.join).to match(/Pipe is required/)
    end

    it "refuses a part that does not fit the slot" do
      verdict = assemble(loadout: { pipe: :plain_tank }).verdict

      expect(verdict.errors.join).to match(/takes a pipe.*is a tank/)
    end

    it "refuses a part that does not exist" do
      expect(assemble(loadout: { pipe: :nonesuch }).verdict.errors.join)
        .to match(/no such part :nonesuch/)
    end

    it "refuses a slot that is not on this chassis" do
      expect(assemble(loadout: { flux_capacitor: :straight_pipe }).verdict.errors.join)
        .to match(/no slot :flux_capacitor/)
    end

    # `provides:` is the id contract the wiring, the gauges and the rng streams all rely on.
    it "refuses a part that promises an id it does not build" do
      expect(assemble(loadout: { tank: :liar }).verdict.errors.join)
        .to match(/provides tank, extra but does not build/)
    end

    # Ids are one flat namespace because they key one rng table, and assembly makes a
    # collision likely for the first time. Naming both slots is the point — the id alone does
    # not tell you which two fittings are fighting over it.
    it "refuses two parts that define the same id, and names both slots" do
      errors = assemble(loadout: { sink: :squatter }).verdict.errors.join

      expect(errors).to match(/both define :tank/)
      expect(errors).to match(/Tank/).and match(/Sink/)
    end

    # The check that catches "assembles perfectly, cannot possibly work". Asked through the
    # real router rather than a second model of the graph.
    it "refuses a build where the material cannot reach its destination" do
      verdict = described_class.new(
        slots: slots, loadout: { pipe: :gas_pipe }, registry: registry,
        routes: [ { from: :tank, to: :sink, carrying: :liquid, as: "no route for liquid" } ]
      ).verdict

      expect(verdict.errors).to include("no route for liquid")
    end

    it "accepts the same build for the tag the pipe does carry" do
      verdict = described_class.new(
        slots: slots, loadout: { pipe: :gas_pipe }, registry: registry,
        routes: [ { from: :tank, to: :sink, carrying: :gas } ]
      ).verdict

      expect(verdict).to be_ok
    end

    it "raises on build! rather than returning a broken graph" do
      expect { assemble(loadout: { pipe: nil }).build! }
        .to raise_error(ReactorSim::Error, /cannot assemble/)
    end
  end

  # **A legal build and a wise build are different questions, and conflating them would delete
  # the game's risk/reward axis.** An engine with no fusible plug assembles, runs, and is a
  # perfectly reasonable thing to choose; the hazard sitting underneath the safety is what
  # makes going without one a decision rather than a strictly-worse choice.
  describe "warnings — these do not" do
    it "warns about an empty slot without refusing the build" do
      verdict = described_class.new(
        slots: slots(pipe_required: false), loadout: { pipe: nil }, registry: registry,
        advisories: [ { slot: :pipe, says: "Nothing connects the tank to anything." } ]
      ).verdict

      expect(verdict).to be_ok
      expect(verdict.warnings).to eq([ "Nothing connects the tank to anything." ])
    end

    it "says nothing when the slot is filled" do
      verdict = described_class.new(
        slots: slots(pipe_required: false), loadout: {}, registry: registry,
        advisories: [ { slot: :pipe, says: "Nothing connects the tank to anything." } ]
      ).verdict

      expect(verdict.warnings).to be_empty
    end
  end

  describe "Slot declarations" do
    it "refuses a bypass on a required slot, which can never be empty" do
      expect { Slot.new(id: :s, accepts: :k, required: true, bypass: [ [ :a, :b ], [ :c, :d ] ]) }
        .to raise_error(ReactorSim::Error, /never empty/)
    end

    it "refuses :bypass with nowhere to bypass to" do
      expect { Slot.new(id: :s, accepts: :k, when_empty: :bypass) }
        .to raise_error(ReactorSim::Error, /needs the two ends/)
    end

    # An unused declaration is a statement nothing checks, which is how a silent off switch
    # gets written — and this engine has already paid for five of those.
    it "refuses a bypass that :omit would never use" do
      expect { Slot.new(id: :s, accepts: :k, when_empty: :omit, bypass: [ [ :a, :b ], [ :c, :d ] ]) }
        .to raise_error(ReactorSim::Error, /never be used/)
    end

    it "joins the two ends when a bypassable slot is empty" do
      slot = Slot.new(id: :pipe, accepts: :pipe, when_empty: :bypass,
                      bypass: [ [ :tank, :out ], [ :sink, :in ] ])
      fragment = described_class.new(slots: [ slot ], loadout: { pipe: nil },
                                     registry: registry).fragment

      expect(fragment.links.map(&:id)).to eq([ :"tank.out->sink.in" ])
    end

    it "makes no link at all when an :omit slot is empty" do
      slot = Slot.new(id: :pipe, accepts: :pipe, when_empty: :omit)
      fragment = described_class.new(slots: [ slot ], loadout: { pipe: nil },
                                     registry: registry).fragment

      expect(fragment.links).to be_empty
    end
  end

  # The mechanism pointed at the machine it was built for.
  describe "the real steam engine" do
    def spec = SteamEngine::CHASSIS.fetch(:high_pressure)

    def real(loadout: {}, chassis: :high_pressure)
      s = SteamEngine::CHASSIS.fetch(chassis)
      described_class.new(
        slots: SteamEngine.slots(s), loadout: loadout, spec: s,
        fixtures: SteamEngine.fixtures(s), instruments: SteamEngine.catalogue(s),
        routes: SteamEngine::ROUTES, advisories: SteamEngine::ADVISORIES
      )
    end

    it "assembles the stock engine cleanly" do
      expect(real.verdict).to be_ok
      expect(real.verdict.warnings).to be_empty
    end

    # **The registry can be asked which frames a type offers**, rather than reached into.
    # Added for the blueprint catalogue, which has to enumerate chassis because each one is
    # separately unlockable — and the alternative was a hand-written map from operation type to
    # `SomeOperation::CHASSIS`, which is an inventory list and drifts the first time somebody
    # adds a frame. It is introspection, not configuration: no tick reads it.
    describe "the operation registry's chassis enumeration" do
      it "names every frame the chassis table has, and only those" do
        expect(ReactorSim::Operations.chassis_for(:steam_engine))
          .to match_array(SteamEngine::CHASSIS.keys)
      end

      # The derivation is the point. A literal list passed at registration would pass this the
      # day it was written and rot the day a third frame arrived.
      it "grows on its own when a frame is added" do
        expect(ReactorSim::Operations.chassis_for(:steam_engine).length)
          .to eq(SteamEngine::CHASSIS.length)
      end

      it "raises on a type nobody registered" do
        expect { ReactorSim::Operations.chassis_for(:water_wheel) }
          .to raise_error(ReactorSim::Error, /unknown operation type/)
      end
    end

    # **The loadout has to identify a machine.** Before stage 3 it did not: both chassis fitted
    # `:stock_boiler`, which was one name for two drums of different radius and plate thickness,
    # because the numbers lived on the chassis and the part only read them. That is a lie the
    # outfitting screen cannot work around — `Parts.fetch(:stock_boiler).stats` had nothing true
    # to say — and it is why stage 3 existed.
    it "fits genuinely different parts on the two chassis, not one part reading two specs" do
      hp = real.loadout
      watt = real(chassis: :atmospheric).loadout

      %i[boiler chimney damper safety_valve cylinder cylinder_relief flywheel load].each do |kind|
        expect(hp.fetch(kind)).not_to eq(watt.fetch(kind)),
                                      "#{kind} is the same part id on both chassis"
      end

      # And the shared ones really are shared — otherwise the assertion above proves nothing
      # except that every id is unique.
      %i[firebox stoker bunker regulator steam_chest feedwater].each do |kind|
        expect(hp.fetch(kind)).to eq(watt.fetch(kind))
      end
    end

    # `group:` is what lets the outfitting screen read down a machine by system instead of
    # scattering the four fittings on the boiler across the page. It defaults to `:other`, which
    # is a silent fallback — exactly the shape of off switch this engine has paid for five times
    # — so a slot that never got one has to fail here rather than quietly landing in a bin at
    # the bottom of the screen.
    it "puts every slot in a real group, on both chassis" do
      %i[high_pressure atmospheric].each do |chassis|
        ungrouped = real(chassis: chassis).slots.select { |s| s.group == :other }

        expect(ungrouped).to be_empty, "#{chassis}: #{ungrouped.map(&:id).join(', ')} has no group"
      end
    end

    # **Two parts of one kind may not share a label**, because the only place a player ever
    # chooses between them is a dropdown that shows nothing else. Found in play: both dampers
    # read "Damper", so the two were indistinguishable at the one moment the distinction
    # mattered. `label` is not decoration here — it is the entire affordance.
    it "gives every part of a kind a label that tells it apart from its alternatives" do
      ReactorSim::Parts.known
                       .map { |part_id| ReactorSim::Parts.fetch(part_id) }
                       .group_by(&:kind)
                       .each do |kind, parts|
        labels = parts.map(&:label)

        expect(labels.uniq.length).to eq(labels.length),
                                      "#{kind} has two parts labelled #{labels.tally.select { |_, n| n > 1 }.keys.join(', ')}"
      end
    end

    # Every part declares stats for the outfitting screen without being built. A part whose
    # numbers came from the chassis could not — which is the other half of why stage 3 happened.
    it "can describe every fitted part without instantiating it" do
      real.loadout.values.compact.each do |part_id|
        part = ReactorSim::Parts.fetch(part_id)

        expect(part.label).to be_a(String)
        expect(part.stats).to be_a(Hash)
      end
    end

    # The gauge list must not move when the slot list is reordered for some unrelated reason:
    # a player learns a panel by where things are. Selection runs over the catalogue, not over
    # the parts.
    it "orders instruments by the panel's catalogue, not by slot order" do
      catalogue_order = SteamEngine.catalogue(spec).keys

      expect(real.diagnostics.map(&:id)).to eq(catalogue_order - [ :condenser_vacuum ])
    end

    it "brings the condenser's gauge only on the chassis that can fit one" do
      expect(real.diagnostics.map(&:id)).not_to include(:condenser_vacuum)
      expect(real(chassis: :atmospheric).diagnostics.map(&:id)).to include(:condenser_vacuum)
    end

    # Reachability, on the real graph. Deleting the chimney leaves a structurally valid
    # operation that cannot possibly run, and nothing before this check would have said so.
    it "refuses an engine whose fire has no way to breathe out" do
      verdict = real(loadout: { chimney: nil }).verdict

      expect(verdict).not_to be_ok
      expect(verdict.errors.join).to match(/Chimney is required/)
    end

    it "refuses a part fitted in the wrong slot" do
      expect(real(loadout: { boiler: :high_pressure_cylinder }).verdict.errors.join)
        .to match(/takes a boiler.*is a cylinder/)
    end

    # Every part's id contract holds, which is what lets the wiring and the gauges around a
    # part survive it being swapped.
    it "has every part build the ids it promises" do
      expect(real.verdict.errors).to be_empty
      expect(real.fragment.nodes.map(&:id)).to include(:boiler, :cylinder, :flywheel, :relief)
    end

    # **Seven parts can be left out, and none of them may break the build.** This is the whole
    # of stage 2 asserted in one place: what is optional, that removing any one of them still
    # assembles and still passes every route check, and that each one says something before the
    # player finds out the hard way.
    #
    # The list is deliberately written out rather than derived from the slots, because a slot
    # silently becoming optional — or silently ceasing to be — is exactly the kind of change
    # that should fail a spec rather than pass one.
    describe "what can be left out" do
      OPTIONAL = { ash_pan: :omit, blower: :bypass, boiler_tubes: :bypass,
                   drain_cocks: :omit, safety_valve: :omit, fusible_plug: :omit,
                   cylinder_relief: :omit }.freeze

      it "is exactly these seven, with these behaviours" do
        declared = SteamEngine.slots(spec).reject(&:required?)
                              .to_h { |s| [ s.id, s.when_empty ] }

        expect(declared).to eq(OPTIONAL)
      end

      OPTIONAL.each_key do |slot_id|
        context "without the #{slot_id}" do
          let(:stripped) { real(loadout: { slot_id => nil }) }

          it "still assembles and still passes every route check" do
            expect(stripped.verdict.errors).to be_empty
          end

          # The warning copy is game design, not error handling — it is the only thing a player
          # gets before finding out, so an optional part without one is a trap rather than a
          # choice.
          it "warns rather than refusing" do
            expect(stripped.verdict).to be_ok
            expect(stripped.verdict.warnings).not_to be_empty
          end

          # The point of fragments: a part's nodes, links, levers and gauges leave together,
          # with no edit anywhere else. Before this, removing one meant finding all four lists.
          it "takes its own pieces with it and nothing else" do
            expect(stripped.fragment.nodes.length).to be < real.fragment.nodes.length
            expect(stripped.verdict.errors).to be_empty
          end
        end
      end

      # Every required slot is required for a reason that the validator can state. This is the
      # other half: emptying one has to be refused, not merely discouraged.
      it "refuses every slot that is not on that list" do
        SteamEngine.slots(spec).select(&:required?).each do |slot|
          verdict = real(loadout: { slot.id => nil }).verdict

          expect(verdict).not_to be_ok, "#{slot.id} was emptied and the build was allowed"
        end
      end

      # **The condenser is the case that stays a chassis decision rather than becoming
      # optional**, and it is worth pinning so nobody "finishes the job" later. On Watt's engine
      # the vacuum IS the prime mover and the cylinder exhausts into it, so an atmospheric
      # engine without one is not an engine with a part missing — it is an engine whose exhaust
      # has nowhere to go. A slot trying to express "absent means rerouted" would be expressing
      # a chassis. See §6 of `design_sketches/modular_components.md`.
      it "keeps the condenser required on the chassis that has one, and absent on the other" do
        expect(real(chassis: :atmospheric).loadout).to have_key(:condenser)
        expect(real.loadout).not_to have_key(:condenser)
        expect(real(chassis: :atmospheric, loadout: { condenser: nil }).verdict).not_to be_ok
      end
    end

    # **The blower is the first part that was an attribute on somebody else's node**, and the
    # first `:bypass` slot on this engine. Both are worth guarding directly: an attribute
    # cannot be fitted, removed or upgraded, and the whole point of promoting it was to make
    # those three things possible.
    describe "the blower, promoted from an attribute to a part" do
      def air_path(assembly)
        fragment = assembly.build!
        op = ReactorSim::Operation.new(
          id: :e, type: :steam_engine, seed: 1, nodes: fragment.nodes, links: fragment.links,
          thermal_links: fragment.thermal_links, drive_links: fragment.drive_links,
          control_points: fragment.control_points, diagnostics: assembly.diagnostics
        )
        op.paths.find { |p| p.to_node == :firebox && p.to_port == :air_in }
      end

      it "sits in series with the damper on the air path when fitted" do
        expect(air_path(real).conduits).to eq(%i[blower_fan damper])
      end

      # `:bypass` and not `:omit`, because the air still has to get in. A naturally-drawn
      # boiler is a real machine; one whose air path has been deleted is not.
      it "leaves the air path intact when it is not fitted" do
        path = air_path(real(loadout: { blower: nil }))

        expect(path.conduits).to eq([ :damper ])
        expect(path.from_node).to eq(:atmosphere)
      end

      it "takes its node and its lever with it" do
        stripped = real(loadout: { blower: nil })

        expect(stripped.fragment.nodes.map(&:id)).not_to include(:blower_fan)
        expect(stripped.fragment.control_points.map(&:id)).not_to include(:blower)
      end

      it "is legal to build without, and says so" do
        verdict = real(loadout: { blower: nil }).verdict

        expect(verdict).to be_ok
        expect(verdict.warnings.join).to match(/cold stack has no draught/)
      end

      # The node cannot be called `:blower` because the lever already is, and ids are one flat
      # namespace across nodes, levers, gauges and crew — they key one rng table. Third part to
      # hit this, after `:stoker` against `stoking` and `:fusible_plug` against `plug_blown`.
      it "keeps the lever's id and gives the node a different one" do
        expect(real.fragment.control_points.map(&:id)).to include(:blower)
        expect(real.fragment.nodes.map(&:id)).to include(:blower_fan)
      end

      # It is deliberately half-built: the shape is right, the cost is not modelled. The
      # outfitting screen has to be able to say so rather than presenting it as finished.
      it "is flagged as work in progress" do
        expect(ReactorSim::Parts.fetch(:stock_blower).wip).to be(true)
      end
    end

    # The second `:bypass` slot, and the one with the largest consequence. Without the bundle
    # the flue gas goes straight from firebox to chimney and the only fire→water path left is
    # the radiant one — a plain shell boiler, which is what tubes were invented to replace.
    describe "the boiler tubes" do
      it "routes the flue gas through the bundle when fitted" do
        links = real.fragment.links.map(&:id)

        expect(links).to include(:"firebox.flue_out->boiler_tubes.inlet")
        expect(links).not_to include(:"firebox.flue_out->flue.inlet")
      end

      it "sends it straight up the chimney when not" do
        links = real(loadout: { boiler_tubes: nil }).fragment.links.map(&:id)

        expect(links).to include(:"firebox.flue_out->flue.inlet")
        expect(links).not_to include(:"firebox.flue_out->boiler_tubes.inlet")
      end

      # The convective heat path leaves with the part, because it lives in the part's fragment.
      # A thermal link left behind would point at a node that no longer exists, and
      # `validate_graph!` would refuse the whole operation.
      it "takes its thermal link to the drum with it, leaving only the radiant path" do
        fitted = real.fragment.thermal_links.map { |l| [ l.a, l.b ] }
        stripped = real(loadout: { boiler_tubes: nil }).fragment.thermal_links.map { |l| [ l.a, l.b ] }

        expect(fitted).to contain_exactly([ :firebox, :boiler ], [ :boiler_tubes, :boiler ])
        expect(stripped).to contain_exactly([ :firebox, :boiler ])
      end
    end
  end
end
