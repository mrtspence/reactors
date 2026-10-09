# frozen_string_literal: true

require "reactor_sim"
require "support/reference_crew"

# **Where a hazard reaches, and why.**
#
# A hazard used to resolve only through the STATION somebody was posted to, which says they were
# hurt because of the work they were doing. That is false of nearly everything: a boiler letting
# go hurts whoever is in the engine room, including the man who has just been carried off his
# post, and misses the fireman who walked out two minutes ago.
#
# So a node belongs to a `Place`, a node's `endangers:` may key by `places:` as well as by
# `stations:`, and both are resolved per minion. The station key stays legal — an operation with
# no geometry has only stations to name — which is what leaves the steam engine untouched.
#
# See `docs/design_sketches/breathable-air.md` §5.
RSpec.describe ReactorSim::Place do
  # A drum that ruptures early and hard, so nobody has to boil a real boiler to find out who it
  # reaches. `stress_rate:` is what makes a `Vessel` fail at all.
  #
  # Its gas port is not decoration: a place has to hold air somewhere or the build refuses it,
  # which is `breath_spec`'s rule reaching back into this one.
  def drum(endangers:)
    ReactorSim::Nodes::Vessel.new(
      id: :drum, label: "Drum", volume_m3: 1.0, heat_capacity: 1.0e4,
      ambient_conductance: 0.0, max_pressure_pa: 1.0e5, stress_rate: 3_000.0,
      ports: [ ReactorSim::Port.new(id: :vent, direction: :inlet, accepts: [ :gas ]) ],
      initial_contents: [ { resource: :water, kg: 50.0, temperature_k: 480.0 },
                          { resource: :air, kg: 0.5, temperature_k: 293.15 } ],
      endangers: endangers
    )
  end

  def open_air
    ReactorSim::Nodes::Atmosphere.new(id: :sky, label: "Sky")
  end

  ROOMS = [ described_class.new(id: :engine_room, nodes: [ :drum ]),
            described_class.new(id: :yard, nodes: [ :sky ]) ].freeze

  # Two people in one room, one of them posted to the lever and one of them merely present.
  def rig(endangers:, places: nil, standing: :engine_room)
    ReactorSim::Operation.new(
      id: :rig, type: :test, seed: 1, nodes: [ drum(endangers: endangers), open_air ],
      places: places || ROOMS,
      passages: [ ReactorSim::Passage.new(a: :engine_room, b: :yard, metres: 10.0) ],
      control_points: [ ReactorSim::ControlPoint.new(id: :lever, node: :drum,
                                                     place: :engine_room) ],
      minions: [
        ReactorSim::Minion.new(id: :driver, name: "Driver", stats: ReferenceCrew::PLAIN_STATS,
                               mass_kg: ReferenceCrew::HUMAN_KG,
                               station: :lever, place: :engine_room),
        ReactorSim::Minion.new(id: :passer, name: "Passer", mass_kg: ReferenceCrew::HUMAN_KG,
                               stats: ReferenceCrew::PLAIN_STATS, place: standing)
      ]
    )
  end

  def run!(op, ticks = 6)
    ticks.times.flat_map { |i| op.step!(tick: i + 1) }
  end

  def hurt(events) = events.select { |e| e[:type] == :minion_hurt }.map { |e| e[:node] }

  describe "a hazard keyed by place" do
    let(:by_place) { { rupture: { tags: [ :scald ], places: { engine_room: 9.0 } } } }

    # The whole point: the passer-by holds no lever and is hurt anyway.
    it "reaches everybody in the room, posted or not" do
      op = rig(endangers: by_place)

      expect(hurt(run!(op))).to contain_exactly(:driver, :passer)
    end

    it "does not reach somebody standing somewhere else" do
      op = rig(endangers: by_place, standing: :yard)

      expect(hurt(run!(op))).to contain_exactly(:driver)
    end

    it "names the place on the record, so a consumer can say where it happened" do
      op = rig(endangers: by_place)
      event = run!(op).find { |e| e[:type] == :minion_hurt }

      expect(event.dig(:detail, :place)).to be(:engine_room)
    end
  end

  # The old key still works, and this is what keeps an operation with no geometry — the steam
  # engine — behaving exactly as it did.
  describe "a hazard keyed by station" do
    it "reaches only the person posted there" do
      op = rig(endangers: { rupture: { tags: [ :scald ], stations: { lever: 9.0 } } })

      expect(hurt(run!(op))).to contain_exactly(:driver)
    end
  end

  # Two things letting go beside somebody is worse than either, and that rule must not change
  # because the two arrived through different keys.
  describe "a hazard that names both" do
    it "adds the severities where both reach the same person" do
      tags = { tags: [ :scald ] }
      both = rig(endangers: { rupture: tags.merge(places: { engine_room: 1.0 },
                                                  stations: { lever: 1.0 }) })
      place_only = rig(endangers: { rupture: tags.merge(places: { engine_room: 1.0 }) })

      run!(both)
      run!(place_only)

      # The driver takes both halves; the passer-by only the room's.
      expect(both.state.dig(:minions, :driver, :resilience))
        .to be < place_only.state.dig(:minions, :driver, :resilience)
      expect(both.state.dig(:minions, :passer, :resilience))
        .to be_within(1e-9).of(place_only.state.dig(:minions, :passer, :resilience))
    end
  end

  # **Silence must never be the safe answer.** Every one of these would otherwise resolve to an
  # empty index and produce a hazard that hurts nobody at all.
  describe "what the build refuses" do
    it "refuses a place naming a node the operation does not have" do
      expect {
        rig(endangers: {},
            places: [ described_class.new(id: :engine_room, nodes: %i[drum ghost]),
                      described_class.new(id: :yard) ])
      }.to raise_error(ReactorSim::Error, /no node :ghost/)
    end

    it "refuses a node two places both claim" do
      expect {
        rig(endangers: {},
            places: [ described_class.new(id: :engine_room, nodes: [ :drum ]),
                      described_class.new(id: :yard, nodes: [ :drum ]) ])
      }.to raise_error(ReactorSim::Error, /more than one place/)
    end

    # The rig's passage runs to the yard, so leaving the yard out is a room somebody can walk
    # into that no hazard could ever name.
    it "refuses a passage endpoint nobody declared" do
      expect { rig(endangers: {}, places: [ described_class.new(id: :engine_room,
                                                                nodes: [ :drum ]) ]) }
        .to raise_error(ReactorSim::Error, /undeclared place\(s\): yard/)
    end

    # A room whose air nobody modelled would read as clean forever, which is the same silence
    # in a third disguise.
    it "refuses a place with nothing in it that holds gas" do
      expect {
        rig(endangers: {},
            places: [ described_class.new(id: :engine_room, nodes: [ :drum ]),
                      described_class.new(id: :yard) ])
      }.to raise_error(ReactorSim::Error, /place yard has no air/)
    end

    # And the reverse: two volumes in one room, so which one a person is breathing is a guess.
    it "refuses a place holding gas in more than one node" do
      expect {
        rig(endangers: {},
            places: [ described_class.new(id: :engine_room, nodes: %i[drum sky]),
                      described_class.new(id: :yard) ])
      }.to raise_error(ReactorSim::Error, /more than one node/)
    end

    # And a station's place, which is the same rule reached the other way.
    it "refuses a station standing in a place nobody declared" do
      expect {
        ReactorSim::Operation.new(
          id: :rig, type: :test, seed: 1, nodes: [ drum(endangers: {}) ],
          places: [ described_class.new(id: :engine_room, nodes: [ :drum ]) ],
          control_points: [ ReactorSim::ControlPoint.new(id: :lever, node: :drum,
                                                         place: :gallery) ]
        )
      }.to raise_error(ReactorSim::Error, /undeclared place\(s\): gallery/)
    end
  end

  describe "places declared by more than one fragment" do
    # A fitting names only the machinery it installs; the room belongs to the chassis.
    it "unions their nodes and keeps the first label" do
      layout = ReactorSim::Layout.new(
        places: [ described_class.new(id: :bank, label: "Pit Bank", nodes: [ :winder ]),
                  described_class.new(id: :bank, nodes: [ :cage_drive ]) ]
      )

      expect(layout.place_of_node(:winder)).to be(:bank)
      expect(layout.place_of_node(:cage_drive)).to be(:bank)
      expect(layout.place(:bank).label).to eq("Pit Bank")
    end
  end

  describe "an operation that declares no places" do
    it "has none, and validates nothing" do
      op = ReactorSim::Operation.new(id: :bare, type: :test, seed: 1,
                                     nodes: [ drum(endangers: {}) ])

      expect(op.layout.places).to be_empty
      expect(op.layout.place_of_node(:drum)).to be_nil
    end
  end
end
