# frozen_string_literal: true

require "rails_helper"

# The season a match is played under, and the chain behind the button: store it, then ask the
# runner to rebuild the match carrying it.
RSpec.describe "Match setup", type: :request do
  let(:producer) { instance_spy(CommandProducer) }

  # A spec that needs a broker running is a spec nobody runs.
  before { allow(CommandProducer).to receive(:instance).and_return(producer) }
  before { DevMatch.provision! }

  def path = edit_match_setup_path(match_id: DevMatch::ID)
  def save_path = match_setup_path(match_id: DevMatch::ID)

  it "offers every season the climate has" do
    get path

    expect(response).to have_http_status(:ok)
    MatchSetup.seasons.each { |season| expect(response.body).to include(season.titleize) }
  end

  it "stores the season and rebuilds the match carrying it" do
    season = (MatchSetup.seasons - [ MatchSetup::DEFAULT_SEASON ]).first
    patch save_path, params: { match_setup: { season: season } }

    expect(MatchSetup.for(DevMatch::ID).season).to eq(season)
    expect(producer).to have_received(:produce)
      .with(hash_including(command: hash_including("conditions" => hash_including("season" => season))))
  end

  it "refuses a season the climate does not have, and rebuilds nothing" do
    patch save_path, params: { match_setup: { season: "monsoon" } }

    expect(response).to have_http_status(:unprocessable_content)
    expect(producer).not_to have_received(:produce)
  end

  # Every machine with a sky is built under the stored season.
  it "builds the match under the stored season" do
    season = (MatchSetup.seasons - [ MatchSetup::DEFAULT_SEASON ]).first
    MatchSetup.for(DevMatch::ID).update!(season: season)
    match = DevMatch.build

    skied = match.operations.select { |op| op.options.key?(:conditions) }
    expect(skied).not_to be_empty
    expect(skied.map { |op| op.options.fetch(:conditions).fetch(:season) }.uniq).to eq([ season.to_sym ])
  end
end
