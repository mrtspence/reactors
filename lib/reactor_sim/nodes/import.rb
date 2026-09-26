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
    # **Starvation needs no special case.** An empty buffer still declares stall torque;
    # `transmit_torque` scales the impulse back against `extractable_joules` and the shaft gains
    # nothing. What the player sees is the shaft slowing under its load rather than stopping
    # dead — the fan winds down, the air falls, and the gas starts to build.
    class Import < Node
      include Concerns::Rotating

      attr_reader :moment_of_inertia, :radius_m, :friction, :rated_torque_nm, :rated_omega,
                  :control_id

      # `holds_seconds:` is how much bought work the shaft can have **in hand**, as a multiple of
      # its own rated output. It exists to absorb the one-tick lag between an exporter paying out
      # and this shaft spending, not to let a mine stockpile power: without it a lightly-loaded
      # operation banks everything it is sent and runs for hours on the reserve, which makes the
      # supply a battery rather than a rope. Measured on a mine fed more than it could use,
      # **355 MJ** of it after an hour.
      def initialize(id:, rated_torque_nm:, rated_omega:, label: nil, holds_seconds: 10.0,
                     moment_of_inertia: 50.0, radius_m: 1.0, friction: 0.0, control_id: nil)
        super(id: id, label: label)
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

      # `supply_joules` is real energy held by this operation between the moment it arrives and
      # the moment the shaft spends it, so `Operation#total_joules` counts it. Without that the
      # exchange would look like creation on one side and destruction on the other.
      def base_initial_state(rng, content)
        super.merge(supply_joules: 0.0)
      end

      # Carries its own rotor, as `Motor` does — a line shaft is one piece of machinery rather
      # than an engine belted to a separate flywheel.
      def drives = id

      def supply_joules(state) = state.fetch(:supply_joules, 0.0)

      # The driver contract `Tick#transmit_torque` reads: what this node can pay for.
      def extractable_joules(state) = [ supply_joules(state), 0.0 ].max

      # The other half of that contract. **Deliberately unclamped**: `transmit_torque` never
      # charges more than `extractable_joules`, so a negative balance here means the bill was
      # computed wrong and the conservation spec should say so rather than a clamp hiding it.
      def add_joules(state, joules, _content = nil)
        state.merge(supply_joules: supply_joules(state) + joules)
      end

      attr_reader :capacity_joules

      # What `Match#exchange!` hands in. Outside the tick, like a command.
      #
      # Returns `[state, wasted]`. **Anything past what the shaft can hold is wasted rather than
      # refused**, because it has already left the supplier's books as `joules_to_work` — a
      # refusal here would destroy it silently, which is the one thing the ledger exists to
      # prevent. Physically it is the rope slipping and the shaft spinning free against a mine
      # with nothing to drive, so it is booked as friction.
      def receive(state, joules)
        total = supply_joules(state) + joules
        return [ state.merge(supply_joules: total), 0.0 ] if total <= @capacity_joules

        [ state.merge(supply_joules: @capacity_joules), total - @capacity_joules ]
      end

      def apply(state, ctx, _grant)
        return state.merge(torque: 0.0) unless extractable_joules(state).positive?

        governed = [ 1.0 - (omega(state) / @rated_omega), 0.0 ].max

        state.merge(torque: @rated_torque_nm * governed * demand(ctx))
      end

      # An optional clutch, so a shaft can be thrown out of gear without the supply being cut.
      def demand(ctx)
        return 1.0 unless @control_id

        (ctx.controls.fetch(@control_id, 0.0) / 100.0).clamp(0.0, 1.0)
      end
    end
  end
end
