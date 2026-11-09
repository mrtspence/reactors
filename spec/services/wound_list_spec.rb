# frozen_string_literal: true

require "rails_helper"

# Wounds taken in play, carried to the next match, and healed a little each one.
RSpec.describe WoundList do
  let(:owner) { "wl-tester" }
  let(:list) { described_class.new(owner_id: owner, logger: Logger.new(File::NULL)) }

  def wound(kind: "crush", depth: 0.8, slot: 0, ref: nil)
    { "kind" => kind, "tier" => "significant", "id" => "broken_leg", "depth" => depth,
      "variant" => 0, "slot" => slot, "ref" => ref }.compact
  end

  def hurt(minion: "jim", wounds: [ wound ], tick: 412, run_id: "run-a")
    { "kind" => "event", "type" => "minion_hurt", "run_id" => run_id, "match_id" => "dev",
      "operation_id" => "pit", "tick" => tick, "seq" => 0, "node" => "crew_1", "mode" => "significant",
      "label" => "Jim", "severity" => "warning", "detail" => { "minion" => minion, "wounds" => wounds } }
  end

  def carried(minion = "jim") = Wound.carried_for(owner).fetch(minion, [])

  it "writes down every wound a harm left" do
    expect(list.call(hurt(wounds: [ wound(slot: 0), wound(kind: "burn", depth: 0.3, slot: 1) ]))).to eq(%w[jim])
    expect(carried.map { |w| w.fetch("kind") }).to eq(%w[crush burn])
  end

  # At-least-once delivery: the same harm arrives twice after a rebalance.
  it "writes a wound once however often it is delivered" do
    2.times { list.call(hurt) }

    expect(carried.length).to eq(1)
  end

  it "keeps a wound that deepens as the same wound" do
    list.call(hurt(wounds: [ wound(depth: 0.3) ]))
    list.call(hurt(wounds: [ wound(depth: 1.1) ], tick: 500))

    expect(carried.map { |w| w.fetch("depth") }).to eq([ 1.1 ])
  end

  it "knows a wound carried in from an earlier match again" do
    list.call(hurt(wounds: [ wound(depth: 0.8) ]))
    ref = carried.first.fetch("ref")
    list.call(hurt(wounds: [ wound(depth: 1.2, slot: 0, ref: ref) ], run_id: "run-b"))

    expect(carried.map { |w| w.values_at("ref", "depth") }).to eq([ [ ref, 1.2 ] ])
  end

  it "never writes down a standin, who is nobody in particular" do
    expect(list.call(hurt(minion: ReactorSim::Crew::STANDIN.to_s))).to be_empty
    expect(Wound.count).to eq(0)
  end

  it "ignores records that are not injuries" do
    expect(list.call({ "kind" => "event", "type" => "grudge_formed" })).to be_empty
  end

  describe "between matches" do
    it "heals, and a healed wound goes" do
      list.call(hurt(wounds: [ wound(depth: 0.8) ]))
      Wound.heal!(owner)

      expect(carried.first.fetch("depth")).to be < 0.8
      Wound.heal!(owner)
      expect(carried).to be_empty
    end

    it "heals a slow healer slower than anybody else" do
      list.call(hurt(minion: "elowynne", wounds: [ wound(depth: 1.0) ]))
      list.call(hurt(minion: "jim", wounds: [ wound(depth: 1.0) ]))
      Wound.heal!(owner)

      expect(carried("elowynne").first.fetch("depth")).to be > carried("jim").first.fetch("depth")
    end

    it "keeps somebody out while a wound would carry them out, and says for how long" do
      list.call(hurt(wounds: [ wound(depth: Wound::OUT + ReactorSim::Wounds::HEAL_PER_MATCH) ]))

      expect(Wound.remaining_for(owner)).to eq("jim" => 2)
      expect(Wound.available?(owner, "jim")).to be(false)
      2.times { Wound.heal!(owner) }
      expect(Wound.available?(owner, "jim")).to be(true)
    end
  end
end
