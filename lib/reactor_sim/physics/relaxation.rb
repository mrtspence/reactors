# frozen_string_literal: true

module ReactorSim
  # Two bodies joined by a coupling drift toward a shared value. Heat does it; so does
  # rotation. The mathematics is identical, so there is one implementation.
  #
  #     heat      capacity = heat capacity (J/K)     potential = temperature (K)
  #     rotation  capacity = moment of inertia       potential = angular velocity (rad/s)
  #
  #     equilibrium = (c₁p₁ + c₂p₂) / (c₁ + c₂)
  #     τ           = 1 / (k · (1/c₁ + 1/c₂))
  #     transfer    = c₁ · (p₁ − equilibrium) · (1 − e^(−dt/τ))
  #
  # Two properties make this the right shape for a simulation whose timestep is a design
  # dial rather than a constant:
  #
  #   * **Unconditionally stable.** The exponential factor is in (0, 1) for every `dt`, so a
  #     link can never overshoot the equilibrium no matter how long the step. Explicit Euler
  #     returns negative Kelvin at dt=100 s; this converges cleanly at dt=10⁶.
  #   * **Exactly conservative.** What one body loses the other gains, to the bit, because
  #     it is one number applied twice with opposite signs.
  #
  # ## Why the bound is not optional
  #
  # Pairwise closed form ALONE is not enough in a network. Each link independently moves
  # most of the way to *its own* two-body equilibrium, and the contributions stack: three
  # 600 K bodies feeding one small 300 K body drove it to 1067 K. Energy was still conserved
  # perfectly — the node was simply hotter than anything touching it.
  #
  # So the totals are capped at the point where a node would pass the conductance-weighted
  # mean of its own neighbours, and whatever is not granted stays with the sender. That is
  # the same settlement rule mass obeys, which is why this lives inside the Arbiter's world
  # rather than beside it.
  module Relaxation
    EPSILON = 1e-12

    module_function

    # `links` need only respond to #id, #a, #b and #conductance — ThermalLink and DriveLink
    # both do. `capacities` and `potentials` are hashes keyed by node id.
    #
    # Returns { link_id => transfer }, where a positive transfer moves from `a` to `b`.
    def settle(links, capacities, potentials, dt)
      return {} if links.empty?

      raw = links.to_h { |link| [ link.id, pairwise(link, capacities, potentials, dt) ] }
      scales = bounds(links, raw, capacities, potentials)

      links.to_h do |link|
        [ link.id,
          raw.fetch(link.id) * [ scales.fetch(link.a, 1.0), scales.fetch(link.b, 1.0) ].min ]
      end.freeze
    end

    # The exact two-body solution, for a coupling considered in isolation.
    def pairwise(link, capacities, potentials, dt)
      ca = capacities.fetch(link.a, 0.0)
      cb = capacities.fetch(link.b, 0.0)
      return 0.0 if ca <= EPSILON || cb <= EPSILON

      pa = potentials.fetch(link.a)
      pb = potentials.fetch(link.b)
      equilibrium = ((ca * pa) + (cb * pb)) / (ca + cb)
      tau = 1.0 / (link.conductance * ((1.0 / ca) + (1.0 / cb)))

      ca * (pa - equilibrium) * (1.0 - Math.exp(-dt / tau))
    end

    # How far each node's total transfer must be scaled back so it cannot be driven past
    # the conductance-weighted mean of its neighbours.
    def bounds(links, raw, capacities, potentials)
      # Adjacency is built once. Scanning the link list per node made this an O(n²) sweep —
      # invisible on a four-node rig and very much not on a hundred.
      adjacency = Hash.new { |h, k| h[k] = [] }
      links.each { |l| adjacency[l.a] << l; adjacency[l.b] << l }

      net = Hash.new(0.0)
      links.each do |link|
        transfer = raw.fetch(link.id)
        net[link.a] -= transfer
        net[link.b] += transfer
      end

      net.to_h do |id, total|
        touching = adjacency.fetch(id)
        k_sum = touching.sum(&:conductance)
        reference = touching.sum { |l|
          l.conductance * potentials.fetch(l.a == id ? l.b : l.a)
        } / k_sum

        headroom = capacities.fetch(id, 0.0) * (reference - potentials.fetch(id))
        overshooting = total.abs > headroom.abs && total * headroom >= 0 && total.abs > EPSILON

        [ id, overshooting ? headroom.abs / total.abs : 1.0 ]
      end
    end

    # A body relaxing toward a fixed, infinite reservoir — ambient air, the environment.
    # No bound is needed: a fixed-potential sink cannot be overshot, because the closed form
    # converges on it rather than past it.
    #
    # Returns the transfer OUT of the body (positive = the body sheds).
    def to_reservoir(capacity, potential, reservoir_potential, conductance, dt)
      return 0.0 if capacity <= EPSILON || conductance <= 0.0

      capacity * (potential - reservoir_potential) * (1.0 - Math.exp(-conductance * dt / capacity))
    end
  end
end
