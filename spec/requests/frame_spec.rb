# frozen_string_literal: true

require "rails_helper"

# **The app's frame**: the nav row, the state strip and the feed on every screen, and the strip
# drawing only the framed machine's state.
RSpec.describe "the frame", type: :request do
  before do
    allow(CommandProducer).to receive(:instance).and_return(instance_double(CommandProducer, produce: true))
    allow(Operator).to receive(:bypass?).and_return(true)
    DevPlayer.grant_everything!
    DevMatch.provision!
  end

  def of_kind(kind) = DevMatch::OPERATIONS.key(kind)
  def at(kind) = { match_id: DevMatch::ID, operation_id: of_kind(kind) }
  def page = Nokogiri::HTML(response.body)
  def drawn(region) = page.css("#{region} [data-instrument-id]").map { |el| el["data-instrument-id"] }

  it "frames every screen with the nav row, the strip and the feed" do
    [ console_path(at(:steam_engine)), edit_loadout_path(at(:steam_engine)), edit_crew_path(at(:steam_engine)),
      edit_match_setup_path(match_id: DevMatch::ID) ].each do |path|
      get path

      expect(response).to have_http_status(:ok)
      expect(page.css("nav[aria-label='App']")).not_to be_empty, path
      expect(page.css(".frame-strip")).not_to be_empty, path
      expect(page.css(".frame-feed [data-feed-target='list']")).not_to be_empty, path
    end
  end

  it "draws the weather and the output in the strip and not in the console's panel" do
    get console_path(at(:steam_engine))

    expect(drawn(".frame-strip")).to include("the_hour", "the_light", "engine_power")
    expect(drawn(".frame-centre")).not_to include("the_hour", "the_light", "engine_power")
    expect(drawn(".frame-centre")).not_to be_empty
  end

  it "shows only the framed machine's output" do
    get console_path(at(:open_pit))

    expect(drawn(".frame-strip")).to include("finished_tons")
    expect(drawn(".frame-strip")).not_to include("engine_power", "coal_raised")
  end

  it "keeps the frame across one machine's screens and gives another machine its own" do
    get console_path(at(:steam_engine))
    console = page.at_css(".frame-top")["id"]
    get edit_loadout_path(at(:steam_engine))
    outfitting = page.at_css(".frame-top")["id"]
    get console_path(at(:open_pit))

    expect(outfitting).to eq(console)
    expect(page.at_css(".frame-top")["id"]).not_to eq(console)
    expect(page.at_css(".frame-top")["data-turbo-permanent"]).not_to be_nil
  end

  it "frames match setup on the match's primary machine" do
    get edit_match_setup_path(match_id: DevMatch::ID)

    expect(page.at_css(".frame-top")["data-stream-operation-id-value"]).to eq(DevMatch::PRIMARY.to_s)
  end

  it "shows the stubs without making them links" do
    get console_path(at(:steam_engine))

    Frame::STUBS.each do |stub|
      expect(page.css("nav[aria-label='App']").text).to include(stub)
      expect(page.css("nav[aria-label='App'] a").map(&:text)).not_to include(stub)
    end
  end

  it "keeps the console's places and minimap room, and no other screen's" do
    get console_path(at(:open_pit))
    expect(page.css(".frame-left .frame-places, .frame-left .frame-placeholder-minimap").size).to eq(2)

    get edit_loadout_path(at(:open_pit))
    expect(page.css(".frame-left")).to be_empty
  end
end
