# frozen_string_literal: true

require "reactor_sim"
require "support/pit_rig"

# **Several people at one post**, and their work adding up. A work post's lever arrives at its
# node in worker-equivalents — the lever times the crew's capabilities, summed — so a node
# multiplies a per-worker rate by it and caps nothing but the crew. See
# `docs/design_sketches/crewed-posts.md`.
#
# Asserted as relationships throughout: more hands move more, a stronger hand moves more than a
# reference one. No figure here is a tuning value.
RSpec.describe "crewed posts" do
  let(:content) do
    ReactorSim::Content.build(resources: {
      water: { tags: [ :liquid ], specific_heat_j_per_kg_k: 4181, density_kg_per_m3: 997 }
    })
  end

  def tank(id, kg)
    ReactorSim::Nodes::Vessel.new(
      id: id, volume_m3: 400.0, initial_temperature_k: 300.0,
      initial_contents: kg.zero? ? [] : [ { resource: :water, kg: kg, temperature_k: 300.0 } ],
      ports: [ ReactorSim::Port.new(id: :in, direction: :inlet, max_kg_per_s: 1.0e3),
               ReactorSim::Port.new(id: :out, direction: :outlet, max_kg_per_s: 1.0e3) ]
    )
  end

  def hand(id, strength: 1.0)
    ReactorSim::Minion.new(id: id, mass_kg: 70.0, station: :bailing,
                           stats: { strength: strength, toughness: 1.0, endurance: 1.0e6 })
  end

  # Water bailed from one tank to another by however many hands are at the post.
  def bailing(hands, worked: true, effort: { force: 1.0 }, capacity: 3)
    ReactorSim::Operation.new(
      id: :bail, type: :bail, seed: 1, content: content,
      nodes: [ tank(:well, 1.0e4),
               ReactorSim::Nodes::Conduit.new(id: :bucket, max_kg_per_s: 1.0, control_id: :bailing,
                                              worked: worked, crew: capacity),
               tank(:trough, 0.0) ],
      links: [ ReactorSim::Link.new(from: [ :well, :out ], to: [ :bucket, :inlet ]),
               ReactorSim::Link.new(from: [ :bucket, :outlet ], to: [ :trough, :in ]) ],
      control_points: [ ReactorSim::ControlPoint.new(id: :bailing, node: :bucket, default: 100.0,
                                                     effort: effort, capacity: capacity) ],
      minions: hands
    )
  end

  def bailed(op)
    op.step!(tick: 1)
    op.telemetry.fetch(:trough)[:kg].to_f
  end

  describe "the work" do
    it "adds up: each hand at the post moves as much again" do
      one, two, three = (1..3).map { |n| bailed(bailing((1..n).map { |i| hand(:"h#{i}") })) }

      expect(two).to be_within(1e-9).of(2.0 * one)
      expect(three).to be > two
    end

    # The clip a work post's own valve used to put on anybody better than the reference.
    it "lets a stronger hand move more than a reference one" do
      expect(bailed(bailing([ hand(:ogre, strength: 2.0) ]))).to be > bailed(bailing([ hand(:man) ]))
    end

    it "moves nothing with nobody at the post" do
      expect(bailed(bailing([]))).to eq(0.0)
    end
  end

  describe "room at a post" do
    it "takes as many as it has room for and refuses the next" do
      op = bailing((1..3).map { |i| hand(:"h#{i}") }, capacity: 2)
      op.assign_minion(:h1, :bailing)
      op.assign_minion(:h2, :bailing)

      expect(op.assign_minion(:h3, :bailing)).to be(false)
    end

    it "holds a governor post to one" do
      expect { ReactorSim::ControlPoint.new(id: :winding, node: :drum, governor: Object.new, capacity: 2) }
        .to raise_error(ReactorSim::Error, /governor/)
    end
  end

  # A worked conduit that did not know it would clamp the crew to one hand's rate, silently.
  describe "declaring a worked conduit" do
    it "refuses a work post on a conduit not declared worked" do
      expect { bailing([], worked: false) }.to raise_error(ReactorSim::Error, /worked/)
    end

    it "refuses a conduit declared worked on a valve" do
      expect { bailing([], effort: nil) }.to raise_error(ReactorSim::Error, /worked/)
    end
  end

  describe "in the mine" do
    include PitRig

    before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

    let(:pit) { build_pit(id: "c", seed: 2) }

    # Busy-ness is against a full road, so one putter flat out is only part of a busy road.
    it "reads one putter as a quieter road than a full gang" do
      road = pit.nodes.fetch(:tub_road)
      one = road.activity({ carried_kg: road.full_crew_kg_per_s / road.crew * ReactorSim::DT }, :tubs, ReactorSim::DT)
      full = road.activity({ carried_kg: road.full_crew_kg_per_s * ReactorSim::DT }, :tubs, ReactorSim::DT)

      expect(one).to be < full
    end

    it "tells the crew screen how many each post takes" do
      hewing = pit.panel.fetch(:stations).find { |s| s[:id] == :hewing }

      expect(hewing[:capacity]).to eq(pit.control_points.fetch(:hewing).capacity)
      expect(hewing[:capacity]).to be > 1
    end
  end
end
