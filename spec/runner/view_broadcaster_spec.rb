# frozen_string_literal: true

require "rails_helper"

# The wire protocol as the runner speaks it. Cross-process delivery itself is verified by
# running the thing; what is guarded here is the envelope and the resync contract, both of
# which fail silently — the runner publishes happily and the client just never recovers.
RSpec.describe ViewBroadcaster do
  subject(:broadcaster) { described_class.new(logger: Logger.new(File::NULL)) }

  let(:match) { DevMatch.build }
  let(:operation) { match.operations.first }
  let(:stream) do
    StreamNames.operation(match_id: match.id, operation_id: DevMatch::PRIMARY)
  end

  # Captures what reached the cable without needing a subscriber or a database.
  def broadcasts
    @broadcasts ||= [].tap do |captured|
      allow(ActionCable.server).to receive(:broadcast) { |_s, payload| captured << payload }
    end
  end

  before { broadcasts }

  def tick!(times = 1, full: false, run_id: "run-1", supersedes: nil)
    times.times do
      match.step!
      broadcaster.publish(match, operation, full: full, run_id: run_id, supersedes: supersedes)
    end
  end

  it "sends a full view first, because a delta has nothing to be a delta from" do
    tick!

    expect(broadcasts.first[:kind]).to eq("full")
    expect(broadcasts.first[:view].keys)
      .to contain_exactly(:tick, :operation_id, :viewer, :gauges, :flags, :controls, :incidents,
                          :crew)
  end

  it "labels the shape explicitly rather than leaving the client to sniff it" do
    tick!(3)

    expect(broadcasts.map { |b| b[:kind] }).to start_with("full", "delta")
  end

  # Because unchanged ticks are skipped, gaps in `tick` are normal. A client comparing against
  # `tick - 1` would resync several times a minute for no reason; `prev_tick` is what chains.
  it "chains deltas by prev_tick, not by tick minus one" do
    tick!(6)
    deltas = broadcasts.select { |b| b[:kind] == "delta" }

    expect(deltas).not_to be_empty
    deltas.each_cons(2) { |a, b| expect(b[:prev_tick]).to eq(a[:tick]) }
  end

  it "carries no prev_tick on a full view, since it replaces rather than merges" do
    tick!

    expect(broadcasts.first[:prev_tick]).to be_nil
  end

  it "resends a full view periodically, so a stale client heals without asking" do
    tick!(described_class::FULL_VIEW_TICKS + 1)

    expect(broadcasts.count { |b| b[:kind] == "full" }).to be >= 2
  end

  it "sends a full view on demand when asked" do
    tick!(2)
    before_count = broadcasts.count { |b| b[:kind] == "full" }
    broadcaster.publish(match, operation, full: true)

    expect(broadcasts.count { |b| b[:kind] == "full" }).to eq(before_count + 1)
  end

  it "broadcasts on the stream the channel subscribes to" do
    allow(ActionCable.server).to receive(:broadcast)
    tick!

    expect(ActionCable.server).to have_received(:broadcast).with(stream, anything).at_least(:once)
  end

  # A reset rebuilds the Match, so every client's accumulated view describes a match that no
  # longer exists. Continuing to send deltas against it would leave the panel subtly wrong
  # rather than obviously broken, which is worse.
  it "starts again with a full view after a reset" do
    tick!(3)
    broadcaster.reset(match.id)
    tick!

    expect(broadcasts.last[:kind]).to eq("full")
  end

  # Nothing stops a second runner broadcasting onto this stream, and it holds its own match at
  # its own tick with its own levers. Tick alone cannot tell the two apart; the run can.
  describe "naming the run the values came from" do
    it "stamps every view, full and delta alike" do
      tick!(3)

      expect(broadcasts.map { |b| b[:run_id] }.uniq).to eq([ "run-1" ])
      expect(broadcasts.map { |b| b[:kind] }).to include("full", "delta")
    end

    # A reset says which run it replaced; a runner restart cannot, which is why a client also
    # needs a grace period. Carrying it means the reset case never has to wait one out.
    it "carries the run it replaced" do
      tick!(2)
      broadcaster.reset(match.id)
      tick!(1, run_id: "run-2", supersedes: "run-1")

      expect(broadcasts.last[:run_id]).to eq("run-2")
      expect(broadcasts.last[:supersedes]).to eq("run-1")
      expect(broadcasts.first[:supersedes]).to be_nil
    end
  end

  it "publishes every operation when asked for a resync with no operation named" do
    broadcaster.publish(match, nil, full: true)

    expect(broadcasts.size).to eq(match.operations.size)
  end

  # Telemetry must never be the thing that stops a match.
  it "swallows a broadcast failure rather than taking the tick down" do
    allow(ActionCable.server).to receive(:broadcast).and_raise(StandardError, "cable down")

    expect { broadcaster.publish(match, operation) }.not_to raise_error
  end
end
