# frozen_string_literal: true

require "rails_helper"
require "support/engine_rig"
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
  include EngineRig

  let(:owner) { "pipeline-tester" }
  let(:run_id) { "run-pipeline" }

  # **A working engine, and the transitions come off it in thirty ticks.**
  #
  # This used to light a cold engine and run it for 1,700 ticks, which was by far the most
  # expensive thing in the file — and it was buying transitions that an engine *at work* emits
  # just as truthfully. `fire_lit`, `steam_raised` and `heater_engaged` are edge-triggered, so a
  # constructed engine announces them on the tick it first reads its own state.
  #
  # **One pulse of the igniter**, because `heater_engaged` is the pilot and a seeded engine's fire
  # is already alight — without the pulse that record never appears.
  #
  # What this file does NOT do any more is pay for a cold start to watch an *achievement* unlock.
  # Whether a given sequence of records earns a given award is the digest's business and is tested
  # there against synthetic records, one example per rule — see `progression_digest_spec`. An
  # achievement that needed an integration test apiece would make the suite unusable, which is
  # the whole reason the digest takes records rather than an operation.
  def working_engine(ticks: 30)
    match = ReactorSim::Match.create(
      id: "p", seed: 42,
      operations: [ { id: "eng", type: :steam_engine, chassis: :high_pressure,
                      loadout: ReferenceCrew.loadout,
                      content: ReferenceCrew::CONTENT }.merge(ReferenceCrew.options) ]
    )
    seeded = seed_match(match, :eng, nodes: at_work_nodes(match.operation(:eng)))
    op = seeded.operation(:eng)
    # The opening move of a match: crew start in the quarters, so an engine with nobody sent to
    # the shovel makes nothing whatever of its fire.
    ReferenceCrew.deploy!(op)
    EngineRig::WORKING.each { |id, value| op.set_control(id, value) }

    events = []
    ticks.times do |i|
      op.set_control(:igniter, i.zero? ? 100 : 0)
      events.concat(seeded.step!)
    end
    [ seeded, events ]
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

  describe "a working engine carried all the way through" do
    # One run, shared across the group. Safe in `before(:all)` because it touches no database —
    # it is pure simulation, which is the whole point of that boundary.
    before(:all) { @match, @events = working_engine }

    it "emits the transitions the achievements are written against" do
      expect(@events.map { |e| e[:type] }.uniq)
        .to include(:fire_lit, :heater_engaged, :steam_raised)
    end

    # §3 of the sketch: **nothing that happens every tick may be an event.** Against four
    # broadcasts a second, anything approaching the tick rate means an accumulation has been
    # mistakenly modelled as a transition.
    #
    # **Asserted as invariance rather than as a budget**, which is the property itself: a count
    # under twenty says the window was short, where a count that does not move between a thirty-
    # tick window and a four-hundred-tick one says the records are transitions. Measured: four
    # events at 30 ticks and the same four at 120.
    it "stays a handful of records, not a stream — the budget the whole design rests on" do
      _, longer = working_engine(ticks: 400)

      expect(@events.length).to be < 20
      expect(longer.length).to eq(@events.length)
    end

    it "awards a full head of steam once the records reach the digest" do
      digest = ProgressionDigest.new(owner_id: owner, logger: Logger.new(File::NULL))

      awarded = on_the_wire(@match, @events).flat_map { |record| digest.call(record) }

      expect(awarded).to include(:first_full_head_of_steam)
      expect(Achievement.earned?(:first_full_head_of_steam, owner_id: owner)).to be(true)
    end

    # `raised_steam_from_cold_alone` is **not** asserted here any more, and deliberately. It is an
    # extent fact — `fire_lit` opens it, `steam_raised` closes it, `heater_engaged` disqualifies it
    # — so what decides it is the *order of the records*, not how long an engine took to make
    # them. Paying 1,700 ticks to find out whether three records arrived in the right order is the
    # thing that cannot scale: one integration test per achievement and the suite is unusable.
    # It lives in `progression_digest_spec`, against synthetic records, with the ordering
    # subtlety that made it surprising written down beside it.
    # **Asserts the WIRING, deliberately not the outcome.** Whether a given blast kills a given
    # worker is a balance question and every constant behind it is a pre-sweep guess, so an
    # end-to-end "Jim dies" example would fail the day the numbers are tuned — for a reason
    # having nothing to do with what it was checking.
    #
    # What does not move with balance is the shape: a real injury on a real machine has to carry
    # the PERSON and whether the injury lasts, because `InjuryList` cannot write the record
    # without them. `node:` is the SEAT — the post outlives whoever was standing in it — and a
    # consumer given only that could not put anybody on the injury list at all.
    it "carries the person and the verdict on a real injury, not just the seat" do
      match = ReactorSim::Match.create(
        id: "p", seed: 42,
        operations: [ { id: "eng", type: :steam_engine,
                        loadout: ReferenceCrew.loadout(fusible_plug: nil),
                        crew: { crew_1: { minion: :test_hand_a } },
                        content: ReferenceCrew::CONTENT } ]
      )
      # **The drum is built on the edge of letting go**, rather than fired for 7,000 ticks until
      # it does. With no plug fitted, 400 kg of water, the feed shut and a shell already worked,
      # the crown sheet fails in a handful of ticks. Both figures belong to `crown_sheet_spec`,
      # which records why neither is arbitrary: severity scales with the water left to flash, and
      # the erosion rate is that spec's claim rather than this one's.
      #
      # **Seeded through the MATCH**, because `on_the_wire` reads `match.id` and the records have
      # to come off the same match the state is in.
      engine_op = match.operation(:eng)
      seeded = seed_match(match, :eng,
                          nodes: at_work_nodes(engine_op, water: 400.0)
                                   .merge(boiler: body(engine_op, :boiler, EngineRig::DRUM_K,
                                                       water: 400.0,
                                                       steam: EngineRig::DRUM.fetch(:steam))
                                                    .merge(durability: 20.0)))
      op = seeded.operation(:eng)
      # Deploy the shift: crew start in the quarters, so nobody is at the firehole — and nobody
      # is near the drum when it lets go — until they are sent.
      op.assign_minion(:crew_1, :stoking)
      { igniter: 0, blower: 0, damper_open: 85, stoking: 70, feed: 0,
        throttle_open: 60, load_demand: 80 }.each { |k, v| op.set_control(k, v) }

      events = []
      20.times do
        events.concat(seeded.step!)
        break if events.any? { |e| e[:type] == :minion_hurt }
      end

      hurt = on_the_wire(seeded, events).find { |r| r["type"] == "minion_hurt" }

      expect(hurt).not_to be_nil, "nobody was hurt, so this proves nothing"
      expect(hurt["node"]).to eq("crew_1")
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
