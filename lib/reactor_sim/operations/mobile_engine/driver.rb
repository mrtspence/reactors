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

        # **Topping up**, where the engine can be — a hose from a standpipe, a chute, a water column:
        # he calls for more under this share of full and stops at full.
        CALLS_FOR_MORE = 0.5
        TOPPED = 0.98

        # **He will not let her race**: past her governed speed he eases the throttle, and by this
        # much over it he has shut it — an engine whose work has stopped is not a flywheel to burst.
        RACING = 1.2

        # One way of topping her up: the `valve:` he works, the `holder:` it fills and what it holds
        # `full_kg`.
        TopUp = Struct.new(:valve, :holder, :full_kg, keyword_init: true)

        attr_reader :boiler, :levers, :top_ups

        # `top_ups:` are the ways she is topped up (`TopUp`). `shaft:` and `governed_omega:` are the
        # speed he holds her under.
        def initialize(boiler:, throttle:, feed:, working_pa:, water_step:, pressure_step_pa:, top_ups: [], shaft: nil,
                       governed_omega: nil)
          @boiler = boiler.to_sym
          @throttle = throttle.to_sym
          @feed = feed.to_sym
          @top_ups = top_ups.freeze
          @shaft = shaft&.to_sym
          @governed_omega = governed_omega&.to_f
          @levers = ([ @throttle, @feed ] + @top_ups.map(&:valve)).freeze
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

          { @throttle => commanded * easing * holding(nodes, states), @feed => feed.clamp(0.0, 100.0) }
            .merge(@top_ups.to_h { |top_up| [ top_up.valve, calling?(top_up, nodes, states, held) ? 100.0 : 0.0 ] })
        end

        # Under the call, and kept open until full.
        def calling?(top_up, nodes, states, held)
          share = nodes.fetch(top_up.holder).contents_kg(states.fetch(top_up.holder)) / top_up.full_kg
          share < CALLS_FOR_MORE || (held.fetch(top_up.valve, 0.0).positive? && share < TOPPED)
        end

        private

        def read(value, step) = step.positive? ? (value / step).round * step : value

        # 1 at or under her governed speed, falling to nothing by `RACING` over it.
        def holding(nodes, states)
          return 1.0 unless @shaft && @governed_omega&.positive?

          over = nodes.fetch(@shaft).omega(states.fetch(@shaft)) / @governed_omega
          ((RACING - over) / (RACING - 1.0)).clamp(0.0, 1.0)
        end
      end
    end
  end
end
