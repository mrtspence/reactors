# frozen_string_literal: true

require "reactor_sim"
require "support/constructed"
require "support/reference_crew"

# **A steam engine in whatever state the claim needs, without raising steam to get there.**
#
# The engine's own specs were slow for a reason that had nothing to do with what they assert: to
# test what the regulator does, they lit a cold firebox and ran 3,600 ticks until there was steam
# to regulate. Everything here is deterministic and state is a plain hash, so the state can be
# **built** and only the ticks that decide the claim need running. Measured: a seeded engine is in
# its working regime on **tick 20**.
#
# That is faster by two orders of magnitude and it is a better test, because a constructed state
# can be put exactly where the claim is — a grate banked with 300 kg of ash, a drum already over
# its safety valve, a cylinder with a slug of water in it — instead of wherever a long run
# happened to arrive.
#
# ## Why the state is reachable rather than invented
#
# Every figure `at_work` writes — `FIRE`, `DRUM`, `CHEST`, `CYLINDER`, `RPM` and the temperatures
# beside them — was **read off a running engine** (3,000 ticks of the real operating procedure)
# rather than chosen. That is what makes a seeded engine a machine the simulation could have
# arrived at itself, and it is checkable: a seeded engine carries on without a transient, which is
# asserted in `engine_stages_spec`.
#
# Two traps, both silent, and `seed` exists to close them:
#
# - **A node's own temperature is stored as `joules`, not as `temperature_k`.** Patching the name
#   a reader uses rather than the one the state holds adds a key nothing reads: the shell stays at
#   ambient and quietly robs the hot water put in beside it. `seed` therefore refuses any key the
#   built state does not already have.
# - **A parcel's energy has to be derived, never written.** `Parcel.build` is the engine's own
#   seeding path and takes enthalpy from the resource's specific heat at the temperature given.
#   Hand-written `joules` is how you get a drum at a temperature its contents cannot explain.
module EngineRig
  include Constructed
  extend Constructed

  module_function

  # What the levers are at on an engine that is working — the positions the state below was
  # measured in, so the two belong together. The blower is off and the igniter is out, because the
  # fire is established and the blastpipe has taken over.
  WORKING = { igniter: 0, blower: 0, damper_open: 85, stoking: 60, feed: 45,
              throttle_open: 60, load_demand: 80, cylinder_cocks: 0 }.freeze

  # The fire, as it burns: a shallow bed, most of it alight, with its own ash and flue gas in
  # among it. `oxidiser_kg` is the fire's memory of the draught and is a rate, not a stock — see
  # `Resources::Ignition`.
  FIRE_K = 1_025.0
  FIRE = { coal: 2.91, air: 0.97, ash: 11.7, flue_gas: 1.13 }.freeze
  IGNITED_KG = 0.589
  OXIDISER_KG = 1.395

  # The drum at its working mark. 608 kPa is where the stock safety valve holds it, so this is an
  # engine sitting on its valve — which is the ordinary condition of a well-fired one.
  DRUM_K = 432.0
  DRUM = { water: 2_118.5, steam: 8.76 }.freeze

  CHEST_K = 424.0
  CHEST = { steam: 2.16 }.freeze

  # **The cylinder runs far cooler than the steam that feeds it**, which is not an error: it
  # exhausts every stroke and the expansion cools the charge. Seeding it at drum temperature puts
  # the compression pressure above the relief valve's setting and the engine then lifts it on
  # every stroke of an "ordinary" run — a constructed state that is not the state it claims.
  CYLINDER_K = 348.0
  CYLINDER = { steam: 0.41, water: 0.059 }.freeze

  TUBES_K = 529.0
  FLUE_K = 461.0
  THROTTLE_K = 432.0
  RPM = 163.5

  def engine(chassis: :high_pressure, seed: 42, loadout: {})
    ReactorSim::Match
      .create(id: "e", seed: seed,
              operations: [ { id: "eng", type: :steam_engine, chassis: chassis,
                              loadout: ReferenceCrew.loadout(loadout) }
                              .merge(ReferenceCrew.options) ])
      .operation(:eng)
  end

  # `seed`, `body`, `wall` and `parcels_at` come from `Constructed`, which also carries the two
  # guards that keep a constructed state honest.

  def spin(op, rpm) = { angular_momentum: omega(rpm) * op.nodes.fetch(:flywheel).moment_of_inertia }

  def omega(rpm) = rpm * 2.0 * Math::PI / 60.0

  # **An engine that has been at work**, every figure measured off one that had been. Keyword
  # overrides move the one thing an example is about and leave the rest alone — `fire_k: 320.0`
  # for a dead fire, `ash: 300.0` for a banked grate, `rpm: 0.0` for a standing engine.
  def at_work(op, **options) = seed(op, nodes: at_work_nodes(op, **options))

  # **The patches alone**, for a caller that has to seed through something other than a bare
  # operation — `Constructed#seed_match`, when a digest or replay example needs the match's own
  # copy to carry the state too.
  def at_work_nodes(op, fire_k: FIRE_K, drum_k: DRUM_K, rpm: RPM, ash: FIRE.fetch(:ash),
                    ignited: IGNITED_KG, water: DRUM.fetch(:water), **extra)
    {
      # `alight` is deliberately not seeded: the firebox derives it every tick from the ignited
      # mass, so it is not in a fresh node's state and `seed` refuses it.
      firebox: body(op, :firebox, fire_k, **FIRE.merge(ash: ash))
        .merge(ignition: { coal_combustion: { kg: ignited, oxidiser_kg: OXIDISER_KG } }),
      boiler: body(op, :boiler, drum_k, **DRUM.merge(water: water)),
      steam_chest: body(op, :steam_chest, CHEST_K, **CHEST),
      cylinder: body(op, :cylinder, CYLINDER_K, **CYLINDER),
      flywheel: spin(op, rpm),
      **wall(op, :boiler_tubes, TUBES_K),
      **wall(op, :throttle, THROTTLE_K),
      **wall(op, :flue, FLUE_K),
      **extra
    }
  end

  # Set the levers and turn the handle. **Tens of ticks, not thousands** — what used to need
  # thousands was raising the steam, never the behaviour being measured.
  #
  # `firing:` posts the hand on the shovel, because an effort station with nobody at it delivers
  # nothing and the fire then goes out underneath whatever is being tested.
  def run!(op, ticks, firing: :crew_1, raking: nil, from: 0, **levers)
    WORKING.merge(levers).each { |id, value| op.set_control(id, value) }
    op.assign_minion(firing, :stoking) if firing
    op.assign_minion(raking, :ash_raking) if raking

    ticks.times.flat_map { |i| op.step!(tick: from + i + 1) }
  end

  def content = ReactorSim::Content.default

  def node_state(op, id) = op.state.fetch(:nodes).fetch(id)

  def pressure_pa(op, id) = op.nodes.fetch(id).pressure_pa(node_state(op, id), op.content)

  def temperature_k(op, id) = op.nodes.fetch(id).temperature_k(node_state(op, id), op.content)

  def rpm(op) = op.nodes.fetch(:flywheel).rpm(node_state(op, :flywheel))

  # What the crank was measurably given, not what the indicator diagram claimed.
  def shaft_power_w(op) = node_state(op, :cylinder).fetch(:shaft_power_w, 0.0)

  # How far the regulator has throttled the steam below the boiler that raised it — the
  # wire-drawing, which is what a regulator physically does.
  def chest_drop_pa(op) = pressure_pa(op, :boiler) - pressure_pa(op, :steam_chest)

  def occupancy(op) = op.nodes.fetch(:cylinder).occupancy(node_state(op, :cylinder), op.content)

  # **The draught: air actually crossing the damper, per tick.** The air a firebox *holds* is a
  # stock and measures draught only while consumption is equal on both sides of a comparison — a
  # dead fire consumes nothing, so it accumulates 6.3 kg against a working fire's 0.98 and reads
  # as six times the draught. `carried_kg` is the flow, which is the quantity a blower, a stack
  # and a blastpipe all act on.
  def draught_kg(op) = node_state(op, :damper).fetch(:carried_kg, 0.0)

  def reaction_throttle(op, id = :firebox)
    op.nodes.fetch(id).reaction_throttle(node_state(op, id), op.content)
  end

  def held(op, id, resource)
    ReactorSim::Parcel.total_kg(
      node_state(op, id).fetch(:parcels, []).select { |p| p.fetch(:resource) == resource }
    )
  end

  def failures_of(events, node)
    events.select { |e| e[:type] == :part_failed && e[:node] == node }
  end
end
