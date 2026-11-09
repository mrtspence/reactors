# frozen_string_literal: true

require "reactor_sim"
require "support/open_pit_rig"
require "support/pit_rig"
require "support/engine_rig"

# **Where the panel says everything is**, which is what lets the console draw one place at a time.
# Derived, never declared: an instrument is where whoever reads it stands, else where what it reads
# is, else where the posts working that are; a lever is at its post. Zero ticks throughout — the
# panel is chrome.
RSpec.describe "the panel's places" do
  def by_id(panel) = panel.fetch(:instruments).to_h { |chrome| [ chrome.fetch(:id), chrome.fetch(:places) ] }

  def declared(panel) = panel.fetch(:places).map { |place| place.fetch(:id) }

  shared_examples "a panel by place" do
    it "names only places the machine declares" do
      places = declared(panel)

      expect(panel.fetch(:instruments).flat_map { |chrome| chrome.fetch(:places) } - places).to be_empty
      expect(panel.fetch(:controls).filter_map { |control| control[:place] } - places).to be_empty
      expect(panel.fetch(:stations).filter_map { |station| station[:place] } - places).to be_empty
    end
  end

  describe "the open pit, fitted with a shovel and a dinky" do
    before { allow(ReactorSim::Content).to receive(:default).and_return(OpenPitRig::CONTENT) }

    let(:op) do
      OpenPitRig.build(id: "p", seed: 1, crew: OpenPitRig.crew(14),
                       loadout: { stripping_shovel_dipper: :yard_dipper, stripping_train_train: :dinkey_train })
    end
    let(:panel) { op.panel }

    it_behaves_like "a panel by place"

    # The mud dam is at the dams; the washer's hands at bank are who tell it.
    it "puts an observed instrument where its observer stands, not where what it reads is" do
      expect(op.layout.place_of_node(:mud_dam)).to eq(:dams)
      expect(by_id(panel).fetch(:the_dam)).to eq([ :bank ])
    end

    it "puts the shovel's board on its bench, where the crew working it stand" do
      expect(by_id(panel).fetch(:stripping_shovel_board)).to eq([ :stripping_bench ])
    end

    it "puts a footplate's board on the footplate" do
      expect(by_id(panel).fetch(:stripping_train_board)).to eq([ :stripping_train_footplate ])
    end

    it "gives every lever and post its post's place" do
      panel.fetch(:controls).each { |control| expect(control[:place]).to eq(op.layout.place_of(control[:id])) }
      panel.fetch(:stations).each { |station| expect(station[:place]).to eq(op.layout.place_of(station[:id])) }
    end
  end

  describe "the colliery" do
    include PitRig

    before { allow(ReactorSim::Content).to receive(:default).and_return(PitRig::CONTENT) }

    let(:panel) { build_pit(id: "m", seed: 1).panel }

    it_behaves_like "a panel by place"

    it "puts a way's instruments in both places at its ends, in the machine's order" do
      expect(by_id(panel).values_at(:roof_timber, :putting)).to all(eq(%i[pit_bottom district]))
    end

    it "puts what is in no room in the works" do
      expect(by_id(panel).values_at(:seam_remaining, :water_make)).to all(eq([]))
    end
  end

  describe "a machine with no places" do
    let(:panel) do
      ReactorSim::Match.create(id: "d", seed: 1, operations: [ { id: "bench", type: :dev_engine } ])
                       .operation(:bench).panel
    end

    it "has everything in the works" do
      expect(panel.fetch(:places)).to be_empty
      expect(panel.fetch(:instruments).map { |chrome| chrome.fetch(:places) }).to all(eq([]))
      expect(panel.fetch(:controls).map { |control| control[:place] }).to all(be_nil)
    end
  end
end
