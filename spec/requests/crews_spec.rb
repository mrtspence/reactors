# frozen_string_literal: true

require "rails_helper"

# The pre-match crew screen, and the order behind its button: **validate, store, reset.**
#
# The same two things that order prevents for parts, prevented here for people: a roster the
# screen refused must never reach the database, and one that never reached the database must
# never reach the runner.
RSpec.describe "crews" do
  let(:edit_path) do
    edit_crew_path(match_id: DevMatch::ID, operation_id: DevMatch::PRIMARY)
  end
  let(:update_path) { crew_path(match_id: DevMatch::ID, operation_id: DevMatch::PRIMARY) }
  let(:draft_path) do
    crew_draft_path(match_id: DevMatch::ID, operation_id: DevMatch::PRIMARY)
  end

  before do
    DevPlayer.grant_everything!
    # **An operation has to exist to be owned.** Every controller now finds a row and asks it
    # whether this player may touch it, so a spec that skips this gets a 404 from the filter
    # rather than the behaviour it was testing.
    DevMatch.provision!
    allow(CommandProducer).to receive(:instance).and_return(producer)
  end

  let(:producer) { instance_double(CommandProducer, produce: nil) }

  # **Seats, and how many there are comes from the fitted quarters.** Asked of the registry by
  # type rather than by naming `Operations::SteamEngine`, which is what lets a second machine be
  # a registration rather than a branch in this screen.
  it "renders a seat for every hand the fitted quarters can field" do
    get edit_path

    expect(response).to have_http_status(:ok)
    capacity = ReactorSim::Operations
               .assembly_for(DevMatch.kind_of(DevMatch::PRIMARY)).crew_capacity
    expect(capacity).to be_positive
    (1..capacity).each { |n| expect(response.body).to include("Seat #{n}") }
  end

  it "posts a crew, stores it, and asks the runner to rebuild" do
    patch update_path, params: { crew: { crew_1: { minion: "jim", tool: "stokers_shovel" } } }

    expect(response).to redirect_to(console_path(match_id: DevMatch::ID,
                                                 operation_id: DevMatch::PRIMARY))
    stored = Roster.find_by(match_id: DevMatch::ID).to_sim
    expect(stored.fetch(:crew_1)).to include(minion: :jim, tool: :stokers_shovel)
    expect(producer).to have_received(:produce)
  end

  # Every seat named, including the ones nobody was posted to — so a seat a player deliberately
  # left to the labour exchange does not re-default on the next render.
  it "names a seat left empty rather than omitting it" do
    patch update_path, params: { crew: { crew_1: { minion: "jim" } } }

    expect(Roster.find_by(match_id: DevMatch::ID).to_sim.keys)
      .to contain_exactly(:crew_1, :crew_2)
  end

  # **An unselected `<select>` submits an empty string, and "" is not nil.** Left in, it reaches
  # `to_sym` and becomes `:""` — a posting for somebody with no name, which resolves to nobody
  # and is not the same as an empty slot.
  it "treats an unselected dropdown as empty rather than as a nameless person" do
    patch update_path, params: { crew: { crew_1: { minion: "jim", gear: "" } } }

    expect(Roster.find_by(match_id: DevMatch::ID).to_sim.fetch(:crew_1)).not_to have_key(:gear)
  end

  it "keeps the whole roster, since the form submits all of it every time" do
    patch update_path, params: { crew: { crew_1: { minion: "jim" },
                                         crew_2: { minion: "galathas" } } }
    patch update_path, params: { crew: { crew_1: { minion: "elowynne" } } }

    stored = Roster.find_by(match_id: DevMatch::ID).to_sim
    expect(stored.fetch(:crew_1)[:minion]).to be(:elowynne)
    expect(stored.fetch(:crew_2)[:minion]).to be_nil
  end

  describe "somebody on the injury list" do
    before do
      MinionCondition.record!(owner_id: DevPlayer::ID, minion_id: "jim", run_id: "r",
                              cause: "boiler", matches: 2)
    end

    # Refused rather than silently swapped. Substitution happens at BUILD for a post left empty,
    # which is a different statement and should feel different to a player.
    it "refuses a roster that posts them, and stores nothing" do
      patch update_path, params: { crew: { crew_1: { minion: "jim" } } }

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
    # It earns its keep harder here than for parts: changing who sits in a seat changes **which
    # kit is offered**, because equipment is owned per minion.
    it "offers the newly chosen person's kit without storing anything" do
      post draft_path, params: { crew: { crew_1: { minion: "jim" } } }

      expect(response).to have_http_status(:ok)
      # "Gauge Spanner" rather than "Stoker's Shovel": ERB escapes the apostrophe to `&#39;`,
      # so asserting the label as it is written in `kit.rb` looks for something that cannot
      # appear. Picking a label with no punctuation says what it means without a workaround.
      expect(response.body).to include("Gauge Spanner")
      expect(Roster.find_by(match_id: DevMatch::ID)).to be_nil
    end

    it "offers no kit at all for a seat nobody is sitting in" do
      post draft_path, params: { crew: { crew_1: {} } }

      expect(response.body).not_to include("Gauge Spanner")
    end
  end

  # `permit`, never `permit!`. Each of these shapes reached `String#to_sym` and 500'd the draft
  # action, which has no rescue.
  describe "shapes that used to 500" do
    [ { crew: "nonsense" },
      { crew: { crew_1: "nonsense" } },
      { crew: { crew_1: { minion: [ "jim" ] } } },
      { crew: { crew_1: { training: "hot_work_ticket" } } } ].each do |params|
      it "survives #{params.inspect}" do
        post draft_path, params: params

        expect(response).to have_http_status(:ok)
      end
    end
  end
end
