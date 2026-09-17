# frozen_string_literal: true

require "rails_helper"
require "support/reference_crew"

# The whole chain, end to end: a real engine run, through the envelope the producer puts round
# each fact, into the fold, out as an award.
#
# **This is the spec that catches the failure nobody else can see.** Every other spec here
# checks one hop. The way this system breaks is a *mismatch between hops* — the engine emits
# `:steam_raised` and an achievement is written against `"full_head"`, or a symbol survives as a
# Symbol on one side and arrives as a String on the other. Neither side is wrong on its own,
# nothing raises, and the only symptom is an achievement that never fires, which is
# indistinguishable from one nobody has earned.
#
# So this drives the real simulation rather than hand-built records, and asserts on what a
# player would actually receive.
# **`content:` is passed explicitly rather than using the `crew: :reference` hook**, because the
# expensive cold start runs in a `before(:all)` — which fires before any `before(:each)`, so the
# stub is not installed yet. Passing it at build works here because nothing in this file restores
# a snapshot; a spec that does must use the hook, since `Operation.from_h` resolves against
# `Content.default` and never sees a `content:` argument.
RSpec.describe "the event pipeline" do
  let(:owner) { "pipeline-tester" }
  let(:run_id) { "run-pipeline" }

  # The real lighting procedure. A cold engine cannot be switched on, and the transitions this
  # is about only exist because of that.
  def raise_steam(ticks: 1_700)
    match = ReactorSim::Match.create(
      id: "p", seed: 42,
      operations: [ { id: "eng", type: :steam_engine, chassis: :high_pressure, loadout: {},
                      content: ReferenceCrew::CONTENT }.merge(ReferenceCrew.options) ]
    )
    op = match.operation(:eng)
    { igniter: 100, blower: 100, damper_open: 85, stoking: 70, feed: 45,
      throttle_open: 0, load_demand: 0 }.each { |k, v| op.set_control(k, v) }

    events = []
    (1..ticks).each do |t|
      op.set_control(:igniter, 0) if t == 300
      op.set_control(:load_demand, 90) if t == 1_150
      if t == 1_200
        op.set_control(:throttle_open, 100)
        op.set_control(:stoking, 80)
      end
      op.set_control(:blower, 0) if t == 1_600
      events.concat(match.step!)
    end
    [ match, events ]
  end

  # Exactly what `EventProducer#fact` puts on the wire, round-tripped through JSON — because
  # that round trip is where the symbols-as-values trap lives, and a spec that skips it would
  # pass with the bug fully present.
  def on_the_wire(match, events)
    events.each_with_index.map do |event, seq|
      JSON.parse(JSON.generate({ kind: "event", match_id: match.id, run_id: run_id,
                                 seq: seq }.merge(event)))
    end
  end

  describe "a cold start carried all the way through" do
    # One run, shared across the group: raising steam from cold is ~1700 ticks and is by far the
    # most expensive thing in this file. Safe in `before(:all)` because it touches no database —
    # it is pure simulation, which is the whole point of that boundary.
    before(:all) { @match, @events = raise_steam }

    it "emits the transitions the achievements are written against" do
      expect(@events.map { |e| e[:type] }.uniq)
        .to include(:fire_lit, :heater_engaged, :steam_raised)
    end

    it "stays a handful of records, not a stream — the budget the whole design rests on" do
      # §3 of the sketch: nothing that happens every tick may be an event. Against four
      # broadcasts a second, anything approaching the tick rate here means an accumulation has
      # been mistakenly modelled as a transition.
      expect(@events.length).to be < 20
    end

    it "awards a full head of steam once the records reach the digest" do
      digest = ProgressionDigest.new(owner_id: owner, logger: Logger.new(File::NULL))

      awarded = on_the_wire(@match, @events).flat_map { |record| digest.call(record) }

      expect(awarded).to include(:first_full_head_of_steam)
      expect(Achievement.earned?(:first_full_head_of_steam, owner_id: owner)).to be(true)
    end

    # **This assertion is the one that found the bug, and it found it by being wrong.** It was
    # written expecting the reference start to be *refused* the cold-start achievement, because
    # the procedure holds the igniter in to tick 300. It passed the award instead — and the
    # reason is that the igniter fires at tick 1 and the fire catches at tick 2, so the only
    # heater event fell outside its own window. See `Achievement`'s note: the pilot is how a
    # cold fire is lit at all, so "without the pilot" was never expressible.
    #
    # Redefined as a clean cold start, the reference procedure earns it, which is right: it is
    # the textbook start, and it is what gates the first instrument upgrade.
    it "awards a clean cold start to a run that never relit the pilot" do
      digest = ProgressionDigest.new(owner_id: owner, logger: Logger.new(File::NULL))

      awarded = on_the_wire(@match, @events).flat_map { |record| digest.call(record) }

      expect(awarded).to include(:raised_steam_from_cold_alone)
    end

    # **Asserts the WIRING, deliberately not the outcome.** Whether a given blast kills a given
    # worker is a balance question and every constant behind it is a pre-sweep guess, so an
    # end-to-end "Jim dies" example would fail the day the numbers are tuned — for a reason
    # having nothing to do with what it was checking.
    #
    # What does not move with balance is the shape: a real injury on a real machine has to carry
    # the PERSON and whether the injury lasts, because `InjuryList` cannot write the record
    # without them. `node:` is the job — the fireman's post outlives whoever was standing in it —
    # and a consumer given only that could not put anybody on the injury list at all.
    it "carries the person and the verdict on a real injury, not just the job" do
      match = ReactorSim::Match.create(
        id: "p", seed: 42,
        operations: [ { id: "eng", type: :steam_engine, loadout: { fusible_plug: nil },
                        crew: { fireman: { minion: :test_hand_a } },
                        content: ReferenceCrew::CONTENT } ]
      )
      op = match.operation(:eng)
      { igniter: 100, blower: 100, damper_open: 85, stoking: 70, feed: 0 }
        .each { |k, v| op.set_control(k, v) }

      events = []
      (1..7_000).each do |t|
        op.set_control(:igniter, 0) if t == 300
        events.concat(match.step!)
        break if events.any? { |e| e[:type] == :minion_hurt }
      end

      hurt = on_the_wire(match, events).find { |r| r["type"] == "minion_hurt" }

      expect(hurt).not_to be_nil, "nobody was hurt, so this proves nothing"
      expect(hurt["node"]).to eq("fireman")
      expect(hurt.fetch("detail")).to include("minion" => "test_hand_a")
      expect(hurt.fetch("detail")).to have_key("lasting")
    end

    # The feed a player reads, reconstructed from the durable rows rather than from whatever
    # this browser happened to be connected for.
    it "records every transition durably while showing the player only what went wrong" do
      on_the_wire(@match, @events).each do |record|
        Incident.record!(record.merge("operation_id" => "eng"))
      end

      expect(Incident.for_run(run_id).count).to eq(@events.length)
      expect(Incident.backfill(run_id).map { |i| i[:type] })
        .to all(satisfy { |t| !%w[fire_lit steam_raised heater_engaged].include?(t) })
    end
  end
end
