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
end
