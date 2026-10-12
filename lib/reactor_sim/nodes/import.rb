# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A shaft turned by somebody else's engine.
    #
    # Where work **arrives** from another operation, and the only node whose energy does not come
    # from this operation's own physics. A mine calls it a line shaft; a rope drive from a valley
    # engine house, a compressed-air main and an incoming feeder are all this node with a
    # different label.
    #
    # Everything downstream is ordinary: pumps and fans name it in `driven_by:`, a drivetrain
    # couples to it with a `DriveLink`, and none of them can tell where the torque came from.
    #
    # ## Torque comes from a state, never from `power ÷ ω`
    #
    # `Nodes::Motor` established the rule the hard way and this node obeys it exactly: derive
    # torque from something the node *holds*, and let `Tick#transmit_torque` bill the kinetic
    # energy the shaft measurably gained. A supply divided by ω explodes at rest, which is where
    # a shaft that is being brought up to speed spends its whole first minute.
    #
    # What it holds is `supply_joules` — a buffer filled by `Match#exchange!` — and the torque it
    # declares is a linear motor curve, full at a standstill and falling to nothing at
    # `rated_omega`. That is `Motor`'s `governed` term with the combustion taken out.
    #
    # **Starvation needs no special case.** With nothing in the buffer the shaft gains nothing,
    # so what the player sees is the shaft slowing under its load rather than stopping dead —
    # the fan winds down, the air falls, and the gas starts to build.
    #
    # **It is one end of a rope** (`Concerns::Roped`). Coupled, the reservoir it is pulled toward
    # is the far end's speed and it brakes when it overruns it, so a mine that sheds its load is
    # felt by the engine. Uncoupled — a rig fed by `receive_supply` — the far end is a steady
    # supply at `rated_omega`, and `rated_torque_nm / rated_omega` is the rope.
    #
    # **An overspeed trip throws the clutch out** (`trip:` names the node that is fitted as one,
    # answering `trip_ratio`): past that multiple of rated speed the shaft is `tripped`, the rope
    # slack, until it has run back down to rated. It saves what hangs off the shaft — and sheds
    # the whole operation as a load rejection on whoever is at the far end.
    class Import < Node
      include Concerns::Rotating
      include Concerns::Roped

      attr_reader :moment_of_inertia, :radius_m, :friction, :rated_torque_nm, :rated_omega,
                  :control_id, :trip

      # `holds_seconds:` is how much bought work the shaft can have **in hand**, as a multiple of
      # its own rated output. It exists to absorb the one-tick lag between an exporter paying out
      # and this shaft spending, not to let a mine stockpile power: without it a lightly-loaded
      # operation banks everything it is sent and runs for hours on the reserve, which makes the
      # supply a battery rather than a rope. Measured on a mine fed more than it could use,
      # **355 MJ** of it after an hour.
      def initialize(id:, rated_torque_nm:, rated_omega:, label: nil, holds_seconds: 10.0,
                     moment_of_inertia: 50.0, radius_m: 1.0, friction: 0.0, control_id: nil,
                     trip: nil)
        super(id: id, label: label)
        @trip = trip&.to_sym
        @rated_torque_nm = rated_torque_nm.to_f
        @rated_omega = rated_omega.to_f
        @capacity_joules = @rated_torque_nm * @rated_omega * holds_seconds.to_f
        @moment_of_inertia = moment_of_inertia.to_f
        @radius_m = radius_m.to_f
        @friction = friction.to_f
        @control_id = control_id&.to_sym
        raise Error, "#{id}: rated_omega must be positive" unless @rated_omega.positive?

        freeze
      end

      # `supply_joules` is counted by `Operation#total_joules`: it is energy in hand.
      def rope_capacity_joules = @capacity_joules

      # The rope's conductance in this end's frame: full torque at a standstill, nothing at
      # `rated_omega` against a steady supply.
      def rope_conductance = @rated_torque_nm / @rated_omega

      def base_initial_state(rng, content) = super.merge(tripped: false)

      def apply(state, ctx, _grant)
        conductance = roped?(state) ? state.fetch(:rope_k) : rope_conductance
        reservoir = roped?(state) ? state.fetch(:remote_omega) : @rated_omega

        state.merge(torque: rope_torque(state, ctx, conductance: conductance, reservoir: reservoir),
                    tripped: tripped?(state, ctx))
      end

      # Past the trip's ratio it throws out, and it stays out until the shaft is back to rated.
      def tripped?(state, ctx)
        trip = @trip && ctx.nodes[@trip] or return false

        ratio = omega(state).abs / @rated_omega
        ratio > trip.trip_ratio || (state.fetch(:tripped, false) && ratio > 1.0)
      end

      def drag_conductances(state, ctx)
        super.merge(rope_drags(state, ctx)) { |_, a, b| a + b }
      end
    end
  end
end
