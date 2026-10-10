# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A winding drum and the two cages hanging off it, **in balance**: as cage A goes down cage B
    # comes up, so the cages' own weight cancels and only what is *in* cage A costs anything to
    # lift. Positive `ω` lowers cage A.
    #
    # **Gravity is a torque source in the drive solve** (`drive_torque`), not an impulse applied
    # after it, so a brake or a clutch reaches equilibrium with the load in the same step — applied
    # afterwards, no brake could ever hold a cage. Its work is booked as it is done, by
    # `Tick#book_drive`: into the operation while the load falls, out while it is raised. Nothing
    # here stores potential energy, so a man stepping into the cage changes nothing on the books.
    #
    # The drum knows where its cage is: `position_m` is cage A's depth below the bank landing,
    # integrated off the drum's own speed.
    #
    #   config: moment_of_inertia, radius_m, depth_m (the bottom landing), friction
    #   state:  angular_momentum, position_m, load_torque
    class Hoist < Node
      include Concerns::Rotating

      # Close enough to a mark, and slow enough, to call the cage stopped there.
      LANDING_M = 0.5
      STOPPED_M_S = 0.2

      attr_reader :moment_of_inertia, :radius_m, :friction, :depth_m

      def initialize(id:, moment_of_inertia:, radius_m:, depth_m:, label: nil, friction: 0.0,
                     position_m: 0.0)
        super(id: id, label: label)
        @moment_of_inertia = moment_of_inertia.to_f
        @radius_m = radius_m.to_f
        @depth_m = depth_m.to_f
        @friction = friction.to_f
        @position_m = position_m.to_f
        freeze
      end

      def base_initial_state(rng, content)
        super.merge(position_m: @position_m, load_torque: 0.0)
      end

      def position_m(state) = state.fetch(:position_m)

      # Cage A's speed down the shaft, m/s.
      def speed_m_s(state) = omega(state) * @radius_m

      def stopped_at?(state, mark_m)
        (position_m(state) - mark_m).abs < LANDING_M && speed_m_s(state).abs < STOPPED_M_S
      end

      # What is in cage A, as the tick sees it — every rider committed to this drum.
      def cargo_kg(ctx) = ctx.respond_to?(:cargo_kg) ? ctx.cargo_kg(id) : 0.0

      # The imbalance, at the drum. Cage B rides empty, so it is all cage A's load.
      def drive_torque(_state, ctx) = Units::GRAVITY_M_PER_S2 * @radius_m * cargo_kg(ctx)

      # What a brake on this drum has to hold, as of last tick — read through `supports:`.
      def load_torque(state, _content = nil) = state.fetch(:load_torque, 0.0)

      # TODO: W1 — the ends of the shaft. Past the bank mark is the headframe and below the bottom
      # landing is the sump; what happens to a cage that reaches either is unit 2's, untested here.
      def apply(state, ctx, _grant)
        state.merge(position_m: position_m(state) + (speed_m_s(state) * ctx.dt),
                    load_torque: drive_torque(state, ctx))
      end
    end
  end
end
