# frozen_string_literal: true

module ReactorSim
  module Nodes
    # A drum and the two conveyances hanging off it, **in balance**: as conveyance A goes down,
    # conveyance B comes up, so their own weight cancels and only what is *in* A costs anything to
    # lift. Positive `ω` lowers A.
    #
    # **Gravity is a torque source in the drive solve** (`drive_torque`), not an impulse applied
    # after it, so a brake or a clutch reaches equilibrium with the load in the same step — applied
    # afterwards, no brake could ever hold a load. Its work is booked as it is done, by
    # `Tick#book_drive`: into the operation while the load falls, out while it is raised. Nothing
    # here stores potential energy, so somebody stepping aboard changes nothing on the books.
    #
    # The drum knows how much rope it has paid out: `position_m`, integrated off its own speed, is
    # what a depth indicator geared to it reads. Conveyance A is that far down **unless it has hung**.
    #
    # ## Hanging up
    #
    # A conveyance running down onto something lodged in its way (`obstructed_by:` names the node
    # that says where, as `jam_m`) stops there while the drum goes on paying out, and the difference
    # piles up as `slack_m`. Hung, it is off the rope: the drum feels nothing of it, and its weight
    # rests on the jam (`resting_n`) instead. When the jam gives, it falls the slack, and the tick it
    # does is recorded as `snatch_m` for the rope to feel. Raised, the drum takes the slack back in
    # before the conveyance moves.
    #
    # ## The ends of the run
    #
    # Above the top landing is `clearance_m`; below the bottom landing, `overrun_m`. **Reaching
    # either is a failure, decided by speed and position, not by a die**:
    #
    #   caught      over the top with a detaching hook fitted — the rope lets go and the
    #               conveyance hangs in the catch plate
    #   crashed     into the stops below the bottom landing
    #   overwound   over the top with no hook — through the sheaves, the rope parts and the
    #               conveyance falls back down its run
    #
    # Failed, the drum stops (`Tick#stress` takes its momentum) and the way it serves is out of
    # service. Who is hurt, and what it wrecks, is the machine's declaration.
    #
    #   config: moment_of_inertia, radius_m, depth_m, clearance_m, overrun_m, detaching_hook,
    #           endangers, damages, rope, obstructed_by, deck, boarding_hazard, rated_speed_m_s,
    #           perils, conveyance_kg, catches
    #   state:  angular_momentum, position_m, slack_m, snatch_m, resting_n, load_torque,
    #           accel_m_s2, durability, failure
    class Hoist < Node
      include Concerns::Rotating
      include Concerns::Wearing

      # Close enough to a mark, and slow enough, to call the conveyance stopped there.
      LANDING_M = 0.5
      STOPPED_M_S = 0.2

      # How long somebody takes to get aboard, and so how long sending it away hurts them.
      BOARDING_S = 3.0

      attr_reader :moment_of_inertia, :radius_m, :friction, :depth_m, :clearance_m, :overrun_m, :rope,
                  :obstructed_by, :deck, :boarding_hazard, :rated_speed_m_s, :perils, :conveyance_kg

      # `rope:` names the rope the conveyance hangs on. Parted, it is no longer the drum's load.
      # `conveyance_kg:` is each conveyance's own mass, and `catches:` whether they grip their
      # guides when the rope parts — properties of the conveyance, which the rope reads.
      # `deck:` names a holder riding in conveyance A, whose contents are load like anybody aboard.
      # `boarding_hazard:` is what sending it away does to somebody still getting aboard.
      def initialize(id:, moment_of_inertia:, radius_m:, depth_m:, label: nil, friction: 0.0,
                     position_m: 0.0, clearance_m: 6.0, overrun_m: 4.0, detaching_hook: false,
                     endangers: {}, damages: {}, rope: nil, obstructed_by: nil, deck: nil,
                     boarding_hazard: nil, rated_speed_m_s: nil, perils: [], conveyance_kg: 0.0,
                     catches: false)
        super(id: id, label: label)
        @conveyance_kg = conveyance_kg.to_f
        @catches = catches
        @rope = rope&.to_sym
        @obstructed_by = obstructed_by&.to_sym
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
        @overrun_m = overrun_m.to_f
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

      # How hard the conveyance was accelerating last tick, which is what a rope feels beyond its
      # weight.
      def acceleration_m_s2(state) = state.fetch(:accel_m_s2, 0.0)

      def rope_parted?(ctx) = !@rope.nil? && !ctx.node_state(@rope)&.fetch(:failure, nil).nil?

      # Rope paid out below the top landing.
      def position_m(state, _content = nil) = state.fetch(:position_m)

      def slack_m(state, _content = nil) = state.fetch(:slack_m, 0.0)

      # Slack the conveyance fell last tick, which is the snatch the rope takes.
      def snatch_m(state) = state.fetch(:snatch_m, 0.0)

      def hung?(state) = slack_m(state).positive?

      # Where conveyance A actually is.
      def conveyance_m(state) = position_m(state) - slack_m(state)

      # The drum's rim speed, m/s: conveyance A's speed along its run while it hangs on the rope.
      def speed_m_s(state) = omega(state) * @radius_m

      def conveyance_speed_m_s(state) = hung?(state) ? 0.0 : speed_m_s(state)

      # The drum at a mark on its indicator, and not turning.
      def stopped_at?(state, mark_m)
        (position_m(state) - mark_m).abs < LANDING_M && speed_m_s(state).abs < STOPPED_M_S
      end

      def conveyance_stopped_at?(state, mark_m)
        (conveyance_m(state) - mark_m).abs < LANDING_M && conveyance_speed_m_s(state).abs < STOPPED_M_S
      end

      # What a landing asks of its carrier.
      def standing_at?(state, mark_m) = conveyance_stopped_at?(state, mark_m)

      # What is in conveyance A, as the tick sees it — every rider committed to this drum, and
      # whatever is on its deck as of last tick.
      def cargo_kg(ctx)
        riders = ctx.respond_to?(:cargo_kg) ? ctx.cargo_kg(id) : 0.0
        riders + deck_kg(ctx)
      end

      def deck_kg(ctx)
        return 0.0 unless @deck && ctx.respond_to?(:node_state)

        Parcel.total_kg(ctx.node_state(@deck)&.fetch(:parcels, []) || [])
      end

      # How hard the conveyance is being run against its rated speed, for a peril that `scales_with:
      # :swing` — one with no guides swings worse the faster it goes.
      def activity(state, quantity, _dt)
        return nil unless quantity == :swing && @rated_speed_m_s&.positive?

        conveyance_speed_m_s(state).abs / @rated_speed_m_s
      end

      # The imbalance, at the drum. B rides empty, so it is A's load — and the ropes', the longer side
      # outweighing the shorter, so a heavy rope is most to lift with A at the bottom — until the rope
      # parts or A hangs, when it is no longer on the drum at all.
      def drive_torque(state, ctx)
        return 0.0 if rope_parted?(ctx) || hung?(state)

        Units::GRAVITY_M_PER_S2 * @radius_m * (cargo_kg(ctx) + rope_imbalance_kg(state, ctx))
      end

      def rope_imbalance_kg(state, ctx)
        rope = @rope && ctx.nodes&.[](@rope)
        return 0.0 unless rope.respond_to?(:kg_per_m)

        rope.kg_per_m * ((2.0 * conveyance_m(state)) - @depth_m)
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

      # The depth of a jam conveyance A is at or above, as of last tick; nil if there is none in its way.
      def jam_below(state, ctx)
        jam = @obstructed_by && ctx.node_state(@obstructed_by)&.fetch(:jam_m, nil)
        jam if jam && conveyance_m(state) <= jam + LANDING_M
      end

      # What a hung conveyance puts on what it hangs from: itself and everybody in it.
      def resting_n(state, ctx)
        return 0.0 unless hung?(state)

        (@conveyance_kg + cargo_kg(ctx)) * Units::GRAVITY_M_PER_S2
      end

      # --- the ends -------------------------------------------------------------

      def into_top?(state) = conveyance_m(state) < -@clearance_m

      def into_bottom?(state) = conveyance_m(state) > @depth_m + @overrun_m

      def overload?(state, _ctx, _integrity) = into_top?(state) || into_bottom?(state)

      # Ascending severity: a conveyance hung in the catch plate is the least of the three.
      def failure_modes = { caught: {}, crashed: {}, overwound: {} }

      def failure_mode(state, _ctx, _cause)
        return :crashed if into_bottom?(state)

        @detaching_hook ? :caught : :overwound
      end

      # How hard it hit, which is what a hazard here scales with.
      def failure_detail(state, _ctx)
        { speed_m_s: speed_m_s(state).abs.round(2), position_m: position_m(state).round(2) }
      end
    end
  end
end
