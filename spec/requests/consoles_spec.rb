# frozen_string_literal: true

require "rails_helper"

# The console's chrome, as far as it is the page's rather than the panel's.
RSpec.describe "the console", type: :request do
  before do
    allow(CommandProducer).to receive(:instance).and_return(instance_double(CommandProducer, produce: true))
    allow(Operator).to receive(:bypass?).and_return(true)
    DevPlayer.grant_everything!
    DevMatch.provision!
  end

  def console(operation_id) = console_path(match_id: DevMatch::ID, operation_id: operation_id)

  def of_kind(kind) = DevMatch::OPERATIONS.key(kind)

  it "shows a machine its own start-up note and no other machine's" do
    get console(of_kind(:steam_engine))
    expect(response.body).to include("The fire is banked")

    get console(of_kind(:open_pit))
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("The fire is banked")
  end
end
