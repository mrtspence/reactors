# frozen_string_literal: true

require "reactor_sim"

# `Arbiter.entrained` — what a **pressure-driven** path carries.
#
# This file exists because that method had no coverage at all. `transport_affinity_spec` builds
# its rig from a conduit with no `conductance:`, so every example in it exercises the rate-driven
# branch, and the whole pressure-driven half of settlement went untested from the day it landed.
#
# **What that cost: the steam engine's cylinder relief valve passed water in exactly zero
# states.** Lifted, its conductance made the path pressure-driven and `entrained` dropped liquid
# outright because the cylinder declares no affinity for `:relief`; shut, its throughput was
# zero. A valve fitted to relieve hydraulic lock, which could not pass water, sitting under a
# comment that said *"Permissive, because what it has to pass is water"* — and worst in the case
# it exists for, since a fully locked cylinder holds no gas and the path then carries nothing at
# all. Every one of the examples below would have caught it.
#
# The two regimes are genuinely different and the difference is deliberate: a rate limit is a
# mass throughput, so an affinity may only redistribute it; a pressure solve rates the **gas**,
# so condensate rides on top and the total is larger than the figure the solve settled.
RSpec.describe "entrainment on a pressure-driven path" do
  let(:rng) { ReactorSim::Rng.stream(1, :entrainment) }

  # Inert substances with no phase model, for the same reason `transport_affinity_spec` uses
  # them: real water boils, and a rig built on it measures evaporation as well as the thing
  # under test.
  let(:content) do
    ReactorSim::Content.build(resources: {
      brine: { tags: [ :liquid ], specific_heat_j_per_kg_k: 3900, density_kg_per_m3: 1100,
               molar_mass_g_per_mol: 18.0 },
      vapour: { tags: [ :gas ], specific_heat_j_per_kg_k: 2000, density_kg_per_m3: 0.6,
                molar_mass_g_per_mol: 18.0 }
    })
  end

  # Two vessels and a pipe that declares a conductance, which is what opts the path into the
  # pressure regime. Neither end declares an intent, so nothing pushes it back out again.
  def rig(affinity: nil, kg: { vapour: 4.0, brine: 200.0 }, line_kg_per_s: 4.0)
    source = Class.new(ReactorSim::Nodes::Vessel) do
      attr_accessor :declared
      def transport_affinity(_port_id, _state, _ctx) = declared || {}
    end.new(
      id: :source, volume_m3: 5.0, heat_capacity: 1.0e4,
      ports: [ ReactorSim::Port.new(id: :out, direction: :outlet, max_kg_per_s: 50.0) ]
    )
    source.declared = affinity

    sink = ReactorSim::Nodes::Vessel.new(
      id: :sink, volume_m3: 5.0, heat_capacity: 1.0e4,
      ports: [ ReactorSim::Port.new(id: :in, direction: :inlet, max_kg_per_s: 50.0) ]
    )
    line = ReactorSim::Nodes::Conduit.new(
      id: :line, max_kg_per_s: line_kg_per_s, conductance: 0.05, heat_capacity: 1.0e3
    )

    op = ReactorSim::Operation.new(
      id: :rig, type: :entrainment_rig, seed: 3, content: content,
      nodes: [ source, sink, line ],
      links: [ ReactorSim::Link.new(from: [ :source, :out ], to: [ :line, :inlet ]),
               ReactorSim::Link.new(from: [ :line, :outlet ], to: [ :sink, :in ]) ],
      control_points: [], diagnostics: []
    )

    seeded = source.rebalance(
      op.state.fetch(:nodes).fetch(:source).merge(
        parcels: kg.map { |resource, mass|
          ReactorSim::Parcel.build(resource: resource, kg: mass, temperature_k: 420.0,
                                   content: content)
        }
      ), content
    )
    op.instance_variable_set(:@state,
                             op.state.merge(nodes: op.state.fetch(:nodes).merge(source: seeded)))
    op
  end

  # One tick, so the figures are the settlement's own and not an accumulation.
  def moved(op)
    before = held(op, :source)
    op.step!(tick: 1)
    after = held(op, :source)

    before.to_h { |resource, kg| [ resource, kg - after.fetch(resource, 0.0) ] }
  end

  def held(op, id)
    op.state.fetch(:nodes).fetch(id).fetch(:parcels, [])
      .to_h { |p| [ p.fetch(:resource).to_sym, p.fetch(:kg) ] }
  end

  # The invariant the whole method is built around. Conductance rates moles of gas down a
  # gradient, and a droplet hitching a lift does not change how many moles crossed — so the gas
  # figure has to survive the entrainment arithmetic exactly, not approximately.
  describe "the gas figure the pressure solve settled" do
    it "is unchanged by an affinity that drags liquid along with it" do
      dry = moved(rig(affinity: { liquid: 0.0 })).fetch(:vapour)
      wet = moved(rig(affinity: { liquid: 0.01 })).fetch(:vapour)

      expect(wet).to be_within(1e-9).of(dry)
    end

    # Across five orders of magnitude of weight, so this is the invariant and not a coincidence
    # at one setting. Note the liquid *inventory* is deliberately held constant here: more water
    # in the vessel leaves the gas less free volume and genuinely does raise the pressure, so a
    # rig that varied it would be measuring `Pressurized#free_volume` rather than this.
    it "is unchanged across every weight the clamp allows" do
      figures = [ 0.0, 1.0e-4, 1.0, 1.0e4, 1.0e6 ].map { |w|
        moved(rig(affinity: { liquid: w })).fetch(:vapour)
      }

      expect(figures.max - figures.min).to be < 1e-9
    end
  end

  describe "liquid riding with the gas" do
    it "crosses in the proportion the declared weight implies" do
      got = moved(rig(affinity: { liquid: 0.01 }))
      wetness = got.fetch(:brine) / (got.fetch(:brine) + got.fetch(:vapour))

      expect(wetness).to be > 0.0
      expect(wetness).to be < 1.0
    end

    it "adds to the total rather than redistributing it, unlike a rate-driven path" do
      dry = moved(rig(affinity: { liquid: 0.0 })).values.sum
      wet = moved(rig(affinity: { liquid: 0.01 })).values.sum

      expect(wet).to be > dry
    end

    # **The cap that was missing, and it is a physical rule rather than a guard.** The
    # entrainment term is `desired × (1 − gas_share)/gas_share`, which grows without bound as the
    # stream approaches pure liquid — a drum on the point of priming claimed its entire inventory
    # in a single tick. The only thing standing behind it was `scale_by_sink_room`, which scales
    # a claim *uniformly* and so trimmed the gas figure below what the solve settled, silently
    # breaking the invariant above.
    #
    # Conductance rates a gas; it says nothing about how fast water moves through a pipe, which
    # is set by its bore. So `Port#max_kg_per_s` bounds liquid on a pressure-driven path after
    # all — and only liquid.
    it "is held to what the bore can pass, however lopsided the weight" do
      narrow = moved(rig(affinity: { liquid: 1.0e6 }, line_kg_per_s: 0.4))

      expect(narrow.fetch(:brine)).to be <= (0.4 * ReactorSim::DT) + 1e-9
    end

    it "passes more through a wider bore, so the cap is the pipe and not a constant" do
      narrow = moved(rig(affinity: { liquid: 1.0e6 }, line_kg_per_s: 0.4))
      wide = moved(rig(affinity: { liquid: 1.0e6 }, line_kg_per_s: 4.0))

      expect(wide.fetch(:brine)).to be > narrow.fetch(:brine)
    end
  end

  # The relief-valve case, stated directly. Membership in the pressure regime is *structural* —
  # any conductance-bearing path whose ends declare no intent — so "nobody expressed an opinion"
  # is the common case, not an edge one, and dropping liquid there was silently the rule for
  # most of the graph.
  describe "with nobody expressing an opinion" do
    it "still passes liquid, because a flooded line flows as a liquid" do
      expect(moved(rig).fetch(:brine, 0.0)).to be > 0.0
    end

    it "passes it at the line's rating rather than as a multiple of the gas flow" do
      got = moved(rig(line_kg_per_s: 0.4))

      expect(got.fetch(:brine)).to be_within(1e-9).of(0.4 * ReactorSim::DT)
    end

    # A locked cylinder holds no gas at all, which is exactly when its relief valve is needed.
    # The old code reached `mean_molar_mass` → nil → zero moles → nothing crossed.
    it "passes liquid from a source holding no gas whatever" do
      got = moved(rig(kg: { brine: 200.0 }))

      expect(got.fetch(:brine, 0.0)).to be > 0.0
    end
  end

  # Nothing here may create or destroy mass, whatever the weights say.
  it "conserves mass exactly, per resource" do
    op = rig(affinity: { liquid: 100.0 })
    before = held(op, :source)
    op.step!(tick: 1)

    after = held(op, :source)
    arrived = held(op, :sink)
    in_line = op.state.fetch(:nodes).fetch(:line).fetch(:parcels, [])

    expect(in_line).to be_empty
    before.each_key do |resource|
      total = after.fetch(resource, 0.0) + arrived.fetch(resource, 0.0)
      expect(total).to be_within(1e-9).of(before.fetch(resource))
    end
  end
end
