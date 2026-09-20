# frozen_string_literal: true

require "rails_helper"

# **The ownership rule, end to end.**
#
# Every controller used to answer "may you touch this" by comparing a path segment against a
# constant. These are the examples that say the replacement actually refuses somebody — the half
# that rots if only the permissive path is ever exercised, which is the same argument
# `DevPlayer.earn` versus `grant` is built on.
#
# See docs/design_sketches/operator_identity.md §7.
RSpec.describe "operator identity", type: :request do
  let(:producer) { instance_double(CommandProducer, produce: true) }

  before do
    allow(CommandProducer).to receive(:instance).and_return(producer)
    DevPlayer.grant_everything!
    DevMatch.provision!
  end

  def console(operation_id) = console_path(match_id: DevMatch::ID, operation_id: operation_id)

  def lever(operation_id)
    post("/matches/#{DevMatch::ID}/operations/#{operation_id}/commands",
         params: { type: "set_control", control_point_id: "feed", value: 10 })
  end

  # Somebody else's machine, in the same match this player is in.
  def someone_elses
    Operation.locate(DevMatch::ID, DevMatch::PRIMARY).update!(owner_id: "mallory")
  end

  describe "with the bypass off" do
    before { allow(Operator).to receive(:bypass?).and_return(false) }

    it "lets the owner watch and drive their own machine" do
      get console(DevMatch::PRIMARY)
      expect(response).to have_http_status(:ok)

      lever(DevMatch::PRIMARY)
      expect(response).to have_http_status(:accepted)
    end

    # **The enforcing path, exercised in development.** A check whose only live call site is the
    # one that says yes is a check that rots.
    it "refuses a machine this player does not own" do
      someone_elses

      get console(DevMatch::PRIMARY)
      expect(response).to have_http_status(:not_found)

      lever(DevMatch::PRIMARY)
      expect(response).to have_http_status(:not_found)
      expect(producer).not_to have_received(:produce)
    end

    # **Indistinguishable from outside, and that is the claim** — not leaking existence is the
    # point of answering 404 rather than 403 for something you cannot see.
    it "answers a machine that is not yours exactly as one that does not exist" do
      someone_elses
      get console(DevMatch::PRIMARY)
      forbidden = response.status

      get console(:no_such_engine)

      expect(forbidden).to eq(response.status)
    end

    it "refuses the outfitting and crew screens for a machine that is not yours" do
      someone_elses

      get edit_loadout_path(match_id: DevMatch::ID, operation_id: DevMatch::PRIMARY)
      expect(response).to have_http_status(:not_found)

      get edit_crew_path(match_id: DevMatch::ID, operation_id: DevMatch::PRIMARY)
      expect(response).to have_http_status(:not_found)
    end

    it "refuses a reset when this player operates nothing in the match" do
      Operation.in_match(DevMatch::ID).update_all(owner_id: "mallory")

      post "/matches/#{DevMatch::ID}/reset"

      expect(response).to have_http_status(:not_found)
      expect(producer).not_to have_received(:produce)
    end
  end

  describe "with the bypass on" do
    before { allow(Operator).to receive(:bypass?).and_return(true) }

    it "lets a developer drive a machine they do not own" do
      someone_elses

      lever(DevMatch::PRIMARY)

      expect(response).to have_http_status(:accepted)
    end

    # The point of the hatch: two machines, driven from two consoles, by one person.
    it "drives two operations independently in one match" do
      lever(:engine)
      lever(:engine_b)

      expect(producer).to have_received(:produce).with(
        match_id: DevMatch::ID, command: hash_including("operation_id" => "engine")
      )
      expect(producer).to have_received(:produce).with(
        match_id: DevMatch::ID, command: hash_including("operation_id" => "engine_b")
      )
    end

    it "says so on the console rather than looking like the real thing" do
      someone_elses

      get console(DevMatch::PRIMARY)

      expect(response.body).to include("borrowed")
    end

    it "does not claim a machine it is only borrowing" do
      someone_elses

      lever(DevMatch::PRIMARY)

      expect(Operation.locate(DevMatch::ID, DevMatch::PRIMARY).owner_id).to eq("mallory")
    end
  end

  # An operation that does not exist is a 404 whatever the hatch is doing — the bypass widens
  # *who may operate*, not *what exists*.
  it "still refuses an operation that is not in the match" do
    allow(Operator).to receive(:bypass?).and_return(true)

    get console(:imaginary)

    expect(response).to have_http_status(:not_found)
  end
end
