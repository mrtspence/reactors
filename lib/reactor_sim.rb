# frozen_string_literal: true

# The simulation. Pure Ruby, no Rails, no I/O on the tick path, no ambient entropy.
#
# Four invariants are load-bearing. Everything here is shaped around keeping them, and each
# has a spec that fails when it is violated:
#
#   1. PURITY        No clock, no `SecureRandom`, no globals, no Rails. Seed and dt are
#                    arguments. The one filesystem read is Content, at boot, never in a tick.
#   2. DETERMINISM   seed + command log reproduces a match exactly. This is what makes crash
#                    recovery exact, replay nearly free, and spectating trivial.
#   3. ORDER-INDEPENDENCE  Every node reads the previous tick and writes the next, so
#                    evaluation order cannot matter — and closed loops need no special case.
#   4. IDEMPOTENCE   Commands carry absolute values and set targets only, so at-least-once
#                    delivery from the log is harmless without a dedup table.
#
# Delay is not configured anywhere. It emerges from graph shape, one tick per hop.
#
# See docs/simulation_architecture.md.
module ReactorSim
  # Wall-clock seconds per tick — 4 Hz. Simulated time is this multiplied by an
  # operation's `time_scale`, so how fast the world runs is a design dial rather than a
  # property of the tick loop.
  DT = 0.25

  class Error < StandardError; end

  module_function

  # Key-sorted JSON. Two states are identical iff their canonical forms are; this is what
  # the determinism spec compares.
  def canonical(obj) = JSON.generate(sort_deep(obj))

  def sort_deep(obj)
    case obj
    when Hash  then obj.keys.map(&:to_s).sort.to_h { |k| [ k, sort_deep(obj[k.to_sym] || obj[k]) ] }
    when Array then obj.map { |v| sort_deep(v) }
    when Float then obj.nan? || obj.infinite? ? obj.to_s : obj
    else obj
    end
  end

  # Snapshots round-trip through JSON, which stringifies symbol keys. Only keys are
  # symbolised on the way back; values stay as they are, because a resource id that is a
  # string in one path and a symbol in another is a bug generator.
  def deep_symbolize(obj)
    case obj
    when Hash  then obj.to_h { |k, v| [ k.to_sym, deep_symbolize(v) ] }
    when Array then obj.map { |v| deep_symbolize(v) }
    else obj
    end
  end
end

require "json"

# Load order is explicit rather than clever: this library is deliberately outside Zeitwerk's
# reach (docs/architecture.md §3), so the chain below is also the dependency graph.
#
#   physics/      substances, energy bookkeeping, the relaxation solver — no graph awareness
#   graph/        nodes, ports, links, and the arbiter that settles every claim between them
#   concerns/     composable state+behaviour fragments a node opts into
#   nodes/        generic machinery, reusable across operations
#   diagnostics/  the instrument chain and the only thing that leaves the simulation
#   operations/   specific machines, built from everything above

require_relative "reactor_sim/physics/units"
require_relative "reactor_sim/rng"
require_relative "reactor_sim/content"
require_relative "reactor_sim/physics/parcel"
require_relative "reactor_sim/physics/resources"
require_relative "reactor_sim/physics/resources/saturation"
require_relative "reactor_sim/physics/resources/reaction"
require_relative "reactor_sim/physics/ledger"
require_relative "reactor_sim/physics/relaxation"

require_relative "reactor_sim/graph/port"
require_relative "reactor_sim/graph/link"
require_relative "reactor_sim/graph/intent"
require_relative "reactor_sim/graph/arbiter"

require_relative "reactor_sim/concerns/thermal"
require_relative "reactor_sim/concerns/holds"
require_relative "reactor_sim/concerns/wearing"
require_relative "reactor_sim/concerns/pressurized"
require_relative "reactor_sim/concerns/rotating"

require_relative "reactor_sim/graph/node"
require_relative "reactor_sim/nodes/conduit"
require_relative "reactor_sim/nodes/vessel"
require_relative "reactor_sim/nodes/flywheel"
require_relative "reactor_sim/nodes/load"
require_relative "reactor_sim/nodes/atmosphere"
require_relative "reactor_sim/nodes/cylinder"
require_relative "reactor_sim/nodes/relief_valve"

require_relative "reactor_sim/control_point"
require_relative "reactor_sim/diagnostics/sources"
require_relative "reactor_sim/diagnostics/filters"
require_relative "reactor_sim/diagnostics/displays"
require_relative "reactor_sim/diagnostics/diagnostic"
require_relative "reactor_sim/diagnostics/player_view"

require_relative "reactor_sim/command"
require_relative "reactor_sim/operations"
require_relative "reactor_sim/tick"
require_relative "reactor_sim/operation"
require_relative "reactor_sim/match"

require_relative "reactor_sim/operations/steam_engine/definition"
require_relative "reactor_sim/operations/steam_engine/panel"
