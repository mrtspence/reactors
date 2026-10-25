# frozen_string_literal: true

module ReactorSim
  module Operations
    module MobileEngine
      # **A locomotive's driver running the round**: two governors in one post. `driver:` keeps the
      # engine — throttle, feed, governed speed — as on any mobile engine; this moves the train, the
      # winding engineman's way (`Mine::Winding`): the clutches by how far short of the speed he wants
      # the train is running, the brake from a point he believes in. See
      # `docs/design_sketches/locomotive.md` §5.
      #
      # **Where to**: full, to the dump; tipped, back to the shovel; part-loaded at the shovel, he
      # waits for the rest. **He eases her over the last stretch and brakes at `v²/2a`**, plus a
      # margin, from what he believes the fitted brake does on the steepest bank empty — both over
      # his lateness, so a hand out of their depth comes in fast and brakes late, and a faded brake
      # stops shorter than he believes. Nothing here says when a train crashes. **Running down a
      # bank faster than he wants** he puts the brake on against it.
      #
      # Asked for nothing he stands with the brake on. Frozen, he works nothing and the levers hold:
      # a train running when he froze runs on.
      class Round
        MARGIN_M = 1.0
        FEATHER_M = 25.0
        CREEP_M_S = 0.4
        CLUTCH_GAIN = 50.0
        LEAST_CLUTCH = 5.0

        # Over the speed he wants by this share he starts on the brake, and by `BRAKE_FULL` it is on.
        BRAKE_FROM = 1.0
        BRAKE_FULL = 1.2

        attr_reader :driver, :train, :levers

        # `full_kg` is cars he calls full; `believed_decel` what he believes a sound brake takes out of
        # the train, m/s².
        def initialize(driver:, train:, forward:, reverse:, brake_release:, full_kg:, believed_decel:)
          @driver = driver
          @train = train.to_sym
          @forward = forward.to_sym
          @reverse = reverse.to_sym
          @brake_release = brake_release.to_sym
          @full_kg = full_kg.to_f
          @believed_decel = believed_decel.to_f
          @levers = (driver.levers + [ @forward, @reverse, @brake_release ]).freeze
          freeze
        end

        def govern(commanded:, nodes:, states:, content:, dt:, frozen:, held:, lateness: 1.0)
          return held if frozen

          engine = @driver.govern(commanded: commanded, nodes: nodes, states: states, content: content, dt: dt,
                                  frozen: false, held: held.slice(*@driver.levers))
          train = nodes.fetch(@train)
          train_state = states.fetch(@train)
          return engine.merge(stopped) unless commanded.positive? && !train.broken?(train_state)

          goal = train.track.mark(destination(train, train_state, states))
          engine.merge(run(goal, train, train_state, held, lateness, train.rated_m_s * commanded / 100.0))
        end

        private

        def destination(train, train_state, states)
          cars = Parcel.total_kg(states.dig(train.cars, :parcels) || [])
          return :dump if cars >= @full_kg
          return :loading if cars <= Train::EMPTY_KG

          near_loading = (train.position_m(train_state) - train.track.mark(:loading)).abs < Train::STANDING_M
          near_loading ? :loading : :dump
        end

        def run(goal, train, train_state, held, lateness, rated_m_s)
          gap = goal - train.position_m(train_state)
          speed = train.speed_m_s(train_state)

          return stopped if gap.abs < Train::STANDING_M
          return stopped if closing?(gap, speed) && gap.abs <= brake_point(speed, lateness)

          drive(gap, speed, held, rated_m_s, FEATHER_M / lateness)
        end

        def closing?(gap, speed) = (gap * speed).positive?

        def brake_point(speed, lateness) = ((speed**2) / (2.0 * @believed_decel) / lateness) + MARGIN_M

        def stopped = { @forward => 0.0, @reverse => 0.0, @brake_release => 0.0 }

        # Forward runs towards the dump, the reverser back; the clutch in use starts from where he left
        # it. Over the speed he wants — a bank running her on — the brake goes on against it.
        def drive(gap, speed, held, rated_m_s, feather_m)
          lever = gap.positive? ? @forward : @reverse
          want = [ rated_m_s * (gap.abs / feather_m), CREEP_M_S ].max.clamp(0.0, rated_m_s)
          going = closing?(gap, speed) ? speed.abs : -speed.abs
          clutch = held.fetch(lever, 0.0) + (CLUTCH_GAIN * (want - going) / want)
          release = (100.0 * (BRAKE_FULL - (going / want)) / (BRAKE_FULL - BRAKE_FROM)).clamp(0.0, 100.0)

          { @forward => 0.0, @reverse => 0.0, @brake_release => release }
            .merge(lever => clutch.clamp(LEAST_CLUTCH, 100.0))
        end
      end
    end
  end
end
