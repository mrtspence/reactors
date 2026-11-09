# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"

# **The open pit every pit spec runs, and the navvy it runs with.** A navvy is the colliery's
# collier above ground: the same plain 1.0 person carrying a pick, because getting is gated on
# one. `CONTENT`'s never tire — a spec about the machine wants that — and `TIRING_CONTENT`'s do,
# for a spec about rest.
#
# It owns the incidental — posting the gangs, putting the faces where an example needs them,
# reading what a node holds — and not the identity: `id:` and `seed:` stay at each call site.
module OpenPitRig
  extend Constructed

  TIRELESS = 1.0e6

  NAVVY = { label: "Navvy", mass_kg: 70.0, strength: 1.0, toughness: 1.0, endurance: TIRELESS,
            intelligence: 1.0, dexterity: 1.0, charisma: 1.0, agility: 1.0, combat_prowess: 1.0,
            tags: { mining_effectiveness: 0.6 } }.freeze

  SEATS = 14

  # What a quarters part seats.
  def self.seats_in(quarters) = ReactorSim::Parts.fetch(quarters).stats.fetch(:crew_capacity)

  # Enough navvies for the largest quarters, so a pit with machines or a full washing floor can be
  # crewed.
  MOST_SEATS = seats_in(:barracks)

  MINIONS = (1..MOST_SEATS).to_h { |i| [ :"navvy_#{i}", { name: "Navvy #{i}", archetype: :navvy, hireable: false } ] }.freeze

  # A shift of `seats` navvies, one to a seat.
  def self.crew(seats) = (1..seats).to_h { |i| [ :"crew_#{i}", { minion: :"navvy_#{i}" } ] }.freeze

  CREW = crew(SEATS)

  def self.content(archetype) = ReactorSim::Content.default.merging(archetypes: { navvy: archetype }, minions: MINIONS)

  CONTENT = content(NAVVY)
  TIRING_CONTENT = content(NAVVY.merge(endurance: 1.0))
  # Navvies who see in the dark, as a dwarf or a goblin does.
  DARK_EYED_CONTENT = content(NAVVY.merge(tags: NAVVY.fetch(:tags).merge(darkvision: 0.8)))

  ORDINARY = ReactorSim::Operations::OpenPit::Ground::ORDINARY

  module_function

  def build(id:, seed:, ground: ORDINARY, crew: CREW, content: CONTENT, **opts)
    ReactorSim::Operations::OpenPit.build(id: id, seed: seed, ground: ground, crew: crew, content: content, **opts)
  end

  # **Gangs at their posts**, already arrived: `{ station => [seats] }`. Everybody else stays where
  # the shift was dealt.
  def posted(op, **posts)
    seed(op, minions: posts.flat_map { |station, seats| Array(seats).map { |seat| [ seat, station ] } }.to_h do |seat, station|
      [ seat, { posting: station, station: station, place: op.layout.place_of(station),
                progress: 0.0, remaining: 0.0, journey: 0.0 } ]
    end)
  end

  # The whole shift at work, from the first seats: four strippers and three barrowmen, two ore
  # getters and two barrowmen, a dumpman and the first washer's two hands.
  def at_work(op)
    seats = (1..SEATS).map { |i| :"crew_#{i}" }
    posted(op, stripping_getters: seats[0, 4], stripping_barrowmen: seats[4, 3], ore_getters: seats[7, 2],
               ore_barrowmen: seats[9, 2], dumpmen: seats[11, 1], bay_1_hands: seats[12, 2])
  end

  # Comfortably more than the pit's line shaft can take in a tick, so the shaft is the machine's
  # and not the supply's.
  SUPPLY_J = 1.2e5

  # **The faces where an example needs them**, in metres along the cut: what is left in each bench
  # and where its face reads, written together so the next tick starts from a consistent cut.
  def faces_at(op, stripping_m: nil, ore_m: nil, nodes: {})
    patches = { stripping_bench: stripping_m, ore_bench: ore_m }.compact.to_h do |id, at_m|
      [ id, face_state(op, id, at_m) ]
    end
    seed(op, nodes: patches.merge(nodes) { |_, a, b| a.merge(b) })
  end

  def face_state(op, id, at_m)
    bench = op.nodes.fetch(id)
    state = op.state.dig(:nodes, id)
    left = state.fetch(:initial_kg) - ((at_m - bench.start_m) * bench.kg_per_m(state))
    { parcels: parcels_at(293.15, **bench.mix.transform_values { |share| left * share }), advanced_m: at_m }
  end

  # The seats posted at `station`, so an example can stand a gang down without knowing who it is.
  def gang(op, station) = op.state.fetch(:minions).select { |_, s| s[:station] == station }.keys

  def node_state(op, id) = op.state.dig(:nodes, id)
  def held_kg(op, id) = ReactorSim::Parcel.total_kg(node_state(op, id).fetch(:parcels, []))
  def board(op, face) = ReactorSim::Operations::OpenPit::Bench::SIGNALS.keys.fetch(node_state(op, :"#{face}_bench").fetch(:signal))

  # A tick of a pit whose line shaft is being paid for; `supply: 0.0` for one that is not.
  def tick(op, ticks = 1, supply: SUPPLY_J)
    ticks.times do |t|
      op.receive_supply(:line_shaft, supply)
      op.step!(tick: t + 1)
    end
    op
  end
end
