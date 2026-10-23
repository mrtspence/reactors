# frozen_string_literal: true

# **Crowds of people in one place for a shift**, through the real tick: how often patience runs
# out, what it comes to, how much of the room is fighting at once, what a boss over the place
# stops, and what somebody does when the one they most resent is already in a fight.
#
#   ruby script/tuning/crowds.rb                          # every scenario, 3 seeds of an hour each
#   ruby script/tuning/crowds.rb --only bosses --minutes 120 --seeds 5
#   ruby script/tuning/crowds.rb --set IRRITATION=0.04 --out tmp/crowds.md
#
# Run from anywhere: it loads the simulation from this checkout and writes, by default, to
# `docs/tuning/crowds.md` in it. Deterministic, so a tuning pass is a diff.
#
# Everybody stands in one lit room carrying miner's tools, nobody working, and starts with full
# patience; a boss, where there is one, is posted to a post overseeing the room. Nobody carried out
# is revived during the shift. What the phase decided is read from instrumenting
# `Animosity::Provoke` from here, so nothing in the simulation exists for this script.
ROOT = File.expand_path("../..", __dir__)
$LOAD_PATH.unshift(File.join(ROOT, "lib"))

require "fileutils"
require "optparse"
require "reactor_sim"

module CrowdTuning
  ROOM = :yard
  BOSS_POST = :bossing
  TOOL = :miners_tools

  # The colliery's mix, in the order a crowd of N takes its first N from (and round again).
  GANG = %i[jim elowynne urist dalthu rijgazh throg galathas kobold_temp].freeze

  Scenario = Struct.new(:group, :name, :cast, :tags, :boss, keyword_init: true)
  Options = Struct.new(:minutes, :seeds, :only, :sizes, :out, :set, keyword_init: true)

  SIZES = [ 2, 4, 8, 16, 32 ].freeze
  BOSSES = [ nil, :throg, :dalthu, :elowynne, :rijgazh, :arunessa ].freeze

  def self.scenarios(sizes = SIZES)
    crowd = sizes.flat_map do |n|
      humans = Array.new(n, :jim)
      quarter = (n / 4.0).ceil
      [ Scenario.new(group: :crowds, name: "#{n} humans", cast: humans),
        Scenario.new(group: :crowds, name: "#{n} humans, #{quarter} annoying 0.6", cast: humans,
                     tags: (0...quarter).to_h { |i| [ i, { annoying: 0.6 } ] }),
        Scenario.new(group: :crowds, name: "#{n} humans, all calming 0.3", cast: humans,
                     tags: (0...n).to_h { |i| [ i, { calming: 0.3 } ] }),
        Scenario.new(group: :crowds, name: "#{n} of the gang", cast: Array.new(n) { |i| GANG[i % GANG.length] }) ]
    end
    bosses = ([ 8, 16 ] & sizes).flat_map do |n|
      cast = Array.new(n) { |i| GANG[i % GANG.length] }
      BOSSES.map do |boss|
        Scenario.new(group: :bosses, name: "#{n} of the gang, #{boss ? "#{boss} over them" : 'no boss'}",
                     cast: cast, boss: boss)
      end
    end
    crowd + bosses
  end

  TUNABLE = [ ReactorSim::Combat, ReactorSim::Animosity, ReactorSim::Injury ].freeze

  def self.override!(name, value)
    owner = TUNABLE.find { |mod| mod.const_defined?(name, false) } or
      raise ArgumentError, "no constant #{name} on #{TUNABLE.map(&:name).join(', ')}"

    owner.send(:remove_const, name)
    owner.const_set(name, value)
  end

  # What each running-out came to, and whether the one they most resented of everybody there was
  # already fighting.
  module Watch
    def act(id, here)
      top = here.max_by { |t| [ grudge(id, t) + irritation(t), t.to_s ] }
      busy = !top.nil? && ReactorSim::Animosity.fighting?(@out.fetch(top))
      before = @events.length
      super
      mine = @events[before..].select { |e| e[:node] == id }
      (Thread.current[:crowd_acts] ||= []) << { busy: busy, came_to: came_to(mine) }
    end

    def came_to(mine)
      quarrel = mine.find { |e| e[:type] == :quarrel }
      return quarrel[:mode] if quarrel

      mine.any? { |e| e[:type] == :quarrel_averted } ? :averted : :seethed
    end
  end

  module_function

  def run(options)
    options.set.each { |name, value| override!(name, value) }
    ReactorSim::Animosity::Provoke.prepend(Watch)
    content = ReactorSim::Content.default
    chosen = scenarios(options.sizes).select { |s| options.only.nil? || options.only.include?(s.group) }
    results = chosen.map do |scenario|
      runs = (1..options.seeds).map { |seed| shift(scenario, seed, options, content) }
      warn "  #{scenario.name}"
      [ scenario, runs ]
    end
    report(results, options)
  end

  def person(seat, id, content, tags: {}, station: nil)
    sheet = ReactorSim::Crew.resolve({ minion: id, ReactorSim::Equipment.fetch(TOOL).slot => TOOL }, content: content)
    ReactorSim::Minion.new(id: seat, place: ROOM, station: station, name: sheet.fetch(:name),
                           minion: sheet.fetch(:minion), archetype: sheet.fetch(:archetype),
                           stats: sheet.fetch(:stats), tags: sheet.fetch(:tags).merge(tags),
                           mass_kg: sheet.fetch(:mass_kg), worn_kg: sheet.fetch(:worn_kg),
                           weapons: sheet.fetch(:weapons), grudges: sheet.fetch(:grudges),
                           resented_by: sheet.fetch(:resented_by))
  end

  def crew(scenario, content)
    people = scenario.cast.each_with_index.map do |id, i|
      person(:"p#{format('%02d', i)}", id, content, tags: (scenario.tags || {}).fetch(i, {}))
    end
    people << person(:boss, scenario.boss, content, station: BOSS_POST) if scenario.boss
    people
  end

  def room
    lamp = Class.new(ReactorSim::Nodes::Vessel) do
      def ambient_tags(_state, _levers) = { darkvision: 1.0 }
    end
    lamp.new(id: :room, label: "Room", volume_m3: 500.0, heat_capacity: 1.0e5,
             ports: [ ReactorSim::Port.new(id: :vent, direction: :inlet, accepts: [ :gas ]) ],
             initial_contents: [ { resource: :air, kg: 600.0 } ])
  end

  def boss_post
    ReactorSim::ControlPoint.new(id: BOSS_POST, place: ROOM, effort: { charisma: 1.0 }, default: 100.0,
                                 capacity: 1, oversees: [ ROOM ])
  end

  def shift(scenario, seed, options, content)
    people = crew(scenario, content)
    op = ReactorSim::Operation.new(id: :crowd, type: :tuning, seed: seed, content: content,
                                   nodes: [ room ], places: [ ReactorSim::Place.new(id: ROOM, nodes: %i[room]) ],
                                   control_points: scenario.boss ? [ boss_post ] : [], minions: people)
    Thread.current[:crowd_acts] = []
    ticks = (options.minutes * 60.0 / ReactorSim::DT).round
    events = []
    fighting_ticks = 0
    fighting_share = 0.0
    peak = 0
    first = nil
    half_down = nil
    ticks.times do |t|
      events.concat(op.step!(tick: t + 1))
      states = op.state.fetch(:minions)
      brawls = states.count { |_, s| s.dig(:fight, :led) && s.dig(:fight, :blows) }
      first ||= (t + 1) * ReactorSim::DT if events.any? { |e| e[:type] == :quarrel }
      half_down ||= (t + 1) * ReactorSim::DT if states.count { |_, s| ReactorSim::Animosity.stood_down?(s) } * 2 >= states.length
      next unless brawls.positive?

      fighting_ticks += 1
      fighting_share += 2.0 * brawls / states.length
      peak = [ peak, brawls ].max
    end
    states = op.state.fetch(:minions)
    { ticks: ticks, heads: people.length, events: events, acts: Thread.current[:crowd_acts],
      fighting_ticks: fighting_ticks, fighting_share: fighting_share, peak: peak, first_s: first,
      half_down_s: half_down, down: states.count { |_, s| ReactorSim::Animosity.stood_down?(s) } }
  end

  # --- the report ----------------------------------------------------------------------------

  def per_hour(count, runs, options) = count / (runs.length * options.minutes / 60.0)

  def num(value, digits = 1) = value.nil? ? "—" : format("%.#{digits}f", value)

  def pct(part, whole) = whole.zero? ? "—" : format("%.0f%%", 100.0 * part / whole)

  def quarrels(runs, mode) = runs.sum { |r| r[:events].count { |e| e[:type] == :quarrel && e[:mode] == mode } }

  def report(results, options)
    lines = []
    lines << "# Crowds"
    lines << ""
    lines << "Generated by `ruby script/tuning/crowds.rb#{argv_echo(options)}`. Each scenario is " \
             "#{options.seeds} seeds of #{options.minutes} simulated minutes: everybody in one lit room, " \
             "carrying miner's tools, nobody working, full patience at the start. Counts are per hour of " \
             "the shift, for the whole room."
    lines << ""
    animosity = ReactorSim::Animosity
    lines << "| Figure | Value |"
    lines << "|---|---|"
    { "IRRITATION" => animosity::IRRITATION, "SPEND_PER_S" => animosity::SPEND_PER_S,
      "MEND_PER_S" => animosity::MEND_PER_S, "RUMPUS" => animosity::RUMPUS,
      "ESCALATION" => animosity::ESCALATION, "VIOLENCE_HOSTILITY" => animosity::VIOLENCE_HOSTILITY,
      "AUTHORITY_HALF" => animosity::AUTHORITY_HALF, "MOST_AVERTED" => animosity::MOST_AVERTED }
      .each { |name, value| lines << "| `#{name}` | #{value} |" }
    lines << ""

    results.group_by { |scenario, _| scenario.group }.each do |group, rows|
      lines << "## #{group.to_s.capitalize}"
      lines << ""
      lines << "Ran out is how often anybody's patience ran out; it comes to a row, a brawl, a shove, " \
               "a quarrel the boss averted, or nothing (seethed). Fighting is the share of the shift " \
               "with a brawl going and, while one is, the share of the room in it; peak is the most " \
               "brawls at once. Down is everybody carried out or killed by the end, of the room; half " \
               "down is when half the room was, in the shifts it happened in."
      lines << ""
      lines << "| Scenario | First quarrel | Ran out /h | Rows /h | Brawls /h | Shoves /h | Averted /h | Seethed /h | " \
               "Drew /h | Hurt minor / significant / severe / mortal per h | Fighting: of shift, of room | Peak | Down | Half down |"
      lines << "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
      rows.each { |scenario, runs| lines << row(scenario, runs, options) }
      lines << ""
    end

    pile_on(lines, results)
    out = File.expand_path(options.out)
    FileUtils.mkdir_p(File.dirname(out))
    File.write(out, "#{lines.join("\n")}\n")
    puts "wrote #{out}"
  end

  def row(scenario, runs, options)
    acts = runs.flat_map { |r| r[:acts] }
    hurt = runs.flat_map { |r| r[:events].select { |e| e[:type] == :minion_hurt && e[:cause] == :brawl } }
    firsts = runs.filter_map { |r| r[:first_s] }
    first = firsts.empty? ? "never" : "#{num(firsts.sum / firsts.length / 60.0)} min (#{firsts.length}/#{runs.length})"
    ticks = runs.sum { |r| r[:ticks] }
    fighting = runs.sum { |r| r[:fighting_ticks] }
    share = fighting.zero? ? "—" : pct(runs.sum { |r| r[:fighting_share] }, fighting)
    injuries = ReactorSim::Injury::ORDER.map { |m| num(per_hour(hurt.count { |e| e[:mode] == m }, runs, options)) }
    heads = runs.first[:heads]
    halves = runs.filter_map { |r| r[:half_down_s] }
    half = halves.empty? ? "never" : "#{num(halves.sum / halves.length / 60.0)} min (#{halves.length}/#{runs.length})"
    "| #{scenario.name} | #{first} | #{num(per_hour(acts.length, runs, options))} | " \
      "#{num(per_hour(quarrels(runs, :row), runs, options))} | #{num(per_hour(quarrels(runs, :brawl), runs, options))} | " \
      "#{num(per_hour(quarrels(runs, :shove), runs, options))} | " \
      "#{num(per_hour(acts.count { |a| a[:came_to] == :averted }, runs, options))} | " \
      "#{num(per_hour(acts.count { |a| a[:came_to] == :seethed }, runs, options))} | " \
      "#{num(per_hour(quarrels(runs, :armed), runs, options))} | #{injuries.join(' / ')} | " \
      "#{pct(fighting, ticks)}, #{share} | #{runs.map { |r| r[:peak] }.max} | " \
      "#{num(runs.sum { |r| r[:down] } / runs.length.to_f)} of #{heads} | #{half} |"
  end

  # Somebody whose patience ran out while the one they most resented was already in a fight.
  def pile_on(lines, results)
    acts = results.flat_map { |_, runs| runs.flat_map { |r| r[:acts] } }
    busy = acts.select { |a| a[:busy] }
    lines << "## When the one they most resent is already fighting"
    lines << ""
    lines << "Every running-out in every scenario above (#{acts.length}), split by whether the person they " \
             "resented most of everybody there was in a row or a brawl at that moment " \
             "(#{busy.length}, #{pct(busy.length, acts.length)}); they then go for somebody free, or seethe."
    lines << ""
    outcomes = acts.map { |a| a[:came_to] }.uniq.sort
    lines << "| Target | #{outcomes.join(' | ')} |"
    lines << "|---|#{outcomes.map { '---' }.join('|')}|"
    [ [ "already fighting", busy ], [ "free", acts.reject { |a| a[:busy] } ] ].each do |label, set|
      lines << "| #{label} | #{outcomes.map { |o| pct(set.count { |a| a[:came_to] == o }, set.length) }.join(' | ')} |"
    end
    lines << ""
  end

  def argv_echo(options)
    parts = []
    parts << " --minutes #{options.minutes}" unless options.minutes == 60
    parts << " --seeds #{options.seeds}" unless options.seeds == 3
    parts << " --only #{options.only.join(',')}" if options.only
    parts << " --sizes #{options.sizes.join(',')}" unless options.sizes == SIZES
    options.set.each { |name, value| parts << " --set #{name}=#{value}" }
    parts.join
  end

  def parse(argv)
    options = Options.new(minutes: 60, seeds: 3, only: nil, sizes: SIZES, out: File.join(ROOT, "docs/tuning/crowds.md"), set: {})
    OptionParser.new do |o|
      o.on("--sizes NS", "crowd sizes, comma-separated (2,4,8,16,32; bosses run at 8 and 16)") do |s|
        options.sizes = s.split(",").map { |n| Integer(n) }
      end
      o.on("--minutes N", Float, "simulated minutes a shift (60)") { |n| options.minutes = n }
      o.on("--seeds N", Integer, "shifts per scenario (3)") { |n| options.seeds = n }
      o.on("--only GROUPS", "crowds and/or bosses, comma-separated") { |g| options.only = g.split(",").map(&:to_sym) }
      o.on("--out PATH", "where the report goes (docs/tuning/crowds.md)") { |p| options.out = p }
      o.on("--set NAME=VALUE", "try a figure on Combat, Animosity or Injury for this pass; repeatable") do |pair|
        name, value = pair.split("=", 2)
        options.set[name.to_sym] = Float(value)
      end
    end.parse!(argv)
    options
  end
end

CrowdTuning.run(CrowdTuning.parse(ARGV)) if $PROGRAM_NAME == __FILE__
