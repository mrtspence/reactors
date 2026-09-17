# frozen_string_literal: true

require "rails_helper"

# The injury list, and the loop that makes losing somebody hurt.
#
# A mortal injury is the only thing in this release that outlives the match that caused it, so
# this is the one place the simulation's consequences reach a player's permanent record.
RSpec.describe InjuryList do
  let(:owner) { "il-tester" }
  let(:list) { described_class.new(owner_id: owner, logger: Logger.new(File::NULL)) }

  def hurt(mode, minion: "jim", lasting: nil, run_id: "run-a")
    { "kind" => "event", "type" => "minion_hurt", "run_id" => run_id, "match_id" => "dev",
      "operation_id" => "engine", "tick" => 412, "seq" => 0, "node" => "fireman",
      "label" => "Jim Ashfield", "severity" => "critical", "mode" => mode,
      "detail" => { "minion" => minion, "station" => "stoking",
                    "lasting" => lasting.nil? ? mode == "mortal" : lasting } }
  end

  # **Read from the event, not re-derived.** The engine owns the ladder and says on the record
  # whether an injury lasts; a second copy of that rule here would be one more thing to keep in
  # step, and it would fail in the direction of losing people forever.
  it "takes somebody off the board for a mortal injury" do
    expect(list.call(hurt("mortal"))).to eq([ "jim" ])
    expect(MinionCondition.available?(owner, "jim")).to be(false)
  end

  it "leaves a severe injury alone, because it heals with the match" do
    expect(list.call(hurt("severe"))).to be_empty
    expect(MinionCondition.available?(owner, "jim")).to be(true)
  end

  it "leaves a scratch alone" do
    expect(list.call(hurt("minor"))).to be_empty
  end

  it "ignores records that are not injuries at all" do
    expect(list.call({ "kind" => "event", "type" => "part_failed" })).to be_empty
    expect(list.call({ "kind" => "meter" })).to be_empty
  end

  # At-least-once delivery means the consumer WILL see the same injury twice after a rebalance
  # or a replayed tick. The second sighting must not extend the sentence.
  it "does not lengthen a sentence when the same injury is delivered twice" do
    list.call(hurt("mortal"))
    first = MinionCondition.find_by(owner_id: owner, minion_id: "jim").matches_remaining

    list.call(hurt("mortal"))

    expect(MinionCondition.find_by(owner_id: owner, minion_id: "jim").matches_remaining)
      .to eq(first)
  end

  # A *later* run hurting the same person is a genuinely new injury, not a redelivery.
  it "starts a fresh sentence when a different run hurts them again" do
    list.call(hurt("mortal", run_id: "run-a"))
    MinionCondition.advance!(owner)
    before = MinionCondition.find_by(owner_id: owner, minion_id: "jim").matches_remaining

    list.call(hurt("mortal", run_id: "run-b"))

    expect(MinionCondition.find_by(owner_id: owner, minion_id: "jim").matches_remaining)
      .to be >= before
  end

  # There is an inexhaustible supply of day-labourers and the whole point of a last resort is
  # that it is always there. A row for one would take the floor out from under every match after.
  it "never puts the standin on the list" do
    expect(list.call(hurt("mortal", minion: ReactorSim::Crew::STANDIN.to_s))).to be_empty
    expect(MinionCondition.count).to eq(0)
  end

  describe "the recovery clock" do
    before { list.call(hurt("mortal")) }

    it "costs between one and three matches" do
      expect(MinionCondition.find_by(owner_id: owner, minion_id: "jim").matches_remaining)
        .to be_between(MinionCondition::RECOVERY.begin, MinionCondition::RECOVERY.end)
    end

    # Derived from the run and the person rather than drawn, so a replayed match takes the same
    # person out for the same length of time — the determinism the injury model rests on does
    # not stop at the simulation's edge.
    it "is the same length for the same run and the same person" do
      first = MinionCondition.recovery_for(owner, "jim", "run-a")

      expect(MinionCondition.recovery_for(owner, "jim", "run-a")).to eq(first)
    end

    it "runs down as matches start, and ends" do
      MinionCondition::RECOVERY.end.times { MinionCondition.advance!(owner) }

      expect(MinionCondition.available?(owner, "jim")).to be(true)
    end

    # The row is kept at zero rather than deleted, so the screen can still say what happened.
    it "keeps the record after they have recovered" do
      MinionCondition::RECOVERY.end.times { MinionCondition.advance!(owner) }

      expect(MinionCondition.find_by(owner_id: owner, minion_id: "jim").cause).to be_present
    end
  end
end
