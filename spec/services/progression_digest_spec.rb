# frozen_string_literal: true

require "rails_helper"

# The fold from the durable log to a player's permanent record.
#
# Driven by hand-built records rather than a broker, deliberately: what is worth guarding is the
# fold — that a point fact awards once, that an interval can be spoiled, that a meter reading is
# absolute — and none of that is about Kafka. The producer's shape is covered where it lives.
RSpec.describe ProgressionDigest do
  let(:owner) { "tester" }
  let(:digest) { described_class.new(owner_id: owner, logger: Logger.new(File::NULL)) }
  let(:run) { "run-a" }

  # **String values throughout, and that is the point rather than an accident.** A record has
  # been through JSON on its way into Kafka, so every symbol that lived as a VALUE — `type`,
  # `node`, `mode`, `severity` — comes back as a String. Sixth instance of that trap in this
  # codebase, and the worst placed: a mismatch is not an error, it is an achievement that
  # silently never fires, which looks exactly like one nobody has earned.
  # `stringify_keys` on `rest` is not decoration: written without it, `node: "flywheel"` lands
  # under a Symbol key while the digest reads `record["node"]`, so the match silently misses and
  # the achievement silently never fires — the trap this helper exists to reproduce, reproduced
  # by accident in the helper itself.
  def event(type, tick: 1, run_id: run, **rest)
    { "kind" => "event", "match_id" => "dev", "run_id" => run_id, "operation_id" => "engine",
      "tick" => tick, "seq" => 0, "type" => type, "severity" => "info" }
      .merge(rest.stringify_keys)
  end

  def meter(ledger, tick: 40, run_id: run)
    { "kind" => "meter", "match_id" => "dev", "run_id" => run_id, "operation_id" => "engine",
      "tick" => tick, "ledger" => ledger }
  end

  describe "point facts" do
    it "awards the moment the fact arrives" do
      expect(digest.call(event("part_failed", node: "flywheel")))
        .to eq([ :burst_a_flywheel ])
      expect(Achievement.earned?(:burst_a_flywheel, owner_id: owner)).to be(true)
    end

    # At-least-once delivery means the consumer WILL see the same fact twice after a rebalance
    # or a replayed tick. The second sighting must be silent, not a second award and not an
    # error.
    it "is idempotent under redelivery" do
      record = event("part_failed", node: "flywheel")
      digest.call(record)

      expect(digest.call(record)).to be_empty
      expect(Award.where(owner_id: owner).count).to eq(1)
    end

    it "ignores a fact whose node does not match the definition" do
      expect(digest.call(event("part_failed", node: "boiler"))).to be_empty
    end
  end

  describe "extent facts" do
    it "awards when the interval closes clean" do
      digest.call(event("fire_lit", tick: 2))

      expect(digest.call(event("steam_raised", tick: 900)))
        .to include(:raised_steam_from_cold_alone)
    end

    # The engine reports that a heater was engaged; only this side knows that forfeits the
    # achievement. That split is the boundary the whole design rests on.
    it "refuses one that was disqualified part way through" do
      digest.call(event("fire_lit", tick: 2))
      digest.call(event("heater_engaged", tick: 3, node: "firebox"))

      expect(digest.call(event("steam_raised", tick: 900)))
        .not_to include(:raised_steam_from_cold_alone)
    end

    it "refuses one that did not last long enough" do
      digest.call(event("steam_raised", tick: 100))

      expect(digest.call(event("fire_out", tick: 200)))
        .not_to include(:ran_an_hour_without_blowing_off)
    end

    it "awards one that lasted the distance" do
      digest.call(event("steam_raised", tick: 100))

      expect(digest.call(event("fire_out", tick: 100 + 14_400)))
        .to include(:ran_an_hour_without_blowing_off)
    end

    # A driver doing well must not have their hour reset by the drum coming back up to pressure
    # after an ordinary dip. Only a spoiled interval is replaced.
    it "does not restart a clean interval when it re-opens" do
      digest.call(event("steam_raised", tick: 100))
      digest.call(event("steam_raised", tick: 5_000))

      expect(digest.call(event("fire_out", tick: 100 + 14_400)))
        .to include(:ran_an_hour_without_blowing_off)
    end

    # A reset rebuilds the match and restarts the tick count. An interval left open by the
    # previous run must not close against the new one's transitions — which is exactly what
    # would happen if these were keyed by match rather than by run.
    it "does not close an interval opened by a different run" do
      digest.call(event("steam_raised", tick: 100, run_id: "run-a"))

      expect(digest.call(event("fire_out", tick: 20_000, run_id: "run-b")))
        .not_to include(:ran_an_hour_without_blowing_off)
    end
  end

  describe "meter readings" do
    it "records an absolute reading rather than accumulating it" do
      digest.call(meter({ "joules_to_work" => 1.0e8 }))
      digest.call(meter({ "joules_to_work" => 2.0e8 }, tick: 80))

      expect(Progress.find_by(owner_id: owner, run_id: run, metric: "joules_to_work").value)
        .to eq(2.0e8)
    end

    # The whole reason readings are absolute: redelivery and reordering both have to be
    # harmless without a dedup table.
    it "never goes backwards when an older reading arrives late" do
      digest.call(meter({ "joules_to_work" => 2.0e8 }, tick: 80))
      digest.call(meter({ "joules_to_work" => 1.0e8 }, tick: 40))

      expect(Progress.find_by(owner_id: owner, run_id: run, metric: "joules_to_work").value)
        .to eq(2.0e8)
    end

    it "awards a threshold achievement from the lifetime total" do
      expect(digest.call(meter({ "joules_to_work" => 2.0e9 })))
        .to include(:generated_a_gigajoule)
    end

    it "sums separate runs into the lifetime figure" do
      digest.call(meter({ "joules_to_work" => 6.0e8 }, run_id: "run-a"))
      digest.call(meter({ "joules_to_work" => 6.0e8 }, run_id: "run-b"))

      expect(Progress.lifetime_totals(owner)["joules_to_work"]).to be_within(1.0).of(1.2e9)
    end

    # **Counting the rows, not just reading the total**, and the difference is a bug this file
    # missed. Postgres treats NULLs as distinct in a unique index, so `(owner, NULL, metric)`
    # never conflicted with itself: every reading INSERTED a fresh lifetime row instead of
    # raising the existing one, and forty seconds of live consumption left 40 rows for 10
    # metrics. The assertion above passed throughout, because `lifetime_totals` builds a Hash
    # and the last value for a repeated key happened to be the right one sitting on three wrong
    # rows. The index is `nulls_not_distinct` now; this is what holds it there.
    it "keeps exactly one lifetime row per metric however many readings arrive" do
      4.times { |i| digest.call(meter({ "joules_to_work" => (i + 1) * 1.0e6 }, tick: (i + 1) * 40)) }

      expect(Progress.lifetime.where(metric: "joules_to_work").count).to eq(1)
      expect(Progress.lifetime_totals(owner)["joules_to_work"]).to be_within(1.0).of(4.0e6)
    end
  end

  # The gate that was decorative until now. `Achievement.earned?` returned true for everything,
  # so `reflex_gauge_glass`'s prerequisite was a silent off switch.
  describe "the blueprint gate" do
    it "is shut before the achievement and open after it" do
      expect(Achievement.earned?(:first_full_head_of_steam, owner_id: owner)).to be(false)

      digest.call(event("steam_raised"))

      expect(Achievement.earned?(:first_full_head_of_steam, owner_id: owner)).to be(true)
    end

    # No auth yet, so an unattributable fact is possible. A nil owner has earned nothing, which
    # is the safe answer: the gate stays shut rather than opening for everybody.
    it "stays shut for an owner nobody can name" do
      expect(Achievement.earned?(:first_full_head_of_steam, owner_id: nil)).to be(false)
    end
  end

  describe "a poisoned record" do
    it "is skipped rather than allowed to block everything behind it" do
      expect(digest.call({ "kind" => "event" })).to be_empty
    end
  end
end
