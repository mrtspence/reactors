# frozen_string_literal: true

require "rails_helper"

# The pre-match crew screen, and the order behind its button: **validate, store, reset.**
#
# The same two things that order prevents for parts, prevented here for people: a roster the
# screen refused must never reach the database, and one that never reached the database must
# never reach the runner.
RSpec.describe "crews" do
  let(:edit_path) do
    edit_crew_path(match_id: DevMatch::ID, operation_id: DevMatch::OPERATION_ID)
  end
  let(:update_path) { crew_path(match_id: DevMatch::ID, operation_id: DevMatch::OPERATION_ID) }
  let(:draft_path) do
    crew_draft_path(match_id: DevMatch::ID, operation_id: DevMatch::OPERATION_ID)
  end

  before do
    DevPlayer.grant_everything!
    allow(CommandProducer).to receive(:instance).and_return(producer)
  end

  let(:producer) { instance_double(CommandProducer, produce: nil) }

  it "renders every job the machine has" do
    get edit_path

    expect(response).to have_http_status(:ok)
    ReactorSim::Operations::SteamEngine.crew_roles.each do |role|
      expect(response.body).to include(role.label)
    end
  end

  it "posts a crew, stores it, and asks the runner to rebuild" do
    patch update_path, params: { crew: { fireman: { minion: "jim", tool: "stokers_shovel" } } }

    expect(response).to redirect_to(console_path(match_id: DevMatch::ID,
                                                 operation_id: DevMatch::OPERATION_ID))
    stored = Roster.find_by(match_id: DevMatch::ID).to_sim
    expect(stored.fetch(:fireman)).to include(minion: :jim, tool: :stokers_shovel)
    expect(producer).to have_received(:produce)
  end

  # Every role named, including the ones nobody was posted to — so a job a player deliberately
  # left to the labour exchange does not re-default on the next render.
  it "names a role left empty rather than omitting it" do
    patch update_path, params: { crew: { fireman: { minion: "jim" } } }

    expect(Roster.find_by(match_id: DevMatch::ID).to_sim.keys)
      .to contain_exactly(:fireman, :yardhand)
  end

  # **An unselected `<select>` submits an empty string, and "" is not nil.** Left in, it reaches
  # `to_sym` and becomes `:""` — a posting for somebody with no name, which resolves to nobody
  # and is not the same as an empty slot.
  it "treats an unselected dropdown as empty rather than as a nameless person" do
    patch update_path, params: { crew: { fireman: { minion: "jim", gear: "" } } }

    expect(Roster.find_by(match_id: DevMatch::ID).to_sim.fetch(:fireman)).not_to have_key(:gear)
  end

  it "keeps the whole roster, since the form submits all of it every time" do
    patch update_path, params: { crew: { fireman: { minion: "jim" },
                                         yardhand: { minion: "galathas" } } }
    patch update_path, params: { crew: { fireman: { minion: "elowynne" } } }

    stored = Roster.find_by(match_id: DevMatch::ID).to_sim
    expect(stored.fetch(:fireman)[:minion]).to be(:elowynne)
    expect(stored.fetch(:yardhand)[:minion]).to be_nil
  end

  describe "somebody on the injury list" do
    before do
      MinionCondition.record!(owner_id: DevPlayer::ID, minion_id: "jim", run_id: "r",
                              cause: "boiler", matches: 2)
    end

    # Refused rather than silently swapped. Substitution happens at BUILD for a post left empty,
    # which is a different statement and should feel different to a player.
    it "refuses a roster that posts them, and stores nothing" do
      patch update_path, params: { crew: { fireman: { minion: "jim" } } }

      expect(response).to have_http_status(:unprocessable_content)
      expect(Roster.find_by(match_id: DevMatch::ID)).to be_nil
      expect(producer).not_to have_received(:produce)
    end

    it "says who, and for how long" do
      get edit_path

      expect(response.body).to include("Jim Ashfield")
      expect(response.body).to include("2 more matches")
    end
  end

  describe "the draft" do
    # It earns its keep harder here than for parts: changing who holds a job changes **which kit
    # is offered**, because equipment is owned per minion.
    it "offers the newly chosen person's kit without storing anything" do
      post draft_path, params: { crew: { fireman: { minion: "jim" } } }

      expect(response).to have_http_status(:ok)
      # "Gauge Spanner" rather than "Stoker's Shovel": ERB escapes the apostrophe to `&#39;`,
      # so asserting the label as it is written in `kit.rb` looks for something that cannot
      # appear. Picking a label with no punctuation says what it means without a workaround.
      expect(response.body).to include("Gauge Spanner")
      expect(Roster.find_by(match_id: DevMatch::ID)).to be_nil
    end

    it "offers no kit at all for a post nobody is standing in" do
      post draft_path, params: { crew: { fireman: {} } }

      expect(response.body).not_to include("Gauge Spanner")
    end
  end

  # `permit`, never `permit!`. Each of these shapes reached `String#to_sym` and 500'd the draft
  # action, which has no rescue.
  describe "shapes that used to 500" do
    [ { crew: "nonsense" },
      { crew: { fireman: "nonsense" } },
      { crew: { fireman: { minion: [ "jim" ] } } },
      { crew: { fireman: { training: "hot_work_ticket" } } } ].each do |params|
      it "survives #{params.inspect}" do
        post draft_path, params: params

        expect(response).to have_http_status(:ok)
      end
    end
  end
end
