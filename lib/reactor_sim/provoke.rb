# frozen_string_literal: true

module ReactorSim
  module Animosity
    # **Phase 6d′: tempers.** Every decision and every exchange of blows reads the minions as the
    # phase begins (`entry`); what they do lands on `out`, walked by sorted id, so two people going
    # for each other on one tick cannot depend on who was visited first.
    #
    # Returns the next minions, this tick's events, the mishaps sabotage leaves for the next tick's
    # `stress`, and the deliberate slips it leaves for the next tick's phase 0.
    class Provoke
      Result = Struct.new(:minions, :events, :mishaps, :spite, keyword_init: true)

      # `defence:` and `ambient:` are the tick's own readings of a person where they stand —
      # `Minion#defend` under their load, and the room as it reaches their wits.
      # `wounds:` is the content's catalogue and `wound_dice:` each person's `wound:` die this tick.
      def initialize(minions:, table:, control_points:, opportunities:, dice:, carried:, ctx:,
                     defence:, ambient:, wounds:, wound_dice:)
        @minions = minions
        @table = table
        @control_points = control_points
        @opportunities = opportunities
        @dice = dice
        @wounds = wounds
        @wound_dice = wound_dice
        @carried = carried
        @ctx = ctx
        @defence = defence
        @ambient = ambient
      end

      def call(entry)
        @entry = entry
        @out = entry.dup
        @events = []
        @mishaps = []
        @spite = []
        @overseers = overseers

        rows
        melees.each_value { |members| brawl(members) }
        @entry.keys.sort.each { |id| temper(id) }

        Result.new(minions: @out.transform_values(&:freeze).freeze, events: @events.freeze,
                   mishaps: @mishaps.freeze, spite: @spite.freeze)
      end

      private

      def dt = @ctx.dt

      # Somebody who can quarrel: here, on their feet, nobody's cargo, not aboard a hoist.
      def able?(id, state = @entry[id])
        !state.nil? && @minions.key?(id) && !Animosity.stood_down?(state) && !@carried.key?(id) &&
          state[:via].nil? && state[:riding].nil?
      end

      def present(id)
        place = @entry.fetch(id)[:place]
        @entry.keys.sort.select { |other| other != id && able?(other) && @entry.fetch(other)[:place] == place }
      end

      def grudge(holder, target) = Animosity.grudge(@table, holder, @out.fetch(holder), target)

      def hostility(holder, target) = Animosity.hostility(@minions.fetch(holder), grudge(holder, target))

      def irritation(other) = Animosity.irritation(@minions.fetch(other))

      def write(id, **changes) = @out[id] = @out.fetch(id).merge(changes)

      # --- the boss ---------------------------------------------------------

      # `{ place => { boss:, effectiveness:, wits:, style: } }`, the best boss over each place.
      # A boss rowing with somebody still has an eye on the rest; one in a brawl does not.
      def overseers
        @control_points.values.reject { |cp| cp.oversees.empty? }.sort_by(&:id).each_with_object({}) do |post, acc|
          boss = @entry.keys.sort.find { |id| @entry.fetch(id)[:station] == post.id && able?(id) && !Animosity.brawling?(@entry.fetch(id)) }
          next if boss.nil?

          minion = @minions.fetch(boss)
          state = @entry.fetch(boss)
          effectiveness, style = Animosity.authority(minion, state)
          watch = { boss: boss, effectiveness: effectiveness, style: style,
                    wits: minion.wits(state, ambient: @ambient.call(minion, state)) }
          post.oversees.each do |place|
            best = acc[place]
            acc[place] = watch if best.nil? || watch[:effectiveness] * watch[:wits] > best[:effectiveness] * best[:wits]
          end
        end
      end

      def stepped_in(id, *others)
        watch = @overseers[@entry.fetch(id)[:place]] or return nil
        return nil if ([ id ] + others).include?(watch[:boss])
        return nil unless Animosity.averted?(watch[:effectiveness], watch[:wits], @dice.fetch(id).fetch(:avert))

        watch
      end

      # **Staring somebody down works, and is remembered.** Talking them round is not. Either puts
      # them in line: some patience back, more for a stare (`PUT_IN_LINE`).
      def averted(id, watch, mode)
        boss = watch[:boss]
        @events << Event.build(type: :quarrel_averted, node: id, label: @minions.fetch(id).name,
                               severity: :warning, tick: @ctx.tick, mode: mode,
                               detail: { minion: @minions.fetch(id).minion, place: @entry.fetch(id)[:place],
                                         by: boss, style: watch[:style] })
        resent(id, boss, INTIMIDATION_GRUDGE * (1.0 - grudge(id, boss))) if watch[:style] == :intimidation

        full = @dice.fetch(id).fetch(:patience)
        # TODO: an `intimidating` tag on the boss raises a stare-down's share, by the tag — first
        # caller is a boss's kit (the mace of discipline). No content carries it yet, so untested.
        boost = watch[:style] == :intimidation ? Injury.numeric(@minions.fetch(boss).tag(:intimidating)) : 0.0
        share = RELEASE.fetch(:averted) + (PUT_IN_LINE.fetch(watch[:style]) * (1.0 + boost))
        write(id, patience: [ share, 1.0 ].min * full, patience_full: full)
      end

      # --- patience -----------------------------------------------------------

      def temper(id)
        state = @entry.fetch(id)
        return unless able?(id) && !Animosity.fighting?(state) && !Animosity.fighting?(@out.fetch(id))
        return if piled_in?(id)

        minion = @minions.fetch(id)
        here = present(id)
        was = state.fetch(:patience, state.fetch(:patience_full, 1.0))
        full = state.fetch(:patience_full, 1.0)
        spent = wearing(id, here) * SPEND_PER_S * Animosity.temper(minion) * tired(state) * rumpus(id) * dt

        return mend(id, was, full) unless spent.positive?
        return write(id, patience: was - spent) if was - spent > 0.0

        act(id, here)
      end

      # **The worst of them, and the crowd**: the deepest grudge present, and a little for everybody
      # there. Two people one hates wear no faster than the worse of them; a crowd wears by its size.
      def wearing(id, here)
        worst = here.map { |other| grudge(id, other) }.max || 0.0
        worst + here.sum { |other| irritation(other) }
      end

      # Filling up ends an episode as running out does, so a long calm reveals nothing.
      def mend(id, was, full)
        patience = was + (MEND_PER_S * dt)
        return write(id, patience: [ patience, full ].min) unless patience >= full && was < full

        renewed = @dice.fetch(id).fetch(:patience)
        write(id, patience: renewed, patience_full: renewed)
      end

      def tired(state) = 1.0 + (SPENT_WEIGHT * (state.fetch(:fatigue, 0.0)**2))

      def rumpus(id)
        place = @entry.fetch(id)[:place]
        fighting = @entry.count { |other, s| other != id && Animosity.brawling?(s) && able?(other) && s[:place] == place }
        1.0 + (RUMPUS * Math.sqrt(fighting / 2.0))
      end

      def release(id, kind)
        full = @dice.fetch(id).fetch(:patience)
        write(id, patience: RELEASE.fetch(kind) * full, patience_full: full)
      end

      # --- piling in --------------------------------------------------------------

      # **Into a fight going on where they stand, their patience not yet run out** (§7.16 of the
      # sketch): spoiling for it, or at the end of their tether with somebody in it they hate. Read
      # off the fights as this tick's exchanges left them, so a fight just over draws nobody in.
      def piled_in?(id)
        minion = @minions.fetch(id)
        share = patience_share(id)
        spoiling = SPOILING * (Animosity.violence(minion).clamp(0.0, 1.0)**2)
        best = fights_at(@entry.fetch(id)[:place]).filter_map { |melee, standing|
          wanted = standing.max_by { |t| [ hostility(id, t), t.to_s ] }
          most = hostility(id, wanted)
          next unless most.positive?

          edge = share < EDGE ? ON_EDGE * most * (EDGE - share) / EDGE : 0.0
          [ melee, wanted, spoiling + edge ]
        }.max_by { |melee, _, rate| [ rate, melee.to_s ] }
        return false unless best && @dice.fetch(id).fetch(:join) < best.last * dt

        melee, wanted, = best
        if (watch = stepped_in(id))
          averted(id, watch, :pile_in)
          return true
        end

        clock = @out.fetch(wanted).dig(:fight, :clock_s)
        write(id, fight: { melee: melee, clock_s: clock, owed: {}.freeze }.freeze)
        write(id, patience: @entry.fetch(id).fetch(:patience, 1.0) * 0.5) if spoiling.positive?
        quarrel(id, wanted, :piled_in)
        true
      end

      # `{ melee => [members on their feet] }` in this place, as this tick has left them.
      def fights_at(place)
        @out.keys.sort.each_with_object({}) do |id, acc|
          melee = @out.fetch(id).dig(:fight, :melee) or next
          next unless @entry.fetch(id)[:place] == place && able?(id, @out.fetch(id))

          (acc[melee] ||= []) << id
        end
      end

      # --- the act ----------------------------------------------------------------

      def act(id, here)
        target = target_for(id, here)
        return release(id, :seethed) if target.nil?

        if (watch = stepped_in(id))
          return averted(id, watch, :quarrel)
        end

        choice = choose(id, target, here.include?(target))
        return release(id, :seethed) if choice.nil?

        perform(id, target, *choice)
      end

      # Anybody here or that their post reaches, by `Animosity.pick` on how much they resent each.
      # Somebody already in a fight is as good a pick as anybody: a brawl joins it, a row heckles.
      def target_for(id, here)
        reachable = openings(id).flat_map { |opening| @entry.keys.select { |t| t != id && reached?(opening, id, t) } }
        scored = (here | reachable).filter_map do |t|
          score = grudge(id, t) + (here.include?(t) ? irritation(t) : 0.0)
          [ t, score ] if score.positive?
        end
        Animosity.pick(scored, @dice.fetch(id).fetch(:target))
      end

      def openings(id) = @control_points[@entry.fetch(id)[:station]]&.openings || []

      def reached?(opening, id, target)
        @minions.key?(target) && opening.reaches?(@entry.fetch(target), @entry.fetch(id)[:place])
      end

      # `[kind, harm, bystanders, means]` for one of the acts they are willing to do, or nil.
      def choose(id, target, here)
        minion = @minions.fetch(id)
        state = @entry.fetch(id)
        held = grudge(id, target)
        # A bonehead takes it for harmless — the lever that squashes the git, and everybody with him.
        harmless = @dice.fetch(id).fetch(:judge) < minion.misjudges(state, ambient: @ambient.call(minion, state))

        willing = acts(id, target, here).select do |_, harm, bystanders, _|
          Animosity.willing?(minion, held, harm, bystanders, harmless: harmless)
        end
        return nil if willing.empty?

        willing[(@dice.fetch(id).fetch(:act) * willing.length).floor.clamp(0, willing.length - 1)]
      end

      def acts(id, target, here)
        found = []
        if here
          found << [ :row, 0.0, 0, nil ]
          found << [ :brawl, BRAWL_HARM, 0, nil ]
          state = @entry.fetch(target)
          @opportunities.each do |peril|
            next unless peril.applies_to?(@minions.fetch(target)) &&
                        peril.reaches?(state[:station], state[:place], state[:via] || state[:riding])

            found << [ :shove, peril.severity, 0, peril ]
          end
        end
        openings(id).each do |opening|
          next unless reached?(opening, id, target)

          caught = @entry.keys.count { |other| other != id && other != target && reached?(opening, id, other) }
          found << [ :sabotage, opening.harm, caught, opening ]
        end
        found
      end

      def perform(id, target, kind, harm, _bystanders, means)
        case kind
        when :row then row(id, target)
        when :brawl then brawl_with(id, target)
        else deed(id, target, kind, harm, means)
        end
      end

      # **A row stops them for `ROW_S`**, and the one they go for too — unless that one is already
      # in a fight, which a row from the sidelines does not stop: a heckle.
      def row(id, target)
        heckled = Animosity.fighting?(@out.fetch(target))
        write(id, fight: { with: target, clock_s: ROW_S }.freeze)
        write(target, fight: { with: id, clock_s: ROW_S }.freeze) unless heckled
        resent(target, id, ROW_GRIEVANCE)
        release(id, :row)
        quarrel(id, target, heckled ? :heckle : :row)
      end

      # **Into their fight, or a new one.** A brawl on somebody already in one joins it; on
      # somebody rowing, it ends their row.
      def brawl_with(id, target)
        theirs = @out.fetch(target)[:fight]
        if theirs&.fetch(:melee, nil)
          write(id, fight: { melee: theirs.fetch(:melee), clock_s: theirs.fetch(:clock_s), owed: {}.freeze }.freeze)
        else
          melee = :"#{id}@#{@ctx.tick}"
          [ id, target ].each { |who| write(who, fight: { melee: melee, clock_s: 0.0, owed: {}.freeze }.freeze) }
        end
        resent(target, id, BRAWL_HARM * GRUDGE_PER_HARM)
        write(id, patience: 0.0, patience_full: @dice.fetch(id).fetch(:patience))
        quarrel(id, target, theirs&.fetch(:melee, nil) ? :joined : :brawl)
      end

      # **A shove or sabotage is all or nothing**: the target saw it coming or did not. Seen,
      # nothing happens and they know who it was; unseen, the shove is the peril in full and the
      # sabotage is the machine's to finish — anonymously.
      def deed(id, target, kind, harm, means)
        minion = @minions.fetch(id)
        landed = Combat.succeeds?(Combat.rolled(minion.strike(@entry.fetch(id)), @dice.fetch(id).fetch(:attack)),
                                  Combat.rolled(defence_of(target), @dice.fetch(target).fetch(:defend)))
        quarrel(id, target, kind, cause: means.id, foiled: !landed)

        unless landed
          resent(target, id, harm * GRUDGE_PER_HARM)
          return release(id, :foiled)
        end

        if kind == :shove
          resent(target, id, harm * GRUDGE_PER_HARM)
          hurt(target, means.hazard, cause: means.id, attacker: id)
          @mishaps << means.mishap if means.mishap?
        elsif means.mishap
          @mishaps << means.mishap
        else
          @spite << { control: @entry.fetch(id)[:station], slip: means.slip }.freeze
        end
        release(id, kind)
      end

      # --- the fight ---------------------------------------------------------------

      # Each person's row runs on their own clock, so a heckle needs nobody else's.
      def rows
        @entry.keys.sort.each do |id|
          fought = @entry.fetch(id)[:fight]
          next if fought.nil? || fought[:melee]

          clock = fought.fetch(:clock_s) - dt
          write(id, fight: clock.positive? && able?(id) ? fought.merge(clock_s: clock).freeze : nil)
        end
      end

      # `{ melee => [members…] }`, by melee and by seat.
      def melees
        @entry.keys.sort.each_with_object({}) { |id, acc|
          melee = @entry.fetch(id).dig(:fight, :melee) or next
          (acc[melee] ||= []) << id
        }.sort_by { |melee, _| melee.to_s }.to_h
      end

      # **One exchange every `BOUT_S`, among everybody in the fight**, for as long as anybody in it
      # is willing (§7.2 of the sketch): still angry, with somebody there they hold hostility
      # against. The willing hit whoever they most want to; the spent hit back at whoever still
      # wants them; whoever is neither steps out. Somebody carried out stays, for anybody who hates
      # them enough to kick them; somebody dead, carried away or done in leaves.
      def brawl(members)
        place = @entry.fetch(members.first)[:place]
        staying, gone = members.partition { |id| staying?(id, place) }
        gone.each { |id| leave(id) }
        standing = staying.select { |id| able?(id) }
        downed = staying - standing
        willing = standing.select { |id| willing?(id, standing, downed) }
        return staying.each { |id| leave(id) } if willing.empty?

        clock = @entry.fetch(standing.first).dig(:fight, :clock_s) - dt
        return staying.each { |id| clocked(id, clock) } if clock.positive?

        if (pulled = parted(place, willing, staying))
          standing -= [ pulled ]
          willing -= [ pulled ]
          return staying.each { |id| leave(id) } if willing.empty?
        end

        exchange(standing, downed, willing)
        staying.each { |id| clocked(id, BOUT_S) if Animosity.brawling?(@out.fetch(id)) }
      end

      # In the fight's place, not dead, not done in, and nobody's cargo.
      def staying?(id, place)
        state = @entry.fetch(id)
        @minions.key?(id) && state[:place] == place && state[:injury] != :mortal && !state[:spent] &&
          !@carried.key?(id) && state[:via].nil? && state[:riding].nil?
      end

      def clocked(id, clock)
        write(id, fight: @out.fetch(id).fetch(:fight).merge(clock_s: clock).freeze)
      end

      # Who they could go for: anybody on their feet they hold hostility against, and anybody
      # carried out they hate enough to kick (`KICKING`).
      def pickable(id, standing, downed)
        minion = @minions.fetch(id)
        (standing - [ id ]).select { |t| hostility(id, t).positive? } +
          downed.select { |t| Animosity.ceiling(minion, grudge(id, t)) >= KICKING }
      end

      def willing?(id, standing, downed)
        state = @entry.fetch(id)
        state.fetch(:patience, 0.0) < SATED * state.fetch(:patience_full, 1.0) && pickable(id, standing, downed).any?
      end

      # **The boss pulls one of them out an exchange** — the angriest, on their own `avert:` die.
      def parted(place, willing, staying)
        watch = @overseers[place] or return nil
        return nil if staying.include?(watch[:boss])

        angriest = willing.min_by { |id| [ patience_share(id), id.to_s ] }
        return nil unless Animosity.averted?(watch[:effectiveness], watch[:wits], @dice.fetch(angriest).fetch(:avert))

        averted(angriest, watch, :brawl)
        leave(angriest)
        angriest
      end

      def patience_share(id)
        state = @entry.fetch(id)
        state.fetch(:patience, 0.0) / state.fetch(:patience_full, 1.0)
      end

      # **Everybody chooses at once, from the fight as the exchange began**; then each is defended
      # against by how many came at them, the blows land in seat order, and everybody standing is
      # relieved by what they did, what was done to them, and what they saw done.
      def exchange(standing, downed, willing)
        aims = standing.to_h { |id| [ id, aim(id, standing, downed, willing) ] }
        aims.each { |id, target| leave(id) if target.nil? }
        aims = aims.compact
        aims = aims.merge(dragged_in(aims.keys & willing, standing + downed))
        ganged = aims.values.tally
        @struck = []
        aims.each { |id, target| escalate(id, target, standing) }
        landed = aims.to_h { |id, target| [ id, blow(id, target, ganged.fetch(target)) ] }
        aims.each_key { |id| relieve(id, landed.fetch(id)) }
        (standing + downed).each { |id| leave(id) if @out.fetch(id)[:injury] == :mortal }
      end

      # **Turning on somebody watching** (§7.16): `{ fighter => bystander }` for each willing fighter
      # whose `drag:` die falls inside `DRAG_IN` times the square of their worst hostility towards
      # anybody standing there in no fight. Whom, by that die again, rescaled — uniform inside the
      # chance. The bystander is in the fight from this blow, and resents it as a brawl's target does.
      def dragged_in(fighters, members)
        melee = @entry.fetch(members.first).dig(:fight, :melee)
        place = @entry.fetch(members.first)[:place]
        near = @entry.keys.sort.select do |id|
          !members.include?(id) && @entry.fetch(id)[:place] == place && able?(id) &&
            !Animosity.brawling?(@entry.fetch(id)) && !Animosity.brawling?(@out.fetch(id))
        end
        fighters.sort.each_with_object({}) do |id, dragged|
          scored = near.filter_map { |b| (h = drag_hostility(id, b)).positive? && [ b, h ] }
          next if scored.empty?

          chance = DRAG_IN * (scored.map(&:last).max**2)
          die = @dice.fetch(id).fetch(:drag)
          next unless die < chance

          bystander = Animosity.pick(scored.map { |b, h| [ b, h**FOCUS ] }, die / chance)
          write(bystander, fight: { melee: melee, clock_s: BOUT_S, owed: {}.freeze }.freeze)
          resent(bystander, id, BRAWL_HARM * GRUDGE_PER_HARM)
          quarrel(id, bystander, :dragged)
          dragged[id] = bystander
        end
      end

      # A heckler is somebody to turn on whatever they hold against him.
      def drag_hostility(id, bystander)
        heckling = @entry.fetch(bystander).dig(:fight, :with) == id
        [ hostility(id, bystander), heckling ? HECKLED : 0.0 ].max
      end

      # **Who they hit**: the willing whoever they most want to, by hostility raised to `FOCUS`;
      # the spent whoever wants them most. Nil for somebody nobody wants and who wants nobody.
      def aim(id, standing, downed, willing)
        die = @dice.fetch(id).fetch(:target)
        return Animosity.pick(pickable(id, standing, downed).map { |t| [ t, hostility(id, t)**FOCUS ] }, die) if willing.include?(id)

        wanting = willing.select { |w| pickable(w, standing, downed).include?(id) }
        Animosity.pick(wanting.map { |w| [ w, hostility(w, id)**FOCUS ] }, die)
      end

      # **Everybody in it lets off steam**, blow by blow and more for what lands, far more once it
      # has hurt them (`HURT_RELIEF`), and for each injury they saw anybody else in it take, by
      # their grudge against them (`WITNESSED`). A tooth out gives anybody pause; an arm broken
      # leaves nobody wanting another fight.
      def relieve(id, landed)
        full = @entry.fetch(id).fetch(:patience_full, 1.0)
        own = (BOUT_RELEASE + (LANDED_RELEASE * landed)) * HURT_RELIEF.fetch(@out.fetch(id)[:injury], 1.0)
        seen = @struck.sum do |hurt, mode|
          hurt == id ? 0.0 : WITNESSED.fetch(mode, 0.0) * (WITNESS_BASE + grudge(id, hurt))
        end
        write(id, patience: [ @out.fetch(id).fetch(:patience, 0.0) + ((own + seen) * full), full ].min)
      end

      # Out of the fight, and what it did to them owed against whoever did it.
      def leave(id)
        fought = @out.fetch(id)[:fight] or return
        write(id, fight: nil)
        fought.fetch(:owed, {}).sort_by { |attacker, _| attacker.to_s }.each do |attacker, amount|
          resent(id, attacker, amount) if @minions.key?(attacker)
        end
      end

      # **Reaching for what is in their hand**, on their `escalate:` die against how willing to
      # kill the one they are going for they are, and far likelier once anybody in the fight who
      # wants them had a weapon out as the exchange began. Once drawn, it stays drawn.
      def escalate(id, target, standing)
        minion = @minions.fetch(id)
        fought = @out.fetch(id).fetch(:fight)
        return if minion.weapons.empty? || fought[:armed]

        threatened = standing.any? do |other|
          other != id && @entry.dig(other, :fight, :armed) == true && hostility(other, id).positive?
        end
        chance = Animosity.escalation(minion, grudge(id, target), threatened: threatened)
        return unless @dice.fetch(id).fetch(:escalate) < chance

        write(id, fight: fought.merge(armed: true).freeze)
        quarrel(id, target, :armed)
      end

      # **A blow, landing by how far the strike beat the defence** (`Minion#strike`: swing and
      # precision) **and hitting with whatever is in hand** (`Minion#wielding`: its handling read
      # off this body, plus its edge, by `Combat.blow_severity`), the one die reading both. **A
      # critical finds the gap**: it meets no resistance kit and only part of the target's
      # toughness. **A man on the ground gets the boot**, bare-handed, from anybody short of wanting
      # him dead. Returns the share that landed.
      def blow(from, to, ganged)
        minion = @minions.fetch(from)
        state = @entry.fetch(from)
        armed = @out.dig(from, :fight, :armed) == true &&
                (!Animosity.stood_down?(@entry.fetch(to)) || Animosity.ceiling(minion, grudge(from, to)) >= LETHAL)
        weapon = minion.wielding(state, armed: armed)
        die = @dice.fetch(from).fetch(:attack)
        strike = Combat.rolled(minion.strike(state), die)
        guard = guard(to, die, ganged)
        share = Combat.landed(strike, guard)
        return 0.0 unless share.positive?

        severity = Combat.blow_severity(minion.hits(state, weapon), weapon.fetch(:edge), die, share)
        pierces = Combat::CRITICAL_TOUGHNESS if Combat.critical?(strike, guard)
        hurt(to, { wounds: Wounds.dealt(weapon.fetch(:wounds), severity), pierces: pierces }.compact,
             cause: :brawl, attacker: from)
        share
      end

      def defence_of(id) = @defence.call(@minions.fetch(id), @entry.fetch(id))

      # **What they defend with against this one attacker**: their defence — `GROUNDED_GUARD` of it
      # lying down — divided by how many came at them this exchange (`GANGED`), on a die of their
      # own for this attack: their `defend:` and the attacker's `attack:` summed, so no one bad
      # moment lands every attacker at once.
      def guard(id, attacker_die, ganged)
        state = @entry.fetch(id)
        grounded = Animosity.stood_down?(state)
        # Carried out, every stat reads nothing; what they cover up with is what their wounds leave.
        defence = @defence.call(@minions.fetch(id), grounded ? state.merge(injury: nil) : state)
        defence *= GROUNDED_GUARD if grounded
        die = (@dice.fetch(id).fetch(:defend) + attacker_die) % 1.0
        Combat.rolled(defence / (1.0 + (GANGED * (ganged - 1))), die)
      end

      # --- what it leaves ----------------------------------------------------------

      # Every wound counts towards what the others in the fight saw, so a string of knocks can sate
      # them as surely as one bad blow.
      def hurt(id, hazard, cause:, attacker:)
        minion = @minions.fetch(id)
        after, mode, wounds = Injury.check(minion, @out.fetch(id), hazard, catalogue: @wounds, die: @wound_dice.fetch(id, 0.0))
        @out[id] = after
        return if mode.nil?

        @events << Event.build(type: :minion_hurt, node: id, label: minion.name, severity: :critical,
                               tick: @ctx.tick, mode: mode, cause: cause,
                               detail: { minion: minion.minion, lasting: Injury.lasting?(mode),
                                         place: after[:place], by: @minions.fetch(attacker).minion,
                                         wounds: Tick.reported(wounds, after) })
        return unless cause == :brawl

        wounded(id, mode, attacker)
        seen = wounds.map { |wound| wound.fetch(:tier) }
        (seen.empty? ? [ mode ] : seen).each { |tier| @struck << [ id, tier ] }
      end

      # **A fight is resented for what it did, once it is over**: a wound bad enough to carry them
      # out is owed against the one who dealt it, and nothing lighter is.
      def wounded(id, mode, attacker)
        owed = WOUND_GRUDGE.fetch(mode, 0.0)
        fought = @out.fetch(id)[:fight]
        return unless owed.positive? && fought

        debts = fought.fetch(:owed, {})
        write(id, fight: fought.merge(owed: debts.merge(attacker => debts.fetch(attacker, 0.0) + owed).freeze).freeze)
      end

      # **A wrong remembered**, by how much it hurt and how spiteful the one wronged is. Held for
      # the rest of the match on their state, and reported to outlast it.
      def resent(holder, target, raw)
        amount = raw * Animosity.spite(@minions.fetch(holder))
        return unless amount.positive?

        grudges = @out.fetch(holder).fetch(:grudges, {})
        held = grudges.fetch(target, 0.0)
        amount = [ amount, 1.0 - held ].min
        return unless amount.positive?

        write(holder, grudges: grudges.merge(target => held + amount).freeze)
        formed(holder, target, amount)
      end

      def formed(holder, target, amount)
        @events << Event.build(type: :grudge_formed, node: holder, label: @minions.fetch(holder).name,
                               severity: :info, tick: @ctx.tick,
                               detail: { holder: @minions.fetch(holder).minion, against: target,
                                         target: @minions.fetch(target).minion, amount: amount })
      end

      def quarrel(id, target, mode, cause: nil, foiled: false)
        minion = @minions.fetch(id)
        @events << Event.build(type: :quarrel, node: id, label: minion.name, severity: :warning,
                               tick: @ctx.tick, mode: mode, cause: cause,
                               detail: { minion: minion.minion, place: @entry.fetch(id)[:place],
                                         target: target, target_minion: @minions.fetch(target).minion,
                                         foiled: foiled })
      end
    end
  end
end
