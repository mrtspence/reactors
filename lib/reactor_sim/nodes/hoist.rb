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
    # The drum knows how much rope it has paid out: `position_m`, integrated off its own speed, is
    # what a depth indicator geared to it reads. Cage A is that far down **unless it has hung**.
    #
    # ## Hanging up
    #
    # A cage running down onto something lodged in the shaft (`shaft:` names the node that says
    # where, as `jam_m`) stops there while the drum goes on paying out, and the difference piles up
    # as `slack_m`. Hung, the cage is off the rope: the drum feels nothing of it, and its weight
    # rests on the jam (`resting_n`) instead. When the jam gives, the cage falls the slack, and the
    # tick it does is recorded as `snatch_m` for the rope to feel. Raised, the drum takes the slack
    # back in before the cage moves.
    #
    # ## The ends of the shaft
    #
    # Above the bank landing is the headframe, `clearance_m` of it; below the bottom landing is the
    # sump. **Reaching either is a failure, decided by speed and position, not by a die**:
    #
    #   caught      into the headframe with a detaching hook fitted — the rope lets go and the
    #               cage hangs in the catch plate
    #   crashed     into the baulks at the bottom of the sump
    #   overwound   into the headframe with no hook — through the sheaves, the rope parts and the
    #               cage falls back down the open shaft
    #
    # Failed, the drum stops (`Tick#stress` takes its momentum) and the way it serves is out of
    # service. Who is hurt, and what it wrecks, is the machine's declaration.
    #
    #   config: moment_of_inertia, radius_m, depth_m, clearance_m, sump_m, detaching_hook,
    #           endangers, damages, rope, shaft, deck, boarding_hazard, rated_speed_m_s, perils
    #   state:  angular_momentum, position_m, slack_m, snatch_m, resting_n, load_torque,
    #           accel_m_s2, durability, failure
    class Hoist < Node
      include Concerns::Rotating
      include Concerns::Wearing

      # Close enough to a mark, and slow enough, to call the cage stopped there.
      LANDING_M = 0.5
      STOPPED_M_S = 0.2

      # How long somebody takes to get into the cage, and so how long winding away hurts them.
      BOARDING_S = 3.0

      attr_reader :moment_of_inertia, :radius_m, :friction, :depth_m, :clearance_m, :sump_m, :rope,
                  :shaft, :deck, :boarding_hazard, :rated_speed_m_s, :perils, :cage_kg

      # `rope:` names the rope the cage hangs on. Parted, the cage is no longer the drum's load.
      # `cage_kg:` is each cage's own mass, and `catches:` whether they grip the guides when the
      # rope parts — properties of the cage, which the rope reads.
      # `deck:` names a holder riding in cage A, whose contents are load like anybody aboard.
      # `boarding_hazard:` is what winding away does to somebody still getting in.
      def initialize(id:, moment_of_inertia:, radius_m:, depth_m:, label: nil, friction: 0.0,
                     position_m: 0.0, clearance_m: 6.0, sump_m: 4.0, detaching_hook: false,
                     endangers: {}, damages: {}, rope: nil, shaft: nil, deck: nil,
                     boarding_hazard: nil, rated_speed_m_s: nil, perils: [], cage_kg: 0.0,
                     catches: false)
        super(id: id, label: label)
        @cage_kg = cage_kg.to_f
        @catches = catches
        @rope = rope&.to_sym
        @shaft = shaft&.to_sym
        @deck = deck&.to_sym
        @boarding_hazard = boarding_hazard&.freeze
        @rated_speed_m_s = rated_speed_m_s&.to_f
        @perils = perils.freeze
        @moment_of_inertia = moment_of_inertia.to_f
        @radius_m = radius_m.to_f
        @depth_m = depth_m.to_f
        @friction = friction.to_f
        @position_m = position_m.to_f
        @clearance_m = clearance_m.to_f
        @sump_m = sump_m.to_f
        @detaching_hook = detaching_hook
        @failure_hazards = endangers.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
        @failure_damages = damages.to_h { |mode, harm| [ mode.to_sym, harm.freeze ] }.freeze
        freeze
      end

      attr_reader :failure_hazards, :failure_damages

      def catches? = @catches

      def base_initial_state(rng, content)
        super.merge(position_m: @position_m, slack_m: 0.0, snatch_m: 0.0, resting_n: 0.0,
                    load_torque: 0.0, accel_m_s2: 0.0)
      end

      # How hard the cage was accelerating last tick, which is what a rope feels beyond its weight.
      def acceleration_m_s2(state) = state.fetch(:accel_m_s2, 0.0)

      def rope_parted?(ctx) = !@rope.nil? && !ctx.node_state(@rope)&.fetch(:failure, nil).nil?

      # Rope paid out below the bank landing.
      def position_m(state, _content = nil) = state.fetch(:position_m)

      def slack_m(state, _content = nil) = state.fetch(:slack_m, 0.0)

      # Slack the cage fell last tick, which is the snatch the rope takes.
      def snatch_m(state) = state.fetch(:snatch_m, 0.0)

      def hung?(state) = slack_m(state).positive?

      # Where cage A actually is.
      def cage_m(state) = position_m(state) - slack_m(state)

      # The drum's rim speed, m/s: cage A's speed down the shaft while it hangs on the rope.
      def speed_m_s(state) = omega(state) * @radius_m

      def cage_speed_m_s(state) = hung?(state) ? 0.0 : speed_m_s(state)

      # The drum at a mark on its indicator, and not turning.
      def stopped_at?(state, mark_m)
        (position_m(state) - mark_m).abs < LANDING_M && speed_m_s(state).abs < STOPPED_M_S
      end

      def cage_stopped_at?(state, mark_m)
        (cage_m(state) - mark_m).abs < LANDING_M && cage_speed_m_s(state).abs < STOPPED_M_S
      end

      # What a landing asks of its carrier.
      def standing_at?(state, mark_m) = cage_stopped_at?(state, mark_m)

      # What is in cage A, as the tick sees it — every rider committed to this drum, and whatever
      # is on its deck as of last tick.
      def cargo_kg(ctx)
        riders = ctx.respond_to?(:cargo_kg) ? ctx.cargo_kg(id) : 0.0
        riders + deck_kg(ctx)
      end

      def deck_kg(ctx)
        return 0.0 unless @deck && ctx.respond_to?(:node_state)

        Parcel.total_kg(ctx.node_state(@deck)&.fetch(:parcels, []) || [])
      end

      # How hard the cage is being wound against its rated speed, for a peril that `scales_with:
      # :swing` — an unguided kibble swings worse the faster it goes.
      def activity(state, quantity, _dt)
        return nil unless quantity == :swing && @rated_speed_m_s&.positive?

        cage_speed_m_s(state).abs / @rated_speed_m_s
      end

      # The imbalance, at the drum. Cage B rides empty, so it is cage A's load — and the ropes', the
      # longer side outweighing the shorter, so a heavy rope is most to lift with cage A at the
      # bottom — until the rope parts or the cage hangs, when cage A is no longer on the drum at all.
      def drive_torque(state, ctx)
        return 0.0 if rope_parted?(ctx) || hung?(state)

        Units::GRAVITY_M_PER_S2 * @radius_m * (cargo_kg(ctx) + rope_imbalance_kg(state, ctx))
      end

      def rope_imbalance_kg(state, ctx)
        rope = @rope && ctx.nodes&.[](@rope)
        return 0.0 unless rope.respond_to?(:kg_per_m)

        rope.kg_per_m * ((2.0 * cage_m(state)) - @depth_m)
      end

      # What a brake on this drum has to hold, as of last tick — read through `supports:`.
      def load_torque(state, _content = nil) = state.fetch(:load_torque, 0.0)

      def apply(state, ctx, _grant)
        before = ctx.node_state(id)
        accel = (speed_m_s(state) - speed_m_s(before)) / ctx.dt
        paid_out = position_m(state) + (speed_m_s(state) * ctx.dt)
        jam = jam_below(state, ctx)
        slack = jam ? [ paid_out - jam, 0.0 ].max : 0.0
        snatch = jam ? 0.0 : slack_m(state)
        settled = state.merge(position_m: paid_out, slack_m: slack, snatch_m: snatch,
                              accel_m_s2: accel)

        settled.merge(load_torque: drive_torque(settled, ctx), resting_n: resting_n(settled, ctx))
      end

      # The depth of a jam cage A is at or above, as of last tick; nil if there is none in its way.
      def jam_below(state, ctx)
        jam = @shaft && ctx.node_state(@shaft)&.fetch(:jam_m, nil)
        jam if jam && cage_m(state) <= jam + LANDING_M
      end

      # What a hung cage puts on the ledge it hangs from: itself and everybody in it.
      def resting_n(state, ctx)
        return 0.0 unless hung?(state)

        (@cage_kg + cargo_kg(ctx)) * Units::GRAVITY_M_PER_S2
      end

      # --- the ends -------------------------------------------------------------

      def into_headframe?(state) = cage_m(state) < -@clearance_m

      def into_sump?(state) = cage_m(state) > @depth_m + @sump_m

      def overload?(state, _ctx, _integrity) = into_headframe?(state) || into_sump?(state)

      # Ascending severity: a cage hung in the catch plate is the least of the three.
      def failure_modes = { caught: {}, crashed: {}, overwound: {} }

      def failure_mode(state, _ctx, _cause)
        return :crashed if into_sump?(state)

        @detaching_hook ? :caught : :overwound
      end

      # How hard it hit, which is what a hazard here scales with.
      def failure_detail(state, _ctx)
        { speed_m_s: speed_m_s(state).abs.round(2), position_m: position_m(state).round(2) }
      end
    end
  end
end
