# frozen_string_literal: true

# **Every crew member against every other, in brawls**, through the real tick and phase 6d′: who
# lands, how hard, when the weapons come out, and who is carried out or killed.
#
#   ruby script/tuning/brawls.rb                       # 100 brawls a pairing, everybody armed
#   ruby script/tuning/brawls.rb --brawls 300 --tool none --only jim,dalthu,elowynne
#   ruby script/tuning/brawls.rb --out tmp/brawls.md
#   ruby script/tuning/brawls.rb --tag callous=0 --tag rijgazh.violent_nature=0.6
#
# Run from anywhere: it loads the simulation from this checkout and writes, by default, to
# `docs/tuning/brawls.md` in it, saying the full path it wrote.
#
# Deterministic: the same code gives the same report, so a tuning pass is a diff of
# `docs/tuning/brawls.md`. Each brawl is one operation, seeded by its number, holding the two in one
# lit room with whatever kit `--tool` gives them; it starts as a brawl does (the starter's patience
# spent, the target holding the grievance the first push leaves), and runs until the fight ends.
#
# The exchange-level figures come from instrumenting `Animosity::Provoke` and `Combat` from here, so nothing in
# the simulation exists for this script. If a method it wraps is renamed, it fails loudly.
ROOT = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

require "fileutils"
require "optparse"
require "reactor_sim"

module BrawlMatrix
  ROOM = :yard
  LIGHT = 1.0
  MAX_TICKS = 2_400 # ten minutes: a fight longer than that is a finding, reported as a timeout
  ENDINGS = %i[sated target_down starter_down both_down spent].freeze
  SEATS = %i[a b].freeze
  OFF_SHIFT = %i[severe mortal].freeze

  Options = Struct.new(:brawls, :tool, :out, :only, :set, :armed, :tags, keyword_init: true)

  # `--tag` with no person before the dot is everybody's.
  EVERYBODY = :all

  # **A figure tried for one pass without editing the simulation**: `--set CRITICAL_AT=5` replaces
  # `Combat::CRITICAL_AT` for this run, and the report's figures table shows what was run.
  TUNABLE = [ ReactorSim::Combat, ReactorSim::Animosity, ReactorSim::Injury ].freeze

  def self.override!(name, value)
    owner = TUNABLE.find { |mod| mod.const_defined?(name, false) } or
      raise ArgumentError, "no constant #{name} on #{TUNABLE.map(&:name).join(', ')}"

    owner.send(:remove_const, name)
    owner.const_set(name, value)
  end

  # Every blow, as the phase threw it.
  module Recorder
    def blow(from, to, *)
      record = { from: from, to: to, armed: @out.dig(from, :fight, :armed) == true }
      Thread.current[:brawl_blow] = record
      share = super
      record[:share] = share
      (Thread.current[:brawl_log] ||= []) << record
      share
    ensure
      Thread.current[:brawl_blow] = nil
    end

    def hurt(id, hazard, cause:, attacker:)
      if (record = Thread.current[:brawl_blow]) && cause == :brawl
        dealt = hazard.fetch(:wounds)
        total = dealt.values.sum
        record[:severity] = total
        record[:bite] = dealt.sum do |kind, severity|
          severity - ReactorSim::Injury.resisted(@minions.fetch(id), hazard, kind, severity / total)
        end
      end
      super
    end
  end

  module Landing
    def landed(attack, defend)
      if (record = Thread.current[:brawl_blow])
        record[:margin] = defend.positive? ? attack / defend : Float::INFINITY
      end
      super
    end
  end

  module_function

  def run(options)
    options.set.each { |name, value| override!(name, value) }
    ReactorSim::Animosity::Provoke.prepend(Recorder)
    ReactorSim::Combat.singleton_class.prepend(Landing)
    content = ReactorSim::Content.default
    cast = options.only || content.minions.keys.sort
    results = cast.product(cast).to_h do |starter, target|
      [ [ starter, target ], (1..options.brawls).map { |n| brawl(starter, target, n, options, content) } ]
    end
    report(results, cast, options, content)
  end

  def person(seat, id, options, content)
    posting = { minion: id }
    posting[ReactorSim::Equipment.fetch(options.tool).slot] = options.tool if options.tool
    sheet = ReactorSim::Crew.resolve(posting, content: content)
    tags = sheet.fetch(:tags).merge(options.tags.fetch(EVERYBODY, {})).merge(options.tags.fetch(id, {}))
    ReactorSim::Minion.new(id: seat, place: ROOM, name: sheet.fetch(:name), minion: sheet.fetch(:minion),
                           archetype: sheet.fetch(:archetype), stats: sheet.fetch(:stats), tags: tags,
                           mass_kg: sheet.fetch(:mass_kg), worn_kg: sheet.fetch(:worn_kg), weapons: sheet.fetch(:weapons),
                           grudges: sheet.fetch(:grudges), resented_by: sheet.fetch(:resented_by))
  end

  # A lit room with air in it, and nothing else.
  def room
    lamp = Class.new(ReactorSim::Nodes::Vessel) do
      def ambient_tags(_state, _levers) = { darkvision: BrawlMatrix::LIGHT }
    end
    lamp.new(id: :room, label: "Room", volume_m3: 50.0, heat_capacity: 1.0e4,
             ports: [ ReactorSim::Port.new(id: :vent, direction: :inlet, accepts: [ :gas ]) ],
             initial_contents: [ { resource: :air, kg: 60.0 } ])
  end

  def operation(crew, seed, content, state: nil, rngs: nil)
    ReactorSim::Operation.new(id: :brawl, type: :tuning, seed: seed, content: content, state: state, rngs: rngs,
                              nodes: [ room ], places: [ ReactorSim::Place.new(id: ROOM, nodes: %i[room]) ],
                              minions: crew)
  end

  # From the moment it starts, as `Provoke#perform` starts one — or, `--armed`, with both weapons
  # already out, so what they do is measured rather than how often they are drawn.
  def brawl(starter, target, seed, options, content)
    crew = [ person(:a, starter, options, content), person(:b, target, options, content) ]
    fresh = operation(crew, seed, content)
    minions = fresh.state.fetch(:minions)
    grievance = ReactorSim::Animosity::BRAWL_HARM * ReactorSim::Animosity::GRUDGE_PER_HARM *
                ReactorSim::Animosity.spite(crew.last)
    fight = { melee: :brawl, clock_s: 0.0, owed: {} }
    fight = fight.merge(armed: true) if options.armed
    started = fresh.state.merge(minions: minions.merge(
      a: minions.fetch(:a).merge(patience: 0.0, fight: fight),
      b: minions.fetch(:b).merge(grudges: { a: grievance }, fight: fight)
    ))
    op = operation(crew, seed, content, state: started, rngs: fresh.rngs)

    Thread.current[:brawl_log] = []
    events = []
    tick = 0
    while SEATS.any? { |id| op.state.dig(:minions, id, :fight) } && tick < MAX_TICKS
      tick += 1
      events.concat(op.step!(tick: tick).map { |e| e.merge(at: Thread.current[:brawl_log].length / 2) })
    end
    outcome(op, Thread.current[:brawl_log], events, tick, armed: options.armed)
  end

  # Started armed, both drew before the first exchange.
  def outcome(op, blows, events, ticks, armed: false)
    states = op.state.fetch(:minions)
    ended = ending(states, ticks)
    # `at` is the exchanges thrown by the end of the tick it was drawn on — its own included.
    drew = events.select { |e| e[:type] == :quarrel && e[:mode] == :armed }.to_h { |e| [ e[:node], e[:at] ] }
    drew = { a: 0, b: 0 } if armed
    { exchanges: blows.length / 2, seconds: ticks * ReactorSim::DT, ended: ended,
      a: side(blows, :a, states.fetch(:b), drew[:a]).merge(fatigue: states.dig(:a, :fatigue)),
      b: side(blows, :b, states.fetch(:a), drew[:b]).merge(fatigue: states.dig(:b, :fatigue)) }
  end

  def ending(states, ticks)
    down = ->(id) { !ReactorSim::Injury::MODES.dig(states.dig(id, :injury), :stood_down).nil? }
    return :timeout if ticks >= MAX_TICKS
    return :both_down if down.(:a) && down.(:b)
    return :target_down if down.(:b)
    return :starter_down if down.(:a)
    return :spent if states.dig(:a, :spent) || states.dig(:b, :spent)

    :sated
  end

  # What one fighter did, and what it did to the other.
  def side(blows, id, victim, drew_at)
    mine = blows.select { |b| b[:from] == id }
    landed = mine.select { |b| b[:share].to_f.positive? }
    { thrown: mine.length, landed: landed.length, clean: landed.count { |b| b[:share] >= 1.0 },
      critical: landed.count { |b| b[:margin].to_f >= ReactorSim::Combat::CRITICAL_AT },
      margins: mine.filter_map { |b| b[:margin] if b[:margin]&.finite? },
      severities: landed.filter_map { |b| b[:severity] }, bites: landed.filter_map { |b| b[:bite] },
      armed_blows: mine.count { |b| b[:armed] }, drew_at: drew_at, inflicted: victim[:injury] }
  end

  # --- the report ----------------------------------------------------------------------------

  def pct(part, whole) = whole.zero? ? "—" : format("%.0f%%", 100.0 * part / whole)

  def median(values)
    return nil if values.empty?

    sorted = values.sort
    mid = sorted.length / 2
    sorted.length.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
  end

  def num(value, digits = 2) = value.nil? ? "—" : format("%.#{digits}f", value)

  def mean(values) = values.empty? ? nil : values.sum / values.length.to_f

  def label(id, content) = "#{content.sheet(id).fetch(:name)} (#{content.sheet(id).fetch(:archetype)})"

  def short(id, content) = content.sheet(id).fetch(:name).split.first

  TEMPERAMENT = %i[short_tempered even_tempered callous kindly violent_nature gentle reckless conscientious
                   spiteful forgiving annoying calming].freeze

  def temperament(minion)
    held = TEMPERAMENT.filter_map do |tag|
      value = ReactorSim::Injury.numeric(minion.tag(tag))
      "#{tag} #{num(value, 1)}" if value.positive?
    end
    held.empty? ? "—" : held.join(", ")
  end

  def report(results, cast, options, content)
    animosity = ReactorSim::Animosity
    lines = []
    lines << "# Brawl matrix"
    lines << ""
    lines << "Generated by `ruby script/tuning/brawls.rb#{argv_echo(options)}`. Each cell is " \
             "#{options.brawls} brawls between the row (who started it) and the column, in a lit room, " \
             "each carrying #{options.tool ? "`#{options.tool}`" : 'nothing'}" \
             "#{options.armed ? ', both armed from the first blow' : ', drawn only on the escalation dice'}."
    lines << ""
    lines << "| Figure | Value |"
    lines << "|---|---|"
    combat = ReactorSim::Combat
    { "CONTEST_SPREAD" => combat::CONTEST_SPREAD, "DAMAGE_SPREAD" => combat::DAMAGE_SPREAD,
      "BLOW" => combat::BLOW, "FULL_AT" => combat::FULL_AT,
      "CRITICAL_AT" => combat::CRITICAL_AT, "CRITICAL_TOUGHNESS" => combat::CRITICAL_TOUGHNESS,
      "ESCALATION" => animosity::ESCALATION, "ESCALATION_POWER" => animosity::ESCALATION_POWER,
      "ANSWER" => animosity::ANSWER, "GRUDGE_HARDENS" => animosity::GRUDGE_HARDENS,
      "VIOLENCE_HOSTILITY" => animosity::VIOLENCE_HOSTILITY,
      "WOUND_GRUDGE" => animosity::WOUND_GRUDGE.map { |mode, g| "#{mode} #{g}" }.join(", "),
      "BOUT_S" => animosity::BOUT_S, "SATED" => animosity::SATED,
      "WITNESSED" => animosity::WITNESSED.map { |mode, w| "#{mode} #{w}" }.join(", "),
      "KICKING" => animosity::KICKING, "GROUNDED_GUARD" => animosity::GROUNDED_GUARD,
      "MORTAL_BITE" => ReactorSim::Injury::MORTAL_BITE, "OUTRIGHT" => ReactorSim::Injury::OUTRIGHT,
      "DEATH_SHARE" => ReactorSim::Injury::DEATH_SHARE }
      .each { |name, value| lines << "| `#{name}` | #{value} |" }
    lines << ""
    lines << "**The cast.** Strike decides whether a blow lands, against defence; a blow's weight is " \
             "the weapon's handling read off the body, plus the weapon's edge. All are the unrolled " \
             "figures the dice stretch; what each holds against the others before anything happens " \
             "is the last column, with the chance each exchange that they draw on them unprovoked; " \
             "a stranger is anybody they hold nothing against."
    lines << ""
    lines << "| Who | Temperament | Swing / precision | Strike | Blow: fists / armed (+ edge) | Defence | Toughness | Wounds | " \
             "Holds against (draws per exchange) | Draws on a stranger |"
    lines << "|---|---|---|---|---|---|---|---|---|---|"
    state = { health: 1.0, fatigue: 0.0 }
    held = animosity.table(cast.map { |id| person(id, id, options, content) })
    cast.each do |id|
      m = person(:x, id, options, content)
      weapon = m.wielding(state, armed: true)
      armed = m.weapons.any? ? "#{num(m.hits(state, weapon))} (+#{num(weapon.fetch(:edge))})" : "—"
      grudges = held.fetch(id, {}).map do |t, g|
        "#{short(t, content)} #{num(g)} (#{format('%.1f%%', 100.0 * animosity.escalation(m, g))})"
      end.join(", ")
      lines << "| #{label(id, content)} | #{temperament(m)} | #{num(m.swing(state))} / #{num(m.precision(state))} | " \
               "#{num(m.strike(state))} | #{num(m.attack(state))} / #{armed} | " \
               "#{num(m.defend(state, ambient: { darkvision: LIGHT }))} | #{num(m.toughness)} | " \
               "#{weapon.fetch(:wounds).map { |kind, share| "#{kind} #{num(share)}" }.join(', ')} | " \
               "#{grudges.empty? ? '—' : grudges} | " \
               "#{format('%.1f%%', 100.0 * animosity.escalation(m, 0.0))} |"
    end
    lines << ""

    # `inflicted` is what that side did to the other: the starter's is the target's injury.
    matrix(lines, results, cast, content, "Target killed: by fists / once the starter drew (starter drew)",
           "Row starts it. A death is the target on the injury list; the bracket is how often the starter drew.") do |runs|
      killed = runs.select { |r| r[:a][:inflicted] == :mortal }
      "#{pct(killed.count { |r| r[:a][:drew_at].nil? }, runs.length)} / " \
        "#{pct(killed.count { |r| r[:a][:drew_at] }, runs.length)} " \
        "(#{pct(runs.count { |r| r[:a][:drew_at] }, runs.length)})"
    end
    matrix(lines, results, cast, content, "Drew: starter / target",
           "How often each side had a weapon out by the end, in brawls where they had one to draw.") do |runs|
      "#{pct(runs.count { |r| r[:a][:drew_at] }, runs.length)} / #{pct(runs.count { |r| r[:b][:drew_at] }, runs.length)}"
    end
    matrix(lines, results, cast, content, "Target carried out or killed",
           "Severe or mortal: the brawl took them off the shift.") do |runs|
      pct(runs.count { |r| OFF_SHIFT.include?(r[:a][:inflicted]) }, runs.length)
    end
    matrix(lines, results, cast, content, "Starter hurt / killed",
           "What starting it cost the one who did: any injury, then deaths.") do |runs|
      "#{pct(runs.count { |r| r[:b][:inflicted] }, runs.length)} / " \
        "#{pct(runs.count { |r| r[:b][:inflicted] == :mortal }, runs.length)}"
    end
    matrix(lines, results, cast, content, "Starter's blows landed / clean / critical",
           "Of every blow the starter threw; clean is full strength (margin ≥ `FULL_AT`), " \
           "critical meets no resistance kit and `CRITICAL_TOUGHNESS` of the target's toughness " \
           "(margin ≥ `CRITICAL_AT`).") do |runs|
      thrown = runs.sum { |r| r[:a][:thrown] }
      "#{pct(runs.sum { |r| r[:a][:landed] }, thrown)} / #{pct(runs.sum { |r| r[:a][:clean] }, thrown)} / " \
        "#{pct(runs.sum { |r| r[:a][:critical] }, thrown)}"
    end

    detail(lines, results, content)
    out = File.expand_path(options.out)
    FileUtils.mkdir_p(File.dirname(out))
    File.write(out, "#{lines.join("\n")}\n")
    puts "wrote #{out}"
  end

  def matrix(lines, results, cast, content, title, note)
    lines << "## #{title}"
    lines << ""
    lines << note
    lines << ""
    lines << "| Starter ↓ / target → | #{cast.map { |id| short(id, content) }.join(' | ')} |"
    lines << "|---|#{cast.map { '---' }.join('|')}|"
    cast.each do |starter|
      lines << "| **#{short(starter, content)}** | #{cast.map { |target| yield(results.fetch([ starter, target ])) }.join(' | ')} |"
    end
    lines << ""
  end

  def detail(lines, results, content)
    lines << "## Every pairing"
    lines << ""
    lines << "Margin is strike ÷ defence as rolled (a blow lands above 1); severity is of landed blows; " \
             "bite is severity past the defender's resistance (positive hurts, ≥ `MORTAL_BITE` kills). " \
             "Drew is how often, and at which exchange on average; fatigue is where they ended it."
    lines << ""
    lines << "| Starter | Target | Exch. | Ended: sated / target down / starter down / both down / spent | " \
             "Starter: landed, clean, crit, median margin, mean sev., max bite, drew @, fatigue | " \
             "Target: landed, clean, crit, median margin, mean sev., max bite, drew @, fatigue | " \
             "Target minor / significant / severe / dead | Starter minor / significant / severe / dead |"
    lines << "|---|---|---|---|---|---|---|---|"
    results.each do |(starter, target), runs|
      ended = ENDINGS.map { |e| pct(runs.count { |r| r[:ended] == e }, runs.length) }
      timeouts = runs.count { |r| r[:ended] == :timeout }
      ended_text = ended.join(" / ") + (timeouts.positive? ? " (#{timeouts} timed out)" : "")
      lines << "| #{short(starter, content)} | #{short(target, content)} | #{num(mean(runs.map { |r| r[:exchanges] }), 1)} | " \
               "#{ended_text} | #{fighter(runs, :a)} | #{fighter(runs, :b)} | " \
               "#{injuries(runs, :b)} | #{injuries(runs, :a)} |"
    end
    lines << ""
  end

  def fighter(runs, side)
    sides = runs.map { |r| r.fetch(side) }
    thrown = sides.sum { |s| s[:thrown] }
    drew = sides.filter_map { |s| s[:drew_at] }
    drew_text = drew.empty? ? "never" : "#{pct(drew.length, runs.length)} @ #{num(mean(drew), 1)}"
    [ pct(sides.sum { |s| s[:landed] }, thrown), pct(sides.sum { |s| s[:clean] }, thrown),
      pct(sides.sum { |s| s[:critical] }, thrown),
      num(median(sides.flat_map { |s| s[:margins] })), num(mean(sides.flat_map { |s| s[:severities] })),
      num(sides.flat_map { |s| s[:bites] }.max), drew_text,
      num(mean(sides.map { |s| s[:fatigue].to_f })) ].join(", ")
  end

  # What was done TO this side: the other side's `inflicted`.
  def injuries(runs, side)
    other = side == :a ? :b : :a
    ReactorSim::Injury::ORDER.map { |mode| pct(runs.count { |r| r.fetch(other)[:inflicted] == mode }, runs.length) }.join(" / ")
  end

  def argv_echo(options)
    parts = []
    parts << " --brawls #{options.brawls}" unless options.brawls == 100
    parts << " --tool #{options.tool || 'none'}" unless options.tool == :miners_tools
    parts << " --only #{options.only.join(',')}" if options.only
    parts << " --armed" if options.armed
    options.set.each { |name, value| parts << " --set #{name}=#{value}" }
    options.tags.each do |who, tags|
      tags.each { |tag, value| parts << " --tag #{who == EVERYBODY ? '' : "#{who}."}#{tag}=#{value}" }
    end
    parts.join
  end

  def parse(argv)
    options = Options.new(brawls: 100, tool: :miners_tools, out: File.join(ROOT, "docs/tuning/brawls.md"),
                          only: nil, set: {}, armed: false, tags: {})
    OptionParser.new do |o|
      o.on("--armed", "start every brawl with both weapons out") { options.armed = true }
      o.on("--brawls N", Integer, "brawls per pairing (100)") { |n| options.brawls = n }
      o.on("--tool ID", "the one item everybody carries, in its own slot, or none (miners_tools)") do |t|
        options.tool = t == "none" ? nil : t.to_sym
      end
      o.on("--out PATH", "where the report goes (docs/tuning/brawls.md)") { |p| options.out = p }
      o.on("--only IDS", "a comma-separated cast instead of everybody") { |ids| options.only = ids.split(",").map(&:to_sym) }
      o.on("--set NAME=VALUE", "try a figure on Combat, Animosity or Injury for this pass; repeatable") do |pair|
        name, value = pair.split("=", 2)
        options.set[name.to_sym] = Float(value)
      end
      o.on("--tag [ID.]TAG=VALUE", "set a tag on everybody, or on one person, for this pass; repeatable") do |pair|
        key, value = pair.split("=", 2)
        who, tag = key.include?(".") ? key.split(".", 2) : [ EVERYBODY, key ]
        (options.tags[who.to_sym] ||= {})[tag.to_sym] = Float(value)
      end
    end.parse!(argv)
    options
  end
end

BrawlMatrix.run(BrawlMatrix.parse(ARGV)) if $PROGRAM_NAME == __FILE__
