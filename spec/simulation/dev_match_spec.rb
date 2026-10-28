# frozen_string_literal: true

require "rails_helper"

# **A stored loadout that the catalogue has moved on from.** A part renamed or removed, or a part
# that still exists but now belongs to another slot, makes `Assembly` refuse the build — and the dev
# match then cannot boot at all. `DevMatch.stored_parts` drops such a part so its slot falls back to
# the default, and the machine is the one a player would get fresh.
RSpec.describe DevMatch do
  describe ".stored_parts" do
    # The mine's cages moved from `manriding` to `winder`, and the coal-only cage winder is gone.
    it "drops a part the catalogue no longer has, and one its slot no longer takes" do
      Loadout.fit(match_id: DevMatch::ID, operation_id: "pit", chassis: "single_shaft",
                  parts: { winder: :cage_winder, manriding: :cage_gear, fan: :guibal_fan })

      parts = described_class.stored_parts(operation_id: :pit)

      expect(parts).to eq(fan: :guibal_fan)
      expect { described_class.outfitting(operation_id: :pit) }.not_to raise_error
    end
  end

  # The runner rebuilds from the reset command alone, so the grudges have to be in it.
  describe "grudges from earlier matches" do
    before { Grudge.deepen!(owner_id: DevPlayer::ID, holder_id: "urist", target_id: "galathas", amount: 0.3, run_id: "r", tick: 1) }

    it "ride in the reset command" do
      expect(described_class.reset_command.fetch("grudges")).to include("urist" => include("galathas" => 0.3))
    end

    it "reach every crewed machine's options" do
      match = described_class.build
      crewed = match.operations.select { |op| op.options.key?(:crew) }

      expect(crewed).not_to be_empty
      expect(crewed.map { |op| op.options.dig(:grudges, :urist, :galathas) }.uniq).to eq([ 0.3 ])
    end
  end

  describe "the dev engine" do
    def flag(value)
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("REACTOR_DEV_ENGINE").and_return(value)
    end

    it "ropes itself to the pit's line shaft in place of the steam engine, and another to the open pit's" do
      flag("1")

      match = described_class.build

      expect(match.operation(:dev_engine)).not_to be_nil
      expect(match.couplings.map { |c| [ c.from, c.to ] })
        .to eq([ [ %i[dev_engine drive], %i[pit line_shaft] ], [ %i[open_pit_dev_engine drive], %i[open_pit line_shaft] ] ])
    end

    it "is not in the match without the flag" do
      flag(nil)

      expect(described_class.operation_ids).not_to include(:dev_engine)
    end

    it "is not in the match outside development and test, flag or no flag" do
      flag("1")
      allow(Rails.env).to receive(:local?).and_return(false)

      expect(described_class.operation_ids).not_to include(:dev_engine)
    end
  end
end
