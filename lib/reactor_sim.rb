# frozen_string_literal: true

# ReactorSim — the pure simulation core.
#
# INVARIANTS. These are not style preferences; recovery, replay and spectating all
# depend on them. See docs/architecture.md §3.
#
#   * No Rails, no ActiveRecord, no ActiveJob, no Kafka, no I/O of any kind.
#     Enforced by spec/reactor_sim/purity_spec.rb.
#   * No Time.now, Date.today, SecureRandom, or globals. Clock and RNG are injected.
#   * No dependence on Hash iteration order, object identity, or String#hash
#     (which is randomised per process). Stable ordering comes from Arrays and
#     from Rng.stream's FNV-1a hashing.
#   * Same seed + same command sequence => byte-identical state.
#     Enforced by spec/reactor_sim/determinism_spec.rb.
#
# Only stdlib is permitted here, and only non-IO stdlib. `json` is used purely for
# canonical serialisation.

require "json"

require_relative "reactor_sim/rng"
require_relative "reactor_sim/buffer"
require_relative "reactor_sim/mechanism"
require_relative "reactor_sim/mechanisms/reagent_feed"
require_relative "reactor_sim/mechanisms/reaction_vessel"
require_relative "reactor_sim/mechanisms/turbine"
require_relative "reactor_sim/control_point"
require_relative "reactor_sim/diagnostic"
require_relative "reactor_sim/player_view"
require_relative "reactor_sim/operation"
require_relative "reactor_sim/operations"
require_relative "reactor_sim/operations/chemical_vats"
require_relative "reactor_sim/command"
require_relative "reactor_sim/match"

module ReactorSim
  # Seconds of simulated time per tick. The runner's wall-clock cadence must match
  # this, but the sim itself never reads a clock — DT is simulated time, not real time.
  DT = 0.25

  class Error < StandardError; end

  # Canonical serialisation: recursively key-sorted JSON. Two states are equal iff
  # their canonical forms are byte-identical, which is what the determinism spec
  # asserts. Key sorting means we never depend on Hash insertion order.
  def self.canonical(obj)
    JSON.generate(sort_deep(obj))
  end

  def self.sort_deep(obj)
    case obj
    when Hash  then obj.map { |k, v| [ k.to_s, sort_deep(v) ] }.sort_by(&:first).to_h
    when Array then obj.map { |e| sort_deep(e) }
    else obj
    end
  end

  # Snapshots round-trip through JSON, which turns every symbol key into a string.
  # State is keyed by mechanism, buffer, control point and diagnostic ids, so those
  # keys have to come back as symbols or every #fetch in the sim misses.
  #
  # Only keys are converted. Values are left exactly as they are — a string value in
  # state stays a string.
  def self.deep_symbolize(obj)
    case obj
    when Hash  then obj.to_h { |k, v| [ k.respond_to?(:to_sym) ? k.to_sym : k, deep_symbolize(v) ] }
    when Array then obj.map { |e| deep_symbolize(e) }
    else obj
    end
  end
end
