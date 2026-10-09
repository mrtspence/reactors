# frozen_string_literal: true

require "reactor_sim"

# **Build the state a claim needs, instead of running a machine until it reaches one.**
#
# State is a plain hash and the engine is deterministic, so a precondition does not have to be
# *reached*. Almost nothing in this suite was slow because of what it asserted — it was slow
# because of what it had to arrive at first: a hot boiler, a shift that had finished walking to
# the face, a district that had seeped its way into the explosive band.
#
# A constructed state is also a **better** test, because it can be put exactly where the claim is
# — a hair under the lean limit, a grate banked with 300 kg of ash, a drum already over its
# safety valve — instead of wherever a long run happened to end up.
#
# See `docs/design_sketches/suite-runtime.md` §7, and `EngineRig` / `PitRig` for the two rigs
# built on this.
#
# ## The three ways a constructed state is a lie
#
# All three are silent, and the first two are closed here.
#
# 1. **A key the node does not read.** A node's own temperature lives in `joules`, so patching
#    `temperature_k:` adds a key nothing reads: the wall stays at ambient and quietly robs the hot
#    contents put in beside it. `seed` therefore **refuses any key the built state does not have**.
# 2. **Energy written rather than derived.** `Parcel.build` takes enthalpy from the resource's
#    specific heat at the temperature given; a hand-written `joules` is how you get a vessel at a
#    temperature its contents cannot explain.
# 3. **A state the simulation could not reach.** Nothing here can check that — it is on the rig,
#    which is why both rigs take their figures from a machine that was *observed* in the state,
#    and why each owes an example proving a seeded machine **carries on without a transient**.
module Constructed
  # Write state into an operation and hand back one restored from it.
  #
  # Goes out through `to_h` and back in through `from_h`, which is the ordinary snapshot path — so
  # a state this builds is one the operation would accept off disk, and a malformed one fails here
  # rather than several hundred ticks later. It also means **the returned operation is a different
  # object**: callers must use the return value, never the argument.
  #
  # `nodes:` and `minions:` patch those two sections. Patches merge one level into nested hashes,
  # so naming one reaction's `ignition` keeps the others.
  #
  # **The operation it returns is detached from any `Match` that built it**, because it is rebuilt
  # from a snapshot rather than mutated. So a replay or digest example — which steps an operation
  # and then asks `match.digest` — cannot seed: the match still holds the original. Those examples
  # keep the real run, which is right anyway, since a digest over a constructed state would be
  # proving the snapshot path rather than the replay.
  def seed(op, nodes: {}, minions: {})
    snapshot = ReactorSim.deep_symbolize(op.to_h)

    patch_section(snapshot, :nodes, nodes, op)
    patch_section(snapshot, :minions, minions, op)

    ReactorSim::Operation.from_h(snapshot)
  end

  def patch_section(snapshot, section, patches, op)
    return if patches.empty?

    states = snapshot.fetch(:state).fetch(section)

    patches.each do |id, patch|
      was = states.fetch(id) { raise ArgumentError, "#{op.type} has no #{section} entry #{id.inspect}" }
      unknown = patch.keys - was.keys
      raise ArgumentError, "#{id} has no #{section} state key #{unknown.inspect}" if unknown.any?

      states[id] = deep_merge(was, patch)
    end
  end

  def deep_merge(into, patch)
    into.merge(patch) do |_, old, new|
      old.is_a?(Hash) && new.is_a?(Hash) ? deep_merge(old, new) : new
    end
  end

  # Parcels at a stated temperature, with their energy derived rather than written. Zero-mass
  # entries are dropped, so a caller can pass `coal_dust: 0.0` without planting an empty parcel
  # that `Parcel.normalise` would keep.
  def parcels_at(temperature_k, **kg_by_resource)
    ReactorSim::Parcel.normalise(
      kg_by_resource.reject { |_, kg| kg.to_f.zero? }.map do |resource, kg|
        ReactorSim::Parcel.build(resource: resource, kg: kg.to_f, temperature_k: temperature_k,
                                 content: ReactorSim::Content.default)
      end
    )
  end

  # Contents and the vessel wall at **one** temperature, which is the invariant every node holds
  # between ticks (`Concerns::Thermal#rebalance`). Seeding the two apart is legal and wrong: they
  # equalise on the first tick and the state the example meant is gone before it is measured.
  def body(op, id, temperature_k, **kg_by_resource)
    { joules: op.nodes.fetch(id).heat_capacity * temperature_k,
      parcels: parcels_at(temperature_k, **kg_by_resource) }
  end

  # Just the wall, for a node that holds nothing — and **nothing at all if the node is not
  # fitted**, so a rig can express the build whose absence is the thing being tested. Returns a
  # one-entry hash to be splatted into a `nodes:` patch.
  def wall(op, id, temperature_k)
    return {} unless op.nodes.key?(id)

    { id => { joules: op.nodes.fetch(id).heat_capacity * temperature_k } }
  end
end
