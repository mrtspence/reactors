# frozen_string_literal: true

require "rails_helper"

# **The console by place**: a panel for each place the machine declares and The Works, one shown,
# and a line for each in the places box — or, with one place, that place and no box. Each
# instrument is drawn in exactly the panels its places name. Chrome only; the JavaScript that
# switches and fills them has no harness here.
RSpec.describe "the console by place", type: :request do
  before do
    allow(CommandProducer).to receive(:instance).and_return(instance_double(CommandProducer, produce: true))
    allow(Operator).to receive(:bypass?).and_return(true)
    DevPlayer.grant_everything!
    DevMatch.provision!
  end

  def console(kind) = console_path(match_id: DevMatch::ID, operation_id: DevMatch::OPERATIONS.key(kind))
  def page = Nokogiri::HTML(response.body)
  def panels = page.css("[data-place-panel]").map { |el| el["data-place-panel"] }
  def panel = DevMatch.panel(operation_id: DevMatch::OPERATIONS.key(:open_pit))

  it "draws a panel and a line for every place in the pit, then The Works, one panel shown" do
    get console(:open_pit)
    places = panel.fetch(:places).map { |place| place.fetch(:id).to_s } + [ "works" ]

    expect(panels).to eq(places)
    expect(page.css("[data-places-line]").map { |el| el["data-places-line"] }).to eq(places)
    expect(page.css("[data-place-panel]:not(.hidden)").size).to eq(1)
  end

  it "draws each instrument in exactly the panels its places name, The Works for none" do
    get console(:open_pit)

    panel.fetch(:instruments).reject { |chrome| chrome[:role] }.each do |chrome|
      wanted = chrome.fetch(:places).empty? ? [ "works" ] : chrome.fetch(:places).map(&:to_s)
      drawn = page.css("[data-place-panel]").select { |el| el.at_css("[data-instrument-id='#{chrome.fetch(:id)}']") }

      expect(drawn.map { |el| el["data-place-panel"] }).to eq(wanted), chrome.fetch(:id).to_s
    end
  end

  it "draws each lever once, in its post's place, and everybody on the roster once" do
    get console(:open_pit)

    expect(page.css("[data-lever-id]").size).to eq(panel.fetch(:controls).size)
    panel.fetch(:controls).each do |control|
      expect(page.at_css("[data-place-panel='#{control.fetch(:place)}'] [data-lever-id='#{control.fetch(:id)}']")).not_to be_nil
    end
    crew = DevMatch.crew(operation_id: DevMatch::OPERATIONS.key(:open_pit))
    expect(page.css("[data-minion-id]").map { |el| el["data-minion-id"] }).to match_array(crew.map { |minion| minion.id.to_s })
  end

  it "gives the places box only a board's calm words, never the rest of its phrases" do
    get console(:open_pit)
    boards = page.css("[data-places-boards]").flat_map { |el| JSON.parse(el["data-places-boards"]) }

    expect(boards).not_to be_empty
    expect(boards.map(&:keys).uniq).to eq([ %w[id calm] ])
  end

  it "puts a machine with one place in that place, with no box" do
    get console(:steam_engine)

    expect(panels).to eq([ "engine_house" ])
    expect(page.css("[data-places-line]")).to be_empty
    expect(page.css("[data-place-panel='engine_house'] [data-instrument-id='water_remaining']")).not_to be_empty
  end
end
