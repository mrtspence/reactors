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
      def initialize(minions:, table:, control_points:, opportunities:, dice:, carried:, ctx:,
                     defence:, ambient:)
        @minions = minions
        @table = table
        @control_points = control_points
        @opportunities = opportunities
        @dice = dice
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

        @entry.keys.sort.each { |id| bout(id) if led?(@entry.fetch(id)) }
        @entry.keys.sort.each { |id| temper(id) }

        Result.new(minions: @out.transform_values(&:freeze).freeze, events: @events.freeze,
                   mishaps: @mishaps.freeze, spite: @spite.freeze)
      end

      private

      def dt = @ctx.dt

      def led?(state) = state.dig(:fight, :led) == true

      # Somebody who can quarrel: here, on their feet, nobody's cargo, not in a cage.
      def able?(id, state = @entry[id])
        !state.nil? && @minions.key?(id) && !Animosity.stood_down?(state) && !@carried.key?(id) &&
          state[:via].nil? && state[:riding].nil?
      end

      def present(id)
        place = @entry.fetch(id)[:place]
        @entry.keys.sort.select { |other| other != id && able?(other) && @entry.fetch(other)[:place] == place }
      end

      def grudge(holder, target) = Animosity.grudge(@table, holder, @out.fetch(holder), target)

      def irritation(other) = Animosity.irritation(@minions.fetch(other))

      def write(id, **changes) = @out[id] = @out.fetch(id).merge(changes)

      # --- the boss ---------------------------------------------------------

      # `{ place => { boss:, effectiveness:, wits:, style: } }`, the best boss over each place.
      def overseers
        @control_points.values.reject { |cp| cp.oversees.empty? }.sort_by(&:id).each_with_object({}) do |post, acc|
          boss = @entry.keys.sort.find { |id| @entry.fetch(id)[:station] == post.id && able?(id) && !Animosity.fighting?(@entry.fetch(id)) }
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

      # **Staring somebody down works, and is remembered.** Talking them round is not.
      def averted(id, watch, mode)
        @events << Event.build(type: :quarrel_averted, node: id, label: @minions.fetch(id).name,
                               severity: :warning, tick: @ctx.tick, mode: mode,
                               detail: { minion: @minions.fetch(id).minion, place: @entry.fetch(id)[:place],
                                         by: watch[:boss], style: watch[:style] })
        resent(id, watch[:boss], INTIMIDATION_GRUDGE) if watch[:style] == :intimidation
      end

      # --- patience -----------------------------------------------------------

      def temper(id)
        state = @entry.fetch(id)
        return unless able?(id) && !Animosity.fighting?(state) && !Animosity.fighting?(@out.fetch(id))

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
        brawls = @entry.count { |other, s| other != id && led?(s) && s.dig(:fight, :blows) && s[:place] == place }
        1.0 + (RUMPUS * brawls)
      end

      def release(id, kind)
        full = @dice.fetch(id).fetch(:patience)
        write(id, patience: RELEASE.fetch(kind) * full, patience_full: full)
      end

      # --- the act ----------------------------------------------------------------

      def act(id, here)
        target = target_for(id, here)
        return release(id, :seethed) if target.nil?

        if (watch = stepped_in(id))
          averted(id, watch, :quarrel)
          return release(id, :averted)
        end

        choice = choose(id, target, here.include?(target))
        return release(id, :seethed) if choice.nil?

        perform(id, target, *choice)
      end

      # Anybody here or that their post reaches, by `Animosity.pick` on how much they resent each —
      # **and nobody already in a fight**, so the one they hate most being busy turns them on
      # somebody else rather than leaving them stewing.
      def target_for(id, here)
        reachable = openings(id).flat_map { |opening| @entry.keys.select { |t| t != id && reached?(opening, id, t) } }
        candidates = (here | reachable).reject { |t| Animosity.fighting?(@out.fetch(t)) }
        scored = candidates.filter_map do |t|
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
          unless Animosity.fighting?(@out.fetch(target))
            found << [ :row, 0.0, 0, nil ]
            found << [ :brawl, BRAWL_HARM, 0, nil ]
          end
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
        when :row
          fight(id, target, blows: false, clock_s: ROW_S)
          resent(target, id, ROW_GRIEVANCE)
          release(id, :row)
          quarrel(id, target, :row)
        when :brawl
          fight(id, target, blows: true, clock_s: 0.0)
          resent(target, id, BRAWL_HARM * GRUDGE_PER_HARM)
          full = @dice.fetch(id).fetch(:patience)
          write(id, patience: 0.0, patience_full: full)
          quarrel(id, target, :brawl)
        else deed(id, target, kind, harm, means)
        end
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
          hurt(target, { severity: means.severity, tags: means.tags }, cause: means.id, attacker: id)
          @mishaps << means.mishap if means.mishap?
        elsif means.mishap
          @mishaps << means.mishap
        else
          @spite << { control: @entry.fetch(id)[:station], slip: means.slip }.freeze
        end
        release(id, kind)
      end

      # --- the fight ---------------------------------------------------------------

      def fight(id, target, blows:, clock_s:)
        write(id, fight: { with: target, blows: blows, led: true, clock_s: clock_s, owed: 0.0 }.freeze)
        write(target, fight: { with: id, blows: blows, led: false, clock_s: clock_s, owed: 0.0 }.freeze)
      end

      # One exchange every `BOUT_S`, both ways at once, until the one who started it is sated,
      # either of them is down or done in, or the boss gets between them.
      def bout(id)
        state = @entry.fetch(id)
        other = state.dig(:fight, :with)
        return finish(id, other) if over?(id, state, other)

        clock = state.dig(:fight, :clock_s) - dt
        return finish(id, other) if !state.dig(:fight, :blows) && clock <= 0.0
        return tick(id, clock) if clock.positive? || !state.dig(:fight, :blows)

        if (watch = stepped_in(id, other))
          averted(id, watch, :brawl)
          return finish(id, other)
        end

        escalate(id, other)
        escalate(other, id)
        landed = blow(id, other)
        relieve(other, blow(other, id))
        return finish(id, other) if relieve(id, landed) >= SATED * state.fetch(:patience_full, 1.0)

        tick(id, BOUT_S)
      end

      # **Both of them let off steam**, blow by blow and more for what lands, and far more once it
      # has hurt them (`HURT_RELIEF`): a tooth out gives anybody pause, and an arm broken leaves
      # nobody wanting another fight. Returns the new patience.
      def relieve(id, landed)
        full = @entry.fetch(id).fetch(:patience_full, 1.0)
        gain = (BOUT_RELEASE + (LANDED_RELEASE * landed)) * full * HURT_RELIEF.fetch(@out.fetch(id)[:injury], 1.0)
        patience = [ @out.fetch(id).fetch(:patience, 0.0) + gain, full ].min
        write(id, patience: patience)
        patience
      end

      def tick(id, clock)
        write(id, fight: @out.fetch(id).fetch(:fight).merge(clock_s: clock).freeze)
      end

      def over?(id, state, other)
        theirs = @entry[other]
        return true if theirs.nil? || theirs.dig(:fight, :with) != id
        return true unless able?(id) && able?(other)

        state[:spent] || theirs[:spent] || state[:place] != theirs[:place]
      end

      def finish(id, other)
        [ id, other ].compact.each do |who|
          fought = @out[who]&.fetch(:fight, nil) or next
          @out[who] = @out.fetch(who).merge(fight: nil)
          resent(who, fought.fetch(:with), fought.fetch(:owed, 0.0))
        end
      end

      # **Reaching for what is in their hand**, on their `escalate:` die against how willing to
      # kill they are, and far likelier once the other drew at an earlier exchange. Once drawn, it
      # stays drawn for the fight.
      def escalate(id, other)
        minion = @minions.fetch(id)
        fought = @out.fetch(id).fetch(:fight)
        return if minion.weapons.empty? || fought[:armed]

        threatened = @entry.dig(other, :fight, :armed) == true
        chance = Animosity.escalation(minion, grudge(id, other), threatened: threatened)
        return unless @dice.fetch(id).fetch(:escalate) < chance

        write(id, fight: fought.merge(armed: true).freeze)
        quarrel(id, other, :armed)
      end

      # **A blow, landing by how far the strike beat the defence** (`Minion#strike`: swing and
      # precision) **and hitting with whatever is in hand** (`Minion#wielding`: its handling read
      # off this body, plus its edge, by `Combat.blow_severity`), the one die reading both. **A
      # critical finds the gap**: it meets no resistance kit and only part of the target's
      # toughness. Returns the share that landed.
      def blow(from, to)
        minion = @minions.fetch(from)
        state = @entry.fetch(from)
        weapon = minion.wielding(state, armed: @out.dig(from, :fight, :armed) == true)
        die = @dice.fetch(from).fetch(:attack)
        strike = Combat.rolled(minion.strike(state), die)
        guard = Combat.rolled(defence_of(to), @dice.fetch(to).fetch(:defend))
        share = Combat.landed(strike, guard)
        return 0.0 unless share.positive?

        severity = Combat.blow_severity(minion.hits(state, weapon), weapon.fetch(:edge), die, share)
        pierces = Combat::CRITICAL_TOUGHNESS if Combat.critical?(strike, guard)
        hurt(to, { severity: severity, tags: weapon.fetch(:wounds), pierces: pierces }.compact,
             cause: :brawl, attacker: from)
        share
      end

      def defence_of(id) = @defence.call(@minions.fetch(id), @entry.fetch(id))

      # --- what it leaves ----------------------------------------------------------

      def hurt(id, hazard, cause:, attacker:)
        minion = @minions.fetch(id)
        after, mode = Injury.check(minion, @out.fetch(id), hazard)
        @out[id] = after
        return if mode.nil?

        @events << Event.build(type: :minion_hurt, node: id, label: minion.name, severity: :critical,
                               tick: @ctx.tick, mode: mode, cause: cause,
                               detail: { minion: minion.minion, lasting: Injury.lasting?(mode),
                                         place: after[:place], by: @minions.fetch(attacker).minion })
        wounded(id, mode) if cause == :brawl
      end

      # **A fight is resented for what it did, once it is over**: a wound bad enough to carry them
      # out is owed against the one who dealt it, and nothing lighter is.
      def wounded(id, mode)
        owed = WOUND_GRUDGE.fetch(mode, 0.0)
        fought = @out.fetch(id)[:fight]
        return unless owed.positive? && fought

        write(id, fight: fought.merge(owed: fought.fetch(:owed, 0.0) + owed).freeze)
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
