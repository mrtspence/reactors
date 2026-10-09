# frozen_string_literal: true

require "reactor_sim"
require "json"
require "support/loop_rig"

# The durable record's contract. See docs/design_sketches/event_system.md.
#
# Events used to exist only inside whatever projection happened to be broadcast, so nothing
# needed to hold them to anything. Once they are the log of record — the thing achievements are
# folded from and a spectator backfills from — three properties become load-bearing, and none
# of them were specced before this file.
RSpec.describe "events" do
  describe "the vocabulary" do
    it "names every type exactly once" do
      expect(ReactorSim::Event::TYPES.tally.select { |_, n| n > 1 }).to be_empty
    end

    # **A type nothing can emit is worse than a missing one.** A consumer keyed to it waits
    # forever and looks exactly like a consumer waiting for something that has not happened
    # yet, which is indistinguishable from "you have not earned this achievement".
    #
    # Derived from the source rather than written out, for the reason every inventory list in
    # this codebase is derived: a hand-written copy drifts the first time somebody adds an
    # emitter, and it drifts silently.
    #
    # **This imposes one rule on emitters, deliberately: spell the type literally at the
    # `Event.build` call.** A computed type — `type: lit ? :fire_lit : :fire_out` — cannot be
    # found here, so the vocabulary check would silently stop covering it, which is the same
    # class of silent gap the check exists to close. Two calls instead of a ternary is cheap.
    it "has no entry that nothing in the library emits" do
      root = File.expand_path("../../lib/reactor_sim", __dir__)
      emitted = Dir.glob(File.join(root, "**", "*.rb"))
                   .flat_map { |f| File.read(f).scan(/Event\.build\(\s*type:\s*:(\w+)/) }
                   .flatten.map(&:to_sym).uniq

      expect(ReactorSim::Event::TYPES - emitted).to be_empty
    end

    it "refuses a type it does not know" do
      expect {
        ReactorSim::Event.build(type: :boiler_had_a_think, node: :boiler, label: "B",
                                severity: :critical, tick: 1)
      }.to raise_error(ReactorSim::Error, /unknown event type/)
    end

    it "refuses a severity it does not know" do
      expect {
        ReactorSim::Event.build(type: :part_failed, node: :boiler, label: "B",
                                severity: :quite_bad, tick: 1)
      }.to raise_error(ReactorSim::Error, /unknown severity/)
    end

    it "drops absent optional fields rather than carrying nils onto the log" do
      event = ReactorSim::Event.build(type: :part_failed, node: :boiler, label: "B",
                                      severity: :critical, tick: 1, escalated_from: nil)

      expect(event).not_to have_key(:escalated_from)
      expect(event).to be_frozen
    end
  end

  # **This is what makes at-least-once delivery harmless**, and it is the whole reason the
  # dedupe key can be `(match_id, run_id, operation_id, tick, seq)` with no dedup table
  # anywhere — exactly as absolute values do the same job for commands.
  #
  # A crash between producing tick N's events and writing the snapshot that supersedes them
  # replays N from the older snapshot and re-emits them. That is only safe if the replay emits
  # the SAME events in the SAME order, which holds because `Tick#apply_nodes` and `Tick#stress`
  # both walk `@nodes` in build order. Nothing held them to it before.
  describe "replay from a snapshot" do
    def rig(seed: 7)
      ReactorSim::Match.create(id: "c", seed: seed, time_scale: 4.0,
                               operations: [ { id: "rig", type: :loop_rig } ])
    end

    def round_trip(match) = ReactorSim::Match.from_h(JSON.parse(JSON.generate(match.to_h)))

    # Shut in with the fire lit, which is the loop rig's route to a burst vessel.
    def shut_in(match)
      op = match.operation(:rig)
      op.set_control(:burner, 100)
      op.set_control(:steam_valve, 0)
      match
    end

    it "re-emits the same events, in the same order, from a restored snapshot" do
      original = shut_in(rig)
      400.times { original.step! }

      replayed = round_trip(original)

      live = Array.new(200) { original.step! }
      again = Array.new(200) { replayed.step! }

      # Compared through `canonical` because these are nested hashes of floats: the events must
      # be identical, not merely similar, or a consumer folding both copies double-counts.
      expect(again.map { |tick| ReactorSim.canonical(tick) })
        .to eq(live.map { |tick| ReactorSim.canonical(tick) })
    end

    it "actually emits something over that window, so the comparison is not of two empties" do
      match = shut_in(rig)
      events = Array.new(600) { match.step! }.flatten

      expect(events.map { |e| e[:type] }).to include(:part_failed)
    end
  end

  describe "what an event carries" do
    it "identifies the part by node and mode rather than by a type per part" do
      match = ReactorSim::Match.create(id: "c", seed: 7, time_scale: 4.0,
                                       operations: [ { id: "rig", type: :loop_rig } ])
      op = match.operation(:rig)
      op.set_control(:burner, 100)
      op.set_control(:steam_valve, 0)

      failure = Array.new(600) { match.step! }.flatten.find { |e| e[:type] == :part_failed }

      expect(failure).to include(:node, :mode, :cause, :severity, :tick)
      # The engine's clock is the tick. A wall-clock stamp is forbidden here anyway, but it is
      # also the wrong clock: `tick` is the one replay and the projection already agree on.
      expect(failure.keys).not_to include(:at, :timestamp, :produced_at_ms)
    end

    # **`cause:` is a top-level field and every casualty owes one**, because that is where the
    # feed reads it: put it inside `detail:` and the line reads "unknown" beside a dead minion,
    # which is the one thing it must never say. A `minion_hurt` names the kind of harm
    # (`asphyxia`, a hazard tag) rather than the part, which rides along as `by:`.
    it "says what hurt somebody, not merely that something did" do
      op = ReactorSim::Match
           .create(id: "h", seed: 5,
                   operations: [ { id: "pit", type: :mine,
                                   ground: ReactorSim::Operations::Mine::Ground::ORDINARY } ])
           .operation(:pit)
      op.assign_minion(:crew_8, :hewing)
      op.set_control(:hewing, 100)

      to_a_person = %i[minion_hurt minion_spent]
      casualties = Array.new(3_000) { |i| op.step!(tick: i + 1) }
                        .flatten.select { |e| to_a_person.include?(e[:type]) }

      expect(casualties).not_to be_empty
      expect(casualties.map { |e| e[:cause] }.uniq).to all(be_a(Symbol))
    end

    # **A fire reaches the player only if it is severe enough to be an incident**, and
    # `Operation#incidents` reports `warning` and `critical` alone. Lighting a district read as
    # `info`, so a gas ignition that burned off the firedamp, drove four fifths of the air out
    # on thermal expansion and left the roadway at 1300 K put *nothing whatever* on the panel —
    # the player watched their air vanish with no line to explain it.
    #
    # The vessel decides, by its own temperature rating: a firebox is built to burn and rates
    # itself infinite; a roadway does not. **No supply, so the fan is stopped and the gas
    # builds** — a lamp in a district the fan is holding at 3% is not an incident and must not
    # read as one, which is the other half of this and lives in `mine_tech_spec`.
    it "puts a fire in a place not built for one in front of the player" do
      op = ReactorSim::Match
           .create(id: "f", seed: 1,
                   operations: [ { id: "pit", type: :mine,
                                   ground: ReactorSim::Operations::Mine::Ground::ORDINARY } ])
           .operation(:pit)
      op.set_control(:naked_flame, 100)

      lit = nil
      2_500.times do |i|
        events = op.step!(tick: i + 1)
        next if events.none? { |e| e[:type] == :fire_lit && e[:severity] == :critical }

        lit = { event: events.find { |e| e[:type] == :fire_lit }, reported: op.incidents }
        break
      end

      expect(lit).not_to be_nil, "the district never caught"
      expect(lit.fetch(:event)[:cause]).to be(:naked_flame)
      expect(lit.fetch(:reported).map { |e| e[:type] }).to include(:fire_lit)
    end

    # The other half, and the one that would break every match if it went wrong: an engine
    # lighting its own firebox is the machine working, not an incident. A firebox is built to
    # burn and rates its temperature as infinite, so nothing alight in one is ever news.
    it "leaves a firebox lighting as ordinary business" do
      op = ReactorSim::Match
           .create(id: "b", seed: 1, operations: [ { id: "eng", type: :steam_engine } ])
           .operation(:eng)
      expect(op.nodes.fetch(:firebox).send(:fire_severity)).to be(:info)
    end
  end
end
