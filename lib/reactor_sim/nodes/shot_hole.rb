# frozen_string_literal: true

module ReactorSim
  module Nodes
    # **A shot hole: drilled, charged and fired by whoever works it.** The conduit is the charge line
    # from a magazine: it passes one charge on the tick after the hole is ready, and the charge
    # reacts wherever its outlet lands, leaving its fumes. What a shot brings down is a running total
    # (`brought_down_kg`) for whatever follows it — coal down a `ShotYield`, ground loosened ahead of
    # a face.
    #
    # **Its accidents are mishaps of its post** (`fired_by:`), so a poor hand has more of them: a shot
    # that blows out of its hole is, for a tick, a flame in the room (`blowout:`); a charge that
    # misfires stays in the hole. **What then happens to a misfire is the shotfirer's judgement**:
    #
    # - recognised, it is a known misfire he digs out, **all or nothing** — its hazard is at full
    #   weight while any of it remains, and the clearing completes in one tick;
    # - taken for a spent shot, it is a **live charge left in the face** nobody knows of, which
    #   whoever works the face (`struck_by:`, each post by the crew of the node it works) can strike.
    #
    # `fire_control:` holds a charged hole until its lever says fire, so somebody can clear the
    # range; without one it fires as soon as it is charged. `charge_from:` and `freezes_below_k:`
    # say where the charge is kept and below what it is frozen, which its `:frozen` activity reads.
    #
    #   state: progress, firing, charged, misfires, live, clearing, brought_down_kg, blew_out,
    #          blowout_pending, misfire_pending, misjudged_pending, work, struck, frozen,
    #          since_fired_s, status
    class ShotHole < Conduit
      # How long a shot reads as just fired, s.
      FIRED_S = 30.0

      STATUSES = %i[idle charging fired misfire clearing charged].freeze

      MISHAPS = %i[blowout misfire misjudged set_off struck].freeze

      attr_reader :charge_kg, :blowout, :perils, :fired_by, :struck_by, :shot_s, :clear_s, :yield_kg,
                  :blown_out_yield, :fire_control, :charge_from, :freezes_below_k

      # `shot_s` is a sound hand's seconds to drill, charge and fire one hole and `clear_s` to dig
      # out a misfire; `yield_kg` what one shot brings down, a blown-out one `blown_out_yield` of it.
      def initialize(charge_kg:, perils:, fired_by:, shot_s:, clear_s:, yield_kg:, blown_out_yield:, blowout: nil,
                     struck_by: {}, fire_control: nil, charge_from: nil, freezes_below_k: nil, **opts)
        @charge_kg = charge_kg.to_f
        @blowout = blowout&.freeze
        @perils = perils.freeze
        @fired_by = fired_by.to_sym
        @struck_by = struck_by.to_h { |control, crew_of| [ control.to_sym, crew_of.to_sym ] }.freeze
        @shot_s = shot_s.to_f
        @clear_s = clear_s.to_f
        @yield_kg = yield_kg.to_f
        @blown_out_yield = blown_out_yield.to_f
        @fire_control = fire_control&.to_sym
        @charge_from = charge_from&.to_sym
        @freezes_below_k = freezes_below_k&.to_f
        super(**opts)
      end

      def base_initial_state(rng, content)
        super.merge(progress: 0.0, firing: false, charged: false, misfires: 0, live: 0, clearing: 0.0,
                    brought_down_kg: 0.0, blew_out: false, blowout_pending: false,
                    misfire_pending: false, misjudged_pending: false, work: 0.0, struck: 0.0, frozen: false,
                    since_fired_s: FIRED_S, status: 0)
      end

      # One charge, on the tick the hole is fired; nothing otherwise.
      def throughput_kg(state, _ctx) = state.fetch(:firing) ? @charge_kg : 0.0

      def ignition(state, _levers) = state.fetch(:blew_out) ? @blowout : nil

      # `:firing` is how hard the hole is worked; `:misfired` a known misfire, at full weight until it
      # is dug out; `:live` a charge left in the face, struck by working it; `:frozen` working with a
      # frozen charge; `:flying` the seconds after a shot, while what it threw comes down.
      def activity(state, quantity, _dt)
        case quantity
        when :firing then state.fetch(:work).clamp(0.0, 1.0)
        when :misfired then state.fetch(:misfires).positive? ? 1.0 : 0.0
        when :live then state.fetch(:live).positive? ? state.fetch(:struck).clamp(0.0, 1.0) : 0.0
        when :frozen then state.fetch(:frozen) ? state.fetch(:work).clamp(0.0, 1.0) : 0.0
        when :flying then state.fetch(:since_fired_s) < FLYING_S ? 1.0 : 0.0
        end
      end

      # How long what a shot throws is coming down, s.
      FLYING_S = 2.0

      def suffers?(kind) = MISHAPS.include?(kind) || super

      # `misfire` and `misjudged` mark the charge being made; `set_off` and `struck` fire a known
      # misfire and a live charge, which is a flame in the room for a tick and a little brought down.
      def suffer(state, mishap, ctx)
        case mishap.fetch(:kind)
        when :blowout then [ state.merge(blowout_pending: true), [] ]
        when :misfire then [ state.merge(misfire_pending: true), [] ]
        when :misjudged then [ state.merge(misjudged_pending: true), [] ]
        when :set_off then [ went_off(state, :misfires), [] ]
        when :struck then [ went_off(state, :live), [] ]
        else super
        end
      end

      def apply(state, ctx, grant)
        work = [ ctx.controls.fetch(@fired_by, 0.0) / 100.0, 0.0 ].max
        shot = fired(super, ctx).merge(work: work, struck: struck(ctx), frozen: frozen?(ctx))
        shot = shot.fetch(:misfires).positive? ? dig_out(shot, work, ctx) : charge(shot, work, ctx)
        shot.merge(status: STATUSES.index(status(shot)))
      end

      private

      # Every post working the face is somebody who might strike a live charge in it, each by how
      # hard against a full crew.
      def struck(ctx)
        @struck_by.map { |control, crew_of|
          crew = ctx.nodes&.[](crew_of)&.crew || 1
          [ ctx.controls.fetch(control, 0.0) / 100.0 / crew, 0.0 ].max
        }.max || 0.0
      end

      def frozen?(ctx)
        return false unless @charge_from && @freezes_below_k

        temperature = ctx.node_temperature(@charge_from)
        !temperature.nil? && temperature < @freezes_below_k
      end

      # What last tick's firing did, now the charge line has passed what the magazine had.
      def fired(state, ctx)
        since = state.fetch(:since_fired_s) + ctx.dt
        return state.merge(blew_out: false, since_fired_s: since) unless state.fetch(:firing)

        share = (state.fetch(:carried_kg, 0.0) / @charge_kg).clamp(0.0, 1.0)
        blew = state.fetch(:blowout_pending) && share.positive?
        down = @yield_kg * share * (blew ? @blown_out_yield : 1.0)
        state.merge(firing: false, blew_out: blew, blowout_pending: false, since_fired_s: 0.0,
                    brought_down_kg: state.fetch(:brought_down_kg) + down)
      end

      # A charge that misfires stays where it is: known, it waits to be dug out; misjudged, it is
      # left live in the face and the shotfirer goes on to the next hole. A charged hole waits for
      # its fire lever.
      def charge(state, work, ctx)
        return fire_when_told(state, ctx) if state.fetch(:charged)

        progress = state.fetch(:progress) + (work * ctx.dt / @shot_s)
        return state.merge(progress: progress) if progress < 1.0

        done = state.merge(progress: 0.0, misfire_pending: false, misjudged_pending: false)
        return done.merge(live: state.fetch(:live) + 1) if state.fetch(:misjudged_pending)
        return done.merge(misfires: state.fetch(:misfires) + 1) if state.fetch(:misfire_pending)

        fire_when_told(done.merge(charged: true), ctx)
      end

      def fire_when_told(state, ctx)
        return state if @fire_control && ctx.controls.fetch(@fire_control, 0.0) < 50.0

        state.merge(charged: false, firing: true)
      end

      def went_off(state, which)
        return state unless state.fetch(which).positive?

        state.merge(which => state.fetch(which) - 1, blew_out: true, clearing: which == :misfires ? 0.0 : state.fetch(:clearing),
                    brought_down_kg: state.fetch(:brought_down_kg) + (@yield_kg * @blown_out_yield))
      end

      def dig_out(state, work, ctx)
        clearing = state.fetch(:clearing) + (work * ctx.dt / @clear_s)
        return state.merge(clearing: clearing) if clearing < 1.0

        state.merge(clearing: 0.0, misfires: state.fetch(:misfires) - 1)
      end

      def status(state)
        if state.fetch(:misfires).positive?
          state.fetch(:work).positive? ? :clearing : :misfire
        elsif state.fetch(:since_fired_s) < FIRED_S
          :fired
        elsif state.fetch(:charged)
          :charged
        else
          state.fetch(:work).positive? ? :charging : :idle
        end
      end
    end
  end
end
