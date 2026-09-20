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
  end
end
