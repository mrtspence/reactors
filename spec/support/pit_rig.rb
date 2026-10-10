# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"

# **The pit that every mine spec runs, and the fixture it runs with.**
#
# ## Why not `ReferenceCrew`
#
# That fixture is flat 1.0 with **no tags at all**, which is right for a steam engine and useless
# in a mine: hewing and timbering are `gated_by: %i[mining_effectiveness darkvision]`, and a gate
# is a *multiply*, so a reference hand with neither cuts precisely nothing. A collier is the same
# boring 1.0 person carrying a pick and a lamp.
#
# ## Two colliers, and the difference is load-bearing
#
# `CONTENT`'s hands never tire; `TIRING_CONTENT`'s do. A spec measuring a *machine* wants the
# first, because a hand who runs out part-way turns a six-thousand-tick measurement into a
# measurement of when he stopped. A spec about **bad air** wants the second, because `Breath`
# drains `fatigue` rather than a pool of its own — with tireless hands, foul air does nothing
# whatever and the spec passes while proving the opposite of what it claims.
#
# ## What belongs here and what does not
#
# The rig owns what is *incidental*: feeding the line shaft, walking the shift down the cage,
# reading a parcel out of a node. It does **not** own a spec's identity — the match id, the seed
# and the loadout stay at each call site, because those choose which pit is being measured and a
# shared default would quietly re-point an example at a different machine. Each spec therefore
# wraps `build_pit` in its own one-line `pit`.
module PitRig
  include Constructed

  # `endurance` is a divisor in `Fatigue`, so this is "never tires" rather than a real stat.
  TIRELESS = 1.0e6

  # A human, so the burden arithmetic has a reference frame. **Carries no equipment**, so
  # `worn_kg` is zero and pace is unburdened — which is what keeps every measured figure in the
  # mine specs a figure about the mine.
  COLLIER = { label: "Collier", mass_kg: 70.0,
              strength: 1.0, toughness: 1.0, endurance: TIRELESS,
              intelligence: 1.0, dexterity: 1.0, charisma: 1.0,
              tags: { mining_effectiveness: 0.6, shovelling: 0.5, darkvision: 0.8 } }.freeze

  SEATS = (1..4)

  MINIONS = SEATS.to_h { |i|
    [ :"hand_#{i}", { name: "Hand #{i}", archetype: :collier, hireable: false } ]
  }.freeze

  # Seats, not people: `crew_1` is a place on the payroll that `hand_1` is filling.
  CREW = SEATS.to_h { |i| [ :"crew_#{i}", { minion: :"hand_#{i}" } ] }.freeze

  def self.content(archetype)
    ReactorSim::Content.default.merging(archetypes: { collier: archetype }, minions: MINIONS)
  end

  CONTENT = content(COLLIER)
  TIRING_CONTENT = content(COLLIER.merge(endurance: 1.0))

  # Comfortably more than the mine can spend, so what is measured is the mine rather than the
  # supply. `Import` caps what it will hold, so this does not accumulate.
  SUPPLY_J = 9.0e4

  # **Ordinary ground unless an example asks otherwise.** How gassy and how wet a pit is is
  # drawn per match, so a spec that does not pin it measures the luck rather than the mine.
  ORDINARY = ReactorSim::Operations::Mine::Ground::ORDINARY

  # `loadout:` is omitted rather than defaulted, so an unfitted slot takes the chassis default
  # exactly as it would without the rig.
  def build_match(id:, seed:, crew: CREW, ground: ORDINARY, loadout: nil, **opts)
    operation = { id: "pit", type: :mine, ground: ground, crew: crew, **opts }
    operation[:loadout] = loadout if loadout

    ReactorSim::Match.create(id: id, seed: seed, operations: [ operation ])
  end

  # The operation, which is what nearly every example wants. A replay example wants the match
  # instead, because `digest` lives there.
  def build_pit(...) = build_match(...).operation(:pit)

  # One tick of a mine that is being paid for, for as many ticks as asked. **Returns the
  # events**, never the operation: the caller already holds that, and an example that wants to
  # assert on what the pit reported should not have to build its own loop to collect it.
  def run!(op, ticks, from: 0, supply: SUPPLY_J)
    events = []
    ticks.times do |i|
      op.receive_supply(:line_shaft, supply)
      events.concat(op.step!(tick: from + i + 1))
    end
    events
  end

  # --- constructed state -----------------------------------------------------
  #
  # **A pit at the state a claim begins in, rather than one that ran until it got there.** Two
  # separate costs were being paid by every mine example: the **walk** (up to 2,000 ticks of
  # nothing but people going down the shaft and along the roadway) and the **make** (two to eight
  # thousand more while gas seeped, dust settled or water rose). Both are constructible.
  #
  # `at_the_face` is checkable and checked: a constructed deployment is **identical on every field
  # of every minion** to one that walked there, which `mine_spec` asserts — and `mine_spec` keeps a
  # real walk for exactly that reason, because a constructed arrival cannot fail when the walking
  # breaks. `cage_spec` keeps its journeys real too, since there the time *is* the claim.

  # Where each post is, so a seeded minion is somewhere their station actually exists. Derived
  # from the layout rather than written down, because a hand-written copy breaks silently — a
  # minion seeded into the wrong room still works their lever and simply breathes the wrong air.
  def post_place(op, station) = op.layout.place_of(station)

  # The shift, already at their posts. `nil` for a seat leaves that hand in the quarters, which is
  # how a spec about the pit bottom keeps the face empty.
  #
  # **Rejecting nil SEATS, not nil values.** `compact` drops nil values, which is the wrong half
  # here — a caller posting nobody to the face passes `hewing: nil`, so nil arrives as a *key* and
  # two nils collapse into one entry.
  #
  # **`progress`, `remaining` and `journey` are zeroed deliberately.** They are what a walk leaves
  # behind, and a minion seeded as "arrived" while still carrying a part-finished journey is a
  # state the tick will try to continue.
  def at_the_face(op, **posts) = seed(op, minions: at_the_face_minions(op, **posts))

  # **The patches alone**, for a caller that has to seed through something other than a bare
  # operation — `Constructed#seed_match`, when a digest or replay example needs the match's own
  # copy to carry the arrival too.
  def at_the_face_minions(op, hewing: :crew_1, haulage: :crew_2, timbering: :crew_3)
    posted = { hewing => :hewing, haulage => :haulage, timbering => :timbering }
             .reject { |seat, _| seat.nil? }

    posted.to_h do |seat, station|
      [ seat, { posting: station, station: station, place: post_place(op, station),
                progress: 0.0, remaining: 0.0, journey: 0.0 } ]
    end
  end

  # **A volume holding exactly the mixture you ask for**, with the percentages taken by MASS of
  # what it holds — which is what `gas_pct` reads back, so an example's figure and its assertion
  # are in the same units.
  #
  # The flammability limits are a different question and are stated **by volume**, because that is
  # what they physically are; `IgnitionRig` is where those live and it converts. Mixing the two up
  # moves every figure by nearly a factor of two.
  def gas_mix(op, node, air:, temperature_k: AMBIENT_K, **gases)
    body(op, node, temperature_k, air: air, **gases)
  end

  def district_mix(op, air: DISTRICT_AIR_KG, **gases) = gas_mix(op, :district, air: air, **gases)

  # **The low point of the mine, which is where blackdamp lies.** Its own helper because its air
  # charge differs from the district's, and `gas_kg` has to be told which volume it is a fraction
  # of or every figure is wrong by the ratio between them.
  def bottom_mix(op, air: BOTTOM_AIR_KG, **gases) = gas_mix(op, :pit_bottom, air: air, **gases)

  # Air as it comes, from the mine's own `initial_contents`.
  DISTRICT_AIR_KG = 1_700.0
  BOTTOM_AIR_KG = 1_100.0
  AMBIENT_K = 292.0

  # A mass fraction of the finished mixture, turned into kilograms of gas to add to `air`. `pct` is
  # of the **total**, so 8% of a 1,700 kg air charge is 147.8 kg rather than 136 — and `air:` has
  # to name the volume being filled, because the district and the pit bottom hold different
  # amounts.
  def gas_kg(pct, air: DISTRICT_AIR_KG) = air * pct / (100.0 - pct)

  # **Set levers, and complain about one that does not exist.** `Operation#set_control` returns
  # `false` for an unknown id and does nothing, which is right on the command path — a command for
  # a lever that is not fitted must not crash a match — and wrong in a spec, where it turns a
  # typo'd lever into an example quietly measuring the default. It also hides a keyword that was
  # meant for the helper: `from:` passed by mistake became `set_control(:from, 100)` and the run
  # silently restarted at tick 1.
  def levers!(op, **positions)
    positions.each do |id, value|
      raise ArgumentError, "#{op.type} has no control #{id.inspect}" unless op.set_control(id, value)
    end
  end

  def parcels(op, node) = op.state.fetch(:nodes).fetch(node).fetch(:parcels)

  # `Parcel.normalise` guarantees a node never holds two parcels of one substance, so summing
  # and finding agree — summing is written because it does not depend on that staying true.
  def held(op, node, resource)
    ReactorSim::Parcel.total_kg(parcels(op, node).select { |p| p.fetch(:resource) == resource })
  end

  # **Percentage, which is the quantity a damp is described in and the one a flame responds
  # to.** Kilograms mean different things with the fan on and off, because the air went with
  # the fan.
  def gas_pct(op, gas: :firedamp, node: :district)
    total = ReactorSim::Parcel.total_kg(parcels(op, node))
    return 0.0 unless total.positive?

    held(op, node, gas) / total * 100.0
  end

  def air(op, place)
    ReactorSim::Breath.breathable_fraction(parcels(op, op.layout.breathes(place)), op.content)
  end

  def crew(op, seat) = op.state.fetch(:minions).fetch(seat)

  # **Asked of the node rather than divided by a literal.** Both copies of this helper carried
  # the line shaft's moment of inertia as `900.0`, so retuning the shaft would have left them
  # quietly reporting a wrong speed instead of failing.
  def omega(op) = op.nodes.fetch(:line_shaft).omega(op.state.fetch(:nodes).fetch(:line_shaft))

  def rpm(op) = op.nodes.fetch(:line_shaft).rpm(op.state.fetch(:nodes).fetch(:line_shaft))
end
