# frozen_string_literal: true

require "rails_helper"

# The ingress. What reaches the log, what is turned away, and what the client is told.
#
# The producer is stubbed throughout: these examples are about validation and status codes, and
# a request spec that needs a broker running is a request spec nobody runs.
RSpec.describe "commands", type: :request do
  let(:producer) { instance_double(CommandProducer, produce: true) }

  before { allow(CommandProducer).to receive(:instance).and_return(producer) }
  # An operation has to exist to be owned — `require_operator!` finds the row and asks it.
  before { DevMatch.provision! }

  # **Nested under the operation**, because a command names the machine it is for and a match
  # holds several. It was match-level while `CommandsController` wrote a constant into every
  # payload, which is exactly what stopped a second console driving a second engine.
  def post_command(operation_id: DevMatch::PRIMARY, **params)
    post("/matches/#{DevMatch::ID}/operations/#{operation_id}/commands", params: params)
  end

  it "accepts a well-formed lever move and answers 202 without waiting for the broker" do
    post_command(type: "set_control", control_point_id: "throttle_open", value: "60")

    expect(response).to have_http_status(:accepted)
    expect(producer).to have_received(:produce).with(
      match_id: DevMatch::ID,
      command: hash_including("type" => "set_control", "control_point_id" => "throttle_open",
                              "value" => 60.0)
    )
  end

  # **The operation comes from the ROUTE, never from the body.** It used to come from a constant,
  # which was safe and also why a second console could not drive a second engine; now it is the
  # row `require_operator!` already found and approved.
  it "stamps the operation id itself rather than trusting the client with it" do
    post("/matches/#{DevMatch::ID}/operations/#{DevMatch::PRIMARY}/commands",
         params: { type: "set_control", control_point_id: "feed", value: 10,
                   operation_id: "somebody_elses_engine" })

    expect(producer).to have_received(:produce).with(
      match_id: DevMatch::ID,
      command: hash_including("operation_id" => DevMatch::PRIMARY.to_s)
    )
  end

  # The other half of the same claim: address a different machine and the command follows.
  it "addresses the operation the route names" do
    post_command(operation_id: :engine_b, type: "set_control",
                 control_point_id: "feed", value: 10)

    expect(producer).to have_received(:produce).with(
      match_id: DevMatch::ID, command: hash_including("operation_id" => "engine_b")
    )
  end

  # Defence in depth, not the only defence — Command.parse coerces the value and Match#apply
  # rejects what it cannot read, because this controller is not the topic's only producer. But
  # junk turned away here never occupies a partition, and the player gets an error rather than
  # silence.
  describe "a value that is not a number" do
    [ [ "a hash", { a: 1 } ], [ "an array", [ 1 ] ], [ "a word", "abc" ], [ "nothing", nil ] ].each do |label, value|
      it "refuses #{label} and never produces" do
        post_command(type: "set_control", control_point_id: "throttle_open", value: value)

        expect(response).to have_http_status(:unprocessable_content)
        expect(producer).not_to have_received(:produce)
      end
    end
  end

  it "refuses a control point id that is not shaped like one" do
    post_command(type: "set_control", control_point_id: "../../etc/passwd", value: 10)

    expect(response).to have_http_status(:unprocessable_content)
    expect(producer).not_to have_received(:produce)
  end

  it "refuses a command type it has never heard of" do
    post_command(type: "drop_tables", value: 1)

    expect(response).to have_http_status(:unprocessable_content)
  end

  it "404s a match that is not the dev match" do
    post "/matches/someone-elses-match/commands",
         params: { type: "set_control", control_point_id: "feed", value: 1 }

    expect(response).to have_http_status(:not_found)
  end

  # The request was fine; we could not forward it. Optimistic UI rolls the lever back when no
  # projection confirms it, so the client needs to know the difference between "rejected" and
  # "not delivered".
  it "answers 503 when the broker cannot be reached" do
    allow(producer).to receive(:produce).and_raise(StandardError, "broker down")
    post_command(type: "set_control", control_point_id: "feed", value: 10)

    expect(response).to have_http_status(:service_unavailable)
  end

  describe "minion assignment" do
    it "accepts a posting" do
      post_command(type: "assign_minion", minion_id: "crew_1", control_point_id: "stoking")

      expect(response).to have_http_status(:accepted)
      expect(producer).to have_received(:produce).with(
        match_id: DevMatch::ID,
        command: hash_including("type" => "assign_minion", "minion_id" => "crew_1",
                                "control_point_id" => "stoking")
      )
    end

    it "accepts standing a minion down, which is a nil station" do
      post_command(type: "assign_minion", minion_id: "crew_1")

      expect(response).to have_http_status(:accepted)
      expect(producer).to have_received(:produce).with(
        match_id: DevMatch::ID, command: hash_including("control_point_id" => nil)
      )
    end
  end

  describe "reset" do
    it "goes through the command log so it stays ordered against the levers" do
      post "/matches/#{DevMatch::ID}/reset"

      expect(response).to have_http_status(:accepted)
      # **Keyed by operation**, because a reset rebuilds every machine in the match and each
      # carries its own chassis, loadout and crew.
      expect(producer).to have_received(:produce).with(
        match_id: DevMatch::ID,
        command: hash_including("type" => "reset_match",
                                "operations" => hash_including(DevMatch::PRIMARY.to_s))
      )
    end
  end

  describe "routing" do
    it "sends the root at the dev console" do
      get "/"

      expect(response).to redirect_to(
        "/matches/#{DevMatch::ID}/operations/#{DevMatch::PRIMARY}"
      )
    end
  end
end
