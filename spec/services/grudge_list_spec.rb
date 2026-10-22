# frozen_string_literal: true

require "rails_helper"

# Grudges formed in play, carried to the next match and worn down by it.
RSpec.describe GrudgeList do
  let(:owner) { "gl-tester" }
  let(:list) { described_class.new(owner_id: owner, logger: Logger.new(File::NULL)) }

  def formed(holder: "galathas", target: "throg", amount: 0.2, tick: 412, run_id: "run-a")
    { "kind" => "event", "type" => "grudge_formed", "run_id" => run_id, "match_id" => "dev",
      "operation_id" => "pit", "tick" => tick, "seq" => 0, "node" => "crew_2",
      "label" => "Galathas", "severity" => "info",
      "detail" => { "holder" => holder, "against" => "crew_1", "target" => target, "amount" => amount } }
  end

  def held(holder = "galathas", target = "throg") = Grudge.carried_for(owner).dig(holder, target).to_f

  it "writes down who now holds what against whom" do
    expect(list.call(formed)).to eq(%w[galathas throg])
    expect(held).to be_positive
  end

  it "deepens with each wrong, and never past a whole grudge" do
    list.call(formed(tick: 1))
    once = held
    list.call(formed(tick: 2))

    expect(held).to be > once
    20.times { |i| list.call(formed(amount: 0.5, tick: 10 + i)) }
    expect(held).to be <= 1.0
  end

  # At-least-once delivery: the same wrong arrives twice after a rebalance.
  it "deepens once for the same wrong delivered twice" do
    list.call(formed)
    once = held
    list.call(formed)

    expect(held).to eq(once)
  end

  it "never writes down a standin, who is nobody in particular" do
    expect(list.call(formed(target: ReactorSim::Crew::STANDIN.to_s))).to be_empty
    expect(Grudge.count).to eq(0)
  end

  it "ignores records that are not grudges" do
    expect(list.call({ "kind" => "event", "type" => "minion_hurt" })).to be_empty
  end

  describe "between matches" do
    it "fades, and is forgotten in the end" do
      list.call(formed(amount: 0.4))
      before = held
      Grudge.fade!(owner)

      expect(held).to be < before
      30.times { Grudge.fade!(owner) }
      expect(Grudge.owned_by(owner)).to be_empty
    end

    it "fades slower for a spiteful holder than a neutral one" do
      list.call(formed(holder: "urist", target: "galathas", amount: 0.4))
      list.call(formed(holder: "jim", target: "galathas", amount: 0.4))
      Grudge.fade!(owner)

      expect(held("urist", "galathas")).to be > held("jim", "galathas")
    end
  end
end
