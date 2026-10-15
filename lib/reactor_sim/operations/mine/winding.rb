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
      #
      # **He winds away from a landing on its bell.** `ready` is the marshal's signal: until it
      # comes he holds the cage where it stands. It is the marshal's word, not the truth — see
      # `Tick#signalled?`.
      class Winding
        # What he believes a sound brake takes out of the cage, m/s².
        BELIEVED_DECEL = 2.0

        # How far short of the mark he starts braking beyond the arithmetic, m. Inside a landing's
        # width, so a cage creeping onto its mark stops on it.
        MARGIN_M = 0.3

        # A deck holding less than this is empty.
        EMPTY_KG = 1.0

        # **He winds by speed, not by clutch position.** He wants the hoist's rated speed, eased to
        # a creep over the last few metres, and each tick takes up or lets out the clutch by how far
        # short of that the cage is running — so a laden cage gets more clutch and a light one near
        # its mark gets less, and neither stalls nor jumps past it.
        FEATHER_M = 6.0
        CREEP_M_S = 0.4
        CLUTCH_GAIN = 50.0
        LEAST_CLUTCH = 5.0

        attr_reader :hoist, :forward, :reverse, :brake_release, :shuttle, :deck, :deck_full_kg,
                    :coal_from

        def initialize(hoist:, forward:, reverse:, brake_release:, shuttle: nil, deck: nil,
                       deck_full_kg: 0.0, coal_from: nil)
          @hoist = hoist.to_sym
          @forward = forward.to_sym
          @reverse = reverse.to_sym
          @brake_release = brake_release.to_sym
          @shuttle = shuttle&.to_sym
          @deck = deck&.to_sym
          @deck_full_kg = deck_full_kg.to_f
          @coal_from = coal_from&.to_sym
          freeze
        end

        def levers = [ @forward, @reverse, @brake_release ]

        # **Where he winds to**, percent of the shaft from bank. Not shuttling, the player's word.
        # Shuttling, he runs the shaft himself: `calls` — the landings men want, aboard first —
        # always come first; otherwise a laden deck goes up, an empty one comes down for more while
        # there is coal at the bottom, and a deck at the bottom waits until it is full or the coal
        # runs out. With nothing to do the cage stands at bank.
        def dispatch(commanded:, shuttling:, drum:, drum_state:, states:, calls:)
          return commanded unless shuttling
          return calls.first if calls.any?

          deck_kg = contents_kg(states, @deck)
          return 0.0 if deck_kg <= EMPTY_KG && contents_kg(states, @coal_from, :coal) <= EMPTY_KG
          return 100.0 if deck_kg <= EMPTY_KG
          return 0.0 unless drum.cage_stopped_at?(drum_state, drum.depth_m)

          deck_kg >= @deck_full_kg || contents_kg(states, @coal_from, :coal) <= EMPTY_KG ? 0.0 : 100.0
        end

        # `destination` is the commanded lever's value, percent of the shaft from bank. `lateness`
        # is 1.0 for a hand who knows the job and more for one out of their depth. Returns the
        # levers this governs, `{ id => position }`, or `held` unchanged while he is frozen.
        def govern(destination:, drum:, drum_state:, lateness:, frozen:, held:, ready: true)
          return held if frozen

          goal = destination / 100.0 * drum.depth_m
          gap = goal - drum.position_m(drum_state)
          speed = drum.speed_m_s(drum_state)

          return stopped if drum.stopped_at?(drum_state, goal)
          # At the mark he holds it with the brake, whichever way it is drifting: driving back
          # against a rope's imbalance with a stiff clutch only hunts round the landing.
          return stopped if gap.abs < Nodes::Hoist::LANDING_M
          return stopped if !ready && speed.abs < Nodes::Hoist::STOPPED_M_S
          return stopped if closing?(gap, speed) && gap.abs <= brake_point(speed, lateness)

          drive(gap, speed, held, drum.rated_speed_m_s || CREEP_M_S)
        end

        private

        def contents_kg(states, node, resource = nil)
          parcels = node ? states.dig(node, :parcels) || [] : []
          parcels = parcels.select { |p| p.fetch(:resource) == resource } if resource
          Parcel.total_kg(parcels)
        end

        def closing?(gap, speed) = (gap * speed).positive?

        # Where he starts braking. A hand out of their depth thinks it takes less road than it does.
        def brake_point(speed, lateness) = ((speed**2) / (2.0 * BELIEVED_DECEL) / lateness) + MARGIN_M

        def stopped = { @forward => 0.0, @reverse => 0.0, @brake_release => 0.0 }

        # Forward lowers cage A, the reverser raises it; the brake comes off to drive. The clutch
        # in use starts from where he left it, and the other is out.
        def drive(gap, speed, held, rated_m_s)
          lever = gap.positive? ? @forward : @reverse
          want = [ rated_m_s * (gap.abs / FEATHER_M), CREEP_M_S ].max.clamp(0.0, rated_m_s)
          going = closing?(gap, speed) ? speed.abs : -speed.abs
          clutch = held.fetch(lever, 0.0) + (CLUTCH_GAIN * (want - going) / want)

          { @forward => 0.0, @reverse => 0.0, @brake_release => 100.0 }
            .merge(lever => clutch.clamp(LEAST_CLUTCH, 100.0))
        end
      end
    end
  end
end
