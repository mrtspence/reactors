# frozen_string_literal: true

require "rails_helper"

# The dev engine has a console and nothing to fit: no outfitting or crew screen, and no place in
# the fitting screens' machine switcher.
RSpec.describe "The dev engine's console", type: :request do
  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("REACTOR_DEV_ENGINE").and_return("1")
    DevPlayer.grant_everything!
    DevMatch.provision!
  end

  def console = console_path(match_id: DevMatch::ID, operation_id: "dev_engine")

  it "renders its levers and gauges, without outfitting or crew links" do
    get console

    expect(response).to have_http_status(:ok)
    expect(response.body).to include("Range (×10ⁿ W)", "Set Power")
    expect(response.body).not_to include(edit_loadout_path(match_id: DevMatch::ID, operation_id: "dev_engine"))
  end

  it "has no outfitting or crew screen" do
    get edit_loadout_path(match_id: DevMatch::ID, operation_id: "dev_engine")
    expect(response).to have_http_status(:not_found)

    get edit_crew_path(match_id: DevMatch::ID, operation_id: "dev_engine")
    expect(response).to have_http_status(:not_found)
  end

  it "is not offered by the fitting screens' switcher" do
    get edit_loadout_path(match_id: DevMatch::ID, operation_id: "pit")

    expect(response.body).to include(edit_loadout_path(match_id: DevMatch::ID, operation_id: "engine"))
    expect(response.body).not_to include(edit_loadout_path(match_id: DevMatch::ID, operation_id: "dev_engine"))
  end
end
