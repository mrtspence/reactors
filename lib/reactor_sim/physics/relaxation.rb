# frozen_string_literal: true

module ReactorSim
  # Bodies joined by couplings drift toward a shared potential. Heat does it; so do rotation
  # and mass. The mathematics is identical, so there is one implementation.
  #
  #     heat      capacity = heat capacity (J/K)     potential = temperature (K)
  #     rotation  capacity = moment of inertia       potential = angular velocity (rad/s)
  #     mass      capacity = dn/dP (mol/Pa)          potential = pressure (Pa)
  #
  # ## The whole network at once, implicitly
  #
  # Each body stores a quantity `q = c·p`, and each coupling carries `k·Δp`. Over a step that
  # is one linear system, and it is solved as one:
  #
  #     (C/dt + K) · p′ = (C/dt) · p + b        K = the conductance Laplacian
  #                                             b = the head terms
  #     transfer_ab     = k · (p′ₐ + head − p′_b) · dt
  #
  # Three properties, and every one of them was learned by losing it:
  #
  #   * **Unconditionally stable at any dt.** Backward Euler is L-stable: the step operator's
  #     eigenvalues are all in (0, 1] however stiff the network, so nothing can overshoot and
  #     nothing can ring. That is what makes `time_scale` a design dial rather than a hazard.
  #   * **Exactly conservative.** A transfer is still one number applied twice with opposite
  #     signs, so what one body loses the other gains, to the bit.
  #   * **Correct for flow THROUGH a body**, which is the case a pairwise law cannot express.
  #     Inflow and outflow are settled simultaneously, so a firebox with a damper at one end
  #     and a chimney at the other passes a steady draught while its pressure barely moves.
  #
  # ## Why this replaced a pairwise closed form and a limiter
  #
  # Heat and rotation used to use the exact two-body solution per coupling; mass could not,
  # because that form caps a transfer at what would equalise the pair, and a through-flow has
  # nothing to do with the amount that would equalise anything. So mass used the linear law
  # `k·ΔP·dt` — which is explicit Euler, and therefore stable only while `dt < τ`.
  #
  # **Every gas coupling in the steam engine ran 400–600× past that limit.** A firebox holds
  # 9.8e-4 mol/Pa against a damper conductance of 1.7 mol/(Pa·s), so τ = 0.58 ms against a
  # 250 ms tick. What kept it from exploding was a per-node bound, and the bound was itself
  # wrong: it capped a sender at the amount that would bring it to the receiver's *current*
  # potential, ignoring that the receiver rises as it fills. For two equal bodies that
  # overshoots by exactly 2× and **swaps them**.
  #
  # Measured, on two 2 m³ vessels holding 6 kg and 1 kg of air joined by one pipe:
  #
  #     k = 0.001  (dt/τ = 0.6)    both settle to 147 287 Pa    correct
  #     k = 0.01   (dt/τ = 6)      42 082 Pa and 252 492 Pa     swapped, forever
  #     k = 0.1    (dt/τ = 61)     42 082 Pa and 252 492 Pa     swapped, forever
  #     k = 1.0    (dt/τ = 610)    42 082 Pa and 252 492 Pa     swapped, forever
  #
  # The engine survived only because every gas coupling in it has `Atmosphere` on one end,
  # whose capacity is ~10⁸× a vessel's, so the receiver never rises and the 2× error vanishes.
  # In the firebox the damage showed up instead as a relaxation oscillation: the flue asked
  # for 1972 mol and the bound granted 1.8, the fire's heat output swung by a factor of 5.9
  # every few ticks, and doubling the draught conductance *cut engine power to a fifth*.
  # `Ignition::OXIDISER_MEMORY_PER_S` and the averaging filters on the power gauges were both
  # written to hide this.
  #
  # ## What the implicit form costs
  #
  # Backward Euler is first order where the pairwise form was exact, so a coupling relaxes
  # slightly slower than the true exponential over a single step: it moves `x/(1+x)` of the
  # way where the exact answer is `1 − e⁻ˣ`, for `x = dt/τ`. Both converge on the same
  # equilibrium and neither can pass it. At heat's `dt/τ ≈ 0.008` the difference is 0.4% of
  # one step's transfer and invisible; at a stiff drive coupling it is a fraction of a tick of
  # extra compliance, which is a tuning number rather than a behaviour.
  #
  # Exactness for one isolated pair is not worth reintroducing a scheme that is wrong for a
  # network, which is what everything in this engine actually is.
  module Relaxation
    EPSILON = 1e-12

    # Passes of the active-set iteration that enforces `limits`. A pass pins every coupling
    # that has run past a bound and solves again, so the rest of the network settles against
    # the flow that actually crossed rather than the one it wanted to. A coupling may be let
    # go once, which bounds the whole loop at two state changes per coupling — so it cannot
    # chatter between pinned and free, and several settle per pass.
    MAX_CONSTRAINT_PASSES = 8

    module_function

    # `links` need only respond to #id, #a, #b and #conductance — ThermalLink, DriveLink and
    # the Arbiter's gas Coupling all do. `capacities` and `potentials` are hashes keyed by
    # node id.
    #
    # Returns { link_id => transfer }, where a positive transfer moves from `a` to `b`.
    #
    # `heads` is optional: `{ link_id => bias }`, a potential source in series with the
    # coupling that pushes from `a` toward `b`. A chimney's buoyancy, a fan, a pump. Absent —
    # as it is for heat and rotation — every expression below is unchanged.
    #
    # `limits` is optional: `{ link_id => [low, high] }`, the most this coupling may carry in
    # each direction over the step, in the transfer's own units. A check valve is `[0, high]`.
    #
    # **A limit is a constraint on the solve, not a clamp applied after it.** Clamping
    # afterwards leaves every other coupling settled against a transfer that did not happen,
    # and the error lands on whatever node sits between them: capping the flue after the fact
    # let a firebox be pumped down to 25 kPa, because the damper had been solved against an
    # exhaust flow four times larger than the one that was allowed to cross. Pinning the
    # coupling and re-solving gives the pressures the network actually reaches, and the
    # firebox settles a few hundred pascals below ambient with the damper choking it — which
    # is what a damper is for.
    def settle(links, capacities, potentials, dt, heads = nil, limits = nil)
      return {} if links.empty?

      components(links).each_with_object({}) do |group, acc|
        acc.merge!(solve_component(group, capacities, potentials, dt, heads, limits))
      end.freeze
    end

    def head(heads, link) = heads ? heads.fetch(link.id, 0.0) : 0.0

    # Split the links into connected components, so a large operation solves several small
    # systems rather than one big one — the elimination below is cubic in the component, and
    # nothing couples a firebox to a gearbox.
    #
    # Order follows the link list, which is declaration order, so the grouping cannot depend
    # on hash iteration. `graph_spec` shuffles nodes and links and compares digests.
    def components(links)
      group_of = {}
      groups = []

      links.each do |link|
        ga = group_of[link.a]
        gb = group_of[link.b]

        if ga.nil? && gb.nil?
          group_of[link.a] = group_of[link.b] = groups.length
          groups << [ link ]
        elsif ga.nil?
          group_of[link.a] = gb
          groups[gb] << link
        elsif gb.nil?
          group_of[link.b] = ga
          groups[ga] << link
        elsif ga == gb
          groups[ga] << link
        else
          # Two partial components have just met. Merge the later into the earlier so the
          # surviving index is the lower one, which keeps the result independent of the order
          # the two halves happened to be discovered in.
          keep, drop = ga < gb ? [ ga, gb ] : [ gb, ga ]
          groups[keep].concat(groups[drop]) << link
          groups[drop] = nil
          group_of.transform_values! { |g| g == drop ? keep : g }
        end
      end

      groups.compact
    end

    def solve_component(links, capacities, potentials, dt, heads, limits)
      ids = links.flat_map { |link| [ link.a, link.b ] }.uniq
      # link_id => the transfer it has been pinned to. A coupling at its choke carries a
      # fixed amount and contributes no conductance, exactly like a current source.
      pinned = {}
      # A coupling may be let go once. Pinning alone is not enough and the failure is loud:
      # pinning the flue at its 3 kg/tick throat drove the firebox pressure down, which is
      # the state in which the flue would no longer be choked at all — and with no way back
      # it stayed pinned, extracting a fixed 3 kg from a box the damper could only put
      # 0.85 kg into. Measured: an 80 kPa vacuum inside a firebox open to the sky.
      #
      # Releasing at most once bounds the whole loop at two state changes per coupling, so it
      # cannot chatter between pinned and free.
      released = {}
      transfers = nil

      (limits ? MAX_CONSTRAINT_PASSES : 1).times do
        settled = settled_potentials(links, ids, capacities, potentials, dt, heads, pinned)
        free = links.to_h { |link| [ link.id, free_transfer(link, settled, heads, dt) ] }

        transfers = links.to_h do |link|
          [ link.id, pinned.fetch(link.id) { free.fetch(link.id) } ]
        end

        break unless limits

        # Let go of a coupling the network no longer pushes past its bound...
        loosened = pinned.keys.select do |id|
          next false if released[id]

          low, high = limits[id]
          value = pinned.fetch(id)
          (value == high && free.fetch(id) < high) || (value == low && free.fetch(id) > low)
        end
        loosened.each { |id| pinned.delete(id); released[id] = true }

        # ...and pin the ones it does.
        breached = free.filter_map do |id, transfer|
          next if pinned.key?(id)

          low, high = limits[id]
          next if low.nil?
          next [ id, low ] if transfer < low
          next [ id, high ] if transfer > high
        end
        breached.each { |id, value| pinned[id] = value }

        break if breached.empty? && loosened.empty?
      end

      transfers
    end

    def free_transfer(link, settled, heads, dt)
      link.conductance * ((settled.fetch(link.a) + head(heads, link)) - settled.fetch(link.b)) * dt
    end

    # Assemble `(C/dt + K)·p′ = (C/dt)·p + b` and solve it. `K` is the conductance Laplacian:
    # symmetric, and diagonally dominant because every off-diagonal entry is subtracted from
    # the diagonal it came from.
    def settled_potentials(links, ids, capacities, potentials, dt, heads, pinned)
      n = ids.length
      index = ids.each_with_index.to_h
      matrix = Array.new(n) { Array.new(n, 0.0) }
      rhs = Array.new(n, 0.0)

      ids.each_with_index do |id, i|
        stiffness = capacities.fetch(id, 0.0) / dt
        matrix[i][i] = stiffness
        rhs[i] = stiffness * potentials.fetch(id)
      end

      links.each do |link|
        i = index.fetch(link.a)
        j = index.fetch(link.b)

        if pinned.key?(link.id)
          # A known quantity leaving `a` and arriving at `b`, with no conductance either way.
          rate = pinned.fetch(link.id) / dt
          rhs[i] -= rate
          rhs[j] += rate
          next
        end

        k = link.conductance
        matrix[i][i] += k
        matrix[i][j] -= k
        matrix[j][j] += k
        matrix[j][i] -= k

        # A head makes the far end of this coupling look higher from `b` and lower from `a`.
        bias = k * head(heads, link)
        rhs[i] -= bias
        rhs[j] += bias
      end

      # A body with no capacity whose every coupling has been pinned has an empty row: there
      # is no conductance left to relate its potential to anything. Hold it where it was
      # rather than dividing by zero — nothing reads the value, because a pinned coupling
      # carries the transfer it was given regardless of the potentials.
      ids.each_with_index do |id, i|
        next if matrix[i][i].abs > EPSILON

        matrix[i][i] = 1.0
        rhs[i] = potentials.fetch(id)
      end

      solution = gaussian_elimination(matrix, rhs, n)
      ids.each_with_index.to_h { |id, i| [ id, solution[i] ] }
    end

    # Gaussian elimination with no pivoting.
    #
    # The matrix is symmetric and diagonally dominant by construction, so pivoting buys no
    # accuracy — and leaving it out means the arithmetic does not depend on which rows
    # happened to compare larger, which is one less way for a match to diverge.
    def gaussian_elimination(matrix, rhs, size)
      size.times do |k|
        pivot = matrix[k][k]
        # Only reachable if a whole component has zero capacity, which leaves the system
        # genuinely underdetermined — there is no stored quantity to set the level. Pin the
        # row rather than raising: the potential is unused, and a crash here would be a very
        # obscure way to report a mis-specified node.
        pivot = matrix[k][k] = 1.0 if pivot.abs <= EPSILON

        ((k + 1)...size).each do |row|
          factor = matrix[row][k] / pivot
          next if factor.zero?

          (k...size).each { |col| matrix[row][col] -= factor * matrix[k][col] }
          rhs[row] -= factor * rhs[k]
        end
      end

      solution = Array.new(size, 0.0)
      (size - 1).downto(0) do |i|
        total = rhs[i]
        ((i + 1)...size).each { |j| total -= matrix[i][j] * solution[j] }
        solution[i] = total / matrix[i][i]
      end
      solution
    end

    # A body relaxing toward a fixed, infinite reservoir — ambient air, the environment.
    #
    # This one keeps the exact closed form. A fixed-potential sink is not a network: there is
    # no second body to be solved with, nothing to overshoot, and the exponential converges on
    # the reservoir rather than past it at any dt.
    #
    # Returns the transfer OUT of the body (positive = the body sheds).
    def to_reservoir(capacity, potential, reservoir_potential, conductance, dt)
      return 0.0 if capacity <= EPSILON || conductance <= 0.0

      capacity * (potential - reservoir_potential) * (1.0 - Math.exp(-conductance * dt / capacity))
    end
  end
end
