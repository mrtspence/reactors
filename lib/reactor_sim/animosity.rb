# frozen_string_literal: true

module ReactorSim
  # **People who cannot stand each other, and what they do about it.**
  #
  # A grudge runs one way, holder to target, 0..1, and comes from the race, the individual, earlier
  # matches and this one, added and clamped (`table`). Resentment wears through a hidden
  # **patience** while the two share a place — `Blunder`'s margin, with a target — and when it runs
  # out the holder acts: a row, a brawl, a shove into a peril, or sabotage through their post. A
  # boss posted over the place may step in first.
  #
  # Pure, and it draws nothing: the dice were thrown in phase 0 on each person's own temper stream,
  # so every outcome is a deterministic comparison. `Provoke` is phase 6d′.
  #
  # See `docs/design_sketches/animosity-and-distraction.md`.
  module Animosity
    # Patience, rolled wide for the reason `Blunder::SPREAD` is: a crew that has kept its temper
    # for twenty minutes must not thereby be known safe.
    SPREAD = (0.35..2.6)

    # Patience spent per second, per person present, per unit of grudge. A middling grudge and a
    # middling patience last half an hour of standing together at a neutral temper.
    SPEND_PER_S = 2.0e-3

    # And mended per second with nobody about it is spent on.
    MEND_PER_S = 3.0e-3

    # **What anybody costs anybody**, grudge or none, so a crowded gang of short tempers rows
    # among itself — more for somebody `annoying`, less for somebody `calming` (`irritation`).
    IRRITATION = 0.02

    # How much a brawl in the room shortens everybody else's temper, per brawl.
    RUMPUS = 1.0

    # Tiredness shortens a temper the way it spends a margin.
    SPENT_WEIGHT = 4.0

    # Temperament is read net through `(1 + net)³`: a 1.0 trait is eight times as much, its
    # opposite nothing at all.
    CURVE = 3

    # The harm a full grudge will do at a neutral temperament, against the harm the bystanders
    # caught by it may come to.
    CEILING = 2.0
    TOLERANCE = 1.0

    # The harm at which somebody is willing to kill — the scale escalation is read against.
    LETHAL = Injury::MORTAL_BITE

    # **Reaching for a weapon is a chance each exchange, not a switch**: `ESCALATION` for a grudge
    # that would kill at a neutral temperament, as the square of how deep their `hostility` is
    # against that, times callousness once. A race's standing dislike turns a brawl armed now and then; a
    # deep, callous hatred within a few blows.
    ESCALATION = 0.1
    ESCALATION_POWER = 2

    # **Somebody with a weapon out against them answers in kind**, whatever their temper: this
    # chance each exchange on top of their own.
    ANSWER = 0.5

    # **A grudge is an exception to a kind nature**: this share of it counts as callousness towards
    # the one it is held against, so an elf who would hurt nobody will hurt an orc.
    GRUDGE_HARDENS = 0.5

    # **A violent nature is a grudge against everybody** (`hostility`): this much of it is added to
    # whatever they hold, so a goblin who hates nobody still brawls rather than rows and now and
    # then reaches for the knife, and a gentle soul's hatred goes less far.
    VIOLENCE_HOSTILITY = 1.0

    # What a fist fight is believed to cost.
    BRAWL_HARM = 0.5

    # A row stops two people working for this long.
    ROW_S = 30.0

    # A brawl is an exchange of blows this often, each one a `Combat` contest.
    BOUT_S = 3.0

    # **How much an act gives back of the new patience**, so one grudge does not fire the next act
    # at once. A brawl gives it back blow by blow and stops once the one who started it is sated.
    RELEASE = { row: 0.3, shove: 0.8, sabotage: 0.8, foiled: 0.3, averted: 0.5, seethed: 0.2 }.freeze
    BOUT_RELEASE = 0.05
    LANDED_RELEASE = 0.05
    SATED = 0.6

    # Grudge left per unit of harm done, before spite.
    GRUDGE_PER_HARM = 0.1

    # **What a fight leaves, once it is over**, by the worst it did to them, before spite: a
    # brawl's start leaves `BRAWL_HARM`'s worth, and only a wound that carries them out leaves
    # more, so two who blow off steam without dropping each other part no worse. Everybody is
    # revived, and remembers who sent them there.
    WOUND_GRUDGE = { severe: 0.15, mortal: 0.3 }.freeze

    # What being stared down leaves the one stared down holding against the boss, and what being
    # shouted at leaves the one shouted at holding — both before spite.
    INTIMIDATION_GRUDGE = 0.05
    ROW_GRIEVANCE = 0.025

    # A boss's authority is worth half its ceiling at this figure.
    AUTHORITY_HALF = 1.0

    # Buying a boss never buys peace.
    MOST_AVERTED = Blunder::MOST_EQUIPMENT_SAVES

    # The two ways to keep a crew in line, and the better one is the one used.
    INTIMIDATION = { force: 0.5, toughness: 0.3, charisma: 0.2 }.freeze
    PERSUASION = { charisma: 0.6, intelligence: 0.4 }.freeze

    # Fatigue per second of fighting, before endurance — and, armed, more per kilogram swung for
    # each unit of `force` behind it: the measure the lift limit reads what a body can heave by. A
    # three-kilo pick costs a man half again; a kobold four times over, and a pick made for an ogre
    # a few swings; an ogre hardly anything.
    FIGHTING_EXERTION = 2.0e-3
    WIELD_EXERTION = 3.3e-4

    # A body with no force left to swing with is not divided by zero.
    MIN_FORCE = 0.05

    # **Something a post lets somebody do to somebody.** A deed is a mishap (`Peril.mishap` shape,
    # through `state[:mishaps]`) or a slip at the holder's own lever (through `state[:spite]`);
    # `reaches:` is who it hurts, in `Peril`'s shape plus `boarding:` — whoever is getting into that
    # hoist at the holder's landing. `harm:` is what the holder believes it does.
    Opening = Struct.new(:id, :harm, :mishap, :slip, :places, :stations, :riders, :boarding,
                         keyword_init: true) do
      def initialize(id:, harm:, mishap: nil, slip: nil, places: [], stations: [], riders: [], boarding: nil)
        raise Error, "opening #{id}: a deed is a mishap or a slip, and exactly one" unless mishap.nil? ^ slip.nil?
        if slip && !Opening::SLIPS.include?(slip.to_sym)
          raise Error, "opening #{id}: slip #{slip.inspect} is none of #{Opening::SLIPS.inspect}"
        end

        super(id: id.to_sym, harm: harm.to_f, mishap: Peril.mishap(mishap), slip: slip&.to_sym,
              places: Array(places).map(&:to_sym).freeze, stations: Array(stations).map(&:to_sym).freeze,
              riders: Array(riders).map(&:to_sym).freeze, boarding: boarding&.to_sym)
        freeze
      end

      def reaches?(state, holder_place)
        return true if boarding && state[:via] == boarding && state[:place] == holder_place &&
                       state.fetch(:boarding_s, 0.0).positive?

        carried = state[:via] || state[:riding]
        return true if carried && riders.include?(carried)

        stations.include?(state[:station]) || places.include?(state[:place])
      end
    end

    # A deliberate slip at your own lever: one that holds it, or one that runs it backwards.
    Opening::SLIPS = %i[freeze reverse].freeze

    module_function

    # **A second stream per person**, so the dice tempers throw leave every other die of theirs
    # where it was.
    def stream(minion_id) = :"#{minion_id}/temper"

    def initial_state(rng)
      full = roll(rng)
      { patience: full, patience_full: full, fight: nil }
    end

    def roll(rng) = rng.between(SPREAD.begin, SPREAD.end)

    # Phase 0's dice for one person, from their own temper stream: always all seven.
    def draw(rng)
      { patience: roll(rng), act: rng.float, judge: rng.float, avert: rng.float,
        attack: rng.float, defend: rng.float, escalate: rng.float }
    end

    # **Holder → target → amount**, over seats, from everything but this match. `account` is
    # `{ holder_person => { target_person => amount } }` from the delivery tier.
    def table(minions, account = {})
      account = carried_over(account) || {}
      ordered = minions.sort_by(&:id)

      ordered.each_with_object({}) { |holder, acc|
        row = ordered.each_with_object({}) do |target, held|
          next if target.id == holder.id

          amount = authored(holder, target) + account.dig(holder.minion, target.minion).to_f
          held[target.id] = amount.clamp(0.0, 1.0) if amount.positive?
        end
        acc[holder.id] = row.freeze unless row.empty?
      }.freeze
    end

    # Grudges from earlier matches as `options:` holds them: symbolised, or nil for none, so an
    # operation nobody has a quarrel in snapshots exactly as before.
    def carried_over(account)
      rows = (account || {}).to_h { |h, row| [ h.to_sym, row.to_h { |t, v| [ t.to_sym, v.to_f ] }.freeze ] }
                            .reject { |_, row| row.empty? }
      rows.empty? ? nil : rows.freeze
    end

    def authored(holder, target)
      holder.grudges.fetch(target.archetype, 0.0) + holder.grudges.fetch(target.minion, 0.0) +
        target.resented_by.fetch(holder.archetype, 0.0) + target.resented_by.fetch(holder.minion, 0.0)
    end

    # The whole of it, this match's included.
    def grudge(table, holder_id, holder_state, target_id)
      (table.dig(holder_id, target_id).to_f + holder_state.fetch(:grudges, {}).fetch(target_id, 0.0)).clamp(0.0, 1.0)
    end

    # **How much of a grudge from an earlier match one more match wears away**, at a neutral spite:
    # divided by `spite`, so a forgiving soul has forgotten by the next and a spiteful dwarf barely
    # notices the time pass. Read by the delivery tier, which keeps the account's grudges.
    FADE_PER_MATCH = 0.25

    def faded(amount, tags)
      kept = amount * (1.0 - (FADE_PER_MATCH / scale(net_of(tags, :spiteful, :forgiving))))
      [ kept, 0.0 ].max
    end

    def net(minion, trait, opposite) = Injury.numeric(minion.tag(trait)) - Injury.numeric(minion.tag(opposite))

    def net_of(tags, trait, opposite) = Injury.numeric(tags.fetch(trait, 0.0)) - Injury.numeric(tags.fetch(opposite, 0.0))

    def scale(net) = (1.0 + net.clamp(-1.0, 1.0))**CURVE

    def violence(minion) = net(minion, :violent_nature, :gentle)

    def temper(minion) = scale(net(minion, :short_tempered, :even_tempered) + violence(minion))

    # Towards somebody they hold `grudge` against.
    def callousness(minion, grudge = 0.0) = scale(net(minion, :callous, :kindly) + (GRUDGE_HARDENS * grudge))

    # The grudge as far as what they will do to somebody goes: what they hold, and their violence.
    def hostility(minion, grudge) = (grudge + (VIOLENCE_HOSTILITY * violence(minion))).clamp(0.0, 1.0)

    def recklessness(minion) = scale(net(minion, :reckless, :conscientious))

    def spite(minion) = scale(net(minion, :spiteful, :forgiving))

    # What sharing a place with `other` costs anybody's patience, before any grudge.
    def irritation(other) = IRRITATION * scale(net(other, :annoying, :calming))

    # The most harm they will do to somebody they hold this grudge against.
    def ceiling(minion, grudge) = hostility(minion, grudge) * CEILING * callousness(minion, grudge)

    # The most harm, times the people caught, they will risk to anybody else.
    def tolerance(minion) = TOLERANCE * recklessness(minion)

    # The chance, this exchange, that they reach for what is in their hand — `threatened:` if the
    # other already has.
    def escalation(minion, grudge, threatened: false)
      depth = hostility(minion, grudge) * CEILING / LETHAL
      own = (ESCALATION * (depth**ESCALATION_POWER) * callousness(minion, grudge)).clamp(0.0, 1.0)
      threatened ? 1.0 - ((1.0 - own) * (1.0 - ANSWER)) : own
    end

    # **Whether they would do it.** `harmless:` is a bonehead who has taken it for harmless — to
    # the target and to everybody caught with them.
    def willing?(minion, grudge, harm, bystanders, harmless: false)
      believed = harmless ? 0.0 : harm
      believed <= ceiling(minion, grudge) && believed * bystanders <= tolerance(minion)
    end

    def fighting?(state) = !state[:fight].nil?

    # Fatigue a fight costs per second, before endurance and strain: nothing outside a brawl, the
    # flat rate bare-handed, and the weapon's weight against their `force` on top once drawn.
    def exertion(minion, state)
      fight = state[:fight] or return 0.0
      return 0.0 unless fight[:blows]
      return FIGHTING_EXERTION unless fight[:armed]

      swung = minion.wielding(state, armed: true).fetch(:mass_kg)
      FIGHTING_EXERTION + (WIELD_EXERTION * swung / [ minion.force(state), MIN_FORCE ].max)
    end

    def stood_down?(state) = !Injury::MODES.dig(state[:injury], :stood_down).nil?

    # `[effectiveness, style]` for a boss in this state: the better of staring them down and
    # talking them round, halved at `AUTHORITY_HALF`.
    def authority(boss, state)
      stare = boss.capability(state, effort: INTIMIDATION)
      talk = boss.capability(state, effort: PERSUASION)
      best, style = stare >= talk ? [ stare, :intimidation ] : [ talk, :persuasion ]

      [ best / (best + AUTHORITY_HALF), style ]
    end

    # Whether the boss got there first. Their wits are the attention it takes to see it coming.
    def averted?(effectiveness, wits, die) = die < (effectiveness * wits).clamp(0.0, MOST_AVERTED)
  end
end
