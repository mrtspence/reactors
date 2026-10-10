# frozen_string_literal: true

module ReactorSim
  module Operations
    module Mine
      # **The winding engineman, as a controller.** The player names where cage A should go; the
      # engineman works the clutches and the brake to get it there, every tick in phase 0, from
      # where the cage was and how fast it was going last tick.
      #
      # He brakes at a point he **believes in** — `v²/2a` for a sound brake, plus a margin — and
      # overwinds come from where that belief and the world part company: a hand out of their depth
      # brakes late, a faded brake stops shorter than believed, a surge arrives faster than his
      # brake point allowed for. Nothing here says when an overwind happens.
      #
      # A slip at the post keeps its meaning: frozen, he stops working the levers and they hold
      # where they were; the destination lever's own slips send the cage somewhere else.
      class Winding
        # What he believes a sound brake takes out of the cage, m/s².
        BELIEVED_DECEL = 2.0

        # How far short of the mark he starts braking beyond the arithmetic, m.
        MARGIN_M = 0.5

        attr_reader :hoist, :forward, :reverse, :brake_release

        def initialize(hoist:, forward:, reverse:, brake_release:)
          @hoist = hoist.to_sym
          @forward = forward.to_sym
          @reverse = reverse.to_sym
          @brake_release = brake_release.to_sym
          freeze
        end

        def levers = [ @forward, @reverse, @brake_release ]

        # `destination` is the commanded lever's value, percent of the shaft from bank. `lateness`
        # is 1.0 for a hand who knows the job and more for one out of their depth. Returns the
        # levers this governs, `{ id => position }`, or `held` unchanged while he is frozen.
        def govern(destination:, drum:, drum_state:, lateness:, frozen:, held:)
          return held if frozen

          goal = destination / 100.0 * drum.depth_m
          gap = goal - drum.position_m(drum_state)
          speed = drum.speed_m_s(drum_state)

          return stopped if drum.stopped_at?(drum_state, goal)
          return stopped if closing?(gap, speed) && gap.abs <= brake_point(speed, lateness)

          drive(gap)
        end

        private

        def closing?(gap, speed) = (gap * speed).positive?

        # Where he starts braking. A hand out of their depth thinks it takes less road than it does.
        def brake_point(speed, lateness) = ((speed**2) / (2.0 * BELIEVED_DECEL) / lateness) + MARGIN_M

        def stopped = { @forward => 0.0, @reverse => 0.0, @brake_release => 0.0 }

        # Forward lowers cage A, the reverser raises it; the brake comes off to drive.
        def drive(gap)
          { @forward => gap.positive? ? 100.0 : 0.0, @reverse => gap.negative? ? 100.0 : 0.0,
            @brake_release => 100.0 }
        end
      end
    end
  end
end
