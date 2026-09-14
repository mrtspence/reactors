# frozen_string_literal: true

require "reactor_sim"

# What crosses, as opposed to how much.
#
# A stream used to carry the composition of whatever it came from, in exactly the proportion it
# was held, and the only other control was a port's binary tag filter. That is two settings, and
# for a cylinder exhausting condensate up a chimney **both of them were wrong**: `[:gas]`
# stranded the water until the cylinder flooded to 21.9 kg, and permissive carried it away
# preferentially, since the stroke sweeps a volume and water is a thousand times denser than the
# steam carrying it.
#
# `Node#transport_affinity` is the third thing a part can say. Design and the rejected
# alternatives: `docs/design_sketches/tag_based_transport_overrides.md`.
RSpec.describe "transport affinity" do
  let(:rng) { ReactorSim::Rng.stream(1, :affinity) }

  # **Inert substances with no phase model.** Real water boils, and a rig built on it measures
  # evaporation as well as apportionment — the composition drifted from 90% to 82% while the
  # thing under test had not moved at all. `brine` and `lye` are both liquids so the tag gate
  # never fires; `lye` carries a second tag so the within-a-port combining rule has something to
  # combine.
  let(:content) do
    ReactorSim::Content.build(resources: {
      brine: { tags: [ :liquid ], specific_heat_j_per_kg_k: 3900, density_kg_per_m3: 1100 },
      lye: { tags: [ :liquid, :reagent ], specific_heat_j_per_kg_k: 2500,
             density_kg_per_m3: 1050 }
    })
  end

  # Two tanks and a pipe. The source holds a mixture; what reaches the sink is the question.
  def rig(affinity: nil, kg: { brine: 90.0, lye: 10.0 })
    source = Class.new(ReactorSim::Nodes::Vessel) do
      attr_accessor :declared
      def transport_affinity(_port_id, _state, _ctx) = declared || {}
    end.new(
      id: :source, volume_m3: 10.0,
      ports: [ ReactorSim::Port.new(id: :out, direction: :outlet, max_kg_per_s: 4.0) ]
    )
    source.declared = affinity

    sink = ReactorSim::Nodes::Vessel.new(
      id: :sink, volume_m3: 10.0,
      ports: [ ReactorSim::Port.new(id: :in, direction: :inlet, max_kg_per_s: 4.0) ]
    )
    line = ReactorSim::Nodes::Conduit.new(id: :line, max_kg_per_s: 1.0, heat_capacity: 1.0e3)

    op = ReactorSim::Operation.new(
      id: :rig, type: :affinity_rig, seed: 3, content: content,
      nodes: [ source, sink, line ],
      links: [ ReactorSim::Link.new(from: [ :source, :out ], to: [ :line, :inlet ]),
               ReactorSim::Link.new(from: [ :line, :outlet ], to: [ :sink, :in ]) ],
      control_points: [], diagnostics: []
    )

    seeded = op.state.fetch(:nodes).fetch(:source).merge(
      parcels: kg.map { |resource, mass|
        ReactorSim::Parcel.build(resource: resource, kg: mass, temperature_k: 300.0, content: content)
      }
    )
    op.instance_variable_set(:@state,
                             op.state.merge(nodes: op.state.fetch(:nodes).merge(source: seeded)))
    op
  end

  def delivered(op, ticks: 8)
    (1..ticks).each { |t| op.step!(tick: t) }
    op.state.fetch(:nodes).fetch(:sink).fetch(:parcels, [])
      .to_h { |p| [ p.fetch(:resource).to_sym, p.fetch(:kg) ] }
  end

  describe "with nobody expressing an opinion" do
    it "carries the mixture it came from, in proportion" do
      got = delivered(rig)
      total = got.values.sum

      expect(got.fetch(:brine) / total).to be_within(0.01).of(0.9)
      expect(got.fetch(:lye) / total).to be_within(0.01).of(0.1)
    end

    # The guarantee that made this safe to build: a neutral opinion is not merely close to no
    # opinion, it is the same arithmetic. The weighted branch must reproduce
    # proportional-by-mass exactly, or every existing balance in the game would have shifted
    # under it.
    it "is bit-identical to a neutral affinity on every tag" do
      plain = delivered(rig)
      neutral = delivered(rig(affinity: { liquid: 1.0 }))

      expect(neutral).to eq(plain)
    end
  end

  describe "biasing the mix" do
    it "holds a substance back when its affinity is below one" do
      got = delivered(rig(affinity: { brine: 0.01 }))
      total = got.values.sum

      expect(got.fetch(:lye) / total).to be > 0.5
      expect(got.fetch(:brine)).to be > 0.0
    end

    it "carries more of a substance than its share when its affinity is above one" do
      got = delivered(rig(affinity: { lye: 50.0 }))
      total = got.values.sum

      expect(got.fetch(:lye) / total).to be > 0.8
    end

    # **The decision most likely to be quietly undone.** An affinity that could change the total
    # would be a second throughput control, and two numbers describing one restriction is a
    # mistake this engine has already made twice — `max_kg_per_s` against `conductance`, and the
    # `extractable_joules` clamp silently becoming the throttle. Rate is rate; this is mix.
    it "changes the mix and not the total, on a rate-driven path" do
      plain = delivered(rig).values.sum
      biased = delivered(rig(affinity: { brine: 0.01 })).values.sum

      expect(biased).to be_within(1e-9).of(plain)
    end

    # Hard exclusion belongs in a port's `accepts:`, where it is structural and visible in the
    # operation definition. A zero here would be a deadlock wearing the costume of a tuning
    # value — and it would make a separator perfect, which no real one is.
    it "never excludes something entirely, however extreme the weight" do
      got = delivered(rig(affinity: { brine: 0.0 }))

      expect(got.fetch(:brine)).to be > 0.0
    end
  end

  describe "combining" do
    # Mirrors the tag gate exactly: `accepts?` is OR within a port, `ports.all?` is AND across
    # them. Keep the shapes the same and the boolean gate stays the limiting case of the
    # weighted rule instead of drifting away from it.
    it "takes the most permissive matching tag within one port" do
      # `lye` is tagged :liquid and :reagent here; the higher of the two wins.
      generous = delivered(rig(affinity: { liquid: 1.0, reagent: 50.0 }))
      total = generous.values.sum

      expect(generous.fetch(:lye) / total).to be > 0.5
    end

    it "prefers an exact resource key over any tag that also matches" do
      by_tag = delivered(rig(affinity: { liquid: 50.0 }))
      by_resource = delivered(rig(affinity: { liquid: 50.0, brine: 0.01 }))

      expect(by_tag.fetch(:brine) / by_tag.values.sum).to be_within(0.01).of(0.9)
      expect(by_resource.fetch(:brine) / by_resource.values.sum).to be < 0.5
    end
  end

  # A `Boiler` declares the steam quality it delivers and the multiplier is solved for, because
  # nobody would have guessed 1.2e-5 and a fixed multiplier would stop meaning the same thing
  # the moment the water level moved.
  describe "a boiler declares steam quality, not a multiplier" do
    # Real water and real steam here: the point of this group is the phase split, which the
    # inert pair above deliberately does not have.
    let(:content) { ReactorSim::Content.default }

    def drum(fill_m3:, **overrides)
      node = ReactorSim::Nodes::Boiler.new(
        id: :drum, volume_m3: 5.0, steam_port: :steam_out,
        wetness: 0.005, foaming_wetness: 0.30, onset_fill: 0.55,
        ports: [ ReactorSim::Port.new(id: :steam_out, direction: :outlet, max_kg_per_s: 2.0) ],
        **overrides
      )
      state = node.rebalance(
        node.initial_state(rng, content).merge(parcels: [
          ReactorSim::Parcel.build(resource: :water, kg: fill_m3 * 1000.0,
                                   temperature_k: 420.0, content: content),
          ReactorSim::Parcel.build(resource: :steam, kg: 6.0, temperature_k: 420.0, content: content)
        ]), content
      )
      [ node, state ]
    end

    it "delivers its calm quality while the level is below the onset" do
      node, state = drum(fill_m3: 2.5)

      expect(node.carryover_wetness(state, content)).to be_within(1e-9).of(0.005)
    end

    it "gets steadily wetter as it is overfilled" do
      calm = drum(fill_m3: 2.5)
      high = drum(fill_m3: 3.5)
      brimming = drum(fill_m3: 4.8)

      wet = [ calm, high, brimming ].map { |n, s| n.carryover_wetness(s, content) }

      expect(wet).to eq(wet.sort)
      expect(wet.last).to be > 0.15
    end

    # **A level is the liquid.** `contents_volume` prices gases at nominal density too, and
    # using it read a 317%-full boiler that primed itself to death from the first tick.
    it "measures its level by the liquid, not by everything it holds" do
      node, state = drum(fill_m3: 2.5)
      gassy = node.rebalance(
        state.merge(parcels: state.fetch(:parcels) + [
          ReactorSim::Parcel.build(resource: :air, kg: 50.0, temperature_k: 420.0, content: content)
        ]), content
      )

      expect(node.carryover_wetness(gassy, content))
        .to be_within(1e-9).of(node.carryover_wetness(state, content))
    end

    it "solves for a multiplier that produces the quality it declared" do
      node, state = drum(fill_m3: 2.5)
      ctx = ReactorSim::Tick::Context.new(
        controls: {}, dt: 0.25, tick: 1, content: content,
        nodes: { drum: node }, states: { drum: state }
      )

      weight = node.transport_affinity(:steam_out, state, ctx).fetch(:liquid)
      liquid = 2500.0
      gas = 6.0

      expect(weight * liquid / ((weight * liquid) + gas)).to be_within(1e-6).of(0.005)
    end

    it "has no opinion about any port but its steam outlet" do
      node, state = drum(fill_m3: 4.8)
      ctx = ReactorSim::Tick::Context.new(
        controls: {}, dt: 0.25, tick: 1, content: content,
        nodes: { drum: node }, states: { drum: state }
      )

      expect(node.transport_affinity(:feed_in, state, ctx)).to eq({})
    end
  end
end
