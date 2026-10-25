# frozen_string_literal: true

module ReactorSim
  module Operations
    module MobileEngine
      # **The driver**: a governor post working a mobile engine's throttle to what it is asked for,
      # and its feed to the water — the two levers that have to be worked, where the rest are held
      # by the blueprint. From the boiler's frozen last tick, read **through whatever is fitted to
      # read it with**: try-cocks give him the water in steps, a glass nearly true, and with no
      # pressure gauge he knows her pressure by the sound of her. Rounding, not noise, so nothing
      # is drawn.
      #
      # **The feed is worked, not set.** A fixed feed matches one rate of steaming: worked harder
      # the water falls, eased it rises and primes. He nudges it against the gap between the water
      # he sees and the water he wants, so a coarse reading is a wide swing and a slip at the post
      # is a low water. See `docs/design_sketches/mobile-engines.md` §4–5.
      class Driver
        # **Under this share of working pressure he eases her**, and by `SPENT_SHARE` the throttle is
        # shut: he will not pull a boiler down to nothing to do what he was asked.
        EASE_SHARE = 0.8
        SPENT_SHARE = 0.5

        # The water he keeps, as he reads it, and how hard he works the feed against a gap: lever
        # percent a second for a whole drum's difference.
        KEEP_FILL = 0.55
        FEED_PER_S = 40.0

        # **The hose**, where the engine has one: he calls for water under this share of a full
        # tank and stops at full.
        CALLS_FOR_WATER = 0.5
        TANK_FULL = 0.98

        # **He will not let her race**: past her governed speed he eases the throttle, and by this
        # much over it he has shut it — an engine whose work has stopped is not a flywheel to burst.
        RACING = 1.2

        attr_reader :boiler, :levers

        # `hose:` is the hose's valve, `tank:` the engine's tank and `tank_kg:` what it holds full —
        # all three or none. `shaft:` and `governed_omega:` are the speed he holds her under.
        def initialize(boiler:, throttle:, feed:, working_pa:, water_step:, pressure_step_pa:, hose: nil, tank: nil,
                       tank_kg: nil, shaft: nil, governed_omega: nil)
          @boiler = boiler.to_sym
          @throttle = throttle.to_sym
          @feed = feed.to_sym
          @hose = hose&.to_sym
          @tank = tank&.to_sym
          @tank_kg = tank_kg&.to_f
          @shaft = shaft&.to_sym
          @governed_omega = governed_omega&.to_f
          @levers = [ @throttle, @feed, @hose ].compact.freeze
          @working_pa = working_pa.to_f
          @water_step = water_step.to_f
          @pressure_step_pa = pressure_step_pa.to_f
          freeze
        end

        # `{ lever => value }` for the levers he works. `commanded` is his own post's lever, what
        # the engine is asked for; frozen, he does nothing and they hold. How late he is (`lateness:`)
        # is for a driver running a train, and keeping the engine does not read it.
        def govern(commanded:, nodes:, states:, content:, dt:, frozen:, held:, **)
          return held if frozen

          drum = nodes.fetch(@boiler)
          drum_state = states.fetch(@boiler)
          pressure = read(drum.pressure_pa(drum_state, content), @pressure_step_pa)
          fill = read(drum.effective_fill(drum_state, content), @water_step)
          easing = (((pressure / @working_pa) - SPENT_SHARE) / (EASE_SHARE - SPENT_SHARE)).clamp(0.0, 1.0)
          feed = held.fetch(@feed) + (FEED_PER_S * (KEEP_FILL - fill) * dt)

          worked = { @throttle => commanded * easing * holding(nodes, states), @feed => feed.clamp(0.0, 100.0) }
          @hose ? worked.merge(@hose => hose(nodes, states, held)) : worked
        end

        private

        def read(value, step) = step.positive? ? (value / step).round * step : value

        # 1 at or under her governed speed, falling to nothing by `RACING` over it.
        def holding(nodes, states)
          return 1.0 unless @shaft && @governed_omega&.positive?

          over = nodes.fetch(@shaft).omega(states.fetch(@shaft)) / @governed_omega
          ((RACING - over) / (RACING - 1.0)).clamp(0.0, 1.0)
        end

        # Open under the call, and kept open until she is full.
        def hose(nodes, states, held)
          share = nodes.fetch(@tank).contents_kg(states.fetch(@tank)) / @tank_kg
          calling = share < CALLS_FOR_WATER || (held.fetch(@hose).positive? && share < TANK_FULL)
          calling ? 100.0 : 0.0
        end
      end
    end
  end
end
